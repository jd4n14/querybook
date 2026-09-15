package executor

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
	"github.com/jd4n14/querybook/internal/results"
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

func TestSQLiteExpressionRuntimeKindsDriveExactFilters(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runtime-kinds.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE seed (n INTEGER)"); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	queries := []struct {
		name string
		sql  string
		want string
	}{
		{"expression", "SELECT 12 + 1 AS n", "integer"},
		{"cte", "WITH x AS (SELECT 12 AS n) SELECT n FROM x", "integer"},
		{"text", "SELECT '001' AS n UNION ALL SELECT '11' AS n", "string"},
	}
	for _, tc := range queries {
		t.Run(tc.name, func(t *testing.T) {
			req := protocol.Request{Version: 1, Type: "execute", RequestID: tc.name, ExecutionID: tc.name, Connection: protocol.Connection{Driver: "sqlite", Path: path}, SQL: tc.sql}
			got, err := Execute(context.Background(), req, func(protocol.Event) error { return nil })
			if err != nil {
				t.Fatal(err)
			}
			if len(got.Rows) == 0 || len(got.Rows[0]) != 1 {
				t.Fatalf("rows=%#v", got.Rows)
			}
			if got.Rows[0][0].ValueKind != tc.want {
				t.Fatalf("value kind=%q want %q cell=%#v", got.Rows[0][0].ValueKind, tc.want, got.Rows[0][0])
			}
			if got.Columns[0].DatabaseType != "" {
				t.Fatalf("expression invented database type %q", got.Columns[0].DatabaseType)
			}
			r := results.New(results.Options{MaxBytes: 1 << 20, MaxSets: 1})
			id, err := r.Retain(results.Metadata{Columns: got.Columns}, got.Rows)
			if err != nil {
				t.Fatal(err)
			}
			if tc.want == "integer" {
				view, count, err := r.Filter(id, "n >= 11")
				if err != nil || count != 1 || view == "" {
					t.Fatalf("numeric filter view=%q count=%d err=%v", view, count, err)
				}
			} else {
				if _, count, err := r.Filter(id, "n >= 11"); err != nil || count != 0 {
					t.Fatalf("text accepted numeric predicate count=%d err=%v", count, err)
				}
				if _, count, err := r.Filter(id, `n == "001"`); err != nil || count != 1 {
					t.Fatalf("text equality count=%d err=%v", count, err)
				}
			}
		})
	}
}

