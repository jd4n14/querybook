-- Native Neovim manager for Querybook's persisted connections.
--
-- This module deliberately has no password state. Passwords are captured by
-- inputsecret only for create/set_password and passed immediately to the
-- runner's private JSONL stdin request. They are never form fields, list data,
-- cache entries, callbacks, or execution configuration.
local runner = require("querybook.runner")

local M = { _connections = {}, _active_id = nil, _loading = false, _waiters = {} }
local metadata_keys = { "name", "driver", "host", "port", "database", "username", "socket", "path", "charset" }

local function notify(message, level)
  vim.notify("Querybook: " .. tostring(message), level or vim.log.levels.INFO)
end

local function scratch(buf, filetype)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = filetype or "querybook-connections"
  vim.bo[buf].modifiable = true
end

local function float(buf, width, height)
  width = math.max(44, math.min(vim.o.columns - 4, width or 96))
  height = math.max(8, math.min(vim.o.lines - 4, height or 16))
  return vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2), width = width,
    height = height, style = "minimal", border = "rounded",
  })
end

local function metadata(value)
  local out = {}
  value = value or {}
  for _, key in ipairs(metadata_keys) do
    local v = value[key]
    if v == nil and key == "username" then v = value.user end
    if v ~= nil and v ~= "" then out[key] = tostring(v) end
  end
  if out.port then out.port = tonumber(out.port) or out.port end
  return out
end

local function wire_metadata(value)
  local out = metadata(value)
  if out.username then out.user, out.username = out.username, nil end
  return out
end

local function normalize(item)
  local c = metadata(item)
  c.id = item.id or item.connection_id
  c.connection_id = item.connection_id or item.id
  return c
end

local function apply_response(event)
  local list = event.connections or event.items
  if type(list) == "table" then
    M._connections = {}
    for _, item in ipairs(list) do
      local c = normalize(item)
      if c.connection_id then M._connections[c.connection_id] = c end
    end
  elseif event.connection then
    local c = normalize(event.connection)
    if c.connection_id then M._connections[c.connection_id] = c end
  end
  if event.active_connection_id ~= nil then M._active_id = event.active_connection_id end
  if event.connection_id and event.op == "select" then M._active_id = event.connection_id end
end

function M.setup(config)
  local old_store = M.config and (M.config.connection_store_path or M.config.store_path)
  M.config = config or {}
  local new_store = M.config.connection_store_path or M.config.store_path
  if old_store ~= nil and old_store ~= new_store then
    M._connections, M._active_id, M._loading, M._waiters = {}, nil, false, {}
  end
  -- Older configurations could contain an inline password. Remove the field
  -- immediately and never inspect its value or use it as an execution path.
  -- Importing those profiles remains an explicit manager action.
  if type(M.config.connections) == "table" then
    for _, item in pairs(M.config.connections) do
      if type(item) == "table" then
        if rawget(item, "password") ~= nil or rawget(item, "pass") ~= nil then
          item.password, item.pass = nil, nil
          notify("inline connection password ignored; use QuerybookConnections", vim.log.levels.WARN)
        end
      end
    end
  end
  runner.setup(M.config)
end

function M.list(callback)
  callback = callback or function() end
  return runner.connection("list", {}, function(event, err)
    if err then callback(nil, err); return end
    apply_response(event)
    callback(M._connections, nil, event)
  end)
end

