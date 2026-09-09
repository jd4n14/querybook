package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jd4n14/querybook/internal/connections"
	"github.com/jd4n14/querybook/internal/credentials"
	"github.com/jd4n14/querybook/internal/executor"
	"github.com/jd4n14/querybook/internal/protocol"
	"github.com/jd4n14/querybook/internal/results"
)

const runnerVersion = "1.0.0"

type runner struct {
	mu        sync.Mutex
	outMu     sync.Mutex
	active    map[string]context.CancelFunc
	closed    bool
	store     *connections.Store
	storePath string
	results   *results.Registry
}

func (r *runner) send(e protocol.Event) error {
	r.outMu.Lock()
	defer r.outMu.Unlock()
	return protocol.Encode(os.Stdout, e)
}
func (r *runner) err(req protocol.Request, code, msg string) {
	_ = r.send(protocol.Event{Version: 1, Type: "error", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, Code: code, Message: msg, Terminal: true})
}

func (r *runner) metadataStore(path string) (*connections.Store, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.store != nil {
		if path != "" && path != r.storePath {
			return nil, errors.New("metadata_store: store path is immutable for this runner")
		}
		return r.store, nil
	}
	store, err := connections.Open(path, credentials.New(nil))
	if err != nil {
		return nil, err
	}
	r.store, r.storePath = store, store.Path()
	return store, nil
}

func (r *runner) connection(req protocol.Request) {
	store, err := r.metadataStore(req.StorePath)
	if err != nil {
		r.err(req, "metadata_store", "metadata store unavailable")
		return
	}
	var event protocol.Event = protocol.Event{Version: 1, Type: "connection", RequestID: req.RequestID, Op: req.Op, Terminal: true}
	switch req.Op {
	case "list":
		event.Connections, event.ActiveConnectionID, err = store.List()
	case "create":
		var password *string
		if req.Password != nil {
			password = req.Password
		}
		var c protocol.Connection
		c, err = store.Create(req.Connection, password)
		event.Connection = &c
	case "update":
		if req.Connection.ID != "" && req.Connection.ID != req.ConnectionID {
			r.err(req, "invalid_connection", "connection id mismatch")
			return
		}
		req.Connection.ID = req.ConnectionID
		var c protocol.Connection
		c, err = store.Update(req.Connection)
		event.Connection = &c
	case "delete":
		err = store.Delete(req.ConnectionID)
	case "set_password":
		if req.Password == nil {
			r.err(req, "invalid_request", "password is required")
			return
		}
		err = store.SetPassword(req.ConnectionID, *req.Password)
	case "select":
		var c protocol.Connection
		c, event.ActiveConnectionID, err = store.Select(req.ConnectionID)
		event.Connection = &c
	case "test":
		testCtx := context.Background()
		timeout := 10 * time.Second
		if req.TimeoutMS > 0 {
			timeout = time.Duration(req.TimeoutMS) * time.Millisecond
		}
		ctx, cancel := context.WithTimeout(testCtx, timeout)
		err = executor.TestConnection(ctx, store.Resolve, req.ConnectionID)
		cancel()
	}
	if err != nil {
		code, msg := "internal", "connection operation failed"
		if e, ok := err.(*connections.Error); ok {
			code, msg = e.Code, e.Message
		}
		r.err(req, code, msg)
		return
	}
	_ = r.send(event)
}

