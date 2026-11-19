//go:build linux && cgo

package credentials

/*
#cgo pkg-config: libsecret-1
#include <libsecret/secret.h>
#include <stdlib.h>

static const SecretSchema querybook_schema = {
	.name = "com.jd4n14.querybook.connections",
	.attributes = {
		{ "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
		{ "account", SECRET_SCHEMA_ATTRIBUTE_STRING },
		{ NULL, 0 },
	},
};

static GHashTable *querybook_attributes(const char *service, const char *account) {
	return secret_attributes_build(&querybook_schema, "service", service, "account", account, NULL);
}

static SecretCollection *querybook_default_collection(SecretService *service, GCancellable *cancel, GError **err) {
	return secret_collection_for_alias_sync(service, SECRET_COLLECTION_DEFAULT, SECRET_COLLECTION_NONE, cancel, err);
}

static SecretItem *querybook_find(GHashTable *attributes, GCancellable *cancel, GError **err) {
	GList *items = secret_service_search_sync(NULL, &querybook_schema, attributes, SECRET_SEARCH_NONE, cancel, err);
	if (items == NULL) return NULL;
	SecretItem *item = g_object_ref(items->data);
	g_list_free_full(items, g_object_unref);
	return item;
}

static SecretItem *querybook_create(SecretCollection *collection, GHashTable *attributes, SecretValue *value, GCancellable *cancel, GError **err) {
	return secret_item_create_sync(collection, &querybook_schema, attributes, "Querybook connection",
		value, SECRET_ITEM_CREATE_NONE, cancel, err);
}

static SecretValue *querybook_value(const char *data, gssize len) {
	return secret_value_new(data == NULL ? "" : data, len, "application/octet-stream");
}
*/
import "C"

import (
	"errors"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
	"unsafe"
)

type nativeBackend struct{}

func runtimeUnavailable() bool { return false }

// Serialize the local existence check and create. Secret Service has a flag
// for replacing an item, but no atomic create-if-absent operation.
var secretServiceAddMu sync.Mutex

func secretServiceRequest(service, account string) (*C.GHashTable, *C.GCancellable, func(), error) {
	for _, id := range []string{service, account} {
		if id == "" || !utf8.ValidString(id) || strings.ContainsRune(id, 0) {
			return nil, nil, nil, errors.New("invalid Secret Service identifier")
		}
	}
	s, a := C.CString(service), C.CString(account)
	defer C.free(unsafe.Pointer(s))
	defer C.free(unsafe.Pointer(a))
	attrs := C.querybook_attributes(s, a)
	cancel := C.g_cancellable_new()
	done := make(chan struct{})
	timer := time.AfterFunc(10*time.Second, func() {
		C.g_cancellable_cancel(cancel)
		close(done)
	})
	return attrs, cancel, func() {
		if !timer.Stop() {
			<-done
		}
		C.g_object_unref(C.gpointer(unsafe.Pointer(cancel)))
		C.g_hash_table_unref(attrs)
	}, nil
}

func secretServiceError(err *C.GError, detail string) error {
	if err != nil {
		defer C.g_error_free(err)
		switch {
		case C.g_error_matches(err, C.secret_error_get_quark(), C.SECRET_ERROR_NO_SUCH_OBJECT) != 0:
			return ErrNotFound
		case C.g_error_matches(err, C.secret_error_get_quark(), C.SECRET_ERROR_ALREADY_EXISTS) != 0:
			return ErrAlreadyExists
		case C.g_error_matches(err, C.secret_error_get_quark(), C.SECRET_ERROR_IS_LOCKED) != 0:
			return unavailableError("unlock the Linux keyring")
		}
	}
	return unavailableError(detail)
}

func findSecretItem(attrs *C.GHashTable, cancel *C.GCancellable) (*C.SecretItem, error) {
	var detail *C.GError
	item := C.querybook_find(attrs, cancel, &detail)
	if item != nil {
		return item, nil
	}
	if detail == nil {
		return nil, ErrNotFound
	}
	return nil, secretServiceError(detail, "check that Secret Service is running in the D-Bus session")
}

