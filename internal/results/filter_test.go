package results

import (
	"strconv"
	"strings"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
)

func billingMeta() Metadata {
	return Metadata{Columns: []protocol.Column{
		{Name: "client_id", DatabaseType: "INTEGER"},
		{Name: "data", DatabaseType: "JSON"},
		{Name: "invoice_id", DatabaseType: "INTEGER"},
		{Name: "flag", DatabaseType: "BOOLEAN"},
		{Name: "note", DatabaseType: "TEXT"},
	}}
}

func billingRows() [][]protocol.Cell {
	return [][]protocol.Cell{
		{intCell("1749"), protocol.TextCell(`{"weight":0.5,"products":[{"id":1},{"id":2}]}`), protocol.NullCell(), boolCell("0"), protocol.TextCell("")},
		{intCell("1749"), protocol.TextCell(`{"weight":0.2,"products":[{"id":3}]}`), protocol.NullCell(), boolCell("false"), protocol.TextCell("0")},
		{intCell("1748"), protocol.TextCell(`{"weight":0.9,"products":[]}`), intCell("10"), boolCell("1"), protocol.TextCell("false")},
		{intCell("0"), protocol.TextCell(`{"weight":0,"products":[{"id":9}]}`), protocol.NullCell(), boolCell("true"), protocol.TextCell("NULL")},
	}
}

func intCell(v string) protocol.Cell {
	c := protocol.TextCell(v)
	c.ValueKind = "integer"
	return c
}

func boolCell(v string) protocol.Cell {
	c := protocol.TextCell(v)
	c.ValueKind = "boolean"
	return c
}

func retainBilling(t *testing.T) (*Registry, string, [][]protocol.Cell) {
	t.Helper()
	rows := billingRows()
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	id, err := r.Retain(billingMeta(), rows)
	if err != nil {
		t.Fatal(err)
	}
	return r, id, rows
}

func filterOrdinals(t *testing.T, r *Registry, id, expr string) (string, []int) {
	t.Helper()
	view, count, err := r.Filter(id, expr)
	if err != nil {
		t.Fatalf("filter %q: %v", expr, err)
	}
	_, ordinals, err := r.PageView(id, view, 0, 100)
	if err != nil {
		t.Fatalf("page view %q: %v", expr, err)
	}
	if len(ordinals) != count {
		t.Fatalf("filter %q count=%d ordinals=%d", expr, count, len(ordinals))
	}
	return view, ordinals
}

func TestJSONPathPositionalValuesShorthand(t *testing.T) {
	if _, err := compileFilter("@['$values'][0] >= 11 && @['$values'][0] <= 19"); err != nil {
		t.Fatalf("compile: %v", err)
	}
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{{Name: "n", DatabaseType: "INTEGER"}}}
	rows := make([][]protocol.Cell, 20)
	for i := range rows {
		rows[i] = []protocol.Cell{intCell(strconv.Itoa(i))}
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	view, count, err := r.Filter(id, "@['$values'][0] >= 11 && @['$values'][0] <= 19")
	if err != nil || count != 9 {
		t.Fatalf("positional filter view=%s count=%d err=%v", view, count, err)
	}
}

func TestJSONPathSimpleClientID(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "@.client_id == 1749")
	if len(ordinals) != 2 || ordinals[0] != 0 || ordinals[1] != 1 {
		t.Fatalf("ordinals=%#v", ordinals)
	}
}

func TestJSONPathMultipleConditionsAndNull(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "@.client_id == 1749 && @.invoice_id == null")
	if len(ordinals) != 2 || ordinals[0] != 0 || ordinals[1] != 1 {
		t.Fatalf("ordinals=%#v", ordinals)
	}
}

func TestJSONPathNestedWeight(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "@.client_id == 1749 && @.data.weight > 0.4 && @.invoice_id == null")
	if len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("ordinals=%#v", ordinals)
	}
}

func TestJSONPathArrayIndex(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "@.data.products[0].id == 1")
	if len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("ordinals=%#v", ordinals)
	}
}

