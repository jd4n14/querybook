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
  max_columns = 12,
  max_value_length = 128,
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

local function json_string(value)
  if vim.json and vim.json.encode then return vim.json.encode(tostring(value)) end
  return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function json_value(row, column)
  local value, is_null = render.value(row, column)
  return is_null and "null" or json_string(value)
end

local function row_payload(result, row)
  local fields = {}
  for _, column in ipairs(result.columns) do
    fields[#fields + 1] = json_string(column) .. ":" .. json_value(row, column)
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function full_payload(result)
  local rows = {}
  for _, row in ipairs(result.rows or {}) do rows[#rows + 1] = row_payload(result, row) end
  return "{\"connection\":" .. json_string(result.connection_name or "connection")
    .. ",\"database\":" .. json_string(result.database or "")
    .. ",\"columns\":[" .. table.concat(vim.tbl_map(json_string, result.columns or {}), ",")
    .. "],\"rows\":[" .. table.concat(rows, ",") .. "]}"
end

local function pretty_json(value)
  local lines, line, depth, quoted, escaped = {}, "", 0, false, false
  local function push()
    if line ~= "" then lines[#lines + 1] = string.rep("  ", depth) .. line; line = "" end
  end
  for i = 1, #value do
    local char = value:sub(i, i)
    if quoted then
      line = line .. char
      if escaped then escaped = false elseif char == "\\" then escaped = true elseif char == '"' then quoted = false end
    elseif char == '"' then quoted, line = true, line .. char
    elseif char:match("%s") then
      -- JSON whitespace outside strings is formatting noise.
    elseif char == "{" or char == "[" then
      line = line .. char; push(); depth = depth + 1
    elseif char == "}" or char == "]" then
      push(); depth = math.max(0, depth - 1); line = char
    elseif char == "," then
      line = line .. char; push()
    elseif char == ":" then
      line = line .. ": "
    else
      line = line .. char
    end
  end
  push()
  return lines
end

local function copy_register(text)
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
  vim.notify("Querybook: copied " .. (#text) .. " characters", vim.log.levels.INFO)
end

local function inspect_content(result)
  local content, locations = {}, {}
  local function add(line, location)
    content[#content + 1] = line
    locations[#content] = location
  end
  add("-- " .. result.status .. " · " .. result.query)
  add("connection: " .. tostring(result.connection_name or "connection"))
  add("driver: " .. tostring(result.connection_driver or "unknown"))
  add("database: " .. tostring(result.database or "(none)"))
  add("rows: " .. tostring(#(result.rows or {})) .. " · columns: " .. tostring(#(result.columns or {})))
  if result.status == "error" then
    add(result.error or "query failed")
    return content, locations
  end
  for row_index, row in ipairs(result.rows or {}) do
    add("", nil)
    add("row " .. row_index, { kind = "row", row = row_index })
    for _, column in ipairs(result.columns or {}) do
      local value, is_null = render.value(row, column)
      local text = is_null and "NULL" or tostring(value)
      local is_json = not is_null and text:match("^%s*[%[{].*[%]}]%s*$")
      if is_json then
        add("  " .. column .. " (JSON):", { kind = "field", row = row_index, column = column })
        local pretty = pretty_json(text)
        for _, line in ipairs(pretty) do add("    " .. line, { kind = "field", row = row_index, column = column }) end
      else
        local value_lines = vim.split(text, "\n", { plain = true })
        add("  " .. column .. ": " .. (value_lines[1] or ""), { kind = "field", row = row_index, column = column })
        for line_index = 2, #value_lines do add("    " .. value_lines[line_index], { kind = "field", row = row_index, column = column }) end
      end
    end
  end
  if #result.rows == 0 then add("(no rows)", nil) end
  return content, locations
end

function M.run(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local queries = {}
  if opts and opts.range and opts.range > 0 then
    local lines = vim.api.nvim_buf_get_lines(bufnr, opts.line1 - 1, opts.line2, false)
    local selected = parser.parse(lines)
    if #selected > 1 then
      -- A visual selection containing multiple statements gets one extmark
      -- and one retained result per statement, preserving independent state.
      for _, statement in ipairs(selected) do
        local global_statement = vim.deepcopy(statement)
        global_statement.start_line = global_statement.start_line + opts.line1 - 1
        global_statement.end_line = global_statement.end_line + opts.line1 - 1
        queries[#queries + 1] = { query = statement_text(bufnr, global_statement), anchor = global_statement.end_line }
      end
    else
      queries[1] = { query = table.concat(lines, "\n"), anchor = opts.line2 }
    end
  else
    local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local statement = parser.statement_at(parser.parse(all), vim.api.nvim_win_get_cursor(0)[1])
    if not statement then return vim.notify("Querybook: cursor is not inside a SQL statement", vim.log.levels.WARN) end
    queries[1] = { query = statement_text(bufnr, statement), anchor = statement.end_line }
  end
  for _, item in ipairs(queries) do
    if item.query:gsub("%s", "") == "" then return vim.notify("Querybook: empty SQL", vim.log.levels.WARN) end
    local analysis = risk.analyze(item.query)
    if analysis.dangerous and not (opts and opts.force) and not M.config.allow_writes then
      return vim.notify("Querybook blocked: " .. table.concat(analysis.reasons, "; ") .. " (use :QuerybookRun! or allow_writes)", vim.log.levels.WARN)
    end
  end
  local conn, name = connection()
  if not conn then return vim.notify("Querybook: unknown connection " .. tostring(M.config.active_connection), vim.log.levels.ERROR) end
  local bs = buffer_state(bufnr)
  local function execute_one(item)
    local old = find_current_result(bufnr, { start_line = item.anchor, end_line = item.anchor })
    bs.next_id = bs.next_id + 1
    local result = {
      id = bs.next_id, query = item.query, status = "running", rows = {}, columns = {},
      connection_name = name, connection_profile = name, connection_driver = conn.driver,
      database = conn.database or conn.path, duration_ms = 0,
    }
    result.extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, item.anchor - 1, 0, { right_gravity = false, virt_lines = render.lines(result, M.config), virt_lines_above = false, virt_lines_leftcol = true })
    bs.results[result.id] = result
    local started = vim.loop.hrtime()
    runner.run(conn, item.query, function(data, err)
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
  for _, item in ipairs(queries) do execute_one(item) end
end

function M.inspect()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local statements = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local current = parser.statement_at(statements, cursor)
  local best = current and find_current_result(bufnr, current)
  if not best then return vim.notify("Querybook: no result near cursor", vim.log.levels.WARN) end
  local content, locations = inspect_content(best)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "querybook"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  local function current_location()
    return locations[vim.api.nvim_win_get_cursor(0)[1]]
  end
  vim.keymap.set("n", "yv", function()
    local location = current_location()
    if not location or location.kind ~= "field" then return vim.notify("Querybook: place cursor on a field", vim.log.levels.WARN) end
    copy_register(render.value(best.rows[location.row], location.column) == nil and "NULL" or render.value_text(best.rows[location.row], location.column))
  end, { buffer = buf, silent = true, desc = "Copy exact Querybook field" })
  vim.keymap.set("n", "yr", function()
    local location = current_location()
    if not location or not location.row then return vim.notify("Querybook: place cursor on a row", vim.log.levels.WARN) end
    copy_register(row_payload(best, best.rows[location.row]))
  end, { buffer = buf, silent = true, desc = "Copy exact Querybook row JSON" })
  vim.keymap.set("n", "yp", function() copy_register(full_payload(best)) end, { buffer = buf, silent = true, desc = "Copy exact Querybook payload JSON" })
  local width, height = math.min(vim.o.columns - 4, 120), math.min(vim.o.lines - 6, math.max(4, #content + 1))
  vim.api.nvim_open_win(buf, true, { relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2), width = width, height = height, style = "minimal", border = "rounded" })
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, silent = true })
end

function M.toggle()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local current = parser.statement_at(parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), cursor)
  if not current then return vim.notify("Querybook: cursor is not inside a SQL statement", vim.log.levels.WARN) end
  local result = find_current_result(bufnr, current)
  if not result then return vim.notify("Querybook: no result near cursor", vim.log.levels.WARN) end
  result.collapsed = not result.collapsed
  render_result(bufnr, result)
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
    vim.api.nvim_create_user_command("QuerybookToggle", M.toggle, { desc = "Collapse or expand Querybook result" })
    vim.api.nvim_create_user_command("QuerybookRefresh", M.refresh, { desc = "Re-run Querybook result" })
    vim.api.nvim_create_user_command("QuerybookClear", function(command_opts) M.clear(command_opts.bang) end, { bang = true, desc = "Clear Querybook result" })
    M._commands_created = true
  end
  local group = vim.api.nvim_create_augroup("Querybook", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, { group = group, callback = function(args) if state[args.buf] then refresh_stale(args.buf) end end })
end

return M
