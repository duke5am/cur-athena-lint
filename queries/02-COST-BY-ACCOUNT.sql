-- ============================================================================
-- Q02  COST BY ACCOUNT, WITH THE LINE-ITEM-TYPE SPLIT MADE VISIBLE
-- ============================================================================
--
-- QUESTION
--   Which linked account owns the spend - and of that spend, how much is real
--   consumption, how much is tax, and how much is a credit we received?
--
-- WHAT IT RETURNS
--   One row per usage account: a total, plus explicit columns for on-demand
--   usage, RI-discounted usage, Savings Plan covered usage and its negation,
--   RI fees, SP fees, other fees, tax, credits, refunds and discounts, then a
--   consumption_subtotal that excludes tax/credit/refund/discount.
--
--   This is the query that stops the classic reconciliation argument. Someone
--   adds "usage" to "credits" without noticing the sign, or drops Tax and
--   then cannot match the invoice.
--
-- WHY THE line_item_line_item_type SPLIT MATTERS (the whole point)
--   line_item_unblended_cost means something different on every line item
--   type. The AWS CUR data dictionary lists the possible values, including:
--     Usage                    on-demand-rate usage
--     DiscountedUsage          usage that received a Reserved Instance benefit
--     SavingsPlanCoveredUsage  on-demand cost covered by a Savings Plan
--     SavingsPlanNegation      the offset that cancels the covered usage
--     RIFee                    the monthly recurring fee for reservations
--     SavingsPlanRecurringFee  recurring hourly charges for a Savings Plan
--     SavingsPlanUpfrontFee    one-time upfront Savings Plan purchase fee
--     Fee, Tax, Credit, Refund, Discount, BundledDiscount
--
--   Consequences you can see directly in the columns below:
--     * SavingsPlanCoveredUsage is recorded at the on-demand list price and is
--       "offset by the corresponding Savings Plan negation items" (AWS CUR
--       data dictionary). Count covered usage WITHOUT the negation and you
--       DOUBLE the SP-covered spend. That is the single most common way to
--       produce a wrong CUR number.
--     * DiscountedUsage is near-zero by construction, so a report that
--       includes it and excludes RIFee shows RI-covered instances as free.
--     * Tax and Credit frequently have a NULL product code, so a naive
--       "cost by service" view silently absorbs them into a NULL row.
--
-- BYTES SCANNED
--   Same shape as Q01 - every row in the selected partitions, ~11 columns.
--   Keep it to one month unless you have a reason and a budget.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01 (verify with SHOW PARTITIONS).
--   * reservation_amortized_upfront_fee_for_billing_period and
--     reservation_recurring_fee_for_usage are used by the amortized_total
--     column. On a report without reservation columns, replace those two
--     COALESCE terms with 0.
--
-- CAVEATS
--   * For a member account inside an Organization, Credit and Refund rows are
--     often booked against the payer, not the member. A member-account report
--     showing zero credits is normal.
--   * NULL usage account ids exist - some fee and tax rows have none.
--     COALESCE keeps them visible as '(blank)' rather than dropping them
--     silently from a total.
--   * 'Discount' and 'BundledDiscount' are separate types from the EDP/private
--     pricing narrative: AWS documents the Discount type as one whose "name
--     may vary and require parsing based on the discount", pointing you at
--     line_item_line_item_description. Do not assume 'EdpDiscount' is a
--     line item type value - it is not in the documented list. See
--     docs/CUR-SCHEMA.md for the full and verified value list.
-- ============================================================================

SELECT
    COALESCE(line_item_usage_account_id, '(blank)')                  AS usage_account_id,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'Usage'
                   THEN line_item_unblended_cost END), 2)            AS usage_on_demand,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage'
                   THEN line_item_unblended_cost END), 2)            AS ri_discounted_usage,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
                   THEN line_item_unblended_cost END), 2)            AS sp_covered_usage,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanNegation'
                   THEN line_item_unblended_cost END), 2)            AS sp_negation,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'RIFee'
                   THEN line_item_unblended_cost END), 2)            AS ri_fee,
    ROUND(SUM(CASE WHEN line_item_line_item_type IN ('SavingsPlanRecurringFee',
                                                     'SavingsPlanUpfrontFee')
                   THEN line_item_unblended_cost END), 2)            AS sp_fee,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'Fee'
                   THEN line_item_unblended_cost END), 2)            AS other_fees,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'Tax'
                   THEN line_item_unblended_cost END), 2)            AS tax,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'Credit'
                   THEN line_item_unblended_cost END), 2)            AS credits,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'Refund'
                   THEN line_item_unblended_cost END), 2)            AS refunds,
    ROUND(SUM(CASE WHEN line_item_line_item_type IN ('Discount',
                                                     'BundledDiscount')
                   THEN line_item_unblended_cost END), 2)            AS discounts,
    ROUND(SUM(CASE WHEN line_item_line_item_type NOT IN ('Tax',
                                                         'Credit',
                                                         'Refund',
                                                         'Discount',
                                                         'BundledDiscount')
                   THEN line_item_unblended_cost END), 2)            AS consumption_subtotal,
    ROUND(SUM(line_item_unblended_cost), 2)                          AS unblended_total,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                                      AS amortized_total,
    COUNT(DISTINCT line_item_line_item_type)                         AS distinct_line_item_types
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1
ORDER BY amortized_total DESC
;
