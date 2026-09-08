local M = {}

local function first_keyword(sql)
  local stripped = sql
  while true do
    stripped = stripped:gsub("^%s+", "")
    if stripped:sub(1, 2) == "--" then
      stripped = stripped:match("^%-%-[^\n]*\n(.*)$") or ""
    elseif stripped:sub(1, 1) == "#" then
      stripped = stripped:match("^#[^\n]*\n(.*)$") or ""
    elseif stripped:sub(1, 2) == "/*" then
      stripped = stripped:match("^/%*.-%*/(.*)$") or ""
    else
      break
    end
  end
  local keyword = stripped:match("^(%a+)")
  return keyword and keyword:lower() or ""
end

function M.analyze(sql)
  local keyword = first_keyword(sql)
  local upper = sql:upper()
  local reasons = {}
  if keyword == "update" and not upper:match("%f[%a]WHERE%f[%A]") then
    reasons[#reasons + 1] = "UPDATE without WHERE"
  elseif keyword == "delete" and not upper:match("%f[%a]WHERE%f[%A]") then
    reasons[#reasons + 1] = "DELETE without WHERE"
  elseif keyword == "drop" or keyword == "truncate" then
    reasons[#reasons + 1] = keyword .. " changes database structure or contents"
  elseif keyword == "insert" or keyword == "update" or keyword == "delete"
      or keyword == "alter" or keyword == "create" or keyword == "replace" then
    reasons[#reasons + 1] = keyword:upper() .. " writes to the database"
  end
  return { keyword = keyword, dangerous = #reasons > 0, reasons = reasons }
end

return M
