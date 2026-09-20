-- ============================================================================
-- Q06  COST BY ONE TAG VALUE, WITH UNTAGGED SPEND AS A FIRST-CLASS CATEGORY
-- ============================================================================
--
-- QUESTION
--   What does each value of one tag cost me - and how much of the bill
--   carries no value for that tag at all?
--
--   The second half is the part that matters. On most real accounts the
--   untagged bucket is the largest single row in the output. A tag report that
--   silently drops it is a lie about your cost allocation, so this query never
--   drops it.
--
-- COLUMN NAME - READ THIS BEFORE EDITING
--   Tag columns in the Athena CUR table are named
--       resource_tags_user_<tag_key_with_underscores>
--   lowercased, with separators in the tag key converted to underscores:
--
--       tag key "Team"        ->  resource_tags_user_team
--       tag key "cost-center" ->  resource_tags_user_cost_center
--       tag key "Environment" ->  resource_tags_user_environment
--
--   The exact spelling depends on how your table was created. The
--   resource_tags_user_* family is what the AWS console-generated CUR DDL and
--   the AWS Cloud Intelligence Dashboards CUR helper both use, and it is what
--   this pack uses. If your table differs, get the REAL name from your own
--   table rather than guessing - one line, no cost:
--
--       SHOW COLUMNS IN REPLACE_ME_DATABASE.REPLACE_ME_TABLE;
--
--   and look for the resource_tags_user_ prefix. A wrong column name in a
--   query that costs money to run is the worst possible outcome, which is why
--   this file tells you how to check instead of asserting.
--
-- WHAT IT RETURNS
--   One row per tag value, with:
--     team                 the tag value, or '(untagged)' for NULL/empty
--     amortized_cost       accrual-basis cost for that tag value
--     unblended_cost       cash-basis cost, for comparison
--     line_items           row count
--     share_of_period_pct  that value's fraction of the period
--   Ordered by amortized_cost descending, so the biggest row is either your
--   largest team or your untagged bucket - and on most accounts it is the
--   untagged bucket, which is the finding.
--
-- WHY COALESCE TO '(untagged)' RATHER THAN WHERE tag IS NOT NULL
--   Untagged and tagged-with-an-empty-string are both real states and both
--   need to appear. NULLIF(...,'') folds the empty string into '(untagged)'
--   so you do not get two rows that mean the same thing.
--
-- BYTES SCANNED
--   Same scale as Q01: every row in the selected partition, 3-4 columns. Tag
--   columns are STRING and are cheap per row in Parquet, but they are still
--   read for every row. Run this once per tag rather than adding five tags to
--   one query.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * Tag columns exist only if the report was configured to include them.
--     "Include resource IDs" is a SEPARATE switch from the tag keys you list:
--     a report can have resource IDs and zero tag columns. Verify with
--     SHOW COLUMNS before assuming.
--   * This query does not reference line_item_resource_id, so it works even
--     on a report without resource IDs - only the tag columns are required.
--
-- CAVEATS
--   * CUR records the tag value AT THE TIME THE CHARGE WAS RECORDED, not
--     today. Re-tagging a resource does not rewrite history, so two months of
--     this query can legitimately disagree with today's tags.
--   * Costs with no resource (data transfer, API requests, tax, RI/SP fees)
--     have no tags by construction and CANNOT be attributed by resource tags
--     at all. If you need those attributed, the supported route is cost
--     allocation tags plus cost categories, and the cost_category_* columns -
--     not a cleverer CASE expression.
--   * Tag values are case-sensitive: 'Prod' and 'prod' are two rows. Wrap in
--     LOWER() if you would rather they were not.
--   * Only activated cost allocation tags appear in CUR. A tag can exist on
--     every resource in the account and still be absent from the report
--     because it was never activated in Billing.
-- ============================================================================

SELECT
    COALESCE(NULLIF(resource_tags_user_team, ''), '(untagged)')  AS team,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                                   AS amortized_cost,
    ROUND(SUM(line_item_unblended_cost), 2)                       AS unblended_cost,
    COUNT(*)                                                      AS line_items,
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
    , 2)                                                          AS share_of_period_pct
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1
ORDER BY amortized_cost DESC
;
