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
		{intCell("1749"), protocol.TextCell(`{"weight":0.5,"products":[{"id":1,"serviceId":10},{"id":2}]}`), protocol.NullCell(), boolCell("0"), protocol.TextCell("")},
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

func TestCELPositionalValues(t *testing.T) {
	meta := Metadata{Columns: []protocol.Column{{Name: "n", DatabaseType: "INTEGER"}}}
	if _, err := compileFilter("values[0] >= 11 && values[0] <= 19", meta); err != nil {
		t.Fatalf("compile: %v", err)
	}
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	rows := make([][]protocol.Cell, 20)
	for i := range rows {
		rows[i] = []protocol.Cell{intCell(strconv.Itoa(i))}
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	view, count, err := r.Filter(id, "values[0] >= 11 && values[0] <= 19")
	if err != nil || count != 9 {
		t.Fatalf("positional filter view=%s count=%d err=%v", view, count, err)
	}
}

func TestCELEqualityAndDirectColumn(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "client_id == 1749")
	if len(ordinals) != 2 || ordinals[0] != 0 || ordinals[1] != 1 {
		t.Fatalf("ordinals=%#v", ordinals)
	}
}

func TestCELInequality(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "client_id != 1749")
	if len(ordinals) != 2 || ordinals[0] != 2 || ordinals[1] != 3 {
		t.Fatalf("ordinals=%#v", ordinals)
	}
}

func TestCELComparisons(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, gt := filterOrdinals(t, r, id, "client_id > 1748")
	if len(gt) != 2 {
		t.Fatalf(">: %#v", gt)
	}
	_, gte := filterOrdinals(t, r, id, "client_id >= 1749")
	if len(gte) != 2 {
		t.Fatalf(">=: %#v", gte)
	}
	_, lt := filterOrdinals(t, r, id, "client_id < 1749")
	if len(lt) != 2 {
		t.Fatalf("<: %#v", lt)
	}
	_, lte := filterOrdinals(t, r, id, "client_id <= 0")
	if len(lte) != 1 || lte[0] != 3 {
		t.Fatalf("<=: %#v", lte)
	}
}

func TestCELLogicalAndOrNot(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, and := filterOrdinals(t, r, id, "client_id == 1749 && invoice_id == null")
	if len(and) != 2 || and[0] != 0 || and[1] != 1 {
		t.Fatalf("&&: %#v", and)
	}
	_, or := filterOrdinals(t, r, id, "client_id == 1748 || client_id == 0")
	if len(or) != 2 || or[0] != 2 || or[1] != 3 {
		t.Fatalf("||: %#v", or)
	}
	_, not := filterOrdinals(t, r, id, "!(client_id == 1749)")
	if len(not) != 2 {
		t.Fatalf("!: %#v", not)
	}
}

func TestCELInAndNotIn(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, in := filterOrdinals(t, r, id, "client_id in [1749, 0]")
	if len(in) != 3 || in[0] != 0 || in[1] != 1 || in[2] != 3 {
		t.Fatalf("in: %#v", in)
	}
	_, notIn := filterOrdinals(t, r, id, "!(client_id in [1749, 0])")
	if len(notIn) != 1 || notIn[0] != 2 {
		t.Fatalf("!(in): %#v", notIn)
	}
}

