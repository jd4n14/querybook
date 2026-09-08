local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
local parser = require("querybook.parser")
local runner = require("querybook.runner")
local risk = require("querybook.risk")
local render = require("querybook.render")
local function eq(a,b,msg) assert(vim.deep_equal(a,b),(msg or "values differ").."\nactual="..vim.inspect(a).."\nexpected="..vim.inspect(b)) end

local statements=parser.parse({"select 1 as one;","","select ';' as semi;"}); assert(#statements==2); assert(parser.statement_at(statements,1).text=="select 1 as one;")
local safe=risk.analyze("select * from t"); assert(not safe.dangerous); assert(risk.analyze("delete from t").dangerous)
local rendered=render.lines({status="success",rows={{ {kind="text",text="abcdefghijklmnopqrstuvwxyz"} }},columns={{name="value"}},connection_name="profile",database="db",duration_ms=1},{max_rows=1,max_columns=1,max_value_length=5,max_column_width=10})
assert(table.concat(vim.tbl_map(function(line)return line[1][1]end,rendered),"\n"):find("values clipped to 5",1,true))
local viewport=render.lines({status="success",rows={{{kind="text",text="one"}},{{kind="text",text="two"}},{{kind="text",text="three"}}},columns={{name="value"}},connection_name="p",database="/very/long/path/querybook.sqlite3"},{preview_rows=2,max_columns=1})
local viewport_text=table.concat(vim.tbl_map(function(line)return line[1][1]end,viewport),"\n")
assert(viewport_text:find("rows 1%-2 of 3")); assert(viewport_text:find("querybook.sqlite3")); assert(not viewport_text:find("three",1,true))
local shifted=render.lines({status="success",row_offset=2,rows={{{kind="text",text="one"}},{{kind="text",text="two"}},{{kind="text",text="three"}}},columns={{name="value"}},connection_name="p",database="db"},{preview_rows=2,max_columns=1})
assert(table.concat(vim.tbl_map(function(line)return line[1][1]end,shifted),"\n"):find("three",1,true))
local columns=render.lines({status="success",column_offset=2,rows={{{kind="text",text="a"},{kind="text",text="b"},{kind="text",text="c"}}},columns={{name="a"},{name="b"},{name="c"}},connection_name="p",database="db"},{preview_rows=1,max_columns=1})
local columns_text=table.concat(vim.tbl_map(function(line)return line[1][1]end,columns),"\n")
assert(columns_text:find("  │ c",1,true)); assert(not columns_text:find("  │ a",1,true))

local db=vim.fn.tempname()..".sqlite3"
local querybook=require("querybook"); querybook.setup({runner_path=root.."/bin/querybook-runner",connections={sqlite={driver="sqlite",path=db}},active_connection="sqlite",timeout_ms=5000})
vim.cmd("enew"); vim.api.nvim_buf_set_lines(0,0,-1,false,{"CREATE TABLE sample(id INTEGER, name TEXT, data BLOB);","","SELECT 1 AS dup, 2 AS dup, id, name, data FROM sample;"})
vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({force=true})
local ns=vim.api.nvim_create_namespace("querybook")
local function texts()
  local out={}; for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(0,ns,0,-1,{details=true})) do for _,line in ipairs(mark[4].virt_lines or {}) do out[#out+1]=line[1][1] end end; return table.concat(out,"\n")
end
local function done() return not texts():find("RUNNING",1,true) end
assert(vim.wait(5000,done),"DDL completion")
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
