# Plan 001: Replace CLI transports with a bounded Go database runner

> **Executor instructions**: Implement this plan in an isolated git worktree created from commit `233761a`. Follow every step and run every verification gate. Keep the user's active checkout at `/Users/g0d13/Documents/ChatGPT/Database/querybook` free of partial work. After all gates pass, integrate the verified commit(s) into that actual local checkout without including unrelated changes. Do not push unless the operator separately asks. Update the status in `plans/README.md` after integration.
>
> **Drift check (run first)**: `git diff --stat 233761a..HEAD -- README.md doc/querybook.txt doc/tags lua/querybook/init.lua lua/querybook/render.lua lua/querybook/runner.lua lua/querybook/risk.lua tests/run.lua .gitignore go.mod go.sum cmd internal Makefile`
> If an in-scope file changed, compare the current-state excerpts below with live code. Stop on a material mismatch instead of silently overwriting it.

## Status

- **Priority**: P1
- **Effort**: L (multi-day)
- **Risk**: HIGH — replaces the execution and retained-result boundary while preserving an interactive UI
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `233761a`, 2026-09-08

## Why this matters

Querybook currently starts `mysql` or `sqlite3` for every statement and then reconstructs results from XML or TSV. That loses zero-row schema in MySQL, cannot represent duplicate column names because rows are Lua maps, makes SQLite delimiters ambiguous, retains an unbounded result, and offers no real cancellation. Replace only that transport with one on-demand Go child per Neovim instance. Preserve the current notebook, virtual-line, inspector, stale-result, error-retention, explicit-write, and multi-anchor behavior.

The Go process is the authoritative execution boundary. Lua may warn early for UX, but the runner must fail closed on unforced SQL it cannot confidently treat as read-only. This is a guardrail, not a substitute for a least-privilege database account.

## Current state

- `lua/querybook/runner.lua:121-163` builds `sqlite3 -tabs` or `mysql --xml` commands and invokes each through `vim.system`.
- `lua/querybook/runner.lua:54-104` derives MySQL columns while parsing rows, so a zero-row result has no column metadata.
- `lua/querybook/runner.lua:107-118` and `lua/querybook/render.lua:3-11` represent each row as a map keyed by column label. `SELECT 1 AS dup, 2 AS dup` therefore overwrites one value.
- `lua/querybook/init.lua:180-238` creates one independently anchored result per parsed statement and replaces the previous successful result only after a new success. Preserve this ordering and error behavior.
- `lua/querybook/init.lua:81-177` generates exact inspector copies from retained strings. It must be converted to positional cells without changing `yv`, `yr`, `yp`, or their exact-value guarantees.
- `lua/querybook/init.lua:206-209` relies on `risk.analyze` before calling the runner. `lua/querybook/risk.lua:21-35` examines a first keyword and a `WHERE` regex; it is not sufficient as an execution boundary.
- `README.md:87-106` says the entire result remains in memory. This must change to bounded retention with explicit truncation metadata.
- `tests/run.lua` is the existing single-file headless Neovim suite. Preserve `nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/run.lua` as the end-to-end Lua gate, while splitting fixtures where that makes failures easier to locate.

Applicable conventions are small Lua modules returning `M`, callbacks scheduled onto Neovim's main loop, user-facing errors prefixed `Querybook:`, and tests using `assert`/`vim.deep_equal`. Recent commits use Conventional Commit messages, for example `feat(querybook): add lossless result inspection`.

## Architectural decisions

### Process and lifecycle

- Start one runner lazily on the first execution for each Neovim instance. Do not start it in `setup()`.
- Use `vim.fn.jobstart({ runner_path }, { rpc = false, ... })`, `vim.fn.chansend`, newline-delimited JSON, unbuffered stdout callbacks, and a receive buffer that handles partial and multiple lines. Never pass credentials or SQL in argv.
- Resolve the executable in this order: explicit `runner_path`, `vim.fn.exepath("querybook-runner")`, then `<plugin-root>/bin/querybook-runner`. If none is executable, show one actionable build command. Do not build or download during editor startup.
- Stop the child on `VimLeavePre`; close database handles, cancel active contexts, and exit on EOF or `shutdown`. On unexpected exit, mark every pending execution as an error, discard partial rows for that execution, clear pending callbacks, and allow one fresh lazy start on the next user command. Do not automatically replay SQL.
- Keep connection profiles in Lua and send them on each execute request. The runner may cache validated `*sql.DB` handles keyed by a canonical connection ID plus a configuration fingerprint; when the fingerprint changes, close and replace the old handle. Passwords must never be echoed in responses/errors or logged.

