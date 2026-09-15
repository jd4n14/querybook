-- Inspector UI contract tests.  The fake registry models handle based view,
-- filter, compare, and export calls without opening a database or touching a
-- user's connection store.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local inspect = require("querybook.inspect")

local function text_of(state)
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end

local function line_with(state, snippet)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    if line:find(snippet, 1, true) then return line end
  end
end

local function child_line(state, snippet)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    if line:find(snippet, 1, true) and not line:find("payload", 1, true) then return line end
  end
end

local function cursor_on(state, snippet)
  for line, value in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    if value:find(snippet, 1, true) then
      vim.api.nvim_win_set_cursor(state.win, { line, 0 })
      return line
    end
  end
end

local function count_op(calls, op)
  local n = 0
  for _, call in ipairs(calls) do
    if call.op == op then n = n + 1 end
  end
  return n
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local payload_raw = '{"nested":{"n":900719925474099312345},"products":[{"price":61.92},{"price":2},{"price":3},{"price":4}],"gone":null}'
local payload_tree = {
  type = "object",
  raw = payload_raw,
  children = {
    { key = { type = "string", raw = '"gone"' }, node = { type = "null", raw = "null" } },
    { key = { type = "string", raw = '"nested"' }, node = { type = "object", raw = '{"n":900719925474099312345}', children = {
      { key = { type = "string", raw = '"n"' }, node = { type = "number", raw = "900719925474099312345" } },
    } } },
    { key = { type = "string", raw = '"products"' }, node = { type = "array", raw = '[{"price":61.92},{"price":2},{"price":3},{"price":4}]', children = {
      { node = { type = "object", raw = '{"price":61.92}', children = {
        { key = { type = "string", raw = '"price"' }, node = { type = "number", raw = "61.92" } },
      } } },
      { node = { type = "object", raw = '{"price":2}', children = {
        { key = { type = "string", raw = '"price"' }, node = { type = "number", raw = "2" } },
      } } },
      { node = { type = "object", raw = '{"price":3}', children = {
        { key = { type = "string", raw = '"price"' }, node = { type = "number", raw = "3" } },
      } } },
      { node = { type = "object", raw = '{"price":4}', children = {
        { key = { type = "string", raw = '"price"' }, node = { type = "number", raw = "4" } },
      } } },
    } } },
  },
}

local columns = {
  { name = "id", database_type = "INT", nullable = false },
  { name = "sql_null", database_type = "VARCHAR", nullable = true },
  { name = "empty", database_type = "VARCHAR", nullable = true },
  { name = "flag", database_type = "BOOLEAN", nullable = true },
  { name = "zero", database_type = "INT", nullable = true },
  { name = "payload", database_type = "JSON", nullable = true },
  { name = "broken", database_type = "JSON", nullable = true },
}

local function cell(kind, text, value_kind)
  if kind == "null" then return { kind = "null" } end
  return { kind = "text", text = text, value_kind = value_kind }
end

local function data_row(id, payload, broken)
  return {
    cell("text", tostring(id), "integer"),
    cell("null"),
    cell("text", ""),
    cell("text", "0", "boolean"),
    cell("text", "0", "integer"),
    cell("text", payload or payload_raw),
    cell("text", broken or "{not-json"),
  }
end

-- 12 retained rows. A warehouse_id-style filter keeps 5 matching sources:
-- 0, 3, 6, 9, 11 so page boundaries (page_size=2) are crossed inside Inspect.
local rows = {}
for i = 0, 11 do
  rows[i + 1] = data_row(i + 1)
  rows[i + 1][1] = cell("text", tostring(i + 1), "integer")
end
rows[1][6] = cell("text", payload_raw)
rows[2][2] = cell("text", "NULL")
rows[2][3] = cell("text", "value")
rows[2][4] = cell("text", "true", "boolean")
rows[2][5] = cell("text", "2", "integer")
rows[2][6] = cell("text", '{"nested":{"n":2}}')

local matching = { 0, 3, 6, 9, 11 }

