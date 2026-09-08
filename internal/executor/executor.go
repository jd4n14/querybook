package executor

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	_ "github.com/go-sql-driver/mysql"
	"github.com/jd4n14/querybook/internal/policy"
	"github.com/jd4n14/querybook/internal/protocol"
	_ "modernc.org/sqlite"
)

const (
	DefaultRows             = 10000
	DefaultBytes      int64 = 16 * 1024 * 1024
	DefaultBatchRows        = 200
	DefaultBatchBytes int64 = 512 * 1024
)

type Limits struct {
	Rows       int
	Bytes      int64
	BatchRows  int
	BatchBytes int64
}

func limits(r protocol.Request) Limits {
	l := Limits{Rows: DefaultRows, Bytes: DefaultBytes, BatchRows: DefaultBatchRows, BatchBytes: DefaultBatchBytes}
	if r.MaxRetainedRows > 0 {
		l.Rows = r.MaxRetainedRows
	}
	if r.MaxRetainedBytes > 0 {
		l.Bytes = r.MaxRetainedBytes
	}
	if r.BatchRows > 0 {
		l.BatchRows = r.BatchRows
	}
	if r.BatchBytes > 0 {
		l.BatchBytes = r.BatchBytes
	}
	return l
}

type Result struct {
	Columns       []protocol.Column
	Rows          [][]protocol.Cell
	Observed      int64
	RetainedBytes int64
	Truncated     bool
	Reason        string
	Affected      int64
	ResultSets    int
}

func dsn(c protocol.Connection) (string, error) {
	switch c.Driver {
	case "sqlite":
		if c.Path == "" {
			return "", errors.New("missing SQLite path")
		}
		return c.Path, nil
	case "mysql":
		user := c.User
		if user == "" {
			user = "root"
		}
		host := c.Host
		if host == "" {
			host = "127.0.0.1"
		}
		addr := host
		if c.Socket != "" {
			addr = "unix(" + c.Socket + ")"
		} else if c.Port > 0 {
			addr = host + ":" + strconv.Itoa(c.Port)
		}
		charset := c.Charset
		if charset == "" {
			charset = "utf8mb4"
		}
		if c.Socket != "" {
			return user + ":" + c.Password + "@unix(" + c.Socket + ")/" + c.Database + "?charset=" + charset + "&parseTime=false", nil
		}
		return user + ":" + c.Password + "@tcp(" + addr + ")/" + c.Database + "?charset=" + charset + "&parseTime=false", nil
	default:
		return "", errors.New("unsupported driver")
	}
}

func cellFrom(v any, typ string) protocol.Cell {
	if v == nil {
		return protocol.NullCell()
	}
	switch x := v.(type) {
	case []byte:
		// MySQL exposes values as bytes. Binary column names/types and invalid
		// UTF-8 are retained as reversible base64; all valid text remains text.
		if isBinaryType(typ) || strings.IndexByte(string(x), 0) >= 0 || !utf8Valid(x) {
			return protocol.BinaryCell(x)
		}
		return protocol.TextCell(string(x))
	case string:
		return protocol.TextCell(x)
	case int64:
		return protocol.TextCell(strconv.FormatInt(x, 10))
	case uint64:
		return protocol.TextCell(strconv.FormatUint(x, 10))
	case int:
		return protocol.TextCell(strconv.Itoa(x))
	case float64:
		return protocol.TextCell(strconv.FormatFloat(x, 'g', -1, 64))
	case bool:
		if x {
			return protocol.TextCell("1")
		}
		return protocol.TextCell("0")
	default:
		return protocol.TextCell(fmt.Sprint(x))
	}
}

func utf8Valid(v []byte) bool { return utf8.Valid(v) }
func isBinaryType(t string) bool {
	t = strings.ToLower(t)
	for _, x := range []string{"blob", "binary", "varbinary", "longblob", "mediumblob", "tinyblob"} {
		if strings.Contains(t, x) {
			return true
		}
	}
	return false
}

type emitter func(protocol.Event) error

