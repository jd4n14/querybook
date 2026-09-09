//go:build integration

package executor

import (
	"context"
	"os"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
)

func TestIsolatedMySQLFixture(t *testing.T) {
	if os.Getenv("QUERYBOOK_MYSQL_TEST") != "1" || os.Getenv("QUERYBOOK_MYSQL_SOCKET") == "" {
		t.Skip("set QUERYBOOK_MYSQL_TEST=1 and QUERYBOOK_MYSQL_SOCKET for isolated MySQL")
	}
	c := protocol.Connection{Driver: "mysql", Socket: os.Getenv("QUERYBOOK_MYSQL_SOCKET"), User: os.Getenv("QUERYBOOK_MYSQL_USER"), Database: os.Getenv("QUERYBOOK_MYSQL_DATABASE"), Charset: "utf8mb4"}
	if c.Database == "" {
		t.Skip("set QUERYBOOK_MYSQL_DATABASE to a disposable fixture database")
	}
	password := []byte(os.Getenv("QUERYBOOK_MYSQL_PASSWORD"))
	resolve := func(string) (protocol.Connection, []byte, error) { return c, password, nil }
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "mysql", ExecutionID: "mysql", ConnectionID: "mysql", SQL: "SELECT NULL AS sql_null, 'NULL' AS literal_null, '' AS empty_value, '9223372036854775807' AS exact_bigint"}
	res, err := ExecuteWithResolver(context.Background(), req, resolve, func(protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != 1 || len(res.Rows[0]) != 4 || res.Rows[0][0].Kind != "null" || res.Rows[0][1].Text != "NULL" || res.Rows[0][2].Text != "" || res.Rows[0][3].Text != "9223372036854775807" {
		t.Fatalf("fixture values=%#v", res.Rows)
	}
	req.SQL = "WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 600) SELECT n FROM nums"
	res, err = ExecuteWithResolver(context.Background(), req, resolve, func(protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if !res.AutoLimit || len(res.Rows) != 500 {
		t.Fatalf("auto limit CTE rows=%d applied=%v", len(res.Rows), res.AutoLimit)
	}
	req.SQL += " LIMIT 3"
	res, err = ExecuteWithResolver(context.Background(), req, resolve, func(protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if res.AutoLimit || len(res.Rows) != 3 {
		t.Fatalf("explicit CTE limit rows=%d applied=%v", len(res.Rows), res.AutoLimit)
	}
	req.SQL = "SELECT 'sentinel' INTO OUTFILE '/tmp/querybook-forbidden'"
	if _, err = Execute(context.Background(), req, func(protocol.Event) error { return nil }); err == nil {
		t.Fatal("OUTFILE was not denied")
	}
}
