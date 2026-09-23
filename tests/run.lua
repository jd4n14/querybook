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

local filtered=render.lines({status="success",rows={{{kind="text",text="1"}},{{kind="text",text="2"}}},columns={{name="id"}},connection_name="p",database="db",duration_ms=4,view_active=true,view_source_rows={1},filter_expression="id == 2"},{preview_rows=10,max_columns=12,display_width=72})
local filtered_lines=texts_of(filtered)
local filtered_text=table.concat(filtered_lines,"\n")
assert_width(filtered_lines, 72, "filtered result box fills display_width")
assert(filtered_text:find("1 matching rows · 2 retained rows",1,true), "inline status shows matching vs retained")
assert(filtered_text:find("local filter: id == 2",1,true), "inline status shows the local CEL filter")
assert(filtered_text:find("│ 2",1,true), "inline page shows matching source rows")

local function joined(lines)
  return vim.tbl_map(function(line)
    local parts = {}
    for _, chunk in ipairs(line) do parts[#parts + 1] = chunk[1] end
    return table.concat(parts)
  end, lines)
end
local token = string.rep("ab", 100)
local pair = render.lines({status="success", rows={{ {kind="text", text=token}, {kind="text", text="42"} }}, columns={{name="token"}, {name="company_id"}}, connection_name="p", database="db", duration_ms=1}, {preview_rows=1, display_width=80})
local pair_text = table.concat(texts_of(pair), "\n")
assert(pair_text:find("company_id", 1, true), "company_id header stays visible beside a long token")
assert(pair_text:find("42", 1, true), "company_id value stays visible beside a long token")
assert(pair_text:find("…", 1, true), "long token still clips inside its cell")
assert(not pair_text:find(token, 1, true), "the full token stays out of the grid cell")
local cols, wide_row = {}, {}
for i = 1, 20 do
  cols[i] = { name = "c" .. i }
  wide_row[i] = { kind = "text", text = tostring(i) }
end
local many = render.lines({status="success", rows={wide_row}, columns=cols, connection_name="p", database="db"}, {preview_rows=1, display_width=200})
local many_text = table.concat(texts_of(many), "\n")
assert(many_text:find("c20", 1, true), "a wide window shows short columns past the old 12-column page")
local capped = render.lines({status="success", rows={wide_row}, columns=cols, connection_name="p", database="db"}, {preview_rows=1, display_width=200, max_columns=12})
local capped_text = table.concat(texts_of(capped), "\n")
assert(capped_text:find("columns 1-12 of 20", 1, true), "max_columns remains a ceiling")
assert(not capped_text:find("c13", 1, true), "max_columns stops the page at 12")
assert(not capped_text:find("QuerybookNextColumn", 1, true), "column footer names the visible span")
local named, named_row = {}, {}
for i = 1, 8 do
  named[i] = { name = "column_" .. i .. "_xxxx" }
  named_row[i] = { kind = "text", text = "v" }
end
local pinned = render.lines({status="success", column_offset=4, rows={named_row}, columns=named, connection_name="p", database="db"}, {preview_rows=1, display_width=80})
local pinned_text = table.concat(texts_of(pinned), "\n")
assert(pinned_text:find("column_1_xxxx", 1, true), "scrolled window keeps the first column")
assert(pinned_text:find("column_5_xxxx", 1, true), "scrolled window shows the offset column")
assert(not pinned_text:find("column_4_xxxx", 1, true), "pinned window skips the columns in the gap")
assert(pinned_text:find("columns 1, 5-7 of 8", 1, true), "footer shows the pinned column and the gap")
local page_result = { status = "success", rows = { named_row }, columns = named, column_offset = 0 }
local page_config = { preview_rows = 1, display_width = 80 }
local next_off = render.shift_column_offset(page_result, page_config, 1)
assert(next_off > 0, "column page advances to the first hidden column")
page_result.column_offset = next_off
assert(render.shift_column_offset(page_result, page_config, -1) == 0, "column page returns to the first screen")
page_result.column_offset = 0
local revealed = render.reveal_column(page_result, page_config, 5)
local revealed_columns = render.visible_columns({ status = "success", rows = { named_row }, columns = named, column_offset = revealed }, page_config)
local saw_five = false
for _, index in ipairs(revealed_columns) do if index == 5 then saw_five = true end end
assert(saw_five, "moving to a hidden column scrolls it into view")
assert(revealed_columns[1] == 1, "the scrolled cell keeps the first column pinned")
local active = render.lines({status="success", grid_active=true, grid_row=1, grid_col=2, rows={{ {kind="text", text=token}, {kind="text", text="42"} }}, columns={{name="token"}, {name="company_id"}}, connection_name="p", database="db"}, {preview_rows=1, display_width=80})
local active_lines = joined(active)
local active_text = table.concat(active_lines, "\n")
assert(active_text:find("row 1 · col 2/2 · company_id", 1, true), "grid footer names the active cell")
assert(active_text:find("▸ company_id · 42", 1, true), "grid detail shows the full active value")
local saw_cursor = false
for _, line in ipairs(active) do
  for _, chunk in ipairs(line) do
    if chunk[2] == "QuerybookCursor" and tostring(chunk[1]):find("company_id", 1, true) then saw_cursor = true end
  end
end
assert(saw_cursor, "active header uses QuerybookCursor")
for _, line in ipairs(active_lines) do
  assert(vim.fn.strdisplaywidth(line) == 80, "grid box keeps the window width")
end
local huge = string.rep("q", 500)
local detail = render.lines({status="success", grid_active=true, grid_row=1, grid_col=1, rows={{ {kind="text", text=huge}, {kind="null"} }}, columns={{name="token"}, {name="company_id"}}, connection_name="p", database="db"}, {preview_rows=1, display_width=80})
local detail_text = table.concat(joined(detail), "\n")
assert(detail_text:find("▸ token · " .. string.rep("q", 20), 1, true), "detail starts with the retained cell")
assert(not detail_text:find(huge, 1, true), "detail stops after three lines")
assert(detail_text:find("▸ company_id", 1, true) == nil, "detail follows the active column")
local null_cell = render.lines({status="success", grid_active=true, grid_row=1, grid_col=1, rows={{ {kind="null"}, {kind="text", text="7"} }}, columns={{name="company_id"}, {name="shop_id"}}, connection_name="p", database="db"}, {preview_rows=1, display_width=80})
local null_text = table.concat(joined(null_cell), "\n")
assert(null_text:find("▸ company_id · NULL", 1, true), "active NULL stays visible in the detail")

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
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT 1 AS id, 'alpha' AS name, 'beta' AS city;"})
vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,function() return done() and texts():find("1 retained rows",1,true)~=nil end),"grid fixture")
querybook.enter_grid()
assert(texts():find("row 1 · col 1/3 · id",1,true), "enter grid on the first cell")
querybook.grid_move("column", 1)
assert(texts():find("row 1 · col 2/3 · name",1,true), "l moves one column")
assert(texts():find("▸ name · alpha",1,true), "detail shows the active cell")
querybook.exit_grid()
assert(not texts():find("▸ name",1,true), "esc leaves the grid")
local saved_preview = querybook.config.preview_rows
querybook.config.preview_rows = 2
vim.api.nvim_buf_set_lines(0,0,-1,false,{"SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3;"})
vim.api.nvim_win_set_cursor(0,{1,0}); querybook.run({}); assert(vim.wait(5000,function() return done() and texts():find("3 retained rows",1,true)~=nil end),"row page fixture")
querybook.enter_grid()
querybook.grid_move("row", 1)
querybook.grid_move("row", 1)
assert(texts():find("rows 3-3 of 3",1,true), "j past the page advances the row viewport")
assert(texts():find("row 3 · col 1/1 · n",1,true), "grid row follows the new page")
querybook.exit_grid()
querybook.config.preview_rows = saved_preview
vim.cmd("bwipeout!")
print("querybook tests passed"); vim.cmd("qa!")
