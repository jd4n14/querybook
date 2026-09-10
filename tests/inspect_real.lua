-- Real Go runner + Neovim inspector smoke test.  Every metadata path is
-- temporary; this test never selects or writes a user's connection store.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local querybook = require("querybook")
local runner = require("querybook.runner")

local store = vim.fn.tempname() .. ".connections.sqlite"
querybook.setup({
  runner_path = root .. "/bin/querybook-runner",
  connection_store_path = store,
  connections = { sqlite = { name = "inspect test", driver = "sqlite", path = ":memory:" } },
  active_connection = "sqlite",
  timeout_ms = 5000,
})
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "WITH RECURSIVE nums(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM nums WHERE n < 19) SELECT CAST(n AS INTEGER) AS n, '900719925474099312345' AS large, NULL AS sql_null, '' AS empty, x'00FF' AS blob, '{\"n\":900719925474099312345}' AS payload FROM nums;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.run({})
local function result_text()
  local ns = vim.api.nvim_create_namespace("querybook")
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do out[#out + 1] = line[1][1] end
  end
  return table.concat(out, "\n")
end
assert(vim.wait(5000, function() return result_text():find("20 retained rows", 1, true) ~= nil end), "real result completion")
querybook.inspect()
local view = querybook._inspect_state
assert(view and view.handle, "inspector receives result handle")
local response, failure
runner.result("cell", { result_handle = view.handle, row = 0, column = 4 }, function(data, err) response, failure = data, err end)
assert(vim.wait(5000, function() return response ~= nil or failure ~= nil end), "real cell response")
assert(not failure and response.cell and response.cell.kind == "binary" and response.cell.base64 == "AP8=", "binary cell remains exact base64")
local tree_response
runner.result("cell", { result_handle = view.handle, row = 0, column = 5, tree_depth = 64, tree_bytes = 1024 * 1024 }, function(data, err) tree_response, failure = data, err end)
assert(vim.wait(5000, function() return tree_response ~= nil or failure ~= nil end), "real JSON tree response")
assert(not failure and tree_response.tree and vim.inspect(tree_response.tree):find("900719925474099312345", 1, true), "JSON tree keeps >2^53 numeric lexeme")
-- SQLite reports an empty database type for expression columns. Mark this
-- test fixture as the explicit structured metadata a provider would return,
-- then exercise the real inspector's lazy Enter/za path against Go's tree.
view.columns[6].database_type = "JSON"
for line, location in pairs(view.locations or {}) do
  if location.kind == "field" and location.column == 6 then vim.api.nvim_win_set_cursor(view.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
assert(vim.wait(1000, function() return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n"):find('"n":', 1, true) ~= nil end), "real inspector expands Go JSON tree")
for line, value in ipairs(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)) do
  if value:find('"n":', 1, true) then vim.api.nvim_win_set_cursor(view.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("za"), "x", false)
assert(table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n"):find("900719925474099312345", 1, true), "real inspector nested tree preserves numeric lexeme")
for line, location in pairs(view.locations or {}) do
  if location.kind == "field" and location.column == 6 then vim.api.nvim_win_set_cursor(view.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("gR"), "x", false)
assert(vim.wait(1000, function() return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n"):find("payload [structured] (raw)", 1, true) ~= nil end), "real inspector raw/formatted toggle uses live cell")
for line, location in pairs(view.locations or {}) do
  if location.kind == "field" and location.column == 5 then vim.api.nvim_win_set_cursor(view.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("yv"), "x", false)
assert(vim.wait(1000, function() return vim.fn.getreg('"') == "base64:AP8=" end), "binary inspect copy preserves typed cell")
local pages
runner.result("view", { result_handle = view.handle, offset = 0, limit = 1 }, function(data, err) pages, failure = data, err end)
assert(vim.wait(5000, function() return pages ~= nil or failure ~= nil end), "real page response")
assert(not failure and pages.source_rows and pages.source_rows[1] == 0 and pages.total_rows == 20, "single row page preserves source ordinal")
local filtered
runner.result("filter", { result_handle = view.handle, filter = "@['$values'][0] >= \"11\" && @['$values'][0] <= \"19\"" }, function(data, err) filtered, failure = data, err end)
assert(vim.wait(5000, function() return filtered ~= nil or failure ~= nil end), "real all-retained filter response")
assert(not failure and filtered.view_id and filtered.total_rows == 9, "filter evaluates all retained rows")
local filtered_page
runner.result("view", { result_handle = view.handle, view_id = filtered.view_id, offset = 0, limit = 1 }, function(data, err) filtered_page, failure = data, err end)
assert(vim.wait(5000, function() return filtered_page ~= nil or failure ~= nil end), "real filtered page response")
assert(not failure and filtered_page.source_rows and filtered_page.source_rows[1] == 11, "filtered page preserves source index")
vim.api.nvim_win_close(view.win, true)
print("querybook real inspector tests passed")
vim.cmd("qa!")
