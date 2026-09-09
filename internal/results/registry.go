// Package results owns the runner's retained result sets. A handle is an
// opaque UUID and is the only durable reference exposed to the UI. Result
// sets are immutable after publication; callers receive defensive copies of
// all slices so a viewport or filter cannot mutate the retained data.
package results

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jd4n14/querybook/internal/protocol"
)

const (
	DefaultMaxBytes = int64(64 * 1024 * 1024)
	DefaultMaxSets  = 32
)

var (
	ErrNotFound       = errors.New("result: handle not found")
	ErrCapacity       = errors.New("result: retention capacity exceeded")
	ErrInvalidPage    = errors.New("result: invalid page")
	ErrInvalidCell    = errors.New("result: invalid cell")
	ErrAlreadyPinned  = errors.New("result: handle is already pinned")
	ErrNotPinned      = errors.New("result: handle is not pinned")
	ErrAmbiguousName  = errors.New("result: column name is ambiguous")
	ErrColumnNotFound = errors.New("result: column not found")
)

// Metadata is execution-time metadata. It deliberately contains no inferred
// keys or schema relationships: only values supplied by database/sql are
// retained.
type Metadata struct {
	Columns          []protocol.Column
	OriginalSQL      string
	ExecutedSQL      string
	AutoLimitApplied bool
	AutoLimitReason  string
	ConnectionID     string
	Connection       protocol.Connection
	ExecutedAt       time.Time
	ResultSets       int
	ObservedRows     int64
	Truncated        bool
	TruncationReason string
	RetainedBytes    int64
	AffectedRows     int64
}

// Snapshot is a defensive, read-only view of a retained result set. Rows and
// columns are copied by Registry.Get/Page/View and are safe for callers to
// inspect or transform.
type Snapshot struct {
	Handle    string
	Meta      Metadata
	Rows      [][]protocol.Cell
	Pinned    bool
	Bytes     int64
	TotalRows int
}

type entry struct {
	meta   Metadata
	rows   [][]protocol.Cell
	bytes  int64
	pinned bool
	views  map[string][]int
}

type Options struct {
	MaxBytes int64
	MaxSets  int
}

// Registry retains successful executions until explicit release. It never
// evicts an old or pinned result implicitly.
type Registry struct {
	mu       sync.RWMutex
	sets     map[string]entry
	bytes    int64
	maxBytes int64
	maxSets  int
}

func New(opts Options) *Registry {
	if opts.MaxBytes <= 0 {
		opts.MaxBytes = DefaultMaxBytes
	}
	if opts.MaxSets <= 0 {
		opts.MaxSets = DefaultMaxSets
	}
	return &Registry{sets: make(map[string]entry), maxBytes: opts.MaxBytes, maxSets: opts.MaxSets}
}

func cloneColumns(in []protocol.Column) []protocol.Column {
	if in == nil {
		return nil
	}
	out := make([]protocol.Column, len(in))
	copy(out, in)
	for i := range out {
		if in[i].Nullable != nil {
			v := *in[i].Nullable
			out[i].Nullable = &v
		}
	}
	return out
}

func cloneRows(in [][]protocol.Cell) [][]protocol.Cell {
	if in == nil {
		return nil
	}
	out := make([][]protocol.Cell, len(in))
	for i := range in {
		out[i] = make([]protocol.Cell, len(in[i]))
		copy(out[i], in[i])
	}
	return out
}

func cloneMeta(in Metadata) Metadata {
	in.Columns = cloneColumns(in.Columns)
	return in
}

func estimate(meta Metadata, rows [][]protocol.Cell) int64 {
	// Include a fixed allowance per row/cell and all variable text/base64
	// payload. The estimate is intentionally conservative for admission.
	n := int64(256 + len(meta.Columns)*96)
	for _, row := range rows {
		n += 32
		for _, cell := range row {
			n += 32 + int64(len(cell.Kind)+len(cell.Text)+len(cell.Base64))
		}
	}
	return n
}

// Retain publishes one successful execution. The returned handle is random,
// unguessable, and stable for the lifetime of this entry.
func (r *Registry) Retain(meta Metadata, rows [][]protocol.Cell) (string, error) {
	if r == nil {
		return "", errors.New("result: registry unavailable")
	}
	meta = cloneMeta(meta)
	rows = cloneRows(rows)
	b := estimate(meta, rows)
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.sets) >= r.maxSets || b > r.maxBytes || r.bytes > r.maxBytes-b {
		return "", ErrCapacity
	}
	id := uuid.NewString()
	r.sets[id] = entry{meta: meta, rows: rows, bytes: b, views: make(map[string][]int)}
	r.bytes += b
	return id, nil
}

