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
  local row_offset = math.max(0, math.min(result.row_offset or 0, math.max(0, #rows - 1)))
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
    status = "STALE · SQL changed; " .. #rows .. " retained rows · run again"
  elseif result.status == "running" then
    status = "RUNNING"
  else
    status = string.format("%d retained rows · %d columns · %d ms", #rows, #columns, result.duration_ms or 0)
  end
  status = status .. " · " .. connection .. " / " .. database
  if result.auto_limit_applied then status = status .. " · auto LIMIT 500" end
  if result.truncated then status = status .. " · retained truncated (" .. tostring(result.truncation_reason or "limit") .. ")" end

  local lines = { chunks("  ┌ " .. status, result.status == "error" and "QuerybookError" or "QuerybookMeta") }
  if result.status == "error" and result.previous_query then
    lines[#lines + 1] = chunks("  │ previous successful data retained; Inspect shows full values", "QuerybookMeta")
  end
  if result.collapsed then
    lines[#lines + 1] = chunks("  │ [collapsed] QuerybookToggle to expand · QuerybookInspect for full result", "QuerybookMeta")
  elseif #visible > 0 then
    local preview_rows = math.max(1, preview_rows)
    local widths = {}
    for i, column in ipairs(visible) do
      widths[i] = math.min(max_width, math.max(#name(column), 3))
      for row_index = row_offset + 1, math.min(#rows, row_offset + preview_rows) do
        widths[i] = math.min(max_width, math.max(widths[i], #M.value_text(rows[row_index], column)))
      end
    end
    local header, divider = "  │ ", "  ├─"
    for i, column in ipairs(visible) do
      header = header .. clip(name(column), widths[i]) .. (i == #visible and "" or " │ ")
      divider = divider .. string.rep("─", widths[i]) .. (i == #visible and "─" or "─┼─")
    end
    lines[#lines + 1] = chunks(header, "QuerybookHeader")
    lines[#lines + 1] = chunks(divider, "QuerybookDivider")
    local first = row_offset + 1
    local last = math.min(#rows, row_offset + preview_rows)
    local clipped = false
    for row_index = first, last do
      local row, row_text = rows[row_index], "  │ "
      for i, column in ipairs(visible) do
        local raw = M.value_text(row, column)
        if #raw > max_value_length then
          clipped = true
          raw = raw:sub(1, math.max(1, max_value_length - 1)) .. "…"
        end
        row_text = row_text .. clip(raw, widths[i]) .. (i == #visible and "" or " │ ")
      end
      lines[#lines + 1] = chunks(row_text, "QuerybookRow")
    end
    if #rows == 0 then lines[#lines + 1] = chunks("  │ (no rows)", "QuerybookMeta") end
    if clipped then lines[#lines + 1] = chunks("  │ values clipped to " .. max_value_length .. " characters · Inspect for exact values", "QuerybookMeta") end
    if #rows > 0 then
      lines[#lines + 1] = chunks("  │ " .. range_label(first, last, #rows) .. " · QuerybookNextPage/PrevPage", "QuerybookMeta")
    end
    if #columns > #visible then
      lines[#lines + 1] = chunks("  │ columns " .. (column_offset + 1) .. "-" .. (column_offset + #visible) .. " of " .. #columns .. " · QuerybookNextColumn/PrevColumn", "QuerybookMeta")
    end
  elseif result.status ~= "error" then
    lines[#lines + 1] = chunks("  │ (no columns returned)", "QuerybookMeta")
  end
  lines[#lines + 1] = chunks("  └──────────────────────────────────────────────", "QuerybookDivider")
  return lines
end

function M.setup_highlights()
  vim.api.nvim_set_hl(0, "QuerybookMeta", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "QuerybookHeader", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "QuerybookRow", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "QuerybookDivider", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "QuerybookError", { link = "DiagnosticError", default = true })
end

return M
