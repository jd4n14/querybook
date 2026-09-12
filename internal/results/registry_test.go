package results

import (
	"errors"
	"sync"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
)

func testMeta() Metadata {
	n := false
	return Metadata{Columns: []protocol.Column{{Name: "id", DatabaseType: "INTEGER", Nullable: &n}, {Name: "payload", DatabaseType: "TEXT"}}, OriginalSQL: "SELECT id,payload FROM t", ExecutedSQL: "SELECT id,payload FROM t LIMIT 500", ConnectionID: "conn-1", ResultSets: 1}
}

func testRows() [][]protocol.Cell {
	return [][]protocol.Cell{{protocol.TextCell("9007199254740993"), protocol.TextCell("first")}, {protocol.NullCell(), protocol.BinaryCell([]byte{1, 2})}}
}

func TestRetainCopiesAndPageDoesNotExposeRows(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 2})
	rows := testRows()
	id, err := r.Retain(testMeta(), rows)
	if err != nil {
		t.Fatal(err)
	}
	rows[0][0].Text = "mutated-input"
	s, err := r.Get(id)
	if err != nil {
		t.Fatal(err)
	}
	s.Rows[0][0].Text = "mutated-output"
	p, ords, err := r.Page(id, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Rows) != 1 || len(ords) != 1 || ords[0] != 1 || p.Rows[0][0].Kind != "null" {
		t.Fatalf("page=%#v ordinals=%#v", p.Rows, ords)
	}
	check, _ := r.Get(id)
	if check.Rows[0][0].Text != "9007199254740993" {
		t.Fatalf("retained row was mutable: %#v", check.Rows)
	}
}

func TestCapacityRejectsWithoutEviction(t *testing.T) {
	r := New(Options{MaxBytes: 5000, MaxSets: 1})
	a, err := r.Retain(testMeta(), testRows())
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Pin(a); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Retain(testMeta(), testRows()); err != ErrCapacity {
		t.Fatalf("capacity error=%v", err)
	}
	if _, err := r.Get(a); err != nil {
		t.Fatalf("existing pinned set was evicted: %v", err)
	}
}

func TestReleaseAndClearLifecycle(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 3})
	a, _ := r.Retain(testMeta(), testRows())
	if err := r.Release(a); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(a); err != ErrNotFound {
		t.Fatalf("released handle=%v", err)
	}
	b, _ := r.Retain(testMeta(), testRows())
	r.Clear()
	if _, err := r.Get(b); err != ErrNotFound {
		t.Fatalf("cleared handle=%v", err)
	}
}

func TestDuplicateColumnNamesAreAmbiguous(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	m := testMeta()
	m.Columns[1].Name = "id"
	id, err := r.Retain(m, testRows())
	if err != nil {
		t.Fatal(err)
	}
	s, _ := r.Get(id)
	if _, err := s.ColumnIndex("id"); err == nil || !errors.Is(err, ErrAmbiguousName) {
		t.Fatalf("duplicate lookup=%v", err)
	}
}

func TestConcurrentReadsAndRelease(t *testing.T) {
	r := New(Options{MaxBytes: 8 << 20, MaxSets: 32})
	id, err := r.Retain(testMeta(), testRows())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 20; j++ {
				_, _, _ = r.Page(id, 0, 1)
			}
		}()
	}
	wg.Wait()
	if err := r.Release(id); err != nil {
		t.Fatal(err)
	}
}

func TestExactNumericFilterAndNullBinaryDistinctions(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	n := false
	m := Metadata{Columns: []protocol.Column{
		{Name: "id", DatabaseType: "BIGINT", Nullable: &n},
		{Name: "label", DatabaseType: "TEXT"},
		{Name: "flag", DatabaseType: "BOOLEAN"},
		{Name: "blob", DatabaseType: "BLOB"},
	}}
	rows := [][]protocol.Cell{
		{protocol.TextCell("1749"), protocol.TextCell("empty"), protocol.TextCell("0"), protocol.BinaryCell([]byte{0})},
		{protocol.TextCell("1750"), protocol.TextCell("zero"), protocol.TextCell("false"), protocol.BinaryCell([]byte{1})},
		{protocol.NullCell(), protocol.TextCell("NULL"), protocol.TextCell("1"), protocol.BinaryCell([]byte{2})},
	}
	id, err := r.Retain(m, rows)
	if err != nil {
		t.Fatal(err)
	}
	view, count, err := r.Filter(id, "@.id == 1750")
	if err != nil || count != 1 {
		t.Fatalf("numeric filter view=%s count=%d err=%v", view, count, err)
	}
	_, ordinals, err := r.PageView(id, view, 0, 10)
	if err != nil || len(ordinals) != 1 || ordinals[0] != 1 {
		t.Fatalf("numeric filter ordinals=%#v err=%v", ordinals, err)
	}
	view, count, err = r.Filter(id, "@['$values'][0] == null")
	if err != nil || count != 1 {
		t.Fatalf("SQL null filter view=%s count=%d err=%v", view, count, err)
	}
	_, ordinals, _ = r.PageView(id, view, 0, 10)
	if len(ordinals) != 1 || ordinals[0] != 2 {
		t.Fatalf("SQL null ordinals=%#v", ordinals)
	}
	view, count, err = r.Filter(id, "@.flag == false")
	if err != nil || count != 2 {
		t.Fatalf("boolean filter view=%s count=%d err=%v", view, count, err)
	}
	_, ordinals, _ = r.PageView(id, view, 0, 10)
	if len(ordinals) != 2 || ordinals[0] != 0 || ordinals[1] != 1 {
		t.Fatalf("boolean ordinals=%#v", ordinals)
	}
	view, count, err = r.Filter(id, "@.missing == 1")
	if err != nil || count != 0 {
		t.Fatalf("missing property should be a JSONPath miss, not a compile error: view=%s count=%d err=%v", view, count, err)
	}
}