func (r *Registry) getLocked(handle string) (entry, error) {
	if handle == "" {
		return entry{}, ErrNotFound
	}
	v, ok := r.sets[handle]
	if !ok {
		return entry{}, ErrNotFound
	}
	return v, nil
}

func snapshotOf(handle string, e entry) Snapshot {
	return Snapshot{Handle: handle, Meta: cloneMeta(e.meta), Rows: cloneRows(e.rows), Pinned: e.pinned, Bytes: e.bytes, TotalRows: len(e.rows)}
}

func (r *Registry) Get(handle string) (Snapshot, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return Snapshot{}, err
	}
	return snapshotOf(handle, e), nil
}

// Page returns rows in source order and their source ordinals. Offset and
// limit are checked without allocating a result-sized temporary slice.
func (r *Registry) Page(handle string, offset, limit int) (Snapshot, []int, error) {
	if offset < 0 || limit < 0 {
		return Snapshot{}, nil, ErrInvalidPage
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return Snapshot{}, nil, err
	}
	if offset > len(e.rows) {
		return Snapshot{}, nil, ErrInvalidPage
	}
	end := offset + limit
	if end < offset || end > len(e.rows) {
		end = len(e.rows)
	}
	view := snapshotOf(handle, e)
	view.Rows = cloneRows(e.rows[offset:end])
	ordinals := make([]int, end-offset)
	for i := range ordinals {
		ordinals[i] = offset + i
	}
	return view, ordinals, nil
}

// View is an alias for Page kept as a distinct operation in the protocol so
// the UI can later pass a filtered ordinal view without changing the handle.
func (r *Registry) View(handle string, offset, limit int) (Snapshot, []int, error) {
	return r.Page(handle, offset, limit)
}

// PageView pages a filtered ordinal view while retaining the immutable base
// handle. An unknown view is rejected; the caller can continue using the
// previous view after a failed filter.
func (r *Registry) PageView(handle, viewID string, offset, limit int) (Snapshot, []int, error) {
	if offset < 0 || limit < 0 {
		return Snapshot{}, nil, ErrInvalidPage
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return Snapshot{}, nil, err
	}
	ordinals, ok := e.views[viewID]
	if !ok || viewID == "" {
		return Snapshot{}, nil, ErrNotFound
	}
	if offset > len(ordinals) {
		return Snapshot{}, nil, ErrInvalidPage
	}
	end := offset + limit
	if end < offset || end > len(ordinals) {
		end = len(ordinals)
	}
	view := snapshotOf(handle, e)
	view.Rows = make([][]protocol.Cell, end-offset)
	view.TotalRows = len(ordinals)
	selected := make([]int, end-offset)
	for i, source := range ordinals[offset:end] {
		view.Rows[i] = cloneRows(e.rows[source : source+1])[0]
		selected[i] = source
	}
	return view, selected, nil
}

func (r *Registry) ViewIndices(handle, viewID string) ([]int, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return nil, err
	}
	indices, ok := e.views[viewID]
	if !ok {
		return nil, ErrNotFound
	}
	return append([]int(nil), indices...), nil
}

// Filter evaluates a bounded row predicate over the complete retained set.
// It returns a new view ID only after parsing and evaluating every row has
// succeeded, so the previous view is never corrupted by a bad expression.
func (r *Registry) Filter(handle, expression string) (string, int, error) {
	predicate, err := compilePredicate(expression)
	if err != nil {
		return "", 0, err
	}
	r.mu.RLock()
	e, err := r.getLocked(handle)
	if err != nil {
		r.mu.RUnlock()
		return "", 0, err
	}
	if err := predicate.validate(e.meta); err != nil {
		r.mu.RUnlock()
		return "", 0, err
	}
	selected := make([]int, 0, len(e.rows))
	for i, row := range e.rows {
		if predicate.matches(e.meta, row) {
			selected = append(selected, i)
		}
	}
	r.mu.RUnlock()
	viewID := uuid.NewString()
	r.mu.Lock()
	defer r.mu.Unlock()
	e, err = r.getLocked(handle)
	if err != nil {
		return "", 0, err
	}
	if e.views == nil {
		e.views = make(map[string][]int)
	}
	e.views[viewID] = append([]int(nil), selected...)
	r.sets[handle] = e
	return viewID, len(selected), nil
}

