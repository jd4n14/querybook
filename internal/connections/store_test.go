package connections

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jd4n14/querybook/internal/credentials"
	"github.com/jd4n14/querybook/internal/protocol"
)

type fakeCredentials struct {
	values     map[string][]byte
	failDelete bool
}

func (f *fakeCredentials) Add(_, id string, p []byte) error {
	if _, ok := f.values[id]; ok {
		return credentials.ErrAlreadyExists
	}
	f.values[id] = append([]byte(nil), p...)
	return nil
}
func (f *fakeCredentials) Get(_, id string) ([]byte, error) {
	v, ok := f.values[id]
	if !ok {
		return nil, credentials.ErrNotFound
	}
	return append([]byte(nil), v...), nil
}
func (f *fakeCredentials) Update(_, id string, p []byte) error {
	if _, ok := f.values[id]; !ok {
		return credentials.ErrNotFound
	}
	f.values[id] = append([]byte(nil), p...)
	return nil
}
func (f *fakeCredentials) Delete(_, id string) error {
	if f.failDelete {
		return errors.New("keychain unavailable")
	}
	if _, ok := f.values[id]; !ok {
		return credentials.ErrNotFound
	}
	delete(f.values, id)
	return nil
}

func openTest(t *testing.T) (*Store, *fakeCredentials, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "nested", "connections.sqlite")
	f := &fakeCredentials{values: map[string][]byte{}}
	s, err := Open(path, credentials.New(f))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, f, path
}

func TestCRUDPersistenceSelectionAndNoSecretSQLite(t *testing.T) {
	s, f, path := openTest(t)
	c, err := s.Create(protocol.Connection{Name: "local", Driver: "sqlite", Path: filepath.Join(t.TempDir(), "fixture.db")}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if c.ID == "" || c.HasPassword {
		t.Fatalf("metadata=%#v", c)
	}
	mysql, err := s.Create(protocol.Connection{Name: "mysql", Driver: "mysql", Host: "db", User: "u", Database: "app"}, strptr("querybook-password-sentinel"))
	if err != nil {
		t.Fatal(err)
	}
	if !mysql.HasPassword || len(f.values) != 1 {
		t.Fatalf("secret state=%#v", mysql)
	}
	if _, _, err := s.Select(mysql.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, f2, _ := func() (*Store, *fakeCredentials, string) {
		f2 := &fakeCredentials{values: f.values}
		ss, err := Open(path, credentials.New(f2))
		if err != nil {
			t.Fatal(err)
		}
		return ss, f2, path
	}()
	defer s.Close()
	list, active, err := s.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || active != mysql.ID {
		t.Fatalf("list=%#v active=%q", list, active)
	}
	if _, _, err := s.Resolve(mysql.ID); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "querybook-password-sentinel") {
		t.Fatal("secret leaked into metadata database")
	}
	var schema string
	if err := s.db.QueryRow(`SELECT sql FROM sqlite_master WHERE name='connections'`).Scan(&schema); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(schema), "password") || strings.Contains(strings.ToLower(schema), "secret") || strings.Contains(strings.ToLower(schema), "checksum") {
		t.Fatalf("secret-bearing schema=%q", schema)
	}
	if err := s.Delete(mysql.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(mysql.ID); err != nil {
		t.Fatal("delete should be idempotent:", err)
	}
	if _, ok := f2.values[mysql.ID]; ok {
		t.Fatal("credential not deleted")
	}
}

func TestMetadataPermissionsArePrivateAndPermissionErrorsFailClosed(t *testing.T) {
	s, _, path := openTest(t)
	defer s.Close()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("database mode=%o", info.Mode().Perm())
	}
	dirInfo, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if dirInfo.Mode().Perm() != 0700 {
		t.Fatalf("directory mode=%o", dirInfo.Mode().Perm())
	}
	for _, sidecar := range []string{path + "-wal", path + "-shm"} {
		if err := os.WriteFile(sidecar, []byte("sidecar"), 0644); err != nil {
			t.Fatal(err)
		}
		if err := securePermissions(path); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(sidecar)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0600 {
			t.Fatalf("sidecar %s mode=%o", sidecar, info.Mode().Perm())
		}
	}
	if err := securePermissions(filepath.Join(filepath.Dir(path), "missing", "metadata.sqlite")); err == nil {
		t.Fatal("permission failure was ignored")
	}
}

func TestPasswordlessCRUDWorksWithUnavailableNativeCredentialStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "connections.sqlite")
	s, err := Open(path, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	c, err := s.Create(protocol.Connection{Name: "sqlite", Driver: "sqlite", Path: ":memory:"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.List(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Select(c.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(c.ID); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteCredentialFailureRetainsMetadata(t *testing.T) {
	s, f, _ := openTest(t)
	c, err := s.Create(protocol.Connection{Name: "mysql", Driver: "mysql", Host: "h"}, strptr("sentinel"))
	if err != nil {
		t.Fatal(err)
	}
	f.failDelete = true
	if err := s.Delete(c.ID); err == nil || !strings.HasPrefix(err.Error(), "partial_failure:") {
		t.Fatalf("delete error=%v", err)
	}
	if _, err := s.Get(c.ID); err != nil {
		t.Fatalf("metadata lost: %v", err)
	}
}

func strptr(v string) *string { return &v }
