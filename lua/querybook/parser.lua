local M = {}

local function is_space(ch)
  return ch == " " or ch == "\t" or ch == "\r" or ch == "\n"
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Split a SQL buffer into statements without treating semicolons in quoted
---strings or comments as statement separators. This is deliberately a small
---scanner; SQL syntax validation remains the database client's job.
function M.parse(lines)
  local statements = {}
  local chars = {}
  local start_line, start_col = nil, nil
  local quote, block_comment, line_comment = nil, false, false
  local function emit(end_line, end_col)
    local text = table.concat(chars)
    if trim(text) ~= "" then
      statements[#statements + 1] = {
        start_line = start_line,
        start_col = start_col,
        end_line = end_line,
        end_col = end_col,
        text = trim(text),
      }
    end
    chars = {}
    start_line, start_col = nil, nil
  end

  for line_no, line in ipairs(lines) do
    local col = 1
    while col <= #line do
      local ch, next_ch = line:sub(col, col), line:sub(col + 1, col + 1)
      -- Do not let whitespace after a completed statement become the start
      -- of the next one. This also makes coordinates correct after newlines.
      if not start_line and not is_space(ch) then
        start_line, start_col = line_no, col
      end
      if line_comment then
        if start_line then chars[#chars + 1] = ch end
      elseif block_comment then
        if start_line then chars[#chars + 1] = ch end
        if ch == "*" and next_ch == "/" then
          if start_line then chars[#chars + 1] = next_ch end
          col = col + 1
          block_comment = false
        end
      elseif quote then
        chars[#chars + 1] = ch
        if ch == quote then
          if next_ch == quote then
            chars[#chars + 1] = next_ch
            col = col + 1
          else
            quote = nil
          end
        elseif ch == "\\" and quote == "'" and col < #line then
          chars[#chars + 1] = next_ch
          col = col + 1
        end
      elseif ch == "'" or ch == '"' or ch == "`" then
        quote = ch
        chars[#chars + 1] = ch
      elseif ch == "-" and next_ch == "-" then
        line_comment = true
        chars[#chars + 1], chars[#chars + 2] = ch, next_ch
        col = col + 1
      elseif ch == "#" then
        line_comment = true
        chars[#chars + 1] = ch
      elseif ch == "/" and next_ch == "*" then
        block_comment = true
        chars[#chars + 1], chars[#chars + 2] = ch, next_ch
        col = col + 1
      elseif ch == ";" then
        chars[#chars + 1] = ch
        emit(line_no, col)
      else
        if start_line then chars[#chars + 1] = ch end
      end
      col = col + 1
    end
    if line_no < #lines then
      if start_line then chars[#chars + 1] = "\n" end
      line_comment = false
    end
  end
  if #chars > 0 and start_line then
    emit(#lines, #lines > 0 and #lines[#lines] or 0)
  end
  return statements
end

function M.statement_at(statements, line)
  for _, statement in ipairs(statements) do
    if line >= statement.start_line and line <= statement.end_line then
      return statement
    end
  end
  return nil
end

return M
