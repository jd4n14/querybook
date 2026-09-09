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

-- A tiny JSON reader keeps numbers as source text.  vim.json.decode turns
-- large integers into Lua numbers, which would corrupt copy and display.
local function parse_json(text)
  local i = 1
  local function ws() while text:sub(i, i):match("%s") do i = i + 1 end end
  local parse_value
  local function string_value()
    local start = i; i = i + 1
    local escaped = false
    while i <= #text do
      local c = text:sub(i, i)
      if escaped then escaped = false
      elseif c == "\\" then escaped = true
      elseif c == '"' then i = i + 1; return { kind = "string", raw = text:sub(start, i - 1) } end
      i = i + 1
    end
    return nil
  end
  local function composite(open, close, kind)
    local node = { kind = kind, raw = nil, children = {} }
    i = i + 1; ws()
    if text:sub(i, i) == close then i = i + 1; node.raw = open .. close; return node end
    while i <= #text do
      local key
      if kind == "object" then
        if text:sub(i, i) ~= '"' then return nil end
        key = string_value(); if not key then return nil end; ws()
        if text:sub(i, i) ~= ":" then return nil end
        i = i + 1; ws()
      end
      local child = parse_value(); if not child then return nil end
      node.children[#node.children + 1] = { key = key, node = child }
      ws()
      local c = text:sub(i, i)
      if c == close then i = i + 1; break end
      if c ~= "," then return nil end
      i = i + 1; ws()
    end
    node.raw = text:sub(node._start or 1, i - 1)
    return node
  end
  function parse_value()
    ws(); local start = i; local c = text:sub(i, i)
    if c == '"' then local n = string_value(); if n then n.raw = text:sub(start, i - 1) end; return n end
    if c == "{" then local n = composite("{", "}", "object"); if n then n.raw = text:sub(start, i - 1) end; return n end
    if c == "[" then local n = composite("[", "]", "array"); if n then n.raw = text:sub(start, i - 1) end; return n end
    for _, literal in ipairs({ "true", "false", "null" }) do
      if text:sub(i, i + #literal - 1) == literal then i = i + #literal; return { kind = literal, raw = literal } end
    end
    local number = text:sub(i):match("^-?(0|[1-9]%d*)(%.%d+)?([eE][+-]?%d+)?")
    if number then i = i + #number; return { kind = "number", raw = number } end
    return nil
  end
  local root = parse_value(); ws()
  if not root or i <= #text then return nil end
  return root
end

local function json_node_for(state, row, column, source_index)
  local c = state.columns[column]
  if type_label(c) ~= "structured" then return nil end
  local key = tostring(source_index) .. ":" .. tostring(column)
  -- A handle-backed view receives an exact presentation tree from Go.  Lua's
  -- JSON decoder is deliberately never used for those results because it can
  -- round large numeric tokens.  The local reader is only a test/legacy
  -- fallback for results without a registry handle.
  if state.trees[key] then return state.trees[key] end
  if state.handle and state.runner and state.runner.result then return nil end
  local value, is_null = render.value(row, column)
  if is_null then return nil end
  if state.json[key] == nil then state.json[key] = parse_json(tostring(value)) or false end
  return state.json[key] or nil
end

local function format_meta(result, state)
  local lines = {}
  local status = result.status or "success"
  if status == "stale" then
    lines[#lines + 1] = "STALE · SQL changed; retained result is from the prior execution"
  end
  lines[#lines + 1] = string.format("%s · %s / %s", status:upper(), tostring(result.connection_name or "connection"), tostring(result.database or "(none)"))
  lines[#lines + 1] = "SQL: " .. tostring(result.query or "")
  if result.auto_limit_applied then lines[#lines + 1] = "execution: automatic outer LIMIT 500 applied" end
  if result.truncated then lines[#lines + 1] = "retention: truncated (" .. tostring(result.truncation_reason or "limit") .. ")" end
  local retained = state.retained_count or #(state.rows or {})
  local matching = state.matching_count or #state.indices
  local page_count = math.max(1, math.ceil(matching / state.page_size))
  local source = state.current_source and (state.current_source .. "/" .. retained) or "-"
  lines[#lines + 1] = string.format("matching %d/%d · source %s · page %d/%d", state.current_match or 0, matching, source, state.page, page_count)
  if state.filter then lines[#lines + 1] = "filter: " .. state.filter end
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
    local value, cell = cell_text(row, col)
    local typ = type_label(column)
    local suffix = typ ~= "" and " [" .. typ .. "]" or ""
    local key = tostring(state.current_source) .. ":" .. tostring(col)
    local expanded = state.expanded[key]
    add(string.format("%s%s = %s", column_name(column), suffix, state.raw[key] and value or value), { kind = "field", row = state.current_source, column = col, key = key })
    if expanded then
      local root = json_node_for(state, row, col, state.current_source)
      local function visit(node, depth, path)
        if not node then return end
        local prefix = string.rep("  ", depth)
        if #node.children == 0 then
          add(prefix .. tostring(node.raw), { kind = "node", row = state.current_source, column = col, path = path, key = key .. ":" .. path })
          return
        end
        for index, entry in ipairs(node.children) do
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
  if data.columns then state.columns = data.columns end
  local rows = data.rows or data.result_rows
  if rows then
    state.rows, state.by_source = {}, {}
    local source = data.source_indices or data.row_indices or data.indices or {}
    for i, row in ipairs(rows) do
      local source_index = tonumber(source[i]) or (type(row) == "table" and tonumber(row.source_index)) or i
      if type(row) == "table" and row.row then row = row.row end
      state.rows[i], state.by_source[source_index] = row, row
    end
  end
  local trees = data.trees or data.json_trees or data.presentation
  if trees then
    for key, tree in pairs(trees) do state.trees[key] = tree end
  end
  state.retained_count = tonumber(data.retained_count or data.total_retained or data.row_count) or state.retained_count
  state.matching_count = tonumber(data.matching_count or data.total_matching) or state.matching_count
  if data.page then state.page = tonumber(data.page) or state.page end
  state.indices = data.matching_indices or state.indices
  state.current_source = tonumber(data.current_source or data.source_index) or state.current_source
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
  payload = vim.tbl_extend("force", payload or {}, { result_handle = state.handle, page_size = state.page_size, page = state.page })
  invoke(state.runner, "view", payload, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err then notify(err, vim.log.levels.WARN); return end
    normalize_page(state, data); redraw(state)
  end)
end

local function set_row(state, match)
  if state.matching_count == 0 then state.current_match = 0; state.current_source = nil; redraw(state); return end
  state.current_match = math.max(1, math.min(match, state.matching_count))
  local source = state.indices[state.current_match]
  if source then state.current_source = tonumber(source) end
  local page = math.floor((state.current_match - 1) / state.page_size) + 1
  state.page = page
  request_page(state, { match_index = state.current_match, source_index = state.current_source })
end

local function current_location(state)
  return state.locations[vim.api.nvim_win_get_cursor(state.win)[1]]
end

function M.filter(state, expression)
  expression = vim.trim(expression or "")
  if expression == "" then return M.clear_filter(state) end
  invoke(state.runner, "filter", { result_handle = state.handle, expression = expression, filter = expression }, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err or not data or data.valid == false then notify(err or data.error or "invalid filter", vim.log.levels.WARN); return end
    local indices = data.matching_indices or data.indices
    if not indices then notify("filter response did not include matching rows", vim.log.levels.WARN); return end
    state.filter, state.indices, state.matching_count, state.current_match, state.current_source, state.page = expression, indices, #indices, 0, nil, 1
    redraw(state); set_row(state, 1)
  end)
end

function M.clear_filter(state)
  if not state.filter then return end
  invoke(state.runner, "filter_clear", { result_handle = state.handle }, function(data, err)
    if err then notify(err, vim.log.levels.WARN); return end
    state.filter = nil; state.indices = data and (data.matching_indices or data.indices) or state.all_indices
    state.matching_count = #state.indices; state.current_match, state.current_source, state.page = 0, nil, 1
    redraw(state); set_row(state, 1)
  end)
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
  invoke(state.runner, "compare", { result_handle = state.handle, left_source_index = state.pinned_source, right_source_index = state.current_source }, function(data, err)
    if err then notify(err, vim.log.levels.WARN); return end
    local lines = { "Querybook compare", string.format("pinned source %s · current source %s", tostring(state.pinned_source), tostring(state.current_source)) }
    for _, item in ipairs((data and (data.columns or data.differences)) or {}) do
      lines[#lines + 1] = string.format("%s: %s", tostring(item.name or item.column or "column"), tostring(item.status or item.equal and "equal" or "different"))
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

function M.export(state, scope, format, path)
  if scope == "full" then notify("full export includes original SQL and connection snapshot; automatic LIMIT and retention status are shown", vim.log.levels.INFO) end
  state.export_request = invoke(state.runner, "export", { result_handle = state.handle, scope = scope, format = format, path = path, filter = state.filter }, function(data, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    if data and data.export_id then state.export_id = data.export_id end
    if data and data.progress then notify(string.format("export %s: %s rows · %s bytes", tostring(data.export_id or state.export_id or ""), tostring(data.rows or 0), tostring(data.bytes or 0)))
    elseif data and data.path then notify("exported " .. tostring(data.path)) end
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
  local state = {
    result = result, runner = opts.runner, handle = result.result_handle or result.handle_id,
    generation = result.generation, columns = columns, rows = rows, by_source = {}, json = {}, trees = {}, expanded = {}, raw = {},
    page_size = opts.page_size or 10, page = 1, matching_count = #rows, retained_count = #rows,
    indices = {}, all_indices = {}, current_match = #rows > 0 and 1 or 0, current_source = #rows > 0 and 1 or nil,
  }
  for i, row in ipairs(rows) do state.by_source[i], state.indices[i], state.all_indices[i] = row, i, i end
  local buf = vim.api.nvim_create_buf(false, true); state.buf = buf; state.closed = false
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype, vim.bo[buf].modifiable = "querybook", false
  redraw(state)
  local width, height = math.min(vim.o.columns - 4, 120), math.min(vim.o.lines - 6, math.max(8, vim.api.nvim_buf_line_count(buf) + 1))
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2), width = width, height = height, style = "minimal", border = "rounded" }); state.win = win
  local function map(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc }) end
  local function move(delta) set_row(state, state.current_match + delta) end
  map("]r", function() move(1) end, "Querybook: next matching row"); map("[r", function() move(-1) end, "Querybook: previous matching row")
  map("]p", function() state.page = state.page + 1; request_page(state, { page = state.page }) end, "Querybook: next matching page")
  map("[p", function() state.page = math.max(1, state.page - 1); request_page(state, { page = state.page }) end, "Querybook: previous matching page")
  map("r", function() move(1) end, "Querybook: next matching row"); map("R", function() move(-1) end, "Querybook: previous matching row")
  map("<CR>", function()
    local loc = current_location(state); if not loc then return end
    local key = loc.key; state.expanded[key] = not state.expanded[key]; redraw(state)
  end, "Querybook: expand or collapse JSON node")
  map("za", function()
    local loc = current_location(state); if not loc then return end
    state.expanded[loc.key] = not state.expanded[loc.key]; redraw(state)
  end, "Querybook: expand or collapse JSON node")
  map("gR", function()
    local loc = current_location(state); if loc and loc.key then state.raw[loc.key] = not state.raw[loc.key]; redraw(state) end
  end, "Querybook: toggle raw/formatted value")
  map("x", function() M.cancel_export(state) end, "Querybook: cancel export")
  map("yv", function()
    local loc = current_location(state); if not loc or loc.kind ~= "field" then return notify("place cursor on a field", vim.log.levels.WARN) end
    local row = state.by_source[loc.row] or row_for(state); local text = render.value_text(row, loc.column); vim.fn.setreg('"', text); pcall(vim.fn.setreg, "+", text)
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
        if err then notify(err, vim.log.levels.WARN) elseif data then copy(data.payload or data.json or data.text) end
      end)
    else
      local fields = {}; for i, column in ipairs(state.columns) do local value, null, cell = render.value(row_for(state), i); fields[#fields + 1] = { column = column_name(column), value = null and vim.NIL or value, encoding = cell and cell.kind == "binary" and "base64" or "text" } end
      copy(vim.json.encode({ connection = state.result.connection_name or "connection", database = state.result.database or "", columns = state.columns, rows = { fields } }))
    end
  end, "Querybook: copy exact payload JSON")
  map("q", function() state.closed = true; vim.api.nvim_win_close(win, true) end, "Querybook: close inspector")
  if state.handle then request_page(state, { page = 1, match_index = state.current_match }) end
  return state
end

return M
