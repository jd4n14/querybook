local render = require("querybook.render")

local M = {}

-- The inspector owns presentation state only.  Row and cell values are never
-- rewritten: source indices, result handles, and expansion paths identify all
-- state held here.  The runner is the authority for filtered views, compares,
-- and exports when a result handle is available.
local function cell_text(row, column)
  local value, is_null, cell = render.value(row, column)
  if is_null then return "NULL", cell end
  if cell and cell.kind == "binary" then return "base64:" .. tostring(value or ""), cell end
  return tostring(value or ""), cell
end

local function cell_display(cell)
  if not cell or cell.kind == "null" then return "NULL", cell end
  if cell.kind == "binary" then return "base64:" .. tostring(cell.base64 or ""), cell end
  return tostring(cell.text or ""), cell
end

local function column_name(column)
  return type(column) == "table" and tostring(column.name or "") or tostring(column)
end

local function column_type(column)
  if type(column) ~= "table" then return nil end
  return column.database_type or column.type or column.data_type
end

local function type_label(column)
  local typ = column_type(column)
  if not typ or typ == "" then return "" end
  local low = tostring(typ):lower()
  if low:find("json", 1, true) or low:find("struct", 1, true) then return "structured" end
  if low:find("blob", 1, true) or low:find("binary", 1, true) or low:find("bytea", 1, true) then return "bin" end
  if low:find("time", 1, true) or low:find("date", 1, true) then return "time" end
  return tostring(typ)
end

local function json_node_for(state, row, column, source_index)
  local c = state.columns[column]
  if type_label(c) ~= "structured" then return nil end
  local key = tostring(source_index) .. ":" .. tostring(column)
  -- The result registry must provide an exact tree. Lua never parses JSON
  -- values, since doing so could round a large numeric token.
  if state.trees[key] then return state.trees[key] end
  return nil
end

