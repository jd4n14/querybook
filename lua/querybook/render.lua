local M = {}

local function clip(value, width)
  value = tostring(value == nil and "NULL" or value):gsub("\n", "\\n"):gsub("\r", "\\r")
  if #value > width then return value:sub(1, width - 1) .. "…" end
  return value .. string.rep(" ", width - #value)
end

local function chunks(text, hl) return { { text, hl } } end

function M.lines(result, config)
  local lines = {}
  local max_rows = config.max_rows or 50
  local max_width = config.max_column_width or 32
  local status = result.status == "error" and "ERROR: " .. result.error
    or (result.status == "stale" and "STALE · SQL changed; run again" or
      string.format("%d rows · %d columns · %d ms · %s", #result.rows, #result.columns,
        result.duration_ms or 0, result.connection_name or "connection"))
  lines[#lines + 1] = chunks("  ┌ " .. status, result.status == "error" and "QuerybookError" or "QuerybookMeta")
  if #result.columns > 0 then
    local widths = {}
    for i, column in ipairs(result.columns) do
      widths[i] = math.min(max_width, math.max(#tostring(column), 3))
      for _, row in ipairs(result.rows) do widths[i] = math.min(max_width, math.max(widths[i], #tostring(row[column] or "NULL"))) end
    end
    local header, divider = "  │ ", "  ├─"
    for i, column in ipairs(result.columns) do
      header = header .. clip(column, widths[i]) .. (i == #result.columns and "" or " │ ")
      divider = divider .. string.rep("─", widths[i]) .. (i == #result.columns and "─" or "─┼─")
    end
    lines[#lines + 1] = chunks(header, "QuerybookHeader")
    lines[#lines + 1] = chunks(divider, "QuerybookDivider")
    for row_index, row in ipairs(result.rows) do
      if row_index > max_rows then
        lines[#lines + 1] = chunks("  │ … " .. (#result.rows - max_rows) .. " more rows (inspect for full values)", "QuerybookMeta")
        break
      end
      local row_text = "  │ "
      for i, column in ipairs(result.columns) do row_text = row_text .. clip(row[column], widths[i]) .. (i == #result.columns and "" or " │ ") end
      lines[#lines + 1] = chunks(row_text, "QuerybookRow")
    end
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