// jsonValue preserves SQL null, strings, booleans, binaries, and exact SQL
// numeric text as distinct values. JSON parsing is only used when a text cell
// is explicitly JSON-shaped by a JSONPath object traversal.
func jsonValue(meta Metadata, index int, c protocol.Cell) any {
	if c.Kind == "null" {
		return nil
	}
	if c.Kind == "binary" {
		return map[string]any{"$binary": c.Base64}
	}
	if c.Kind != "text" {
		return c.Text
	}
	if index < len(meta.Columns) && isJSONNumericType(meta.Columns[index].DatabaseType) {
		if _, ok := new(big.Rat).SetString(c.Text); ok {
			return exactNumber{raw: c.Text}
		}
	}
	if index < len(meta.Columns) && isJSONBoolType(meta.Columns[index].DatabaseType) {
		switch c.Text {
		case "0", "false", "FALSE":
			return false
		case "1", "true", "TRUE":
			return true
		}
	}
	return c.Text
}

type exactNumber struct{ raw string }

func (n exactNumber) rat() (*big.Rat, error) {
	r := new(big.Rat)
	if _, ok := r.SetString(n.raw); !ok {
		return nil, errors.New("invalid numeric cell")
	}
	return r, nil
}

func isJSONNumericType(typ string) bool {
	t := strings.ToLower(typ)
	for _, part := range []string{"int", "decimal", "numeric", "number", "float", "double", "real", "bit"} {
		if strings.Contains(t, part) {
			return true
		}
	}
	return false
}

func isJSONBoolType(typ string) bool {
	t := strings.ToLower(typ)
	return strings.Contains(t, "bool") || t == "bit" || strings.HasPrefix(t, "bit(")
}

// JSONNumber is exposed for tests and future filters that need to inspect a
// raw exact literal without converting through float64.
func JSONNumber(raw string) (json.Number, error) {
	if _, ok := new(big.Rat).SetString(raw); !ok {
		return "", errors.New("invalid JSON number")
	}
	return json.Number(raw), nil
}

// RawBinary returns the original bytes represented by a binary cell.
func RawBinary(c protocol.Cell) ([]byte, error) {
	if c.Kind != "binary" {
		return nil, errors.New("result: cell is not binary")
	}
	return base64.StdEncoding.DecodeString(c.Base64)
}

func (r *Registry) Cell(handle string, row, column int) (protocol.Cell, protocol.Column, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return protocol.Cell{}, protocol.Column{}, err
	}
	if row < 0 || row >= len(e.rows) || column < 0 || column >= len(e.meta.Columns) || column >= len(e.rows[row]) {
		return protocol.Cell{}, protocol.Column{}, ErrInvalidCell
	}
	return e.rows[row][column], e.meta.Columns[column], nil
}

func (r *Registry) Pin(handle string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return err
	}
	if e.pinned {
		return ErrAlreadyPinned
	}
	e.pinned = true
	r.sets[handle] = e
	return nil
}

func (r *Registry) Unpin(handle string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return err
	}
	if !e.pinned {
		return ErrNotPinned
	}
	e.pinned = false
	r.sets[handle] = e
	return nil
}

func (r *Registry) Release(handle string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return err
	}
	delete(r.sets, handle)
	r.bytes -= e.bytes
	return nil
}

func (r *Registry) Clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sets = make(map[string]entry)
	r.bytes = 0
}

func (r *Registry) Stats() (sets int, bytes int64) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.sets), r.bytes
}

// ColumnIndex resolves a unique actual database column label. Empty labels
// are treated exactly like any other label; duplicate labels are ambiguous.
func (s Snapshot) ColumnIndex(name string) (int, error) {
	found := -1
	for i, c := range s.Meta.Columns {
		if c.Name != name {
			continue
		}
		if found >= 0 {
			return -1, fmt.Errorf("%w: %q", ErrAmbiguousName, name)
		}
		found = i
	}
	if found < 0 {
		return -1, fmt.Errorf("%w: %q", ErrColumnNotFound, name)
	}
	return found, nil
}
