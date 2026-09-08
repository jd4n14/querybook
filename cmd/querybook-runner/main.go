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

	"github.com/jd4n14/querybook/internal/executor"
	"github.com/jd4n14/querybook/internal/protocol"
)

const runnerVersion = "1.0.0"

type runner struct {
	mu     sync.Mutex
	outMu  sync.Mutex
	active map[string]context.CancelFunc
	closed bool
}

func (r *runner) send(e protocol.Event) error {
	r.outMu.Lock()
	defer r.outMu.Unlock()
	return protocol.Encode(os.Stdout, e)
}
func (r *runner) err(req protocol.Request, code, msg string) {
	_ = r.send(protocol.Event{Version: 1, Type: "error", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, Code: code, Message: msg, Terminal: true})
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
		res, err := executor.Execute(ctx, req, func(e protocol.Event) error { return r.send(e) })
		if err != nil {
			code, msg := "internal", err.Error()
			for _, prefix := range []string{"unsafe_statement", "connection", "query", "timeout", "cancelled", "limit"} {
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
		_ = r.send(protocol.Event{Version: 1, Type: "result_end", RequestID: req.RequestID, ExecutionID: req.ExecutionID, Generation: req.Generation, DurationMS: time.Since(start).Milliseconds(), ResultSets: res.ResultSets, RowCount: int64(len(res.Rows)), ObservedRows: res.Observed, RetainedBytes: res.RetainedBytes, Truncated: res.Truncated, TruncationReason: res.Reason, AffectedRows: res.Affected, Terminal: true})
		cancel()
	}()
}

func main() {
	r := &runner{active: map[string]context.CancelFunc{}}
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
		case "cancel":
			r.mu.Lock()
			c := r.active[req.ExecutionID]
			r.mu.Unlock()
			if c != nil {
				c()
			}
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
	time.Sleep(5 * time.Millisecond)
}
