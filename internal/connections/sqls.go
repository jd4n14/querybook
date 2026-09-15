package connections

import "github.com/jd4n14/querybook/internal/protocol"

// SQLSConfig maps a Querybook connection to sqls' in-memory DBConfig.
// SQLite uses dataSourceName as the file path (sqls' sqlite3 driver). MySQL
// uses discrete fields so passwords are never stuffed into a DSN.
func SQLSConfig(c protocol.Connection, password []byte) (protocol.SQLSConfig, error) {
	switch c.Driver {
	case "sqlite":
		return protocol.SQLSConfig{Connections: []protocol.SQLSConnection{{
			Alias:          c.Name,
			Driver:         "sqlite3",
			DataSourceName: c.Path,
		}}}, nil
	case "mysql":
		conn := protocol.SQLSConnection{
			Alias:  c.Name,
			Driver: "mysql",
			User:   c.User,
			Passwd: string(password),
			DBName: c.Database,
			Params: map[string]string{"charset": c.Charset},
		}
		if conn.User == "" {
			conn.User = "root"
		}
		if conn.Params["charset"] == "" {
			conn.Params["charset"] = "utf8mb4"
		}
		if c.Socket != "" {
			conn.Proto = "unix"
			conn.Path = c.Socket
		} else {
			conn.Proto = "tcp"
			conn.Host = c.Host
			if conn.Host == "" {
				conn.Host = "127.0.0.1"
			}
			if c.Port > 0 {
				conn.Port = c.Port
			}
		}
		return protocol.SQLSConfig{Connections: []protocol.SQLSConnection{conn}}, nil
	default:
		return protocol.SQLSConfig{}, errf("invalid_connection", "unsupported driver")
	}
}
