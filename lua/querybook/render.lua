local M = {}

local function name(column)
  return type(column) == "table" and column.name or tostring(column)
end

function M.column_name(column) return name(column) end
function M.cell(row, index) return row and row[index] end

function M.value(row, column)
  local index = type(column) == "number" and column or type(column) == "table" and column._index
  if not index and type(column) == "string" and row then
    for i, cell in ipairs(row) do
      if cell.column == column then index = i; break end
    end
  end
  local cell = row and row[index]
  if not cell or cell.kind == "null" then return nil, true, cell end
  if cell.kind == "binary" then return cell.base64 or "", false, cell end
  return cell.text or "", false, cell
end

function M.value_text(row, column)
  local value, is_null = M.value(row, column)
  return is_null and "NULL" or tostring(value)
end

local function display_len(text)
  return vim.fn.strdisplaywidth(tostring(text or ""))
end

local function truncate_display(text, width)
  text = tostring(text or "")
  if width <= 0 then return "" end
  if display_len(text) <= width then return text end
  if width == 1 then return "…" end
  local lo, hi, best = 0, vim.fn.strchars(text), 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local candidate = vim.fn.strcharpart(text, 0, mid)
    if display_len(candidate) <= width - 1 then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, best) .. "…"
end

local function clip(value, width)
  value = tostring(value):gsub("\n", "\\n"):gsub("\r", "\\r")
  if width <= 0 then return "" end
  if #value > width * 4 + 8 then value = value:sub(1, width * 4 + 8) end
  local truncated = truncate_display(value, width)
  return truncated .. string.rep(" ", math.max(0, width - display_len(truncated)))
end

local function chunks(text, hl) return { { text, hl } } end

local function box_line(text, fill, right, hl)
  return { text = text, fill = fill, right = right, hl = hl }
end