local calls = {}
local fake = {}
local active_filter = false
local view_updates = 0
function fake.result(op, payload, callback)
  calls[#calls + 1] = { op = op, payload = payload }
  if op == "view" then
    local source = payload.source_row or (payload.offset or 0)
    callback({ metadata = { columns = columns }, rows = { rows[source + 1] }, source_rows = { source }, total_rows = active_filter and #matching or #rows, view_id = active_filter and "v1" or nil }, nil)
  elseif op == "filter" then
    if payload.expression == "bad" then
      callback({ valid = false, error = "invalid filter" }, nil)
    else
      active_filter = true
      callback({ view_id = "v1", total_rows = #matching, matching_indices = matching, source_rows = matching }, nil)
    end
  elseif op == "cell" then
    local row = rows[payload.row + 1]
    local item = row and row[payload.column + 1]
    local tree
    if item and item.text and item.text:find("{", 1, true) == 1 and item.text:find("nested", 1, true) then
      tree = payload_tree
      if payload.row == 1 then
        tree = { type = "object", raw = item.text, children = {
          { key = { type = "string", raw = '"nested"' }, node = { type = "object", raw = '{"n":2}', children = {
            { key = { type = "string", raw = '"n"' }, node = { type = "number", raw = "2" } },
          } } },
        } }
      end
    elseif item and item.text then
      tree = { type = "raw", raw = item.text }
    end
    callback({ cell = item, tree = tree }, nil)
  elseif op == "compare" then
    callback({ differences = { { name = "id", status = "different" } } }, nil)
  elseif op == "export" then
    callback({ progress = true, export_id = payload.export_id, row_count = 123, bytes = 456 }, nil)
    return { cancel = function() end }
  elseif op == "export_cancel" then
    callback({ progress = false, export_id = payload.export_id }, nil)
  end
end

local result = {
  status = "success",
  query = "select 1",
  result_handle = "h1",
  generation = 1,
  connection_name = "test",
  database = "db",
  rows = rows,
  columns = columns,
  auto_limit_applied = true,
}
local original_payload = rows[1][6].text
local state = inspect.open(result, {
  runner = fake,
  page_size = 2,
  on_view_change = function() view_updates = view_updates + 1 end,
})
assert(state and state.handle == "h1")
local function text() return text_of(state) end

-- Header + compact fields, no per-field SQL type dump.
assert(text():find("matching 1/12", 1, true), "starts at first retained row")
assert(text():find("source 1/12", 1, true), "source ordinal is 1-based")
assert(text():find("page 1/", 1, true), "page is shown")
assert(text():find("execution: automatic outer LIMIT 500 applied", 1, true), "keeps execution metadata")
assert(not text():find("[INT]", 1, true) and not text():find("[JSON]", 1, true), "exact SQL types are not repeated on every field")
assert(line_with(state, "sql_null"):find("NULL", 1, true), "SQL NULL is labelled NULL")
assert(line_with(state, "empty"):find('""', 1, true), "empty string is distinct from NULL")
assert(line_with(state, "flag"):find("false", 1, true), "boolean false is visible")
assert(line_with(state, "zero"):find("0", 1, true), "numeric zero is visible")
assert(line_with(state, "payload"):find("▶", 1, true), "structured values start collapsed")
assert(not child_line(state, "products") and not child_line(state, "nested"), "JSON children are not listed until expand")
assert(count_op(calls, "view") == 0, "opening Inspect does not page the runner")
assert(count_op(calls, "cell") == 0, "opening Inspect does not parse JSON")
assert(count_op(calls, "filter") == 0, "opening Inspect does not re-run CEL")

-- Local matching-row navigation, including page boundaries, without runner ops.
local views = count_op(calls, "view")
local cells = count_op(calls, "cell")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_match == 2 and state.current_source == 1, "next row uses retained source index")
assert(text():find("matching 2/12", 1, true) and text():find("source 2/12", 1, true), "header tracks next source row")
assert(text():find("page 1/", 1, true), "page 1 still contains matching 2 with page_size 2")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_match == 3 and state.current_source == 2, "third matching row")
assert(text():find("page 2/", 1, true), "row navigation crosses the grid page boundary")
assert(count_op(calls, "view") == views and count_op(calls, "cell") == cells, "row navigation does not call view/cell")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]p") end)
assert(state.current_match == 5 and state.current_source == 4, "next page jumps to first matching row of that page")
assert(text():find("matching 5/12", 1, true) and text():find("page 3/", 1, true), "page jump updates header")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal [p") end)
assert(state.current_match == 3, "previous page returns to the start of the previous page")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal [r") end)
assert(state.current_match == 2 and state.current_source == 1, "previous matching row")

-- CEL filter walks matching rows, not all retained rows.
inspect.filter(state, "bad")
assert(state.filter == nil and state.matching_count == 12 and view_updates == 0, "invalid filter keeps previous view")
inspect.filter(state, "id in [1, 4, 7, 10, 12]")
assert(state.filter == "id in [1, 4, 7, 10, 12]" and state.matching_count == 5 and state.current_source == 0 and result.view_active and result.view_source_rows[1] == 0 and view_updates == 1, "valid filter maps matching source index")
assert(text():find("local filter: id in [1, 4, 7, 10, 12]", 1, true), "inspector shows the active local filter")
assert(text():find("matching 1/5", 1, true) and text():find("source 1/12", 1, true), "filtered inspect starts at matching 1 / source 1")
views, cells = count_op(calls, "view"), count_op(calls, "cell")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_match == 2 and state.current_source == 3, "next matching row skips non-matching retained rows")
assert(text():find("matching 2/5", 1, true) and text():find("source 4/12", 1, true), "source stays the original retained ordinal")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_match == 3 and state.current_source == 6, "matching 3 is source 7")
assert(text():find("page 2/", 1, true), "filtered navigation crosses page boundaries")
assert(count_op(calls, "view") == views, "filtered row navigation does not re-page the runner")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]p") end)
assert(state.current_match == 5 and state.current_source == 11, "filtered page jump uses matching rows")
assert(text():find("matching 5/5", 1, true) and text():find("source 12/12", 1, true), "last matching source is retained")

-- Pin survives navigation; compare stays available but is not required to render a diff UI.
inspect.pin(state)
assert(state.pinned_source == 11, "pin tracks source row")
assert(text():find("pinned", 1, false), "pinned row is visible in the inspector")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal [r") end)
assert(state.pinned_source == 11 and state.current_source == 9, "pinned source survives navigation")
assert(text():find("pinned source 12", 1, true) or text():find("pinned 12", 1, true), "header keeps the pinned source while browsing")
inspect.compare(state)
assert(calls[#calls].op == "compare" and calls[#calls].payload.result_handle == "h1", "compare uses immutable handle")

-- Clear filter restores retained navigation without corrupting Inspect.
inspect.clear_filter(state)
assert(state.filter == nil and state.matching_count == 12 and not result.view_active and result.view_source_rows == nil and view_updates == 2, "clear filter restores all retained rows")
assert(state.pinned_source == 11, "clearing the filter does not drop the pinned row")
assert(text():find("matching 1/12", 1, true), "clear filter returns Inspect to retained rows")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_source == 1 and state.matching_count == 12, "Inspect still navigates after clear")

-- Lazy JSON tree: collapsed by default, expand/collapse, nested object/array, invalid JSON, raw intact.
inspect.set_row(state, 1)
cursor_on(state, "payload")
assert(line_with(state, "payload"):find("▶", 1, true), "payload stays collapsed until Enter")
feed("<CR>")
assert(count_op(calls, "cell") >= 1, "expand loads one cell tree lazily")
cells = count_op(calls, "cell")
assert(text():find("▼", 1, true), "expanded structured node uses a down marker")
assert(child_line(state, "gone") and child_line(state, "gone"):find("null", 1, true), "JSON null is distinct from SQL NULL")
assert(child_line(state, "nested"), "object children are listed")
assert(child_line(state, "products") and child_line(state, "products"):find("▶", 1, true), "nested arrays stay collapsed")
assert(child_line(state, "products"):find("[4]", 1, true), "collapsed array shows length")
assert(not child_line(state, "61.92"), "array elements are not expanded automatically")
assert(rows[1][6].text == original_payload, "expanding JSON does not rewrite the ResultSet cell")
cursor_on(state, "nested")
feed("za")
assert(child_line(state, "900719925474099312345"), "expanded tree preserves exact >2^53 numeric lexeme")
assert(count_op(calls, "cell") == cells, "nested expand uses the already loaded tree")
cursor_on(state, "products")
feed("<CR>")
assert(child_line(state, "[0]") and child_line(state, "[3]"), "array children are addressable")
cursor_on(state, "[0]")
feed("<CR>")
assert(child_line(state, "61.92"), "array element expands to fields")
cursor_on(state, "payload")
feed("gR")
assert(line_with(state, "payload"):find("(raw)", 1, true), "raw/formatted toggle is per cell")
assert(not child_line(state, "[0]"), "raw mode hides the structured tree")
feed("gR")
assert(not (line_with(state, "payload") or ""):find("(raw)", 1, true), "toggling again restores formatted presentation")
cursor_on(state, "broken")
feed("<CR>")
assert(rows[1][7].text == "{not-json", "invalid JSON leaves the raw cell intact")
assert(not (line_with(state, "broken") or ""):find("▼", 1, true), "invalid JSON does not become a fake tree")

-- Metadata on demand uses driver column facts, not inferred keys.
local notes = {}
local previous_notify = vim.notify
vim.notify = function(message, level)
  notes[#notes + 1] = tostring(message)
  return previous_notify(message, level)
end
cursor_on(state, "id")
feed("K")
assert(notes[#notes]:find("id", 1, true) and notes[#notes]:find("INT", 1, true) and notes[#notes]:find("NOT NULL", 1, true), "K shows name, SQL type, and nullable")
assert(not notes[#notes]:find("PRIMARY KEY", 1, true), "K does not invent a primary key")
cursor_on(state, "payload")
feed("K")
assert(notes[#notes]:find("JSON", 1, true) and notes[#notes]:find("nullable", 1, true), "K shows JSON column metadata")
cursor_on(state, "nested")
feed("yj")
assert(vim.fn.getreg('"'):find("nested", 1, true), "JSONPath of the current node can be copied")
cursor_on(state, "id")
feed("yn")
assert(vim.fn.getreg('"') == "id", "column name can be copied")
vim.notify = previous_notify

-- STALE inspect keeps the same retained rows / handle.
result.status = "stale"
inspect.sync(state)
assert(text():find("STALE", 1, true), "stale header is visible in Inspect")
assert(state.handle == "h1" and state.current_source == 0, "stale Inspect does not mix another execution")
result.generation = 2
inspect.filter(state, "id in [1, 4, 7, 10, 12]")
assert(state.filter == nil, "callbacks from a newer generation do not rewrite Inspect")

local export_notifications = {}
previous_notify = vim.notify
vim.notify = function(message, level)
  export_notifications[#export_notifications + 1] = tostring(message)
  return previous_notify(message, level)
end
inspect.export(state, "filtered", "jsonl", vim.fn.tempname())
assert(calls[#calls].op == "export" and calls[#calls].payload.scope == "filtered" and calls[#calls].payload.export_id, "export carries explicit scope and cancel ID")
assert(export_notifications[#export_notifications]:find("123 rows", 1, true) and export_notifications[#export_notifications]:find("456 bytes", 1, true), "export progress uses authoritative row_count and bytes")
inspect.cancel_export(state)
assert(calls[#calls].op == "export_cancel" and calls[#calls].payload.export_id, "export cancellation targets export ID")
vim.notify = previous_notify

local keymaps = vim.api.nvim_buf_get_keymap(state.buf, "n")
local seen = {}
for _, map in ipairs(keymaps) do seen[map.lhs] = true end
assert(seen["[r"] and seen["]r"] and seen["[p"] and seen["]p"] and seen["p"] and seen["yv"] and seen["yr"] and seen["yn"] and seen["yj"] and seen["K"], "inspector navigation, pin, and copy mappings installed")
vim.api.nvim_win_close(state.win, true)
print("querybook inspector tests passed")
vim.cmd("qa!")
