-- ============================================================================
-- Q13  S3 STORAGE vs REQUESTS vs TRANSFER: separating the three things people
--      all call "S3 cost"
-- ============================================================================
--
-- QUESTION
--   Of my S3 bill, how much is storage, how much is requests, and how much is
--   data leaving the bucket?
--
-- WHAT IT RETURNS
--   One row per (cost category, usage type, storage class, account) with the
--   cost, usage amount and row count.
--
-- WHY THE CATEGORY COLUMN
--   "S3 costs X" is not an actionable sentence. Storage is a function of how
--   much you keep and for how long. Requests are a function of how your
--   application reads. Transfer is a function of where the readers are. Three
--   completely different fixes. Splitting them is the entire value of this
--   query.
--
--   The categorisation matches on usage type substrings:
--     TimedStorage                                          -> Storage
--     Requests / Select / Inventory / BatchOperations /
--       Replication                                         -> Requests
--     Bytes                                                 -> Transfer
--     everything else in S3                                 -> Other
--   'Other' is kept rather than dropped on purpose. It catches retrieval,
--   early-delete, lifecycle-transition, management and Object Lambda usage
--   types, plus any future type AWS adds. If 'Other' is large, that is a real
--   finding about usage types you did not know you had.
--
-- BYTES SCANNED
--   One partition, 7 columns, filtered to AmazonS3. One of the cheapest
--   queries in the pack.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * line_item_product_code = 'AmazonS3'.
--   * product_storage_class is present in the standard export but populated
--     only for storage usage types (STANDARD, STANDARD_IA,
--     INTELLIGENT_TIERING, GLACIER, DEEP_ARCHIVE and similar). Request and
--     transfer rows show '(none)'.
--   * line_item_usage_account_id is grouped but not COALESCEd, so a NULL
--     account collapses into one NULL group. If you would rather see it
--     labelled, wrap it the way Q06 does.
--
-- CAVEATS
--   * This is NOT per-bucket. Per-bucket needs line_item_resource_id, which
--     requires resource IDs to be enabled AND is blank for request and
--     transfer rows - so a per-bucket view can never explain the whole S3
--     bill. Add the resource id to the GROUP BY only if you understand that
--     limitation.
--   * S3 Intelligent-Tiering monitoring and automation charges are their own
--     usage types and land in 'Other'. They scale with object count, not
--     bytes, which is why they can surprise you on a bucket with many small
--     objects.
--   * Request charges are usually dominated by a few request types (GET, PUT,
--     LIST). One misconfigured poller can outcost a large amount of stored
--     data. Sort by cost and read the usage types.
--   * usage_amount units differ per row (GB-Mo, Requests, GB), so this query
--     deliberately emits no usage total. Adding one would produce a
--     meaningless number.
-- ============================================================================

SELECT
    CASE
        WHEN line_item_usage_type LIKE '%TimedStorage%'    THEN 'Storage'
        WHEN line_item_usage_type LIKE '%Requests%'        THEN 'Requests'
        WHEN line_item_usage_type LIKE '%Select%'          THEN 'Requests'
        WHEN line_item_usage_type LIKE '%Inventory%'       THEN 'Requests'
        WHEN line_item_usage_type LIKE '%BatchOperations%' THEN 'Requests'
        WHEN line_item_usage_type LIKE '%Replication%'     THEN 'Requests'
        WHEN line_item_usage_type LIKE '%Bytes%'           THEN 'Transfer'
        ELSE 'Other'
    END                                                          AS cost_category,
    line_item_usage_type                                         AS usage_type,
    COALESCE(NULLIF(product_storage_class, ''), '(none)')        AS storage_class,
    line_item_usage_account_id                                   AS usage_account_id,
    ROUND(SUM(line_item_unblended_cost), 2)                      AS unblended_cost,
    ROUND(SUM(line_item_usage_amount), 2)                        AS usage_amount,
    COUNT(*)                                                     AS line_items
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_product_code = 'AmazonS3'
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2, 3, 4
ORDER BY unblended_cost DESC
;
