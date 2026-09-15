package connections

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
)

func marshalSQLSConn(t *testing.T, cfg protocol.SQLSConfig) map[string]any {
	t.Helper()
	if len(cfg.Connections) != 1 {
		t.Fatalf("connections=%d", len(cfg.Connections))
	}
	b, err := json.Marshal(cfg.Connections[0])
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestSQLSConfigSQLiteUsesSqlite3DataSourceName(t *testing.T) {
	cfg, err := SQLSConfig(protocol.Connection{Name: "local", Driver: "sqlite", Path: "/tmp/app.db"}, []byte("ignored"))
	if err != nil {
		t.Fatal(err)
	}
	m := marshalSQLSConn(t, cfg)
	if m["driver"] != "sqlite3" || m["alias"] != "local" || m["dataSourceName"] != "/tmp/app.db" {
		t.Fatalf("sqlite mapping=%v", m)
	}
	if _, ok := m["passwd"]; ok {
		t.Fatalf("sqlite passwd present: %v", m)
	}
	if _, ok := m["proto"]; ok {
		t.Fatalf("sqlite proto present: %v", m)
	}
}

func TestSQLSConfigMySQLTCPDiscreteFieldsAndDefaults(t *testing.T) {
	cfg, err := SQLSConfig(protocol.Connection{Name: "app", Driver: "mysql"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	m := marshalSQLSConn(t, cfg)
	if m["driver"] != "mysql" || m["alias"] != "app" || m["proto"] != "tcp" {
		t.Fatalf("mysql defaults=%v", m)
	}
	if m["user"] != "root" || m["host"] != "127.0.0.1" {
		t.Fatalf("mysql user/host defaults=%v", m)
	}
	if _, ok := m["port"]; ok {
		t.Fatalf("port 0 should be omitted: %v", m)
	}
	if _, ok := m["dataSourceName"]; ok {
		t.Fatalf("mysql dsn present: %v", m)
	}
	params, _ := m["params"].(map[string]any)
	if params["charset"] != "utf8mb4" {
		t.Fatalf("charset=%v", m["params"])
	}

	cfg, err = SQLSConfig(protocol.Connection{
		Name: "app", Driver: "mysql", User: "u", Host: "db.internal", Port: 3307, Database: "shop", Charset: "utf8",
	}, []byte("secret"))
	if err != nil {
		t.Fatal(err)
	}
	m = marshalSQLSConn(t, cfg)
	if m["user"] != "u" || m["host"] != "db.internal" || m["port"] != float64(3307) || m["dbName"] != "shop" {
		t.Fatalf("mysql explicit=%v", m)
	}
	if m["passwd"] != "secret" {
		t.Fatalf("passwd=%v", m["passwd"])
	}
	params, _ = m["params"].(map[string]any)
	if params["charset"] != "utf8" {
		t.Fatalf("charset=%v", m["params"])
	}
}

func TestSQLSConfigMySQLUnixSocket(t *testing.T) {
	cfg, err := SQLSConfig(protocol.Connection{
		Name: "sock", Driver: "mysql", User: "u", Socket: "/tmp/mysql.sock", Database: "app",
	}, []byte("pw"))
	if err != nil {
		t.Fatal(err)
	}
	m := marshalSQLSConn(t, cfg)
	if m["proto"] != "unix" || m["path"] != "/tmp/mysql.sock" {
		t.Fatalf("unix mapping=%v", m)
	}
	if _, ok := m["dataSourceName"]; ok {
		t.Fatalf("unix dsn present: %v", m)
	}
	if _, ok := m["host"]; ok {
		t.Fatalf("unix host present: %v", m)
	}
	if _, ok := m["port"]; ok {
		t.Fatalf("unix port present: %v", m)
	}
}

func TestSQLSConfigMySQLPasswordStaysOutOfDSN(t *testing.T) {
	password := []byte("p@ss/w:ord")
	cfg, err := SQLSConfig(protocol.Connection{Name: "db", Driver: "mysql", User: "u"}, password)
	if err != nil {
		t.Fatal(err)
	}
	m := marshalSQLSConn(t, cfg)
	if m["passwd"] != "p@ss/w:ord" {
		t.Fatalf("passwd=%v", m["passwd"])
	}
	if _, ok := m["dataSourceName"]; ok {
		t.Fatal("password stuffed into dataSourceName")
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(b); !strings.Contains(got, `"passwd":"p@ss/w:ord"`) || strings.Contains(got, "dataSourceName") {
		t.Fatalf("json=%s", b)
	}
}

func TestSQLSConfigUnknownDriverErrors(t *testing.T) {
	if _, err := SQLSConfig(protocol.Connection{Name: "x", Driver: "postgres"}, nil); err == nil {
		t.Fatal("expected unsupported driver error")
	}
}
