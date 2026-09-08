local M = {}
local function name(column) return type(column) == "table" and column.name or tostring(column) end
function M.column_name(column) return name(column) end
function M.cell(row, index) return row and row[index] end
function M.value(row, column)
  local index = type(column) == "number" and column or type(column) == "table" and column._index
  if not index and type(column) == "string" and row then
    -- Compatibility for callers that still pass a label; positional results
    -- use numeric indexes so duplicate labels remain unambiguous.
    for i, cell in ipairs(row) do if cell.column == column then index = i; break end end
  end
  local cell = row and row[index]
  if not cell or cell.kind == "null" then return nil, true, cell end
  if cell.kind == "binary" then return cell.base64 or "", false, cell end
  return cell.text or "", false, cell
end
function M.value_text(row, column)
  local value, is_null = M.value(row, column); return is_null and "NULL" or tostring(value)
end
local function clip(value, width)
  value = tostring(value):gsub("\n", "\\n"):gsub("\r", "\\r")
  if width < 2 then return value:sub(1, width) end
  if #value > width then return value:sub(1, width - 1) .. "…" end
  return value .. string.rep(" ", width - #value)
end
local function chunks(text, hl) return { { text, hl } } end
function M.lines(result, config)
  config = config or {}; local lines = {}; local max_rows = config.max_rows or 50; local max_columns = config.max_columns or 12; local max_value_length = config.max_value_length or 128; local max_width = config.max_column_width or 32
  local visible = {}; for i, column in ipairs(result.columns or {}) do if i > max_columns then break end; local copy = type(column)=="table" and vim.deepcopy(column) or {name=tostring(column)}; copy._index=i; visible[#visible+1]=copy end
  local status = result.status == "error" and "ERROR: " .. tostring(result.error) .. " · " .. (result.connection_name or "connection") .. (result.database and (" / " .. result.database) or "") or result.status == "stale" and "STALE · SQL changed; run again" or result.status == "running" and "RUNNING · " .. (result.connection_name or "connection") or string.format("%d rows · %d columns · %d ms · %s%s%s", #(result.rows or {}), #(result.columns or {}), result.duration_ms or 0, result.connection_name or "connection", result.database and " / " or "", result.database or "")
  if result.truncated then status = status .. " · truncated (" .. tostring(result.truncation_reason or "limit") .. ")" end
  lines[#lines+1] = chunks("  ┌ " .. status, result.status=="error" and "QuerybookError" or "QuerybookMeta")
  if result.collapsed then lines[#lines+1]=chunks("  │ [collapsed] QuerybookToggle to expand · QuerybookInspect for full result","QuerybookMeta")
  elseif #visible > 0 then
    local widths={}; for i,column in ipairs(visible) do widths[i]=math.min(max_width,math.max(#name(column),3)); for _,row in ipairs(result.rows or {}) do widths[i]=math.min(max_width,math.max(widths[i],#M.value_text(row,column))) end end
    local header,divider="  │ ","  ├─"; for i,column in ipairs(visible) do header=header..clip(name(column),widths[i])..(i==#visible and "" or " │ "); divider=divider..string.rep("─",widths[i])..(i==#visible and "─" or "─┼─") end
    lines[#lines+1]=chunks(header,"QuerybookHeader"); lines[#lines+1]=chunks(divider,"QuerybookDivider")
    local clipped=false
    for row_index,row in ipairs(result.rows or {}) do if row_index > max_rows then lines[#lines+1]=chunks("  │ … " .. (#result.rows-max_rows) .. " more rows hidden (inspect for full values)","QuerybookMeta"); break end; local text="  │ "; for i,column in ipairs(visible) do local raw=M.value_text(row,column); if #raw>max_value_length then clipped=true; raw=raw:sub(1,max_value_length-1).."…" end; text=text..clip(raw,widths[i])..(i==#visible and "" or " │ ") end; lines[#lines+1]=chunks(text,"QuerybookRow") end
    if #result.columns>#visible then lines[#lines+1]=chunks("  │ … " .. (#result.columns-#visible) .. " more columns hidden (inspect for full values)","QuerybookMeta") end
    if clipped then lines[#lines+1]=chunks("  │ … values clipped to " .. max_value_length .. " characters (inspect for full values)","QuerybookMeta") end
  elseif result.status ~= "error" then lines[#lines+1]=chunks("  │ (no columns returned)","QuerybookMeta") end
  lines[#lines+1]=chunks("  └────────────────────────────────────────────────────────","QuerybookDivider"); return lines
end
function M.setup_highlights()
  vim.api.nvim_set_hl(0,"QuerybookMeta",{link="Comment",default=true}); vim.api.nvim_set_hl(0,"QuerybookHeader",{link="Identifier",default=true}); vim.api.nvim_set_hl(0,"QuerybookRow",{link="Normal",default=true}); vim.api.nvim_set_hl(0,"QuerybookDivider",{link="NonText",default=true}); vim.api.nvim_set_hl(0,"QuerybookError",{link="DiagnosticError",default=true})
end
return M