func (r *runner) execute(req protocol.Request) {
	ctx := context.Background()
	var cancel context.CancelFunc
	if req.TimeoutMS > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(req.TimeoutMS)*time.Millisecond)
	} else {
		ctx, cancel = context.WithCancel(ctx)
	}
	r.mu.Lock()
	r.active[req.ExecutionID] = cancel
	r.mu.Unlock()
	go func() {
		defer func() { r.mu.Lock(); delete(r.active, req.ExecutionID); r.mu.Unlock() }()
		start := time.Now()
		store, storeErr := r.metadataStore(req.StorePath)
		if storeErr != nil {
			r.err(req, "metadata_store", "metadata store unavailable")
			cancel()
			return
		}
		res, err := executor.ExecuteWithResolver(ctx, req, store.Resolve, func(e protocol.Event) error { return r.send(e) })
		if err != nil {
			code, msg := "internal", err.Error()
			if e, ok := err.(*connections.Error); ok {
				code, msg = e.Code, e.Message
			}
			for _, prefix := range []string{"unsafe_statement", "connection", "query", "timeout", "cancelled", "limit"} {
				if code != "internal" {
					break
				}
				if strings.HasPrefix(msg, prefix+":") {
					code = prefix
					msg = strings.TrimSpace(strings.TrimPrefix(msg, prefix+":"))
					break
				}
			}
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				code = "timeout"
			}
			if errors.Is(ctx.Err(), context.Canceled) {
				code = "cancelled"
			}
			if code == "cancelled" {
				_ = r.send(protocol.Event{Version: 1, Type: "cancelled", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, Terminal: true})
			} else {
				r.err(req, code, msg)
			}
			cancel()
			return
		}
		connection := res.Connection
		if req.ConnectionID != "" {
			if stored, getErr := store.Get(req.ConnectionID); getErr == nil {
				// Keep the execution-time snapshot from executor. The store lookup
				// only supplies fields in case a resolver omitted them; it must not
				// retarget this result after a metadata edit.
				if connection.ID == "" {
					connection = stored
				}
			}
		}
		meta := results.Metadata{
			Columns:          res.Columns,
			OriginalSQL:      req.SQL,
			ExecutedSQL:      res.ExecutedSQL,
			AutoLimitApplied: res.AutoLimit,
			AutoLimitReason:  res.AutoLimitWhy,
			ConnectionID:     req.ConnectionID,
			Connection:       connection,
			ExecutedAt:       start,
			ResultSets:       res.ResultSets,
			ObservedRows:     res.Observed,
			RetainedBytes:    res.RetainedBytes,
			Truncated:        res.Truncated,
			TruncationReason: res.Reason,
			AffectedRows:     res.Affected,
		}
		handle, retainErr := r.results.Retain(meta, res.Rows)
		if retainErr != nil {
			r.err(req, "limit", retainErr.Error())
			cancel()
			return
		}
		_ = r.send(protocol.Event{Version: 1, Type: "result_end", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, DurationMS: time.Since(start).Milliseconds(), ResultSets: res.ResultSets, RowCount: int64(len(res.Rows)), ObservedRows: res.Observed, RetainedBytes: res.RetainedBytes, Truncated: res.Truncated, TruncationReason: res.Reason, AutoLimitApplied: res.AutoLimit, AutoLimitReason: res.AutoLimitWhy, AffectedRows: res.Affected, Handle: handle, Connection: &connection, Terminal: true})
		cancel()
	}()
}

func resultProtocolMetadata(meta results.Metadata) *protocol.ResultMetadata {
	columns := make([]protocol.Column, len(meta.Columns))
	copy(columns, meta.Columns)
	connection := meta.Connection
	return &protocol.ResultMetadata{
		Columns: columns, OriginalSQL: meta.OriginalSQL, ExecutedSQL: meta.ExecutedSQL,
		AutoLimitApplied: meta.AutoLimitApplied, AutoLimitReason: meta.AutoLimitReason,
		ConnectionID: meta.ConnectionID, Connection: &connection, ExecutedAt: meta.ExecutedAt.UTC().Format(time.RFC3339Nano),
		ResultSets: meta.ResultSets, ObservedRows: meta.ObservedRows, RetainedBytes: meta.RetainedBytes,
		Truncated: meta.Truncated, TruncationReason: meta.TruncationReason, AffectedRows: meta.AffectedRows,
	}
}

