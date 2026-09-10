package results

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"sort"
	"strconv"
	"strings"

	"github.com/jd4n14/querybook/internal/protocol"
)

// CellTree decodes one cell on demand for structured presentation. Raw JSON
// lexemes are kept in every node, so large numeric tokens and whitespace are
// never normalized through float64 or a re-encoded map.
func CellTree(cell protocol.Cell) *protocol.JSONTreeNode {
	return CellTreeAt(cell, "", 8, 1<<20)
}

// CellTreeAt selects one JSON node and expands only up to depth and byte
// budgets. A truncated node remains explicitly typed so the UI can request a
// smaller subtree without guessing whether data was omitted.
func CellTreeAt(cell protocol.Cell, path string, depth int, maxBytes int64) *protocol.JSONTreeNode {
	if cell.Kind != "text" {
		return nil
	}
	raw := bytes.TrimSpace([]byte(cell.Text))
	if len(raw) == 0 {
		return nil
	}
	if depth <= 0 {
		depth = 1
	}
	if maxBytes <= 0 {
		maxBytes = 1 << 20
	}
	selected, ok := selectTreeRaw(raw, path)
	if !ok {
		return &protocol.JSONTreeNode{Type: "raw", Raw: cell.Text}
	}
	budget := maxBytes
	node, ok := treeNodeLimited(selected, depth, &budget)
	if !ok {
		return &protocol.JSONTreeNode{Type: "raw", Raw: cell.Text}
	}
	return &node
}

