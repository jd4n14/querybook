// Package connections owns durable, non-secret connection metadata and the
// active connection selection. Passwords are addressed by metadata UUID in
// the OS credential store and never enter SQLite.
package connections

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
	"github.com/jd4n14/querybook/internal/credentials"
	"github.com/jd4n14/querybook/internal/protocol"
	_ "modernc.org/sqlite"
)

const defaultDirectory = "querybook"
const defaultFilename = "connections.sqlite"

type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string        { return e.Code + ": " + e.Message }
func errf(code, message string) error { return &Error{Code: code, Message: message} }

type Store struct {
	db          *sql.DB
	credentials *credentials.Store
	path        string
}

func DefaultPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("configuration directory unavailable")
	}
	return filepath.Join(dir, defaultDirectory, defaultFilename), nil
}

func Open(path string, creds *credentials.Store) (*Store, error) {
	if path == "" {
		var err error
		path, err = DefaultPath()
		if err != nil {
			return nil, err
		}
	}
	if path != ":memory:" {
		dir := filepath.Dir(path)
		if err := os.MkdirAll(dir, 0700); err != nil {
			return nil, fmt.Errorf("metadata store unavailable")
		}
		if err := os.Chmod(dir, 0700); err != nil {
			return nil, fmt.Errorf("metadata store unavailable")
		}
	}
	if creds == nil {
		creds = credentials.New(nil)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("metadata store unavailable")
	}
	s := &Store{db: db, credentials: creds, path: path}
	if err := s.init(); err != nil {
		db.Close()
		return nil, err
	}
	if err := securePermissions(path); err != nil {
		db.Close()
		return nil, fmt.Errorf("metadata store unavailable")
	}
	return s, nil
}