local function part_plain(part)
  if part.spans then
    local out = {}
    for _, span in ipairs(part.spans) do out[#out + 1] = span[1] end
    return table.concat(out)
  end
  return part.text or ""
end

local function close_box(parts, target)
  local width = 0
  for _, part in ipairs(parts) do
    width = math.max(width, display_len(part_plain(part)) + 2)
  end
  if type(target) == "number" and target > 0 then width = math.max(1, math.floor(target)) end
  local lines = {}
  for _, part in ipairs(parts) do
    local plain = part_plain(part)
    local max_text = math.max(0, width - 1)
    if part.spans and display_len(plain) <= max_text then
      local spans, len = {}, 0
      for _, span in ipairs(part.spans) do
        spans[#spans + 1] = { span[1], span[2] }
        len = len + display_len(span[1])
      end
      local pad = math.max(0, width - len - 1)
      if pad > 0 then spans[#spans + 1] = { string.rep(part.fill or " ", pad), part.hl } end
      spans[#spans + 1] = { part.right or "│", part.hl }
      lines[#lines + 1] = spans
    else
      local text = plain
      if display_len(text) > math.max(0, width - 2) then text = truncate_display(text, math.max(0, width - 2)) end
      local pad = math.max(0, width - display_len(text) - 1)
      lines[#lines + 1] = chunks(text .. string.rep(part.fill or " ", pad) .. (part.right or "│"), part.hl)
    end
  end
  return lines
end

local function span_line(spans, hl)
  return { spans = spans, fill = " ", right = "│", hl = hl }
end

local function column_budget(target, n)
  if n <= 0 then return 0 end
  return math.max(1, target - 6 - 3 * (n - 1))
end

local function column_cap(config)
  local cap = config.max_column_width
  if type(cap) ~= "number" or cap < 1 then cap = 32 end
  return math.floor(cap)
end

local function column_limit(config)
  local limit = config.max_columns
  if type(limit) ~= "number" or limit < 1 then return nil end
  return math.floor(limit)
end

local function append_index(list, value)
  local copy = {}
  for i, item in ipairs(list) do copy[i] = item end
  copy[#copy + 1] = value
  return copy
end

-- A long cell used to claim the whole window and shrink the columns on its
-- right down to one character. Each column now keeps its header, long values
-- start at max_column_width, and leftover space goes to values that are still
-- clipped. The last column still absorbs leftover space when nothing is clipped,
-- so the grid continues to fill the window.
local function assign_widths(visible, target)
  local n = #visible
  if n == 0 then return {} end
  local budget = column_budget(target, n)
  local widths, sum = {}, 0
  for i, col in ipairs(visible) do
    widths[i] = col.preferred
    sum = sum + col.preferred
  end
  if sum > budget then
    local overflow = sum - budget
    for i = n, 1, -1 do
      if overflow <= 0 then break end
      local slack = widths[i] - visible[i].floor
      if slack > 0 then
        local take = math.min(slack, overflow)
        widths[i] = widths[i] - take
        overflow = overflow - take
      end
    end
    for i = n, 1, -1 do
      if overflow <= 0 then break end
      local take = math.min(math.max(0, widths[i] - 1), overflow)
      widths[i] = widths[i] - take
      overflow = overflow - take
    end
  elseif sum < budget then
    local extra = budget - sum
    local clipped, total = {}, 0
    for i, col in ipairs(visible) do
      local over = math.max(0, col.content - widths[i])
      if over > 0 then
        clipped[#clipped + 1] = { index = i, over = over }
        total = total + over
      end
    end
    if #clipped == 0 then
      widths[n] = widths[n] + extra
    else
      local given = 0
      for i, item in ipairs(clipped) do
        local share = i == #clipped and (extra - given) or math.floor(extra * item.over / total)
        given = given + share
        widths[item.index] = widths[item.index] + share
      end
    end
  end
  return widths
end

local function resolve_display_width(config)
  if type(config.display_width) == "number" and config.display_width > 0 then
    return math.floor(config.display_width)
  end
  local ok, width = pcall(vim.api.nvim_win_get_width, 0)
  if ok and type(width) == "number" and width > 0 then return width end
  return tonumber(vim.o.columns) or 80
end

local function compact_database(result)
  local value = tostring(result.database or "")
  if value == "" then return "(none)" end
  if #value <= 40 then return value end
  if result.connection_driver == "sqlite" then
    local tail = vim.fn.fnamemodify(value, ":t")
    if tail ~= "" and tail ~= value then return "…/" .. tail end
  end
  return value:sub(1, 18) .. "…" .. value:sub(-18)
end

local function range_label(first, last, total)
  if total == 0 then return "0 rows" end
  return string.format("rows %d-%d of %d", first, last, total)
end

local function fit_chars(text, width)
  text = tostring(text or "")
  if width <= 0 then return "", text end
  if display_len(text) <= width then return text, "" end
  local lo, hi, best = 0, vim.fn.strchars(text), 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local candidate = vim.fn.strcharpart(text, 0, mid)
    if display_len(candidate) <= width then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, best), vim.fn.strcharpart(text, best)
end

local function detail_value_lines(label, value, target)
  local max_text = math.max(1, target - 2)
  local lines = {}
  local remain = tostring(value or ""):gsub("\n", "\\n")
  remain = remain:gsub("\r", "\\r")
  for n = 1, 3 do
    local prefix = n == 1 and ("  │ ▸ " .. label .. " · ") or "  │ "
    if display_len(prefix) >= max_text then
      lines[#lines + 1] = truncate_display(prefix .. remain, max_text)
      break
    end
    local room = max_text - display_len(prefix)
    local head, tail = fit_chars(remain, room)
    if tail ~= "" and n == 3 then head = truncate_display(remain, room) end
    lines[#lines + 1] = prefix .. head
    remain = tail
    if remain == "" or n == 3 then break end
  end
  return lines
end

local function column_range_label(visible, total)
  local parts, i = {}, 1
  while i <= #visible do
    local j = i
    while j + 1 <= #visible and visible[j + 1].index == visible[j].index + 1 do j = j + 1 end
    parts[#parts + 1] = i == j and tostring(visible[i].index) or (visible[i].index .. "-" .. visible[j].index)
    i = j + 1
  end
  return "columns " .. table.concat(parts, ", ") .. " of " .. tostring(total)
end

-- max_columns nil shows every column whose header fits. A positive number is
-- only a ceiling. Once the viewport scrolls, the first result column stays
-- pinned when the window can hold it beside the scrolled column.
local function prepare(result, config)
  config = config or {}
  local preview_rows = math.max(1, config.preview_rows or config.max_rows or 10)
  local target = resolve_display_width(config)
  local cap = column_cap(config)
  local limit = column_limit(config)
  local rows = result.rows or {}
  local columns = result.columns or {}
  local source_rows = result.view_active and result.view_source_rows
  local total_rows = source_rows and #source_rows or #rows
  local row_offset = math.max(0, math.min(result.row_offset or 0, math.max(0, total_rows - 1)))
  local column_offset = math.max(0, math.min(result.column_offset or 0, math.max(0, #columns - 1)))
  local metrics = {}
  for i, column in ipairs(columns) do
    local copy = type(column) == "table" and vim.deepcopy(column) or { name = tostring(column) }
    copy._index = i
    local floor = math.max(1, display_len(name(copy)))
    local content = 0
    for row_index = row_offset + 1, math.min(total_rows, row_offset + preview_rows) do
      local source = source_rows and source_rows[row_index]
      local row = source_rows and rows[source + 1] or rows[row_index]
      content = math.max(content, display_len(M.value_text(row, copy)))
    end
    metrics[i] = {
      column = copy, index = i, floor = floor, content = content,
      preferred = math.max(floor, math.min(content, cap)),
    }
  end
  local function fits(indexes)
    local sum = 0
    for _, index in ipairs(indexes) do sum = sum + metrics[index].floor end
    return sum <= column_budget(target, #indexes)
  end
  local function take(indexes)
    local visible = {}
    for _, index in ipairs(indexes) do visible[#visible + 1] = metrics[index] end
    return visible
  end
  local function window(offset)
    local n = #metrics
    if n == 0 then return {} end
    offset = math.max(0, math.min(offset or 0, n - 1))
    local start = offset + 1
    if limit == 1 then return take({ start }) end
    if start > 1 and (limit == nil or limit >= 2) then
      local pinned, added = { 1 }, false
      for i = start, n do
        if i ~= 1 then
          local trial = append_index(pinned, i)
          if limit and #trial > limit then break end
          if not fits(trial) then break end
          pinned, added = trial, true
        end
      end
      if added then return take(pinned) end
    end
    local indexes = {}
    for i = start, n do
      local trial = append_index(indexes, i)
      if limit and #trial > limit then break end
      if #indexes >= 1 and not fits(trial) then break end
      indexes = trial
    end
    if #indexes == 0 then indexes = { start } end
    return take(indexes)
  end
  return {
    config = config, preview_rows = preview_rows, target = target, rows = rows, columns = columns,
    source_rows = source_rows, total_rows = total_rows, row_offset = row_offset,
    column_offset = column_offset, window = window,
  }
end

function M.visible_columns(result, config)
  local prep = prepare(result, config)
  local indexes = {}
  for _, col in ipairs(prep.window(prep.column_offset)) do indexes[#indexes + 1] = col.index end
  return indexes
end

function M.shift_column_offset(result, config, direction)
  local prep = prepare(result, config)
  local current = prep.column_offset
  if direction > 0 then
    local visible = prep.window(current)
    if #visible == 0 then return current end
    local last = visible[#visible].index
    if last >= #prep.columns then return current end
    return last
  end
  if current == 0 then return 0 end
  for off = 0, current - 1 do
    local visible = prep.window(off)
    if #visible > 0 and visible[#visible].index == current then return off end
  end
  return 0
end

function M.reveal_column(result, config, column)
  local prep = prepare(result, config)
  local n = #prep.columns
  if n == 0 then return 0 end
  local idx = math.max(1, math.min(math.floor(column or 1), n))
  local current = prep.column_offset
  local function shows(offset)
    for _, col in ipairs(prep.window(offset)) do
      if col.index == idx then return true end
    end
    return false
  end
  if shows(current) then return current end
  if idx == 1 then return 0 end
  if idx - 1 < current then return idx - 1 end
  for off = current + 1, idx - 1 do
    if shows(off) then return off end
  end
  return idx - 1
end

function M.lines(result, config)
  local prep = prepare(result, config)
  local preview_rows = prep.preview_rows
  local target = prep.target
  local rows = prep.rows
  local columns = prep.columns
  local source_rows = prep.source_rows
  local total_rows = prep.total_rows
  local row_offset = prep.row_offset
  local column_offset = prep.column_offset
  local visible = prep.window(column_offset)
  local connection = result.connection_name or "connection"
  local database = compact_database(result)
  local status
  if result.status == "error" then
    status = "ERROR · " .. tostring(result.error or "query failed")
  elseif result.status == "stale" then
    status = source_rows
      and string.format("STALE · SQL changed; %d matching rows · %d retained rows · run again", total_rows, #rows)
      or "STALE · SQL changed; " .. #rows .. " retained rows · run again"
  elseif result.status == "running" then
    status = "RUNNING"
  else
    status = source_rows
      and string.format("%d matching rows · %d retained rows · %d columns · %d ms", total_rows, #rows, #columns, result.duration_ms or 0)
      or string.format("%d retained rows · %d columns · %d ms", #rows, #columns, result.duration_ms or 0)
  end
  status = status .. " · " .. connection .. " / " .. database
  if result.auto_limit_applied then status = status .. " · auto LIMIT 500" end
  if result.truncated then status = status .. " · retained truncated (" .. tostring(result.truncation_reason or "limit") .. ")" end

  local parts = { box_line("  ┌ " .. status .. " ", "─", "┐", result.status == "error" and "QuerybookError" or "QuerybookMeta") }
  if result.filter_expression and result.filter_expression ~= "" then
    parts[#parts + 1] = box_line("  │ local filter: " .. tostring(result.filter_expression), " ", "│", "QuerybookMeta")
  end
  if result.status == "error" and result.previous_query then
    parts[#parts + 1] = box_line("  │ previous successful data retained; Inspect shows full values", " ", "│", "QuerybookMeta")
  end
  if result.collapsed then
    parts[#parts + 1] = box_line("  │ [collapsed] QuerybookToggle to expand · QuerybookInspect for full result", " ", "│", "QuerybookMeta")
  elseif #visible > 0 then
    local widths = assign_widths(visible, target)
    local grid_col = result.grid_active and math.max(1, math.min(result.grid_col or 1, #columns)) or nil
    local function row_at(row_index)
      local source = source_rows and source_rows[row_index]
      return source_rows and rows[source + 1] or rows[row_index]
    end
    local function cell_spans(base_hl, text_at)
      local spans = { { "  │ ", base_hl } }
      for i, col in ipairs(visible) do
        local hl = grid_col == col.index and "QuerybookCursor" or base_hl
        spans[#spans + 1] = { clip(text_at(col), widths[i]), hl }
        if i < #visible then spans[#spans + 1] = { " │ ", base_hl } end
      end
      return spans
    end
    local divider = "  ├─"
    for i, _ in ipairs(visible) do
      divider = divider .. string.rep("─", widths[i]) .. (i == #visible and "" or "─┼─")
    end
    if grid_col then
      parts[#parts + 1] = span_line(cell_spans("QuerybookHeader", function(col) return name(col.column) end), "QuerybookHeader")
    else
      local header = "  │ "
      for i, col in ipairs(visible) do
        header = header .. clip(name(col.column), widths[i]) .. (i == #visible and "" or " │ ")
      end
      parts[#parts + 1] = box_line(header, " ", "│", "QuerybookHeader")
    end
    parts[#parts + 1] = box_line(divider, "─", "┤", "QuerybookDivider")
    local first = row_offset + 1
    local last = math.min(total_rows, row_offset + preview_rows)
    for row_index = first, last do
      local row = row_at(row_index)
      if grid_col and row_index == result.grid_row then
        parts[#parts + 1] = span_line(cell_spans("QuerybookRow", function(col) return M.value_text(row, col.column) end), "QuerybookRow")
      else
        local row_text = "  │ "
        for i, col in ipairs(visible) do
          row_text = row_text .. clip(M.value_text(row, col.column), widths[i]) .. (i == #visible and "" or " │ ")
        end
        parts[#parts + 1] = box_line(row_text, " ", "│", "QuerybookRow")
      end
    end
    if total_rows == 0 then parts[#parts + 1] = box_line("  │ (no matching rows)", " ", "│", "QuerybookMeta") end
    if total_rows > 0 then
      local range = range_label(first, last, total_rows)
      if source_rows then
        local first_source, last_source = source_rows[first], source_rows[last]
        range = range:gsub("^rows", "matching rows") .. string.format(" · source %d-%d of %d", first_source + 1, last_source + 1, #rows)
      end
      parts[#parts + 1] = box_line("  │ " .. range .. " · QuerybookNextPage/PrevPage", " ", "│", "QuerybookMeta")
    end
    local shown = {}
    for _, col in ipairs(visible) do shown[col.index] = true end
    local shows_all = #visible == #columns
    for i = 1, #columns do
      if not shown[i] then shows_all = false; break end
    end
    if not shows_all then
      parts[#parts + 1] = box_line("  │ " .. column_range_label(visible, #columns), " ", "│", "QuerybookMeta")
    end
    if grid_col then
      local active = columns[grid_col]
      local label = name(active)
      local row_n = total_rows == 0 and 0 or math.max(0, math.min(result.grid_row or 0, total_rows))
      parts[#parts + 1] = box_line(string.format("  │ row %d · col %d/%d · %s", row_n, grid_col, #columns, label), " ", "│", "QuerybookMeta")
      local value = ""
      if row_n >= 1 then
        local copy = type(active) == "table" and vim.deepcopy(active) or { name = tostring(active or "") }
        copy._index = grid_col
        value = M.value_text(row_at(row_n), copy)
      end
      for _, line in ipairs(detail_value_lines(label, value, target)) do
        parts[#parts + 1] = box_line(line, " ", "│", "QuerybookMeta")
      end
    end
  elseif result.status ~= "error" then
    parts[#parts + 1] = box_line("  │ (no columns returned)", " ", "│", "QuerybookMeta")
  end
  parts[#parts + 1] = box_line("  └", "─", "┘", "QuerybookDivider")
  return close_box(parts, target)
end

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "QuerybookMeta", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "QuerybookHeader", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "QuerybookRow", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "QuerybookDivider", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "QuerybookError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "QuerybookCursor", { link = "Visual", default = true })
end

return M
