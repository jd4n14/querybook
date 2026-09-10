package main

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/jd4n14/querybook/internal/protocol"
	"github.com/jd4n14/querybook/internal/results"
	_ "modernc.org/sqlite"
)

func TestFullExportTerminalReportsStreamedRows(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "source.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("CREATE TABLE t (v INTEGER); WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 600) INSERT INTO t SELECT n FROM nums"); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	events := make(chan protocol.Event, 128)
	r := &runner{
		results:     results.New(results.Options{}),
		active:      map[string]context.CancelFunc{},
		exports:     map[string]context.CancelFunc{},
		exportOwner: map[string]string{},
		sendFn: func(e protocol.Event) error {
			events <- e
			return nil
		},
	}
	defer r.shutdown()
	conn := protocol.Connection{Driver: "sqlite", Name: "source", Path: dbPath}
	handle, err := r.results.Retain(results.Metadata{
		Columns:     []protocol.Column{{Name: "v", DatabaseType: "INTEGER"}},
		OriginalSQL: "SELECT v FROM t ORDER BY v",
		Connection:  conn,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	output := filepath.Join(dir, "full.csv")
	if err := r.startExport(protocol.Request{Version: 1, Type: "export", RequestID: "full", Handle: handle, Scope: "full", Format: "csv", ExportID: "full-rows", Path: output, StorePath: filepath.Join(dir, "connections.sqlite")}); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(10 * time.Second)
	for {
		select {
		case event := <-events:
			if !event.Terminal {
				continue
			}
			if event.Type == "error" {
				t.Fatalf("full export failed: %s", event.Message)
			}
			if event.RowCount != 600 {
				t.Fatalf("terminal row count=%d, want 600", event.RowCount)
			}
			return
		case <-deadline:
			t.Fatal("timed out waiting for full export terminal event")
		}
	}
}