func (r *runner) result(req protocol.Request) {
	var event protocol.Event
	event.Version, event.Type, event.RequestID, event.Op, event.Handle = 1, "result", req.RequestID, req.Op, req.Handle
	switch req.Op {
	case "page", "view":
		var snap results.Snapshot
		var ordinals []int
		var err error
		offset, limit := req.Offset, req.Limit
		if req.PageSize > 0 {
			limit = req.PageSize
			page := req.Page
			if page <= 0 {
				page = 1
			}
			offset = (page - 1) * limit
		}
		if req.ViewID != "" {
			snap, ordinals, err = r.results.PageView(req.Handle, req.ViewID, offset, limit)
			event.ViewID = req.ViewID
		} else if req.Op == "page" {
			snap, ordinals, err = r.results.Page(req.Handle, offset, limit)
		} else {
			snap, ordinals, err = r.results.View(req.Handle, offset, limit)
		}
		if err == nil {
			event.Rows, event.SourceRows, event.SourceIndices, event.TotalRows = snap.Rows, ordinals, ordinals, int64(snap.TotalRows)
			event.Pinned, event.Metadata = snap.Pinned, resultProtocolMetadata(snap.Meta)
		}
		if err != nil {
			r.err(req, "result", err.Error())
			return
		}
	case "filter":
		expression := req.Filter
		if expression == "" {
			expression = req.Expression
		}
		viewID, count, err := r.results.Filter(req.Handle, expression)
		if err != nil {
			r.err(req, "result", err.Error())
			return
		}
		snap, getErr := r.results.Get(req.Handle)
		if getErr != nil {
			r.err(req, "result", getErr.Error())
			return
		}
		indices, _ := r.results.ViewIndices(req.Handle, viewID)
		event.ViewID, event.TotalRows, event.Pinned, event.Metadata, event.MatchingIndices, event.SourceRows, event.SourceIndices, event.Valid = viewID, int64(count), snap.Pinned, resultProtocolMetadata(snap.Meta), indices, indices, indices, true
	case "filter_clear":
		snap, err := r.results.Get(req.Handle)
		if err != nil {
			r.err(req, "result", err.Error())
			return
		}
		indices := make([]int, len(snap.Rows))
		for i := range indices {
			indices[i] = i
		}
		event.TotalRows, event.Pinned, event.Metadata, event.MatchingIndices, event.SourceRows, event.SourceIndices, event.Valid = int64(len(indices)), snap.Pinned, resultProtocolMetadata(snap.Meta), indices, indices, indices, true
	case "cell":
		columnIndex := req.Column
		if req.ColumnName != "" {
			snap, getErr := r.results.Get(req.Handle)
			if getErr != nil {
				r.err(req, "result", getErr.Error())
				return
			}
			var resolveErr error
			columnIndex, resolveErr = snap.ColumnIndex(req.ColumnName)
			if resolveErr != nil {
				r.err(req, "result", resolveErr.Error())
				return
			}
		}
		cell, column, err := r.results.Cell(req.Handle, req.Row, columnIndex)
		if err != nil {
			r.err(req, "result", err.Error())
			return
		}
		event.Cell, event.Column = &cell, &column
	case "compare":
		sourceRow, currentRow := req.SourceRow, req.CurrentRow
		if req.LeftSourceIndex != 0 || req.RightSourceIndex != 0 {
			sourceRow, currentRow = req.LeftSourceIndex, req.RightSourceIndex
		}
		changes, err := r.results.CompareRows(req.Handle, sourceRow, currentRow)
		if err != nil {
			r.err(req, "result", err.Error())
			return
		}
		event.Changes = changes
	case "release":
		if err := r.results.Release(req.Handle); err != nil {
			r.err(req, "result", err.Error())
			return
		}
	case "pin":
		if err := r.results.Pin(req.Handle); err != nil {
			r.err(req, "result", err.Error())
			return
		}
		event.Pinned = true
	case "unpin":
		if err := r.results.Unpin(req.Handle); err != nil {
			r.err(req, "result", err.Error())
			return
		}
	default:
		// Filter and compare are added in the next core unit; accepting their
		// names here would incorrectly report success without doing work.
		r.err(req, "result", "operation not implemented")
		return
	}
	event.Terminal = true
	_ = r.send(event)
}

func main() {
	r := &runner{active: map[string]context.CancelFunc{}, results: results.New(results.Options{})}
	_ = r.send(protocol.Event{Version: 1, Type: "ready", RunnerVersion: runnerVersion})
	d := protocol.NewDecoder(os.Stdin, 2*1024*1024)
	for {
		req, err := d.Next()
		if err == io.EOF {
			r.shutdown()
			return
		}
		if err != nil {
			code := "invalid_request"
			if errors.Is(err, protocol.ErrUnsupportedVersion) {
				code = "unsupported_protocol"
			}
			_ = r.send(protocol.Event{Version: 1, Type: "error", Code: code, Message: err.Error(), Terminal: false})
			continue
		}
		switch req.Type {
		case "execute":
			r.execute(req)
		case "connection":
			r.connection(req)
		case "cancel":
			r.mu.Lock()
			c := r.active[req.ExecutionID]
			r.mu.Unlock()
			if c != nil {
				c()
			}
		case "result":
			r.result(req)
		case "shutdown":
			r.shutdown()
			return
		default:
			_ = r.send(protocol.Event{Version: 1, Type: "error", RequestID: req.RequestID, Code: "invalid_request", Message: fmt.Sprintf("unknown request type %q", req.Type), Terminal: false})
		}
	}
}
func (r *runner) shutdown() {
	r.mu.Lock()
	r.closed = true
	for _, c := range r.active {
		c()
	}
	r.mu.Unlock()
	if r.store != nil {
		_ = r.store.Close()
	}
	time.Sleep(5 * time.Millisecond)
}
