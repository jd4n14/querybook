// Package protocol contains the versioned JSONL protocol shared by Querybook
// and its child runner. IDs are deliberately strings: Lua and JSON numbers
// must never be used for request correlation.
package protocol

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const Version = 1

var ErrUnsupportedVersion = errors.New("unsupported protocol version")

type Request struct {
	Version          int        `json:"version"`
	Type             string     `json:"type"`
	RequestID        string     `json:"request_id,omitempty"`
	ExecutionID      string     `json:"execution_id,omitempty"`
	Generation       int64      `json:"generation,omitempty"`
	Connection       Connection `json:"connection,omitempty"`
	ConnectionID     string     `json:"connection_id,omitempty"`
	StorePath        string     `json:"store_path,omitempty"`
	Op               string     `json:"op,omitempty"`
	Password         *string    `json:"password,omitempty"`
	SQL              string     `json:"sql,omitempty"`
	Force            bool       `json:"force,omitempty"`
	TimeoutMS        int        `json:"timeout_ms,omitempty"`
	MaxRetainedRows  int        `json:"max_retained_rows,omitempty"`
	MaxRetainedBytes int64      `json:"max_retained_bytes,omitempty"`
	BatchRows        int        `json:"batch_rows,omitempty"`
	BatchBytes       int64      `json:"batch_bytes,omitempty"`
	Handle           string     `json:"result_handle,omitempty"`
	Offset           int        `json:"offset,omitempty"`
	Limit            int        `json:"limit,omitempty"`
	Row              int        `json:"row,omitempty"`
	Column           int        `json:"column,omitempty"`
	ColumnName       string     `json:"column_name,omitempty"`
	SourceRows       []int      `json:"source_rows,omitempty"`
	Filter           string     `json:"filter,omitempty"`
	ViewID           string     `json:"view_id,omitempty"`
	SourceRow        int        `json:"source_row,omitempty"`
	CurrentRow       int        `json:"current_row,omitempty"`
	Page             int        `json:"page,omitempty"`
	PageSize         int        `json:"page_size,omitempty"`
	MatchIndex       int        `json:"match_index,omitempty"`
	SourceIndex      int        `json:"source_index,omitempty"`
	Expression       string     `json:"expression,omitempty"`
	LeftSourceIndex  int        `json:"left_source_index,omitempty"`
	RightSourceIndex int        `json:"right_source_index,omitempty"`
	Scope            string     `json:"scope,omitempty"`
	Format           string     `json:"format,omitempty"`
	Path             string     `json:"path,omitempty"`
	ExportID         string     `json:"export_id,omitempty"`
}

type Connection struct {
	ID          string `json:"id,omitempty"`
	Name        string `json:"name"`
	Driver      string `json:"driver"`
	Path        string `json:"path,omitempty"`
	Host        string `json:"host,omitempty"`
	Port        int    `json:"port,omitempty"`
	Socket      string `json:"socket,omitempty"`
	User        string `json:"user,omitempty"`
	Database    string `json:"database,omitempty"`
	Charset     string `json:"charset,omitempty"`
	HasPassword bool   `json:"has_password,omitempty"`
}

type Column struct {
	Name         string `json:"name"`
	DatabaseType string `json:"database_type"`
	Nullable     *bool  `json:"nullable"`
}

type Cell struct {
	Kind   string `json:"kind"`
	Text   string `json:"text,omitempty"`
	Base64 string `json:"base64,omitempty"`
}

// ResultMetadata is returned with retained-set lifecycle responses. Column
// metadata is limited to the database/sql facts available at execution time.
type ResultMetadata struct {
	Columns          []Column    `json:"columns,omitempty"`
	OriginalSQL      string      `json:"original_sql,omitempty"`
	ExecutedSQL      string      `json:"executed_sql,omitempty"`
	AutoLimitApplied bool        `json:"auto_limit_applied,omitempty"`
	AutoLimitReason  string      `json:"auto_limit_reason,omitempty"`
	ConnectionID     string      `json:"connection_id,omitempty"`
	Connection       *Connection `json:"connection,omitempty"`
	ExecutedAt       string      `json:"executed_at,omitempty"`
	ResultSets       int         `json:"result_sets,omitempty"`
	ObservedRows     int64       `json:"observed_rows,omitempty"`
	RetainedBytes    int64       `json:"retained_bytes,omitempty"`
	Truncated        bool        `json:"truncated,omitempty"`
	TruncationReason string      `json:"truncation_reason,omitempty"`
	AffectedRows     int64       `json:"affected_rows,omitempty"`
}

