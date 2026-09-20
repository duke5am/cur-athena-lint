-- ============================================================================
-- Q15  RECONCILE AGAINST A KNOWN FIGURE (Cost Explorer or the invoice)
-- ============================================================================
--
-- QUESTION
--   Does this table, and the cost expression I am using, actually reproduce a
--   number I already trust?
--
-- WHY THIS IS THE FIRST QUERY YOU SHOULD RUN
--   Every other query in this pack is only as trustworthy as the column
--   choice underneath it. Cost Explorer gives you a monthly figure you can
--   read off a screen and compare against. If Athena does not land close to
--   it, the cause is almost always one of:
--     - the wrong cost column (unblended vs amortized - see Q01's header),
--     - a partition that was never loaded, so a month of data is missing,
--     - Savings Plan covered usage double-counted against its negation,
--     - a table created over a different report configuration than you think.
--   Running this first turns all four into a five-minute check.
--
-- WHAT IT RETURNS
--   One row per calendar month, with several subtotals computed different
--   ways so you can pick the one that matches what you are comparing to:
--     unblended_all_types    everything, cash basis (closest to Cost
--                            Explorer's "Unblended cost")
--     amortized_all_types    everything, accrual basis (closest to Cost
--                            Explorer's "Amortized cost", with caveats below)
--     amortized_usage_only   amortized, excluding Tax/Credit/Refund/Discount
--     gross_usage_only       Usage + DiscountedUsage + SavingsPlan* + Fee +
--                            RIFee, cash basis, no tax/credit/refund
--     line_items, distinct_products, distinct_accounts
--
-- BYTES SCANNED
--   *** THE WIDEST QUERY IN THE PACK. *** It spans every month you list and
--   reads 5 columns across all of them. Run it ONCE per period while
--   validating, then stop. Do not put it on a dashboard. A 12-month
--   reconciliation over a large Organization is the most expensive single
--   query here.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * The month IN (...) list must contain EXACTLY the months you intend. A
--     typo here is a silent wider scan, and the year = 'REPLACE_ME_YYYY' predicate is
--     present specifically so the query cannot cross a year boundary by
--     accident. Extend it deliberately if you need to.
--
-- CAVEATS - WHY IT WILL NOT MATCH EXACTLY, AND THAT IS EXPECTED
--   * Cost Explorer applies its own processing and its own RI/SP handling.
--     AWS does not publish a guarantee that CUR and Cost Explorer totals are
--     identical, and they routinely are not.
--   * Timezone. Cost Explorer months follow your account's billing view; CUR
--     timestamps are UTC. Usage in the first and last hours of a month can
--     land in different months in the two tools.
--   * Late-arriving rows. AWS can update a report after it has been finalized
--     - for example when a credit or refund is applied for the previous
--     month. A reconciliation run today and the same run tomorrow can
--     legitimately differ.
--   * Blended vs unblended. At the payer level, blended cost is not the
--     invoice. Check which figure you are comparing against before concluding
--     the query is wrong.
--   * If you are comparing against the INVOICE rather than Cost Explorer,
--     remember it includes tax and may reflect private-pricing adjustments
--     that are not fully represented in every CUR column.
--
--   docs/VALIDATION.md has the full procedure: run ONE day, compare to a
--   figure you already know, then scale up. Do that before you trust anything
--   else in this pack.
-- ============================================================================

SELECT
    date_format(line_item_usage_start_date, '%Y-%m')                 AS usage_month,
    ROUND(SUM(line_item_unblended_cost), 2)                          AS unblended_all_types,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                                      AS amortized_all_types,
    ROUND(SUM(CASE WHEN line_item_line_item_type NOT IN ('Tax',
                                                         'Credit',
                                                         'Refund',
                                                         'Discount',
                                                         'BundledDiscount')
                   THEN COALESCE(line_item_unblended_cost, 0)
                      + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
                      + COALESCE(reservation_recurring_fee_for_usage, 0)
              END), 2)                                               AS amortized_usage_only,
    ROUND(SUM(CASE WHEN line_item_line_item_type IN ('Usage',
                                                     'DiscountedUsage',
                                                     'SavingsPlanCoveredUsage',
                                                     'SavingsPlanNegation',
                                                     'SavingsPlanRecurringFee',
                                                     'SavingsPlanUpfrontFee',
                                                     'RIFee',
                                                     'Fee')
                   THEN line_item_unblended_cost END), 2)            AS gross_usage_only,
    COUNT(*)                                                         AS line_items,
    COUNT(DISTINCT line_item_product_code)                           AS distinct_products,
    COUNT(DISTINCT line_item_usage_account_id)                       AS distinct_accounts
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month IN ('REPLACE_ME_MONTH', 'REPLACE_ME_MONTH', 'REPLACE_ME_MONTH')   -- exactly the months you are checking
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1
ORDER BY usage_month
;
