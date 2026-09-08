local parser = require("querybook.parser")
local render = require("querybook.render")
local risk = require("querybook.risk")
local runner = require("querybook.runner")

local M = {}
local ns = vim.api.nvim_create_namespace("querybook")
local state = {}
local defaults = {
  active_connection = "sqlite",
  connections = { sqlite = { driver = "sqlite", path = vim.fn.stdpath("data") .. "/querybook.sqlite3" } },
  max_rows = 50,
  max_column_width = 32,
  allow_writes = false,
}

local function buffer_state(bufnr)
  state[bufnr] = state[bufnr] or { results = {}, next_id = 0 }
  return state[bufnr]
end

local function statement_text(bufnr, statement)
  local lines = vim.api.nvim_buf_get_lines(bufnr, statement.start_line - 1, statement.end_line, false)
  if #lines == 0 then return "" end
  if #lines == 1 then return vim.trim(lines[1]:sub(statement.start_col, statement.end_col)) end
  lines[1] = lines[1]:sub(statement.start_col)
  lines[#lines] = lines[#lines]:sub(1, statement.end_col)
  return vim.trim(table.concat(lines, "\n"))
end

local function result_position(bufnr, result)
  if not result.extmark or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, result.extmark, {})
  return pos[1] and pos[1] + 1 or nil
end

local function render_result(bufnr, result)
  local line = result_position(bufnr, result)
  if not line then return end
  vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
    id = result.extmark,
    right_gravity = false,
    virt_lines = render.lines(result, M.config),
    virt_lines_above = false,
    virt_lines_leftcol = true,
  })
end

local function refresh_stale(bufnr)
  local current = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  for _, result in pairs(buffer_state(bufnr).results) do
    local line = result_position(bufnr, result)
    local statement = line and parser.statement_at(current, line)
    local changed = not statement or statement_text(bufnr, statement) ~= result.query
    if result.status ~= "error" then result.status = changed and "stale" or "success" end
    render_result(bufnr, result)
  end
end

local function find_current_result(bufnr, statement)
  local found
  for _, result in pairs(buffer_state(bufnr).results) do
    local line = result_position(bufnr, result)
    if line and line >= statement.start_line and line <= statement.end_line
        and (not found or result.id > found.id) then found = result end
  end
  return found
end

local function remove_result(bufnr, result)
  if result.extmark then pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, result.extmark) end
  buffer_state(bufnr).results[result.id] = nil
end

local function connection()
  return M.config.connections[M.config.active_connection], M.config.active_connection
end

function M.run(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines, anchor, query
  if opts and opts.range and opts.range > 0 then
    lines = vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false)
    query, anchor = table.concat(lines, "\n"), opts.line2
  else
    local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local statement = parser.statement_at(parser.parse(all), vim.api.nvim_win_get_cursor(0)[1])
    if not statement then return vim.notify("Querybook: cursor is not inside a SQL statement", vim.log.levels.WARN) end
    query, anchor = statement_text(bufnr, statement), statement.end_line
  end
  if query:gsub("%s", "") == "" then return vim.notify("Querybook: empty SQL", vim.log.levels.WARN) end
  local analysis = risk.analyze(query)
  if analysis.dangerous and not (opts and opts.force) and not M.config.allow_writes then
    return vim.notify("Querybook blocked: " .. table.concat(analysis.reasons, "; ") .. " (use :QuerybookRun! or allow_writes)", vim.log.levels.WARN)
  end
  local conn, name = connection()
  if not conn then return vim.notify("Querybook: unknown connection " .. tostring(M.config.active_connection), vim.log.levels.ERROR) end
  local bs = buffer_state(bufnr)
  local old = find_current_result(bufnr, { start_line = anchor, end_line = anchor })
  bs.next_id = bs.next_id + 1
  local result = { id = bs.next_id, query = query, status = "running", rows = {}, columns = {}, connection_name = name, duration_ms = 0 }
  result.extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor - 1, 0, { right_gravity = false, virt_lines = render.lines(result, M.config), virt_lines_above = false, virt_lines_leftcol = true })
  bs.results[result.id] = result
  local started = vim.loop.hrtime()
  runner.run(conn, query, function(data, err)
    result.duration_ms = math.floor((vim.loop.hrtime() - started) / 1000000)
    if err then result.status, result.error = "error", err
    else
      result.status, result.rows, result.columns = "success", data.rows, data.columns
      -- A successful refresh replaces the previous execution. On failure the
      -- old result remains visible beside the new error, preserving context.
      if old and bs.results[old.id] then remove_result(bufnr, old) end
    end
    render_result(bufnr, result)
  end)
end

function M.inspect()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local statements = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local current = parser.statement_at(statements, cursor)
  local best = current and find_current_result(bufnr, current)
  if not best then return vim.notify("Querybook: no result near cursor", vim.log.levels.WARN) end
  local content = { "-- " .. best.status .. " · " .. best.query, "" }
  if best.status == "error" then content[#content + 1] = best.error
  else
    content[#content + 1] = table.concat(best.columns, "\t")
    for _, row in ipairs(best.rows) do
      local values = {}; for _, column in ipairs(best.columns) do values[#values + 1] = tostring(row[column] or "NULL") end
      content[#content + 1] = table.concat(values, "\t")
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "querybook"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  local width, height = math.min(vim.o.columns - 4, 120), math.min(vim.o.lines - 6, math.max(4, #content + 1))
  vim.api.nvim_open_win(buf, true, { relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2), width = width, height = height, style = "minimal", border = "rounded" })
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
end

function M.refresh()
  M.run({})
end

function M.clear(all)
  local bufnr = vim.api.nvim_get_current_buf()
  local bs = buffer_state(bufnr)
  if all then for _, result in pairs(bs.results) do remove_result(bufnr, result) end
  else
    local current = parser.statement_at(parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), vim.api.nvim_win_get_cursor(0)[1])
    if current then local result = find_current_result(bufnr, current); if result then remove_result(bufnr, result) end end
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  render.setup_highlights()
  if not M._commands_created then
    vim.api.nvim_create_user_command("QuerybookRun", function(command_opts) M.run({ range = command_opts.range, line1 = command_opts.line1, line2 = command_opts.line2, force = command_opts.bang }) end, { range = true, bang = true, desc = "Run SQL under cursor or visual selection" })
    vim.api.nvim_create_user_command("QuerybookInspect", M.inspect, { desc = "Inspect Querybook result" })
    vim.api.nvim_create_user_command("QuerybookRefresh", M.refresh, { desc = "Re-run Querybook result" })
    vim.api.nvim_create_user_command("QuerybookClear", function(command_opts) M.clear(command_opts.bang) end, { bang = true, desc = "Clear Querybook result" })
    M._commands_created = true
  end
  local group = vim.api.nvim_create_augroup("Querybook", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, { group = group, callback = function(args) if state[args.buf] then refresh_stale(args.buf) end end })
end

return M
