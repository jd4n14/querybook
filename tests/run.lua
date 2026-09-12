local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local parser = require("querybook.parser")
local runner = require("querybook.runner")
local risk = require("querybook.risk")
local render = require("querybook.render")
local function eq(a,b,msg) assert(vim.deep_equal(a,b),(msg or "values differ").."\nactual="..vim.inspect(a).."\nexpected="..vim.inspect(b)) end

local statements=parser.parse({"select 1 as one;","","select ';' as semi;"}); assert(#statements==2); assert(parser.statement_at(statements,1).text=="select 1 as one;")
local safe=risk.analyze("select * from t"); assert(not safe.dangerous); assert(risk.analyze("delete from t").dangerous)
local function texts_of(lines) return vim.tbl_map(function(line) return line[1][1] end, lines) end
local function assert_width(lines, width, msg)
  for _, line in ipairs(lines) do
    assert(vim.fn.strdisplaywidth(line)==width, (msg or "box width").." actual="..vim.fn.strdisplaywidth(line).." expected="..width.." line="..line)
  end
end
local narrow=render.lines({status="success",rows={{ {kind="text",text="abcdefghijklmnopqrstuvwxyz"} }},columns={{name="value"}},connection_name="profile",database="db",duration_ms=1},{max_rows=1,max_columns=1,display_width=24})
local narrow_lines=texts_of(narrow)
local narrow_text=table.concat(narrow_lines,"\n")
assert_width(narrow_lines, 24, "narrow table fills the window")
assert(narrow_text:find("…",1,true), "long values clip to the window with an ellipsis")
assert(not narrow_text:find("abcdefghijklmnopqrstuvwxyz",1,true), "clipped values must not keep the full cell")
assert(not narrow_text:find("values clipped",1,true), "clip notice must not appear in the result box")
local wide=render.lines({status="success",rows={{{kind="text",text="1"},{kind="text",text=string.rep("x",120)}}},columns={{name="id"},{name="data"}},connection_name="p",database="db",duration_ms=1},{preview_rows=1,max_columns=12,display_width=80,max_column_width=10,max_value_length=20})
local wide_lines=texts_of(wide)
assert_width(wide_lines, 80, "wide table fills the requested window")
local wide_row
for _, line in ipairs(wide_lines) do if line:find("xxx",1,true) then wide_row=line end end
assert(wide_row, "wide table must show the long last column")
local shown=wide_row:match("x+")
assert(shown and #shown > 32, "last column must use leftover window space instead of the 32-cell cap")
assert(wide_row:find("…",1,true), "a value longer than the window still clips")
local viewport=render.lines({status="success",rows={{{kind="text",text="one"}},{{kind="text",text="two"}},{{kind="text",text="three"}}},columns={{name="value"}},connection_name="p",database="/very/long/path/querybook.sqlite3"},{preview_rows=2,max_columns=1,display_width=100})
local viewport_text=table.concat(vim.tbl_map(function(line)return line[1][1]end,viewport),"\n")
assert(viewport_text:find("rows 1%-2 of 3")); assert(viewport_text:find("querybook.sqlite3")); assert(not viewport_text:find("three",1,true))
local shifted=render.lines({status="success",row_offset=2,rows={{{kind="text",text="one"}},{{kind="text",text="two"}},{{kind="text",text="three"}}},columns={{name="value"}},connection_name="p",database="db"},{preview_rows=2,max_columns=1})
assert(table.concat(vim.tbl_map(function(line)return line[1][1]end,shifted),"\n"):find("three",1,true))
local columns=render.lines({status="success",column_offset=2,rows={{{kind="text",text="a"},{kind="text",text="b"},{kind="text",text="c"}}},columns={{name="a"},{name="b"},{name="c"}},connection_name="p",database="db"},{preview_rows=1,max_columns=1})
local columns_text=table.concat(vim.tbl_map(function(line)return line[1][1]end,columns),"\n")
assert(columns_text:find("  │ c",1,true)); assert(not columns_text:find("  │ a",1,true))

local boxed=render.lines({status="success",rows={{{kind="text",text="1"},{kind="text",text="alpha"}}},columns={{name="id"},{name="name"}},connection_name="p",database="db",duration_ms=4},{preview_rows=10,max_columns=12,display_width=72})
local boxed_lines=texts_of(boxed)
local boxed_text=table.concat(boxed_lines,"\n")
assert_width(boxed_lines, 72, "result box fills display_width")
assert(boxed_lines[1]:find("┐",1,true), "status line must close the top-right corner")
assert(boxed_text:find("┤",1,true), "header divider must close with ┤")
assert(boxed_lines[#boxed_lines]:find("┘",1,true), "bottom line must close the bottom-right corner")
local header, divider, row
for _, line in ipairs(boxed_lines) do
  if not header and line:find("id",1,true) and line:find("name",1,true) then header=line
  elseif line:find("┼",1,true) then divider=line
  elseif line:find("alpha",1,true) then row=line
  end
end
assert(header and header:sub(-#"│") == "│", "header must have a right vertical border")
assert(row and row:sub(-#"│") == "│", "data row must have a right vertical border")
assert(divider and divider:sub(-#"┤") == "┤", "divider must end with ┤")
local box_width=vim.fn.strdisplaywidth(header)
assert(vim.fn.strdisplaywidth(boxed_lines[1])==box_width, "status width must match the table")
assert(vim.fn.strdisplaywidth(divider)==box_width, "divider width must match the header")
assert(vim.fn.strdisplaywidth(row)==box_width, "row width must match the header")
assert(vim.fn.strdisplaywidth(boxed_lines[#boxed_lines])==box_width, "bottom width must match the table")
for _, line in ipairs(boxed_lines) do
  assert(vim.fn.strdisplaywidth(line)==box_width, "every box line must share a right edge")
end

local db=vim.fn.tempname()..".sqlite3"
local querybook=require("querybook"); querybook.setup({runner_path=root.."/bin/querybook-runner",connection_store_path=vim.fn.tempname()..".connections.sqlite",connections={sqlite={driver="sqlite",path=db}},active_connection="sqlite",timeout_ms=5000})
vim.cmd("enew"); vim.api.nvim_buf_set_lines(0,0,-1,false,{"CREATE TABLE sample(id INTEGER, name TEXT, data BLOB);","","SELECT 1 AS dup, 2 AS dup, id, name, data FROM sample;"})
vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({force=true})
local ns=vim.api.nvim_create_namespace("querybook")
local function texts()
  local out={}; for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{details=true})) do for _,line in ipairs(mark[4].virt_lines or {}) do out[#out+1]=line[1][1] end end; return table.concat(out,"\n")
end
local function done() return not texts():find("RUNNING",1,true) end
local function complete() return require("querybook.connections").active() ~= nil and done() end
assert(vim.wait(5000,complete),"DDL completion")
vim.api.nvim_buf_set_lines(0,0,1,false,{"INSERT INTO sample VALUES (1, 'alpha', x'0001ff');"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({force=true}); assert(vim.wait(5000,done),"first insert")
vim.api.nvim_buf_set_lines(0,0,1,false,{"INSERT INTO sample VALUES (2, 'NULL', x'');"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({force=true}); assert(vim.wait(5000,done),"second insert")
vim.api.nvim_buf_set_lines(0,0,-1,false,{"-- setup complete","","SELECT 1 AS dup, 2 AS dup, id, name, data FROM sample;"})
vim.api.nvim_win_set_cursor(0,{3,0}); querybook.run({}); local got=vim.wait(5000,function()return done() and texts():find("2 retained rows",1,true)~=nil end); assert(got,"SQLite result")
assert(#vim.api.nvim_buf_get_lines(0,0,-1,false)==3,"virtual lines must not alter SQL")
querybook.inspect(); local inspect_lines=vim.api.nvim_buf_get_lines(0,0,-1,false); local saw_select=false; for _,line in ipairs(inspect_lines) do if line:find("SELECT",1,true) or line:find("select",1,true) then saw_select=true end end; assert(saw_select,"inspect follows current statement"); vim.cmd("close")

-- A failed refresh keeps the prior result visible; a changed write is blocked.
vim.api.nvim_buf_set_lines(0,2,3,false,{"DELETE FROM sample;"}); vim.api.nvim_win_set_cursor(0,{3,0}); querybook.refresh(); vim.wait(300); assert(texts():find("2 retained rows",1,true),"refresh blocks write")
querybook.run({force=true}); assert(vim.wait(5000,function() return texts():find("0 retained rows",1,true)~=nil end),"forced DML")

-- Repeated failures reuse one logical slot; a later success clears the error.
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT missing_querybook_function(1);"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,function() return done() and texts():find("ERROR",1,true) ~= nil end),"first error")
querybook.run({}); assert(vim.wait(5000,function() return done() and texts():find("ERROR",1,true) ~= nil end),"second error")
local _, errors = texts():gsub("ERROR", ""); assert(errors == 1, "retries must keep one error block")
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT 7 AS recovered;"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,function() return done() and texts():find("1 retained rows",1,true) ~= nil end),"recovery")
assert(not texts():find("ERROR",1,true), "success replaces prior error")

-- Removing one of several notebook statements also removes its orphaned slot.
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT 1 AS first;","","SELECT 2 AS second;"})
vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,done),"first notebook slot")
vim.api.nvim_win_set_cursor(0,{3,0}); querybook.run({}); assert(vim.wait(5000,done),"second notebook slot")
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT 3 AS remaining;"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,done),"remaining notebook slot")
assert(#vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{}) == 1, "removed statements must not leave orphaned results")
-- Clearing and replacing an in-flight anchor cancels its handle; late events
-- cannot restore the removed result. Buffer wipe also drops pending state.
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT randomblob(50000000);"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); querybook.clear(true); assert(#vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{})==0,"clear cancels pending result")
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT 42 AS current;"}); vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,function() return done() and texts():find("1 retained rows",1,true)~=nil end),"runner restarts after clear")
vim.cmd("bwipeout!")
print("querybook tests passed"); vim.cmd("qa!")
