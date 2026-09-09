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
		{protocol.TextCell("9007199254740992"), protocol.TextCell("empty"), protocol.TextCell("0"), protocol.BinaryCell([]byte{0})},
		{protocol.TextCell("9007199254740993"), protocol.TextCell("zero"), protocol.TextCell("false"), protocol.BinaryCell([]byte{1})},
		{protocol.NullCell(), protocol.TextCell("NULL"), protocol.TextCell("1"), protocol.BinaryCell([]byte{2})},
	}
	id, err := r.Retain(m, rows)
	if err != nil {
		t.Fatal(err)
	}
	view, count, err := r.Filter(id, "@.id == 9007199254740993")
	if err != nil || count != 1 {
		t.Fatalf("exact filter view=%s count=%d err=%v", view, count, err)
	}
	_, ordinals, err := r.PageView(id, view, 0, 10)
	if err != nil || len(ordinals) != 1 || ordinals[0] != 1 {
		t.Fatalf("exact filter ordinals=%#v err=%v", ordinals, err)
	}
	view, count, err = r.Filter(id, "@['$values'][0] == null")
	if err != nil || count != 1 {
		t.Fatalf("SQL null filter view=%s count=%d err=%v", view, count, err)
	}
	_, ordinals, _ = r.PageView(id, view, 0, 10)
	if len(ordinals) != 1 || ordinals[0] != 2 {
		t.Fatalf("SQL null ordinals=%#v", ordinals)
	}
	if _, _, err = r.Filter(id, "@.missing == 1"); err == nil {
		t.Fatal("unknown named column accepted")
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
	if _, _, err = r.Filter(id, "@.missing == 1"); err == nil {
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
