-- ============================================================================
-- Q10  EC2 COVERAGE AND EFFECTIVE DISCOUNT: ON-DEMAND vs RI vs SAVINGS PLAN
-- ============================================================================
--
-- QUESTION
--   For EC2 compute, how much am I paying at on-demand rates, how much is
--   covered by a commitment, and what discount am I actually getting on the
--   covered part?
--
-- WHAT IT RETURNS
--   One row per (usage type, account), with:
--     on_demand_cost          uncovered usage at on-demand rates
--     discounted_usage_cost   the near-zero charge on RI-covered usage
--     sp_covered_usage        what SP-covered usage would have cost on demand
--     sp_negation             the negative offset that cancels it
--     ri_effective_cost       the amortized true cost of RI-covered usage
--     sp_effective_cost       the amortized true cost of SP-covered usage
--     public_on_demand_cost   the list price of everything in the row
--     effective_cost          what you actually paid, amortized
--     effective_discount_pct  how far below list price that is
--
-- WHY effective_cost IS THE HONEST DENOMINATOR
--   The obvious move - compare line_item_unblended_cost against
--   pricing_public_on_demand_cost - is wrong on both sides:
--     * UnblendedRate is documented as ZERO for EC2 and RDS line items with an
--       RI discount applied, so discounted_usage_cost tells you nothing about
--       what the reservation actually cost you.
--     * sp_covered_usage is recorded at the on-demand list price and is then
--       cancelled by sp_negation. Including one without the other inflates
--       the list-price side by exactly the amount you never paid.
--
--   So the committed side comes from the amortized columns instead. AWS
--   documents reservation_effective_cost as "the sum of both the upfront and
--   hourly rate of your RI, averaged into an effective hourly rate", and
--   savings_plan_savings_plan_effective_cost as "the proportion of the Savings
--   Plans monthly commitment amount (upfront and recurring) that is allocated
--   to each usage line". Those are the committed dollars. This query sums them
--   and compares to list price.
--
-- A NOTE ON THE DISCOUNT PERCENTAGE
--   effective_discount_pct is arithmetic on YOUR data:
--   (list - effective) / list. It is not a benchmark. This pack makes no claim
--   about what a "good" discount is, because that depends on your instance
--   mix, term length, and growth. Read it as a description of what you bought,
--   not a score.
--
-- BYTES SCANNED
--   One partition, about 10 columns, filtered to EC2 via
--   line_item_product_code. Without that product filter this would be a
--   full-bill scan; with it, Parquet reads a fraction of the month.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * REQUIRES reservation_effective_cost and
--     savings_plan_savings_plan_effective_cost. These are part of the column
--     families the AWS Cloud Intelligence Dashboards CUR helper uses to
--     detect "this CUR has RI/SP data":
--         reservation_reservation_a_r_n, reservation_effective_cost,
--         reservation_start_time, reservation_end_time
--         savings_plan_savings_plan_a_r_n,
--         savings_plan_savings_plan_effective_cost,
--         savings_plan_start_time, savings_plan_end_time
--     If DESCRIBE shows them missing, the query fails to parse - that is the
--     correct loud failure. Either re-create the report including Savings
--     Plans and reservation columns, or ALTER TABLE ADD COLUMNS.
--   * line_item_product_code = 'AmazonEC2'. Change it for RDS or ElastiCache,
--     which have their own RI mechanics and their own product codes.
--
-- CAVEATS
--   * Coverage for a size-flexible RI is spread across instance sizes using
--     line_item_normalization_factor, so a per-usage-type coverage number is
--     approximate at the size level even when the account total is exact.
--   * pricing_public_on_demand_cost is the LIST cost. It ignores every
--     discount you hold, which is precisely why it is usable as the ratio's
--     numerator and useless as a statement of what you paid.
--   * Savings Plans cover compute across EC2, Lambda and Fargate. Filtering
--     to AmazonEC2 understates your SP coverage, because the SP benefit on
--     Lambda and Fargate lands under those product codes. Remove the product
--     filter for a true organization-wide coverage number - and accept the
--     larger scan.
--   * Rows where list price is zero are dropped by the HAVING. Those are
--     typically credits, fees and zero-cost usage types, where a discount
--     percentage is not a meaningful quantity.
-- ============================================================================

SELECT
    line_item_usage_type                                     AS usage_type,
    COALESCE(line_item_usage_account_id, '(blank)')          AS usage_account_id,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'Usage'
                   THEN line_item_unblended_cost END), 2)    AS on_demand_cost,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage'
                   THEN line_item_unblended_cost END), 2)    AS discounted_usage_cost,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
                   THEN line_item_unblended_cost END), 2)    AS sp_covered_usage,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanNegation'
                   THEN line_item_unblended_cost END), 2)    AS sp_negation,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'DiscountedUsage'
                   THEN reservation_effective_cost END), 2)  AS ri_effective_cost,
    ROUND(SUM(CASE WHEN line_item_line_item_type = 'SavingsPlanCoveredUsage'
                   THEN savings_plan_savings_plan_effective_cost END), 2)
                                                             AS sp_effective_cost,
    ROUND(SUM(pricing_public_on_demand_cost), 2)             AS public_on_demand_cost,
    ROUND(SUM(
              COALESCE(reservation_effective_cost, 0)
            + COALESCE(savings_plan_savings_plan_effective_cost, 0)
            + CASE WHEN line_item_line_item_type = 'Usage'
                   THEN COALESCE(line_item_unblended_cost, 0) END
          ), 2)                                              AS effective_cost,
    ROUND(
        100.0 * (
            SUM(pricing_public_on_demand_cost)
          - SUM(
                COALESCE(reservation_effective_cost, 0)
              + COALESCE(savings_plan_savings_plan_effective_cost, 0)
              + CASE WHEN line_item_line_item_type = 'Usage'
                     THEN COALESCE(line_item_unblended_cost, 0) END
            )
        )
        / NULLIF(SUM(pricing_public_on_demand_cost), 0)
    , 1)                                                     AS effective_discount_pct
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_product_code = 'AmazonEC2'
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2
HAVING SUM(pricing_public_on_demand_cost) > 0
ORDER BY public_on_demand_cost DESC
;
