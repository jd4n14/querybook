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
function fake.result(op, payload, callback)
  calls[#calls + 1] = { op = op, payload = payload }
  if op == "view" then
    local filtered = payload.view_id == "v1"
    local source = payload.source_row or (filtered and 1 or (payload.offset or 0))
    local tree = { kind = "object", children = {
      { key = { raw = '"nested"' }, node = { kind = "object", children = {
        { key = { raw = '"n"' }, node = { kind = "number", raw = "900719925474099312345" } },
      } } },
    } }
    callback({ metadata = { columns = columns }, rows = { rows[source + 1] }, source_rows = { source }, total_rows = filtered and 1 or 2, view_id = filtered and "v1" or nil, trees = { ["0:5"] = tree } }, nil)
  elseif op == "filter" then
    if payload.expression == "bad" then callback({ valid = false, error = "invalid filter" }, nil)
    else active_filter = true; callback({ view_id = "v1", total_rows = 1 }, nil) end
  elseif op == "compare" then callback({ differences = { { name = "large", status = "different" } } }, nil)
  elseif op == "export" then callback({ path = payload.path }, nil) end
end

local result = { status = "success", query = "select 1", result_handle = "h1", generation = 1, connection_name = "test", database = "db", rows = rows, columns = columns }
local state = inspect.open(result, { runner = fake, page_size = 1 })
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

inspect.filter(state, "bad")
assert(state.filter == nil and state.matching_count == 2, "invalid filter keeps previous view")
inspect.filter(state, ".nested")
assert(state.filter == ".nested" and state.matching_count == 1 and state.current_source == 1, "valid filter maps matching source index")
inspect.clear_filter(state)
assert(state.filter == nil and state.matching_count == 2, "clear filter restores all retained rows")
vim.api.nvim_buf_call(state.buf, function() vim.cmd("normal ]r") end)
assert(state.current_source == 1 and calls[#calls].op == "view" and calls[#calls].payload.limit == 1, "row navigation requests one matching row")
inspect.pin(state)
assert(state.pinned_source == state.current_source, "pin tracks source row")
inspect.compare(state)
assert(calls[#calls].op == "compare" and calls[#calls].payload.result_handle == "h1", "compare uses immutable handle")
inspect.export(state, "filtered", "jsonl", vim.fn.tempname())
assert(calls[#calls].op == "export" and calls[#calls].payload.scope == "filtered", "export carries explicit scope")

local keymaps = vim.api.nvim_buf_get_keymap(state.buf, "n")
local seen = {}; for _, map in ipairs(keymaps) do seen[map.lhs] = true end
assert(seen["[r"] and seen["]r"] and seen["[p"] and seen["]p"] and seen["yv"] and seen["yr"] and seen["K"], "inspector navigation and copy mappings installed")
vim.api.nvim_win_close(state.win, true)
print("querybook inspector tests passed")
vim.cmd("qa!")
