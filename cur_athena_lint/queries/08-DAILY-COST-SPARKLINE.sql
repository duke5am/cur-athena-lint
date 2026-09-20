-- ============================================================================
-- Q08  DAILY COST SERIES FOR ONE SERVICE (sparkline data)
-- ============================================================================
--
-- QUESTION
--   What did service REPLACE_ME_PRODUCT_CODE cost on each individual day of the
--   period?
--
-- WHAT IT RETURNS
--   One row per day: the day, the amortized cost, the summed usage amount,
--   the row count, and a trailing-7-day average with the difference from it.
--   The trailing average is what turns a list of numbers into a picture - a
--   one-day spike is visible against that series' own recent normal instead of
--   being averaged away by a monthly total.
--
-- WHY DAILY AND NOT MONTHLY
--   A monthly total cannot show you a spike. Most interesting spend events - a
--   runaway batch job, a misconfigured autoscaler, a forgotten NAT gateway,
--   an accidental cross-region copy - are one to three days long and vanish
--   inside a monthly average. Run this once you know WHICH service moved
--   (from Q03/Q04) and want to know WHEN.
--
--   The row_count column exists so a partial day is visible rather than
--   mistaken for a dip. The first and last day of a range are usually
--   partial: CUR rows are timestamped in UTC and the final day is incomplete
--   while AWS is still delivering.
--
-- BYTES SCANNED
--   One of the cheapest queries in the pack. One partition, one product code,
--   4 columns. The line_item_product_code predicate is a real column filter
--   that Parquet pushes down, so this typically scans a fraction of a month.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * Daily granularity only exists if the report was configured for HOURLY
--     or DAILY delivery. A monthly-only report has one row per resource per
--     billing period and this query collapses to a single bucket. If the
--     output looks wrong, that is the first thing to check.
--   * line_item_usage_start_date is a TIMESTAMP in UTC; CAST(... AS DATE)
--     groups by UTC day. If your business day is not UTC, shift before
--     casting - and say which convention you used, because an unstated
--     timezone is the most common cause of "the numbers changed between two
--     runs".
--
-- CAVEATS
--   * A day with no usage produces no row at all. A plotting library will
--     read the gap as zero, which is usually what you want; if you need every
--     day present, build a date spine and LEFT JOIN onto it.
--   * Amortized daily cost of an all-upfront Reserved Instance is a smooth
--     line by construction. That is the definition of amortization, not a
--     data problem, and it is exactly why this query is more useful for
--     uncovering on-demand surprises than commitment ones.
--   * The trailing average is NULL for the first day of the range because
--     there is no preceding data inside the window. That is expected; it is
--     not a missing-data bug. Widen the partition range if you need a warm
--     baseline on day one.
-- ============================================================================

WITH daily AS (
    SELECT
        CAST(line_item_usage_start_date AS DATE)  AS usage_date,
        SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
        )                                         AS amortized_cost,
        SUM(line_item_usage_amount)               AS usage_amount,
        COUNT(*)                                  AS row_count
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year  = 'REPLACE_ME_YYYY'
      AND month = 'REPLACE_ME_MONTH'
      AND line_item_product_code = 'REPLACE_ME_PRODUCT_CODE'
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
    GROUP BY 1
)
SELECT
    usage_date,
    ROUND(amortized_cost, 2)                                       AS amortized_cost,
    ROUND(usage_amount, 4)                                         AS usage_amount,
    row_count,
    ROUND(
        AVG(amortized_cost) OVER (
            ORDER BY usage_date
            ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
        )
    , 2)                                                           AS trailing_7d_avg,
    ROUND(
        amortized_cost
        - AVG(amortized_cost) OVER (
            ORDER BY usage_date
            ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
          )
    , 2)                                                           AS vs_trailing_7d
FROM daily
ORDER BY usage_date
;
