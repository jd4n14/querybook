-- Run both statements with :QuerybookRun while the cursor is in each one.
-- Inspect the order payload, then return to the second result: each is kept.
select 1001 as order_id,
  '{"customer":"Ana","items":[{"sku":"SKU-9","qty":2}]}' as order_payload;

select 'warehouse.default' as setting,
  '{"pick_wave":"morning","cutoff":"18:30","enabled":true}' as configuration;
