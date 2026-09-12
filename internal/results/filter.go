package results

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/jd4n14/querybook/internal/protocol"
	"github.com/theory/jsonpath"
	"github.com/theory/jsonpath/spec"
)

// compiledFilter is a JSONPath row predicate. Evaluation uses
// github.com/theory/jsonpath; Querybook only normalizes interactive shorthand
// and adapts each retained row into a temporary object.
type compiledFilter struct {
	filter     *spec.FilterSelector
	rendered   string
	wildcard   bool
	deepValues bool
}

func compileFilter(source string) (compiledFilter, error) {
	normalized, err := normalizeJSONPath(source)
	if err != nil {
		return compiledFilter{}, err
	}
	path, err := jsonpath.Parse(normalized)
	if err != nil {
		return compiledFilter{}, fmt.Errorf("invalid filter: %w", err)
	}
	filter := rowFilterSelector(path)
	if filter == nil {
		return compiledFilter{}, errors.New("invalid filter: JSONPath must select retained rows with a filter")
	}
	rendered := path.String()
	return compiledFilter{
		filter:     filter,
		rendered:   rendered,
		wildcard:   pathHasWildcard(rendered),
		deepValues: valuesNested(rendered),
	}, nil
}

// normalizeJSONPath is purely syntactic. Expressions that start with @ are
// wrapped as $[?(...)]; full JSONPath is left unchanged.
func normalizeJSONPath(source string) (string, error) {
	s := strings.TrimSpace(source)
	if s == "" {
		return "", errors.New("invalid filter: empty JSONPath filter")
	}
	if strings.HasPrefix(s, "@") {
		return "$[?(" + s + ")]", nil
	}
	if strings.HasPrefix(s, "$") {
		return s, nil
	}
	return "", errors.New("invalid filter: filter must be a JSONPath predicate")
}

func rowFilterSelector(path *jsonpath.Path) *spec.FilterSelector {
	if path == nil {
		return nil
	}
	for _, seg := range path.Query().Segments() {
		for _, sel := range seg.Selectors() {
			if f, ok := sel.(*spec.FilterSelector); ok {
				return f
			}
		}
	}
	return nil
}

func (c compiledFilter) validate(meta Metadata) error {
	counts := columnCounts(meta)
	for name, count := range counts {
		if count < 2 {
			continue
		}
		if used, _ := pathUsesColumn(c.rendered, name); used {
			return fmt.Errorf("%w: %q", ErrAmbiguousName, name)
		}
	}
	return nil
}

func (c compiledFilter) match(meta Metadata, row []protocol.Cell) (matched bool) {
	defer func() {
		if recover() != nil {
			matched = false
		}
	}()
	obj := adaptRow(meta, row, c)
	return c.filter.Eval(obj, obj)
}

func columnCounts(meta Metadata) map[string]int {
	counts := make(map[string]int, len(meta.Columns))
	for _, column := range meta.Columns {
		counts[column.Name]++
	}
	return counts
}

func columnToken(name string) string {
	return "[" + strconv.Quote(name) + "]"
}

func pathUsesColumn(rendered, name string) (used, nested bool) {
	token := columnToken(name)
	for _, prefix := range []string{"@", "$"} {
		needle := prefix + token
		start := 0
		for {
			i := strings.Index(rendered[start:], needle)
			if i < 0 {
				break
			}
			i += start
			used = true
			if strings.HasPrefix(rendered[i+len(needle):], "[") {
				nested = true
			}
			start = i + len(needle)
		}
	}
	return used, nested
}

func pathHasWildcard(rendered string) bool {
	return strings.Contains(rendered, "[*]") || strings.Contains(rendered, "..")
}

