package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jd4n14/querybook/internal/connections"
	"github.com/jd4n14/querybook/internal/credentials"
	"github.com/jd4n14/querybook/internal/protocol"
	"github.com/jd4n14/querybook/internal/results"
	_ "modernc.org/sqlite"
)

type memoryCreds struct{ values map[string][]byte }

func (m *memoryCreds) Add(_, account string, secret []byte) error {
	if m.values == nil {
		m.values = map[string][]byte{}
	}
	if _, ok := m.values[account]; ok {
		return credentials.ErrAlreadyExists
	}
	m.values[account] = append([]byte(nil), secret...)
	return nil
}
func (m *memoryCreds) Get(_, account string) ([]byte, error) {
	v, ok := m.values[account]
	if !ok {
		return nil, credentials.ErrNotFound
	}
	return append([]byte(nil), v...), nil
}
func (m *memoryCreds) Update(_, account string, secret []byte) error {
	if _, ok := m.values[account]; !ok {
		return credentials.ErrNotFound
	}
	m.values[account] = append([]byte(nil), secret...)
	return nil
}
func (m *memoryCreds) Delete(_, account string) error {
	if _, ok := m.values[account]; !ok {
		return credentials.ErrNotFound
	}
	delete(m.values, account)
	return nil
}

func TestSQLSSettingsReturnsPasswordOnlyInSQLSConfig(t *testing.T) {
	storePath := filepath.Join(t.TempDir(), "connections.sqlite")
	store, err := connections.Open(storePath, credentials.New(&memoryCreds{values: map[string][]byte{}}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	sentinel := "s3ntinel@/pass"
	c, err := store.Create(protocol.Connection{Name: "mysql", Driver: "mysql", Host: "127.0.0.1", User: "u", Database: "app"}, &sentinel)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Select(c.ID); err != nil {
		t.Fatal(err)
	}
	var got protocol.Event
	r := &runner{
		store:     store,
		storePath: storePath,
		active:    map[string]context.CancelFunc{},
		results:   results.New(results.Options{}),
		sendFn: func(e protocol.Event) error {
			got = e
			return nil
		},
	}
	r.connection(protocol.Request{Version: 1, Type: "connection", RequestID: "r", Op: "sqls_settings"})
	if got.Type != "connection" || got.SQLS == nil || len(got.SQLS.Connections) != 1 {
		t.Fatalf("event=%#v", got)
	}
	conn := got.SQLS.Connections[0]
	if conn.Passwd != sentinel || conn.Proto != "tcp" || conn.DataSourceName != "" || conn.Driver != "mysql" {
		t.Fatalf("sqls conn=%#v", conn)
	}
	if got.Connection == nil || got.Connection.ID != c.ID || got.ActiveConnectionID != c.ID {
		t.Fatalf("metadata=%#v active=%q", got.Connection, got.ActiveConnectionID)
	}
	raw, err := json.Marshal(got.Connection)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), sentinel) || strings.Contains(string(raw), "passwd") {
		t.Fatalf("connection metadata leaked secret: %s", raw)
	}
}

func TestFullExportTerminalReportsStreamedRows(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "source.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (v INTEGER); WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 600) INSERT INTO t SELECT n FROM nums"); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	events := make(chan protocol.Event, 128)
	r := &runner{
		results:     results.New(results.Options{}),
		active:      map[string]context.CancelFunc{},
		exports:     map[string]context.CancelFunc{},
		exportOwner: map[string]string{},
		sendFn: func(e protocol.Event) error {
			events <- e
			return nil
		},
	}
	defer r.shutdown()
	conn := protocol.Connection{Driver: "sqlite", Name: "source", Path: dbPath}
	handle, err := r.results.Retain(results.Metadata{
		Columns:     []protocol.Column{{Name: "v", DatabaseType: "INTEGER"}},
		OriginalSQL: "SELECT v FROM t ORDER BY v",
		Connection:  conn,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(dir, "full.csv")
	if err := r.startExport(protocol.Request{Version: 1, Type: "export", RequestID: "full", Handle: handle, Scope: "full", Format: "csv", ExportID: "full-rows", Path: output, StorePath: filepath.Join(dir, "connections.sqlite")}); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(10 * time.Second)
	for {
		select {
		case event := <-events:
			if !event.Terminal {
				continue
			}
			if event.Type == "error" {
				t.Fatalf("full export failed: %s", event.Message)
			}
			if event.RowCount != 600 {
				t.Fatalf("terminal row count=%d, want 600", event.RowCount)
			}
			return
		case <-deadline:
			t.Fatal("timed out waiting for full export terminal event")
		}
	}
}