func (nativeBackend) Add(service, account string, secret []byte) error {
	secretServiceAddMu.Lock()
	defer secretServiceAddMu.Unlock()
	attrs, cancel, cleanup, err := secretServiceRequest(service, account)
	if err != nil {
		return err
	}
	defer cleanup()
	item, err := findSecretItem(attrs, cancel)
	if err == nil {
		C.g_object_unref(C.gpointer(unsafe.Pointer(item)))
		return ErrAlreadyExists
	}
	if !errors.Is(err, ErrNotFound) {
		return err
	}
	var detail *C.GError
	keyring := C.secret_service_get_sync(C.SECRET_SERVICE_NONE, cancel, &detail)
	if keyring == nil {
		return secretServiceError(detail, "check that Secret Service is running in the D-Bus session")
	}
	defer C.g_object_unref(C.gpointer(unsafe.Pointer(keyring)))
	collection := C.querybook_default_collection(keyring, cancel, &detail)
	if collection == nil {
		if detail != nil {
			C.g_error_free(detail)
		}
		return unavailableError("set up a default Linux keyring in Secret Service")
	}
	defer C.g_object_unref(C.gpointer(unsafe.Pointer(collection)))
	if C.secret_collection_get_locked(collection) != 0 {
		return unavailableError("unlock the default Linux keyring")
	}
	value := C.querybook_value((*C.char)(unsafe.Pointer(unsafe.SliceData(secret))), C.gssize(len(secret)))
	defer C.secret_value_unref(C.gpointer(unsafe.Pointer(value)))
	item = C.querybook_create(collection, attrs, value, cancel, &detail)
	if item == nil {
		return secretServiceError(detail, "could not create a Secret Service item")
	}
	C.g_object_unref(C.gpointer(unsafe.Pointer(item)))
	return nil
}

func withSecretItem(service, account string, op func(*C.SecretItem, *C.GCancellable) error) error {
	attrs, cancel, cleanup, err := secretServiceRequest(service, account)
	if err != nil {
		return err
	}
	defer cleanup()
	item, err := findSecretItem(attrs, cancel)
	if err != nil {
		return err
	}
	defer C.g_object_unref(C.gpointer(unsafe.Pointer(item)))
	if C.secret_item_get_locked(item) != 0 {
		return unavailableError("unlock the Linux keyring")
	}
	return op(item, cancel)
}

func (nativeBackend) Get(service, account string) ([]byte, error) {
	var secret []byte
	err := withSecretItem(service, account, func(item *C.SecretItem, cancel *C.GCancellable) error {
		var detail *C.GError
		if C.secret_item_load_secret_sync(item, cancel, &detail) == 0 {
			return secretServiceError(detail, "could not load a Secret Service item")
		}
		value := C.secret_item_get_secret(item)
		if value == nil {
			return unavailableError("could not read a Secret Service item")
		}
		defer C.secret_value_unref(C.gpointer(unsafe.Pointer(value)))
		var size C.gsize
		data := C.secret_value_get(value, &size)
		secret = C.GoBytes(unsafe.Pointer(data), C.int(size))
		return nil
	})
	return secret, err
}

func (nativeBackend) Update(service, account string, secret []byte) error {
	return withSecretItem(service, account, func(item *C.SecretItem, cancel *C.GCancellable) error {
		value := C.querybook_value((*C.char)(unsafe.Pointer(unsafe.SliceData(secret))), C.gssize(len(secret)))
		defer C.secret_value_unref(C.gpointer(unsafe.Pointer(value)))
		var detail *C.GError
		if C.secret_item_set_secret_sync(item, value, cancel, &detail) == 0 {
			return secretServiceError(detail, "could not update a Secret Service item")
		}
		return nil
	})
}

func (nativeBackend) Delete(service, account string) error {
	return withSecretItem(service, account, func(item *C.SecretItem, cancel *C.GCancellable) error {
		var detail *C.GError
		if C.secret_item_delete_sync(item, cancel, &detail) == 0 {
			return secretServiceError(detail, "could not delete a Secret Service item")
		}
		return nil
	})
}