### Session semantics

- Default and only public mode in this migration is `session_mode = "isolated"`: each execution obtains its own `*sql.Conn`, and the implementation must not promise that temporary tables, transaction state, variables, or other session mutations survive into another Querybook run.
- For MySQL, ensure an execution's physical connection is not concurrently used by a sibling request. For SQLite, cap a connection profile to one active connection unless tests prove the selected driver and DSN are safe at a higher value. A cancellation affects only the target context/connection.
- Do not add a persistent interactive transaction/session mode in this plan. Document the boundary. If driver behavior makes physical-session reuse observable despite cleanup, disable idle reuse for this version rather than exposing implicit state.

### Protocol v1

Use UTF-8 JSON objects separated by `\n`. Every message has `version: 1` and `type`. Client requests also have a monotonically increasing string `request_id`; execution-related messages carry a unique string `execution_id` and a Lua-side `generation` integer. IDs remain strings end-to-end.

The minimum message set is:

- runner → client `ready`: protocol version and runner version;
- client → runner `execute`: IDs, generation, connection profile, SQL, `force`, `timeout_ms`, and retention/batch limits;
- runner → client `result_start`: IDs, ordered `result_set`, and ordered column metadata independent of rows;
- runner → client `rows`: IDs, result-set index, and a positional array of row arrays;
- runner → client `result_end`: IDs, duration, result-set/row counts, affected-row count when available, and truncation details;
- runner → client `error`: stable code (`invalid_request`, `unsupported_protocol`, `unsafe_statement`, `connection`, `query`, `timeout`, `cancelled`, `limit`, `internal`), safe message, terminal flag;
- client → runner `cancel`, runner → client `cancelled` (terminal for that execution);
- client → runner `shutdown`.

Require exactly one terminal message per accepted execution. Ignore stale messages in Lua unless `execution_id`, `generation`, and the pending result identity all match. Unknown fields are ignored within v1; an unsupported version and malformed JSON receive an error without crashing the process. Protocol output owns stdout; diagnostics go to stderr and exclude SQL/passwords.

Column metadata is an ordered array with at least `{ name, database_type, nullable }`; `nullable` may be `null` when the driver cannot report it. Rows are positional and always have exactly the column count. Each cell is one of:

```json
{"kind":"null"}
{"kind":"text","text":"9223372036854775807"}
{"kind":"binary","base64":"AAEC/w=="}
```

Scan through `sql.RawBytes`/`[]byte`, copy before the next `Rows.Next`, and never decode `BIGINT`, unsigned integers, `DECIMAL`, or other returned numerics into Go/Lua JSON numbers. Use column database type plus the returned value to classify binary types; arbitrary bytes, NUL, and invalid UTF-8 use base64. Preserve empty text and literal `NULL` as text. Call `ColumnTypes()` before row iteration, check `Rows.Err()`, close rows on every path, and iterate `NextResultSet()`.

The protocol transport limit and retained-result limit are the same boundary: default `max_retained_rows = 10000`, `max_retained_bytes = 16 MiB`, `batch_rows = 200`, `batch_bytes = 512 KiB`, and `timeout_ms = 30000`. Count decoded cell payload bytes plus a documented fixed per-cell/row overhead, stop reading when either retention limit would be exceeded, close/cancel the query, and return a successful terminal result with `truncated: true`, `truncation_reason`, and retained/observed counts. Never silently drop rows. `max_rows`, `max_columns`, `max_value_length`, and `max_column_width` remain display-only settings.

Do not let stdout backpressure grow memory without bound: produce at most one configured batch in memory, encode/write it synchronously, and stop work promptly if the pipe closes. The client must process each batch incrementally into the matching result rather than queue raw protocol text.

### Authoritative write guard

- Preserve `:QuerybookRun!` and `allow_writes = true` as explicit intent. Send `force = true` only for those paths. Refresh must recompute the guard from current SQL and must not inherit force from an old execution.
- In the Go runner, reject multiple top-level statements per request and unknown/ambiguous syntax unless `force` is true. Implement a quote/comment-aware tokenizer, not keyword regexes. The conservative unforced allowlist may admit plain read forms (`SELECT`, `SHOW`, `DESCRIBE`/`DESC`, and read-only `EXPLAIN`) only after tokenization establishes one statement. Treat CTEs, dialect pragmas, executable comments, writable `EXPLAIN` forms, and anything the tokenizer cannot classify as requiring force for v1.
- Add a driver enforcement layer for unforced execution: execute MySQL reads on the dedicated connection inside a read-only transaction that is always rolled back; execute SQLite reads on a dedicated connection with `PRAGMA query_only=ON` and close/reset that connection afterward. If a driver cannot establish the read-only boundary, fail the request. The lexical guard is defense in depth, not a claim of complete SQL semantic parsing.
- Forced statements use the same timeout/cancellation/retention controls. Return rows when the driver produces them; otherwise return affected rows where available.