func valuesNested(rendered string) bool {
	for _, prefix := range []string{"@", "$"} {
		needle := prefix + columnToken("$values") + "["
		start := 0
		for {
			i := strings.Index(rendered[start:], needle)
			if i < 0 {
				break
			}
			i += start
			rest := rendered[i+len(needle):]
			j := 0
			if j < len(rest) && rest[j] == '-' {
				j++
			}
			digits := j
			for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {
				j++
			}
			if j > digits && j < len(rest) && rest[j] == ']' && j+1 < len(rest) && rest[j+1] == '[' {
				return true
			}
			start = i + len(needle)
		}
	}
	return false
}

// adaptRow builds a temporary JSONPath object for one retained row. Named
// keys are unique column labels. Duplicate labels are omitted from the object
// and remain available through the positional $values array. SQL NULL becomes
// JSON null. Nested JSON is materialized only for columns the path actually
// traverses.
func adaptRow(meta Metadata, row []protocol.Cell, compiled compiledFilter) map[string]any {
	counts := columnCounts(meta)
	obj := make(map[string]any, len(meta.Columns)+1)
	values := make([]any, len(row))
	for i, cell := range row {
		name := ""
		if i < len(meta.Columns) {
			name = meta.Columns[i].Name
		}
		_, nested := pathUsesColumn(compiled.rendered, name)
		if compiled.wildcard || compiled.deepValues {
			if i < len(meta.Columns) && isJSONDocumentType(meta.Columns[i].DatabaseType) {
				nested = true
			}
		}
		val := materializeCell(meta, i, cell, nested)
		values[i] = val
		if name == "" || counts[name] != 1 {
			continue
		}
		obj[name] = val
	}
	obj["$values"] = values
	return obj
}

func materializeCell(meta Metadata, index int, c protocol.Cell, nested bool) any {
	scalar := cellScalar(meta, index, c)
	if !nested || c.Kind != "text" {
		return scalar
	}
	typedJSON := index < len(meta.Columns) && isJSONDocumentType(meta.Columns[index].DatabaseType)
	if !typedJSON && !looksLikeJSONDocument(c.Text) {
		return scalar
	}
	decoded, ok := decodeJSONValue(c.Text)
	if !ok {
		return scalar
	}
	return decoded
}

func cellScalar(meta Metadata, index int, c protocol.Cell) any {
	if c.Kind == "null" {
		return nil
	}
	if c.Kind == "binary" {
		return map[string]any{"$binary": c.Base64}
	}
	if c.Kind != "text" {
		return c.Text
	}
	if c.ValueKind == "integer" || c.ValueKind == "unsigned" || c.ValueKind == "float" {
		if _, err := JSONNumber(c.Text); err == nil {
			return json.Number(c.Text)
		}
	}
	if c.ValueKind == "boolean" {
		if v, ok := booleanScalar(c.Text); ok {
			return v
		}
	}
	legacy := c.ValueKind == ""
	if legacy && index < len(meta.Columns) && isJSONNumericType(meta.Columns[index].DatabaseType) {
		if _, err := JSONNumber(c.Text); err == nil {
			return json.Number(c.Text)
		}
	}
	if legacy && index < len(meta.Columns) && isJSONBoolType(meta.Columns[index].DatabaseType) {
		if v, ok := booleanScalar(c.Text); ok {
			return v
		}
	}
	return c.Text
}

func booleanScalar(text string) (bool, bool) {
	switch text {
	case "0", "false", "FALSE":
		return false, true
	case "1", "true", "TRUE":
		return true, true
	default:
		return false, false
	}
}

func looksLikeJSONDocument(text string) bool {
	trimmed := strings.TrimSpace(text)
	return len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[')
}

func decodeJSONValue(text string) (any, bool) {
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	var decoded any
	if err := dec.Decode(&decoded); err != nil {
		return nil, false
	}
	if dec.More() {
		return nil, false
	}
	return decoded, true
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
	return strings.Contains(strings.ToLower(typ), "bool")
}

func isJSONDocumentType(typ string) bool {
	t := strings.ToLower(typ)
	return strings.Contains(t, "json") || strings.Contains(t, "struct")
}