func TestCELNullEmptyZeroFalseAreDistinct(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, nulls := filterOrdinals(t, r, id, "invoice_id == null")
	if len(nulls) != 3 || nulls[0] != 0 || nulls[1] != 1 || nulls[2] != 3 {
		t.Fatalf("null ordinals=%#v", nulls)
	}
	_, empty := filterOrdinals(t, r, id, `note == ""`)
	if len(empty) != 1 || empty[0] != 0 {
		t.Fatalf("empty string ordinals=%#v", empty)
	}
	_, zero := filterOrdinals(t, r, id, "client_id == 0")
	if len(zero) != 1 || zero[0] != 3 {
		t.Fatalf("zero ordinals=%#v", zero)
	}
	_, flagFalse := filterOrdinals(t, r, id, "flag == false")
	if len(flagFalse) != 2 || flagFalse[0] != 0 || flagFalse[1] != 1 {
		t.Fatalf("false ordinals=%#v", flagFalse)
	}
	if _, zerosAsNull := filterOrdinals(t, r, id, "client_id == null"); len(zerosAsNull) != 0 {
		t.Fatalf("0 must not match null: %#v", zerosAsNull)
	}
	if _, emptyAsNull := filterOrdinals(t, r, id, "note == null"); len(emptyAsNull) != 0 {
		t.Fatalf("empty string must not match null: %#v", emptyAsNull)
	}
	if _, falseAsNull := filterOrdinals(t, r, id, "flag == null"); len(falseAsNull) != 0 {
		t.Fatalf("false must not match null: %#v", falseAsNull)
	}
}

func TestCELNoMatchesAndAllMatches(t *testing.T) {
	r, id, rows := retainBilling(t)
	_, none := filterOrdinals(t, r, id, "client_id == 999")
	if len(none) != 0 {
		t.Fatalf("no-match ordinals=%#v", none)
	}
	_, all := filterOrdinals(t, r, id, "client_id != null")
	if len(all) != len(rows) {
		t.Fatalf("all-match count=%d want %d", len(all), len(rows))
	}
}

func TestCELInvalidLeavesExistingView(t *testing.T) {
	r, id, _ := retainBilling(t)
	view, _ := filterOrdinals(t, r, id, "client_id == 1748")
	_, count, err := r.Filter(id, "client_id ==")
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
	if _, _, err := r.Filter(id, ""); err == nil {
		t.Fatal("empty filter accepted")
	}
	if _, _, err := r.Filter(id, "$[?(@.client_id == 1748)]"); err == nil {
		t.Fatal("JSONPath still accepted")
	}
}

func TestCELTypeErrorIsRowMiss(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, `client_id > "x"`)
	if len(ordinals) != 0 {
		t.Fatalf("type error should miss, not panic: %#v", ordinals)
	}
}