func TestNestedJSONPathAndGroupedPredicates(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	m := Metadata{Columns: []protocol.Column{{Name: "client_id", DatabaseType: "INTEGER"}, {Name: "data", DatabaseType: "JSON"}, {Name: "invoice_id", DatabaseType: "INTEGER"}}}
	rows := [][]protocol.Cell{
		{protocol.TextCell("1749"), protocol.TextCell(`{"weight":0.5,"state":"ready"}`), protocol.NullCell()},
		{protocol.TextCell("1749"), protocol.TextCell(`{"weight":0.2,"state":"ready"}`), protocol.NullCell()},
		{protocol.TextCell("1748"), protocol.TextCell(`{"weight":0.9,"state":"ready"}`), protocol.NullCell()},
	}
	id, err := r.Retain(m, rows)
	if err != nil {
		t.Fatal(err)
	}
	view, count, err := r.Filter(id, "@.client_id == 1749 && @.data.weight > 0.4 && @.invoice_id == null")
	if err != nil || count != 1 {
		t.Fatalf("nested filter view=%s count=%d err=%v", view, count, err)
	}
	_, ordinals, _ := r.PageView(id, view, 0, 10)
	if len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("nested ordinals=%#v", ordinals)
	}
	view, count, err = r.Filter(id, "$[?((@.client_id == 1749 || @.client_id == 1748) && @.data.weight > 0.8)]")
	if err != nil || count != 1 {
		t.Fatalf("grouped filter view=%s count=%d err=%v", view, count, err)
	}
	view, count, err = r.Filter(id, `@.data['weight'] == 0.5`)
	if err != nil || count != 1 {
		t.Fatalf("bracket nested filter view=%s count=%d err=%v", view, count, err)
	}
}

func TestFailedFilterLeavesExistingView(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	m := testMeta()
	id, _ := r.Retain(m, testRows())
	view, _, err := r.Filter(id, "@.id == 9007199254740993")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = r.Filter(id, "@.id === 1"); err == nil {
		t.Fatal("failed filter accepted")
	}
	_, ordinals, err := r.PageView(id, view, 0, 10)
	if err != nil || len(ordinals) != 1 || ordinals[0] != 0 {
		t.Fatalf("existing view changed ordinals=%#v err=%v", ordinals, err)
	}
}

func TestCompareRowsUsesExactJSONAndKeepsRawCells(t *testing.T) {
	r := New(Options{MaxBytes: 1 << 20, MaxSets: 1})
	m := Metadata{Columns: []protocol.Column{{Name: "doc", DatabaseType: "JSON"}, {Name: "raw", DatabaseType: "TEXT"}}}
	rows := [][]protocol.Cell{
		{protocol.TextCell(`{"n":9007199254740993,"same":null}`), protocol.NullCell()},
		{protocol.TextCell(`{"n":9007199254740992,"same":null,"added":true}`), protocol.TextCell("null")},
	}
	id, err := r.Retain(m, rows)
	if err != nil {
		t.Fatal(err)
	}
	changes, err := r.CompareRows(id, 0, 1)
	if err != nil || len(changes) != 3 {
		t.Fatalf("changes=%#v err=%v", changes, err)
	}
	if changes[0].Path != "$.added" && changes[0].Path != "$.n" {
		t.Fatalf("paths=%#v", changes)
	}
	for _, change := range changes {
		if change.Before == nil || change.After == nil {
			t.Fatal("raw cells omitted")
		}
	}
}

func TestCellTreePreservesLargeNumberLexeme(t *testing.T) {
	tree := CellTree(protocol.TextCell(`{"n":900719925474099312345,"empty":"","zero":0,"false":false}`))
	if tree == nil || tree.Type != "object" || len(tree.Children) != 4 {
		t.Fatalf("tree=%#v", tree)
	}
	found := false
	for _, child := range tree.Children {
		if child.Key != nil && child.Key.Raw == `"n"` {
			found = child.Node.Type == "number" && child.Node.Raw == "900719925474099312345"
		}
	}
	if !found {
		t.Fatalf("large number lexeme was normalized: %#v", tree)
	}
	if raw := CellTree(protocol.TextCell("not-json")); raw == nil || raw.Type != "raw" || raw.Raw != "not-json" {
		t.Fatalf("invalid JSON fallback=%#v", raw)
	}
	nested := CellTreeAt(protocol.TextCell(`{"data":{"weight":0.4,"items":[{"id":900719925474099312345}]}}`), "$.data.items[0]", 4, 1024)
	if nested == nil || nested.Type != "object" || len(nested.Children) != 1 || nested.Children[0].Node.Raw != "900719925474099312345" {
		t.Fatalf("nested tree=%#v", nested)
	}
	shallow := CellTreeAt(protocol.TextCell(`{"a":{"b":{"c":1}}}`), "", 1, 1024)
	if shallow == nil || shallow.Type != "object" || len(shallow.Children) != 0 {
		t.Fatalf("depth budget ignored=%#v", shallow)
	}
}
