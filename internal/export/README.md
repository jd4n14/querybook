# Result export contract

The export package accepts ordered `protocol.Column` metadata and positional
`protocol.Cell` rows. It supports CSV and JSONL only. `ExportCurrent` walks the
retained row slice directly; `ExportRows` consumes one row at a time from a
`RowSource` and does not accumulate the stream.

CSV writes one ordered header row, preserving duplicate labels. SQL `NULL` is
written as `\N`; text backslashes are doubled, so a text value equal to `\N`
is written as `\\N` and remains distinguishable. Binary cells use `\B` followed
by their standard base64 payload. The CSV package performs normal quoting for
commas, quotes, and newlines. This is a deliberately documented interchange
contract: consumers should decode the two backslash sentinels before treating
values as ordinary text.

JSONL writes one object per result row:

```json
{"columns":[{"name":"id","database_type":"INTEGER","nullable":null}],"cells":[{"kind":"text","text":"1"}]}
```

`columns` is repeated on every row so each line is self-contained, and `cells`
is positional to preserve duplicate names. Cell kinds are `null`, `text`, and
`binary`; binary payloads remain base64. A zero-row result emits one schema
record with `"schema":true` and `"cells":null`.

The destination is created with private mode (`0600`) through a same-directory
temporary file, synced, and atomically published with a no-clobber hard link.
Existing files are never replaced. Cancellation, encoder errors, source errors,
and publish failures remove only the export's own temporary file.

Progress callbacks receive row count, encoded byte count, and elapsed duration;
they never receive row values. Callbacks are throttled by row count and time.