func NullCell() Cell         { return Cell{Kind: "null"} }
func TextCell(v string) Cell { return Cell{Kind: "text", Text: v} }
func BinaryCell(v []byte) Cell {
	return Cell{Kind: "binary", Base64: base64.StdEncoding.EncodeToString(v)}
}

type Event struct {
	Version            int                `json:"version"`
	Type               string             `json:"type"`
	RequestID          string             `json:"request_id,omitempty"`
	ExecutionID        string             `json:"execution_id,omitempty"`
	Generation         int64              `json:"generation,omitempty"`
	RunnerVersion      string             `json:"runner_version,omitempty"`
	ResultSet          int                `json:"result_set,omitempty"`
	Columns            []Column           `json:"columns,omitempty"`
	Rows               [][]Cell           `json:"rows,omitempty"`
	DurationMS         int64              `json:"duration_ms,omitempty"`
	ResultSets         int                `json:"result_sets,omitempty"`
	RowCount           int64              `json:"row_count,omitempty"`
	ObservedRows       int64              `json:"observed_rows,omitempty"`
	AffectedRows       int64              `json:"affected_rows,omitempty"`
	Truncated          bool               `json:"truncated,omitempty"`
	TruncationReason   string             `json:"truncation_reason,omitempty"`
	AutoLimitApplied   bool               `json:"auto_limit_applied,omitempty"`
	AutoLimitReason    string             `json:"auto_limit_reason,omitempty"`
	RetainedBytes      int64              `json:"retained_bytes,omitempty"`
	Code               string             `json:"code,omitempty"`
	Message            string             `json:"message,omitempty"`
	Op                 string             `json:"op,omitempty"`
	Connection         *Connection        `json:"connection,omitempty"`
	Connections        []Connection       `json:"connections,omitempty"`
	ActiveConnectionID string             `json:"active_connection_id,omitempty"`
	Terminal           bool               `json:"terminal,omitempty"`
	Handle             string             `json:"result_handle,omitempty"`
	Offset             int                `json:"offset,omitempty"`
	TotalRows          int64              `json:"total_rows,omitempty"`
	SourceRows         []int              `json:"source_rows,omitempty"`
	ViewID             string             `json:"view_id,omitempty"`
	SourceRow          int                `json:"source_row,omitempty"`
	CurrentRow         int                `json:"current_row,omitempty"`
	Cell               *Cell              `json:"cell,omitempty"`
	Column             *Column            `json:"column,omitempty"`
	Metadata           *ResultMetadata    `json:"metadata,omitempty"`
	Pinned             bool               `json:"pinned,omitempty"`
	Changes            []ResultDifference `json:"changes,omitempty"`
	SourceIndices      []int              `json:"source_indices,omitempty"`
	MatchingIndices    []int              `json:"matching_indices,omitempty"`
	Valid              bool               `json:"valid,omitempty"`
}

type ResultDifference struct {
	Column     int    `json:"column"`
	ColumnName string `json:"column_name,omitempty"`
	Path       string `json:"path"`
	Kind       string `json:"kind"`
	Before     *Cell  `json:"before,omitempty"`
	After      *Cell  `json:"after,omitempty"`
}