local function format_meta(result, state)
  local lines = {}
  local status = result.status or "success"
  if status == "stale" then
    lines[#lines + 1] = "STALE · SQL changed; retained result is from the prior execution"
  end
  lines[#lines + 1] = string.format("%s · %s / %s", status:upper(), tostring(result.connection_name or "connection"), tostring(result.database or "(none)"))
  local sql = tostring(result.query or "")
  local compact_sql = sql:gsub("%s+", " ")
  if #compact_sql > 72 then compact_sql = compact_sql:sub(1, 69) .. "…" end
  lines[#lines + 1] = "SQL: " .. compact_sql
  if compact_sql ~= sql:gsub("%s+", " ") then lines[#lines + 1] = "SQL truncated · gQ shows the full execution SQL" end
  if result.auto_limit_applied then lines[#lines + 1] = "execution: automatic outer LIMIT 500 applied" end
  if result.truncated then lines[#lines + 1] = "retention: truncated (" .. tostring(result.truncation_reason or "limit") .. ")" end
  local retained = state.retained_count or #(state.rows or {})
  local matching = state.matching_count or #state.indices
  local page_count = math.max(1, math.ceil(matching / state.page_size))
  local source = state.current_source and ((state.current_source + 1) .. "/" .. retained) or "-"
  lines[#lines + 1] = string.format("matching %d/%d · source %s · page %d/%d", state.current_match or 0, matching, source, state.page, page_count)
  if state.filter then lines[#lines + 1] = "local filter: " .. state.filter end
  return lines
end

local function row_for(state)
  if not state.current_source then return nil end
  if state.by_source[state.current_source] then return state.by_source[state.current_source] end
  local local_index = state.current_source
  return state.rows[local_index]
end

local function render_lines(state)
  local lines, locations = {}, {}
  local function add(line, location)
    lines[#lines + 1] = line
    locations[#lines] = location
  end
  for _, line in ipairs(format_meta(state.result, state)) do add(line) end
  local row = row_for(state)
  if not row then add("(no matching rows)"); return lines, locations end
  add("")
  for col, column in ipairs(state.columns) do
    local key = tostring(state.current_source) .. ":" .. tostring(col)
    local value, cell = state.live_cells[key] and cell_display(state.live_cells[key]) or cell_text(row, col)
    local typ = type_label(column)
    local suffix = typ ~= "" and " [" .. typ .. "]" or ""
    local expanded = state.expanded[key]
    local mode = state.raw[key] and " (raw)" or ""
    add(string.format("%s%s%s = %s", column_name(column), suffix, mode, value), { kind = "field", row = state.current_source, column = col, key = key })
    if expanded then
      local root = json_node_for(state, row, col, state.current_source)
      local function visit(node, depth, path)
        if not node then return end
        local prefix = string.rep("  ", depth)
        local children = node.children or {}
        if #children == 0 then
          add(prefix .. tostring(node.raw), { kind = "node", row = state.current_source, column = col, path = path, key = key .. ":" .. path })
          return
        end
        for index, entry in ipairs(children) do
          local child_path = path == "" and tostring(index) or path .. "." .. tostring(index)
          local label = entry.key and entry.key.raw .. ": " or ("[" .. tostring(index) .. "] ")
          add(prefix .. label .. (entry.node.children and "" or tostring(entry.node.raw or "")), { kind = "node", row = state.current_source, column = col, path = child_path, key = key .. ":" .. child_path })
          if entry.node.children and state.expanded[key .. ":" .. child_path] then visit(entry.node, depth + 1, child_path) end
        end
      end
      visit(root, 1, "")
    end
  end
  return lines, locations
end

local function notify(message, level)
  vim.notify("Querybook: " .. message, level or vim.log.levels.INFO)
end

local function invoke(runner, op, payload, callback)
  if runner and runner.result then return runner.result(op, payload, callback) end
  callback(nil, "result registry is unavailable")
end

local function normalize_page(state, data)
  if type(data) ~= "table" then return false end
  if data.metadata and data.metadata.columns then state.columns = data.metadata.columns end
  if data.columns then state.columns = data.columns end
  local rows = data.rows or data.result_rows
  if rows then
    state.rows, state.by_source, state.page_sources = {}, {}, {}
    local source = data.source_rows or data.source_indices or data.row_indices or data.indices or {}
    for i, row in ipairs(rows) do
      local source_index = tonumber(source[i]) or (type(row) == "table" and tonumber(row.source_index)) or (i - 1)
      if type(row) == "table" and row.row then row = row.row end
      state.rows[i], state.by_source[source_index], state.page_sources[i] = row, row, source_index
    end
  end
  local trees = data.trees or data.json_trees or data.presentation
  if trees then
    for key, tree in pairs(trees) do state.trees[key] = tree end
  end
  state.retained_count = tonumber(data.retained_count or data.total_retained) or state.retained_count
  state.matching_count = tonumber(data.total_rows or data.matching_count or data.total_matching) or state.matching_count
  if data.view_id then state.view_id = data.view_id end
  state.current_source = tonumber(data.current_source or data.source_row) or state.current_source
  state.current_match = tonumber(data.current_match or data.match_index) or state.current_match
  return true
end

local function redraw(state)
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  local source_lines, source_locations = render_lines(state)
  local lines, locations = {}, {}
  for i, line in ipairs(source_lines) do
    local parts = vim.split(tostring(line), "\n", { plain = true })
    for _, part in ipairs(parts) do
      lines[#lines + 1] = part
      locations[#lines] = source_locations[i]
    end
  end
  state.locations = locations
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function request_page(state, payload)
  payload = vim.tbl_extend("force", payload or {}, { result_handle = state.handle, limit = (payload and payload.limit) or state.page_size, view_id = state.view_id })
  if payload.offset == nil then payload.offset = math.max(0, ((state.page or 1) - 1) * (payload.limit or state.page_size)) end
  invoke(state.runner, "view", payload, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err then notify(err, vim.log.levels.WARN); return end
    normalize_page(state, data)
    if state.page_sources and state.page_sources[1] ~= nil then
      state.current_source = state.page_sources[1]
      if payload.limit > 1 then state.current_match = math.max(1, (payload.offset or 0) + 1) end
    end
    redraw(state)
  end)
end

local function load_tree(state, location, done)
  local key = tostring(location.row) .. ":" .. tostring(location.column)
  if state.trees[key] then done(state.trees[key]); return end
  if not state.handle or not state.runner or not state.runner.result then return done(nil) end
  invoke(state.runner, "cell", {
    result_handle = state.handle, row = location.row, column = location.column - 1,
    tree_depth = 64, tree_bytes = 1024 * 1024,
  }, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err then notify(err, vim.log.levels.WARN); done(nil); return end
    if data and data.tree then state.trees[key] = data.tree end
    if data and data.cell then state.live_cells[key] = data.cell end
    done(data and data.tree)
  end)
end

local function refresh_cell(state, location, done)
  local key = tostring(location.row) .. ":" .. tostring(location.column)
  if not state.handle or not state.runner or not state.runner.result then return done(nil) end
  invoke(state.runner, "cell", {
    result_handle = state.handle, row = location.row, column = location.column - 1,
    tree_depth = 64, tree_bytes = 1024 * 1024,
  }, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err then notify(err, vim.log.levels.WARN); done(nil); return end
    if data and data.tree then state.trees[key] = data.tree end
    if data and data.cell then state.live_cells[key] = data.cell end
    done(data)
  end)
end

local function set_row(state, match)
  if state.matching_count == 0 then state.current_match = 0; state.current_source = nil; redraw(state); return end
  state.current_match = math.max(1, math.min(match, state.matching_count))
  local source = state.indices and state.indices[state.current_match]
  if source then state.current_source = tonumber(source) end
  local page = math.floor((state.current_match - 1) / state.page_size) + 1
  state.page = page
  request_page(state, { offset = state.current_match - 1, limit = 1, source_row = state.current_source })
end

local function current_location(state)
  return state.locations[vim.api.nvim_win_get_cursor(state.win)[1]]
end

function M.filter(state, expression)
  expression = vim.trim(expression or "")
  if expression == "" then return M.clear_filter(state) end
  invoke(state.runner, "filter", { result_handle = state.handle, expression = expression, filter = expression }, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err or not data or data.valid == false then notify(err or (data and data.error) or "invalid filter", vim.log.levels.WARN); return end
    local indices = data.matching_indices or data.source_rows or data.source_indices
    if type(indices) ~= "table" then
      return notify("filter response did not include matching source rows", vim.log.levels.WARN)
    end
    state.filter, state.view_id, state.matching_count, state.current_match, state.current_source, state.page = expression, data.view_id, tonumber(data.total_rows or data.matching_count) or #indices, 0, nil, 1
    state.indices = vim.deepcopy(indices)
    state.result.view_active = true
    state.result.view_id = state.view_id
    state.result.filter_expression = expression
    state.result.view_source_rows = vim.deepcopy(indices)
    state.result.view_count = state.matching_count
    state.result.row_offset = 0
    if state.on_view_change then state.on_view_change(state.result) end
    redraw(state); set_row(state, 1)
  end)
end

function M.clear_filter(state)
  if not state.filter and not state.result.view_active then return end
  state.filter, state.view_id, state.indices = nil, nil, state.all_indices
  state.matching_count, state.current_match, state.current_source, state.page = #state.indices, 0, nil, 1
  state.result.view_active = false
  state.result.view_id = nil
  state.result.filter_expression = nil
  state.result.view_source_rows = nil
  state.result.view_count = nil
  state.result.row_offset = 0
  if state.on_view_change then state.on_view_change(state.result) end
  redraw(state); set_row(state, 1)
end

function M.pin(state)
  if not state.current_source then return notify("no current row", vim.log.levels.WARN) end
  if state.pinned_source == state.current_source then state.pinned_source = nil; notify("row unpinned"); return redraw(state) end
  state.pinned_source, state.pinned_handle = state.current_source, state.handle
  notify("row pinned")
  redraw(state)
end

function M.compare(state)
  if not state.pinned_source then return notify("pin a row first", vim.log.levels.WARN) end
  invoke(state.runner, "compare", { result_handle = state.handle, source_row = state.pinned_source, current_row = state.current_source }, function(data, err)
    if err then notify(err, vim.log.levels.WARN); return end
    local lines = { "Querybook compare", string.format("pinned source %s · current source %s", tostring(state.pinned_source), tostring(state.current_source)) }
    for _, item in ipairs((data and (data.changes or data.columns or data.differences)) or {}) do
      lines[#lines + 1] = string.format("%s %s: %s", tostring(item.column_name or item.name or item.column or "column"), tostring(item.path or ""), tostring(item.kind or item.status or "different"))
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

function M.export(state, scope, format, path)
  if scope == "full" then notify("full export includes original SQL and connection snapshot; automatic LIMIT and retention status are shown", vim.log.levels.INFO) end
  state.export_id = "qb-" .. tostring(vim.loop.hrtime())
  state.export_request = invoke(state.runner, "export", { result_handle = state.handle, scope = scope, format = format, path = path, filter = state.filter, export_id = state.export_id }, function(data, err)
    if err then state.export_request = nil; notify(err, vim.log.levels.ERROR); return end
    if data and data.export_id then state.export_id = data.export_id end
    if data and data.progress then
      -- Progress events carry row_count; rows is retained as a compatibility
      -- fallback for older runner builds that used that field.
      local row_count = data.row_count ~= nil and data.row_count or data.rows or 0
      notify(string.format("export %s: %s rows · %s bytes", tostring(data.export_id or state.export_id or ""), tostring(row_count), tostring(data.bytes or 0)))
    elseif data and data.path then state.export_request = nil; notify("exported " .. tostring(data.path)) end
  end)
end

function M.cancel_export(state)
  if not state.export_request then return notify("no export is running", vim.log.levels.WARN) end
  local id = state.export_id
  if state.export_request.cancel then state.export_request.cancel() end
  state.export_request = nil
  if id then invoke(state.runner, "export_cancel", { result_handle = state.handle, export_id = id }, function() end) end
  notify("export cancelled")
end

function M.open(result, opts)
  opts = opts or {}
  local columns = result.columns or {}
  local rows = result.rows or {}
  local active_indices = result.view_active and result.view_source_rows or nil
  local state = {
    result = result, runner = opts.runner, handle = result.result_handle or result.handle_id,
    generation = result.generation, columns = columns, rows = rows, by_source = {}, trees = {}, live_cells = {}, expanded = {}, raw = {},
    page_size = opts.page_size or 10, page = 1, matching_count = active_indices and (#active_indices) or #rows, retained_count = tonumber(result.row_count) or #rows,
    indices = {}, all_indices = {}, current_match = active_indices and (#active_indices > 0 and 1 or 0) or (#rows > 0 and 1 or 0), current_source = active_indices and (active_indices[1]) or (#rows > 0 and 0 or nil),
    filter = result.filter_expression, view_id = result.view_id, on_view_change = opts.on_view_change,
  }
  for i, row in ipairs(rows) do local source = i - 1; state.by_source[source], state.all_indices[i] = row, source end
  if active_indices then
    state.indices = vim.deepcopy(active_indices)
  else
    state.indices = vim.deepcopy(state.all_indices)
  end
  local buf = vim.api.nvim_create_buf(false, true); state.buf = buf; state.closed = false
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() state.closed = true end })
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype, vim.bo[buf].modifiable = "querybook", false
  redraw(state)
  local width, height = math.min(vim.o.columns - 4, 80), math.min(vim.o.lines - 6, math.max(8, vim.api.nvim_buf_line_count(buf) + 1))
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2), width = width, height = height, style = "minimal", border = "rounded" }); state.win = win
  local function map(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc }) end
  local function move(delta) set_row(state, state.current_match + delta) end
  map("]r", function() move(1) end, "Querybook: next matching row"); map("[r", function() move(-1) end, "Querybook: previous matching row")
  map("]p", function() state.page = state.page + 1; request_page(state, { page = state.page }) end, "Querybook: next matching page")
  map("[p", function() state.page = math.max(1, state.page - 1); request_page(state, { page = state.page }) end, "Querybook: previous matching page")
  map("r", function() move(1) end, "Querybook: next matching row"); map("R", function() move(-1) end, "Querybook: previous matching row")
  map("<CR>", function()
    local loc = current_location(state); if not loc then return end
    local key = loc.key
    if loc.kind == "field" and not state.trees[key] then
      load_tree(state, loc, function(tree) if tree then state.expanded[key] = true; redraw(state) end end)
    else state.expanded[key] = not state.expanded[key]; redraw(state) end
  end, "Querybook: expand or collapse JSON node")
  map("za", function()
    local loc = current_location(state); if not loc then return end
    if loc.kind == "field" and not state.trees[loc.key] then
      load_tree(state, loc, function(tree) if tree then state.expanded[loc.key] = true; redraw(state) end end)
    else state.expanded[loc.key] = not state.expanded[loc.key]; redraw(state) end
  end, "Querybook: expand or collapse JSON node")
  map("gR", function()
    local loc = current_location(state); if not loc or not loc.key then return end
    refresh_cell(state, loc, function()
      state.raw[loc.key] = not state.raw[loc.key]
      redraw(state)
    end)
  end, "Querybook: toggle raw/formatted value")
  map("K", function()
    local loc = current_location(state)
    if not loc or not loc.column then return notify("place cursor on a field", vim.log.levels.WARN) end
    local column = state.columns[loc.column] or {}
    local details = { name = column.name, database_type = column.database_type, nullable = column.nullable }
    notify(vim.inspect(details), vim.log.levels.INFO)
  end, "Querybook: show source column metadata")
  map("gQ", function() notify(tostring(state.result.query or ""), vim.log.levels.INFO) end, "Querybook: show full execution SQL")
  map("x", function() M.cancel_export(state) end, "Querybook: cancel export")
  map("yv", function()
    local loc = current_location(state); if not loc or loc.kind ~= "field" then return notify("place cursor on a field", vim.log.levels.WARN) end
    local function copy(text) vim.fn.setreg('"', text); pcall(vim.fn.setreg, "+", text) end
    if state.handle and state.runner and state.runner.result then
      invoke(state.runner, "cell", { result_handle = state.handle, row = loc.row, column = loc.column - 1 }, function(data, err)
        if err then notify(err, vim.log.levels.WARN); return end
        local cell = data and (data.cell or data.Cell)
        if not cell then return notify("cell is unavailable", vim.log.levels.WARN) end
        if cell.kind == "null" then copy("NULL") elseif cell.kind == "binary" then copy("base64:" .. tostring(cell.base64 or "")) else copy(tostring(cell.text or "")) end
      end)
    else
      local row = state.by_source[loc.row] or row_for(state); copy(render.value_text(row, loc.column))
    end
  end, "Querybook: copy exact field")
  map("yr", function()
    local loc = current_location(state); if not loc or not loc.row then return notify("place cursor on a row", vim.log.levels.WARN) end
    local row = state.by_source[loc.row] or row_for(state); local fields = {}
    for i, column in ipairs(state.columns) do local value, null, cell = render.value(row, i); fields[#fields + 1] = { column = column_name(column), value = null and vim.NIL or value, encoding = cell and cell.kind == "binary" and "base64" or "text" } end
    local text = vim.json.encode(fields); vim.fn.setreg('"', text); pcall(vim.fn.setreg, "+", text)
  end, "Querybook: copy exact row JSON")
  map("yp", function()
    local function copy(text)
      if not text then return notify("payload is unavailable", vim.log.levels.WARN) end
      vim.fn.setreg('"', text); pcall(vim.fn.setreg, "+", text)
    end
    if state.handle and state.runner and state.runner.result then
      invoke(state.runner, "payload", { result_handle = state.handle }, function(data, err)
        if err then notify(err, vim.log.levels.WARN); return end
        if not data then return notify("payload is unavailable", vim.log.levels.WARN) end
        if data.payload or data.json or data.text then return copy(data.payload or data.json or data.text) end
        local payload_rows = {}
        local payload_columns = data.metadata and data.metadata.columns or state.columns
        for _, row in ipairs(data.rows or {}) do
          local fields = {}
          for i, column in ipairs(payload_columns) do
            local value, null, cell = render.value(row, i)
            fields[#fields + 1] = { column = column_name(column), value = null and vim.NIL or value, encoding = cell and cell.kind == "binary" and "base64" or "text" }
          end
          payload_rows[#payload_rows + 1] = fields
        end
        copy(vim.json.encode({ connection = data.metadata and data.metadata.connection or state.result.connection_name or "connection", database = data.metadata and data.metadata.connection and (data.metadata.connection.database or data.metadata.connection.path) or state.result.database or "", columns = payload_columns, rows = payload_rows }))
      end)
    else
      local fields = {}; for i, column in ipairs(state.columns) do local value, null, cell = render.value(row_for(state), i); fields[#fields + 1] = { column = column_name(column), value = null and vim.NIL or value, encoding = cell and cell.kind == "binary" and "base64" or "text" } end
      copy(vim.json.encode({ connection = state.result.connection_name or "connection", database = state.result.database or "", columns = state.columns, rows = { fields } }))
    end
  end, "Querybook: copy exact payload JSON")
  map("q", function() state.closed = true; vim.api.nvim_win_close(win, true) end, "Querybook: close inspector")
  if state.handle then request_page(state, { offset = 0, limit = state.page_size }) end
  return state
end

return M
