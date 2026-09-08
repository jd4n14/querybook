local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local parser = require("querybook.parser")
local runner = require("querybook.runner")
local risk = require("querybook.risk")
local render = require("querybook.render")
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "values differ") .. "\nactual=" .. vim.inspect(actual) .. "\nexpected=" .. vim.inspect(expected))
end

local statements = parser.parse({ "select 1 as one;", "", "select ';' as semi;" })
assert(#statements == 2, "quoted semicolon must not split a statement")
assert(parser.statement_at(statements, 1).text == "select 1 as one;")
assert(parser.statement_at(statements, 3).text == "select ';' as semi;")
eq(runner.parse_output("id\tname\n1\talpha\n2\tbeta\n"), { columns = { "id", "name" }, rows = { { id = "1", name = "alpha" }, { id = "2", name = "beta" } } }, "tab output")
local xml_fixture = [[<?xml version="1.0"?>
<resultset statement="fixture" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><row>
<field name="sql_null" xsi:nil="true" /><field name="literal_null">NULL</field>
<field name="empty"></field><field name="special">a\tb\n\c &amp; &lt;ok&gt;</field>
<field name="unicode">café · 東京</field><field name="decimal">123456789012345678901234567890.12345678901234567890</field>
</row></resultset>]]
local xml_result = runner.parse_xml(xml_fixture)
eq(xml_result.columns, { "sql_null", "literal_null", "empty", "special", "unicode", "decimal" }, "MySQL XML columns")
assert(xml_result.rows[1]._null.sql_null == true, "XML SQL NULL marker")
assert(xml_result.rows[1].literal_null == "NULL", "XML literal NULL")
assert(xml_result.rows[1].empty == "", "XML empty string")
assert(xml_result.rows[1].special == "a\\tb\\n\\c & <ok>", "XML escaped scalar")
assert(xml_result.rows[1].decimal == "123456789012345678901234567890.12345678901234567890", "XML exact decimal")
local rendered = render.lines({ status = "success", rows = { { value = "abcdefghijklmnopqrstuvwxyz" } }, columns = { "value" }, connection_name = "profile", database = "db", duration_ms = 1 }, { max_rows = 1, max_columns = 1, max_value_length = 5, max_column_width = 10 })
local rendered_text = table.concat(vim.tbl_map(function(line) return line[1][1] end, rendered), "\n")
assert(rendered_text:find("values clipped to 5", 1, true), "inline value truncation is explicit")
local collapsed = render.lines({ status = "success", rows = { { value = "x" } }, columns = { "value" }, collapsed = true, connection_name = "profile", database = "db", duration_ms = 1 }, {})
assert(table.concat(vim.tbl_map(function(line) return line[1][1] end, collapsed), "\n"):find("collapsed", 1, true), "result collapse is per result")
if vim.env.QUERYBOOK_MYSQL_TEST == "1" then
  local mysql_result, mysql_error
  runner.run({ driver = "mysql", socket = vim.env.QUERYBOOK_MYSQL_SOCKET, host = vim.env.QUERYBOOK_MYSQL_HOST,
    port = vim.env.QUERYBOOK_MYSQL_PORT, user = vim.env.QUERYBOOK_MYSQL_USER or "root",
    database = vim.env.QUERYBOOK_MYSQL_DATABASE, password = vim.env.QUERYBOOK_MYSQL_PASSWORD }, [[
      SELECT NULL AS sql_null, 'NULL' AS literal_null, '' AS empty_value,
        CONCAT('a', CHAR(9), 'b', CHAR(10), CHAR(92), 'c') AS special,
        'café · 東京' AS unicode_value,
        '123456789012345678901234567890.12345678901234567890' AS exact_decimal,
        '9223372036854775807' AS exact_bigint
    ]], function(data, err) mysql_result, mysql_error = data, err end)
  assert(vim.wait(10000, function() return mysql_result ~= nil or mysql_error ~= nil end), "live MySQL fixture completed")
  assert(not mysql_error, mysql_error or "live MySQL fixture failed")
  local row = mysql_result.rows[1]
  assert(mysql_result.format == "mysql-xml", "live MySQL uses XML transport")
  assert(mysql_result.columns[#mysql_result.columns] == "exact_bigint", "live MySQL column order")
  assert(row._null.sql_null and row.literal_null == "NULL" and row.empty_value == "", "live MySQL null and empty values")
  assert(row.special == "a\tb\n\\c" and row.unicode_value == "café · 東京", "live MySQL special characters")
  assert(row.exact_decimal == "123456789012345678901234567890.12345678901234567890" and row.exact_bigint == "9223372036854775807", "live MySQL exact numerics")
end
assert(risk.analyze("delete from sample;").dangerous, "lowercase DELETE is guarded")
assert(risk.analyze("UPDATE sample SET name = 'x';").dangerous, "uppercase UPDATE without WHERE is guarded")
assert(risk.analyze("-- comment\ninsert into sample values (3, 'gamma');").dangerous, "commented INSERT is guarded")
assert(risk.analyze("select * from sample;").dangerous == false, "SELECT remains safe")

local db = vim.fn.tempname() .. ".sqlite3"
vim.system({ "sqlite3", db, "create table sample(id integer, name text); insert into sample values (1, 'alpha'), (2, 'beta');" }, { text = true }):wait()
local querybook = require("querybook")
querybook.setup({ connections = { sqlite = { driver = "sqlite", path = db } }, active_connection = "sqlite" })
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select * from sample;", "", "select count(*) as total from sample;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.run({})
local querybook_ns = vim.api.nvim_create_namespace("querybook")
local function has_text(text)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, querybook_ns, 0, -1, { details = true })) do
    for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(virtual_line) do if chunk[1]:find(text, 1, true) then return true end end
    end
  end
  return false
end
assert(vim.wait(3000, function() return has_text("2 rows") end), "first SQLite result")
vim.api.nvim_win_set_cursor(0, { 3, 0 })
querybook.run({})
assert(vim.wait(3000, function() return has_text("1 rows") end), "second SQLite result")
assert(#vim.api.nvim_buf_get_lines(0, 0, -1, false) == 3, "rendered results must not enter SQL buffer")
querybook.inspect()
local inspect_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(inspect_lines[1]:find("count(*)", 1, true), "inspect follows the current statement")
vim.cmd("close")

-- Updating one statement leaves the other statement's result attached.
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "select * from sample where id = 1;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.run({})
assert(vim.wait(3000, function() return #vim.api.nvim_buf_get_extmarks(0, querybook_ns, 0, -1, {}) == 2 end), "updated first result")
assert(#vim.api.nvim_buf_get_extmarks(0, querybook_ns, 0, -1, {}) == 2, "two independent results")

-- A failed execution keeps the prior successful result and adds an error.
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "select missing_column from sample;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.run({})
assert(vim.wait(3000, function() return has_text("ERROR:") end), "SQLite error result")
assert(#vim.api.nvim_buf_get_extmarks(0, querybook_ns, 0, -1, {}) == 3, "previous result retained on error")
assert(#vim.api.nvim_buf_get_lines(0, 0, -1, false) == 3, "SQL buffer remains clean after error")

-- Refresh follows the same write guard as Run; changing SQL cannot silently
-- turn a refresh into a destructive operation.
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "delete from sample;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.refresh()
vim.wait(300)
local count_after_block = vim.system({ "sqlite3", db, "select count(*) from sample;" }, { text = true }):wait()
assert((count_after_block.stdout or ""):match("2"), "refresh blocks an edited DELETE")
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "delete from sample where id = 2;" })
querybook.run({ force = true })
vim.wait(300)
local count_after_force = vim.system({ "sqlite3", db, "select count(*) from sample;" }, { text = true }):wait()
assert((count_after_force.stdout or ""):match("1"), "explicit force allows a write")

-- A visual selection containing two statements keeps separate result anchors.
querybook.clear(true)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 1 as first;", "", "select 2 as second;" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
querybook.run({ range = 1, line1 = 1, line2 = 3 })
assert(vim.wait(3000, function() return #vim.api.nvim_buf_get_extmarks(0, querybook_ns, 0, -1, {}) == 2 end), "multi-statement selection keeps two results")
print("querybook tests passed")
vim.cmd("qa!")
