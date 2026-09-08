local M = {}
local process, receive_buffer, next_request = nil, "", 0
local pending, initialized = {}, false
local max_line = 2 * 1024 * 1024
local function encode(value) return vim.json.encode(value) .. "\n" end
local function emit_error(item, message)
  if not item or item.done then return end
  item.done = true; pending[item.execution_id] = nil; item.callback(nil, message)
end
local function dispatch(line)
  if #line > max_line then return end
  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= "table" or event.version ~= 1 or event.type == "ready" then return end
  local item = pending[event.execution_id]
  if not item or item.done or event.generation ~= item.generation then return end
  local result_set = event.result_set or 0
  if event.type == "result_start" then
    item.data.resultsets = item.data.resultsets or {}
    local rs = { columns = event.columns or {}, rows = {} }; item.data.resultsets[result_set + 1] = rs
    if result_set == 0 then item.data.columns, item.data.rows = rs.columns, rs.rows end
  elseif event.type == "rows" then
    local rs = item.data.resultsets and item.data.resultsets[result_set + 1]
    if rs then for _, row in ipairs(event.rows or {}) do rs.rows[#rs.rows + 1] = row end end
    if result_set == 0 then item.data.rows = rs and rs.rows or item.data.rows end
  elseif event.type == "result_end" then
    item.done = true; pending[event.execution_id] = nil; for k, v in pairs(event) do item.data[k] = v end; item.callback(item.data, nil, event)
  elseif event.type == "cancelled" then
    item.done = true; pending[event.execution_id] = nil; item.callback(nil, "Querybook: execution cancelled", event)
  elseif event.type == "error" and event.terminal then
    item.done = true; pending[event.execution_id] = nil; item.callback(nil, "Querybook: " .. tostring(event.message or event.code or "query failed"), event)
  end
end
local function on_stdout(_, data)
  data = data or {}
  receive_buffer = receive_buffer .. table.concat(data, "\n")
  if data[#data] == "" then receive_buffer = receive_buffer .. "\n" end
  while true do local newline = receive_buffer:find("\n", 1, true); if not newline then break end; local line = receive_buffer:sub(1, newline - 1); receive_buffer = receive_buffer:sub(newline + 1); if line ~= "" then dispatch(line) end end
  if #receive_buffer > max_line then receive_buffer = "" end
end
local function on_exit(_, code)
  process = nil; local message = "Querybook: runner exited" .. (code and (" (code " .. code .. ")") or "")
  for _, item in pairs(pending) do emit_error(item, message) end; pending = {}; receive_buffer = ""
end
local function plugin_root() return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h") end
local function executable(config)
  local path = config and config.runner_path; if path and path ~= "" then return path end
  local found = vim.fn.exepath("querybook-runner"); if found and found ~= "" then return found end
  local bundled = plugin_root() .. "/bin/querybook-runner"; if vim.fn.executable(bundled) == 1 then return bundled end
end
local function ensure_process(config)
  if process and process > 0 then return true end
  local path = executable(config); if not path then vim.notify("Querybook: querybook-runner is missing; run `make build` in the plugin directory", vim.log.levels.ERROR); return false end
  process = vim.fn.jobstart({ path }, { rpc = false, stdin = "pipe", stdout = "pipe", stderr = "pipe", on_stdout = on_stdout, on_exit = on_exit })
  if process <= 0 then process = nil; vim.notify("Querybook: could not start querybook-runner", vim.log.levels.ERROR); return false end; return true
end
function M.run(connection, sql, opts, callback)
  if type(opts) == "function" then callback, opts = opts, {} end; opts = opts or {}; callback = callback or function() end
  local config = M.config or {}
  if not ensure_process(M.config or {}) then callback(nil, "Querybook: runner unavailable"); return nil end
  next_request = next_request + 1; local execution_id = tostring(next_request) .. "-" .. tostring(vim.loop.hrtime()); local generation = opts.generation or next_request
  local item = { execution_id = execution_id, generation = generation, callback = callback, data = { rows = {}, columns = {} } }; pending[execution_id] = item
  local request = { version = 1, type = "execute", request_id = tostring(next_request), execution_id = execution_id, generation = generation, connection = connection, sql = sql, force = opts.force == true, timeout_ms = opts.timeout_ms or config.timeout_ms, max_retained_rows = opts.max_retained_rows or config.max_retained_rows, max_retained_bytes = opts.max_retained_bytes or config.max_retained_bytes, batch_rows = opts.batch_rows or config.batch_rows, batch_bytes = opts.batch_bytes or config.batch_bytes }
  local ok, err = pcall(vim.fn.chansend, process, encode(request)); if not ok then emit_error(item, "Querybook: runner input failed: " .. tostring(err)) end
  return { execution_id = execution_id, generation = generation, cancel = function() M.cancel(execution_id) end }
end
function M.cancel(execution_id)
  if pending[execution_id] and process then pcall(vim.fn.chansend, process, encode({ version = 1, type = "cancel", execution_id = execution_id })) end
end
function M.shutdown()
  if process then pcall(vim.fn.chansend, process, encode({ version = 1, type = "shutdown" })); process = nil end
  for _, item in pairs(pending) do emit_error(item, "Querybook: runner stopped") end; pending = {}; receive_buffer = ""
end
function M._reset() M.shutdown(); initialized = false end
function M.setup(config)
  M.config = config or M.config or {}; if initialized then return end; initialized = true
  vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.shutdown })
end
return M
