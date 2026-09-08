package policy

import (
	"fmt"
	"strings"
	"unicode"
)

type Decision struct {
	Allowed bool
	Reason  string
	Keyword string
}

// Tokens is intentionally small and quote/comment aware. Unknown syntax is
// denied by Classify; force is the explicit escape hatch.
func Tokens(sql string) ([]string, error) {
	var out []string
	var word strings.Builder
	flush := func() {
		if word.Len() > 0 {
			out = append(out, strings.ToLower(word.String()))
			word.Reset()
		}
	}
	for i := 0; i < len(sql); {
		c := sql[i]
		if c == '\'' || c == '"' || c == '`' {
			flush()
			quote := c
			i++
			closed := false
			for i < len(sql) {
				if sql[i] == '\\' && quote != '`' {
					i += 2
					continue
				}
				if sql[i] == quote {
					if i+1 < len(sql) && sql[i+1] == quote {
						i += 2
						continue
					}
					i++
					closed = true
					break
				}
				i++
			}
			if !closed {
				return nil, fmt.Errorf("unterminated quoted value")
			}
			continue
		}
		if c == '-' && i+1 < len(sql) && sql[i+1] == '-' && (i+2 >= len(sql) || unicode.IsSpace(rune(sql[i+2]))) {
			flush()
			i += 2
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if c == '#' {
			flush()
			i++
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if c == '/' && i+1 < len(sql) && sql[i+1] == '*' {
			flush()
			executable := i+2 < len(sql) && sql[i+2] == '!'
			i += 2
			start := i
			for i+1 < len(sql) && !(sql[i] == '*' && sql[i+1] == '/') {
				i++
			}
			if i+1 >= len(sql) {
				return nil, fmt.Errorf("unterminated comment")
			}
			if executable {
				return nil, fmt.Errorf("executable comments require force")
			}
			i += 2
			_ = start
			continue
		}
		if c == ';' {
			flush()
			out = append(out, ";")
			i++
			continue
		}
		if unicode.IsLetter(rune(c)) || unicode.IsDigit(rune(c)) || c == '_' || c == '$' {
			word.WriteByte(c)
			i++
			continue
		}
		flush()
		i++
	}
	flush()
	return out, nil
}

func Classify(sql string) Decision {
	t, err := Tokens(sql)
	if err != nil {
		return Decision{Reason: err.Error()}
	}
	if len(t) == 0 {
		return Decision{Reason: "empty statement"}
	}
	statements := 1
	for _, v := range t {
		if v == ";" {
			statements++
		}
	}
	// One optional terminal semicolon is accepted.
	if statements > 2 || (statements == 2 && t[len(t)-1] != ";") {
		return Decision{Reason: "multiple statements require force"}
	}
	if t[len(t)-1] == ";" {
		t = t[:len(t)-1]
	}
	if len(t) == 0 {
		return Decision{Reason: "empty statement"}
	}
	k := t[0]
	d := Decision{Keyword: k}
	lowerSQL := strings.ToLower(sql)
	if strings.Contains(lowerSQL, ":=") || strings.Contains(lowerSQL, "load_file(") {
		d.Reason = "session or filesystem side effect requires force"
		return d
	}
	switch k {
	case "select", "show", "describe", "desc":
		d.Allowed = true
		for _, v := range t {
			if v == "into" || v == "for" || v == "lock" {
				d.Allowed = false
				d.Reason = "side-effecting read form requires force"
				break
			}
		}
	case "explain":
		if len(t) > 1 && (t[1] == "select" || t[1] == "show" || t[1] == "describe" || t[1] == "desc") {
			d.Allowed = true
		} else {
			d.Reason = "writable or ambiguous EXPLAIN requires force"
		}
	default:
		d.Reason = strings.ToUpper(k) + " is not an unforced read"
	}
	return d
}

func Allow(sql string, force bool) Decision {
	d := Classify(sql)
	if force {
		d.Allowed = true
	}
	return d
}