func TestCELPaginationAfterFilter(t *testing.T) {
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
	view, count, err := r.Filter(id, "n >= 20")
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

func TestCELDoesNotMutateRetainedRows(t *testing.T) {
	r, id, original := retainBilling(t)
	raw := original[0][1].Text
	if _, _, err := r.Filter(id, "data.weight > 0.4"); err != nil {
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

func TestCELInvalidNestedJSONDoesNotPanic(t *testing.T) {
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
	_, ordinals := filterOrdinals(t, r, id, "data.weight > 0.4")
	if len(ordinals) != 2 || ordinals[0] != 0 || ordinals[1] != 2 {
		t.Fatalf("invalid JSON should be a miss, not a panic: %#v", ordinals)
	}
	_, unused := filterOrdinals(t, r, id, "client_id == 1750")
	if len(unused) != 1 || unused[0] != 1 {
		t.Fatalf("unused invalid JSON column affected scalar filter: %#v", unused)
	}
}

func TestCELNestedJSONAndArrayIndex(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, nested := filterOrdinals(t, r, id, "client_id == 1749 && data.weight > 0.4 && invoice_id == null")
	if len(nested) != 1 || nested[0] != 0 {
		t.Fatalf("nested=%#v", nested)
	}
	_, idx := filterOrdinals(t, r, id, "data.products[0].id == 1")
	if len(idx) != 1 || idx[0] != 0 {
		t.Fatalf("array index=%#v", idx)
	}
	_, bracket := filterOrdinals(t, r, id, `data["weight"] == 0.5`)
	if len(bracket) != 1 || bracket[0] != 0 {
		t.Fatalf("bracket=%#v", bracket)
	}
}

func TestCELExistsMacro(t *testing.T) {
	r, id, _ := retainBilling(t)
	_, ordinals := filterOrdinals(t, r, id, "data.products.exists(p, p.serviceId == 10)")
	if len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("exists=%#v", ordinals)
	}
}

func TestCELMissingJSONProperty(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{{Name: "data", DatabaseType: "JSON"}}}
	rows := [][]protocol.Cell{
		{protocol.TextCell(`{"invoice_id": null}`)},
		{protocol.TextCell(`{"weight": 0.5}`)},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, jsonNull := filterOrdinals(t, r, id, "data.invoice_id == null")
	if len(jsonNull) != 1 || jsonNull[0] != 0 {
		t.Fatalf("JSON null key=%#v", jsonNull)
	}
	_, missingEqNull := filterOrdinals(t, r, id, "data.missing == null")
	if len(missingEqNull) != 0 {
		t.Fatalf("missing property is not JSON null: %#v", missingEqNull)
	}
	_, hasMissing := filterOrdinals(t, r, id, "!has(data.invoice_id)")
	if len(hasMissing) != 1 || hasMissing[0] != 1 {
		t.Fatalf("has() missing=%#v", hasMissing)
	}
}

func TestCELLazyJSONLeavesUnusedDocumentsRaw(t *testing.T) {
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
	if _, _, err := r.Filter(id, "client_id == 1749"); err != nil {
		t.Fatal(err)
	}
	snap, _ := r.Get(id)
	if snap.Rows[0][1].Text != raw {
		t.Fatalf("scalar filter rewrote JSON cell: %#v", snap.Rows[0][1])
	}
}

func TestCELDuplicateColumnNames(t *testing.T) {
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
	_, _, err = r.Filter(id, "id == 1")
	if err == nil || !strings.Contains(err.Error(), "ambiguous column") {
		t.Fatalf("ambiguous name err=%v", err)
	}
	_, ordinals := filterOrdinals(t, r, id, "values[1] == 2")
	if len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("positional duplicate access=%#v", ordinals)
	}
}

func TestCELInvalidIdentifierColumn(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{
		{Name: "order-id", DatabaseType: "INTEGER"},
		{Name: "in", DatabaseType: "INTEGER"},
	}}
	rows := [][]protocol.Cell{{intCell("7"), intCell("9")}}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, ordinals := filterOrdinals(t, r, id, `row["order-id"] == 7`)
	if len(ordinals) != 1 {
		t.Fatalf("invalid ident via row[]=%#v", ordinals)
	}
	_, reserved := filterOrdinals(t, r, id, `row["in"] == 9`)
	if len(reserved) != 1 {
		t.Fatalf("reserved ident via row[]=%#v", reserved)
	}
}

func TestCELConservativeTextJSONFallback(t *testing.T) {
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
	_, nested := filterOrdinals(t, r, id, "payload.weight > 0.4")
	if len(nested) != 1 || nested[0] != 0 {
		t.Fatalf("TEXT JSON fallback=%#v", nested)
	}
	_, scalar := filterOrdinals(t, r, id, `label == "keep"`)
	if len(scalar) != 2 {
		t.Fatalf("scalar text filter=%#v", scalar)
	}
}

func TestCELInt64LargeIntegerExact(t *testing.T) {
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
	_, ordinals := filterOrdinals(t, r, id, "id == 9007199254740993")
	if len(ordinals) != 1 || ordinals[0] != 1 {
		t.Fatalf("int64 compare should be exact beyond 2^53: %#v", ordinals)
	}
}

func TestCELDecimalExactVsIntAndDouble(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{{Name: "price", DatabaseType: "DECIMAL(10,2)"}}}
	rows := [][]protocol.Cell{
		{protocol.TextCell("10.50")},
		{protocol.TextCell("10.500")},
		{protocol.TextCell("9.99")},
		{protocol.TextCell("100.00")},
		{protocol.TextCell("10")},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, rangeOrds := filterOrdinals(t, r, id, "price >= 10.0 && price <= 20")
	if len(rangeOrds) != 3 || rangeOrds[0] != 0 || rangeOrds[1] != 1 || rangeOrds[2] != 4 {
		t.Fatalf("decimal range=%#v", rangeOrds)
	}
	_, eqInt := filterOrdinals(t, r, id, "price == 10")
	if len(eqInt) != 1 || eqInt[0] != 4 {
		t.Fatalf("decimal == int=%#v", eqInt)
	}
	_, exact := filterOrdinals(t, r, id, "price == 10.50")
	if len(exact) != 2 {
		t.Fatalf("10.50 and 10.500 are the same rational: %#v", exact)
	}
}

