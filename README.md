# Querybook

Querybook is a small SQL notebook for Neovim. SQL stays as normal, editable
buffer text while each execution renders its result below the statement that
produced it. Multiple statements can therefore be investigated together.

The first milestone supports SQLite (useful for local tests) and MySQL through
their command line clients. It intentionally does not build a schema browser
or inline data editor.

## Requirements

- Neovim 0.10 or newer (the plugin uses `vim.system` and virtual lines).
- `sqlite3` for SQLite connections.
- `mysql` for MySQL connections.

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
          -- password = "...", -- prefer MYSQL_PWD or an option file
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
`socket`, `user`, `database`, and optional `password`. Querybook passes MySQL
passwords through `MYSQL_PWD` for the child process; an option file or an
external credential helper is preferable for shared machines.

## Current boundary

Inline output is bounded for readability by `max_rows`, `max_columns`,
`max_value_length`, and `max_column_width`; each hidden or clipped dimension is
labelled explicitly. The full result stays in memory until it is cleared or
replaced. `QuerybookInspect` opens a vertical, navigable view with connection
profile and database captured at execution time. JSON shaped values are
formatted for reading without changing their original text. In an inspect
window, `yv` copies the exact field value, `yr` copies the exact row as ordered
JSON (including `null`), and `yp` copies the complete payload; all three use
the retained strings, so decimals and large integers do not round.

MySQL uses the client's escaped XML batch transport. This preserves tabs,
newlines, backslashes, Unicode, empty strings, literal `NULL`, SQL `NULL`,
exact decimal text, and large integer text. The parser records SQL NULL as
`row._null[column] = true` while leaving an empty string as `row[column] ==
""`. A visual selection containing multiple statements creates an independent
result for each statement. SQLite keeps its existing tab transport. Snapshots,
semantic comparison, DDL lookup, and richer safety policy are planned after
this two-query/two-result milestone.

## Tests

The focused test suite uses the installed SQLite CLI and Neovim headlessly:

```sh
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/run.lua
```

The MySQL adapter has parser fixtures and a live fixture path. To run the live
fixture against an isolated local server, set `QUERYBOOK_MYSQL_TEST=1` plus
`QUERYBOOK_MYSQL_SOCKET` (or host/port variables); the test only executes a
read-only `SELECT` and never uses a real application database by default.
