local parser = require("querybook.parser")
local render = require("querybook.render")
local risk = require("querybook.risk")
local runner = require("querybook.runner")
local connections = require("querybook.connections")
local inspect_view = require("querybook.inspect")

local M = {}
local ns = vim.api.nvim_create_namespace("querybook")
local state = {}
local defaults = {
  active_connection = nil,
  connections = {},
	preview_rows = 10,
  max_columns = 12,
  max_value_length = 128,
  max_column_width = 32,
  allow_writes = false,
  runner_path = nil,
  timeout_ms = 30000,
  max_retained_rows = 10000,
  max_retained_bytes = 16 * 1024 * 1024,
  batch_rows = 200,
  batch_bytes = 512 * 1024,
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

local remove_result

local function refresh_stale(bufnr)
	local current = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	local attached = {}
	for _, result in pairs(buffer_state(bufnr).results) do
		local line = result_position(bufnr, result)
		local statement = line and parser.statement_at(current, line)
		if not statement then
			if result.handle then result.handle.cancel() end
			remove_result(bufnr, result)
		else
			-- Buffer-wide edits can collapse several old extmarks onto one new
			-- statement. Keep the newest execution as that statement's one slot.
			local key = statement.start_line .. ":" .. statement.end_line
			if attached[key] then
				local duplicate = attached[key]
				if duplicate.id < result.id then
					if duplicate.handle then duplicate.handle.cancel() end
					remove_result(bufnr, duplicate)
					attached[key] = result
				else
					if result.handle then result.handle.cancel() end
					remove_result(bufnr, result)
				end
			else
				attached[key] = result
			end
			if attached[key] == result then
				local changed = statement_text(bufnr, statement) ~= result.query
				if result.status ~= "error" then result.status = changed and "stale" or "success" end
				render_result(bufnr, result)
			end
		end
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

local function release_result_handle(result)
  if not result or not result.result_handle or not runner.result then return end
  local handle = result.result_handle
  result.result_handle = nil
  runner.result("release", { result_handle = handle }, function() end)
end

remove_result = function(bufnr, result)
  if result.extmark then pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, result.extmark) end
  if M._inspect_state and M._inspect_state.result == result then
    M._inspect_state.closed = true
    if M._inspect_state.win and vim.api.nvim_win_is_valid(M._inspect_state.win) then pcall(vim.api.nvim_win_close, M._inspect_state.win, true) end
    M._inspect_state = nil
  end
  release_result_handle(result)
  buffer_state(bufnr).results[result.id] = nil
end

local function json_string(value)
  if vim.json and vim.json.encode then return vim.json.encode(tostring(value)) end
  return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

