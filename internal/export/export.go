// Package export writes retained or streamed Querybook result rows to files.
//
// It deliberately consumes positional protocol cells. Column names are labels
// only, so duplicate labels remain ordered and lossless. Files are published
// with a no-clobber link after the encoder has closed and synced its private
// temporary file.
package export

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/jd4n14/querybook/internal/protocol"
)

type Format string

const (
	CSV   Format = "csv"
	JSONL Format = "jsonl"
)

var (
	ErrUnsupportedFormat = errors.New("export: unsupported format")
	ErrDestinationExists = errors.New("export: destination already exists")
)

// Progress is safe to expose to the UI: it contains counters and timing only,
// never a cell or a row value.
type Progress struct {
	Rows         int64
	BytesWritten int64
	Elapsed      time.Duration
}

type ProgressFunc func(Progress) error

// Options controls encoding and publication. Overwrite is intentionally not
// supported in v1; callers must select a new path when the destination exists.
type Options struct {
	Format        Format
	Progress      ProgressFunc
	ProgressRows  int64
	ProgressEvery time.Duration
}

type Stats struct {
	Rows         int64
	BytesWritten int64
	Elapsed      time.Duration
}

// StreamCallbacks is the small bridge used by executor.Stream. The runner
// invokes Schema once before rows and Row once per positional row. The
// callbacks are intentionally push based so a full export never materializes
// the result in this package.
type StreamCallbacks struct {
	Schema func([]protocol.Column) error
	Row    func(context.Context, []protocol.Cell) error
}

// RowSource supplies one positional row at a time. io.EOF means the stream is
// complete. Implementations must return a row owned by the source; the
// encoder does not retain it after WriteRow returns.
type RowSource interface {
	Next() ([]protocol.Cell, error)
}

type SliceSource struct {
	Rows  [][]protocol.Cell
	index int
}

func (s *SliceSource) Next() ([]protocol.Cell, error) {
	if s.index >= len(s.Rows) {
		return nil, io.EOF
	}
	row := s.Rows[s.index]
	s.index++
	return row, nil
}

// ExportCurrent writes retained rows supplied by the caller. It iterates the
// existing slice directly and never makes a second copy of the result.
func ExportCurrent(ctx context.Context, path string, columns []protocol.Column, rows [][]protocol.Cell, opts Options) (Stats, error) {
	return ExportRows(ctx, path, columns, &SliceSource{Rows: rows}, opts)
}

func ExportRows(ctx context.Context, path string, columns []protocol.Column, source RowSource, opts Options) (Stats, error) {
	if source == nil {
		return Stats{}, errors.New("export: nil row source")
	}
	if err := ctx.Err(); err != nil {
		return Stats{}, err
	}
	file, err := beginFile(path)
	if err != nil {
		return Stats{}, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = file.Close()
			_ = os.Remove(file.Name())
		}
	}()

	encoder, err := NewEncoder(file, columns, opts)
	if err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		return Stats{}, err
	}
	for {
		if err := ctx.Err(); err != nil {
			_, _ = encoder.Close()
			return Stats{}, err
		}
		row, nextErr := source.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			_, _ = encoder.Close()
			return Stats{}, nextErr
		}
		if err := encoder.WriteRow(ctx, row); err != nil {
			_, _ = encoder.Close()
			return Stats{}, err
		}
	}
	stats, err := encoder.Close()
	if err != nil {
		return Stats{}, err
	}
	if err := ctx.Err(); err != nil {
		return Stats{}, err
	}
	if err := file.Sync(); err != nil {
		return Stats{}, fmt.Errorf("export: sync temporary file: %w", err)
	}
	if err := file.Close(); err != nil {
		return Stats{}, fmt.Errorf("export: close temporary file: %w", err)
	}
	if err := publishNoClobber(file.Name(), path); err != nil {
		return Stats{}, err
	}
	committed = true
	return stats, nil
}

// ExportStream wraps a push-based database stream in the same private-file and
// atomic publication rules as ExportRows. The runner callback must return only
// after its database rows are exhausted or the context is cancelled.
func ExportStream(ctx context.Context, path string, opts Options, run func(StreamCallbacks) error) (Stats, error) {
	if run == nil {
		return Stats{}, errors.New("export: nil stream runner")
	}
	if err := ctx.Err(); err != nil {
		return Stats{}, err
	}
	file, err := beginFile(path)
	if err != nil {
		return Stats{}, err
	}
	committed := false
	defer func() {
		if !committed {
			_ = file.Close()
			_ = os.Remove(file.Name())
		}
	}()
	var encoder *Encoder
	callbacks := StreamCallbacks{
		Schema: func(columns []protocol.Column) error {
			if encoder != nil {
				return errors.New("export: multiple result sets are not supported in one file")
			}
			encoder, err = NewEncoder(file, columns, opts)
			return err
		},
		Row: func(rowCtx context.Context, row []protocol.Cell) error {
			if encoder == nil {
				return errors.New("export: stream row received before schema")
			}
			return encoder.WriteRow(rowCtx, row)
		},
	}
	if err := run(callbacks); err != nil {
		if encoder != nil {
			_, _ = encoder.Close()
		}
		return Stats{}, err
	}
	if err := ctx.Err(); err != nil {
		return Stats{}, err
	}
	if encoder == nil {
		return Stats{}, errors.New("export: stream did not provide schema")
	}
	stats, err := encoder.Close()
	if err != nil {
		return Stats{}, err
	}
	if err := file.Sync(); err != nil {
		return Stats{}, fmt.Errorf("export: sync temporary file: %w", err)
	}
	if err := file.Close(); err != nil {
		return Stats{}, fmt.Errorf("export: close temporary file: %w", err)
	}
	if err := publishNoClobber(file.Name(), path); err != nil {
		return Stats{}, err
	}
	committed = true
	return stats, nil
}

