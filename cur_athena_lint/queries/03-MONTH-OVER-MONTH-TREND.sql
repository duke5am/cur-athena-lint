-- ============================================================================
-- Q03  MONTH-OVER-MONTH TREND: TOTAL, DELTA, PERCENT CHANGE
-- ============================================================================
--
-- QUESTION
--   Over the months I select, what did each service cost, how much did it
--   move against the previous month, and which direction did the total go?
--
-- WHAT IT RETURNS
--   One row per service per month with the cost, the previous month's cost,
--   the absolute delta, the percentage change, and the all-services total for
--   that month. The month_total column is what tells you whether one service
--   explains the whole movement or whether ten of them drifted together.
--
-- WHY THE LAG PARTITIONS ON SERVICE, NOT ON ACCOUNT
--   Partition by account and the "biggest mover" gets diluted - a service
--   that doubled inside one account looks flat across forty accounts.
--   Aggregate to the level you actually want to explain first, then window.
--
-- BYTES SCANNED
--   This scans every month you list, so it costs roughly N times Q01. That is
--   the trade for a trend. In order of effectiveness:
--     1. Keep the column list narrow. It already is - do not add columns.
--     2. Add AND line_item_product_code IN (...) for the services you care
--        about. On Parquet this is a real column filter that pushes down.
--     3. Materialise a slim monthly table with CTAS ONCE and query that
--        forever - see docs/COST-CONTROL-ATHENA.md.
--   Never run a 24-month version of this "just to look".
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month. Because a trend crosses years, the year IN
--     (...) list must contain EVERY year in range. If you list one year and
--     query two, you get a silently truncated trend with no error.
--   * line_item_usage_start_date is a TIMESTAMP in UTC; date_format accepts
--     it directly in Athena (Trino).
--
-- CAVEATS
--   * These are CALENDAR months, not billing periods. If your bill closes on
--     the 3rd, a calendar-month trend disagrees with the invoice by a few
--     days. Use bill_billing_period_start_date if you need invoice alignment.
--   * A month with no rows for a service produces no row, so LAG jumps over
--     it and reports a change against a month you have no data for. Build a
--     month spine and LEFT JOIN if that matters to you.
--   * The most recent month in any CUR is usually incomplete while AWS is
--     still delivering. A trend ending in a cliff is almost always this, not
--     a cost optimisation you accidentally performed.
--   * Comparing January to December will lie to you. Compare like months.
-- ============================================================================

WITH monthly AS (
    SELECT
        date_format(line_item_usage_start_date, '%Y-%m') AS usage_month,
        line_item_product_code                           AS service,
        SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
        )                                                AS amortized_cost
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year IN ('REPLACE_ME_YYYY', 'REPLACE_ME_YYYY')       -- list EVERY year you cross
      AND month BETWEEN 'REPLACE_ME_MONTH' AND 'REPLACE_ME_MONTH'    -- keeps the scan bounded
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
    GROUP BY 1, 2
),
with_lag AS (
    SELECT
        usage_month,
        service,
        amortized_cost,
        LAG(amortized_cost) OVER (
            PARTITION BY service ORDER BY usage_month
        ) AS prev_month_cost
    FROM monthly
)
SELECT
    usage_month,
    service,
    ROUND(amortized_cost, 2)                                      AS amortized_cost,
    ROUND(prev_month_cost, 2)                                     AS prev_month_cost,
    ROUND(amortized_cost - prev_month_cost, 2)                    AS mom_delta,
    ROUND(
        100.0 * (amortized_cost - prev_month_cost)
        / NULLIF(prev_month_cost, 0)
    , 1)                                                          AS mom_delta_pct,
    ROUND(SUM(amortized_cost) OVER (PARTITION BY usage_month), 2) AS month_total
FROM with_lag
ORDER BY usage_month DESC, mom_delta DESC NULLS LAST
;
