local M = {}

local function split_lines(text)
  local out = {}
  text = text or ""
  text = text:gsub("\r?\n$", "")
  if text == "" then return out end
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    out[#out + 1] = line
  end
  return out
end

local function split_tabs(line)
  local fields = {}
  local start = 1
  while true do
    local tab = line:find("\t", start, true)
    if not tab then
      fields[#fields + 1] = line:sub(start)
      return fields
    end
    fields[#fields + 1] = line:sub(start, tab - 1)
    start = tab + 1
  end
end

local function xml_unescape(value)
  return (value:gsub("&#x([0-9A-Fa-f]+);", function(hex)
    local codepoint = tonumber(hex, 16)
    if not codepoint or codepoint < 0 or codepoint > 0x10ffff then return "" end
    if codepoint < 0x80 then return string.char(codepoint) end
    if codepoint < 0x800 then
      return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    end
    if codepoint < 0x10000 then
      return string.char(0xe0 + math.floor(codepoint / 0x1000), 0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return string.char(0xf0 + math.floor(codepoint / 0x40000), 0x80 + math.floor(codepoint / 0x1000) % 0x40, 0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
  end):gsub("&#([0-9]+);", function(decimal)
    local codepoint = tonumber(decimal)
    if not codepoint or codepoint < 0 or codepoint > 0x10ffff then return "" end
    if codepoint < 0x80 then return string.char(codepoint) end
    if codepoint < 0x800 then
      return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
    end
    if codepoint < 0x10000 then
      return string.char(0xe0 + math.floor(codepoint / 0x1000), 0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
    end
    return string.char(0xf0 + math.floor(codepoint / 0x40000), 0x80 + math.floor(codepoint / 0x1000) % 0x40, 0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
  end):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function add_xml_field(columns, row, name, attrs, value)
  name = xml_unescape(name)
  if not vim.tbl_contains(columns, name) then columns[#columns + 1] = name end
  if attrs:match("xsi:nil%s*=%s*['\"]true['\"]") then
    row._null = row._null or {}
    row._null[name] = true
  else
    row[name] = xml_unescape(value or "")
  end
end

---Parse the MySQL client's XML batch format. XML avoids the ambiguity and
---escaping hazards of tab-delimited --raw output while retaining all scalar
---values as strings (so decimals and large integers never pass through Lua
---number conversion). SQL NULL is represented by row._null[column] = true;
---an empty string remains row[column] == "" and a literal "NULL" remains a
---normal string.
function M.parse_xml(stdout)
  local resultsets = {}
  for resultset_body in (stdout or ""):gmatch("<resultset[^>]*>([%s%S]-)</resultset>") do
    local columns, rows = {}, {}
    for row_body in resultset_body:gmatch("<row>([%s%S]-)</row>") do
      local row, position = {}, 1
      while true do
        local field_start = row_body:find("<field%s", position)
        if not field_start then break end
        local tag_end = row_body:find(">", field_start, true)
        if not tag_end then break end
        local tag = row_body:sub(field_start, tag_end)
        local name = tag:match('name%s*=%s*["\'](.-)["\']')
        if name then
          if tag:match("/%s*>$") then
            add_xml_field(columns, row, name, tag, "")
            position = tag_end + 1
          else
            local close_start, close_end = row_body:find("</field>", tag_end + 1, true)
            if not close_start then break end
            add_xml_field(columns, row, name, tag, row_body:sub(tag_end + 1, close_start - 1))
            position = close_end + 1
          end
        else
          position = tag_end + 1
        end
      end
      rows[#rows + 1] = row
    end
    resultsets[#resultsets + 1] = { columns = columns, rows = rows, format = "mysql-xml" }
  end
  local first = resultsets[1] or { columns = {}, rows = {}, format = "mysql-xml" }
  first.resultsets = resultsets
  return first
end

function M.parse_output(stdout)
  local lines = split_lines(stdout)
  if #lines == 0 then return { columns = {}, rows = {} } end
  local columns = split_tabs(lines[1])
  local rows = {}
  for i = 2, #lines do
    local fields = split_tabs(lines[i])
    local row = {}
    for col, name in ipairs(columns) do row[name] = fields[col] or "" end
    rows[#rows + 1] = row
  end
  return { columns = columns, rows = rows }
end

local function sqlite_args(connection, sql)
  return { "sqlite3", "-header", "-tabs", "-nullvalue", "<NULL>", connection.path, sql }
end

local function mysql_args(connection, sql)
  -- XML is escaped by the client and carries an explicit xsi:nil marker.
  -- Keep values textual to preserve exact decimal and integer spellings.
  local args = { "mysql", "--batch", "--xml", "--skip-binary-as-hex", "--default-character-set=" .. tostring(connection.charset or "utf8mb4") }
  if connection.host then args[#args + 1] = "--host=" .. tostring(connection.host) end
  if connection.port then args[#args + 1] = "--port=" .. tostring(connection.port) end
  if connection.socket then args[#args + 1] = "--socket=" .. connection.socket end
  if connection.user then args[#args + 1] = "--user=" .. connection.user end
  if connection.database then args[#args + 1] = connection.database end
  args[#args + 1] = "--execute=" .. sql
  return args
end

function M.command(connection, sql)
  if connection.driver == "sqlite" then return sqlite_args(connection, sql) end
  if connection.driver == "mysql" then return mysql_args(connection, sql) end
  return nil, "unknown Querybook driver: " .. tostring(connection.driver)
end

function M.run(connection, sql, callback)
  local command, command_error = M.command(connection, sql)
  if not command then return callback(nil, command_error) end
  if vim.system == nil then return callback(nil, "Querybook requires Neovim 0.10 or newer") end
  local opts = { text = true }
  if connection.driver == "mysql" and connection.password then
    opts.env = vim.tbl_extend("force", vim.fn.environ(), { MYSQL_PWD = connection.password })
  end
  vim.system(command, opts, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        callback(nil, (obj.stderr or obj.stdout or "query failed"):gsub("%s+$", ""), obj)
        return
      end
      local result = connection.driver == "mysql" and M.parse_xml(obj.stdout or "") or M.parse_output(obj.stdout or "")
      result.exit_code, result.stderr = obj.code, obj.stderr
      callback(result, nil, obj)
    end)
  end)
end

return M
