-- Run both statements with :QuerybookRun while the cursor is in each one.
-- Their virtual result tables remain attached below their statements.
select 1 as id, 'notebook' as state;

select 'Run :QuerybookInspect on this statement for a copyable view' as note;
