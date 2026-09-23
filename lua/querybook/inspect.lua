local render = require("querybook.render")

local M = {}
local ns = vim.api.nvim_create_namespace("querybook-inspect")

-- The inspector owns presentation state only.  Row and cell values are never
-- rewritten: source indices, result handles, and expansion paths identify all
-- state held here.  The runner is the authority for filtered views, compares,
-- and exports when a result handle is available.  Row navigation reads the
-- already retained Lua rows; JSON trees are loaded lazily from the runner.
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

local function type_group(column)
  local typ = column_type(column)
  if not typ or typ == "" then return nil end
  local low = tostring(typ):lower()
  if low:find("json", 1, true) or low:find("struct", 1, true) then return "structured" end
  if low:find("blob", 1, true) or low:find("binary", 1, true) or low:find("bytea", 1, true) then return "binary" end
  if low:find("time", 1, true) or low:find("date", 1, true) then return "temporal" end
  return nil
end

local function looks_like_json(text)
  local trimmed = vim.trim(tostring(text or ""))
  return trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "["
end

local function decode_json_string(raw)
  if type(raw) ~= "string" or raw:sub(1, 1) ~= '"' then return raw end
  local ok, decoded = pcall(vim.json.decode, raw)
  if ok and type(decoded) == "string" then return decoded end
  return raw
end

local function entry_label(entry, index)
  if entry and entry.key and entry.key.raw then return decode_json_string(entry.key.raw) end
  return "[" .. tostring((index or 1) - 1) .. "]"
end

local function json_ident(key)
  if type(key) == "string" and key:match("^[%a_][%w_]*$") then return "." .. key end
  return "[" .. vim.json.encode(tostring(key)) .. "]"
end

local function child_json_path(parent, entry, index)
  parent = parent or "$"
  if entry and entry.key and entry.key.raw then return parent .. json_ident(decode_json_string(entry.key.raw)) end
  return parent .. "[" .. tostring((index or 1) - 1) .. "]"
end

local function compact_preview(text, max_len)
  text = tostring(text or ""):gsub("%s+", " ")
  max_len = max_len or 48
  if vim.fn.strdisplaywidth(text) <= max_len then return text end
  if max_len <= 1 then return "…" end
  local lo, hi, best = 0, vim.fn.strchars(text), 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local candidate = vim.fn.strcharpart(text, 0, mid)
    if vim.fn.strdisplaywidth(candidate) <= max_len - 1 then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, best) .. "…"
end

local function pad_name(name, width)
  name = tostring(name or "")
  local extra = math.max(1, width - vim.fn.strdisplaywidth(name) + 2)
  return name .. string.rep(" ", extra)
end

local function byte_size(n)
  n = tonumber(n) or 0
  if n < 1024 then return string.format("%d B", n) end
  return string.format("%.1f KB", n / 1024)
end

local function special_display(cell, text)
  if not cell or cell.kind == "null" then return "NULL", "QuerybookInspectNull" end
  if cell.kind == "binary" then return "base64:" .. tostring(cell.base64 or cell.text or ""), nil end
  local value = text
  if value == nil then value = cell.text or "" end
  if cell.value_kind == "boolean" then
    if value == "0" or value == "false" or value == "FALSE" then return "false", "QuerybookInspectFalse" end
    if value == "1" or value == "true" or value == "TRUE" then return "true", nil end
  end
  if value == "" then return '""', "QuerybookInspectEmpty" end
  if cell.value_kind == "integer" or cell.value_kind == "unsigned" or cell.value_kind == "float" then
    return tostring(value), nil
  end
  return tostring(value), nil
end

local function node_scalar(node)
  if not node then return "", nil end
  if node.type == "null" then return "null", "QuerybookInspectNull" end
  if node.type == "boolean" and (node.raw == "false" or node.raw == "FALSE") then return "false", "QuerybookInspectFalse" end
  if node.type == "string" then
    local decoded = decode_json_string(node.raw)
    if decoded == "" then return '""', "QuerybookInspectEmpty" end
    return decoded, nil
  end
  return tostring(node.raw or ""), nil
end

local function node_preview(node)
  if not node then return "" end
  if node.type == "array" then
    local n = node.children and #node.children
    if n then return "[" .. tostring(n) .. "]" end
  end
  if node.type == "object" or node.type == "array" or node.type == "truncated" then
    return compact_preview(node.raw, 48)
  end
  local text = node_scalar(node)
  return text
end

local function node_expandable(node)
  return node and (node.type == "object" or node.type == "array") and node.children and #node.children > 0