func TestCELCompileOnceEvaluateMany(t *testing.T) {
	meta := Metadata{Columns: []protocol.Column{{Name: "n", DatabaseType: "INTEGER"}}}
	compiled, err := compileFilter("n >= 11 && n <= 19", meta)
	if err != nil {
		t.Fatal(err)
	}
	matched := 0
	for i := 0; i < 20; i++ {
		if compiled.match(meta, []protocol.Cell{intCell(strconv.Itoa(i))}) {
			matched++
		}
	}
	if matched != 9 {
		t.Fatalf("compiled program reused across rows: matched=%d", matched)
	}
}

func TestCELStringContains(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{{Name: "status", DatabaseType: "TEXT"}}}
	rows := [][]protocol.Cell{
		{protocol.TextCell("completed")},
		{protocol.TextCell("cancelled")},
		{protocol.TextCell("in_progress")},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, contains := filterOrdinals(t, r, id, `status.contains("complete")`)
	if len(contains) != 1 || contains[0] != 0 {
		t.Fatalf("contains=%#v", contains)
	}
	_, ne := filterOrdinals(t, r, id, `status != "cancelled"`)
	if len(ne) != 2 {
		t.Fatalf("!= %#v", ne)
	}
}

func TestCELWarehouseStyleExamples(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	meta := Metadata{Columns: []protocol.Column{
		{Name: "warehouse_id", DatabaseType: "INTEGER"},
		{Name: "client_id", DatabaseType: "INTEGER"},
		{Name: "data", DatabaseType: "JSON"},
		{Name: "invoice_id", DatabaseType: "INTEGER"},
	}}
	rows := [][]protocol.Cell{
		{intCell("102"), intCell("1580"), protocol.TextCell(`{"weight":0.8,"products":[{"serviceId":10}]}`), protocol.NullCell()},
		{intCell("33"), intCell("87"), protocol.TextCell(`{"weight":0.2,"products":[]}`), intCell("1")},
		{intCell("9"), intCell("1580"), protocol.TextCell(`{"weight":1.2,"products":[{"serviceId":9}]}`), protocol.NullCell()},
	}
	id, err := r.Retain(meta, rows)
	if err != nil {
		t.Fatal(err)
	}
	_, warehouses := filterOrdinals(t, r, id, "warehouse_id in [33, 102]")
	if len(warehouses) != 2 || warehouses[0] != 0 || warehouses[1] != 1 {
		t.Fatalf("warehouse in=%#v", warehouses)
	}
	_, nested := filterOrdinals(t, r, id, "warehouse_id in [33, 102] && data.weight > 0.4")
	if len(nested) != 1 || nested[0] != 0 {
		t.Fatalf("warehouse+weight=%#v", nested)
	}
	_, invoices := filterOrdinals(t, r, id, "invoice_id == null")
	if len(invoices) != 2 || invoices[0] != 0 || invoices[1] != 2 {
		t.Fatalf("invoice null=%#v", invoices)
	}
	_, exists := filterOrdinals(t, r, id, "data.products.exists(p, p.serviceId == 10)")
	if len(exists) != 1 || exists[0] != 0 {
		t.Fatalf("exists serviceId=%#v", exists)
	}
}

func TestCELMultilineExpression(t *testing.T) {
	r, id, _ := retainBilling(t)
	expr := "client_id == 1749 &&\ndata.weight > 0.4 &&\ninvoice_id == null"
	_, rows := filterOrdinals(t, r, id, expr)
	if len(rows) != 1 || rows[0] != 0 {
		t.Fatalf("multiline=%#v", rows)
	}
}
