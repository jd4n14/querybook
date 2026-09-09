package results

import (
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"sort"
	"strconv"
	"strings"

	"github.com/jd4n14/querybook/internal/protocol"
)

// CompareRows compares two retained source ordinals from one immutable
// handle. It reports semantic differences for valid JSON cells and falls back
// to exact raw-cell comparison for invalid JSON or binary cells.
func (r *Registry) CompareRows(handle string, sourceRow, currentRow int) ([]protocol.ResultDifference, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, err := r.getLocked(handle)
	if err != nil {
		return nil, err
	}
	if sourceRow < 0 || currentRow < 0 || sourceRow >= len(e.rows) || currentRow >= len(e.rows) {
		return nil, ErrInvalidPage
	}
	before, after := e.rows[sourceRow], e.rows[currentRow]
	columns := len(e.meta.Columns)
	if len(before) > columns {
		columns = len(before)
	}
	if len(after) > columns {
		columns = len(after)
	}
	changes := make([]protocol.ResultDifference, 0)
	for i := 0; i < columns; i++ {
		var b, a protocol.Cell
		if i < len(before) {
			b = before[i]
		}
		if i < len(after) {
			a = after[i]
		}
		if cellsEqual(b, a) {
			continue
		}
		name := ""
		if i < len(e.meta.Columns) {
			name = e.meta.Columns[i].Name
		}
		var paths []string
		if left, lok := decodeStructured(b); lok {
			if right, rok := decodeStructured(a); rok {
				paths = diffJSON(left, right, "$")
			}
		}
		if len(paths) == 0 {
			paths = []string{"$"}
		}
		for _, path := range paths {
			kind := "value"
			if path != "$" {
				kind = "json"
			}
			bc, ac := b, a
			changes = append(changes, protocol.ResultDifference{Column: i, ColumnName: name, Path: path, Kind: kind, Before: &bc, After: &ac})
		}
	}
	return changes, nil
}

type sqlNull struct{}

func decodeStructured(c protocol.Cell) (any, bool) {
	if c.Kind == "null" {
		return sqlNull{}, true
	}
	if c.Kind != "text" || strings.TrimSpace(c.Text) == "" {
		return nil, false
	}
	dec := json.NewDecoder(strings.NewReader(c.Text))
	dec.UseNumber()
	var value any
	if err := dec.Decode(&value); err != nil {
		return nil, false
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return nil, false
	}
	return value, true
}

func cellsEqual(a, b protocol.Cell) bool {
	if a.Kind == "null" || b.Kind == "null" {
		return a.Kind == b.Kind
	}
	left, lok := decodeStructured(a)
	right, rok := decodeStructured(b)
	if lok && rok {
		return jsonEqual(left, right)
	}
	return a == b
}

func jsonEqual(a, b any) bool {
	if an, ok := a.(json.Number); ok {
		bn, bok := b.(json.Number)
		if !bok {
			return false
		}
		ar, aok := new(big.Rat).SetString(string(an))
		br, bok := new(big.Rat).SetString(string(bn))
		return aok && bok && ar.Cmp(br) == 0
	}
	if am, ok := a.(map[string]any); ok {
		bm, bok := b.(map[string]any)
		if !bok || len(am) != len(bm) {
			return false
		}
		for key, av := range am {
			bv, exists := bm[key]
			if !exists || !jsonEqual(av, bv) {
				return false
			}
		}
		return true
	}
	if aa, ok := a.([]any); ok {
		ba, bok := b.([]any)
		if !bok || len(aa) != len(ba) {
			return false
		}
		for i := range aa {
			if !jsonEqual(aa[i], ba[i]) {
				return false
			}
		}
		return true
	}
	return fmt.Sprint(a) == fmt.Sprint(b) && fmt.Sprintf("%T", a) == fmt.Sprintf("%T", b)
}

func diffJSON(a, b any, path string) []string {
	if jsonEqual(a, b) {
		return nil
	}
	if am, ok := a.(map[string]any); ok {
		bm, bok := b.(map[string]any)
		if !bok {
			return []string{path}
		}
		keys := make([]string, 0, len(am)+len(bm))
		seen := make(map[string]bool)
		for key := range am {
			seen[key] = true
			keys = append(keys, key)
		}
		for key := range bm {
			if !seen[key] {
				keys = append(keys, key)
			}
		}
		sort.Strings(keys)
		var out []string
		for _, key := range keys {
			av, aok := am[key]
			bv, bok := bm[key]
			child := path + "." + key
			if !aok || !bok {
				out = append(out, child)
			} else {
				out = append(out, diffJSON(av, bv, child)...)
			}
		}
		return out
	}
	if aa, ok := a.([]any); ok {
		ba, bok := b.([]any)
		if !bok || len(aa) != len(ba) {
			return []string{path}
		}
		var out []string
		for i := range aa {
			out = append(out, diffJSON(aa[i], ba[i], path+"["+strconv.Itoa(i)+"]")...)
		}
		return out
	}
	return []string{path}
}