function M.ensure_active(callback)
  callback = callback or function() end
  local active = M._active_id and M._connections[M._active_id]
  if active then callback(active, nil); return end
  M._waiters[#M._waiters + 1] = callback
  if M._loading then return end
  M._loading = true
  M.list(function(_, err)
    local c = M._active_id and M._connections[M._active_id]
    if not c and M.config and M.config.active_connection and M._connections[M.config.active_connection] then
      c = M._connections[M.config.active_connection]
      M._active_id = c.connection_id
    end
    -- The built-in SQLite notebook remains zero-configuration. This is the
    -- only automatic metadata bootstrap; legacy MySQL profiles require an
    -- explicit QuerybookConnectionsImport action.
    if not c and not err and vim.tbl_isempty(M._connections) then
      local configured = M.config and M.config.connections and M.config.connections[M.config.active_connection or "sqlite"]
      local default = configured and configured.driver == "sqlite" and wire_metadata(configured) or {
        name = "sqlite", driver = "sqlite", path = vim.fn.stdpath("data") .. "/querybook.sqlite3"
      }
      default.name = default.name or M.config.active_connection or "sqlite"
      runner.connection("create", { connection = default }, function(event, create_err)
        if not create_err and event.connection then
          apply_response(event)
          local id = event.connection.id or event.connection.connection_id
          if id then
            runner.connection("select", { connection_id = id }, function(selected, select_err)
              if not select_err then apply_response(selected); c = M._connections[id] end
              M._loading = false
              local waiters = M._waiters; M._waiters = {}
              for _, waiter in ipairs(waiters) do waiter(c, select_err or (not c and "Querybook: no active connection")) end
            end)
            return
          end
        end
        M._loading = false
        local waiters = M._waiters; M._waiters = {}
        for _, waiter in ipairs(waiters) do waiter(nil, create_err or "Querybook: no active connection") end
      end)
      return
    end
    M._loading = false
    local waiters = M._waiters; M._waiters = {}
    for _, waiter in ipairs(waiters) do waiter(c, err or (not c and "Querybook: no active connection")) end
  end)
end

function M.active()
  return M._active_id and M._connections[M._active_id] or nil
end

local function confirm_empty_password()
  return vim.fn.confirm("Use an empty password?", "&Cancel\n&Use empty password", 1) == 2
end

local function input_password(prompt, callback)
  vim.fn.inputsave()
  local ok, value = pcall(vim.fn.inputsecret, prompt)
  vim.fn.inputrestore()
  if not ok then callback(nil, true); return end
  value = value or ""
  -- inputsecret returns an empty string both for an empty password and for
  -- Esc. An explicit confirmation makes those outcomes distinct.
  if value == "" and not confirm_empty_password() then callback(nil, true); return end
  callback(value, false)
end

function M._capture_password(prompt, callback)
  input_password(prompt, callback)
end

local function fields_for(c)
  local lines = { "# Querybook connection metadata (s to save, q to cancel)" }
  c = c or {}
  for _, key in ipairs(metadata_keys) do
    lines[#lines + 1] = key .. " = " .. tostring(c[key] or "")
  end
  return lines
end

function M._parse_form(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and vim.tbl_contains(metadata_keys, key) then
      if value ~= "" then out[key] = value end
    end
  end
  if out.port then out.port = tonumber(out.port) or out.port end
  return out
end

local function open_form(existing, mode, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  scratch(buf, "querybook-connection-form")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, fields_for(existing))
  local form_win = float(buf, 76, #metadata_keys + 4)
  vim.bo[buf].modifiable = true
  local function cancel()
    if vim.api.nvim_win_is_valid(form_win) then vim.api.nvim_win_close(form_win, true) end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true, desc = "Cancel connection form" })
  vim.keymap.set("n", "s", function()
    local form = M._parse_form(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    if form.name == nil or form.name == "" then return notify("connection name is required", vim.log.levels.WARN) end
    if form.driver ~= "sqlite" and form.driver ~= "mysql" then return notify("driver must be sqlite or mysql", vim.log.levels.WARN) end
    if form.driver == "sqlite" and (form.path == nil or form.path == "") then return notify("SQLite path is required", vim.log.levels.WARN) end
    callback(form, mode, cancel)
  end, { buffer = buf, silent = true, desc = "Save connection metadata" })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  vim.cmd("normal! G")
end

local list_buf, list_win, list_locations
local function list_lines()
  local lines, locations = { "Querybook Connections", "", "Enter select · a add · e edit · p password · d delete · t test · q close", "" }, {}
  local ids = vim.tbl_keys(M._connections)
  table.sort(ids, function(a, b) return tostring(M._connections[a].name or a):lower() < tostring(M._connections[b].name or b):lower() end)
  for _, id in ipairs(ids) do
    local c = M._connections[id]
    local marker = id == M._active_id and "*" or " "
    lines[#lines + 1] = string.format("%s %-24s %-7s %s", marker, c.name or id, c.driver or "", c.database or c.path or "")
    locations[#lines] = id
  end
  if #ids == 0 then lines[#lines + 1] = "(no saved connections)" end
  return lines, locations
end

local function redraw_list()
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then return end
  local lines, locations = list_lines(); list_locations = locations
  vim.bo[list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.bo[list_buf].modifiable = false
end

local function selected_id()
  return list_locations and list_locations[vim.api.nvim_win_get_cursor(0)[1]]
end

local function reopen_list()
  if list_buf and vim.api.nvim_buf_is_valid(list_buf) then vim.api.nvim_set_current_buf(list_buf); redraw_list(); return end
  M.open()
end

local function mutate(op, payload, after)
  runner.connection(op, payload, function(event, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    apply_response(event)
    if after then after(event) end
    reopen_list()
    redraw_list()
  end)
end

-- Explicit, user-invoked metadata-only import for a legacy config profile.
-- The profile is copied through the allowlist and its password is never read.
function M.import_legacy(name)
  local profile = M.config and M.config.connections and M.config.connections[name]
  if type(profile) ~= "table" then return notify("unknown legacy profile " .. tostring(name), vim.log.levels.ERROR) end
  open_form(metadata(profile), "create", function(form, _, cancel)
    if form.driver == "mysql" then
      M._capture_password("Password (Esc cancels): ", function(password, cancelled)
        if cancelled then return end
        cancel(); local payload = { connection = wire_metadata(form), password = password }; mutate("create", payload)
      end)
    else cancel(); mutate("create", { connection = wire_metadata(form) }) end
  end)
end

function M.open()
  if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
    if not list_win or not vim.api.nvim_win_is_valid(list_win) then
      list_win = float(list_buf, 112, math.min(24, #vim.tbl_keys(M._connections) + 6))
    else
      vim.api.nvim_set_current_buf(list_buf)
    end
    redraw_list(); return list_buf
  end
  list_buf = vim.api.nvim_create_buf(false, true)
  scratch(list_buf)
  list_win = float(list_buf, 112, math.min(24, #vim.tbl_keys(M._connections) + 6))
  vim.bo[list_buf].modifiable = false
  local function id_or_warn()
    local id = selected_id()
    if not id then notify("select a saved connection first", vim.log.levels.WARN) end
    return id
  end
  vim.keymap.set("n", "q", function()
    if list_win and vim.api.nvim_win_is_valid(list_win) then vim.api.nvim_win_close(list_win, true) end
  end, { buffer = list_buf, silent = true, desc = "Close connections" })
  vim.keymap.set("n", "<CR>", function()
    local id = id_or_warn(); if not id then return end
    mutate("select", { connection_id = id }, function() notify("active connection: " .. tostring(M._connections[id].name or id)) end)
  end, { buffer = list_buf, silent = true })
  vim.keymap.set("n", "a", function()
    open_form(nil, "create", function(form, _, cancel)
      if form.driver == "mysql" then
        M._capture_password("Password (Esc cancels): ", function(password, cancelled)
          if cancelled then return end
          cancel(); local payload = { connection = wire_metadata(form), password = password }; mutate("create", payload)
        end)
      else cancel(); mutate("create", { connection = wire_metadata(form) }) end
    end)
  end, { buffer = list_buf, silent = true })
  vim.keymap.set("n", "e", function()
    local id = id_or_warn(); if not id then return end
    open_form(M._connections[id], "update", function(form, _, cancel)
      cancel(); mutate("update", { connection_id = id, connection = wire_metadata(form) })
    end)
  end, { buffer = list_buf, silent = true })
  vim.keymap.set("n", "p", function()
    local id = id_or_warn(); if not id then return end
    M._capture_password("New password (empty clears; Esc cancels): ", function(password, cancelled)
      if cancelled then return end
      mutate("set_password", { connection_id = id, password = password })
    end)
  end, { buffer = list_buf, silent = true })
  vim.keymap.set("n", "d", function()
    local id = id_or_warn(); if not id then return end
    if vim.fn.confirm("Delete " .. tostring(M._connections[id].name or id) .. "?", "&Cancel\n&Delete", 1) == 2 then
      mutate("delete", { connection_id = id }, function() M._connections[id] = nil; if M._active_id == id then M._active_id = nil end end)
    end
  end, { buffer = list_buf, silent = true })
  vim.keymap.set("n", "t", function()
    local id = id_or_warn(); if not id then return end
    runner.connection("test", { connection_id = id }, function(event, err)
      if err then notify(err, vim.log.levels.ERROR); return end
      notify(event.message or ("connection test passed: " .. tostring(M._connections[id].name or id)))
    end)
  end, { buffer = list_buf, silent = true })
  runner.setup(M.config or {})
  M.list(function(_, err)
    if err then notify(err, vim.log.levels.ERROR) else redraw_list() end
  end)
  return list_buf
end

function M.refresh()
  return M.list(function(_, err) if err then notify(err, vim.log.levels.ERROR) else redraw_list() end end)
end

return M