func TestJSONPathSQLNullEmptyZeroFalseAreDistinct(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, nulls := filterOrdinals(t, r, id, "@.invoice_id == null")
	if len(nulls) != 3 || nulls[0] != 0 || nulls[1] != 1 || nulls[2] != 3 {
		t.Fatalf("null ordinals=%#v", nulls)
	}
	_, empty := filterOrdinals(t, r, id, `@.note == ""`)
	if len(empty) != 1 || empty[0] != 0 {
		t.Fatalf("empty string ordinals=%#v", empty)
	}
	_, zero := filterOrdinals(t, r, id, "@.client_id == 0")
	if len(zero) != 1 || zero[0] != 3 {
		t.Fatalf("zero ordinals=%#v", zero)
	}
	_, flagFalse := filterOrdinals(t, r, id, "@.flag == false")
	if len(flagFalse) != 2 || flagFalse[0] != 0 || flagFalse[1] != 1 {
		t.Fatalf("false ordinals=%#v", flagFalse)
	}
	if _, zerosAsNull := filterOrdinals(t, r, id, "@.client_id == null"); len(zerosAsNull) != 0 {
		t.Fatalf("0 must not match null: %#v", zerosAsNull)
	}
	if _, emptyAsNull := filterOrdinals(t, r, id, "@.note == null"); len(emptyAsNull) != 0 {
		t.Fatalf("empty string must not match null: %#v", emptyAsNull)
	}
	if _, falseAsNull := filterOrdinals(t, r, id, "@.flag == null"); len(falseAsNull) != 0 {
		t.Fatalf("false must not match null: %#v", falseAsNull)
	}
}

func TestJSONPathNoMatchesAndAllMatches(t *testing.T) {
	r, id, rows := retainBilling(t)
	_, none := filterOrdinals(t, r, id, "@.client_id == 999")
	if len(none) != 0 {
		t.Fatalf("no-match ordinals=%#v", none)
	}
	_, all := filterOrdinals(t, r, id, "@.client_id != null")
	if len(all) != len(rows) {
		t.Fatalf("all-match count=%d want %d", len(all), len(rows))
	}
}

func TestJSONPathInvalidLeavesExistingView(t *testing.T) {
	r, id, _ := retainBilling(t)
	view, _ := filterOrdinals(t, r, id, "@.client_id == 1748")
	_, count, err := r.Filter(id, "@.client_id === 1748")
	if err == nil || !strings.Contains(err.Error(), "invalid filter") || count != 0 {
		t.Fatalf("invalid filter err=%v count=%d", err, count)
	}
	_, ordinals, err := r.PageView(id, view, 0, 10)
	if err != nil || len(ordinals) != 1 || ordinals[0] != 2 {
		t.Fatalf("previous view lost: %#v err=%v", ordinals, err)
	}
	if _, _, err := r.Filter(id, "client_id = 1749"); err == nil {
		t.Fatal("pseudo-SQL accepted")
	}
	if _, _, err := r.Filter(id, "$.client_id"); err == nil {
		t.Fatal("non-filter JSONPath accepted")
	}
}

func TestJSONPathPaginationAfterFilter(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{{Name: "n", DatabaseType: "INTEGER"}}}
	rows := make([][]protocol.Cell, 40)
	for i := range rows {
		rows[i] = []protocol.Cell{intCell(strconv.Itoa(i))}
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	view, count, err := r.Filter(id, "@.n >= 20")
	if err != nil || count != 20 {
		t.Fatalf("count=%d err=%v", count, err)
	}
	page1, ords1, err := r.PageView(id, view, 0, 10)
	if err != nil || len(page1.Rows) != 10 || len(ords1) != 10 || ords1[0] != 20 || ords1[9] != 29 {
		t.Fatalf("page1 rows=%d ordinals=%#v err=%v", len(page1.Rows), ords1, err)
	}
	if page1.TotalRows != 20 {
		t.Fatalf("page total=%d", page1.TotalRows)
	}
	page2, ords2, err := r.PageView(id, view, 10, 10)
	if err != nil || len(page2.Rows) != 10 || ords2[0] != 30 || ords2[9] != 39 {
		t.Fatalf("page2 ordinals=%#v err=%v", ords2, err)
	}
	unfiltered, all, err := r.Page(id, 0, 10)
	if err != nil || len(unfiltered.Rows) != 10 || all[0] != 0 || unfiltered.TotalRows != 40 {
		t.Fatalf("clear/original page=%#v err=%v", all, err)
	}
}

func TestJSONPathDoesNotMutateRetainedRows(t *testing.T) {
	r, id, original := retainBilling(t)
	raw := original[0][1].Text
	if _, _, err := r.Filter(id, "@.data.weight > 0.4"); err != nil {
		t.Fatal(err)
	}
	snap, err := r.Get(id)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Rows[0][1].Text != raw || snap.Rows[0][1].Kind != "text" {
		t.Fatalf("retained JSON was rewritten: %#v", snap.Rows[0][1])
	}
	if snap.Rows[0][2].Kind != "null" {
		t.Fatalf("retained NULL was rewritten: %#v", snap.Rows[0][2])
	}
}

