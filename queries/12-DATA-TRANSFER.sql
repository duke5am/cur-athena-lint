-- ============================================================================
-- Q12  DATA TRANSFER COST BREAKDOWN
-- ============================================================================
--
-- QUESTION
--   How much am I paying to move bytes, on which service, and from where to
--   where?
--
-- WHAT IT RETURNS
--   One row per (service, usage type, from-location, to-location) with the
--   transfer cost, usage amount, list cost and row count. '(none)' means the
--   service does not populate that location attribute for that usage type,
--   which is information rather than an error.
--
-- WHY THIS NEEDS ITS OWN QUERY
--   Data transfer is the cost that is hardest to attribute by resource and
--   easiest to cause by accident. AWS treats it as a first-class subject with
--   its own guide (Understanding data transfer charges) precisely because it
--   is metered per usage type - DataTransfer-Out-Bytes,
--   DataTransfer-Regional-Bytes, NatGateway-Bytes and so on - and NOT per
--   resource. These rows typically carry no line_item_resource_id at all, so
--   resource reports and tag reports simply do not see them, and the cost
--   accumulates quietly.
--
--   Filtering on line_item_usage_type LIKE '%Bytes%' is the practical
--   definition of "data transfer" in CUR. It is a substring match on a real
--   column rather than a hardcoded list of magic values, so it keeps working
--   when AWS adds new transfer usage types.
--
-- BYTES SCANNED
--   One partition, about 8 columns, no product filter - transfer is spread
--   across S3, EC2, CloudFront, NAT Gateway, Direct Connect and others. Note
--   carefully: the LIKE predicate is a row filter, NOT a partition filter.
--   It reduces the rows returned but NOT the bytes read, because Athena still
--   has to read line_item_usage_type for every row in the partition. Only the
--   year/month predicate prunes. If you already know which service is
--   transfer-heavy, adding AND line_item_product_code IN ('AmazonEC2','AmazonS3')
--   is a genuine saving.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * product_from_location, product_to_location and the *location_type
--     variants are product columns: present in the standard export but
--     populated for only some services. All STRING.
--   * line_item_line_item_type is restricted to Usage, DiscountedUsage and
--     SavingsPlanCoveredUsage so credits, taxes and fees cannot leak into a
--     "transfer cost" number.
--
-- CAVEATS
--   * "Data transfer" is not one thing. Cross-AZ traffic inside a region,
--     internet egress, inter-region traffic, CloudFront origin fetch and NAT
--     Gateway processing are priced differently and all appear here. Do not
--     sum them into one "egress" line and then try to reconcile against a
--     pricing page - the pricing page has more rows than you do.
--   * Some usage types containing 'Bytes' are not transfer at all (some
--     services meter storage or scanned data in bytes). Cross-check
--     line_item_product_code before acting on a row.
--   * Free-tier and included-allowance usage appears at zero cost. A row with
--     a large usage_amount and a near-zero cost is not a data error.
--   * CloudFront and some other services record transfer under their own
--     product code even when the bytes physically left an S3 bucket. The
--     "cause" and the "charge" frequently sit on different rows. That is
--     inherent to how CUR models usage, and no query fixes it.
--   * usage_amount units differ per usage type (GB, GB-Mo, requests). Do not
--     sum usage_amount across categories.
-- ============================================================================

SELECT
    line_item_product_code                                      AS service,
    line_item_usage_type                                        AS usage_type,
    COALESCE(NULLIF(product_from_location, ''), '(none)')       AS from_location,
    COALESCE(NULLIF(product_to_location, ''), '(none)')         AS to_location,
    COALESCE(NULLIF(product_from_location_type, ''), '(none)')  AS from_location_type,
    COALESCE(NULLIF(product_to_location_type, ''), '(none)')    AS to_location_type,
    ROUND(SUM(line_item_unblended_cost), 2)                     AS unblended_cost,
    ROUND(SUM(line_item_usage_amount), 2)                       AS usage_amount,
    ROUND(SUM(pricing_public_on_demand_cost), 2)                AS public_on_demand_cost,
    COUNT(*)                                                    AS line_items
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_usage_type LIKE '%Bytes%'
  AND line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY unblended_cost DESC
;
