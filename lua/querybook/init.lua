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

local function window_for_buf(bufnr)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == bufnr then return current end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return win end
  end
  return current
end

local function render_config(bufnr)
  local cfg = vim.tbl_extend("force", {}, M.config or {})
  local ok, width = pcall(vim.api.nvim_win_get_width, window_for_buf(bufnr))
  if ok and type(width) == "number" and width > 0 then cfg.display_width = width end
  return cfg
end

local function render_result(bufnr, result)
  local line = result_position(bufnr, result)
  if not line then return end
  vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
    id = result.extmark,
    right_gravity = false,
    virt_lines = render.lines(result, render_config(bufnr)),
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
        if M._inspect_state and M._inspect_state.result == result then inspect_view.sync(M._inspect_state) end
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
      else
        bs.next_id = bs.next_id + 1
        result = {
          id = bs.next_id, query = item.query, status = "running", rows = {}, columns = {}, generation = 1,
          connection_name = display_name, connection_profile = display_name, connection_driver = conn.driver,
          database = conn.database or conn.path, duration_ms = 0, row_offset = 0, column_offset = 0,
        }
        result.extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, item.anchor - 1, 0, { right_gravity = false, virt_lines = render.lines(result, render_config(bufnr)), virt_lines_above = false, virt_lines_leftcol = true })
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
          -- A successful execution gets a fresh immutable registry handle and
          -- therefore cannot retain a prior filtered view or inspector state.
          result.view_active, result.view_id, result.filter_expression, result.view_source_rows, result.view_count = false, nil, nil, nil, nil
          result.row_offset, result.column_offset = 0, 0
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
    local source_rows = result.view_active and result.view_source_rows
    local row_count = source_rows and #source_rows or #rows
    result.row_offset = math.max(0, math.min((result.row_offset or 0) + direction * page_size, math.max(0, row_count - 1)))
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
  M._inspect_state = inspect_view.open(best, {
    runner = runner,
    page_size = M.config.preview_rows or 10,
    on_view_change = function(result) render_result(bufnr, result) end,
  })
end

local function inspect_state()
  local view = M._inspect_state
  if view and view.buf and vim.api.nvim_buf_is_valid(view.buf) then return view end
  return nil
end

local function current_notebook_result()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local current = parser.statement_at(parser.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), cursor)
  return bufnr, current and find_current_result(bufnr, current)
end

local function apply_notebook_filter(bufnr, result, expression)
  expression = vim.trim(expression or "")
  if expression == "" then
    result.view_active, result.view_id, result.filter_expression, result.view_source_rows, result.view_count = false, nil, nil, nil, nil
    result.row_offset = 0
    render_result(bufnr, result)
    return
  end
  if not result.result_handle or not runner.result then
    return vim.notify("Querybook: no retained result near cursor", vim.log.levels.WARN)
  end
  runner.result("filter", { result_handle = result.result_handle, expression = expression, filter = expression }, function(data, err)
    if err or not data or data.valid == false then
      return vim.notify(err or data and data.error or "Querybook: invalid filter", vim.log.levels.WARN)
    end
    local indices = data.matching_indices or data.source_rows or data.source_indices
    if type(indices) ~= "table" then
      return vim.notify("Querybook: filter response did not include matching source rows", vim.log.levels.WARN)
    end
    result.view_active, result.view_id, result.filter_expression = true, data.view_id, expression
    result.view_source_rows, result.view_count, result.row_offset = vim.deepcopy(indices), tonumber(data.total_rows or data.matching_count) or #indices, 0
    render_result(bufnr, result)
  end)
end

function M.filter()
  local view = inspect_state()
  if view then
    vim.ui.input({ prompt = "Querybook filter (CEL; empty clears): " }, function(value)
      if value == nil then return end
      inspect_view.filter(view, value)
    end)
    return
  end
  local bufnr, result = current_notebook_result()
  if not result or not result.result_handle then
    return vim.notify("Querybook: no retained result near cursor", vim.log.levels.WARN)
  end
  vim.ui.input({ prompt = "Querybook filter (CEL; empty clears): " }, function(value)
    if value == nil then return end
    apply_notebook_filter(bufnr, result, value)
  end)
end

function M.clear_filter()
  local view = inspect_state()
  if view then inspect_view.clear_filter(view); return end
  local bufnr, result = current_notebook_result()
  if not result then return vim.notify("Querybook: no retained result near cursor", vim.log.levels.WARN) end
  apply_notebook_filter(bufnr, result, "")
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
  require("querybook.sqls").setup()
  render.setup_highlights()
  if not M._commands_created then
    vim.api.nvim_create_user_command("QuerybookRun", function(command_opts) M.run({ range = command_opts.range, line1 = command_opts.line1, line2 = command_opts.line2, force = command_opts.bang }) end, { range = true, bang = true, desc = "Run SQL under cursor or visual selection" })
    vim.api.nvim_create_user_command("QuerybookInspect", M.inspect, { desc = "Inspect Querybook result" })
    vim.api.nvim_create_user_command("QuerybookFilter", M.filter, { desc = "Filter retained Querybook rows with local CEL" })
    vim.api.nvim_create_user_command("QuerybookClearFilter", M.clear_filter, { desc = "Clear the local Querybook CEL filter" })
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
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { group = group, callback = function()
    for bufnr, bs in pairs(state) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        for _, result in pairs(bs.results) do render_result(bufnr, result) end
      end
    end
  end })
  vim.api.nvim_create_autocmd("BufDelete", { group = group, callback = function(args)
    local bs = state[args.buf]
    if bs then for _, result in pairs(bs.results) do if result.handle then result.handle.cancel() end end; state[args.buf] = nil end
  end })
end

return M