func (r Request) Validate() error {
	if r.Version != Version {
		return ErrUnsupportedVersion
	}
	if r.Type == "" {
		return errors.New("missing type")
	}
	if r.Type == "execute" {
		if r.RequestID == "" || r.ExecutionID == "" {
			return errors.New("missing execution identifiers")
		}
		if r.SQL == "" {
			return errors.New("missing sql")
		}
		if r.ConnectionID == "" {
			return errors.New("missing connection_id")
		}
		if r.Connection.Driver != "" || r.Password != nil {
			return errors.New("inline credentials are not allowed")
		}
	}
	if r.Type == "connection" {
		if r.RequestID == "" {
			return errors.New("missing request_id")
		}
		switch r.Op {
		case "list", "create", "update", "delete", "set_password", "test", "select":
		default:
			return errors.New("unknown connection operation")
		}
		if r.Op == "create" || r.Op == "update" {
			if r.Connection.Driver == "" {
				return errors.New("missing connection metadata")
			}
		}
		if r.Op == "delete" || r.Op == "set_password" || r.Op == "test" || r.Op == "select" || r.Op == "update" {
			if r.ConnectionID == "" {
				return errors.New("missing connection_id")
			}
		}
		if r.Op == "update" && r.Password != nil {
			return errors.New("password only allowed on create or set_password")
		}
		if r.Op != "create" && r.Password != nil {
			return errors.New("password only allowed on create or set_password")
		}
	}
	if r.Type == "cancel" && r.ExecutionID == "" {
		return errors.New("missing execution_id")
	}
	if r.Type == "result" {
		if r.RequestID == "" {
			return errors.New("missing request_id")
		}
		switch r.Op {
		case "page", "view", "cell", "filter", "filter_clear", "compare", "release", "pin", "unpin", "payload", "export", "export_cancel":
		default:
			return errors.New("unknown result operation")
		}
		if r.Handle == "" {
			return errors.New("missing result handle")
		}
		if (r.Op == "page" || r.Op == "view") && (r.Offset < 0 || r.Limit < 0 || r.Page < 0 || r.PageSize < 0) {
			return errors.New("invalid result page")
		}
		if r.Op == "cell" && (r.Row < 0 || r.Column < 0) {
			return errors.New("invalid result cell")
		}
		if r.Op == "filter" && r.Filter == "" && r.Expression == "" {
			return errors.New("missing result filter")
		}
		if r.Op == "compare" && (r.SourceRow < 0 || r.CurrentRow < 0) {
			return errors.New("invalid result comparison rows")
		}
	}
	return nil
}

func Encode(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	_, err = w.Write(b)
	return err
}

func DecodeLine(line []byte) (Request, error) {
	var req Request
	dec := json.NewDecoder(bytes.NewReader(line))
	if err := dec.Decode(&req); err != nil {
		return req, fmt.Errorf("malformed JSON: %w", err)
	}
	// Credentials are accepted only as the top-level field on the two
	// credential-mutating operations. A nested execute.connection or any
	// other password-shaped payload is rejected before it reaches Go memory.
	var shape struct {
		Type       string           `json:"type"`
		Op         string           `json:"op"`
		Password   *json.RawMessage `json:"password"`
		Connection json.RawMessage  `json:"connection"`
	}
	if err := json.Unmarshal(line, &shape); err == nil {
		if shape.Password != nil && !(shape.Type == "connection" && (shape.Op == "create" || shape.Op == "set_password")) {
			return Request{}, errors.New("inline credentials are not allowed")
		}
		if len(shape.Connection) > 0 && string(shape.Connection) != "null" {
			var nested map[string]json.RawMessage
			if json.Unmarshal(shape.Connection, &nested) == nil {
				if _, ok := nested["password"]; ok {
					return Request{}, errors.New("inline credentials are not allowed")
				}
			}
		}
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return req, errors.New("malformed JSON: multiple values")
		}
		return req, fmt.Errorf("malformed JSON: %w", err)
	}
	if err := req.Validate(); err != nil {
		return req, err
	}
	return req, nil
}

type Decoder struct{ scanner *bufio.Scanner }

func NewDecoder(r io.Reader, maxLine int) *Decoder {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 4096), maxLine)
	return &Decoder{scanner: s}
}
func (d *Decoder) Next() (Request, error) {
	if !d.scanner.Scan() {
		if err := d.scanner.Err(); err != nil {
			return Request{}, err
		}
		return Request{}, io.EOF
	}
	return DecodeLine(d.scanner.Bytes())
}
