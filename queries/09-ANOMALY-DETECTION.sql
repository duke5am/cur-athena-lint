-- ============================================================================
-- Q09  ANOMALY DETECTION: EACH DAY AGAINST ITS OWN TRAILING BASELINE
-- ============================================================================
--
-- QUESTION
--   Which service-days are unusual for THAT SERVICE, relative to what that
--   service has been doing recently - not relative to the whole account?
--
-- WHAT IT RETURNS
--   One row per (service, day) that deviates from the service's own trailing
--   baseline, with:
--     trailing_7d_mean    what this service normally does
--     trailing_7d_sd      how stable it normally is
--     baseline_days       how many days the baseline is built from
--     deviation_abs       cost minus baseline, in dollars
--     deviation_pct       the same thing as a percentage
--     z_score             deviation in standard deviations
--     direction           SPIKE / DROP
--   Sorted by absolute dollar deviation, so the biggest surprise is first.
--
-- WHY A PER-SERVICE BASELINE AND NOT THE ACCOUNT TOTAL
--   Comparing everything to the account total only ever finds EC2. Comparing
--   each service to its own recent history finds the NAT gateway that
--   normally costs a few dollars a day and charged hundreds yesterday -
--   which matters more, even though it is invisible on a total-cost chart.
--
--   Both a z-score and a percentage are emitted on purpose, because each
--   fails differently:
--     * a z-score explodes when a series is nearly constant, because the
--       standard deviation approaches zero and every trivial change looks
--       enormous;
--     * a percentage explodes when the baseline is near zero.
--   The min baseline filter below removes the second failure mode; read the
--   pair together and be suspicious of rows where they disagree wildly.
--
-- BYTES SCANNED
--   TWO months of rows, 5 columns, because the trailing window needs the days
--   before the period you are investigating. Budget roughly twice Q08.
--   For a year of history, CTAS a daily rollup once
--   (docs/COST-CONTROL-ATHENA.md) and run this against that - the anomaly
--   logic is identical and the scan becomes trivial.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month - and because the window crosses a month
--     boundary, the year/month predicate must cover BOTH months. This is the
--     easiest place in the pack to scan a year by accident: a
--     `month BETWEEN '01' AND '12'` would scan all twelve.
--   * ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING deliberately excludes the
--     current day from its own baseline.
--   * STDDEV is standard SQL; Athena (Trino) provides it as an aggregate and
--     as a window function. This query uses the window form.
--
-- CAVEATS
--   * Seven days is a starting point, not a law. Short enough to notice a
--     change, long enough to survive a weekend. For a service with a strong
--     weekly cycle, use 14 days plus a same-weekday comparison, or spikes
--     will fire every Monday.
--   * This is a statistical filter, not an anomaly detection service. It will
--     flag a planned marketing push and it will miss a slow two-month climb.
--     It answers "what is unusual today" and nothing more.
--   * Where the standard deviation is zero (a perfectly flat series) the
--     NULLIF keeps the query from failing and yields a NULL z_score. Those
--     rows are still reporting deviation_pct, so they are not lost.
--   * The thresholds - baseline of at least 5 days, baseline mean of at least
--     1.0, z of 3 or 50 percent - are judgement calls, not tuned values. They
--     are stated as literals so you can change them deliberately. On a small
--     bill, lower the 1.0; on a large one, raise it.
--   * Grouping by UTC date means two days a year are 23 or 25 hours long.
--     Irrelevant unless you are chasing small deviations.
-- ============================================================================

WITH daily AS (
    SELECT
        line_item_product_code                    AS service,
        CAST(line_item_usage_start_date AS DATE)  AS usage_date,
        SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
        )                                         AS amortized_cost
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year IN ('REPLACE_ME_YYYY', 'REPLACE_ME_YYYY')       -- both months' years
      AND month BETWEEN 'REPLACE_ME_MONTH' AND 'REPLACE_ME_MONTH'    -- exactly the two months
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
    GROUP BY 1, 2
),
baselined AS (
    SELECT
        service,
        usage_date,
        amortized_cost,
        AVG(amortized_cost) OVER w    AS trailing_7d_mean,
        STDDEV(amortized_cost) OVER w AS trailing_7d_sd,
        COUNT(*) OVER w                AS baseline_days
    FROM daily
    WINDOW w AS (
        PARTITION BY service
        ORDER BY usage_date
        ROWS BETWEEN 7 PRECEDING AND 1 PRECEDING
    )
)
SELECT
    service,
    usage_date,
    ROUND(amortized_cost, 2)                                 AS amortized_cost,
    ROUND(trailing_7d_mean, 2)                               AS trailing_7d_mean,
    ROUND(trailing_7d_sd, 2)                                 AS trailing_7d_sd,
    baseline_days,
    ROUND(amortized_cost - trailing_7d_mean, 2)              AS deviation_abs,
    ROUND(
        100.0 * (amortized_cost - trailing_7d_mean)
        / NULLIF(trailing_7d_mean, 0)
    , 1)                                                     AS deviation_pct,
    ROUND(
        (amortized_cost - trailing_7d_mean)
        / NULLIF(trailing_7d_sd, 0)
    , 2)                                                     AS z_score,
    CASE WHEN amortized_cost > trailing_7d_mean THEN 'SPIKE' ELSE 'DROP' END AS direction
FROM baselined
WHERE baseline_days >= 5
  AND trailing_7d_mean >= 1.0
  AND (
          ABS((amortized_cost - trailing_7d_mean) / NULLIF(trailing_7d_sd, 0)) >= 3
       OR ABS(100.0 * (amortized_cost - trailing_7d_mean)
              / NULLIF(trailing_7d_mean, 0)) >= 50
      )
ORDER BY ABS(amortized_cost - trailing_7d_mean) DESC
;
