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
	c := protocol.Connection{Driver: "mysql", Socket: os.Getenv("QUERYBOOK_MYSQL_SOCKET"), User: os.Getenv("QUERYBOOK_MYSQL_USER"), Password: os.Getenv("QUERYBOOK_MYSQL_PASSWORD"), Database: os.Getenv("QUERYBOOK_MYSQL_DATABASE"), Charset: "utf8mb4"}
	if c.Database == "" {
		t.Skip("set QUERYBOOK_MYSQL_DATABASE to a disposable fixture database")
	}
	req := protocol.Request{Version: 1, Type: "execute", RequestID: "mysql", ExecutionID: "mysql", Connection: c, SQL: "SELECT NULL AS sql_null, 'NULL' AS literal_null, '' AS empty_value, '9223372036854775807' AS exact_bigint"}
	res, err := Execute(context.Background(), req, func(protocol.Event) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Rows) != 1 || len(res.Rows[0]) != 4 || res.Rows[0][0].Kind != "null" || res.Rows[0][1].Text != "NULL" || res.Rows[0][2].Text != "" || res.Rows[0][3].Text != "9223372036854775807" {
		t.Fatalf("fixture values=%#v", res.Rows)
	}
	req.SQL = "SELECT 'sentinel' INTO OUTFILE '/tmp/querybook-forbidden'"
	if _, err = Execute(context.Background(), req, func(protocol.Event) error { return nil }); err == nil {
		t.Fatal("OUTFILE was not denied")
	}
}
