-- sqls LSP client for the active Querybook connection.
-- sqls reads workspace/didChangeConfiguration (and init_options.connectionConfig),
-- not workspace/configuration. Changing the active connection restarts sqls.
local runner = require("querybook.runner")

local M = {}
local setup_done, missing_notified, generation, started_id = false, false, 0, nil
local CLIENT_NAME = "querybook-sqls"
vim.g.omni_sql_no_default_maps = 1

local function notify(message, level)
  message = tostring(message)
  if not message:match("^Querybook:%s") then message = "Querybook: " .. message end
  vim.notify(message, level or vim.log.levels.INFO)
end

-- Vim's sql ftplugin maps <Left>/<Right> to <C-r>=sqlcomplete#... which Noice
-- shows as a flashing "Calculator" cmdline. Querybook uses sqls + the editor
-- completion UI, so disable those maps.
local function disable_sqlcomplete_arrow_maps(buf)
  vim.g.omni_sql_no_default_maps = 1
  if not buf or buf == 0 then buf = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
    if type(map.rhs) == "string" and map.rhs:find("sqlcomplete#", 1, true) then
      pcall(vim.api.nvim_buf_del_keymap, buf, "i", map.lhs)
    end
  end
end

local function get_clients(filter)
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  if not get then return {} end
  return get(filter) or {}
end

local function sqls_path()
  if vim.fn.executable("sqls") ~= 1 then return nil end
  local path = vim.fn.exepath("sqls")
  if path == nil or path == "" then return nil end
  return path
end

function M.stop()
  for _, client in ipairs(get_clients({ name = CLIENT_NAME })) do
    if type(client.stop) == "function" then
      pcall(function() client:stop(true) end)
    elseif vim.lsp.stop_client and client.id then
      pcall(vim.lsp.stop_client, client.id, true)
    end
  end
  started_id = nil
end

local function notify_did_change(client)
  local settings = client.config and client.config.settings
  if type(settings) ~= "table" then return end
  local payload = { settings = settings }
  local method = "workspace/didChangeConfiguration"
  if type(client.notify) == "function" then
    if pcall(function() client:notify(method, payload) end) then return end
    pcall(client.notify, client, method, payload)
    return
  end
  if vim.lsp.buf_notify then pcall(vim.lsp.buf_notify, 0, method, payload) end
end

local function sql_buffers()
  local bufs = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ft = vim.bo[buf].filetype
      if ft == "sql" or ft == "mysql" then bufs[#bufs + 1] = buf end
    end
  end
  return bufs
end

local function attach_sql_buffers(client_id)
  for _, buf in ipairs(sql_buffers()) do
    pcall(vim.lsp.buf_attach_client, buf, client_id)
  end
end

local function start_with(cfg, connection_id)
  local path = sqls_path()
  if not path then
    if not missing_notified then
      missing_notified = true
      notify("sqls is not installed; SQL completion requires sqls", vim.log.levels.WARN)
    end
    return
  end
  if type(cfg) ~= "table" or type(cfg.connections) ~= "table" or cfg.connections[1] == nil then
    notify("sqls did not return a connection", vim.log.levels.WARN)
    return
  end
  local bufs = sql_buffers()
  if #bufs == 0 then return end
  M.stop()
  local client_id = vim.lsp.start({
    name = CLIENT_NAME,
    cmd = { path },
    filetypes = { "sql", "mysql" },
    root_dir = vim.fn.getcwd(),
    settings = { sqls = cfg },
    init_options = { connectionConfig = cfg.connections[1] },
    on_init = function(client)
      notify_did_change(client)
    end,
    on_attach = function(client, _)
      if client.server_capabilities then
        client.server_capabilities.executeCommandProvider = false
        client.server_capabilities.codeActionProvider = false
      end
    end,
    reuse_client = function() return false end,
  }, { bufnr = bufs[1], reuse_client = function() return false end })
  if client_id then
    started_id = connection_id
    attach_sql_buffers(client_id)
  end
end

local function sync_active(active, opts)
  opts = opts or {}
  local id = active and (active.connection_id or active.id)
  if not id then
    M.stop()
    return
  end
  if not sqls_path() then
    if not missing_notified and #sql_buffers() > 0 then
      missing_notified = true
      notify("sqls is not installed; SQL completion requires sqls", vim.log.levels.WARN)
    end
    return
  end
  local existing = get_clients({ name = CLIENT_NAME })
  if not opts.force and started_id == id and #existing > 0 then
    attach_sql_buffers(existing[1].id)
    return
  end
  if #sql_buffers() == 0 then
    if started_id and started_id ~= id then M.stop() end
    return
  end
  generation = generation + 1
  local gen = generation
  runner.connection("sqls_settings", { connection_id = id }, function(event, err)
    if gen ~= generation then return end
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    start_with(event and event.sqls, id)
  end)
end

function M.sync(opts)
  local connections = require("querybook.connections")
  local active = connections.active()
  if active then
    sync_active(active, opts)
    return
  end
  connections.ensure_active(function(conn)
    if conn then sync_active(conn, opts) end
  end)
end

function M.setup()
  if setup_done then return end
  setup_done = true
  require("querybook.connections").set_active_listener(function(id, force)
    vim.schedule(function()
      if id == nil or id == "" then
        M.stop()
        return
      end
      M.sync({ force = force == true })
    end)
  end)
  vim.g.omni_sql_no_default_maps = 1
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("QuerybookSQLS", { clear = true }),
    pattern = { "sql", "mysql" },
    callback = function(args)
      disable_sqlcomplete_arrow_maps(args.buf)
      M.sync()
    end,
  })
  -- FileType may already have fired for buffers opened before setup.
  vim.schedule(function()
    local synced = false
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local ft = vim.bo[buf].filetype
        if ft == "sql" or ft == "mysql" then
          disable_sqlcomplete_arrow_maps(buf)
          if not synced then
            M.sync()
            synced = true
          end
        end
      end
    end
  end)
end

return M
