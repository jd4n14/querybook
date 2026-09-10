package results

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"unicode"

	"github.com/jd4n14/querybook/internal/protocol"
	"github.com/theory/jsonpath"
)

type operand struct {
	path  *rowPath
	lit   any
	isLit bool
}
type comparison struct {
	left, right operand
	op          string
}
type predicate struct {
	ors [][]comparison
}

type rowPath struct {
	name  string
	index int
	pos   bool
	parts []pathPart
}

type pathPart struct {
	name  string
	index *int
}

func compilePredicate(source string) (predicate, error) {
	s := strings.TrimSpace(source)
	if s == "" {
		return predicate{}, errors.New("result: empty JSONPath filter")
	}
	if strings.HasPrefix(s, "$[?(") && strings.HasSuffix(s, ")]") {
		s = strings.TrimSuffix(strings.TrimPrefix(s, "$[?("), ")]")
	}
	if strings.HasPrefix(s, "$") {
		return predicate{}, errors.New("result: JSONPath must select retained rows with a filter")
	}
	if !strings.HasPrefix(s, "@") && !strings.HasPrefix(s, "(") {
		if strings.HasPrefix(s, ".") {
			s = "@" + s
		} else {
			return predicate{}, errors.New("result: filter must be a JSONPath predicate")
		}
	}
	// The maintained RFC 9535 parser is the syntax gate. Evaluation below is
	// deliberately separate because its default numeric comparator converts
	// json.Number to float64, which would round BIGINT/DECIMAL values.
	if _, err := jsonpath.Parse("$[?(" + s + ")]"); err != nil {
		return predicate{}, fmt.Errorf("result: invalid JSONPath filter: %w", err)
	}
	p := parser{s: s}
	out, err := p.parseOr()
	if err != nil {
		return predicate{}, fmt.Errorf("result: invalid JSONPath filter: %w", err)
	}
	p.skipSpace()
	if !p.eof() {
		return predicate{}, errors.New("result: trailing JSONPath filter input")
	}
	return out, nil
}

