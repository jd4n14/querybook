//go:build darwin && cgo

package credentials

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdlib.h>
#include <string.h>

static CFStringRef qb_string(const char *v) {
	return CFStringCreateWithCString(kCFAllocatorDefault, v, kCFStringEncodingUTF8);
}

static CFDictionaryRef qb_query(const char *service, const char *account) {
	CFStringRef s = qb_string(service);
	CFStringRef a = qb_string(account);
	const void *keys[] = { kSecClass, kSecAttrService, kSecAttrAccount };
	const void *vals[] = { kSecClassGenericPassword, s, a };
	CFDictionaryRef q = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 3,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFRelease(s);
	CFRelease(a);
	return q;
}

static OSStatus qb_add(const char *service, const char *account, const unsigned char *secret, size_t n) {
	CFStringRef s = qb_string(service);
	CFStringRef a = qb_string(account);
	CFDataRef d = CFDataCreate(kCFAllocatorDefault, secret, (CFIndex)n);
	const void *keys[] = { kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData };
	const void *vals[] = { kSecClassGenericPassword, s, a, d };
	CFDictionaryRef q = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 4,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	OSStatus status = SecItemAdd(q, NULL);
	CFRelease(q); CFRelease(d); CFRelease(s); CFRelease(a);
	return status;
}

static OSStatus qb_get(const char *service, const char *account, unsigned char **out, size_t *n) {
	CFDictionaryRef q = qb_query(service, account);
	const void *keys[] = { kSecReturnData, kSecMatchLimit };
	const void *vals[] = { kCFBooleanTrue, kSecMatchLimitOne };
	CFMutableDictionaryRef query = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, q);
	CFDictionarySetValue(query, keys[0], vals[0]);
	CFDictionarySetValue(query, keys[1], vals[1]);
	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching(query, &result);
	if (status == errSecSuccess) {
		CFDataRef data = (CFDataRef)result;
		CFIndex len = CFDataGetLength(data);
		unsigned char *copy = (unsigned char *)malloc((size_t)len);
		if (copy == NULL && len != 0) status = errSecAllocate;
		else { memcpy(copy, CFDataGetBytePtr(data), (size_t)len); *out = copy; *n = (size_t)len; }
	}
	if (result != NULL) CFRelease(result);
	CFRelease(query); CFRelease(q);
	return status;
}

static OSStatus qb_update(const char *service, const char *account, const unsigned char *secret, size_t n) {
	CFDictionaryRef q = qb_query(service, account);
	CFDataRef d = CFDataCreate(kCFAllocatorDefault, secret, (CFIndex)n);
	const void *key = kSecValueData;
	const void *val = d;
	CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, &key, &val, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	OSStatus status = SecItemUpdate(q, attrs);
	CFRelease(attrs); CFRelease(d); CFRelease(q);
	return status;
}

static OSStatus qb_delete(const char *service, const char *account) {
	CFDictionaryRef q = qb_query(service, account);
	OSStatus status = SecItemDelete(q);
	CFRelease(q);
	return status;
}

static const char *qb_status_not_found(void) { return "not_found"; }
static void qb_free(void *p) { free(p); }
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

type nativeBackend struct{}

func runtimeUnavailable() bool { return false }

func statusError(op string, status C.OSStatus) error {
	if status == C.errSecItemNotFound {
		return ErrNotFound
	}
	if status == C.errSecDuplicateItem {
		return ErrAlreadyExists
	}
	return fmt.Errorf("keychain %s failed (osstatus %d)", op, int32(status))
}

func cbytes(v string) (*C.char, error) {
	if len(v) == 0 || len(v) > 4096 || bytesHasNUL(v) {
		return nil, errors.New("invalid keychain identifier")
	}
	return C.CString(v), nil
}

func bytesHasNUL(v string) bool {
	for i := 0; i < len(v); i++ {
		if v[i] == 0 {
			return true
		}
	}
	return false
}

func (nativeBackend) Add(service, account string, secret []byte) error {
	s, err := cbytes(service)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(s))
	a, err := cbytes(account)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(a))
	var p *C.uchar
	if len(secret) > 0 {
		p = (*C.uchar)(unsafe.Pointer(&secret[0]))
	}
	status := C.qb_add(s, a, p, C.size_t(len(secret)))
	if status != C.errSecSuccess {
		return statusError("add", status)
	}
	return nil
}

func (nativeBackend) Get(service, account string) ([]byte, error) {
	s, err := cbytes(service)
	if err != nil {
		return nil, err
	}
	defer C.free(unsafe.Pointer(s))
	a, err := cbytes(account)
	if err != nil {
		return nil, err
	}
	defer C.free(unsafe.Pointer(a))
	var p *C.uchar
	var n C.size_t
	status := C.qb_get(s, a, &p, &n)
	if status != C.errSecSuccess {
		return nil, statusError("get", status)
	}
	defer C.qb_free(unsafe.Pointer(p))
	if n == 0 {
		return []byte{}, nil
	}
	return C.GoBytes(unsafe.Pointer(p), C.int(n)), nil
}

func (nativeBackend) Update(service, account string, secret []byte) error {
	s, err := cbytes(service)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(s))
	a, err := cbytes(account)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(a))
	var p *C.uchar
	if len(secret) > 0 {
		p = (*C.uchar)(unsafe.Pointer(&secret[0]))
	}
	status := C.qb_update(s, a, p, C.size_t(len(secret)))
	if status != C.errSecSuccess {
		return statusError("update", status)
	}
	return nil
}

func (nativeBackend) Delete(service, account string) error {
	s, err := cbytes(service)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(s))
	a, err := cbytes(account)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(a))
	status := C.qb_delete(s, a)
	if status != C.errSecSuccess {
		return statusError("delete", status)
	}
	return nil
}
