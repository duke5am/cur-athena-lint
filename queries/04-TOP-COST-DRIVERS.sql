-- ============================================================================
-- Q04  TOP COST DRIVERS: WHAT ACTUALLY MOVED THE BILL, WITH CONTRIBUTION
-- ============================================================================
--
-- QUESTION
--   The bill moved between the two months I select. Which specific
--   (account, service, usage type) combinations caused the increase, and how
--   much of the total increase does each one explain?
--
--   This is the difference between "what costs the most" - a useless answer,
--   because EC2 always costs the most - and "what CHANGED", which is the only
--   answer that helps.
--
-- WHAT IT RETURNS
--   One row per driver that moved, sorted by absolute contribution:
--     prev_cost / curr_cost   the two period figures
--     delta                   signed change
--     pct_of_total_change     this driver's share of the whole movement.
--                             Read this first: if one row is 60%, you are
--                             done investigating.
--     direction               NEW / GONE / UP / DOWN
--   A '(TOTAL CHANGE)' row is appended with pct_of_total_change = 100 so you
--   can see the denominator the shares are computed against.
--
-- WHY FULL OUTER JOIN AND NOT INNER JOIN
--   A driver that existed last month and vanished this month is a cost
--   SAVING, and an inner join deletes exactly that row. A brand new usage
--   type has no previous-month row either. FULL OUTER JOIN keeps both, and
--   the direction column labels them.
--
-- BYTES SCANNED
--   Two months of rows, aggregated on 6 columns - roughly two runs of Q01.
--   Note: adding LIMIT does NOT reduce bytes scanned, because the aggregation
--   still has to read every row before it can sort and cut. The only real
--   levers are a narrower partition range and a product-code pre-filter.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month, with the year IN (...) list covering both
--     months if they straddle a year boundary.
--   * line_item_usage_type is the right grain for "what changed" in most
--     investigations (BoxUsage:m5.4xlarge, NatGateway-Bytes, TimedStorage-ByteHrs
--     and so on). It is also the noisiest, so small movers are still emitted.
--     Once you know the scale of your bill, add a HAVING on ABS(delta).
--
-- CAVEATS
--   * Two months is the minimum honest comparison. Month-over-month is the
--     only comparison not confounded by seasonality or by a different number
--     of days in the month.
--   * If the current month is still being delivered, every driver reads as a
--     saving. Check the report status first.
--   * A Reserved Instance purchase creates a large UP row in the month of
--     purchase (the upfront/recurring fee usage types) plus DOWN rows where
--     on-demand usage was replaced. That is expected behaviour, not an
--     anomaly, and it is why the RI fee usage types should not be filtered
--     out of this query.
--   * The pct_of_total_change denominator is the NET movement. If increases
--     and decreases nearly cancel, individual shares exceed 100% or go
--     negative. That is arithmetic, not a bug - read the absolute delta.
-- ============================================================================

WITH period_cost AS (
    SELECT
        date_format(line_item_usage_start_date, '%Y-%m')  AS usage_month,
        COALESCE(line_item_usage_account_id, '(blank)')   AS usage_account_id,
        line_item_product_code                            AS service,
        line_item_usage_type                              AS usage_type,
        SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
        )                                                 AS amortized_cost
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year IN ('REPLACE_ME_YYYY', 'REPLACE_ME_YYYY')       -- every year you cross
      AND month BETWEEN 'REPLACE_ME_MONTH' AND 'REPLACE_ME_MONTH'
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
    GROUP BY 1, 2, 3, 4
),
curr AS (
    SELECT usage_month, usage_account_id, service, usage_type, amortized_cost
    FROM period_cost
    WHERE usage_month = 'REPLACE_ME_YYYY-MM'
),
prev AS (
    SELECT usage_month, usage_account_id, service, usage_type, amortized_cost
    FROM period_cost
    WHERE usage_month = 'REPLACE_ME_YYYY-MM'
),
joined AS (
    SELECT
        COALESCE(c.usage_account_id, p.usage_account_id) AS usage_account_id,
        COALESCE(c.service,          p.service)          AS service,
        COALESCE(c.usage_type,       p.usage_type)       AS usage_type,
        COALESCE(p.amortized_cost, 0)                    AS prev_cost,
        COALESCE(c.amortized_cost, 0)                    AS curr_cost,
        COALESCE(c.amortized_cost, 0) - COALESCE(p.amortized_cost, 0) AS delta
    FROM curr c
    FULL OUTER JOIN prev p
      ON  c.usage_account_id = p.usage_account_id
      AND c.service          = p.service
      AND c.usage_type       = p.usage_type
),
grand AS (
    SELECT SUM(delta) AS total_change FROM joined
)
SELECT
    j.usage_account_id,
    j.service,
    j.usage_type,
    ROUND(j.prev_cost, 2)                                    AS prev_cost,
    ROUND(j.curr_cost, 2)                                    AS curr_cost,
    ROUND(j.delta, 2)                                        AS delta,
    ROUND(100.0 * j.delta / NULLIF(g.total_change, 0), 1)    AS pct_of_total_change,
    CASE
        WHEN j.prev_cost = 0 AND j.curr_cost > 0 THEN 'NEW'
        WHEN j.curr_cost = 0 AND j.prev_cost > 0 THEN 'GONE'
        WHEN j.delta > 0                         THEN 'UP'
        ELSE 'DOWN'
    END                                                      AS direction,
    ROUND(g.total_change, 2)                                 AS period_total_change
FROM joined j
CROSS JOIN grand g

UNION ALL

SELECT
    '(all accounts)',
    '(TOTAL CHANGE)',
    '(all usage types)',
    NULL,
    NULL,
    ROUND(g.total_change, 2),
    100.0,
    CASE WHEN g.total_change > 0 THEN 'UP' ELSE 'DOWN' END,
    ROUND(g.total_change, 2)
FROM grand g
ORDER BY ABS(delta) DESC NULLS LAST, usage_account_id, service
;
