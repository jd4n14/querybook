package protocol

import (
	"bytes"
	"io"
	"testing"
)

func TestJSONLAndCells(t *testing.T) {
	var b bytes.Buffer
	if err := Encode(&b, Event{Version: 1, Type: "rows", ExecutionID: "e", Rows: [][]Cell{{NullCell(), TextCell(""), TextCell("9223372036854775807"), BinaryCell([]byte{0, 1, 255})}}}); err != nil {
		t.Fatal(err)
	}
	d := NewDecoder(bytes.NewBufferString(`{"version":1,"type":"shutdown"}`+"\n"), 1024)
	req, err := d.Next()
	if err != nil || req.Type != "shutdown" {
		t.Fatalf("decode: %#v %v", req, err)
	}
	if _, err := d.Next(); err != io.EOF {
		t.Fatalf("expected EOF, got %v", err)
	}
	if _, err := DecodeLine([]byte(`{"version":2,"type":"shutdown"}`)); err != ErrUnsupportedVersion {
		t.Fatalf("version: %v", err)
	}
}

func TestConnectionProtocolRejectsInlineSecretsAndRequiresIDForExecute(t *testing.T) {
	if _, err := DecodeLine([]byte(`{"version":1,"type":"execute","request_id":"r","execution_id":"e","connection":{"driver":"mysql","password":"sentinel"},"sql":"SELECT 1"}`)); err == nil {
		t.Fatal("nested execute credential accepted")
	}
	if _, err := DecodeLine([]byte(`{"version":1,"type":"execute","request_id":"r","execution_id":"e","connection_id":"id","password":"sentinel","sql":"SELECT 1"}`)); err == nil {
		t.Fatal("inline execute credential accepted")
	}
	empty := ""
	raw := `{"version":1,"type":"connection","request_id":"r","op":"create","connection":{"name":"n","driver":"mysql"},"password":""}`
	got, err := DecodeLine([]byte(raw))
	if err != nil || got.Password == nil || *got.Password != empty {
		t.Fatalf("empty password presence lost: %#v err=%v", got, err)
	}
	if _, err := DecodeLine([]byte(`{"version":1,"type":"connection","request_id":"r","op":"update","connection":{"id":"id","name":"n","driver":"mysql"},"password":"sentinel"}`)); err == nil {
		t.Fatal("update credential accepted")
	}
}
