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
    require("querybook").setup({
      connections = {
        sqlite = { driver = "sqlite", path = vim.fn.stdpath("data") .. "/querybook.sqlite3" },
        local_mysql = {
          driver = "mysql",
          host = "127.0.0.1",
          port = 3306,
          user = "root",
          database = "app_development",
          -- charset = "utf8mb4", -- default for reliable Unicode values
          -- password = "...", -- sent only to the child over stdin
        },
      },
      active_connection = "sqlite",
    })
  end,
}
```

The plugin also installs defaults when no configuration is supplied. The
following commands are available:

```vim
:QuerybookRun       " execute the statement under the cursor
:QuerybookRun!      " explicitly allow a statement classified as a write
:QuerybookInspect   " open the current result in a floating scratch window
:QuerybookRefresh   " re-run the result under the cursor
:QuerybookClear     " clear the current result
:QuerybookClear!    " clear all results in the buffer
:QuerybookToggle    " collapse or expand only the result under the cursor
```

Select lines in visual mode before `:QuerybookRun` to execute that selection;
multiple statements receive independent result anchors. A result is marked
stale as soon as its statement text changes.
An execution error is rendered below the statement and does not delete the
previous successful result until a new successful execution replaces it.

## Connection configuration

`active_connection` names an entry in `connections`. Each entry has a
`driver`, either `sqlite` or `mysql`.

SQLite accepts `path` (use `:memory:` only for one process invocation; a file
is better for repeated notebook executions). MySQL accepts `host`, `port`,
`socket`, `user`, `database`, and optional `password`. The password is sent
only in the private JSON request on the child stdin and is never put in argv,
output, or logs. Set `runner_path` for a custom installation; otherwise run
`make build` to create `bin/querybook-runner`.

## Current boundary

Inline output is bounded for readability by `max_rows`, `max_columns`,
`max_value_length`, and `max_column_width`; each hidden or clipped dimension is
labelled explicitly. The runner retains at most `max_retained_rows` rows or
`max_retained_bytes` bytes (defaults 10000 and 16 MiB), and labels truncation.
`QuerybookInspect` opens a vertical, navigable view with connection
profile and database captured at execution time. JSON shaped values are
formatted for reading without changing their original text. In an inspect
window, `yv` copies the exact field value, `yr` copies the exact row as ordered
JSON (including `null`), and `yp` copies the complete payload; all three use
the retained strings, so decimals and large integers do not round.

Rows are positional arrays and columns are ordered metadata objects, so
duplicate labels remain lossless. Cells are null, text, or base64 binary cells;
exact numeric spellings, empty strings, literal `NULL`, Unicode, and arbitrary
bytes are preserved. Sessions are isolated per execution. Unforced reads use
driver-level read-only boundaries; `:QuerybookRun!` or `allow_writes=true` is
required for writes. A visual selection containing multiple statements creates
an independent result for each statement. Snapshots, semantic comparison, and
DDL lookup remain out of scope.

## Tests

The focused test suite uses the Go runner and Neovim headlessly:

```sh
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/run.lua
```

`make test-integration` accepts an isolated disposable MySQL 8.4 socket through
`QUERYBOOK_MYSQL_SOCKET` and related connection variables. It never selects an
application database by default.
