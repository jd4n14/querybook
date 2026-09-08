package executor

import "strings"

const autoLimitRows = 500

type sqlToken struct {
	text       string
	start, end int
	depth      int
}

// addAutoLimit returns a query with a protective outer LIMIT. It deliberately
// understands only the lexical structure needed for this decision. If the
// input is malformed or uses executable comments, it is returned unchanged so
// a display feature can never alter a query into invalid SQL.
func addAutoLimit(sql string) (string, bool) {
	tokens, semicolon, lastEnd, ok := lexSQL(sql)
	if !ok || len(tokens) == 0 {
		return sql, false
	}
	first := strings.ToLower(tokens[0].text)
	if first != "select" && first != "with" {
		return sql, false
	}
	if first == "with" {
		outer := ""
		for _, token := range tokens[1:] {
			switch strings.ToLower(token.text) {
			case "select", "insert", "update", "delete", "replace", "merge", "values":
				outer = strings.ToLower(token.text)
			}
			if outer != "" {
				break
			}
		}
		if outer != "select" {
			return sql, false
		}
	}
	if semicolon >= 0 {
		for _, token := range tokens {
			if token.start > semicolon {
				return sql, false
			}
		}
	}
	if hasTopLevelLimit(tokens) {
		return sql, false
	}
	for index, token := range tokens {
		word := strings.ToLower(token.text)
		next := ""
		if index+1 < len(tokens) {
			next = strings.ToLower(tokens[index+1].text)
		}
		switch word {
		case "fetch":
			if next == "first" || next == "next" {
				return sql, false
			}
		case "into":
			if next != "" && next != "from" {
				return sql, false
			}
		case "offset":
			if next != "" && isSQLNumber(next) {
				return sql, false
			}
		case "for":
			if next == "update" || next == "share" || next == "no" {
				return sql, false
			}
		case "lock":
			if next == "in" || next == "tables" {
				return sql, false
			}
		}
	}
	insertAt := len(sql)
	if semicolon >= 0 {
		insertAt = semicolon
	} else {
		// Insert before trailing comments/whitespace by using the final
		// final code token. This keeps a line comment from swallowing LIMIT and
		// keeps closing parentheses in their original position.
		insertAt = lastEnd
	}
	return sql[:insertAt] + " LIMIT 500" + sql[insertAt:], true
}

func lexSQL(sql string) ([]sqlToken, int, int, bool) {
	var tokens []sqlToken
	depth, semicolon, lastEnd := 0, -1, 0
	for i := 0; i < len(sql); {
		c := sql[i]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			i++
			continue
		}
		if c == '-' && i+1 < len(sql) && sql[i+1] == '-' && (i+2 >= len(sql) || sql[i+2] == ' ' || sql[i+2] == '\t' || sql[i+2] == '\r' || sql[i+2] == '\n') {
			i += 2
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if c == '#' {
			i++
			for i < len(sql) && sql[i] != '\n' {
				i++
			}
			continue
		}
		if c == '/' && i+1 < len(sql) && sql[i+1] == '*' {
			if i+2 < len(sql) && sql[i+2] == '!' {
				return nil, -1, 0, false
			}
			i += 2
			closed := false
			for i+1 < len(sql) {
				if sql[i] == '*' && sql[i+1] == '/' {
					i += 2
					closed = true
					break
				}
				i++
			}
			if !closed {
				return nil, -1, 0, false
			}
			continue
		}
		if c == '\'' || c == '"' || c == '`' {
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
				return nil, -1, 0, false
			}
			lastEnd = i
			continue
		}
		if c == '(' {
			depth++
			i++
			lastEnd = i
			continue
		}
		if c == ')' {
			if depth == 0 {
				return nil, -1, 0, false
			}
			depth--
			i++
			lastEnd = i
			continue
		}
		if c == ';' {
			if depth != 0 {
				return nil, -1, 0, false
			}
			if semicolon < 0 {
				semicolon = i
			}
			i++
			lastEnd = i
			continue
		}
		if isSQLWord(c) {
			start := i
			for i < len(sql) && isSQLWord(sql[i]) {
				i++
			}
			tokens = append(tokens, sqlToken{text: sql[start:i], start: start, end: i, depth: depth})
			lastEnd = i
			continue
		}
		i++
		lastEnd = i
	}
	if depth != 0 {
		return nil, -1, 0, false
	}
	var top []sqlToken
	for _, token := range tokens {
		if token.depth == 0 {
			top = append(top, token)
		}
	}
	return top, semicolon, lastEnd, true
}

func isSQLWord(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '$'
}

func isSQLNumber(value string) bool {
	if value == "" {
		return false
	}
	if value[0] == '-' {
		value = value[1:]
	}
	if value == "" {
		return false
	}
	for _, c := range value {
		if (c < '0' || c > '9') && c != '.' {
			return false
		}
	}
	return true
}

func hasTopLevelLimit(tokens []sqlToken) bool {
	for index, token := range tokens {
		if !strings.EqualFold(token.text, "limit") {
			continue
		}
		previousClause := false
		for _, previous := range tokens[:index] {
			switch strings.ToLower(previous.text) {
			case "from", "where", "group", "having", "order", "union", "intersect", "except":
				previousClause = true
			}
		}
		next := ""
		if index+1 < len(tokens) {
			next = strings.ToLower(tokens[index+1].text)
		}
		if previousClause || next == "all" {
			return true
		}
		if isSQLNumber(next) {
			looksLikeExpression := false
			for _, later := range tokens[index+2:] {
				if strings.EqualFold(later.text, "from") || strings.EqualFold(later.text, "where") {
					looksLikeExpression = true
					break
				}
			}
			if !looksLikeExpression {
				return true
			}
		}
	}
	return false
}