## Dependency and build decision

Create a Go module at the repository root, a small `cmd/querybook-runner`, and focused packages under `internal/` for protocol, SQL policy, driver execution, and process orchestration. Use `github.com/go-sql-driver/mysql` and `modernc.org/sqlite` behind `database/sql`. Pin released module versions in `go.mod`/`go.sum`.

Choose `modernc.org/sqlite` because it is CGo-free and supports the current macOS arm64 target plus cross-compilation. Record the trade-off in the README: larger/slower builds and a substantial transitive dependency tree in exchange for no system SQLite headers/compiler and portable release binaries. Do not add `mattn/go-sqlite3`, CGo build tags, vendored dependencies, automatic downloads, or a release workflow in this migration.

Add a `Makefile` with `build`, `test`, and `test-integration` targets. `build` writes the ignored local artifact `bin/querybook-runner`; plugin-manager examples use `build = "make build"`. Document `runner_path` for Nix/custom installs. A later release can attach checksummed platform binaries, but that is explicitly deferred until the protocol stabilizes.

Primary references: Go [`database/sql`](https://pkg.go.dev/database/sql) for contexts, `Rows.ColumnTypes`, `RawBytes`, and resource lifetime; [`go-sql-driver/mysql`](https://github.com/go-sql-driver/mysql) for DSN/TLS/session behavior; [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite) for the CGo-free driver and supported targets.

## Scope

**In scope (only these paths may change):**

- `go.mod`, `go.sum`, `Makefile`, `.gitignore`
- `cmd/querybook-runner/**` (new)
- `internal/**` (new Go packages and tests)
- `lua/querybook/runner.lua`, `lua/querybook/init.lua`, `lua/querybook/render.lua`, `lua/querybook/risk.lua`
- `tests/**`
- `README.md`, `doc/querybook.txt`, `doc/tags`
- `plans/README.md` status only
- Operational after repository integration: `~/.config/nvim/lua/plugins/querybook.lua` may receive only the migration described in Step 5; it is outside git and must not be copied into the repository.

**Out of scope:**

- schema snapshots, DDL lookup, semantic diffs, schema browser, or inline editing;
- a classic Vim adapter, TCP/socket daemon, shared runner across Neovim instances, RPC framework, plugin system, or auto-updater;
- persistent transactions/session mode, prepared-statement UI, parameters UI, credential storage, SSH tunnels, TLS-policy redesign;
- changing parser behavior, command names, inspector mappings, extmark placement, collapse/stale/error-retention UX, or adding mappings;
- changing the user's MySQL service configuration or touching a real application database;
- CI/release publishing in this plan.

## Git workflow

- Work in an isolated worktree and branch named `feat/go-runner` from `233761a` (or the executor's orchestrator-provided isolated branch).
- Commit logical units with Conventional Commits, for example `feat(querybook): add Go query runner` and `test(querybook): verify runner integrations`.
- Before integration, confirm the target checkout is still clean and at the expected ancestor. Integrate only the verified commits; do not copy a dirty worktree wholesale. Stop if unrelated user changes overlap.
- Do not push or open a PR unless separately authorized.

## Steps

### Step 1: Define and test protocol v1 before database code

Add Go request/event structs, strict required-field validation, JSONL decoder/encoder, safe protocol errors, and golden fixtures usable by Lua tests. Add Lua framing that handles split/coalesced stdout callbacks and rejects malformed, oversized, or unsupported messages without crashing Neovim. Set a maximum inbound line size slightly above `batch_bytes` plus envelope overhead.

**Verify**: `go test ./internal/protocol/...` exits 0 and covers split writes, multiple frames, malformed JSON, unsupported versions, unknown fields, oversized frames, and every cell kind. A headless Lua protocol test exits 0 with equivalent split/coalesced fixtures.

### Step 2: Implement exact, positional database results

Add driver configuration/validation and the database executor using `database/sql`, the two selected drivers, `ColumnTypes`, copied raw bytes, positional cells, multiple result sets, empty result schemas, affected rows, safe errors, and unconditional cleanup. Do not include a connection password in a cache key or error; derive a one-way fingerprint over normalized settings if caching requires one.

Driver unit/integration fixtures must cover duplicate labels, zero rows with schema, SQL NULL, empty text, literal `NULL`, tabs/newlines/backslashes, Unicode, NUL/control bytes, invalid UTF-8/blob bytes, signed/unsigned bigint boundary values, high-precision decimals, and multiple result sets where the driver supports them.

**Verify**: `go test ./internal/...` exits 0; `go test -race ./internal/...` exits 0; test assertions compare exact cell kinds and byte/text payloads, never floating-point conversions.

### Step 3: Enforce execution safety, cancellation, limits, and cleanup

Implement the conservative tokenizer/classifier and driver-specific unforced read boundary described above. Track each active `execution_id` with its own cancel function. Apply timeout, row/byte/batch limits, and exactly-one-terminal-event state. Cancelled/limited queries must close rows and release the connection without stopping unrelated executions or the runner.

Test bypass-shaped inputs: comments before a write, semicolons in strings/comments, two statements, `WITH ... DELETE`, `EXPLAIN` around mutation, MySQL executable comments, SQLite `PRAGMA` and `VACUUM`, lowercase/mixed case, and malformed/unterminated strings. Each is denied without force when ambiguous/writable and reaches the driver only with force. Test the read-only database boundary independently from the classifier so a simulated classifier mistake still cannot mutate in unforced mode.

**Verify**: `go test -race ./internal/...` exits 0 and includes concurrent fast/slow executions where cancelling the slow request does not cancel or corrupt the fast one. Limit tests confirm bounded batch size, explicit truncation, and cleanup. An EOF test confirms the runner exits and closes resources.

### Step 4: Replace the Lua adapter without changing notebook UX

Rewrite `lua/querybook/runner.lua` as the lazy process manager and protocol client. Adapt `init.lua` and `render.lua` to ordered column objects and positional cell arrays. Keep an explicit accessor such as `cell(result, row_index, column_index)` so display, inspector, `yv`, `yr`, and `yp` use the same exact data path.

For row JSON with duplicate labels, preserve valid ordered information rather than emitting duplicate object keys: define `yr` as an ordered JSON array of `{ "column": <name>, "value": <string|null>, "encoding": "text"|"base64" }` entries, and define `yp.rows` as arrays in the same column order with top-level ordered `columns` metadata. This is a documented compatibility correction required to make duplicate names lossless. `yv` copies text verbatim, SQL NULL as `NULL`, and binary as the documented base64 string (with a visible encoding label in the inspector).

Create a new generation when refreshing/re-executing an anchor; cancel the older in-flight execution for that anchor. Late rows or terminals from the old generation must not update UI. `QuerybookClear` cancels the matching request; `QuerybookClear!` cancels all requests for the buffer. Buffer deletion cleans its pending executions. Process failure converts pending states into errors and preserves earlier successful results.

**Verify**: the headless Neovim tests exit 0 and assert existing commands, independent multi-query anchors, stale marking, successful replacement, failed-result retention, collapse, exact copies, connection snapshot, duplicate columns, zero-row schema, cancellation, late-generation suppression, truncation labels, process crash/restart, missing-binary error, and Refresh write blocking.

### Step 5: Migrate configuration and documentation

Update defaults with `runner_path`, `timeout_ms`, `max_retained_rows`, `max_retained_bytes`, `batch_rows`, and `batch_bytes`. Keep existing connection tables source-compatible. Remove CLI requirements and `MYSQL_PWD` guidance; explain the build hook, executable lookup, isolated session semantics, explicit force behavior, bounded retention, binary/base64 copies, and changed duplicate-column row payload. Update help tags.

Migrate the user's actual development configuration at `~/.config/nvim/lua/plugins/querybook.lua` only after the verified repository commits are integrated: keep `dir = vim.fn.expand("~/Documents/ChatGPT/Database/querybook")`, add `build = "make build"`, preserve every existing mapping/option and environment-derived connection field, and replace the obsolete `MYSQL_PWD`/option-file transport comment with wording that the configured password is sent only over the child process's stdin. This one operational config edit is authorized as part of making the migrated local plugin load; do not edit it from the isolated worktree or include it in a repository commit.

**Verify**: `rg -n 'mysql client|sqlite3.*require|MYSQL_PWD|XML transport|tab output|full result stays' README.md doc lua` has no stale transport/retention claims. `nvim --headless -u NONE -c 'set rtp^=$PWD' -c 'helptags doc' -c 'qa'` exits 0 and `git diff --exit-code -- doc/tags` exits 0 after tags are committed.

### Step 6: Run real SQLite, MySQL, and Neovim acceptance

Use a temporary SQLite file and a temporary isolated MySQL 8.4 data directory/socket. Initialize/start/stop it explicitly with a shell trap; do not use `brew services`, do not change the installed service, and do not connect to an application database. Create a disposable least-privilege fixture database/user. Make the test target accept socket/host settings through environment variables without printing credentials.

Run protocol/driver tests directly against both engines, then run the same fixtures through headless Neovim and the built child. Finally start Neovim using the actual plugin configuration at `~/.config/nvim/lua/plugins/querybook.lua` and the actual local checkout, execute a disposable SQLite notebook, and assert virtual results plus inspector copies. This final acceptance catches incorrect runner resolution that a modified runtime path can hide.

**Verify**:

```sh
make build
make test
QUERYBOOK_MYSQL_TEST=1 QUERYBOOK_MYSQL_SOCKET="$temporary_socket" make test-integration
nvim --headless -u NONE -c "set rtp^=$PWD" -l tests/run.lua
git status --short
```

Expected: every command exits 0; integration output identifies SQLite, isolated MySQL 8.4, and Neovim layers as passed; MySQL stops and its temporary directory is removable; status contains only intended in-scope files. After integration in the actual checkout, rerun `make build`, the headless suite, and the disposable SQLite acceptance there.

## Test plan

- Go protocol unit tests: framing, validation, versions, IDs/generations, terminal-state invariant, safe errors, cell round trips.
- Go policy tests: full bypass matrix and force behavior.
- Go executor tests: fake-driver deterministic cancellation/backpressure/cleanup plus real SQLite semantics.
- Isolated MySQL 8.4 integration: exact values, duplicate labels, zero-row schema, multiple result sets if enabled, read-only enforcement, timeout/cancel, and subsequent healthy query.
- Lua unit tests: incremental JSONL parser, positional accessors, payload encoding, generation filtering.
- Headless Neovim acceptance: every current UX assertion plus process lifecycle, cancellation, crash recovery, bounded retention, SQLite and opt-in MySQL.
- Do not assert implementation details such as goroutine counts unless needed for a leak regression; assert observable cleanup and successful subsequent execution.

## Done criteria

- [ ] `make build`, `make test`, and `go test -race ./internal/...` exit 0.
- [ ] Headless Neovim suite exits 0 with no `mysql`/`sqlite3` CLI dependency.
- [ ] Isolated real SQLite and MySQL 8.4 tests pass for exact values, duplicate columns, zero-row schema, limits, cancellation, and write enforcement.
- [ ] Protocol is documented as v1 and all execution events correlate by request, execution, and generation IDs.
- [ ] Rows/cells are positional end-to-end; no result map is keyed by column name.
- [ ] NULL, empty/literal `NULL`, numerics, Unicode, controls, and binary values round-trip without loss or Lua numeric conversion.
- [ ] Retained rows/bytes and batches are bounded, with visible truncation metadata.
- [ ] Child/DB resources close on cancel, clear, buffer deletion, Neovim exit, stdin EOF, and process failure.
- [ ] Existing commands, mappings, anchors, stale/collapse/error behavior, and connection snapshots remain covered.
- [ ] README/help/config examples describe the new build, limits, session semantics, force boundary, and payload shape.
- [ ] The verified commits are integrated into the actual local checkout and acceptance is rerun there; no unrelated files are changed.

## STOP conditions

Stop and report rather than improvising if:

- in-scope code has materially drifted from `233761a` or the actual checkout has overlapping unrelated changes;
- the chosen driver cannot preserve MySQL `DECIMAL`/`BIGINT` as bytes/text, cannot distinguish SQLite blob/text reliably enough for reversible encoding, or fails on macOS arm64;
- unforced execution cannot establish the driver-level read-only boundary described above;
- safe cancellation requires killing the whole runner or demonstrably corrupts sibling executions;
- a protocol frame must exceed the configured maximum to transport one cell (report the fixture and propose an explicit oversized-cell terminal error; do not silently clip it);
- integration requires a real application database, changes to a Homebrew service, credentials in committed files/output, or files outside scope;
- any verification gate still fails after two focused correction attempts.

## Maintenance notes

Treat protocol v1 as an internal but versioned compatibility boundary: future runner changes must remain backward compatible or negotiate a new version. Reviewers should concentrate on exactly-one-terminal-event behavior, buffer accounting, raw-byte copying before `Rows.Next`, generation checks, and cleanup paths. A persistent session mode would need a separate design for serialization, transactions, reconnect behavior, and UI state; do not infer it from the long-lived process.
