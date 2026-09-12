# Querybook

Querybook is a small SQL notebook for Neovim. SQL stays as normal, editable
buffer text while each execution renders its result below the statement that
produced it. Multiple statements can therefore be investigated together.

The runner supports SQLite and MySQL through one on-demand Go child per Neovim
instance. It intentionally does not build a schema browser
or inline data editor.

## Requirements

- Neovim 0.10 or newer (the plugin uses `jobstart` and virtual lines).
- Go 1.23+ to build the child runner (`make build`).

The SQLite driver is `modernc.org/sqlite`: builds are larger and slower than a
CGo driver, but release binaries need no system SQLite headers or compiler.

## Install

For a native Neovim package install:

```sh
git clone https://github.com/jd4n14/querybook.git ~/.local/share/nvim/site/pack/querybook/start/querybook
```

For a quick SQLite demo from a checkout, open the included notebook and run
`:QuerybookRun` on each query:

```sh
nvim --clean --cmd "set rtp^=$PWD" examples/demo.sql
```

With `lazy.nvim`:

```lua
{
  dir = "/path/to/querybook",
  config = function()
    require("querybook").setup({})
  end,
}
```

Use `:QuerybookConnections` or normal-mode `qC` to manage saved connections.
The rounded native list supports Enter (select), `a` (add), `e` (edit
metadata), `p` (change password), `d` (delete with confirmation), `t` (test),
and `q` (close). Passwords are captured only by the hidden input prompt for
create or password changes. They are never editable buffer fields or stored in
Lua configuration. `qc` remains the existing clear mapping.

The plugin also installs defaults when no configuration is supplied. The
following commands are available:

```vim
:QuerybookRun       " execute the statement under the cursor
:QuerybookRun!      " explicitly allow a statement classified as a write
:QuerybookInspect   " open the current result in a floating scratch window
:QuerybookFilter    " filter the open inspector (JSONPath or shorthand)
:QuerybookClearFilter " clear the inspector filter
:QuerybookPinRow    " pin or unpin the current inspector row
:QuerybookCompareRows " compare current row with the pinned row
:QuerybookExportRetained " export all retained rows
:QuerybookExportFiltered " export rows matching the current filter
:QuerybookExportFull " export the full provider result when available
:QuerybookRefresh   " re-run the result under the cursor
:QuerybookClear     " clear the current result
:QuerybookClear!    " clear all results in the buffer
:QuerybookToggle    " collapse or expand only the result under the cursor
:QuerybookNextPage  " show the next retained row page
:QuerybookPrevPage  " show the previous retained row page
:QuerybookNextColumn " show the next retained column page
:QuerybookPrevColumn " show the previous retained column page
:QuerybookConnections " open saved connection manager
:QuerybookConnectionsImport name " explicitly import metadata from an old config profile
```

Select lines in visual mode before `:QuerybookRun` to execute that selection;
multiple statements receive independent result anchors. A result is marked
stale as soon as its statement text changes.
An execution error is rendered below the statement and does not delete the
previous successful result until a new successful execution replaces it. Each
statement has one result slot, so repeated failures do not stack duplicate
error blocks; a later success replaces that slot. Results from statements that
remain in the notebook stay independently anchored.

## Connection configuration

Connections are persisted by the Go runner and selected by managed UUID. The
metadata form accepts `name`, `driver`, `host`, `port`, `database`, `username`,
`socket`, `path`, and `charset`; SQLite requires `path`, while MySQL uses its
host/socket, port, username, and database fields. Set `runner_path` for a
custom installation; otherwise run `make build` to create
`bin/querybook-runner`. Existing inline profiles can be imported as metadata
from the manager when the user requests it; passwords are never read from
those profiles or from environment variables.
Set `connection_store_path` only when an isolated metadata SQLite file is
needed for tests or a deliberately separate local profile store.

## Current boundary

Inline output is a compact viewport showing 10 rows by default. Use
`:QuerybookNextPage`/`:QuerybookPrevPage` or the `<leader>qN`/`<leader>qP`
mappings to page retained rows, and `:QuerybookNextColumn`/`:QuerybookPrevColumn`
or `<leader>qL`/`<leader>qH` to page columns. Configure `preview_rows` and
`max_columns` to change the page size; legacy `max_rows` is honored as a
preview override when `preview_rows` is not set. The inline result table fills
the current window and clips cell values to the allocated column width. Hidden
row and column pages are labelled with the current range. The runner retains at most `max_retained_rows` rows or
`max_retained_bytes` bytes (defaults 10000 and 16 MiB), and labels truncation.
`QuerybookInspect` opens a vertical, navigable view with connection profile
and database captured at execution time. It keeps an opaque result handle and
requests pages from the runner, so inspecting a large retained result does not
copy every row into Lua. `[r`/`]r` move through matching rows and `[p`/`]p`
move through matching pages. `Enter` or `za` expands a JSON field lazily when
its column metadata is structured; `gR` toggles raw/formatted presentation.
`K` shows the actual source metadata for the field and `gQ` shows the full SQL
when the compact header truncates it.
`yv` copies the exact field value, `yr` copies the exact row as ordered JSON
(including `null`), and `yp` copies the complete payload; all three use the
retained typed cells, so decimals and large integers do not round.

`:QuerybookFilter` sends a JSONPath or shorthand expression to the runner;
invalid expressions leave the current view unchanged. Filtering is local to
the retained result and resets to its first matching page on success. Pinning
stores a source row index and handle, allowing comparison to survive paging
and filtering. A successful re-run creates a new handle and clears inspector
filter, pin, and expansion state; a failed re-run retains the previous result.

Exports require an explicit scope (`retained`, `filtered`, or `full`), format,
and a new path. The runner writes raw typed cells and reports progress and an
export ID for cancellation. Full export includes the original execution SQL
and connection snapshot; the automatic outer `LIMIT 500` and retention state
are shown whenever they affect what is available.

Rows are positional arrays and columns are ordered metadata objects, so
duplicate labels remain lossless. Cells are null, text, or base64 binary cells;
exact numeric spellings, empty strings, literal `NULL`, Unicode, and arbitrary
bytes are preserved. Sessions are isolated per execution. Unforced reads use
driver-level read-only boundaries; `:QuerybookRun!` or `allow_writes=true` is
required for writes. A visual selection containing multiple statements creates
an independent result for each statement. For a top-level `SELECT` without an
outer `LIMIT`, the Go runner adds an authoritative `LIMIT 500` while
preserving the SQL buffer. Strings, comments, subqueries, CTE limits, explicit
outer limits, and unsupported forms are handled conservatively. The header
reports the automatic limit separately from the visible 10-row viewport and
retention status. Snapshots, semantic comparison, and DDL lookup remain out
of scope.

## Tests

The focused test suite uses the Go runner and Neovim headlessly:

```sh
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/run.lua
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/connections_ui.lua
```

`make test-integration` accepts an isolated disposable MySQL 8.4 socket through
`QUERYBOOK_MYSQL_SOCKET` and related connection variables. It never selects an
application database by default.