func TestJSONPathInvalidNestedJSONDoesNotPanic(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{
		{Name: "client_id", DatabaseType: "INTEGER"},
		{Name: "data", DatabaseType: "JSON"},
	}}
	rows := [][]protocol.Cell{
		{intCell("1749"), protocol.TextCell(`{"weight":0.5}`)},
		{intCell("1750"), protocol.TextCell(`{not-json`)},
		{intCell("1751"), protocol.TextCell(`{"weight":0.9}`)},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, ordinals := filterOrdinals(t, r, id, "@.data.weight > 0.4")
	if len(ordinals) != 2 || ordinals[0] != 0 || ordinals[1] != 2 {
		t.Fatalf("invalid JSON should be a miss, not a panic: %#v", ordinals)
	}
	_, unused := filterOrdinals(t, r, id, "@.client_id == 1750")
	if len(unused) != 1 || unused[0] != 1 {
		t.Fatalf("unused invalid JSON column affected scalar filter: %#v", unused)
	}
}

func TestJSONPathFullFormAndShorthand(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, short := filterOrdinals(t, r, id, "@.client_id == 1748")
	_, full := filterOrdinals(t, r, id, "$[?(@.client_id == 1748)]")
	if len(short) != 1 || len(full) != 1 || short[0] != full[0] {
		t.Fatalf("shorthand=%#v full=%#v", short, full)
	}
	multiline := "@.client_id == 1749 &&\n@.data.weight > 0.4 &&\n@.invoice_id == null"
	_, rows := filterOrdinals(t, r, id, multiline)
	if len(rows) != 1 || rows[0] != 0 {
		t.Fatalf("multiline shorthand=%#v", rows)
	}
}

func TestJSONPathLazyJSONLeavesUnusedDocumentsRaw(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{
		{Name: "client_id", DatabaseType: "INTEGER"},
		{Name: "data", DatabaseType: "JSON"},
	}}
	raw := `{"weight":0.5}`
	rows := [][]protocol.Cell{{intCell("1749"), protocol.TextCell(raw)}}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := r.Filter(id, "@.client_id == 1749"); err != nil {
		t.Fatal(err)
	}
	snap, _ := r.Get(id)
	if snap.Rows[0][1].Text != raw {
		t.Fatalf("scalar filter rewrote JSON cell: %#v", snap.Rows[0][1])
	}
}

func TestJSONPathDuplicateColumnNames(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{
		{Name: "id", DatabaseType: "INTEGER"},
		{Name: "id", DatabaseType: "INTEGER"},
	}}
	rows := [][]protocol.Cell{{intCell("1"), intCell("2")}}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := r.Filter(id, "@.id == 1"); err == nil {
		t.Fatal("ambiguous name accepted")
	}
	_, ordinals := filterOrdinals(t, r, id, "@['$values'][1] == 2")
	if len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("positional duplicate access=%#v", ordinals)
	}
}

func TestJSONPathConservativeTextJSONFallback(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{
		{Name: "payload", DatabaseType: "TEXT"},
		{Name: "label", DatabaseType: "TEXT"},
	}}
	rows := [][]protocol.Cell{
		{protocol.TextCell(`{"weight":0.5}`), protocol.TextCell("keep")},
		{protocol.TextCell("not-json"), protocol.TextCell("keep")},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, nested := filterOrdinals(t, r, id, "@.payload.weight > 0.4")
	if len(nested) != 1 || nested[0] != 0 {
		t.Fatalf("TEXT JSON fallback=%#v", nested)
	}
	_, scalar := filterOrdinals(t, r, id, `@.label == "keep"`)
	if len(scalar) != 2 {
		t.Fatalf("scalar text filter=%#v", scalar)
	}
}

func TestJSONPathIEEE754LargeIntegerLimitation(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{{Name: "id", DatabaseType: "BIGINT"}}}
	rows := [][]protocol.Cell{
		{intCell("9007199254740992")},
		{intCell("9007199254740993")},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, ordinals := filterOrdinals(t, r, id, "@.id == 9007199254740993")
	if len(ordinals) != 2 {
		t.Fatalf("theory/jsonpath compares numbers as float64; both >2^53 integers should collide: %#v", ordinals)
	}
}
