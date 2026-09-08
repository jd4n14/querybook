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
  local args = { "mysql", "--batch", "--raw", "--column-names" }
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
      local result = M.parse_output(obj.stdout or "")
      result.exit_code, result.stderr = obj.code, obj.stderr
      callback(result, nil, obj)
    end)
  end)
end

return M