func (p predicate) matches(meta Metadata, row []protocol.Cell) bool {
	for _, ands := range p.ors {
		ok := true
		for _, c := range ands {
			left, lok := c.left.value(meta, row)
			right, rok := c.right.value(meta, row)
			if !lok || !rok || !compareValues(left, right, c.op) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

func (p predicate) validate(meta Metadata) error {
	for _, ands := range p.ors {
		for _, c := range ands {
			for _, o := range []operand{c.left, c.right} {
				if o.path == nil || o.path.pos {
					continue
				}
				count := 0
				for _, column := range meta.Columns {
					if column.Name == o.path.name {
						count++
					}
				}
				if count > 1 {
					return fmt.Errorf("%w: %q", ErrAmbiguousName, o.path.name)
				}
				if count == 0 {
					return fmt.Errorf("%w: %q", ErrColumnNotFound, o.path.name)
				}
			}
		}
	}
	return nil
}

func (o operand) value(meta Metadata, row []protocol.Cell) (any, bool) {
	if o.isLit {
		return o.lit, true
	}
	if o.path == nil {
		return nil, false
	}
	if o.path.pos {
		if o.path.index < 0 || o.path.index >= len(row) {
			return nil, false
		}
		return jsonValue(meta, o.path.index, row[o.path.index]), true
	}
	idx := -1
	for i, c := range meta.Columns {
		if c.Name != o.path.name {
			continue
		}
		if idx >= 0 { // duplicate aliases must never choose one implicitly
			return nil, false
		}
		idx = i
	}
	if idx < 0 || idx >= len(row) {
		return nil, false
	}
	value := jsonValue(meta, idx, row[idx])
	for _, part := range o.path.parts {
		if part.index != nil {
			array, ok := value.([]any)
			if !ok || *part.index < 0 || *part.index >= len(array) {
				return nil, false
			}
			value = array[*part.index]
			continue
		}
		object, ok := value.(map[string]any)
		if !ok {
			return nil, false
		}
		value, ok = object[part.name]
		if !ok {
			return nil, false
		}
	}
	return value, true
}

func compareValues(a, b any, op string) bool {
	if a == nil || b == nil {
		eq := a == nil && b == nil
		if op == "==" {
			return eq
		}
		if op == "!=" {
			return !eq
		}
		return false
	}
	if ar, ok := numberRat(a); ok {
		br, bok := numberRat(b)
		if !bok {
			return op == "!="
		}
		cmp := ar.Cmp(br)
		return compareInt(cmp, op)
	}
	if _, ok := numberRat(b); ok {
		return op == "!="
	}
	if reflectEqual(a, b) {
		return op == "==" || op == "<=" || op == ">="
	}
	if op == "!=" {
		return true
	}
	as, aok := a.(string)
	bs, bok := b.(string)
	if !aok || !bok {
		return false
	}
	cmp := strings.Compare(as, bs)
	return compareInt(cmp, op)
}

func reflectEqual(a, b any) bool {
	// JSON scalar types are intentionally small; JSON null was handled above.
	switch av := a.(type) {
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case string:
		bv, ok := b.(string)
		return ok && av == bv
	default:
		return false
	}
}

func numberRat(v any) (*big.Rat, bool) {
	var raw string
	switch n := v.(type) {
	case exactNumber:
		r, err := n.rat()
		return r, err == nil
	case json.Number:
		raw = string(n)
	default:
		return nil, false
	}
	r := new(big.Rat)
	_, ok := r.SetString(raw)
	return r, ok
}

func compareInt(cmp int, op string) bool {
	switch op {
	case "==":
		return cmp == 0
	case "!=":
		return cmp != 0
	case "<":
		return cmp < 0
	case ">":
		return cmp > 0
	case "<=":
		return cmp <= 0
	case ">=":
		return cmp >= 0
	default:
		return false
	}
}

type parser struct {
	s string
	i int
}

func (p *parser) eof() bool { return p.i >= len(p.s) }
func (p *parser) skipSpace() {
	for !p.eof() && unicode.IsSpace(rune(p.s[p.i])) {
		p.i++
	}
}
func (p *parser) take(v string) bool {
	p.skipSpace()
	if strings.HasPrefix(p.s[p.i:], v) {
		p.i += len(v)
		return true
	}
	return false
}

func (p *parser) parseOr() (predicate, error) {
	first, err := p.parseAnd()
	if err != nil {
		return predicate{}, err
	}
	out := first
	for p.take("||") {
		next, err := p.parseAnd()
		if err != nil {
			return predicate{}, err
		}
		out.ors = append(out.ors, next.ors...)
	}
	return out, nil
}

func (p *parser) parseAnd() (predicate, error) {
	first, err := p.parsePrimary()
	if err != nil {
		return predicate{}, err
	}
	ands := append([][]comparison(nil), first.ors...)
	for p.take("&&") {
		next, err := p.parsePrimary()
		if err != nil {
			return predicate{}, err
		}
		combined := make([][]comparison, 0, len(ands)*len(next.ors))
		for _, left := range ands {
			for _, right := range next.ors {
				combined = append(combined, append(append([]comparison(nil), left...), right...))
			}
		}
		ands = combined
	}
	return predicate{ors: ands}, nil
}

func (p *parser) parsePrimary() (predicate, error) {
	p.skipSpace()
	if p.take("(") {
		v, err := p.parseOr()
		if err != nil || !p.take(")") {
			return predicate{}, errors.New("unclosed filter parenthesis")
		}
		return v, nil
	}
	left, err := p.parseOperand()
	if err != nil {
		return predicate{}, err
	}
	p.skipSpace()
	op := ""
	for _, candidate := range []string{"==", "!=", "<=", ">=", "<", ">"} {
		if p.take(candidate) {
			op = candidate
			break
		}
	}
	if op == "" {
		return predicate{}, errors.New("comparison operator required")
	}
	right, err := p.parseOperand()
	if err != nil {
		return predicate{}, err
	}
	return predicate{ors: [][]comparison{{{left: left, right: right, op: op}}}}, nil
}

func (p *parser) parseOperand() (operand, error) {
	p.skipSpace()
	if p.eof() {
		return operand{}, errors.New("missing operand")
	}
	if p.s[p.i] == '@' || p.s[p.i] == '.' {
		path, err := p.parsePath()
		return operand{path: path}, err
	}
	start := p.i
	if p.s[p.i] == '\'' || p.s[p.i] == '"' {
		quote := p.s[p.i]
		p.i++
		for !p.eof() {
			if p.s[p.i] == '\\' {
				p.i += 2
				continue
			}
			if p.s[p.i] == quote {
				p.i++
				break
			}
			p.i++
		}
	} else {
		for !p.eof() && !unicode.IsSpace(rune(p.s[p.i])) && !strings.ContainsRune("()&|<>=!", rune(p.s[p.i])) {
			p.i++
		}
	}
	raw := strings.TrimSpace(p.s[start:p.i])
	if raw == "" {
		return operand{}, errors.New("missing operand")
	}
	var val any
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&val); err != nil {
		return operand{}, fmt.Errorf("invalid literal %q", raw)
	}
	return operand{lit: val, isLit: true}, nil
}

func (p *parser) parsePath() (*rowPath, error) {
	p.skipSpace()
	if !p.eof() && p.s[p.i] == '@' {
		p.i++
	}
	if !p.eof() && p.s[p.i] == '.' {
		p.i++
	}
	p.skipSpace()
	if p.eof() {
		return nil, errors.New("missing JSONPath member")
	}
	if p.s[p.i] == '[' {
		p.i++
		p.skipSpace()
		if p.eof() || (p.s[p.i] != '\'' && p.s[p.i] != '"') {
			return nil, errors.New("JSONPath member must be quoted")
		}
		quote := p.s[p.i]
		p.i++
		start := p.i
		for !p.eof() {
			if p.s[p.i] == '\\' {
				p.i += 2
				continue
			}
			if p.s[p.i] == quote {
				break
			}
			p.i++
		}
		if p.eof() {
			return nil, errors.New("unclosed JSONPath member")
		}
		name := unquotePathMember(p.s[start:p.i], quote)
		p.i++
		p.skipSpace()
		if p.eof() || p.s[p.i] != ']' {
			return nil, errors.New("unclosed JSONPath member")
		}
		p.i++
		if name == "$values" {
			p.skipSpace()
			if p.eof() || p.s[p.i] != '[' {
				return nil, errors.New("$values requires a positional index")
			}
			p.i++
			start = p.i
			for !p.eof() && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
				p.i++
			}
			if start == p.i || p.eof() || p.s[p.i] != ']' {
				return nil, errors.New("invalid $values index")
			}
			idx, _ := strconv.Atoi(p.s[start:p.i])
			p.i++
			return &rowPath{pos: true, index: idx}, nil
		}
		path := &rowPath{name: name}
		return p.parsePathTail(path)
	}
	start := p.i
	for !p.eof() && (unicode.IsLetter(rune(p.s[p.i])) || unicode.IsDigit(rune(p.s[p.i])) || p.s[p.i] == '_' || p.s[p.i] == '-') {
		p.i++
	}
	if start == p.i {
		return nil, errors.New("invalid JSONPath member")
	}
	path := &rowPath{name: p.s[start:p.i]}
	return p.parsePathTail(path)
}

func (p *parser) parsePathTail(path *rowPath) (*rowPath, error) {
	for {
		p.skipSpace()
		if p.eof() || p.s[p.i] != '.' {
			if !p.eof() && p.s[p.i] == '[' {
				p.i++
				if !p.eof() && (p.s[p.i] == '\'' || p.s[p.i] == '"') {
					quote := p.s[p.i]
					p.i++
					start := p.i
					for !p.eof() {
						if p.s[p.i] == '\\' {
							p.i += 2
							continue
						}
						if p.s[p.i] == quote {
							break
						}
						p.i++
					}
					if p.eof() {
						return nil, errors.New("unclosed JSONPath member")
					}
					name := unquotePathMember(p.s[start:p.i], quote)
					p.i++
					if p.eof() || p.s[p.i] != ']' {
						return nil, errors.New("unclosed JSONPath member")
					}
					p.i++
					path.parts = append(path.parts, pathPart{name: name})
					continue
				}
				start := p.i
				for !p.eof() && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
					p.i++
				}
				if start == p.i || p.eof() || p.s[p.i] != ']' {
					return nil, errors.New("invalid JSONPath array index")
				}
				idx, _ := strconv.Atoi(p.s[start:p.i])
				p.i++
				path.parts = append(path.parts, pathPart{index: &idx})
				continue
			}
			break
		}
		p.i++
		start := p.i
		for !p.eof() && (unicode.IsLetter(rune(p.s[p.i])) || unicode.IsDigit(rune(p.s[p.i])) || p.s[p.i] == '_' || p.s[p.i] == '-') {
			p.i++
		}
		if start == p.i {
			return nil, errors.New("invalid JSONPath member")
		}
		path.parts = append(path.parts, pathPart{name: p.s[start:p.i]})
	}
	return path, nil
}

func unquotePathMember(raw string, quote byte) string {
	if quote == '"' {
		if decoded, err := strconv.Unquote(`"` + raw + `"`); err == nil {
			return decoded
		}
	}
	return strings.ReplaceAll(strings.ReplaceAll(raw, `\'`, `'`), `\\`, `\`)
}
