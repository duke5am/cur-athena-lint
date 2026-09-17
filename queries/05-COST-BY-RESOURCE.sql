-- ============================================================================
-- Q05  COST BY RESOURCE ID - AND THE HONEST BUCKET FOR SPEND WITH NO RESOURCE
-- ============================================================================
--
-- QUESTION
--   Which individual resources cost the most - and how much of my bill
--   cannot be attributed to a resource at all?
--
-- WHAT IT RETURNS
--   One row per resource id with account, service and amortized cost, PLUS a
--   literal '(no resource id)' bucket accounting for everything without one.
--   The second part is the point of this query.
--
-- WHY THE '(no resource id)' BUCKET IS NOT AN EDGE CASE
--   AWS documents line_item_resource_id as optional, and states plainly that
--   the field "is blank for usage types that aren't associated with an
--   instantiated host, such as data transfers and API requests, and line item
--   types such as discounts, credits, and taxes."
--
--   So on a real bill, a large share of spend legitimately has NO resource id:
--   S3 request charges, data transfer, Lambda invocations, taxes, credits, and
--   every RI and Savings Plan fee. People build a "top resources" report, see
--   that it does not add up to the invoice, and conclude the report is broken.
--   It is not. Filtering those rows out of the output would repeat that
--   mistake, so this query surfaces them as an explicit bucket instead.
--
--   If this bucket is bigger than you expect, that is a finding: it is the
--   ceiling on how much of your bill resource-level attribution can ever
--   explain. Resource tags cannot fix it either - see Q06.
--
-- BYTES SCANNED
--   *** EXPENSIVE. *** This groups at the highest-cardinality grain in CUR.
--   line_item_resource_id has roughly one distinct value per live resource,
--   so the shuffle is large even when Parquet keeps the raw scan small. On a
--   large Organization this is the query most likely to hit an Athena memory
--   or shuffle limit. Run it for ONE month. For a year, run it per month and
--   union the outputs, or CTAS a monthly resource rollup once.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * REQUIRES line_item_resource_id to exist - i.e. the report was created
--     with "Include resource IDs" enabled. Without it the column does not
--     exist and this query fails to run at all. That is the correct, loud
--     failure. Check with DESCRIBE before assuming.
--   * line_item_usage_account_id is in the GROUP BY on purpose: resource ids
--     are not guaranteed unique across accounts.
--
-- CAVEATS
--   * Some services use ARNs as the resource id, some a bare id, and a few
--     reuse the same value across regions. The account dimension is what
--     makes this grouping safe.
--   * Dedicated Host and some marketplace resources can carry the resource id
--     on the fee line rather than the usage line, so one resource's true cost
--     is split across two rows with the same id. This query sums them, which
--     is correct.
--   * A resource that existed for one hour still appears, so long lists are
--     normal. The LIMIT 200 is a display convenience; it does not reduce
--     bytes scanned.
--   * Do not sum this output and expect the invoice. The LIMIT cuts it, and
--     that is intentional - this is a "look at the head" query.
-- ============================================================================

SELECT
    COALESCE(line_item_usage_account_id, '(blank)')       AS usage_account_id,
    line_item_product_code                                AS service,
    COALESCE(line_item_resource_id, '(no resource id)')   AS resource_id,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                           AS amortized_cost,
    ROUND(SUM(line_item_usage_amount), 4)                 AS usage_amount,
    COUNT(*)                                              AS line_items,
    ROUND(
        100.0 * SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
        )
        / NULLIF(SUM(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
        )) OVER (), 0)
    , 2)                                                  AS share_of_period_pct
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2, 3
ORDER BY amortized_cost DESC
LIMIT 200
;
