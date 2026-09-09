package executor

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jd4n14/querybook/internal/connections"
	"github.com/jd4n14/querybook/internal/policy"
	"github.com/jd4n14/querybook/internal/protocol"
)

// StreamSink receives one schema and one row at a time. Callbacks must not
// retain or mutate a row after returning. A callback error stops this export
// only; it cannot cancel or affect a sibling execution.
type StreamSink struct {
	OnSchema   func(resultSet int, columns []protocol.Column) error
	OnRow      func(resultSet int, row []protocol.Cell) error
	OnProgress func(StreamProgress) error
}

type StreamOptions struct {
	// Zero means unlimited. The database driver may allocate one large value
	// before this guard can inspect it; the stream still never collects rows.
	MaxCellBytes  int64
	MaxRowBytes   int64
	ProgressRows  int64
	ProgressEvery time.Duration
}

type StreamProgress struct {
	Rows    int64
	Bytes   int64
	Elapsed time.Duration
}

type StreamResult struct {
	Rows       int64
	Bytes      int64
	ResultSets int
}

// Stream executes the exact SQL in req.SQL and sends typed positional cells
// directly to sink. It intentionally does not call addAutoLimit: full export
// must use the immutable original SQL captured by the caller. Export is always
// read-only even when req.Force is set.
func Stream(ctx context.Context, req protocol.Request, resolve Resolver, sink StreamSink, opts StreamOptions) (StreamResult, error) {
	if err := ctx.Err(); err != nil {
		return StreamResult{}, err
	}
	if req.SQL == "" {
		return StreamResult{}, errors.New("export: missing sql")
	}
	decision := policy.Classify(req.SQL)
	switch decision.Keyword {
	case "select", "with", "show", "describe", "desc", "explain":
	default:
		return StreamResult{}, errors.New("unsafe_statement: export requires a read query")
	}
	// Never permit Force to weaken the export read-only boundary.
	if !policy.Allow(req.SQL, false).Allowed {
		return StreamResult{}, errors.New("unsafe_statement: export query is not allowed")
	}

	var c protocol.Connection
	var password []byte
	var err error
	if req.ConnectionID != "" {
		if resolve == nil {
			return StreamResult{}, errors.New("connection: connection resolver unavailable")
		}
		c, password, err = resolve(req.ConnectionID)
	} else {
		c = req.Connection
	}
	if err != nil {
		return StreamResult{}, err
	}
	if c.Driver == "sqlite" {
		if err := connections.CheckSQLitePath(c.Path); err != nil {
			return StreamResult{}, err
		}
	}
	dsnv, err := dsnWithPassword(c, password)
	if err != nil {
		return StreamResult{}, err
	}
	db, err := sql.Open(c.Driver, dsnv)
	if err != nil {
		return StreamResult{}, errors.New("connection: connection failed")
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(0)
	defer db.Close()
	conn, err := db.Conn(ctx)
	if err != nil {
		return StreamResult{}, errors.New("connection: connection failed")
	}
	defer conn.Close()
	var rows *sql.Rows
	var tx *sql.Tx
	if c.Driver == "sqlite" {
		if _, err = conn.ExecContext(ctx, "PRAGMA query_only=ON"); err != nil {
			return StreamResult{}, errors.New("connection: read-only boundary unavailable")
		}
	} else {
		tx, err = conn.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
		if err != nil {
			return StreamResult{}, errors.New("connection: read-only boundary unavailable")
		}
		defer tx.Rollback()
	}
	if tx != nil {
		rows, err = tx.QueryContext(ctx, req.SQL)
	} else {
		rows, err = conn.QueryContext(ctx, req.SQL)
	}
	if err != nil {
		return StreamResult{}, queryError(ctx, err, dsnv, string(password))
	}
	defer rows.Close()
	if opts.ProgressRows <= 0 {
		opts.ProgressRows = 500
	}
	if opts.ProgressEvery <= 0 {
		opts.ProgressEvery = 250 * time.Millisecond
	}
	started := time.Now()
	lastProgress := started
	result := StreamResult{}
	for {
		result.ResultSets++
		cols, err := rows.ColumnTypes()
		if err != nil {
			return result, safeError(err, dsnv, string(password))
		}
		meta := make([]protocol.Column, len(cols))
		for i, column := range cols {
			nullable, ok := column.Nullable()
			var np *bool
			if ok {
				v := nullable
				np = &v
			}
			meta[i] = protocol.Column{Name: column.Name(), DatabaseType: column.DatabaseTypeName(), Nullable: np}
		}
		if sink.OnSchema != nil {
			if err := sink.OnSchema(result.ResultSets-1, meta); err != nil {
				return result, err
			}
		}
		for rows.Next() {
			if err := ctx.Err(); err != nil {
				return result, err
			}
			raw := make([]any, len(cols))
			dest := make([]any, len(cols))
			for i := range raw {
				dest[i] = &raw[i]
			}
			if err := rows.Scan(dest...); err != nil {
				return result, queryError(ctx, err, dsnv, string(password))
			}
			row := make([]protocol.Cell, len(cols))
			var rowBytes int64
			for i, value := range raw {
				if opts.MaxCellBytes > 0 && rawSize(value) > opts.MaxCellBytes {
					return result, fmt.Errorf("limit: cell %d exceeds max_cell_bytes", i)
				}
				row[i] = cellFrom(value, meta[i].DatabaseType)
				rowBytes += cellSize(row[i])
			}
			if opts.MaxRowBytes > 0 && rowBytes > opts.MaxRowBytes {
				return result, fmt.Errorf("limit: row exceeds max_row_bytes")
			}
			result.Rows++
			result.Bytes += rowBytes
			if sink.OnRow != nil {
				if err := sink.OnRow(result.ResultSets-1, row); err != nil {
					return result, err
				}
			}
			now := time.Now()
			if sink.OnProgress != nil && (result.Rows%opts.ProgressRows == 0 || now.Sub(lastProgress) >= opts.ProgressEvery) {
				lastProgress = now
				if err := sink.OnProgress(StreamProgress{Rows: result.Rows, Bytes: result.Bytes, Elapsed: now.Sub(started)}); err != nil {
					return result, err
				}
			}
		}
		if err := rows.Err(); err != nil {
			return result, queryError(ctx, err, dsnv, string(password))
		}
		if !rows.NextResultSet() {
			break
		}
	}
	if sink.OnProgress != nil {
		if err := sink.OnProgress(StreamProgress{Rows: result.Rows, Bytes: result.Bytes, Elapsed: time.Since(started)}); err != nil {
			return result, err
		}
	}
	return result, nil
}

func rawSize(value any) int64 {
	switch x := value.(type) {
	case []byte:
		return int64(len(x))
	case string:
		return int64(len(x))
	default:
		return 0
	}
}

func cellSize(cell protocol.Cell) int64 {
	if strings.EqualFold(cell.Kind, "binary") {
		return int64(len(cell.Base64))
	}
	return int64(len(cell.Text))
}
