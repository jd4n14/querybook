package results

import (
	"fmt"
	"strings"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/types"

	"github.com/jd4n14/querybook/internal/protocol"
)

// compiledFilter is a CEL row predicate. The expression is compiled once
// against the ResultSet column environment and then evaluated per retained
// row. The retained cells are never rewritten.
type compiledFilter struct {
	program cel.Program
	idents  map[string]struct{}
}

func compileFilter(source string, meta Metadata) (compiledFilter, error) {
	s := strings.TrimSpace(source)
	if s == "" {
		return compiledFilter{}, fmt.Errorf("invalid filter: empty CEL filter")
	}
	idents := uniqueColumnIdents(meta)
	opts := make([]cel.EnvOption, 0, len(idents)+4)
	opts = append(opts,
		cel.CrossTypeNumericComparisons(true),
		cel.Variable("row", cel.MapType(cel.StringType, cel.DynType)),
		cel.Variable("values", cel.ListType(cel.DynType)),
	)
	for name := range idents {
		opts = append(opts, cel.Variable(name, cel.DynType))
	}
	env, err := cel.NewEnv(opts...)
	if err != nil {
		return compiledFilter{}, fmt.Errorf("invalid filter: %s", err.Error())
	}
	ast, iss := env.Compile(s)
	if iss != nil && iss.Err() != nil {
		return compiledFilter{}, annotateCompileError(iss.Err(), meta)
	}
	out := ast.OutputType()
	if out != nil && !out.IsAssignableType(types.BoolType) && !out.IsAssignableType(types.DynType) {
		return compiledFilter{}, fmt.Errorf("invalid filter: CEL filter must evaluate to bool")
	}
	program, err := env.Program(ast, cel.EvalOptions(cel.OptOptimize))
	if err != nil {
		return compiledFilter{}, fmt.Errorf("invalid filter: %s", err.Error())
	}
	return compiledFilter{program: program, idents: idents}, nil
}

func annotateCompileError(err error, meta Metadata) error {
	msg := err.Error()
	counts := columnCounts(meta)
	for name, count := range counts {
		if count < 2 {
			continue
		}
		if strings.Contains(msg, "'"+name+"'") || strings.Contains(msg, "\""+name+"\"") {
			return fmt.Errorf("invalid filter: ambiguous column %q; use values[i] (0-based)", name)
		}
	}
	for _, col := range meta.Columns {
		if celIdentOK(col.Name) {
			continue
		}
		if strings.Contains(msg, col.Name) {
			return fmt.Errorf("invalid filter: column %q is not a CEL identifier; use row[%q]", col.Name, col.Name)
		}
	}
	return fmt.Errorf("invalid filter: %s", msg)
}

func (c compiledFilter) match(meta Metadata, row []protocol.Cell) (matched bool) {
	defer func() {
		if recover() != nil {
			matched = false
		}
	}()
	out, _, err := c.program.Eval(c.activation(meta, row))
	if err != nil || out == nil || types.IsError(out) {
		return false
	}
	b, ok := out.(types.Bool)
	return ok && b == types.True
}

func (c compiledFilter) activation(meta Metadata, row []protocol.Cell) map[string]any {
	bindings := make(map[string]any, len(c.idents)+2)
	counts := columnCounts(meta)
	for i, cell := range row {
		if i >= len(meta.Columns) {
			continue
		}
		name := meta.Columns[i].Name
		if _, ok := c.idents[name]; !ok {
			continue
		}
		bindings[name] = projectCell(meta, i, cell)
	}
	bindings["row"] = func() any { return eagerRowMap(meta, row, counts) }
	bindings["values"] = func() any { return eagerValues(meta, row) }
	return bindings
}

func eagerRowMap(meta Metadata, row []protocol.Cell, counts map[string]int) map[string]any {
	obj := make(map[string]any, len(meta.Columns))
	for i, cell := range row {
		if i >= len(meta.Columns) {
			continue
		}
		name := meta.Columns[i].Name
		if name == "" || counts[name] != 1 {
			continue
		}
		obj[name] = projectEager(meta, i, cell)
	}
	return obj
}

func eagerValues(meta Metadata, row []protocol.Cell) []any {
	values := make([]any, len(row))
	for i, cell := range row {
		values[i] = projectEager(meta, i, cell)
	}
	return values
}
