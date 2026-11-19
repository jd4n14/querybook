// Package credentials stores connection secrets outside Querybook's metadata
// database. It uses Keychain on macOS and Secret Service on Linux.
// The package intentionally has no plaintext fallback.
package credentials

import (
	"errors"
	"fmt"
)

var ErrNotFound = errors.New("credential not found")
var ErrAlreadyExists = errors.New("credential already exists")
var ErrUnavailable = errors.New("credential store unavailable")

const Service = "com.jd4n14.querybook.connections"

// Backend is the small operation surface used by Store and its tests. The
// native backend is injectable so metadata tests can use an isolated store.
type Backend interface {
	Add(service, account string, secret []byte) error
	Get(service, account string) ([]byte, error)
	Update(service, account string, secret []byte) error
	Delete(service, account string) error
}

type Store struct {
	backend Backend
	service string
}

func New(backend Backend) *Store {
	if backend == nil {
		backend = nativeBackend{}
	}
	return &Store{backend: backend, service: Service}
}

func (s *Store) Add(account string, secret []byte) error {
	if account == "" {
		return errors.New("missing credential account")
	}
	return s.backend.Add(s.service, account, secret)
}

func (s *Store) Get(account string) ([]byte, error) {
	if account == "" {
		return nil, errors.New("missing credential account")
	}
	b, err := s.backend.Get(s.service, account)
	if err != nil {
		return nil, err
	}
	return b, nil
}

func (s *Store) Set(account string, secret []byte) error {
	if account == "" {
		return errors.New("missing credential account")
	}
	if err := s.backend.Add(s.service, account, secret); err == nil {
		return nil
	} else if errors.Is(err, ErrUnavailable) {
		return err
	} else if !errors.Is(err, ErrAlreadyExists) {
		// Backends that do not expose a duplicate sentinel still support an
		// existing-item update (the native backend does expose it).
		if updateErr := s.backend.Update(s.service, account, secret); updateErr == nil {
			return nil
		}
		return err
	}
	if err := s.backend.Update(s.service, account, secret); err == nil {
		return nil
	} else if !errors.Is(err, ErrNotFound) {
		return err
	}
	return s.backend.Add(s.service, account, secret)
}

func (s *Store) Delete(account string) error {
	if account == "" {
		return errors.New("missing credential account")
	}
	return s.backend.Delete(s.service, account)
}

func unavailableError(op string) error { return fmt.Errorf("%w: %s", ErrUnavailable, op) }
