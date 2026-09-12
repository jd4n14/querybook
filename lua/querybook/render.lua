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

local function clip(value, width)
  value = tostring(value):gsub("\n", "\\n"):gsub("\r", "\\r")
  if width < 2 then return value:sub(1, width) end
  if #value > width then return value:sub(1, width - 1) .. "…" end
  return value .. string.rep(" ", width - #value)
end

local function chunks(text, hl) return { { text, hl } } end

local function box_line(text, fill, right, hl)
  return { text = text, fill = fill, right = right, hl = hl }
end

local function close_box(parts)
  local width = 0
  for _, part in ipairs(parts) do
    width = math.max(width, vim.fn.strdisplaywidth(part.text) + 2)
  end
  local lines = {}
  for _, part in ipairs(parts) do
    local pad = math.max(0, width - vim.fn.strdisplaywidth(part.text) - 1)
    lines[#lines + 1] = chunks(part.text .. string.rep(part.fill, pad) .. part.right, part.hl)
  end
  return lines
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

function M.lines(result, config)
  config = config or {}
  -- preview_rows is the new name. max_rows remains a compatibility override.
  local preview_rows = config.preview_rows or config.max_rows or 10
  local max_columns = config.max_columns or 12
  local max_value_length = config.max_value_length or 128
  local max_width = config.max_column_width or 32
  local rows = result.rows or {}
  local columns = result.columns or {}
  local source_rows = result.view_active and result.view_source_rows
  local total_rows = source_rows and #source_rows or #rows
  local row_offset = math.max(0, math.min(result.row_offset or 0, math.max(0, total_rows - 1)))
  local column_offset = math.max(0, math.min(result.column_offset or 0, math.max(0, #columns - 1)))
  local visible = {}
  for i = column_offset + 1, math.min(#columns, column_offset + max_columns) do
    local column = columns[i]
    local copy = type(column) == "table" and vim.deepcopy(column) or { name = tostring(column) }
    copy._index = i
    visible[#visible + 1] = copy
  end
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
  if result.status == "error" and result.previous_query then
    parts[#parts + 1] = box_line("  │ previous successful data retained; Inspect shows full values", " ", "│", "QuerybookMeta")
  end
  if result.collapsed then
    parts[#parts + 1] = box_line("  │ [collapsed] QuerybookToggle to expand · QuerybookInspect for full result", " ", "│", "QuerybookMeta")
  elseif #visible > 0 then
    local preview_rows = math.max(1, preview_rows)
    local widths = {}
    for i, column in ipairs(visible) do
      widths[i] = math.min(max_width, math.max(#name(column), 3))
      for row_index = row_offset + 1, math.min(total_rows, row_offset + preview_rows) do
        local source = source_rows and source_rows[row_index]
        local row = source_rows and rows[source + 1] or rows[row_index]
        widths[i] = math.min(max_width, math.max(widths[i], #M.value_text(row, column)))
      end
    end
    local header, divider = "  │ ", "  ├─"
    for i, column in ipairs(visible) do
      header = header .. clip(name(column), widths[i]) .. (i == #visible and "" or " │ ")
      divider = divider .. string.rep("─", widths[i]) .. (i == #visible and "" or "─┼─")
    end
    parts[#parts + 1] = box_line(header, " ", "│", "QuerybookHeader")
    parts[#parts + 1] = box_line(divider, "─", "┤", "QuerybookDivider")
    local first = row_offset + 1
    local last = math.min(total_rows, row_offset + preview_rows)
    for row_index = first, last do
      local source = source_rows and source_rows[row_index]
      local row, row_text = source_rows and rows[source + 1] or rows[row_index], "  │ "
      for i, column in ipairs(visible) do
        local raw = M.value_text(row, column)
        if #raw > max_value_length then
          raw = raw:sub(1, math.max(1, max_value_length - 1)) .. "…"
        end
        row_text = row_text .. clip(raw, widths[i]) .. (i == #visible and "" or " │ ")
      end
      parts[#parts + 1] = box_line(row_text, " ", "│", "QuerybookRow")
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
    if #columns > #visible then
      parts[#parts + 1] = box_line("  │ columns " .. (column_offset + 1) .. "-" .. (column_offset + #visible) .. " of " .. #columns .. " · QuerybookNextColumn/PrevColumn", " ", "│", "QuerybookMeta")
    end
  elseif result.status ~= "error" then
    parts[#parts + 1] = box_line("  │ (no columns returned)", " ", "│", "QuerybookMeta")
  end
  parts[#parts + 1] = box_line("  └", "─", "┘", "QuerybookDivider")
  return close_box(parts)
end

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "QuerybookMeta", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "QuerybookHeader", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "QuerybookRow", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "QuerybookDivider", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "QuerybookError", { link = "DiagnosticError", default = true })
end

return M
