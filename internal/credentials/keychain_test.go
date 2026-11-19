package credentials

import (
	"bytes"
	"errors"
	"os"
	"runtime"
	"testing"

	"github.com/google/uuid"
)

type fakeBackend struct{ values map[string][]byte }

func (f *fakeBackend) key(s, a string) string { return s + "\x00" + a }
func (f *fakeBackend) Add(s, a string, v []byte) error {
	k := f.key(s, a)
	if _, ok := f.values[k]; ok {
		return ErrAlreadyExists
	}
	f.values[k] = append([]byte(nil), v...)
	return nil
}
func (f *fakeBackend) Get(s, a string) ([]byte, error) {
	v, ok := f.values[f.key(s, a)]
	if !ok {
		return nil, ErrNotFound
	}
	return append([]byte(nil), v...), nil
}
func (f *fakeBackend) Update(s, a string, v []byte) error {
	k := f.key(s, a)
	if _, ok := f.values[k]; !ok {
		return ErrNotFound
	}
	f.values[k] = append([]byte(nil), v...)
	return nil
}
func (f *fakeBackend) Delete(s, a string) error {
	k := f.key(s, a)
	if _, ok := f.values[k]; !ok {
		return ErrNotFound
	}
	delete(f.values, k)
	return nil
}

func TestStoreUsesInjectedBackendAndCopiesSecrets(t *testing.T) {
	f := &fakeBackend{values: map[string][]byte{}}
	s := New(f)
	account := uuid.NewString()
	secret := []byte("sentinel-password")
	if err := s.Add(account, secret); err != nil {
		t.Fatal(err)
	}
	secret[0] = 'X'
	got, err := s.Get(account)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "sentinel-password" {
		t.Fatalf("secret=%q", got)
	}
	got[0] = 'Y'
	got, err = s.Get(account)
	if err != nil || string(got) != "sentinel-password" {
		t.Fatalf("copy=%q err=%v", got, err)
	}
	if err := s.Set(account, []byte("new-secret")); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(account); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(account); !errors.Is(err, ErrNotFound) {
		t.Fatalf("not found=%v", err)
	}
}

// This is an intentionally isolated smoke proof for the native backend. It
// creates one random Querybook generic-password item and always removes it.
func TestNativeBackendCRUDSynthetic(t *testing.T) {
	if runtimeUnavailable() {
		t.Skip("native keychain unavailable on this platform/build")
	}
	if runtime.GOOS == "linux" && os.Getenv("QUERYBOOK_TEST_SECRET_SERVICE") != "1" {
		t.Skip("set QUERYBOOK_TEST_SECRET_SERVICE=1 to test with a real Linux keyring")
	}
	s := New(nil)
	account := "test-" + uuid.NewString()
	defer func() { _ = s.Delete(account) }()
	want := []byte("  synthetic\x00password\xff\n")
	if err := s.Add(account, want); err != nil {
		t.Fatal(err)
	}
	if err := s.Add(account, []byte("duplicate")); !errors.Is(err, ErrAlreadyExists) {
		t.Fatalf("duplicate add: %v", err)
	}
	got, err := s.Get(account)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("get=%q err=%v", got, err)
	}
	if err := s.Set(account, []byte("querybook-keychain-updated")); err != nil {
		t.Fatal(err)
	}
	got, err = s.Get(account)
	if err != nil || string(got) != "querybook-keychain-updated" {
		t.Fatalf("update=%q err=%v", got, err)
	}
	if err := s.Delete(account); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(account); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete=%v", err)
	}
	if err := s.Delete(account); !errors.Is(err, ErrNotFound) {
		t.Fatalf("delete missing credential: %v", err)
	}
	if err := s.Set(account, []byte{}); err != nil {
		t.Fatal(err)
	}
	got, err = s.Get(account)
	if err != nil || len(got) != 0 {
		t.Fatalf("empty=%q err=%v", got, err)
	}
}
