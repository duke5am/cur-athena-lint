-- ============================================================================
-- Q01  COST BY SERVICE FOR A PERIOD  [AMORTIZED BASIS - the default answer]
-- ============================================================================
--
-- QUESTION
--   What did each AWS service cost me in the period I select, as a single
--   honest number per service?
--
-- WHY THIS QUERY USES line_item_unblended_cost + reservation amortization
--   There is no single "cost" column in CUR. The three candidates are:
--
--     line_item_unblended_cost
--        The rate your own account was charged, times usage. AWS defines it
--        as "the UnblendedRate multiplied by the UsageAmount". This is the
--        cash-ish figure. Its weakness: for Reserved Instance usage it is NOT
--        the real cost. AWS documents that for EC2 and RDS line items with an
--        RI discount applied, the UnblendedRate is zero and the line item
--        type is DiscountedUsage. So RI-covered usage can appear at ~$0 on
--        the usage line while the real money sits once, in a separate RIFee
--        line for the whole month. Summing unblended_cost alone therefore
--        HIDES RI-covered spend and makes an RI-heavy account look cheap in
--        exactly the wrong places.
--
--     line_item_blended_cost
--        The BlendedRate multiplied by the UsageAmount, where the blended
--        rate is documented as "the average cost incurred for each SKU across
--        an organization", calculated at the management account level and
--        used to allocate costs to member accounts. It is an ALLOCATION
--        construct, not your bill. AWS documents it as blank for line items
--        with a LineItemType of Discount. Do not use it to answer "what did
--        we spend": at the payer level it does not sum to the invoice. Use
--        it only when a member account asks "what is my share of the
--        organization's committed spend".
--
--     amortized cost  (derived, used below)
--        Distributes one-time RI and Savings Plan fees across the period they
--        benefit. AWS documents the concept directly: "Amortizing is when you
--        distribute one-time reservation costs across the billing period that
--        is affected by that cost. Amortizing enables you to see your costs
--        in accrual-based accounting as opposed to cash-based accounting."
--
--   This query computes:
--       amortized_cost = line_item_unblended_cost
--                      + reservation_amortized_upfront_fee_for_billing_period
--                      + reservation_recurring_fee_for_usage
--
--   *** THE HONEST DISCLOSURE ***
--   The three-column sum above is a widely used CUR idiom. It is NOT an
--   AWS-published formula. AWS documents what each component column means and
--   what amortization is; it does not publish "amortized cost = A + B + C".
--   Treat this expression as a starting point that you MUST validate against
--   Cost Explorer for one month before relying on it. Q15 is the
--   reconciliation query and docs/VALIDATION.md is the procedure.
--
--   COALESCE(...,0) is used so the query still runs on a report that lacks
--   the reservation columns - but on such a report the amortized figure
--   degenerates to unblended and RI-covered spend stays hidden. Check with
--   DESCRIBE which columns you actually have (see Q00).
--
-- RETURNS
--   usage_account_id     account charged for the usage
--   service              line_item_product_code, e.g. AmazonEC2, AmazonS3
--   unblended_cost       cash-basis subtotal, kept for comparison
--   amortized_cost       accrual-basis subtotal - sort by this one
--   share_of_total_pct   this service's fraction of the period
--   line_items           row count, to spot a service made of one row
--
-- BYTES SCANNED
--   *** THIS IS THE EXPENSIVE QUERY. *** It aggregates every row in the
--   selected partitions. It reads 9 columns, which on Parquet is cheap per
--   row, but it touches EVERY row of every month you list. Always fill in the
--   year/month predicate. Never widen it "just to see". See
--   docs/COST-CONTROL-ATHENA.md for the four rules that make this cheap, and
--   Q14 for the partition-pruned version of the same question.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * REPLACE_ME_DATABASE.REPLACE_ME_TABLE - substitute your own.
--   * Partition columns: year (string) and month (string, zero-padded).
--     This is the standard CUR layout, but it VARIES with the report
--     configuration - some deployments use a single partition, or none.
--     Verify with SHOW PARTITIONS before editing the WHERE clause.
--   * reservation_amortized_upfront_fee_for_billing_period and
--     reservation_recurring_fee_for_usage come from the reservation column
--     family. If your report was created without them, replace those two
--     COALESCE terms with 0.
--
-- CAVEATS
--   * line_item_product_code is a billing code, not a friendly name.
--   * Nothing is excluded, so tax, credits and refunds are inside the total.
--     That is right for "what did I spend" and wrong for "what did my
--     workloads consume". Q02 splits it out and docs/CUR-SCHEMA.md explains
--     the line_item_line_item_type values.
--   * The last month in any CUR is usually incomplete while AWS is still
--     delivering rows. An apparently collapsing service is usually this.
-- ============================================================================

SELECT
    line_item_usage_account_id                                   AS usage_account_id,
    line_item_product_code                                       AS service,
    ROUND(SUM(line_item_unblended_cost), 2)                      AS unblended_cost,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                                  AS amortized_cost,
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
    , 2)                                                         AS share_of_total_pct,
    COUNT(*)                                                     AS line_items
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'                                            -- partition filter
  AND month = 'REPLACE_ME_MONTH'                                              -- partition filter
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2
ORDER BY amortized_cost DESC
;
