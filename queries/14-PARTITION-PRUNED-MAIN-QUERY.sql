-- ============================================================================
-- Q14  PARTITION-PRUNED COST BY SERVICE - THE VERSION YOU SHOULD ACTUALLY RUN
-- ============================================================================
--
-- QUESTION
--   The same question as Q01 - what did each service cost this month, per
--   account - asked in a form that reads as few bytes as Athena will let you
--   read.
--
-- WHY THIS FILE EXISTS
--   Q01 and Q14 answer the same question. Q14 is here so you can see, side by
--   side, exactly which lines make a query cheap. There are four, and only
--   four:
--
--     1. A LITERAL partition predicate on EVERY partition column.
--            WHERE year = '2024' AND month = '03'
--        Athena prunes partitions from this. Anything that stops it being a
--        literal - a function call, a subquery, a CAST, a bind parameter -
--        can defeat pruning and turn a one-partition scan into a full-table
--        scan. Keep the partition predicate as plain equality against string
--        literals.
--
--     2. No SELECT *.
--        CUR has 100+ columns. Parquet is columnar, so naming 7 columns reads
--        roughly 7 columns' worth of bytes. SELECT * reads every column -
--        including the very large product attribute set - for every row you
--        selected. It is the single most expensive habit in CUR querying.
--
--     3. No function wrapped around a partition value.
--            WHERE date_format(line_item_usage_start_date, '%Y-%m') = '2024-03'
--        This is the classic mistake. It LOOKS like a partition filter and is
--        not one, so the query scans everything and filters afterwards.
--        Filter the partition columns; bound the timestamp separately.
--
--     4. The timestamp bound written as a half-open range.
--            >= start AND < end
--        Athena can push a range predicate on line_item_usage_start_date into
--        Parquet row-group statistics, so this reads fewer row groups than
--        pulling the whole partition and filtering the days in an outer query.
--
-- HOW TO KNOW IT WORKED
--   Run EXPLAIN (or EXPLAIN ANALYZE) on both versions, then run them and
--   compare the "Data scanned" figure Athena reports for each query. If Q14's
--   scanned bytes are not dramatically lower than a naive full-table version
--   of the same question, one of the four rules is still being broken.
--   docs/COST-CONTROL-ATHENA.md has the full checklist, plus partition
--   projection, CTAS and the tag-partition trade-off.
--
-- RETURNS
--   Same shape as Q01: service, account, unblended cost, amortized cost,
--   usage amount, row count.
--
-- BYTES SCANNED
--   Deliberately the minimum for this question: one partition, 7 columns.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month, both STRING, as in Q01.
--   * If your deployment uses Athena partition projection, this WHERE clause
--     still prunes, and you additionally avoid the Glue GetPartitions call.
--     Projection does not change the SQL; it changes the table properties.
--   * If your report has NO partitions (one flat prefix), none of this helps
--     and the right move is to re-create the report partitioned, or to CTAS.
--
-- CAVEATS
--   * year and month must be STRING with zero-padded months ('01' ... '12'),
--     matching the S3 key layout. If your table declares them as INT, drop
--     the quotes. Do not write year = 2024 against a STRING column and hope:
--     a failed cast can silently return nothing and look like "no cost".
--   * Pruning is only as good as the partition layout. A CUR delivered as one
--     file group per month is genuinely prunable. A single multi-GB Parquet
--     file covering a whole year is not, no matter what the WHERE clause
--     says.
--   * Partition pruning reduces bytes READ. It does not reduce the size of
--     the result, so keep the GROUP BY as narrow as the question allows.
-- ============================================================================

SELECT
    line_item_product_code                                   AS service,
    line_item_usage_account_id                               AS usage_account_id,
    ROUND(SUM(line_item_unblended_cost), 2)                  AS unblended_cost,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                              AS amortized_cost,
    ROUND(SUM(line_item_usage_amount), 4)                    AS usage_amount,
    COUNT(*)                                                 AS line_items
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'                 -- literal -> partition pruned
  AND month = 'REPLACE_ME_MONTH'                   -- literal -> partition pruned
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2
ORDER BY amortized_cost DESC
;