func Execute(ctx context.Context, req protocol.Request, emit emitter) (Result, error) {
	d := policy.Allow(req.SQL, req.Force)
	if !d.Allowed {
		return Result{}, fmt.Errorf("unsafe_statement: %s", d.Reason)
	}
	dsnv, err := dsn(req.Connection)
	if err != nil {
		return Result{}, err
	}
	driver := req.Connection.Driver
	db, err := sql.Open(driver, dsnv)
	if err != nil {
		return Result{}, safeError(err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(0)
	defer db.Close()
	conn, err := db.Conn(ctx)
	if err != nil {
		return Result{}, safeError(err)
	}
	defer conn.Close()
	var rows *sql.Rows
	var tx *sql.Tx
	if !req.Force {
		if driver == "sqlite" {
			if _, err = conn.ExecContext(ctx, "PRAGMA query_only=ON"); err != nil {
				return Result{}, fmt.Errorf("read-only boundary: %w", safeError(err))
			}
		} else {
			tx, err = conn.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
			if err != nil {
				return Result{}, fmt.Errorf("read-only boundary: %w", safeError(err))
			}
			defer tx.Rollback()
		}
	}
	decision := policy.Classify(req.SQL)
	if req.Force && decision.Keyword != "select" && decision.Keyword != "show" && decision.Keyword != "describe" && decision.Keyword != "desc" && decision.Keyword != "explain" {
		var result sql.Result
		if tx != nil {
			result, err = tx.ExecContext(ctx, req.SQL)
		} else {
			result, err = conn.ExecContext(ctx, req.SQL)
		}
		if err != nil {
			return Result{}, queryError(ctx, err)
		}
		affected, _ := result.RowsAffected()
		if err := emit(protocol.Event{Version: 1, Type: "result_start", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, ResultSet: 0, Columns: []protocol.Column{}}); err != nil {
			return Result{}, err
		}
		return Result{ResultSets: 1, Affected: affected}, nil
	}
	if tx != nil {
		rows, err = tx.QueryContext(ctx, req.SQL)
	} else {
		rows, err = conn.QueryContext(ctx, req.SQL)
	}
	if err != nil {
		return Result{}, queryError(ctx, err)
	}
	defer rows.Close()
	l := limits(req)
	out := Result{}
	for {
		out.ResultSets++
		cols, err := rows.ColumnTypes()
		if err != nil {
			return out, safeError(err)
		}
		meta := make([]protocol.Column, len(cols))
		for i, c := range cols {
			nullable, ok := c.Nullable()
			var np *bool
			if ok {
				nullableCopy := nullable
				np = &nullableCopy
			}
			meta[i] = protocol.Column{Name: c.Name(), DatabaseType: c.DatabaseTypeName(), Nullable: np}
		}
		out.Columns = meta
		if err := emit(protocol.Event{Version: 1, Type: "result_start", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, ResultSet: out.ResultSets - 1, Columns: meta}); err != nil {
			return out, err
		}
		batch := make([][]protocol.Cell, 0, l.BatchRows)
		var batchBytes int64
		for rows.Next() {
			out.Observed++
			raw := make([]any, len(cols))
			dest := make([]any, len(cols))
			for i := range raw {
				dest[i] = &raw[i]
			}
			if err := rows.Scan(dest...); err != nil {
				return out, safeError(err)
			}
			row := make([]protocol.Cell, len(cols))
			var rowBytes int64 = 16
			for i, v := range raw {
				row[i] = cellFrom(v, meta[i].DatabaseType)
				if row[i].Kind == "binary" {
					rowBytes += int64(len(row[i].Base64)) + 16
				} else {
					rowBytes += int64(len(row[i].Text)) + 16
				}
			}
			if int64(len(out.Rows)) >= int64(l.Rows) || out.RetainedBytes+rowBytes > l.Bytes {
				out.Truncated = true
				if out.Reason == "" {
					out.Reason = "retention_limit"
				}
				break
			}
			if rowBytes > l.BatchBytes {
				return out, fmt.Errorf("limit: row exceeds batch_bytes")
			}
			if len(batch) > 0 && batchBytes+rowBytes > l.BatchBytes {
				if err := emit(protocol.Event{Version: 1, Type: "rows", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, ResultSet: out.ResultSets - 1, Rows: batch}); err != nil {
					return out, err
				}
				batch = nil
				batchBytes = 0
			}
			out.Rows = append(out.Rows, row)
			out.RetainedBytes += rowBytes
			batch = append(batch, row)
			batchBytes += rowBytes
			if len(batch) >= l.BatchRows || batchBytes >= l.BatchBytes {
				if err := emit(protocol.Event{Version: 1, Type: "rows", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, ResultSet: out.ResultSets - 1, Rows: batch}); err != nil {
					return out, err
				}
				batch = nil
				batchBytes = 0
			}
		}
		if err := rows.Err(); err != nil {
			return out, queryError(ctx, err)
		}
		if len(batch) > 0 {
			if err := emit(protocol.Event{Version: 1, Type: "rows", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, ResultSet: out.ResultSets - 1, Rows: batch}); err != nil {
				return out, err
			}
		}
		if out.Truncated {
			break
		}
		if !rows.NextResultSet() {
			break
		}
	}
	if tx != nil {
		out.Affected = -1
		_ = tx.Rollback()
	}
	return out, nil
}

func queryError(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("timeout: %w", ctx.Err())
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		return fmt.Errorf("cancelled: %w", ctx.Err())
	}
	return fmt.Errorf("query: %w", safeError(err))
}
func safeError(err error) error {
	if err == nil {
		return nil
	}
	s := err.Error()
	s = strings.ReplaceAll(strings.ReplaceAll(s, "password", "credential"), "Password", "credential")
	return errors.New(s)
}
