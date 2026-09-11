-- Inspector UI contract tests.  The fake registry models handle based view,
-- filter, compare, and export calls without opening a database or touching a
-- user's connection store.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local inspect = require("querybook.inspect")

local rows = {
  { { kind = "text", text = "900719925474099312345" }, { kind = "null" }, { kind = "text", text = "" }, { kind = "text", text = "false" }, { kind = "text", text = '{"nested":{"n":900719925474099312345}}' } },
  { { kind = "text", text = "second" }, { kind = "text", text = "NULL" }, { kind = "text", text = "value" }, { kind = "text", text = "true" }, { kind = "text", text = '{"nested":{"n":2}}' } },
}
local columns = {
  { name = "large", database_type = "DECIMAL" },
  { name = "sql_null", database_type = "VARCHAR" },
  { name = "empty", database_type = "VARCHAR" },
  { name = "bool_text", database_type = "VARCHAR" },
  { name = "payload", database_type = "JSON" },
}
local calls = {}
local fake = {}
local active_filter = false
local view_updates = 0
function fake.result(op, payload, callback)
  calls[#calls + 1] = { op = op, payload = payload }
  if op == "view" then
    local filtered = payload.view_id == "v1"
    local source = payload.source_row or (filtered and 1 or (payload.offset or 0))
    callback({ metadata = { columns = columns }, rows = { rows[source + 1] }, source_rows = { source }, total_rows = filtered and 1 or 2, view_id = filtered and "v1" or nil }, nil)
  elseif op == "filter" then
    if payload.expression == "bad" then callback({ valid = false, error = "invalid filter" }, nil)
    else active_filter = true; callback({ view_id = "v1", total_rows = 1, matching_indices = { 1 }, source_rows = { 1 } }, nil) end
  elseif op == "cell" then
    local tree = { type = "object", raw = rows[payload.row + 1][payload.column + 1].text, children = {
      { key = { type = "string", raw = '"nested"' }, node = { type = "object", raw = '{"n":900719925474099312345}', children = {
        { key = { type = "string", raw = '"n"' }, node = { type = "number", raw = "900719925474099312345" } },
      } } },
    } }
    callback({ cell = rows[payload.row + 1][payload.column + 1], tree = tree }, nil)
  elseif op == "compare" then callback({ differences = { { name = "large", status = "different" } } }, nil)
  elseif op == "export" then callback({ progress = true, export_id = payload.export_id, rows = 0, bytes = 0 }, nil); return { cancel = function() end }
  elseif op == "export_cancel" then callback({ progress = false, export_id = payload.export_id }, nil) end
end

local result = { status = "success", query = "select 1", result_handle = "h1", generation = 1, connection_name = "test", database = "db", rows = rows, columns = columns }
local state = inspect.open(result, { runner = fake, page_size = 1, on_view_change = function() view_updates = view_updates + 1 end })
assert(state and state.handle == "h1")
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end
assert(text():find("900719925474099312345", 1, true), "large integer keeps exact spelling")
assert(text():find("large %[%]", 1, false) == nil, "metadata type is not replaced by guessed content type")
assert(text():find("structured", 1, true), "JSON metadata receives structured category")
assert(text():find("NULL", 1, true) and text():find("empty [VARCHAR] = ", 1, true), "null and empty text remain distinct")
for line, value in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
  if value:find("payload", 1, true) then vim.api.nvim_win_set_cursor(state.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
assert(text():find('"nested":', 1, true), "structured JSON tree expands lazily from exact runner presentation")
for line, value in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
  if value:find('"nested":', 1, true) then vim.api.nvim_win_set_cursor(state.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
assert(text():find("900719925474099312345", 1, true), "expanded tree preserves exact >2^53 numeric lexeme")
vim.api.nvim_feedkeys(vim.keycode("gR"), "x", false)
assert(text():find("payload [structured] (raw)", 1, true), "raw/formatted toggle changes only inspector presentation")

inspect.filter(state, "bad")
assert(state.filter == nil and state.matching_count == 2 and view_updates == 0, "invalid filter keeps previous view")
inspect.filter(state, ".nested")
assert(state.filter == ".nested" and state.matching_count == 1 and state.current_source == 1 and result.view_active and result.view_source_rows[1] == 1 and view_updates == 1, "valid filter maps matching source index")
inspect.clear_filter(state)
assert(state.filter == nil and state.matching_count == 2 and not result.view_active and result.view_source_rows == nil and view_updates == 2, "clear filter restores all retained rows")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_source == 1 and calls[#calls].op == "view" and calls[#calls].payload.limit == 1, "row navigation requests one matching row")
inspect.pin(state)
assert(state.pinned_source == state.current_source, "pin tracks source row")
inspect.compare(state)
assert(calls[#calls].op == "compare" and calls[#calls].payload.result_handle == "h1", "compare uses immutable handle")
inspect.export(state, "filtered", "jsonl", vim.fn.tempname())
assert(calls[#calls].op == "export" and calls[#calls].payload.scope == "filtered" and calls[#calls].payload.export_id, "export carries explicit scope and cancel ID")
inspect.cancel_export(state)
assert(calls[#calls].op == "export_cancel" and calls[#calls].payload.export_id, "export cancellation targets export ID")

local keymaps = vim.api.nvim_buf_get_keymap(state.buf, "n")
local seen = {}; for _, map in ipairs(keymaps) do seen[map.lhs] = true end
assert(seen["[r"] and seen["]r"] and seen["[p"] and seen["]p"] and seen["yv"] and seen["yr"] and seen["K"], "inspector navigation and copy mappings installed")
vim.api.nvim_win_close(state.win, true)
print("querybook inspector tests passed")
vim.cmd("qa!")
