-- Managed connection protocol and native UI smoke test. Uses a unique store
-- so this test never reads or changes a user's connection metadata.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local querybook = require("querybook")
local connections = require("querybook.connections")
local runner = require("querybook.runner")
querybook.setup({ runner_path = root .. "/bin/querybook-runner", connection_store_path = vim.fn.tempname() .. ".connections.sqlite", timeout_ms = 5000 })

local function request(op, payload)
  local result, err
  runner.connection(op, payload or {}, function(event, failure) result, err = event, failure end)
  if not vim.wait(5000, function() return result ~= nil or err ~= nil end) then print("NO RESPONSE " .. op) end
  assert(result ~= nil or err ~= nil, op .. " response")
  assert(not err, op .. ": " .. tostring(err))
  return result
end

local path = vim.fn.tempname() .. ".sqlite3"
local created = request("create", { connection = { name = "UI smoke", driver = "sqlite", path = path } })
assert(created.connection and created.connection.id, "create returns managed UUID")
local id = created.connection.id
local listed = request("list")
assert(#(listed.connections or {}) == 1, "list returns metadata")
local updated = request("update", { connection_id = id, connection = { name = "UI smoke edited", driver = "sqlite", path = path } })
assert(updated.connection and updated.connection.name == "UI smoke edited", "update returns metadata")
local selected = request("select", { connection_id = id })
assert(selected.active_connection_id == id, "select persists active UUID")
request("test", { connection_id = id })
request("delete", { connection_id = id })
assert(#(request("list").connections or {}) == 0, "delete removes metadata")

local buf = connections.open()
assert(vim.bo[buf].buftype == "nofile")
assert(vim.bo[buf].swapfile == false)
assert(vim.bo[buf].undolevels == -1)
local config = vim.api.nvim_win_get_config(0)
assert(type(config.border) == "table" and config.border[1] == "╭", "manager uses rounded float")
vim.api.nvim_win_close(0, true)
vim.cmd("qa!")