// Encoder writes a result stream to an already-created private file or other
// writer. NewEncoder emits a CSV header immediately; JSONL emits a schema line
// only when no rows arrive, so a zero-row result still carries its schema.
type Encoder struct {
	columns []protocol.Column
	opts    Options
	start   time.Time
	rows    int64
	last    time.Time
	bytes   *countingWriter
	csv     *csv.Writer
	json    *json.Encoder
	closed  bool
	mu      sync.Mutex
}

func NewEncoder(w io.Writer, columns []protocol.Column, opts Options) (*Encoder, error) {
	if opts.Format == "" {
		opts.Format = CSV
	}
	if opts.Format != CSV && opts.Format != JSONL {
		return nil, ErrUnsupportedFormat
	}
	if opts.ProgressRows <= 0 {
		opts.ProgressRows = 500
	}
	if opts.ProgressEvery <= 0 {
		opts.ProgressEvery = 250 * time.Millisecond
	}
	cw := &countingWriter{w: w}
	e := &Encoder{columns: columns, opts: opts, start: time.Now(), last: time.Now(), bytes: cw}
	switch opts.Format {
	case CSV:
		e.csv = csv.NewWriter(cw)
		header := make([]string, len(columns))
		for i, column := range columns {
			header[i] = column.Name
		}
		e.csv.Write(header)
		e.csv.Flush()
		if err := e.csv.Error(); err != nil {
			return nil, err
		}
	case JSONL:
		e.json = json.NewEncoder(cw)
	}
	return e, nil
}

func (e *Encoder) WriteRow(ctx context.Context, row []protocol.Cell) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return errors.New("export: encoder is closed")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(row) != len(e.columns) {
		return fmt.Errorf("export: row has %d cells, schema has %d columns", len(row), len(e.columns))
	}
	switch e.opts.Format {
	case CSV:
		values := make([]string, len(row))
		for i, cell := range row {
			values[i] = csvValue(cell)
		}
		e.csv.Write(values)
		e.csv.Flush()
		if err := e.csv.Error(); err != nil {
			return err
		}
	case JSONL:
		if err := e.json.Encode(jsonRecord{Columns: e.columns, Cells: row}); err != nil {
			return err
		}
	}
	e.rows++
	return e.maybeProgress(false)
}

func (e *Encoder) maybeProgress(final bool) error {
	if e.opts.Progress == nil {
		return nil
	}
	now := time.Now()
	if !final && e.rows%e.opts.ProgressRows != 0 && now.Sub(e.last) < e.opts.ProgressEvery {
		return nil
	}
	e.last = now
	return e.opts.Progress(Progress{Rows: e.rows, BytesWritten: e.bytes.n, Elapsed: now.Sub(e.start)})
}

func (e *Encoder) Close() (Stats, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return Stats{}, errors.New("export: encoder is closed")
	}
	e.closed = true
	if e.opts.Format == CSV {
		e.csv.Flush()
		if err := e.csv.Error(); err != nil {
			return Stats{}, err
		}
	}
	if e.opts.Format == JSONL && e.rows == 0 {
		if err := e.json.Encode(jsonRecord{Columns: e.columns, Cells: nil, Schema: true}); err != nil {
			return Stats{}, err
		}
	}
	if err := e.maybeProgress(true); err != nil {
		return Stats{}, err
	}
	now := time.Now()
	return Stats{Rows: e.rows, BytesWritten: e.bytes.n, Elapsed: now.Sub(e.start)}, nil
}

type jsonRecord struct {
	Columns []protocol.Column `json:"columns"`
	Cells   []protocol.Cell   `json:"cells"`
	Schema  bool              `json:"schema,omitempty"`
}

func csvValue(cell protocol.Cell) string {
	switch cell.Kind {
	case "null":
		return `\N`
	case "binary":
		return `\B` + cell.Base64
	default:
		// Backslash escaping makes the NULL and binary sentinels reversible.
		return strings.ReplaceAll(cell.Text, `\`, `\\`)
	}
}

type countingWriter struct {
	w io.Writer
	n int64
}

func (w *countingWriter) Write(p []byte) (int, error) {
	n, err := w.w.Write(p)
	w.n += int64(n)
	return n, err
}

func beginFile(path string) (*os.File, error) {
	if path == "" {
		return nil, errors.New("export: missing destination")
	}
	dir := filepath.Dir(path)
	base := filepath.Base(path)
	if _, err := os.Lstat(path); err == nil {
		return nil, ErrDestinationExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("export: inspect destination: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "."+base+".querybook-export-*")
	if err != nil {
		return nil, fmt.Errorf("export: create temporary file: %w", err)
	}
	_ = os.Chmod(tmp.Name(), 0600)
	return tmp, nil
}

func publishNoClobber(temp, path string) error {
	if err := os.Link(temp, path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return ErrDestinationExists
		}
		return fmt.Errorf("export: publish: %w", err)
	}
	if err := os.Remove(temp); err != nil {
		return fmt.Errorf("export: remove temporary file: %w", err)
	}
	return nil
}
