package executor

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
	_ "modernc.org/sqlite"
)

func TestSQLitePositionalExactResultsAndGuard(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "fixture.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec("CREATE TABLE t (v TEXT, b BLOB); INSERT INTO t VALUES ('NULL', x'0001ff');")
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "1", ExecutionID: "e", Connection: protocol.Connection{Driver: "sqlite", Path: dbPath}, SQL: "SELECT 1 AS dup, 2 AS dup, v, b FROM t"}
	var events []protocol.Event
	res, err := Execute(context.Background(), req, func(e protocol.Event) error { events = append(events, e); return nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != 1 || len(res.Rows[0]) != 4 {
		t.Fatalf("rows=%#v", res.Rows)
	}
	if res.Rows[0][0].Text != "1" || res.Rows[0][1].Text != "2" {
		t.Fatalf("duplicate labels lost: %#v", res.Rows[0])
	}
	if res.Rows[0][2].Text != "NULL" || res.Rows[0][3].Kind != "binary" {
		t.Fatalf("exact cells: %#v", res.Rows[0])
	}
	if len(events) < 2 || len(events[0].Columns) != 4 {
		t.Fatalf("schema event missing: %#v", events)
	}
	bad := req
	bad.SQL = "DELETE FROM t"
	if _, err = Execute(context.Background(), bad, func(protocol.Event) error { return nil }); err == nil {
		t.Fatal("unsafe write allowed")
	}
	forced := bad
	forced.Force = true
	if _, err = Execute(context.Background(), forced, func(protocol.Event) error { return nil }); err != nil {
		t.Fatal(err)
	}
	check, _ := sql.Open("sqlite", dbPath)
	defer check.Close()
	var n int
	_ = check.QueryRow("SELECT count(*) FROM t").Scan(&n)
	if n != 0 {
		t.Fatalf("forced delete did not execute: %d", n)
	}
}

func TestSQLiteSchemaAndRetention(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fixture.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('a'),('b'),('c');")
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "r", ExecutionID: "e", Connection: protocol.Connection{Driver: "sqlite", Path: path}, SQL: "SELECT v AS value FROM t WHERE 0", MaxRetainedRows: 1, MaxRetainedBytes: 100, BatchRows: 1, BatchBytes: 100}
	var starts int
	got, err := Execute(context.Background(), req, func(e protocol.Event) error {
		if e.Type == "result_start" {
			starts++
			if len(e.Columns) != 1 || e.Columns[0].Name != "value" {
				t.Errorf("schema=%#v", e.Columns)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if starts != 1 || len(got.Rows) != 0 {
		t.Fatalf("zero result=%#v starts=%d", got, starts)
	}
	req.SQL = "SELECT v FROM t"
	got, err = Execute(context.Background(), req, func(e protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if !got.Truncated || len(got.Rows) != 1 || got.Reason == "" {
		t.Fatalf("retention=%#v", got)
	}
}

func TestBatchByteLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fixture.db")
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "r", ExecutionID: "e", Connection: protocol.Connection{Driver: "sqlite", Path: path}, SQL: "SELECT printf('%0*d', 100, 0)", MaxRetainedBytes: 4096, BatchBytes: 32, BatchRows: 10}
	if _, err := Execute(context.Background(), req, func(protocol.Event) error { return nil }); err == nil {
		t.Fatal("oversized batch row accepted")
	}
}

func TestSQLiteDriverReadOnlyBoundaryRejectsWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boundary.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err = conn.ExecContext(context.Background(), "PRAGMA query_only=ON"); err != nil {
		t.Fatal(err)
	}
	if _, err = conn.ExecContext(context.Background(), "CREATE TABLE blocked(v TEXT)"); err == nil {
		t.Fatal("SQLite query_only boundary allowed a write")
	}
}

func TestMySQLDSNUsesDriverAddressSyntax(t *testing.T) {
	d, err := dsn(protocol.Connection{Driver: "mysql", Host: "127.0.0.1", Port: 3307, User: "u", Password: "p", Database: "db"})
	if err != nil {
		t.Fatal(err)
	}
	if d != "u:p@tcp(127.0.0.1:3307)/db?charset=utf8mb4&parseTime=false" {
		t.Fatalf("dsn=%q", d)
	}
	d, err = dsn(protocol.Connection{Driver: "mysql", Socket: "/tmp/mysql.sock", User: "u", Database: "db"})
	if err != nil {
		t.Fatal(err)
	}
	if d != "u:@unix(/tmp/mysql.sock)/db?charset=utf8mb4&parseTime=false" {
		t.Fatalf("socket dsn=%q", d)
	}
}

func TestCanceledExecutionClosesCleanly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fixture.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec("CREATE TABLE t(v TEXT)")
	db.Close()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "r", ExecutionID: "e", Connection: protocol.Connection{Driver: "sqlite", Path: path}, SQL: "SELECT * FROM t"}
	if _, err := Execute(ctx, req, func(protocol.Event) error { return nil }); err == nil {
		t.Fatal("canceled execution succeeded")
	}
}