end

local function cell_expandable(_, cell, text)
  return looks_like_json(text) or (cell and cell.kind == "text" and looks_like_json(cell.text))
end

local function marker(expanded, expandable, column)
  if expandable then return expanded and "▼ " or "▶ " end
  if type(column) == "table" and (column.primary_key or column.pk) then return "◆ " end
  return "  "
end

local function json_node_for(state, column, source_index)
  local key = tostring(source_index) .. ":" .. tostring(column)
  return state.trees[key]
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
  local page_count = math.max(1, math.ceil(math.max(matching, 1) / state.page_size))
  local source = state.current_source and ((state.current_source + 1) .. "/" .. retained) or "-"
  local header = string.format("matching %d/%d · source %s · page %d/%d", state.current_match or 0, matching, source, state.page or 1, page_count)
  if state.pinned_source ~= nil and state.pinned_source == state.current_source then
    header = header .. " · pinned"
  end
  lines[#lines + 1] = header
  if state.pinned_source ~= nil and state.pinned_source ~= state.current_source then
    lines[#lines + 1] = "pinned source " .. tostring(state.pinned_source + 1)
  end
  if state.filter then lines[#lines + 1] = "local filter: " .. state.filter end
  return lines
end

local function row_for(state)
  if state.current_source == nil then return nil end
  if state.by_source[state.current_source] then return state.by_source[state.current_source] end
  return state.rows[state.current_source + 1]
end

local function name_width_for(columns)
  local width = 8
  for _, column in ipairs(columns or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(column_name(column)))
  end
  return math.min(width, 28)
end

local function sibling_width(entries)
  local width = 1
  for index, entry in ipairs(entries or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(entry_label(entry, index)))
  end
  return math.min(width, 28)
end

local function render_lines(state)
  local lines, locations, highlights = {}, {}, {}
  local function add(line, location, hl, value_text)
    lines[#lines + 1] = line
    locations[#lines] = location
    if hl and value_text and value_text ~= "" then
      local last = nil
      local idx = 1
      while true do
        local found = line:find(value_text, idx, true)
        if not found then break end
        last = found
        idx = found + 1
      end
      if last then
        highlights[#lines] = { group = hl, col = last - 1, last = last - 1 + #value_text }
      end
    end
  end
  for _, line in ipairs(format_meta(state.result, state)) do add(line) end
  local row = row_for(state)
  if not row then add("(no matching rows)"); return lines, locations, highlights end
  add("")
  local width = name_width_for(state.columns)
  for col, column in ipairs(state.columns) do
    local key = tostring(state.current_source) .. ":" .. tostring(col)
    local value, cell
    if state.live_cells[key] then
      value, cell = cell_display(state.live_cells[key])
    else
      value, cell = cell_text(row, col)
    end
    local shown, hl = special_display(cell, value)
    local expandable = cell_expandable(column, cell, shown)
    local expanded = state.expanded[key] == true
    local raw_mode = state.raw[key] == true
    local tree = json_node_for(state, col, state.current_source)
    if expandable and not raw_mode and expanded and node_expandable(tree) then
      add(marker(true, true, column) .. column_name(column), { kind = "field", row = state.current_source, column = col, key = key, json_path = "$", expandable = true })
      local function visit(node, depth, path)
        if not node then return end
        local children = node.children or {}
        local child_width = sibling_width(children)
        local prefix = string.rep("  ", depth)
        for index, entry in ipairs(children) do
          local child = entry.node or entry
          local child_path = child_json_path(path, entry, index)
          local child_key = key .. ":" .. child_path
          local label = entry_label(entry, index)
          local can_expand = node_expandable(child)
          local child_expanded = can_expand and state.expanded[child_key] == true
          local child_raw = state.raw[child_key] == true
          local loc = { kind = "node", row = state.current_source, column = col, path = child_path, json_path = child_path, key = child_key, expandable = can_expand, raw = child.raw }
          if child_raw or not can_expand then
            local scalar, child_hl = node_scalar(child)
            if can_expand then scalar = compact_preview(child.raw, 48) end
            add(prefix .. marker(false, can_expand) .. pad_name(label, child_width) .. scalar, loc, child_hl, scalar)
          elseif child_expanded then
            local extra = child.type == "array" and child.children and (" [" .. tostring(#child.children) .. "]") or ""
            add(prefix .. marker(true, true) .. label .. extra, loc)
            visit(child, depth + 1, child_path)
          else
            local preview = node_preview(child)
            add(prefix .. marker(false, true) .. pad_name(label, child_width) .. preview, loc)
          end
        end
      end
      visit(tree, 1, "$")
    else
      local suffix = raw_mode and " (raw)" or ""
      if expandable then shown = compact_preview(cell and (cell.text or cell.base64) or shown, 48) end
      if raw_mode then
        shown = compact_preview(cell and (cell.text or cell.base64) or value, 72)
        hl = nil
      end
      add(marker(false, expandable, column) .. pad_name(column_name(column), width) .. shown .. suffix, {
        kind = "field", row = state.current_source, column = col, key = key, json_path = expandable and "$" or nil, expandable = expandable,
      }, hl, shown)
    end
  end
  return lines, locations, highlights
end

local function notify(message, level)
  vim.notify("Querybook: " .. message, level or vim.log.levels.INFO)
end

local function invoke(runner, op, payload, callback)
  if runner and runner.result then return runner.result(op, payload, callback) end
  callback(nil, "result registry is unavailable")
end

local function merge_page(state, data)
  if type(data) ~= "table" then return false end
  if data.metadata and data.metadata.columns then state.columns = data.metadata.columns end
  if data.columns then state.columns = data.columns end
  local rows = data.rows or data.result_rows
  if rows then
    state.page_sources = {}
    local source = data.source_rows or data.source_indices or data.row_indices or data.indices or {}
    for i, row in ipairs(rows) do
      local source_index = tonumber(source[i]) or (type(row) == "table" and tonumber(row.source_index)) or (i - 1)
      if type(row) == "table" and row.row then row = row.row end
      state.by_source[source_index] = row
      state.page_sources[i] = source_index
    end
  end
  local trees = data.trees or data.json_trees or data.presentation
  if trees then
    for key, tree in pairs(trees) do state.trees[key] = tree end
  end
  state.retained_count = tonumber(data.retained_count or data.total_retained) or state.retained_count
  state.matching_count = tonumber(data.total_rows or data.matching_count or data.total_matching) or state.matching_count
  if data.view_id then state.view_id = data.view_id end
  return true
end

local function apply_highlights(state, highlights)
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for line, hl in pairs(highlights or {}) do
    if hl and hl.group then
      pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, hl.group, line - 1, hl.col, hl.last)
    end
  end
end

local function redraw(state)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local source_lines, source_locations, source_highlights = render_lines(state)
  local lines, locations, highlights = {}, {}, {}
  for i, line in ipairs(source_lines) do
    local parts = vim.split(tostring(line), "\n", { plain = true })
    for _, part in ipairs(parts) do
      lines[#lines + 1] = part
      locations[#lines] = source_locations[i]
      highlights[#lines] = source_highlights[i]
    end
  end
  state.locations = locations
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  apply_highlights(state, highlights)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local height = math.min(vim.o.lines - 6, math.max(8, #lines + 1))
    local width = math.min(vim.o.columns - 4, 80)
    pcall(vim.api.nvim_win_set_config, state.win, { height = height, width = width })
  end
end

local function focus_column(state, column)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  -- Header lines store no location, so the location list has holes and ipairs stops.
  local function seek(match)
    for line = 1, vim.api.nvim_buf_line_count(state.buf) do
      local loc = state.locations and state.locations[line]
      if loc and loc.kind == "field" and (not match or loc.column == match) then
        pcall(vim.api.nvim_win_set_cursor, state.win, { line, 0 })
        return true
      end
    end
  end
  if column and seek(column) then return end
  seek()
end

local function current_location(state)
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then return nil end
  return state.locations[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function request_page(state, payload)
  payload = vim.tbl_extend("force", payload or {}, { result_handle = state.handle, limit = (payload and payload.limit) or 1, view_id = state.view_id })
  if payload.offset == nil then payload.offset = math.max(0, (state.current_match or 1) - 1) end
  invoke(state.runner, "view", payload, function(data, err)
    if state.closed or state.generation ~= state.result.generation then return end
    if err then notify(err, vim.log.levels.WARN); return end
    merge_page(state, data)
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

local function set_row(state, match, keep_column)
  local column = keep_column
  if column == nil and state.win and vim.api.nvim_win_is_valid(state.win) then
    local loc = current_location(state)
    column = loc and loc.column
  end
  if state.matching_count == 0 then
    state.current_match = 0
    state.current_source = nil
    state.page = 1
    redraw(state)
    return
  end
  state.current_match = math.max(1, math.min(match, state.matching_count))
  local source = state.indices and state.indices[state.current_match]
  if source ~= nil then state.current_source = tonumber(source) end
  state.page = math.floor((state.current_match - 1) / state.page_size) + 1
  if state.current_source ~= nil and not state.by_source[state.current_source] and not state.rows[state.current_source + 1] and state.handle then
    request_page(state, { offset = state.current_match - 1, limit = 1, source_row = state.current_source })
    return
  end
  redraw(state)
  focus_column(state, column)
end

local function move_page(state, delta)
  local matching = state.matching_count or 0
  local page_count = math.max(1, math.ceil(math.max(matching, 1) / state.page_size))
  local page = math.max(1, math.min((state.page or 1) + delta, page_count))
  set_row(state, (page - 1) * state.page_size + 1)
end

local function toggle_expand(state)
  local loc = current_location(state)
  if not loc or not loc.key then return end
  if loc.kind == "field" then
    local function apply(tree)
      if tree and (tree.type == "object" or tree.type == "array") and node_expandable(tree) then
        state.expanded[loc.key] = not state.expanded[loc.key]
      elseif tree and tree.type == "raw" then
        notify("value is not valid JSON", vim.log.levels.WARN)
        state.expanded[loc.key] = false
      end
      redraw(state)
      if loc.column then focus_column(state, loc.column) end
    end
    if not state.trees[tostring(loc.row) .. ":" .. tostring(loc.column)] then
      load_tree(state, loc, apply)
    else
      apply(state.trees[tostring(loc.row) .. ":" .. tostring(loc.column)])
    end
    return
  end
  if loc.expandable then
    state.expanded[loc.key] = not state.expanded[loc.key]
    redraw(state)
  end
end

local function copy(text)
  text = tostring(text or "")
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
end

local function column_metadata_line(column, cell)
  local parts = { column_name(column) }
  local typ = column_type(column)
  if typ and typ ~= "" then parts[#parts + 1] = tostring(typ) end
  if column.primary_key or column.pk then parts[#parts + 1] = "PRIMARY KEY" end
  if type(column.nullable) == "boolean" then parts[#parts + 1] = column.nullable and "nullable" or "NOT NULL" end
  if column.auto_increment or column.autoincrement then parts[#parts + 1] = "AUTO_INCREMENT" end
  if column.default ~= nil then parts[#parts + 1] = "default " .. tostring(column.default) end
  local group = type_group(column)
  local nbytes = 0
  if cell then
    if cell.kind == "binary" then nbytes = #tostring(cell.base64 or "")
    else nbytes = #tostring(cell.text or "") end
  end
  if group == "structured" or group == "binary" or nbytes >= 1024 then
    parts[#parts + 1] = byte_size(nbytes)
  end
  return table.concat(parts, " · ")
end

function M.sync(state)
  if not state or state.closed then return end
  redraw(state)
end

function M.set_row(state, match)
  set_row(state, match)
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
    set_row(state, 1)
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
  set_row(state, 1)
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

local function setup_highlights()
  vim.api.nvim_set_hl(0, "QuerybookInspectNull", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "QuerybookInspectEmpty", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "QuerybookInspectFalse", { link = "Boolean", default = true })
end

function M.open(result, opts)
  opts = opts or {}
  setup_highlights()
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
  if type(opts.match) == "number" and state.matching_count > 0 then
    state.current_match = math.max(1, math.min(math.floor(opts.match), state.matching_count))
    local source = state.indices[state.current_match]
    if source ~= nil then state.current_source = tonumber(source) end
    state.page = math.floor((state.current_match - 1) / state.page_size) + 1
  end
  local buf = vim.api.nvim_create_buf(false, true); state.buf = buf; state.closed = false
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() state.closed = true end })
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype, vim.bo[buf].modifiable = "querybook", false
  redraw(state)
  local width, height = math.min(vim.o.columns - 4, 80), math.min(vim.o.lines - 6, math.max(8, vim.api.nvim_buf_line_count(buf) + 1))
  local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2), width = width, height = height, style = "minimal", border = "rounded" }); state.win = win
  if opts.column then focus_column(state, opts.column) end
  local function map(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc }) end
  map("]r", function() set_row(state, state.current_match + 1) end, "Querybook: next matching row")
  map("[r", function() set_row(state, state.current_match - 1) end, "Querybook: previous matching row")
  map("]p", function() move_page(state, 1) end, "Querybook: next matching page")
  map("[p", function() move_page(state, -1) end, "Querybook: previous matching page")
  map("r", function() set_row(state, state.current_match + 1) end, "Querybook: next matching row")
  map("R", function() set_row(state, state.current_match - 1) end, "Querybook: previous matching row")
  map("p", function() M.pin(state) end, "Querybook: pin or unpin current row")
  map("<CR>", function() toggle_expand(state) end, "Querybook: expand or collapse JSON node")
  map("za", function() toggle_expand(state) end, "Querybook: expand or collapse JSON node")
  map("gR", function()
    local loc = current_location(state); if not loc or not loc.column then return end
    local key = tostring(loc.row) .. ":" .. tostring(loc.column)
    if loc.kind == "node" then key = loc.key end
    state.raw[key] = not state.raw[key]
    redraw(state)
  end, "Querybook: toggle raw/formatted value")
  map("K", function()
    local loc = current_location(state)
    if not loc or not loc.column then return notify("place cursor on a field", vim.log.levels.WARN) end
    if loc.kind == "node" then
      local details = tostring(loc.json_path or loc.path or "$")
      if loc.raw then details = details .. " · " .. byte_size(#tostring(loc.raw)) end
      notify(details)
      return
    end
    local column = state.columns[loc.column] or {}
    local row = row_for(state)
    local _, _, cell = render.value(row, loc.column)
    if state.live_cells[loc.key] then cell = state.live_cells[loc.key] end
    notify(column_metadata_line(column, cell))
  end, "Querybook: show source column metadata")
  map("gQ", function() notify(tostring(state.result.query or ""), vim.log.levels.INFO) end, "Querybook: show full execution SQL")
  map("x", function() M.cancel_export(state) end, "Querybook: cancel export")
  map("yv", function()
    local loc = current_location(state); if not loc then return notify("place cursor on a field", vim.log.levels.WARN) end
    if loc.kind == "node" then
      if loc.raw then copy(loc.raw) else notify("payload is unavailable", vim.log.levels.WARN) end
      return
    end
    if loc.kind ~= "field" then return notify("place cursor on a field", vim.log.levels.WARN) end
    local row = state.by_source[loc.row] or row_for(state)
    if row then
      local value, is_null, cell = render.value(row, loc.column)
      if is_null then copy("NULL") elseif cell and cell.kind == "binary" then copy("base64:" .. tostring(cell.base64 or "")) else copy(tostring(value or "")) end
      return
    end
    if state.handle and state.runner and state.runner.result then
      invoke(state.runner, "cell", { result_handle = state.handle, row = loc.row, column = loc.column - 1 }, function(data, err)
        if err then notify(err, vim.log.levels.WARN); return end
        local cell = data and (data.cell or data.Cell)
        if not cell then return notify("cell is unavailable", vim.log.levels.WARN) end
        if cell.kind == "null" then copy("NULL") elseif cell.kind == "binary" then copy("base64:" .. tostring(cell.base64 or "")) else copy(tostring(cell.text or "")) end
      end)
    else
      notify("cell is unavailable", vim.log.levels.WARN)
    end
  end, "Querybook: copy exact field")
  map("yn", function()
    local loc = current_location(state); if not loc or not loc.column then return notify("place cursor on a field", vim.log.levels.WARN) end
    if loc.kind == "node" then
      local path = loc.json_path or loc.path or ""
      local key = path:match("%['([^']+)'%]$") or path:match("%[\"([^\"]+)\"%]$") or path:match("%.([%w_]+)$") or path:match("%[(%d+)%]$")
      copy(key or column_name(state.columns[loc.column]))
      return
    end
    copy(column_name(state.columns[loc.column]))
  end, "Querybook: copy column or node name")
  map("yj", function()
    local loc = current_location(state)
    if not loc or not loc.json_path then return notify("place cursor on a JSON node", vim.log.levels.WARN) end
    copy(loc.json_path)
  end, "Querybook: copy JSONPath of the current node")
  map("yr", function()
    local loc = current_location(state); if not loc or not loc.row then return notify("place cursor on a row", vim.log.levels.WARN) end
    local row = state.by_source[loc.row] or row_for(state); local fields = {}
    for i, column in ipairs(state.columns) do local value, null, cell = render.value(row, i); fields[#fields + 1] = { column = column_name(column), value = null and vim.NIL or value, encoding = cell and cell.kind == "binary" and "base64" or "text" } end
    copy(vim.json.encode(fields))
  end, "Querybook: copy exact row JSON")
  map("yp", function()
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
  if state.current_source ~= nil and not state.by_source[state.current_source] and state.handle then
    request_page(state, { offset = math.max(0, (state.current_match or 1) - 1), limit = 1, source_row = state.current_source })
  end
  return state
end

return M
