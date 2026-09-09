package export

import (
	"bufio"
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jd4n14/querybook/internal/protocol"
)

func testColumns() []protocol.Column {
	return []protocol.Column{{Name: "dup", DatabaseType: "TEXT"}, {Name: "dup", DatabaseType: "BLOB"}, {Name: "nullable", DatabaseType: "TEXT"}}
}

func TestCSVIsOrderedAndReversible(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rows.csv")
	rows := [][]protocol.Cell{{protocol.TextCell(`a,b`), protocol.BinaryCell([]byte{0, 0xff}), protocol.NullCell()}, {protocol.TextCell(`\N`), protocol.TextCell(""), protocol.TextCell(`slash\\value`)}}
	stats, err := ExportCurrent(context.Background(), path, testColumns(), rows, Options{Format: CSV})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Rows != 2 || stats.BytesWritten == 0 {
		t.Fatalf("stats=%+v", stats)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	records, err := csv.NewReader(f).ReadAll()
	_ = f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 3 || records[0][0] != "dup" || records[0][1] != "dup" {
		t.Fatalf("records=%#v", records)
	}
	if records[1][0] != "a,b" || records[1][1] != `\B`+"AP8=" || records[1][2] != `\N` {
		// Check the binary marker separately below; this branch gives a useful
		// failure if the familiar CSV reader changes quoting behavior.
		t.Fatalf("first row=%#v", records[1])
	}
	if records[2][0] != `\\N` || records[2][1] != "" || records[2][2] != `slash\\\\value` {
		t.Fatalf("escaped row=%#v", records[2])
	}
}

func TestJSONLIncludesTypedPositionalSchemaOnEveryRow(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rows.jsonl")
	_, err := ExportCurrent(context.Background(), path, testColumns(), [][]protocol.Cell{{protocol.TextCell("x"), protocol.BinaryCell([]byte{1}), protocol.NullCell()}}, Options{Format: JSONL})
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s := bufio.NewScanner(f)
	var record struct {
		Columns []protocol.Column `json:"columns"`
		Cells   []protocol.Cell   `json:"cells"`
	}
	if !s.Scan() || json.Unmarshal(s.Bytes(), &record) != nil {
		t.Fatalf("invalid JSONL: %q", s.Bytes())
	}
	_ = f.Close()
	if len(record.Columns) != 3 || len(record.Cells) != 3 || record.Columns[0].Name != "dup" || record.Columns[1].Name != "dup" {
		t.Fatalf("record=%+v", record)
	}
	if record.Cells[1].Kind != "binary" || record.Cells[2].Kind != "null" {
		t.Fatalf("cells=%+v", record.Cells)
	}
}

func TestJSONLZeroRowsStillCarriesSchema(t *testing.T) {
	path := filepath.Join(t.TempDir(), "empty.jsonl")
	if _, err := ExportCurrent(context.Background(), path, testColumns(), nil, Options{Format: JSONL}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"schema":true`) || !strings.Contains(string(b), `"cells":null`) {
		t.Fatalf("schema record=%s", b)
	}
}

func TestCancelLeavesNoPartialOutputAndExistingUntouched(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cancel.csv")
	ctx, cancel := context.WithCancel(context.Background())
	rows := make([][]protocol.Cell, 20)
	for i := range rows {
		rows[i] = []protocol.Cell{protocol.TextCell("row")}
	}
	_, err := ExportCurrent(ctx, path, []protocol.Column{{Name: "v"}}, rows, Options{Format: CSV, ProgressRows: 1, Progress: func(p Progress) error {
		if p.Rows == 2 {
			cancel()
		}
		return nil
	}})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err=%v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("partial output exists: %v", statErr)
	}
	existing := filepath.Join(dir, "existing.csv")
	if err := os.WriteFile(existing, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := ExportCurrent(context.Background(), existing, []protocol.Column{{Name: "v"}}, rows[:1], Options{Format: CSV}); !errors.Is(err, ErrDestinationExists) {
		t.Fatalf("overwrite err=%v", err)
	}
	b, _ := os.ReadFile(existing)
	if string(b) != "keep" {
		t.Fatalf("existing changed: %q", b)
	}
}

func TestSourceErrorLeavesNoPartialOutput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "error.csv")
	source := &errorSource{}
	_, err := ExportRows(context.Background(), path, []protocol.Column{{Name: "v"}}, source, Options{Format: CSV})
	if !errors.Is(err, errSource) {
		t.Fatalf("err=%v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("partial output exists: %v", statErr)
	}
}

func TestExportStreamPublishesOnlyAfterRunnerCompletes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stream.csv")
	stats, err := ExportStream(context.Background(), path, Options{Format: CSV}, func(callbacks StreamCallbacks) error {
		if err := callbacks.Schema([]protocol.Column{{Name: "v"}}); err != nil {
			return err
		}
		if err := callbacks.Row(context.Background(), []protocol.Cell{protocol.TextCell("one")}); err != nil {
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if stats.Rows != 1 {
		t.Fatalf("stats=%+v", stats)
	}
	if b, err := os.ReadFile(path); err != nil || !strings.Contains(string(b), "one") {
		t.Fatalf("output=%q err=%v", b, err)
	}
}

func TestExportStreamRunnerFailureRemovesTemporaryFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stream.csv")
	_, err := ExportStream(context.Background(), path, Options{Format: CSV}, func(callbacks StreamCallbacks) error {
		if err := callbacks.Schema([]protocol.Column{{Name: "v"}}); err != nil {
			return err
		}
		return errSource
	})
	if !errors.Is(err, errSource) {
		t.Fatalf("err=%v", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("output exists: %v", statErr)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 0 {
		t.Fatalf("temporary files remain: %#v", entries)
	}
}

var errSource = errors.New("source failed")

type errorSource struct{ done bool }

func (s *errorSource) Next() ([]protocol.Cell, error) {
	if s.done {
		return nil, errSource
	}
	s.done = true
	return []protocol.Cell{protocol.TextCell("first")}, nil
}

func BenchmarkExportRowsStreaming(b *testing.B) {
	columns := []protocol.Column{{Name: "a"}, {Name: "b"}}
	rows := make([][]protocol.Cell, 10000)
	for i := range rows {
		rows[i] = []protocol.Cell{protocol.TextCell("value"), protocol.TextCell("value")}
	}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		path := filepath.Join(b.TempDir(), "rows.csv")
		if _, err := ExportCurrent(context.Background(), path, columns, rows, Options{Format: CSV}); err != nil && !errors.Is(err, io.EOF) {
			b.Fatal(err)
		}
	}
}
