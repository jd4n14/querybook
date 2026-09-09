//go:build !darwin || !cgo

package credentials

type nativeBackend struct{}

func runtimeUnavailable() bool { return true }

func (nativeBackend) Add(string, string, []byte) error    { return unavailableError("add") }
func (nativeBackend) Get(string, string) ([]byte, error)  { return nil, unavailableError("get") }
func (nativeBackend) Update(string, string, []byte) error { return unavailableError("update") }
func (nativeBackend) Delete(string, string) error         { return unavailableError("delete") }
