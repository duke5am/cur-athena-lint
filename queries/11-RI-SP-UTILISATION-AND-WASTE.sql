-- ============================================================================
-- Q11  COMMITMENT UTILISATION AND UNUSED COMMITMENT (the money you wasted)
-- ============================================================================
--
-- QUESTION
--   Of everything I committed to - Reserved Instances and Savings Plans - how
--   much did I actually use, and how much did I pay for and not use?
--
--   This is the query that finds money already spent that will never come
--   back. On most accounts it is the highest-value file in the pack and the
--   one people ask for after they have seen a surprising bill.
--
-- WHAT IT RETURNS
--   An RI section and an SP section, UNION ALL'd (not UNION, so a month with
--   only RI and no SP still returns a row):
--     commitment_type          'ReservedInstance' or 'SavingsPlan'
--     commitment_id            the reservation ARN / savings plan ARN
--     period_commitment_cost   what the commitment cost this period
--     used_commitment          the part a resource actually consumed
--     unused_commitment        the part that bought you nothing
--     unused_hours             RI hours you did not use (RI section only)
--     unused_pct               unused / commitment
--     utilisation_pct          used / commitment
--     effective_cost           amortized cost of the usage it covered
--     on_demand_equivalent     what that usage would have cost undiscounted
--
-- WHY THESE EXACT COLUMNS - AND WHY NOT savings_plan_total_commitment_to_date
--   AWS documents the RI columns precisely:
--     reservation_unused_quantity
--        "The number of RI hours that you didn't use during this billing
--         period."
--     reservation_unused_recurring_fee
--        "The recurring fees associated with your unused reservation hours
--         for partial upfront and no upfront RIs."
--     reservation_unused_amortized_upfront_fee_for_billing_period
--        the amortized portion of the initial upfront fee, i.e. upfront money
--        that bought nothing this period.
--   AWS also states where they live: "The values for these columns appear
--   only for RI subscription line items (also known as RI Fee line items) and
--   not for the actual instances using the RIs." Hence the
--   line_item_line_item_type = 'RIFee' filter on the RI section. (Unfiltered
--   would also be correct - the columns are NULL elsewhere - but the filter
--   says what you mean and reads less.)
--
--   For Savings Plans, the two columns that matter are:
--     savings_plan_used_commitment
--        "The total dollar amount of the Savings Plans commitment used.
--         (SavingsPlanRate multiplied by usage)" - lives on
--         SavingsPlanRecurringFee line items.
--     savings_plan_recurring_commitment_for_billing_period and
--     savings_plan_amortized_upfront_commitment_for_billing_period
--        the recurring and the amortized-upfront halves of what you owe for
--        the period.
--
--   savings_plan_total_commitment_to_date is deliberately NOT used here. AWS
--   documents it as "the total amortized upfront commitment and recurring
--   commitment TO DATE, for that hour" - it is CUMULATIVE. Dividing a used
--   quantity by a cumulative one makes every month look nearly 100%
--   utilised, which is worse than useless because it is reassuring.
--
-- BYTES SCANNED
--   One partition, roughly 12 columns, no product filter - and that is the
--   problem. reservation_* and savings_plan_* columns are read for every row
--   even though only a tiny fraction of rows populate them. This is one of
--   the two best cases in the pack for CTAS: build a slim commitment table
--   once and query it forever. See docs/COST-CONTROL-ATHENA.md.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * REQUIRES the reservation_* and savings_plan_* column families. Without
--     them the query fails to parse. See Q10's header for the marker columns.
--   * The subqueries in the final SELECT read from the same table again, so
--     this query touches the partition more than once. Athena caches by
--     digest only for repeated identical queries, not within one query - the
--     scan is what it is. Narrow it with the partition predicate and stop.
--
-- CAVEATS
--   * A Savings Plan is an HOURLY commitment. It is possible to be 100%
--     utilised for the month and still be over-committed, if you committed
--     on the last day. Utilisation describes the period; it cannot tell you
--     whether the commitment is sized right for next month.
--   * utilisation_pct is dollar-weighted across every RI and SP you hold,
--     including region-scoped and zonal RIs and both EC2 Instance and Compute
--     Savings Plans, which behave differently. Split by the relevant
--     attribute if you need to act on a specific commitment.
--   * unused_pct and utilisation_pct will not sum to exactly 100. The RI
--     denominator is amortized upfront plus recurring, while the "used" side
--     comes from effective-cost components rounded independently. Treat a
--     small gap as rounding; a large gap means a column is missing from your
--     report.
--   * expiry: an RI near the end of its term shows a large committed cost and
--     a small remaining use. That is not waste, it is an expiring asset. Read
--     the ARN and the term before you act on a row.
--   * This query makes NO recommendation. It shows the waste. Deciding
--     whether to buy more, sell on the RI Marketplace, or let a commitment
--     expire is a judgement about your roadmap that SQL does not have.
-- ============================================================================

