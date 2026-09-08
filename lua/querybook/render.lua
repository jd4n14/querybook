local M = {}

function M.value(row, column)
  if row and row._null and row._null[column] then return nil, true end
  return row and row[column] or "", false
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

function M.lines(result, config)
  local lines = {}
  local max_rows = config.max_visible_rows or config.max_rows or 50
  local max_columns = config.max_visible_columns or config.max_columns or 12
  local max_value_length = config.max_visible_value_length or config.max_value_length or 128
  local max_width = config.max_column_width or 32
  local visible_columns = {}
  for i, column in ipairs(result.columns or {}) do
    if i > max_columns then break end
    visible_columns[#visible_columns + 1] = column
  end
  local value_truncated = false
  local status = result.status == "error" and "ERROR: " .. result.error .. " · " .. (result.connection_name or "connection") .. (result.database and (" / " .. result.database) or "")
    or (result.status == "stale" and "STALE · SQL changed; run again" or
      string.format("%d rows · %d columns · %d ms · %s%s", #(result.rows or {}), #(result.columns or {}),
        result.duration_ms or 0, result.connection_name or "connection",
        result.database and (" / " .. result.database) or ""))
  lines[#lines + 1] = chunks("  ┌ " .. status, result.status == "error" and "QuerybookError" or "QuerybookMeta")
  if result.collapsed then
    lines[#lines + 1] = chunks("  │ [collapsed] QuerybookToggle to expand · QuerybookInspect for full result", "QuerybookMeta")
  elseif #visible_columns > 0 then
    local widths = {}
    for i, column in ipairs(visible_columns) do
      widths[i] = math.min(max_width, math.max(#tostring(column), 3))
      for _, row in ipairs(result.rows or {}) do widths[i] = math.min(max_width, math.max(widths[i], #M.value_text(row, column))) end
    end
    local header, divider = "  │ ", "  ├─"
    for i, column in ipairs(visible_columns) do
      header = header .. clip(column, widths[i]) .. (i == #visible_columns and "" or " │ ")
      divider = divider .. string.rep("─", widths[i]) .. (i == #visible_columns and "─" or "─┼─")
    end
    lines[#lines + 1] = chunks(header, "QuerybookHeader")
    lines[#lines + 1] = chunks(divider, "QuerybookDivider")
    for row_index, row in ipairs(result.rows) do
      if row_index > max_rows then
        lines[#lines + 1] = chunks("  │ … " .. (#result.rows - max_rows) .. " more rows hidden (inspect for full values)", "QuerybookMeta")
        break
      end
      local row_text = "  │ "
      for i, column in ipairs(visible_columns) do
        local raw = M.value_text(row, column)
        if #raw > max_value_length then value_truncated = true end
        row_text = row_text .. clip(#raw > max_value_length and raw:sub(1, max_value_length - 1) .. "…" or raw, widths[i]) .. (i == #visible_columns and "" or " │ ")
      end
      lines[#lines + 1] = chunks(row_text, "QuerybookRow")
    end
    if #result.rows > max_rows then
      -- The row loop already emits the explicit row truncation marker.
    end
    if #result.columns > #visible_columns then
      lines[#lines + 1] = chunks("  │ … " .. (#result.columns - #visible_columns) .. " more columns hidden (inspect for full values)", "QuerybookMeta")
    end
    if value_truncated then
      lines[#lines + 1] = chunks("  │ … values clipped to " .. max_value_length .. " characters (inspect for full values)", "QuerybookMeta")
    end
  elseif #result.columns == 0 and result.status ~= "error" then
    lines[#lines + 1] = chunks("  │ (no columns returned)", "QuerybookMeta")
  end
  lines[#lines + 1] = chunks("  └────────────────────────────────────────────────────────", "QuerybookDivider")
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
