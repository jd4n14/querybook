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