func securePermissions(path string) error {
	if path == ":memory:" {
		return nil
	}
	if err := os.Chmod(path, 0600); err != nil {
		return err
	}
	for _, sidecar := range []string{path + "-wal", path + "-shm"} {
		if err := os.Chmod(sidecar, 0600); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func (s *Store) Path() string { return s.path }
func (s *Store) Close() error { return s.db.Close() }

func (s *Store) init() error {
	for _, q := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=NORMAL",
		"PRAGMA busy_timeout=5000",
		`CREATE TABLE IF NOT EXISTS connections (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL UNIQUE,
			driver TEXT NOT NULL,
			path TEXT NOT NULL DEFAULT '',
			host TEXT NOT NULL DEFAULT '',
			port INTEGER NOT NULL DEFAULT 0,
			socket TEXT NOT NULL DEFAULT '',
			user TEXT NOT NULL DEFAULT '',
			database_name TEXT NOT NULL DEFAULT '',
			charset TEXT NOT NULL DEFAULT ''
			,credential_present INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
	} {
		if _, err := s.db.Exec(q); err != nil {
			return fmt.Errorf("metadata store unavailable")
		}
	}
	return nil
}

func validate(c protocol.Connection) error {
	if strings.TrimSpace(c.Name) == "" {
		return errf("invalid_connection", "name is required")
	}
	if len(c.Name) > 200 {
		return errf("invalid_connection", "name is too long")
	}
	if c.Driver != "sqlite" && c.Driver != "mysql" {
		return errf("invalid_connection", "unsupported driver")
	}
	if c.Driver == "sqlite" && c.Path == "" {
		return errf("invalid_connection", "SQLite path is required")
	}
	if c.Driver == "mysql" && c.Path != "" {
		return errf("invalid_connection", "MySQL path is not supported")
	}
	if c.Port < 0 || c.Port > 65535 {
		return errf("invalid_connection", "port is invalid")
	}
	return nil
}

func normalizeConnection(c protocol.Connection) (protocol.Connection, error) {
	if c.Driver == "sqlite" {
		path, err := NormalizeSQLitePath(c.Path)
		if err != nil {
			return protocol.Connection{}, err
		}
		c.Path = path
	}
	return c, nil
}

func (s *Store) Create(c protocol.Connection, password *string) (protocol.Connection, error) {
	if err := validate(c); err != nil {
		return protocol.Connection{}, err
	}
	var err error
	c, err = normalizeConnection(c)
	if err != nil {
		return protocol.Connection{}, err
	}
	c.ID = uuid.NewString()
	tx, err := s.db.Begin()
	if err != nil {
		return protocol.Connection{}, errf("metadata_store", "could not begin metadata update")
	}
	if password != nil {
		c.HasPassword = true
	}
	_, err = tx.Exec(`INSERT INTO connections (id,name,driver,path,host,port,socket,user,database_name,charset,credential_present) VALUES (?,?,?,?,?,?,?,?,?,?,?)`, c.ID, c.Name, c.Driver, c.Path, c.Host, c.Port, c.Socket, c.User, c.Database, c.Charset, c.HasPassword)
	if err != nil {
		_ = tx.Rollback()
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return protocol.Connection{}, errf("duplicate_name", "connection name already exists")
		}
		return protocol.Connection{}, errf("metadata_store", "could not create connection")
	}
	if password != nil {
		if s.credentials == nil {
			_ = tx.Rollback()
			return protocol.Connection{}, errf("credential_store", "credential store unavailable")
		}
		if err := s.credentials.Add(c.ID, []byte(*password)); err != nil {
			_ = tx.Rollback()
			_ = s.credentials.Delete(c.ID)
			return protocol.Connection{}, errf("credential_store", "could not store credential")
		}
	}
	if err := tx.Commit(); err != nil {
		if password != nil && s.credentials != nil {
			_ = s.credentials.Delete(c.ID)
		}
		return protocol.Connection{}, errf("metadata_store", "could not create connection")
	}
	return c, nil
}

func (s *Store) List() ([]protocol.Connection, string, error) {
	rows, err := s.db.Query(`SELECT id,name,driver,path,host,port,socket,user,database_name,charset,credential_present FROM connections ORDER BY name`)
	if err != nil {
		return nil, "", errf("metadata_store", "could not list connections")
	}
	defer rows.Close()
	var out []protocol.Connection
	for rows.Next() {
		var c protocol.Connection
		if err := rows.Scan(&c.ID, &c.Name, &c.Driver, &c.Path, &c.Host, &c.Port, &c.Socket, &c.User, &c.Database, &c.Charset, &c.HasPassword); err != nil {
			return nil, "", errf("metadata_store", "could not read metadata")
		}
		c, err = normalizeConnection(c)
		if err != nil {
			return nil, "", err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, "", errf("metadata_store", "could not read metadata")
	}
	return out, s.activeID(), nil
}

func (s *Store) Get(id string) (protocol.Connection, error) {
	var c protocol.Connection
	err := s.db.QueryRow(`SELECT id,name,driver,path,host,port,socket,user,database_name,charset,credential_present FROM connections WHERE id=?`, id).Scan(&c.ID, &c.Name, &c.Driver, &c.Path, &c.Host, &c.Port, &c.Socket, &c.User, &c.Database, &c.Charset, &c.HasPassword)
	if errors.Is(err, sql.ErrNoRows) {
		return protocol.Connection{}, errf("connection_not_found", "connection not found")
	}
	if err != nil {
		return protocol.Connection{}, errf("metadata_store", "could not read metadata")
	}
	c, err = normalizeConnection(c)
	if err != nil {
		return protocol.Connection{}, err
	}
	return c, nil
}

func (s *Store) Update(c protocol.Connection) (protocol.Connection, error) {
	if c.ID == "" {
		return protocol.Connection{}, errf("connection_not_found", "connection not found")
	}
	if err := validate(c); err != nil {
		return protocol.Connection{}, err
	}
	var err error
	c, err = normalizeConnection(c)
	if err != nil {
		return protocol.Connection{}, err
	}
	res, err := s.db.Exec(`UPDATE connections SET name=?,driver=?,path=?,host=?,port=?,socket=?,user=?,database_name=?,charset=? WHERE id=?`, c.Name, c.Driver, c.Path, c.Host, c.Port, c.Socket, c.User, c.Database, c.Charset, c.ID)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "unique") {
			return protocol.Connection{}, errf("duplicate_name", "connection name already exists")
		}
		return protocol.Connection{}, errf("metadata_store", "could not update connection")
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return protocol.Connection{}, errf("connection_not_found", "connection not found")
	}
	return c, nil
}

func (s *Store) SetPassword(id, password string) error {
	if _, err := s.Get(id); err != nil {
		return err
	}
	if s.credentials == nil {
		return errf("credential_store", "credential store unavailable")
	}
	if err := s.credentials.Set(id, []byte(password)); err != nil {
		return errf("credential_store", "could not store credential")
	}
	if _, err := s.db.Exec(`UPDATE connections SET credential_present=1 WHERE id=?`, id); err != nil {
		return errf("partial_failure", "credential stored but metadata could not be updated")
	}
	return nil
}

func (s *Store) Delete(id string) error {
	c, err := s.Get(id)
	if err != nil {
		if e, ok := err.(*Error); ok && e.Code == "connection_not_found" {
			return nil
		}
		return err
	}
	if c.HasPassword && s.credentials != nil {
		if err := s.credentials.Delete(id); err != nil && !errors.Is(err, credentials.ErrNotFound) {
			return errf("partial_failure", "credential removed status is unknown; metadata retained")
		}
	}
	res, err := s.db.Exec(`DELETE FROM connections WHERE id=?`, id)
	if err != nil {
		return errf("partial_failure", "credential removed but metadata could not be deleted")
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil
	}
	_, _ = s.db.Exec(`DELETE FROM settings WHERE key='active_connection_id' AND value=?`, id)
	return nil
}

func (s *Store) Select(id string) (protocol.Connection, string, error) {
	c, err := s.Get(id)
	if err != nil {
		return protocol.Connection{}, "", err
	}
	if _, err := s.db.Exec(`INSERT INTO settings(key,value) VALUES('active_connection_id',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, id); err != nil {
		return protocol.Connection{}, "", errf("metadata_store", "could not select connection")
	}
	return c, id, nil
}

func (s *Store) activeID() string {
	var id string
	_ = s.db.QueryRow(`SELECT value FROM settings WHERE key='active_connection_id'`).Scan(&id)
	return id
}

// Resolve is the only method that returns a credential. Callers must use the
// bytes immediately to construct an in-memory DSN and must never serialize it.
// Go and the database driver do not guarantee runtime memory erasure; this
// boundary keeps the lifetime and number of copies as small as practical.
func (s *Store) Resolve(id string) (protocol.Connection, []byte, error) {
	c, err := s.Get(id)
	if err != nil {
		return protocol.Connection{}, nil, err
	}
	if !c.HasPassword {
		return c, nil, nil
	}
	if s.credentials == nil {
		return protocol.Connection{}, nil, errf("credential_store", "credential store unavailable")
	}
	p, err := s.credentials.Get(id)
	if errors.Is(err, credentials.ErrNotFound) {
		return protocol.Connection{}, nil, errf("credential_not_found", "credential not found")
	}
	if err != nil {
		return protocol.Connection{}, nil, errf("credential_store", "could not read credential")
	}
	return c, p, nil
}

func (s *Store) Test(ctx context.Context, id string) error {
	c, _, err := s.Resolve(id)
	if err != nil {
		return err
	}
	if c.Driver == "sqlite" {
		if err := CheckSQLitePath(c.Path); err != nil {
			return err
		}
		db, err := sql.Open("sqlite", c.Path)
		if err != nil {
			return errf("sqlite_path_unavailable", "SQLite database could not be opened")
		}
		defer db.Close()
		if err := db.PingContext(ctx); err != nil {
			return errf("sqlite_path_unavailable", "SQLite database could not be opened")
		}
		return nil
	}
	return errf("connection", "connection test is handled by the query executor")
}
