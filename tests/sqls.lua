-- sqls LSP integration: missing binary, sqlite mapping, restart on connection
-- change, mysql password isolation, and no config.yml writes.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

local orig_executable = vim.fn.executable
local orig_exepath = vim.fn.exepath
local orig_lsp_start = vim.lsp.start
local orig_get_clients = vim.lsp.get_clients
local orig_get_active = vim.lsp.get_active_clients
local orig_stop_client = vim.lsp.stop_client
local orig_notify = vim.notify

local sqls_installed = false
local starts, clients, next_client = {}, {}, 0

vim.fn.executable = function(name)
  if name == "sqls" then return sqls_installed and 1 or 0 end
  return orig_executable(name)
end
vim.fn.exepath = function(name)
  if name == "sqls" then return sqls_installed and "/stub/sqls" or "" end
  return orig_exepath(name)
end

local function list_clients(filter)
  local out = {}
  for _, client in pairs(clients) do
    if not filter or not filter.name or client.name == filter.name then
      out[#out + 1] = client
    end
  end
  return out
end

vim.lsp.get_clients = list_clients
vim.lsp.get_active_clients = list_clients
vim.lsp.stop_client = function(id)
  clients[id] = nil
end
vim.lsp.start = function(config)
  next_client = next_client + 1
  local id = next_client
  local client = {
    id = id,
    name = config.name,
    config = config,
    server_capabilities = { executeCommandProvider = true, codeActionProvider = true },
    notify = function() end,
    stop = function() clients[id] = nil end,
  }
  if config.on_init then config.on_init(client) end
  if config.on_attach then config.on_attach(client, vim.api.nvim_get_current_buf()) end
  clients[id] = client
  starts[#starts + 1] = { config = config, client = client }
  return id
end

local function restore()
  pcall(function() require("querybook.sqls").stop() end)
  vim.fn.executable = orig_executable
  vim.fn.exepath = orig_exepath
  vim.lsp.start = orig_lsp_start
  vim.lsp.get_clients = orig_get_clients
  vim.lsp.get_active_clients = orig_get_active
  vim.lsp.stop_client = orig_stop_client
  vim.notify = orig_notify
end
vim.api.nvim_create_autocmd("VimLeavePre", { callback = restore })

local store = vim.fn.tempname() .. ".connections.sqlite"
local db = vim.fn.tempname() .. ".sqlite3"
local querybook = require("querybook")
querybook.setup({
  runner_path = root .. "/bin/querybook-runner",
  connection_store_path = store,
  connections = { sqlite = { driver = "sqlite", path = db } },
  active_connection = "sqlite",
  timeout_ms = 5000,
})
local connections = require("querybook.connections")
local runner = require("querybook.runner")
local sqls = require("querybook.sqls")

local function request(op, payload)
  local result, err
  runner.connection(op, payload or {}, function(event, failure) result, err = event, failure end)
  if not vim.wait(5000, function() return result ~= nil or err ~= nil end) then
    error("NO RESPONSE " .. op)
  end
  assert(result ~= nil or err ~= nil, op .. " response")
  assert(not err, op .. ": " .. tostring(err))
  return result
end

local function contains_secret(value, needle)
  if type(value) ~= "table" then
    return tostring(value or ""):find(needle, 1, true) ~= nil
  end
  for k, v in pairs(value) do
    if contains_secret(k, needle) or contains_secret(v, needle) then return true end
  end
  return false
end

local function glob_sqls_configs(dir)
  local found = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/**/sqls/config.y*ml", true, true)) do
    found[#found + 1] = path
  end
  for _, path in ipairs(vim.fn.glob(dir .. "/**/config.yml", true, true)) do
    if path:find("sqls", 1, true) then found[#found + 1] = path end
  end
  return found
end

-- 1 + 5. Missing sqls: Querybook still runs, no LSP start, no config.yml.
sqls_installed = false
starts = {}
vim.fn.writefile({}, db)
local cwd = vim.fn.getcwd()
local before_cwd = glob_sqls_configs(cwd)
local before_tmp = glob_sqls_configs(vim.fn.fnamemodify(store, ":h"))
vim.cmd("enew")
vim.bo.filetype = "sql"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT 1 AS one;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.run({})
local ns = vim.api.nvim_create_namespace("querybook")
local function texts()
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do out[#out + 1] = line[1][1] end
  end
  return table.concat(out, "\n")
end
assert(vim.wait(5000, function()
  return connections.active() ~= nil and not texts():find("RUNNING", 1, true) and texts():find("1 retained rows", 1, true) ~= nil
end), "sqlite QuerybookRun without sqls")
vim.wait(200)
assert(#starts == 0, "sqls must not start when missing")
assert(vim.deep_equal(before_cwd, glob_sqls_configs(cwd)), "cwd sqls config.yml created")
assert(vim.deep_equal(before_tmp, glob_sqls_configs(vim.fn.fnamemodify(store, ":h"))), "tmp sqls config.yml created")

-- 2. sqls present: sqlite mapping, init_options, cache stays password-free.
sqls_installed = true
starts, clients, next_client = {}, {}, 0
local path_a = vim.fn.tempname() .. "-a.sqlite3"
local created_a = request("create", { connection = { name = "sqls-a", driver = "sqlite", path = path_a } })
local id_a = created_a.connection.id
local resolved_a = created_a.connection.path
request("select", { connection_id = id_a })
connections.list(function() end)
assert(vim.wait(5000, function() return connections.active() and connections.active().id == id_a end), "select A")
vim.bo.filetype = "sql"
sqls.sync()
assert(vim.wait(5000, function() return #starts >= 1 end), "sqls start for sqlite")
local first = starts[#starts].config
assert(first.name == "querybook-sqls", "client name")
assert(first.settings and first.settings.sqls and first.settings.sqls.connections, "settings.sqls.connections")
assert(#first.settings.sqls.connections == 1, "exactly one sqls connection")
assert(first.settings.sqls.connections[1].driver == "sqlite3", "sqlite3 driver")
assert(first.settings.sqls.connections[1].dataSourceName == resolved_a, "sqlite dataSourceName")
assert(first.init_options and first.init_options.connectionConfig and first.init_options.connectionConfig.driver == "sqlite3", "init_options.connectionConfig")
assert(type(first.cmd) == "table" and (first.cmd[1] == "/stub/sqls" or first.cmd[1] == "sqls"), "sqls cmd")
local cached = connections._connections[id_a]
assert(cached, "sqlite cache entry")
assert(cached.passwd == nil and cached.password == nil and cached.dataSourceName == nil, "cache has no sqls secrets")
sqls.stop()
starts, clients, next_client = {}, {}, 0
connections._connections, connections._active_id = {}, nil
sqls.sync()
assert(vim.wait(5000, function() return #starts >= 1 end), "empty Lua cache still starts sqls from store")
assert(starts[#starts].config.settings.sqls.connections[1].dataSourceName == resolved_a, "empty cache uses persisted active path")
local starts_after_first = #starts
vim.cmd("enew")
vim.bo.filetype = "sql"
sqls.sync()
assert(#starts == starts_after_first, "second sql buffer must attach, not restart")

-- 3. Connection change restarts sqls with the new sqlite path.
local path_b = vim.fn.tempname() .. "-b.sqlite3"
local created_b = request("create", { connection = { name = "sqls-b", driver = "sqlite", path = path_b } })
local id_b = created_b.connection.id
local resolved_b = created_b.connection.path
local starts_before_b = #starts
request("select", { connection_id = id_b })
connections.list(function() end)
assert(vim.wait(5000, function() return connections.active() and connections.active().id == id_b end), "select B")
sqls.sync()
assert(vim.wait(5000, function() return #starts > starts_before_b end), "sqls restarted for B")
local second = starts[#starts].config
assert(second.settings.sqls.connections[1].dataSourceName == resolved_b, "second start uses B")
assert(second.settings.sqls.connections[1].dataSourceName ~= resolved_a, "second start must not keep A")

-- 4. mysql sqls_settings returns passwd to LSP only, never to the Lua cache.
local sentinel = "querybook-sqls-sentinel@/"
local mysql
local mysql_ok, mysql_err = pcall(function()
  mysql = request("create", {
    connection = { name = "sqls-mysql", driver = "mysql", host = "127.0.0.1", user = "root", database = "app" },
    password = sentinel,
  })
end)
if mysql_ok then
  local mysql_id = mysql.connection.id
  request("select", { connection_id = mysql_id })
  connections.list(function() end)
  assert(vim.wait(5000, function() return connections.active() and connections.active().id == mysql_id end), "select mysql")
  local starts_before_mysql = #starts
  sqls.sync({ force = true })
  assert(vim.wait(5000, function() return #starts > starts_before_mysql end), "sqls start for mysql")
  local mysql_cfg = starts[#starts].config
  local sqls_conn = mysql_cfg.settings.sqls.connections[1]
  assert(sqls_conn, "sqls connections")
  assert(sqls_conn.passwd == sentinel, "passwd reaches vim.lsp.start settings")
  assert(sqls_conn.proto == "tcp", "mysql proto")
  assert(sqls_conn.dataSourceName == nil or sqls_conn.dataSourceName == "", "no mysql dsn")
  assert(mysql_cfg.init_options.connectionConfig.passwd == sentinel, "passwd reaches init_options")
  connections.list(function() end)
  assert(vim.wait(5000, function() return connections._connections[mysql_id] ~= nil end), "mysql listed")
  assert(not contains_secret(connections._connections, sentinel), "list cache leaked sentinel")
  assert(not contains_secret(connections.active(), sentinel), "active cache leaked sentinel")
  assert(rawget(sqls, "sqls") == nil and rawget(sqls, "_sqls") == nil and rawget(sqls, "_settings") == nil, "sqls module retained settings")
  local starts_before_force = #starts
  sqls.sync({ force = true })
  assert(vim.wait(5000, function() return #starts > starts_before_force end), "force restart of the same connection")
  assert(starts[#starts].config.settings.sqls.connections[1].passwd == sentinel, "force restart still uses mysql passwd")
  request("delete", { connection_id = mysql_id })
else
  error("mysql create failed: " .. tostring(mysql_err))
end

-- Vim sql ftplugin <Left>/<Right> maps flash Noice's Calculator cmdline.
assert(vim.g.omni_sql_no_default_maps == 1, "sqlcomplete default maps must stay disabled")
vim.cmd("enew")
vim.bo.filetype = "sql"
vim.keymap.set("i", "<Right>", "<C-R>=sqlcomplete#DrillIntoTable()<CR>", { buffer = true })
vim.keymap.set("i", "<Left>", "<C-R>=sqlcomplete#DrillOutOfColumns()<CR>", { buffer = true })
vim.cmd("doautocmd FileType sql")
local leftover = {}
for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "i")) do
  if type(map.rhs) == "string" and map.rhs:find("sqlcomplete#", 1, true) then
    leftover[#leftover + 1] = (map.lhs or "") .. " -> " .. map.rhs
  end
end
assert(#leftover == 0, "sqlcomplete insert maps still present: " .. table.concat(leftover, "; "))

pcall(sqls.stop)
vim.fn.executable = orig_executable
vim.fn.exepath = orig_exepath
vim.lsp.start = orig_lsp_start
vim.lsp.get_clients = orig_get_clients
vim.lsp.get_active_clients = orig_get_active
vim.lsp.stop_client = orig_stop_client
vim.notify = orig_notify
vim.cmd("qa!")
