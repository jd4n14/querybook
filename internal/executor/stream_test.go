package executor

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
	_ "modernc.org/sqlite"
)

func TestStreamUsesOriginalSQLWithoutProtectiveAutoLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stream.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (v INTEGER)"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 1001; i++ {
		if _, err := db.Exec("INSERT INTO t(v) VALUES (?)", i); err != nil {
			t.Fatal(err)
		}
	}
	_ = db.Close()
	var rows int
	var gotSQLRows int
	result, err := Stream(context.Background(), protocol.Request{
		SQL:          "SELECT v FROM t ORDER BY v LIMIT 2000",
		Connection:   protocol.Connection{Driver: "sqlite", Path: path},
		ConnectionID: "",
		Force:        true, // stream must retain its read-only boundary
	}, Resolver(nil), StreamSink{
		OnSchema: func(set int, columns []protocol.Column) error {
			if set != 0 || len(columns) != 1 {
				t.Fatalf("schema set=%d columns=%#v", set, columns)
			}
			return nil
		},
		OnRow: func(set int, row []protocol.Cell) error {
			rows++
			if set != 0 || len(row) != 1 {
				t.Fatalf("row set=%d row=%#v", set, row)
			}
			return nil
		},
		OnProgress: func(p StreamProgress) error {
			gotSQLRows++
			return nil
		},
	}, StreamOptions{ProgressRows: 500})
	if err != nil {
		t.Fatal(err)
	}
	if rows != 1001 || result.Rows != 1001 || result.ResultSets != 1 {
		t.Fatalf("stream result=%+v callbacks=%d", result, rows)
	}
	if gotSQLRows == 0 {
		t.Fatal("progress callback missing")
	}
}

func TestStreamRejectsWritesEvenWithForce(t *testing.T) {
	_, err := Stream(context.Background(), protocol.Request{SQL: "DELETE FROM t", Force: true, Connection: protocol.Connection{Driver: "sqlite", Path: "/tmp/nope"}}, nil, StreamSink{}, StreamOptions{})
	if err == nil {
		t.Fatal("write accepted")
	}
}

func TestStreamCancellationStopsCallbacks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cancel.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (v INTEGER)"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 100; i++ {
		if _, err := db.Exec("INSERT INTO t(v) VALUES (?)", i); err != nil {
			t.Fatal(err)
		}
	}
	_ = db.Close()
	ctx, cancel := context.WithCancel(context.Background())
	var seen int
	_, err = Stream(ctx, protocol.Request{SQL: "SELECT v FROM t", Connection: protocol.Connection{Driver: "sqlite", Path: path}}, nil, StreamSink{OnRow: func(_ int, _ []protocol.Cell) error {
		seen++
		if seen == 3 {
			cancel()
		}
		return nil
	}}, StreamOptions{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err=%v", err)
	}
	if seen != 3 {
		t.Fatalf("callbacks after cancellation: %d", seen)
	}
}

func TestStreamMaxCellAndRowBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "limits.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('12345')"); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	_, err = Stream(context.Background(), protocol.Request{SQL: "SELECT v FROM t", Connection: protocol.Connection{Driver: "sqlite", Path: path}}, nil, StreamSink{}, StreamOptions{MaxCellBytes: 4})
	if err == nil {
		t.Fatal("cell limit not enforced")
	}
	_, err = Stream(context.Background(), protocol.Request{SQL: "SELECT v FROM t", Connection: protocol.Connection{Driver: "sqlite", Path: path}}, nil, StreamSink{}, StreamOptions{MaxRowBytes: 4})
	if err == nil {
		t.Fatal("row limit not enforced")
	}
}
