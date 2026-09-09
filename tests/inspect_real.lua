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
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT '900719925474099312345' AS large, NULL AS sql_null, '' AS empty, x'00FF' AS blob;" })
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
assert(vim.wait(5000, function() return result_text():find("1 retained rows", 1, true) ~= nil end), "real result completion")
querybook.inspect()
local view = querybook._inspect_state
assert(view and view.handle, "inspector receives result handle")
local response, failure
runner.result("cell", { result_handle = view.handle, row = 0, column = 3 }, function(data, err) response, failure = data, err end)
assert(vim.wait(5000, function() return response ~= nil or failure ~= nil end), "real cell response")
assert(not failure and response.cell and response.cell.kind == "binary" and response.cell.base64 == "AP8=", "binary cell remains exact base64")
for line, location in pairs(view.locations or {}) do
  if location.kind == "field" and location.column == 4 then vim.api.nvim_win_set_cursor(view.win, { line, 0 }); break end
end
vim.api.nvim_feedkeys(vim.keycode("yv"), "x", false)
assert(vim.wait(1000, function() return vim.fn.getreg('"') == "base64:AP8=" end), "binary inspect copy preserves typed cell")
local pages
runner.result("view", { result_handle = view.handle, offset = 0, limit = 1 }, function(data, err) pages, failure = data, err end)
assert(vim.wait(5000, function() return pages ~= nil or failure ~= nil end), "real page response")
assert(not failure and pages.source_rows and pages.source_rows[1] == 0 and pages.total_rows == 1, "single row page preserves source ordinal")
vim.api.nvim_win_close(view.win, true)
print("querybook real inspector tests passed")
vim.cmd("qa!")
