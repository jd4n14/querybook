package results

import (
	"encoding/json"
	"strconv"
	"strings"

	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/common/types/ref"

	"github.com/jd4n14/querybook/internal/protocol"
)

// reservedCELIdents are names that cannot be declared as column variables.
// true/false/null/in are CEL keywords. row and values are Querybook fallbacks.
var reservedCELIdents = map[string]bool{
	"true": true, "false": true, "null": true, "in": true,
	"as": true, "break": true, "const": true, "continue": true,
	"else": true, "for": true, "function": true, "if": true,
	"import": true, "let": true, "loop": true, "package": true,
	"namespace": true, "return": true, "var": true, "void": true,
	"while": true,
	"row":   true, "values": true,
}

func columnCounts(meta Metadata) map[string]int {
	counts := make(map[string]int, len(meta.Columns))
	for _, column := range meta.Columns {
		counts[column.Name]++
	}
	return counts
}

func celIdentOK(name string) bool {
	if name == "" || reservedCELIdents[name] {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if i == 0 {
			if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_') {
				return false
			}
		} else if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

func uniqueColumnIdents(meta Metadata) map[string]struct{} {
	counts := columnCounts(meta)
	idents := make(map[string]struct{})
	for name, count := range counts {
		if count == 1 && celIdentOK(name) {
			idents[name] = struct{}{}
		}
	}
	return idents
}

func isJSONDocumentType(typ string) bool {
	t := strings.ToLower(typ)
	return strings.Contains(t, "json") || strings.Contains(t, "struct")
}

func isDecimalType(typ string) bool {
	t := strings.ToLower(typ)
	return strings.Contains(t, "decimal") || strings.Contains(t, "numeric")
}

func isIntegerType(typ string) bool {
	t := strings.ToLower(typ)
	if isDecimalType(typ) || strings.Contains(t, "point") || strings.Contains(t, "interval") {
		return false
	}
	for _, part := range []string{"int", "serial", "tinyint", "smallint", "mediumint", "bigint"} {
		if strings.Contains(t, part) {
			return true
		}
	}
	return false
}

func isUnsignedType(typ string) bool {
	return strings.Contains(strings.ToLower(typ), "unsigned")
}

func isFloatType(typ string) bool {
	t := strings.ToLower(typ)
	if isDecimalType(typ) {
		return false
	}
	for _, part := range []string{"float", "double", "real"} {
		if strings.Contains(t, part) {
			return true
		}
	}
	return false
}

func isBoolType(typ string) bool {
	return strings.Contains(strings.ToLower(typ), "bool")
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

func jsonCellVal(raw string) ref.Val {
	decoded, ok := decodeJSONValue(raw)
	if !ok {
		return types.String(raw)
	}
	return types.DefaultTypeAdapter.NativeToValue(decoded)
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

func parseIntPref(text string) (any, bool) {
	if i, err := strconv.ParseInt(text, 10, 64); err == nil {
		return i, true
	}
	if u, err := strconv.ParseUint(text, 10, 64); err == nil {
		return u, true
	}
	if d, ok := parseDecimal(text); ok {
		return d, true
	}
	return nil, false
}

func structuredCell(meta Metadata, index int, c protocol.Cell) bool {
	if c.Kind != "text" || strings.TrimSpace(c.Text) == "" {
		return false
	}
	if index < len(meta.Columns) && isJSONDocumentType(meta.Columns[index].DatabaseType) {
		return true
	}
	return looksLikeJSONDocument(c.Text)
}

func databaseType(meta Metadata, index int) string {
	if index < len(meta.Columns) {
		return meta.Columns[index].DatabaseType
	}
	return ""
}

// projectCell returns a CEL activation value for one retained cell. JSON
// documents are lazy funcs so unused structured cells are not parsed.
func projectCell(meta Metadata, index int, c protocol.Cell) any {
	if c.Kind == "null" {
		return nil
	}
	if structuredCell(meta, index, c) {
		raw := c.Text
		return func() ref.Val { return jsonCellVal(raw) }
	}
	return projectScalar(meta, index, c)
}

func projectEager(meta Metadata, index int, c protocol.Cell) any {
	if c.Kind == "null" {
		return nil
	}
	if structuredCell(meta, index, c) {
		decoded, ok := decodeJSONValue(c.Text)
		if !ok {
			return c.Text
		}
		return decoded
	}
	return projectScalar(meta, index, c)
}

func projectScalar(meta Metadata, index int, c protocol.Cell) any {
	if c.Kind == "binary" {
		return map[string]any{"$binary": c.Base64}
	}
	if c.Kind != "text" {
		return c.Text
	}
	colType := databaseType(meta, index)
	if isDecimalType(colType) {
		if d, ok := parseDecimal(c.Text); ok {
			return d
		}
	}
	switch c.ValueKind {
	case "integer":
		if v, ok := parseIntPref(c.Text); ok {
			return v
		}
	case "unsigned":
		if u, err := strconv.ParseUint(c.Text, 10, 64); err == nil {
			return u
		}
		if v, ok := parseIntPref(c.Text); ok {
			return v
		}
	case "float":
		if f, err := strconv.ParseFloat(c.Text, 64); err == nil {
			return f
		}
	case "boolean":
		if v, ok := booleanScalar(c.Text); ok {
			return v
		}
	}
	legacy := c.ValueKind == ""
	if legacy && isFloatType(colType) {
		if f, err := strconv.ParseFloat(c.Text, 64); err == nil {
			return f
		}
	}
	if legacy && isIntegerType(colType) {
		if v, ok := parseIntPref(c.Text); ok {
			return v
		}
	}
	if (legacy || c.ValueKind == "string") && isUnsignedType(colType) {
		if u, err := strconv.ParseUint(c.Text, 10, 64); err == nil {
			return u
		}
	}
	if (legacy || c.ValueKind == "") && isBoolType(colType) {
		if v, ok := booleanScalar(c.Text); ok {
			return v
		}
	}
	return c.Text
}