WITH ri AS (
    SELECT
        COALESCE(reservation_reservation_a_r_n, '(no ARN on row)')  AS commitment_id,
        SUM(
              COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_unused_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
            + COALESCE(reservation_unused_recurring_fee, 0)
        )                                                          AS period_commitment_cost,
        SUM(COALESCE(reservation_recurring_fee_for_usage, 0))       AS used_commitment,
        SUM(
              COALESCE(reservation_unused_recurring_fee, 0)
            + COALESCE(reservation_unused_amortized_upfront_fee_for_billing_period, 0)
        )                                                          AS unused_commitment,
        SUM(reservation_unused_quantity)                           AS unused_hours
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year  = 'REPLACE_ME_YYYY'
      AND month = 'REPLACE_ME_MONTH'
      AND line_item_line_item_type = 'RIFee'
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
    GROUP BY 1
),
ri_usage AS (
    SELECT
        SUM(reservation_effective_cost)        AS effective_cost,
        SUM(pricing_public_on_demand_cost)     AS on_demand_equivalent
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year  = 'REPLACE_ME_YYYY'
      AND month = 'REPLACE_ME_MONTH'
      AND line_item_line_item_type = 'DiscountedUsage'
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
),
sp AS (
    SELECT
        COALESCE(savings_plan_savings_plan_a_r_n, '(no ARN on row)')  AS commitment_id,
        SUM(
              COALESCE(savings_plan_amortized_upfront_commitment_for_billing_period, 0)
            + COALESCE(savings_plan_recurring_commitment_for_billing_period, 0)
        )                                                             AS period_commitment_cost,
        SUM(COALESCE(savings_plan_used_commitment, 0))                AS used_commitment,
        SUM(
              COALESCE(savings_plan_amortized_upfront_commitment_for_billing_period, 0)
            + COALESCE(savings_plan_recurring_commitment_for_billing_period, 0)
        ) - SUM(COALESCE(savings_plan_used_commitment, 0))            AS unused_commitment
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year  = 'REPLACE_ME_YYYY'
      AND month = 'REPLACE_ME_MONTH'
      AND line_item_line_item_type = 'SavingsPlanRecurringFee'
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
    GROUP BY 1
),
sp_usage AS (
    SELECT
        SUM(savings_plan_savings_plan_effective_cost)  AS effective_cost,
        SUM(pricing_public_on_demand_cost)             AS on_demand_equivalent
    FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
    WHERE year  = 'REPLACE_ME_YYYY'
      AND month = 'REPLACE_ME_MONTH'
      AND line_item_line_item_type = 'SavingsPlanCoveredUsage'
      AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
      AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
)
SELECT
    'ReservedInstance'                                   AS commitment_type,
    r.commitment_id,
    ROUND(r.period_commitment_cost, 2)                   AS period_commitment_cost,
    ROUND(r.used_commitment, 2)                          AS used_commitment,
    ROUND(r.unused_commitment, 2)                        AS unused_commitment,
    ROUND(r.unused_hours, 2)                             AS unused_hours,
    ROUND(100.0 * r.unused_commitment
          / NULLIF(r.period_commitment_cost, 0), 1)      AS unused_pct,
    ROUND(100.0 * r.used_commitment
          / NULLIF(r.period_commitment_cost, 0), 1)      AS utilisation_pct,
    ROUND(u.effective_cost, 2)                           AS effective_cost,
    ROUND(u.on_demand_equivalent, 2)                     AS on_demand_equivalent
FROM ri r
CROSS JOIN ri_usage u

UNION ALL

SELECT
    'SavingsPlan'                                        AS commitment_type,
    s.commitment_id,
    ROUND(s.period_commitment_cost, 2),
    ROUND(s.used_commitment, 2),
    ROUND(s.unused_commitment, 2),
    CAST(NULL AS DOUBLE)                                 AS unused_hours,
    ROUND(100.0 * s.unused_commitment
          / NULLIF(s.period_commitment_cost, 0), 1),
    ROUND(100.0 * s.used_commitment
          / NULLIF(s.period_commitment_cost, 0), 1),
    ROUND(u.effective_cost, 2),
    ROUND(u.on_demand_equivalent, 2)
FROM sp s
CROSS JOIN sp_usage u
ORDER BY unused_commitment DESC NULLS LAST
;