func selectTreeRaw(raw []byte, path string) ([]byte, bool) {
	path = strings.TrimSpace(path)
	if path == "" || path == "$" {
		return raw, true
	}
	if !strings.HasPrefix(path, "$") {
		return nil, false
	}
	cur := raw
	for i := 1; i < len(path); {
		if path[i] == '.' {
			i++
			start := i
			for i < len(path) && (path[i] == '_' || path[i] == '-' || path[i] >= '0' && path[i] <= '9' || path[i] >= 'a' && path[i] <= 'z' || path[i] >= 'A' && path[i] <= 'Z') {
				i++
			}
			if start == i {
				return nil, false
			}
			var object map[string]json.RawMessage
			if json.Unmarshal(cur, &object) != nil {
				return nil, false
			}
			value, exists := object[path[start:i]]
			if !exists {
				return nil, false
			}
			cur = value
			continue
		}
		if path[i] == '[' {
			i++
			if i < len(path) && (path[i] == '\'' || path[i] == '"') {
				quote := path[i]
				i++
				start := i
				for i < len(path) {
					if path[i] == '\\' {
						i += 2
						continue
					}
					if path[i] == quote {
						break
					}
					i++
				}
				if i >= len(path) {
					return nil, false
				}
				key := path[start:i]
				if quote == '"' {
					if decoded, err := strconv.Unquote(`"` + key + `"`); err == nil {
						key = decoded
					}
				} else {
					key = strings.ReplaceAll(strings.ReplaceAll(key, `\'`, `'`), `\\`, `\`)
				}
				i++
				if i >= len(path) || path[i] != ']' {
					return nil, false
				}
				i++
				var object map[string]json.RawMessage
				if json.Unmarshal(cur, &object) != nil {
					return nil, false
				}
				value, exists := object[key]
				if !exists {
					return nil, false
				}
				cur = value
				continue
			}
			start := i
			for i < len(path) && path[i] >= '0' && path[i] <= '9' {
				i++
			}
			if start == i || i >= len(path) || path[i] != ']' {
				return nil, false
			}
			index, _ := strconv.Atoi(path[start:i])
			i++
			var array []json.RawMessage
			if json.Unmarshal(cur, &array) != nil || index >= len(array) {
				return nil, false
			}
			cur = array[index]
			continue
		}
		return nil, false
	}
	return cur, true
}

func treeNodeLimited(raw []byte, depth int, budget *int64) (protocol.JSONTreeNode, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || *budget <= 0 {
		return protocol.JSONTreeNode{}, false
	}
	if int64(len(trimmed)) > *budget {
		return protocol.JSONTreeNode{Type: "truncated", Raw: "<tree byte budget exceeded>"}, true
	}
	*budget -= int64(len(trimmed))
	if depth <= 0 {
		return protocol.JSONTreeNode{Type: "truncated", Raw: string(trimmed)}, true
	}
	if trimmed[0] != '{' && trimmed[0] != '[' {
		node, ok := treeNode(trimmed)
		return node, ok
	}
	if trimmed[0] == '{' {
		var object map[string]json.RawMessage
		if json.Unmarshal(trimmed, &object) != nil {
			return protocol.JSONTreeNode{}, false
		}
		node := protocol.JSONTreeNode{Type: "object", Raw: string(raw)}
		keys := make([]string, 0, len(object))
		for key := range object {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		if depth == 1 {
			return node, true
		}
		for _, key := range keys {
			child, childOK := treeNodeLimited(object[key], depth-1, budget)
			if !childOK {
				return protocol.JSONTreeNode{Type: "truncated", Raw: "<tree byte budget exceeded>"}, true
			}
			keyRaw, _ := json.Marshal(key)
			node.Children = append(node.Children, protocol.JSONTreeEntry{Key: &protocol.JSONTreeNode{Type: "string", Raw: string(keyRaw)}, Node: child})
		}
		return node, true
	} else {
		var array []json.RawMessage
		if json.Unmarshal(trimmed, &array) != nil {
			return protocol.JSONTreeNode{}, false
		}
		node := protocol.JSONTreeNode{Type: "array", Raw: string(raw)}
		if depth == 1 {
			return node, true
		}
		for i := range array {
			child, childOK := treeNodeLimited(array[i], depth-1, budget)
			if !childOK {
				return protocol.JSONTreeNode{Type: "truncated", Raw: "<tree byte budget exceeded>"}, true
			}
			node.Children = append(node.Children, protocol.JSONTreeEntry{Node: child})
		}
		return node, true
	}
}

func treeNode(raw []byte) (protocol.JSONTreeNode, bool) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return protocol.JSONTreeNode{}, false
	}
	node := protocol.JSONTreeNode{Raw: string(raw)}
	switch trimmed[0] {
	case '{':
		var object map[string]json.RawMessage
		if err := json.Unmarshal(trimmed, &object); err != nil {
			return protocol.JSONTreeNode{}, false
		}
		node.Type = "object"
		keys := make([]string, 0, len(object))
		for key := range object {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			child, ok := treeNode(object[key])
			if !ok {
				return protocol.JSONTreeNode{}, false
			}
			keyRaw, _ := json.Marshal(key)
			node.Children = append(node.Children, protocol.JSONTreeEntry{Key: &protocol.JSONTreeNode{Type: "string", Raw: string(keyRaw)}, Node: child})
		}
	case '[':
		var array []json.RawMessage
		if err := json.Unmarshal(trimmed, &array); err != nil {
			return protocol.JSONTreeNode{}, false
		}
		node.Type = "array"
		for _, value := range array {
			child, ok := treeNode(value)
			if !ok {
				return protocol.JSONTreeNode{}, false
			}
			node.Children = append(node.Children, protocol.JSONTreeEntry{Node: child})
		}
	case '"':
		var value string
		if err := json.Unmarshal(trimmed, &value); err != nil {
			return protocol.JSONTreeNode{}, false
		}
		node.Type = "string"
	case 't', 'f':
		var value bool
		if err := json.Unmarshal(trimmed, &value); err != nil {
			return protocol.JSONTreeNode{}, false
		}
		node.Type = "boolean"
	case 'n':
		if !bytes.Equal(trimmed, []byte("null")) {
			return protocol.JSONTreeNode{}, false
		}
		node.Type = "null"
	default:
		var value json.Number
		dec := json.NewDecoder(bytes.NewReader(trimmed))
		dec.UseNumber()
		if err := dec.Decode(&value); err != nil {
			return protocol.JSONTreeNode{}, false
		}
		node.Type = "number"
	}
	return node, true
}

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
