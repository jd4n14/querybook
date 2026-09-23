# Querybook

A SQL notebook for Neovim. Queries stay as ordinary buffer text; each execution
renders its result beneath the statement that produced it. Several statements
can be investigated in the same file without leaving the editor.

The plugin talks to a local Go runner over a private JSONL protocol. Drivers
today are SQLite and MySQL. Querybook is not a schema browser or an inline
data editor.

## Features

- Inline result tables anchored to each statement, with independent stale and
  error state
- Native connection manager; passwords never live in Lua config or YAML
- macOS Keychain storage for credentials (`com.jd4n14.querybook.connections`)
- Read-only by default; writes require `:QuerybookRun!` or `allow_writes`
- Local [CEL](https://cel.dev) filters over retained rows (the SQL is not rewritten)
- Floating inspector for typed cells, JSON expansion, and lossless copies
- CSV / JSONL export of retained, filtered, or full results
- Optional [sqls](https://github.com/sqls-server/sqls) completion against the
  active connection's real schema

## Requirements

| Tool | Notes |
|------|--------|
| Neovim 0.10+ | Uses `jobstart` and virtual lines |
| Go 1.23+ | Builds `bin/querybook-runner` (`make build`) |
| sqls (optional) | Schema-aware completion when present on `PATH` |

SQLite uses [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite):
binaries are larger than a CGo build, but they do not need system SQLite
headers or a C compiler.

## Install

Build the runner once after clone:

```sh
make build
```

### lazy.nvim

```lua
{
  "jd4n14/querybook",
  build = "make build",
  config = function()
    require("querybook").setup({})
  end,
}
```

If you use [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) and it
would start its own `sqls` client, disable that server so Querybook owns the
process:

```lua
{
  "neovim/nvim-lspconfig",
  opts = { servers = { sqls = { enabled = false } } },
}
```

### Native packages

```sh
git clone https://github.com/jd4n14/querybook.git \
  ~/.local/share/nvim/site/pack/querybook/start/querybook
cd ~/.local/share/nvim/site/pack/querybook/start/querybook
make build
```

### Quick demo

From a checkout, open the included notebook and run `:QuerybookRun` on each
query:

```sh
nvim --clean --cmd "set rtp^=$PWD" examples/demo.sql
```

## Quick start

1. Open a `.sql` buffer.
2. `:QuerybookConnections` (or `qC`) and add a SQLite or MySQL connection.
3. Place the cursor in a statement and run `:QuerybookRun`.
4. Inspect the result with `:QuerybookInspect`, page with `<leader>qN` /
   `<leader>qP`, or filter retained rows with `:QuerybookFilter`.

Visual-mode `:QuerybookRun` executes the selection; each statement gets its own
result. Editing a statement marks that result stale. A later error replaces the
previous error for that statement without stacking blocks; a later success
replaces the slot entirely.

## Connections

`:QuerybookConnections` opens a native list:

| Key | Action |
|-----|--------|
| `Enter` | Select the connection |
| `a` | Add |
| `e` | Edit metadata |
| `p` | Change password |
| `d` | Delete (with confirmation) |
| `t` | Test |
| `q` | Close |

The metadata form accepts `name`, `driver`, `host`, `port`, `database`,
`username`, `socket`, `path`, and `charset`. SQLite requires `path`. MySQL
uses host or socket, port, username, and database.

Passwords are captured only by a hidden prompt on create or password change.
They are never buffer fields, Lua config, environment variables, or files.
`:QuerybookConnectionsImport {name}` copies metadata from a legacy config
profile; passwords are ignored.

Set `runner_path` if the binary is not at `bin/querybook-runner`. Set
`connection_store_path` only for an isolated metadata SQLite file (tests or a
separate local store).

## Commands

| Command | Description |
|---------|-------------|
| `:QuerybookRun` | Execute the statement under the cursor |
| `:QuerybookRun!` | Allow a statement classified as a write |
| `:QuerybookInspect` | Open the current result in a floating scratch window |
| `:QuerybookFilter` | Local CEL filter over retained rows |
| `:QuerybookClearFilter` | Clear the local CEL filter |
| `:QuerybookPinRow` | Pin or unpin the current inspector row |
| `:QuerybookCompareRows` | Compare the current row with the pinned row |
| `:QuerybookExportRetained` | Export all retained rows |
| `:QuerybookExportFiltered` | Export rows matching the current filter |
| `:QuerybookExportFull` | Export the full provider result when available |
| `:QuerybookRefresh` | Re-run the result under the cursor |
| `:QuerybookClear` | Clear the current result |
| `:QuerybookClear!` | Clear all results in the buffer |
| `:QuerybookToggle` | Collapse or expand the result under the cursor |
| `:QuerybookNextPage` / `:QuerybookPrevPage` | Page retained rows |
| `:QuerybookNextColumn` / `:QuerybookPrevColumn` | Page retained columns |
| `:QuerybookConnections` | Open the connection manager |
| `:QuerybookConnectionsImport {name}` | Import metadata from a legacy profile |

## Default mappings

| Mapping | Where | Action |
|---------|-------|--------|
| `qC` | Global | Connection manager |
| `qc` | Global | Clear current result |
| `<leader>qN` / `<leader>qP` | SQL buffer after a run | Next / previous row page |
| `<leader>qL` / `<leader>qH` | SQL buffer after a run | Next / previous column page |
| `<leader>qe` | SQL buffer after a run | Enter the result grid |

`<leader>qe` marks a cell in the inline table. The editor cursor stays on the statement. `h` / `l` move one column and the viewport follows, keeping the first result column visible once the view has scrolled. `j` / `k` move one row and cross row pages. `H` / `L` jump a screen of columns. The active header and cell are highlighted, and a detail line under the grid shows that cell's retained value (up to three lines). `Enter` opens Inspect on that cell. `<Esc>` leaves the grid.

## Inspector

`:QuerybookInspect` walks already retained matching rows. It does not re-run
SQL or CEL. Connection profile and database are captured at execution time.

| Key | Action |
|-----|--------|
| `[r` / `]r` | Previous / next matching row (crosses grid pages) |
| `[p` / `]p` | Jump matching pages |
| `p` | Pin or unpin the current source row |
| `Enter` / `za` | Expand a JSON field lazily |
| `gR` | Toggle raw / formatted presentation for that cell |
| `K` | Driver column metadata (type, nullable, size) |
| `gQ` | Full SQL when the compact header truncates it |
| `yv` | Copy the exact field value |
| `yn` | Copy the column name |
| `yj` | Copy the JSONPath of the current node |
| `yr` | Copy the exact row as ordered JSON (including `null`) |
| `yp` | Copy the complete payload |
| `q` | Close |

Copies use retained typed cells, so decimals and large integers do not round.

## Local filters (CEL)

SQL queries the database. CEL queries the retained result.

```vim
:QuerybookFilter
warehouse_id in [33, 102] && data.weight > 0.4 && invoice_id == null
```

Unique column labels become CEL variables. Duplicate labels are addressed with
`values[i]`. Names that are not CEL identifiers use `row["column-name"]`.

- Invalid expressions leave the current view unchanged.
- Pagination and Inspect `[r` / `]r` walk matching rows.
- Clearing the filter restores retained rows without re-executing SQL.
- A successful re-run creates a new handle and drops the filter; a failed
  re-run keeps the previous result.
- SQL integers that fit `int64` compare exactly. `DECIMAL` / `NUMERIC` compare
  as rationals against integers and other decimals; mixed comparisons with
  double use IEEE 754. SQL `NULL` is CEL `null`; empty string, `0`, and
  `false` remain distinct.

See `:help querybook-cel` for the full evaluation rules.

## Export

Exports require an explicit scope (`retained`, `filtered`, or `full`), a format
(CSV or JSONL), and a new path. Existing files are never overwritten. The
runner writes raw typed cells and reports progress plus an export ID for
cancellation.

Full export includes the original execution SQL and connection snapshot. The
automatic outer `LIMIT 500` and retention bounds are reported whenever they
affect what is available.

## SQL completion

When `sqls` is on `PATH`, Querybook starts a `querybook-sqls` client for the
active connection and attaches it to `sql` / `mysql` buffers. Changing the
active connection (or updating its password) restarts sqls. Querybook does not
execute SQL through sqls, and it does not write a `~/.config/sqls/config.yml`.

If sqls is missing, queries still run; only schema-aware completion is
unavailable.

Querybook also disables Vim's default SQL omni maps (`<Left>` / `<Right>` →
`sqlcomplete`), which otherwise flash an expression-register UI.

## Configuration

```lua
require("querybook").setup({
  preview_rows = 10,          -- rows per inline page
  max_columns = nil,          -- nil fits the window; a number caps a column page
  max_column_width = 32,      -- initial cap before leftover width goes to clipped cells
  timeout_ms = 30000,
  max_retained_rows = 10000,
  max_retained_bytes = 16 * 1024 * 1024,
  batch_rows = 200,
  batch_bytes = 512 * 1024,
  allow_writes = false,
  runner_path = nil,          -- defaults to bin/querybook-runner
  connection_store_path = nil,
})
```

`max_rows` is still honored as a preview override when `preview_rows` is not
set. The inline table fills the current window. Each visible column keeps at
least its header width; cell text starts capped at `max_column_width` and any
leftover window width goes to values that are still clipped. With
`max_columns` unset, the page shows as many columns as those headers fit. A
scrolled page keeps the first result column pinned and labels the gap
(`columns 1, 30-41 of 46`). Hidden row pages are labelled with the current
range.

For a top-level `SELECT` without an outer `LIMIT`, the runner adds an
authoritative `LIMIT 500` while leaving the buffer SQL unchanged. Nested
limits, comments, CTEs, and explicit outer limits are left alone. The header
reports that automatic limit separately from the 10-row viewport and retention
status.

Rows are positional arrays and columns are ordered metadata, so duplicate
labels stay lossless. Cells are `null`, text, or base64 binary.

## Safety

Unforced reads use driver-level read-only boundaries. Writes need
`:QuerybookRun!` or `allow_writes = true`. Sessions are isolated per execution;
there is no persistent SQL session or shared daemon across Neovim instances.

## Tests

```sh
make test
```

Focused Neovim suites:

```sh
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/run.lua
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/connections_ui.lua
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/sqls.lua
```

`make test-integration` accepts an isolated disposable MySQL 8.4 socket through
`QUERYBOOK_MYSQL_SOCKET` and related connection variables. It never selects an
application database by default.

## Documentation

- `:help querybook` — commands, inspector, CEL, configuration, and transport
- `examples/demo.sql` — two-statement notebook for a first run

## Out of scope

Snapshots, semantic comparison, DDL lookup, a schema browser, and an inline
data editor are intentionally out of scope.