func TestCellFromUsesDriverRuntimeKindWithoutInventingBooleans(t *testing.T) {
	if got := cellFrom(int64(1), "TINYINT(1)"); got.ValueKind != "integer" || got.Text != "1" {
		t.Fatalf("MySQL integer runtime kind=%#v", got)
	}
	if got := cellFrom("001", "INTEGER"); got.ValueKind != "string" || got.Text != "001" {
		t.Fatalf("text runtime kind=%#v", got)
	}
	if got := cellFrom(true, "BOOLEAN"); got.ValueKind != "boolean" || got.Text != "1" {
		t.Fatalf("boolean runtime kind=%#v", got)
	}
	if got := cellFrom([]byte{0, 1}, "BIT"); got.Kind != "binary" || got.ValueKind != "binary" {
		t.Fatalf("binary runtime kind=%#v", got)
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
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
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

func TestSQLiteConnectionTestDoesNotCreateMissingDatabase(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "missing.sqlite3")
	err := TestConnection(context.Background(), func(string) (protocol.Connection, []byte, error) {
		return protocol.Connection{Name: "missing", Driver: "sqlite", Path: path}, nil, nil
	}, "missing")
	if err == nil || !strings.HasPrefix(err.Error(), "sqlite_database_missing:") {
		t.Fatalf("missing database error=%v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("connection test created %s: %v", path, statErr)
	}
}

func TestSQLiteReadDoesNotCreateMissingDatabase(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "missing.sqlite3")
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "r", ExecutionID: "e", Connection: protocol.Connection{Driver: "sqlite", Path: path}, SQL: "SELECT 1"}
	if _, err := Execute(context.Background(), req, func(protocol.Event) error { return nil }); err == nil || !strings.HasPrefix(err.Error(), "sqlite_database_missing:") {
		t.Fatalf("missing database error=%v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("read created %s: %v", path, statErr)
	}
}

func TestMySQLDSNUsesDriverAddressSyntax(t *testing.T) {
	d, err := dsnWithPassword(protocol.Connection{Driver: "mysql", Host: "127.0.0.1", Port: 3307, User: "u", Database: "db"}, []byte("p"))
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

func TestSafeErrorRedactsDSNAndCredentialSentinel(t *testing.T) {
	secret := "querybook-secret-sentinel"
	dsn := "u:" + secret + "@tcp(db:3306)/app"
	err := safeError(errors.New("driver echoed "+dsn+" in query="+secret), dsn, secret)
	if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), dsn) {
		t.Fatalf("secret leaked: %q", err)
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

func TestAutoLimitIsTopLevelAndQuoteCommentAware(t *testing.T) {
	tests := []struct {
		name    string
		sql     string
		want    string
		applied bool
	}{
		{"plain", "SELECT * FROM t", "SELECT * FROM t LIMIT 500", true},
		{"semicolon", "SELECT * FROM t;", "SELECT * FROM t LIMIT 500;", true},
		{"trailing comment", "SELECT * FROM t -- LIMIT 3\n", "SELECT * FROM t LIMIT 500 -- LIMIT 3\n", true},
		{"quoted limit", "SELECT 'LIMIT 3' AS text", "SELECT 'LIMIT 3' AS text LIMIT 500", true},
		{"subquery limit", "SELECT * FROM (SELECT * FROM t LIMIT 3) AS x", "SELECT * FROM (SELECT * FROM t LIMIT 3) AS x LIMIT 500", true},
		{"cte outer limit", "WITH x AS (SELECT * FROM t LIMIT 3) SELECT * FROM x", "WITH x AS (SELECT * FROM t LIMIT 3) SELECT * FROM x LIMIT 500", true},
		{"cte dml unchanged", "WITH x AS (SELECT 1) DELETE FROM t", "WITH x AS (SELECT 1) DELETE FROM t", false},
		{"union", "SELECT 1 UNION SELECT 2", "SELECT 1 UNION SELECT 2 LIMIT 500", true},
		{"mysql double dash operator", "SELECT 1--2", "SELECT 1--2 LIMIT 500", true},
		{"parenthesized expression", "SELECT (1)", "SELECT (1) LIMIT 500", true},
		{"reserved column offset", "SELECT offset FROM t", "SELECT offset FROM t LIMIT 500", true},
		{"reserved column lock", "SELECT lock FROM t", "SELECT lock FROM t LIMIT 500", true},
		{"reserved column fetch", "SELECT fetch AS x FROM t", "SELECT fetch AS x FROM t LIMIT 500", true},
		{"reserved column limit", "SELECT limit FROM t", "SELECT limit FROM t LIMIT 500", true},
		{"explicit outer limit", "WITH x AS (SELECT * FROM t LIMIT 3) SELECT * FROM x LIMIT 9", "WITH x AS (SELECT * FROM t LIMIT 3) SELECT * FROM x LIMIT 9", false},
		{"fetch unchanged", "SELECT * FROM t FETCH FIRST 3 ROWS ONLY", "SELECT * FROM t FETCH FIRST 3 ROWS ONLY", false},
		{"into unchanged", "SELECT * FROM t INTO OUTFILE '/tmp/x'", "SELECT * FROM t INTO OUTFILE '/tmp/x'", false},
		{"show unchanged", "SHOW TABLES", "SHOW TABLES", false},
		{"malformed unchanged", "SELECT 'unterminated", "SELECT 'unterminated", false},
	}
	for _, tt := range tests {
		got, applied := addAutoLimit(tt.sql)
		if got != tt.want || applied != tt.applied {
			t.Errorf("%s: got %q/%v, want %q/%v", tt.name, got, applied, tt.want, tt.applied)
		}
	}
}

func TestAutoLimitExecutionBoundsOnlyUnqualifiedSelects(t *testing.T) {
	path := filepath.Join(t.TempDir(), "many.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("CREATE TABLE t (v INTEGER)"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 600; i++ {
		if _, err = db.Exec("INSERT INTO t(v) VALUES (?)", i); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()
	base := protocol.Request{Version: 1, Type: "execute", RequestID: "r", ExecutionID: "e", Connection: protocol.Connection{Driver: "sqlite", Path: path}, SQL: "SELECT v FROM t ORDER BY v"}
	got, err := Execute(context.Background(), base, func(protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if !got.AutoLimit || len(got.Rows) != 500 {
		t.Fatalf("auto limit result=%#v", got)
	}
	explicit := base
	explicit.SQL = "SELECT v FROM t ORDER BY v LIMIT 3"
	got, err = Execute(context.Background(), explicit, func(protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if got.AutoLimit || len(got.Rows) != 3 {
		t.Fatalf("explicit limit result=%#v", got)
	}
}