local function row_payload(result, row)
  local fields = {}
  for index, column in ipairs(result.columns or {}) do
    local value, is_null, cell = render.value(row, index)
    fields[#fields + 1] = { column = type(column) == "table" and column.name or tostring(column), value = is_null and vim.NIL or value, encoding = (cell and cell.kind == "binary") and "base64" or "text" }
  end
  return vim.json.encode(fields)
end

local function full_payload(result)
  local rows = {}
  for _, row in ipairs(result.rows or {}) do rows[#rows + 1] = row_payload(result, row) end
  local columns = {}; for _, column in ipairs(result.columns or {}) do columns[#columns + 1] = type(column) == "table" and column or { name = tostring(column) } end
  return vim.json.encode({ connection = result.connection_name or "connection", database = result.database or "", columns = columns, rows = vim.tbl_map(vim.json.decode, rows), truncated = result.truncated or false, truncation_reason = result.truncation_reason, auto_limit_applied = result.auto_limit_applied or false })
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
  for _, query_line in ipairs(vim.split("-- " .. result.status .. " · " .. result.query, "\n", { plain = true })) do add(query_line) end
  add("connection: " .. tostring(result.connection_name or "connection"))
  add("driver: " .. tostring(result.connection_driver or "unknown"))
  add("database: " .. tostring(result.database or "(none)"))
	add("rows: " .. tostring(#(result.rows or {})) .. " · columns: " .. tostring(#(result.columns or {})) .. (result.truncated and " · truncated" or ""))
	if result.auto_limit_applied then add("execution: automatic outer LIMIT 500 applied") end
	if result.status == "error" then
		add(result.error or "query failed")
		if result.previous_query then add("previous successful result retained from: " .. result.previous_query) end
	end
  for row_index, row in ipairs(result.rows or {}) do
    add("", nil)
    add("row " .. row_index, { kind = "row", row = row_index })
    for column_index, column in ipairs(result.columns or {}) do
      local value, is_null, cell = render.value(row, column_index)
      local text = is_null and "NULL" or tostring(value)
      local column_name = type(column) == "table" and column.name or tostring(column)
      if cell and cell.kind == "binary" then text = "base64:" .. text end
      local is_json = not is_null and text:match("^%s*[%[{].*[%]}]%s*$")
      if is_json then
        add("  " .. column_name .. " (JSON):", { kind = "field", row = row_index, column = column_index })
        local pretty = pretty_json(text)
        for _, line in ipairs(pretty) do add("    " .. line, { kind = "field", row = row_index, column = column_index }) end
      else
        local value_lines = vim.split(text, "\n", { plain = true })
        add("  " .. column_name .. ": " .. (value_lines[1] or ""), { kind = "field", row = row_index, column = column_index })
        for line_index = 2, #value_lines do add("    " .. value_lines[line_index], { kind = "field", row = row_index, column = column_index }) end
      end
    end
  end
  if #result.rows == 0 then add("(no rows)", nil) end
  return content, locations
end

function M.run(opts)
	local bufnr = vim.api.nvim_get_current_buf()
	refresh_stale(bufnr)
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
  local function execute_queries(conn)
  runner.setup(M.config)
  local name = conn.connection_id or conn.id
  local display_name = conn.name or name
  if not name then return vim.notify("Querybook: active connection has no id", vim.log.levels.ERROR) end
	local bs = buffer_state(bufnr)
	if not vim.b[bufnr].querybook_viewport_maps then
		vim.keymap.set("n", "<leader>qN", "<Cmd>QuerybookNextPage<CR>", { buffer = bufnr, silent = true, desc = "Querybook: next result page" })
		vim.keymap.set("n", "<leader>qP", "<Cmd>QuerybookPrevPage<CR>", { buffer = bufnr, silent = true, desc = "Querybook: previous result page" })
		vim.keymap.set("n", "<leader>qL", "<Cmd>QuerybookNextColumn<CR>", { buffer = bufnr, silent = true, desc = "Querybook: next result columns" })
		vim.keymap.set("n", "<leader>qH", "<Cmd>QuerybookPrevColumn<CR>", { buffer = bufnr, silent = true, desc = "Querybook: previous result columns" })
		vim.b[bufnr].querybook_viewport_maps = true
	end
	local function execute_one(item)
		local old = find_current_result(bufnr, { start_line = item.anchor, end_line = item.anchor })
		local previous_query = old and (old.last_successful_query or old.query)
		local previous_truncated = old and old.truncated
		local previous_truncation_reason = old and old.truncation_reason
		if old and old.handle then old.handle.cancel(); old.handle = nil end
		local result
		if old then
			-- One statement owns one result slot. Reusing the extmark prevents a
			-- failed retry from stacking another ERROR block below the query.
			result = old
			result.generation = (result.generation or 0) + 1
			result.query, result.status, result.error = item.query, "running", nil
			result.previous_query = nil
			result.connection_name, result.connection_profile, result.connection_driver = display_name, display_name, conn.driver
			result.database, result.duration_ms = conn.database or conn.path, 0
			result.auto_limit_applied, result.auto_limit_reason, result.truncated, result.truncation_reason = nil, nil, false, nil
			result.row_offset, result.column_offset = 0, 0
		else
			bs.next_id = bs.next_id + 1
			result = {
				id = bs.next_id, query = item.query, status = "running", rows = {}, columns = {}, generation = 1,
				connection_name = display_name, connection_profile = display_name, connection_driver = conn.driver,
				database = conn.database or conn.path, duration_ms = 0, row_offset = 0, column_offset = 0,
			}
			result.extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, item.anchor - 1, 0, { right_gravity = false, virt_lines = render.lines(result, M.config), virt_lines_above = false, virt_lines_leftcol = true })
			bs.results[result.id] = result
		end
		render_result(bufnr, result)
		local started = vim.loop.hrtime()
		local run_generation = result.generation
		result.handle = runner.run(name, item.query, { force = (opts and opts.force) or M.config.allow_writes, generation = run_generation }, function(data, err)
			if result.generation ~= run_generation or bs.results[result.id] ~= result then return end
			result.duration_ms = math.floor((vim.loop.hrtime() - started) / 1000000)
			result.handle = nil
			if err then
				result.status, result.error = "error", err
				if M._inspect_state and M._inspect_state.result == result then M._inspect_state.generation = result.generation end
				result.previous_query = (#(result.rows or {}) > 0 or #(result.columns or {}) > 0) and previous_query or nil
				result.truncated, result.truncation_reason = previous_truncated or false, previous_truncation_reason
			else
				result.status, result.rows, result.columns = "success", data.rows or {}, data.columns or {}
				local previous_handle = result.result_handle
				result.result_handle = data.result_handle or data.handle
				if previous_handle and previous_handle ~= result.result_handle and runner.result then
					runner.result("release", { result_handle = previous_handle }, function() end)
				end
				-- The runner may attach the authoritative execution snapshot. Keep
				-- that metadata with this result even if the manager selection changes.
				local snapshot = data.connection or data.connection_metadata
				if type(snapshot) == "table" then
					result.connection_name = snapshot.name or result.connection_name
					result.connection_profile = result.connection_name
					result.connection_driver = snapshot.driver or result.connection_driver
					result.database = snapshot.database or snapshot.path or result.database
				end
				result.previous_query = nil
				result.last_successful_query = item.query
				result.auto_limit_applied, result.auto_limit_reason = data.auto_limit_applied, data.auto_limit_reason
				result.truncated, result.truncation_reason = data.truncated, data.truncation_reason
				if M._inspect_state and M._inspect_state.result == result then
					M._inspect_state.closed = true
					if M._inspect_state.win and vim.api.nvim_win_is_valid(M._inspect_state.win) then pcall(vim.api.nvim_win_close, M._inspect_state.win, true) end
					M._inspect_state = nil
				end
			end
      render_result(bufnr, result)
    end)
  end
  for _, item in ipairs(queries) do execute_one(item) end
  end
  local active = connections.active()
  if active then execute_queries(active)
  else
    connections.ensure_active(function(conn, err)
      if not conn then return vim.notify(err or "Querybook: no active connection", vim.log.levels.ERROR) end
      execute_queries(conn)
    end)
  end
end

function M.page(axis, direction)
	local bufnr = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)[1]
	local current = parser.statement_at(parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), cursor)
	local result = current and find_current_result(bufnr, current)
	if not result then return vim.notify("Querybook: no result near cursor", vim.log.levels.WARN) end
	local rows = result.rows or {}
	local columns = result.columns or {}
	if axis == "row" then
		local page_size = M.config.preview_rows or M.config.max_rows or 10
		result.row_offset = math.max(0, math.min((result.row_offset or 0) + direction * page_size, math.max(0, #rows - 1)))
	else
		local page_size = M.config.max_columns or 12
		result.column_offset = math.max(0, math.min((result.column_offset or 0) + direction * page_size, math.max(0, #columns - 1)))
	end
	render_result(bufnr, result)
end

function M.next_page() M.page("row", 1) end
function M.prev_page() M.page("row", -1) end
function M.next_column() M.page("column", 1) end
function M.prev_column() M.page("column", -1) end

function M.inspect()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local statements = parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local current = parser.statement_at(statements, cursor)
  local best = current and find_current_result(bufnr, current)
  if not best then return vim.notify("Querybook: no result near cursor", vim.log.levels.WARN) end
  M._inspect_state = inspect_view.open(best, { runner = runner, page_size = M.config.preview_rows or 10 })
end

local function inspect_state()
  local view = M._inspect_state
  if view and view.buf and vim.api.nvim_buf_is_valid(view.buf) then return view end
  return nil
end

function M.filter()
  local view = inspect_state()
  if not view then return vim.notify("Querybook: open an inspector first", vim.log.levels.WARN) end
  vim.ui.input({ prompt = "Querybook filter (JSONPath or shorthand; empty clears): " }, function(value)
    if value == nil then return end
    inspect_view.filter(view, value)
  end)
end

function M.clear_filter()
  local view = inspect_state()
  if view then inspect_view.clear_filter(view) else vim.notify("Querybook: open an inspector first", vim.log.levels.WARN) end
end

function M.pin_row()
  local view = inspect_state()
  if view then inspect_view.pin(view) else vim.notify("Querybook: open an inspector first", vim.log.levels.WARN) end
end

function M.compare_rows()
  local view = inspect_state()
  if view then inspect_view.compare(view) else vim.notify("Querybook: open an inspector first", vim.log.levels.WARN) end
end

function M.export(scope)
  local view = inspect_state()
  if not view then return vim.notify("Querybook: open an inspector first", vim.log.levels.WARN) end
  vim.ui.input({ prompt = "Export format (csv/jsonl): " }, function(format)
    if not format or format == "" then return end
    vim.ui.input({ prompt = "Export path (must not already exist): " }, function(path)
      if not path or path == "" then return end
      inspect_view.export(view, scope, format, path)
    end)
  end)
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
  if all then for _, result in pairs(bs.results) do if result.handle then result.handle.cancel() end; remove_result(bufnr, result) end
  else
    local current = parser.statement_at(parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), vim.api.nvim_win_get_cursor(0)[1])
    if current then local result = find_current_result(bufnr, current); if result then if result.handle then result.handle.cancel() end; remove_result(bufnr, result) end end
  end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", defaults, opts or {})
	-- max_rows was the old preview setting. Honor it when callers have not
	-- opted into the clearer preview_rows name.
	if opts and opts.preview_rows == nil and opts.max_rows ~= nil then M.config.preview_rows = opts.max_rows end
  connections.setup(M.config)
  render.setup_highlights()
  if not M._commands_created then
    vim.api.nvim_create_user_command("QuerybookRun", function(command_opts) M.run({ range = command_opts.range, line1 = command_opts.line1, line2 = command_opts.line2, force = command_opts.bang }) end, { range = true, bang = true, desc = "Run SQL under cursor or visual selection" })
    vim.api.nvim_create_user_command("QuerybookInspect", M.inspect, { desc = "Inspect Querybook result" })
		vim.api.nvim_create_user_command("QuerybookFilter", M.filter, { desc = "Filter the open Querybook inspector" })
		vim.api.nvim_create_user_command("QuerybookClearFilter", M.clear_filter, { desc = "Clear the Querybook inspector filter" })
		vim.api.nvim_create_user_command("QuerybookPinRow", M.pin_row, { desc = "Pin or unpin the current inspector row" })
		vim.api.nvim_create_user_command("QuerybookCompareRows", M.compare_rows, { desc = "Compare the current row with the pinned row" })
		vim.api.nvim_create_user_command("QuerybookExportRetained", function() M.export("retained") end, { desc = "Export retained Querybook rows" })
		vim.api.nvim_create_user_command("QuerybookExportFiltered", function() M.export("filtered") end, { desc = "Export filtered Querybook rows" })
		vim.api.nvim_create_user_command("QuerybookExportFull", function() M.export("full") end, { desc = "Export the full Querybook result" })
		vim.api.nvim_create_user_command("QuerybookToggle", M.toggle, { desc = "Collapse or expand Querybook result" })
		vim.api.nvim_create_user_command("QuerybookNextPage", M.next_page, { desc = "Show next retained Querybook rows" })
		vim.api.nvim_create_user_command("QuerybookPrevPage", M.prev_page, { desc = "Show previous retained Querybook rows" })
		vim.api.nvim_create_user_command("QuerybookNextColumn", M.next_column, { desc = "Show next retained Querybook columns" })
		vim.api.nvim_create_user_command("QuerybookPrevColumn", M.prev_column, { desc = "Show previous retained Querybook columns" })
    vim.api.nvim_create_user_command("QuerybookRefresh", M.refresh, { desc = "Re-run Querybook result" })
    vim.api.nvim_create_user_command("QuerybookClear", function(command_opts) M.clear(command_opts.bang) end, { bang = true, desc = "Clear Querybook result" })
    vim.api.nvim_create_user_command("QuerybookConnections", connections.open, { desc = "Manage Querybook connections" })
    vim.api.nvim_create_user_command("QuerybookConnectionsImport", function(command_opts) connections.import_legacy(command_opts.args) end, { nargs = 1, desc = "Import connection metadata from config" })
    -- qC opens the manager; qc remains the established clear mapping.
    vim.keymap.set("n", "qC", "<Cmd>QuerybookConnections<CR>", { silent = true, desc = "Querybook: manage connections" })
    vim.keymap.set("n", "qc", "<Cmd>QuerybookClear<CR>", { silent = true, desc = "Querybook: clear result" })
    M._commands_created = true
  end
  local group = vim.api.nvim_create_augroup("Querybook", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, { group = group, callback = function(args) if state[args.buf] then refresh_stale(args.buf) end end })
  vim.api.nvim_create_autocmd("BufDelete", { group = group, callback = function(args)
    local bs = state[args.buf]
    if bs then for _, result in pairs(bs.results) do if result.handle then result.handle.cancel() end end; state[args.buf] = nil end
  end })
end

return M
