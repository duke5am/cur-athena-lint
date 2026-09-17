-- ============================================================================
-- create_table.sql
-- Athena external table for a standard AWS Cost and Usage Report (CUR)
-- delivered to Amazon S3 as Parquet, partitioned by year / month.
--
-- READ setup/README.md FIRST. It explains how the report must be configured
-- for this DDL to match your data, and how to check whether yours does.
--
-- EXPECTED S3 LAYOUT (partition projection / Hive style):
--   s3://<bucket>/<prefix>/<report-name>/<report-name>/year=2024/month=03/*.parquet
--
--   The standard CUR delivery puts the report name in the prefix twice. Get
--   the exact prefix from the S3 console - it is the path you land on when
--   you navigate to the folder containing the year= folders - and paste it
--   into LOCATION below, ending with a single trailing slash.
--
-- NOTHING HERE WAS RUN AGAINST ATHENA. See ../README.md for the disclosure
-- and ../docs/VALIDATION.md for the procedure to prove this against your
-- own account. The column list below was checked against AWS's published
-- CUR documentation; see ../docs/CUR-SCHEMA.md section 14 for the sources.
--
-- ----------------------------------------------------------------------------
-- ABOUT THE COLUMN LIST
-- ----------------------------------------------------------------------------
-- This DDL declares the columns this pack's queries use, plus the small set
-- of structural columns you will want immediately. It is deliberately NOT
-- the full 100+ column CUR schema.
--
-- Why: the full CUR 2.0 column set is partly conditional. Some columns exist
-- only when an account has a discount in the period, only when IAM principal
-- data is enabled, or only when split cost allocation data is enabled. A DDL
-- that declares columns your report does not contain does not break anything
-- (the columns read as NULL), but a DDL that OMITS a column your report does
-- contain means you cannot query it.
--
-- So: this list is a safe floor, not a ceiling. If your report has more
-- columns, add them with ALTER TABLE ... ADD COLUMNS (see the bottom of this
-- file). The safest starting point of all is AWS's own generated DDL - see
-- setup/README.md section "Where to get the authoritative DDL for YOUR
-- report", which is what we recommend you do if you can.
--
-- Column families declared below:
--   bill_*          billing period and payer
--   line_item_*     cost, usage, type
--   product_*       product attributes used by the queries in this pack
--   pricing_*       list-price baseline and term information
--   reservation_*   Reserved Instance cost and waste
--   savings_plan_*  Savings Plan commitment and usage
--   resource_tags_* two example tag keys - SEE THE WARNING BELOW
--   year, month     partition columns
--
-- *** WARNING ABOUT THE resource_tags_ COLUMNS BELOW ***
-- Tag columns are named resource_tags_user_<tag_key>, and they exist ONLY
-- for tag keys the report was configured to include. The two declared here
-- (resource_tags_user_team, resource_tags_user_environment) are placeholders
-- for two common keys. Replace them with the keys YOUR report actually
-- carries, spelled the way the report spells them (lowercased, separators
-- converted to underscores: tag key "cost-center" -> resource_tags_user_cost_center).
-- Find the real names with:
--     SHOW COLUMNS IN <database>.<table>;
-- Declaring a tag column your report does not populate is harmless - it
-- reads as NULL - but declaring the WRONG NAME while believing it is right
-- is how an untagged-spend number gets silently reported as full coverage.
-- ============================================================================

CREATE EXTERNAL TABLE IF NOT EXISTS `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE` (

    -- ------------------------------------------------------------------
    -- bill_*  : billing period and payer
    -- ------------------------------------------------------------------
    `bill_bill_type`                    string,
    `bill_billing_entity`               string,
    `bill_billing_period_end_date`      timestamp,
    `bill_billing_period_start_date`    timestamp,
    `bill_invoice_id`                   string,
    `bill_payer_account_id`             string,

    -- ------------------------------------------------------------------
    -- identity_*
    -- ------------------------------------------------------------------
    `identity_line_item_id`             string,
    `identity_time_interval`            string,

    -- ------------------------------------------------------------------
    -- line_item_*  : the columns that carry the money
    -- ------------------------------------------------------------------
    `line_item_availability_zone`       string,
    `line_item_blended_cost`            double,
    `line_item_blended_rate`            string,
    `line_item_currency_code`           string,
    `line_item_legal_entity`            string,
    `line_item_line_item_description`   string,
    `line_item_line_item_type`          string,
    `line_item_normalization_factor`    double,
    `line_item_normalized_usage_amount` double,
    `line_item_operation`               string,
    `line_item_product_code`            string,
    `line_item_resource_id`             string,
    `line_item_tax_type`                string,
    `line_item_unblended_cost`          double,
    `line_item_unblended_rate`          string,
    `line_item_usage_account_id`        string,
    `line_item_usage_amount`            double,
    `line_item_usage_end_date`          timestamp,
    `line_item_usage_start_date`        timestamp,
    `line_item_usage_type`              string,

    -- ------------------------------------------------------------------
    -- product_*  : only the attributes this pack's queries reference.
    --              The published CUR product attribute list is far larger
    --              (hundreds of attributes across services). Add what you
    --              need with ALTER TABLE rather than guessing names.
    -- ------------------------------------------------------------------
    `product_from_location`             string,
    `product_from_location_type`        string,
    `product_instance_type`             string,
    `product_product_family`            string,
    `product_product_name`              string,
    `product_region`                    string,
    `product_storage_class`             string,
    `product_to_location`               string,
    `product_to_location_type`          string,

    -- ------------------------------------------------------------------
    -- pricing_*  : list-price baseline and term information
    -- ------------------------------------------------------------------
    `pricing_lease_contract_length`     string,
    `pricing_public_on_demand_cost`     double,
    `pricing_public_on_demand_rate`     string,
    `pricing_rate_id`                   string,
    `pricing_term`                      string,
    `pricing_unit`                      string,

    -- ------------------------------------------------------------------
    -- reservation_*  : Reserved Instance cost and waste.
    --   Populated per line item type - see ../docs/CUR-SCHEMA.md section 7.
    --   REMOVE THIS BLOCK if your report was created without the
    --   reservations columns, and remove the reservation_ terms from the
    --   queries that use them (the query headers say which).
    -- ------------------------------------------------------------------
    `reservation_amortized_upfront_cost_for_usage`                  double,
    `reservation_amortized_upfront_fee_for_billing_period`          double,
    `reservation_effective_cost`                                    double,
    `reservation_end_time`                                          timestamp,
    `reservation_modification_status`                               string,
    `reservation_normalized_units_per_reservation`                  string,
    `reservation_number_of_reservations`                            string,
    `reservation_recurring_fee_for_usage`                           double,
    `reservation_reservation_a_r_n`                                 string,
    `reservation_start_time`                                        timestamp,
    `reservation_subscription_id`                                   string,
    `reservation_total_reserved_normalized_units`                   string,
    `reservation_total_reserved_units`                              string,
    `reservation_units_per_reservation`                             string,
    `reservation_unused_amortized_upfront_fee_for_billing_period`   double,
    `reservation_unused_normalized_unit_quantity`                   double,
    `reservation_unused_quantity`                                   double,
    `reservation_unused_recurring_fee`                              double,
    `reservation_upfront_value`                                     double,

    -- ------------------------------------------------------------------
    -- savings_plan_*  : Savings Plan commitment and usage.
    --   REMOVE THIS BLOCK if your report was created without the
    --   Savings Plans columns.
    -- ------------------------------------------------------------------
    `savings_plan_amortized_upfront_commitment_for_billing_period`  double,
    `savings_plan_end_time`                                         timestamp,
    `savings_plan_instance_type_family`                             string,
    `savings_plan_offering_type`                                    string,
    `savings_plan_payment_option`                                   string,
    `savings_plan_purchase_term`                                    string,
    `savings_plan_recurring_commitment_for_billing_period`          double,
    `savings_plan_region`                                           string,
    `savings_plan_savings_plan_a_r_n`                               string,
    `savings_plan_savings_plan_effective_cost`                      double,
    `savings_plan_savings_plan_rate`                                double,
    `savings_plan_start_time`                                       timestamp,
    `savings_plan_total_commitment_to_date`                         double,
    `savings_plan_used_commitment`                                  double,

    -- ------------------------------------------------------------------
    -- resource_tags_*  : REPLACE THESE TWO WITH YOUR OWN TAG KEYS.
    --   See the WARNING in the header of this file.
    -- ------------------------------------------------------------------
    `resource_tags_user_team`           string,
    `resource_tags_user_environment`    string

)
PARTITIONED BY (
    `year`  string,
    `month` string
)
ROW FORMAT SERDE
    'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS INPUTFORMAT
    'org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat'
OUTPUTFORMAT
    'org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat'
LOCATION
    's3://REPLACE_ME_BUCKET/REPLACE_ME_PREFIX/REPLACE_ME_REPORT_NAME/REPLACE_ME_REPORT_NAME/'
TBLPROPERTIES (
    'parquet.compression' = 'SNAPPY',
    'classification' = 'parquet',
    'has_encrypted_data' = 'false'
)

-- ============================================================================
-- STEP 2 - REGISTER PARTITIONS
-- ============================================================================
-- The CREATE TABLE above declares the partitions but registers none. Until
-- partitions exist, every query returns zero rows and reports no error. This
-- is the single most common "my CUR table is broken" cause.
--
-- ----------------------------------------------------------------------------
-- OPTION A (recommended for a non-projected table): MSCK REPAIR TABLE
-- ----------------------------------------------------------------------------
-- Lists the LOCATION prefix and registers any Hive-style partition folders
-- it finds. Run it after every new report delivery.
--
--   MSCK REPAIR TABLE `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE`;
--
-- In the Athena console the same operation is the table's "Load partitions"
-- action, which is what the AWS CUR User Guide tells you to use. On a deep
-- CUR prefix this is a full listing of the prefix, so it is not free - but it
-- is far cheaper than a query that silently returns nothing.
--
-- ----------------------------------------------------------------------------
-- OPTION B (cheapest and most precise): ALTER TABLE ADD PARTITION
-- ----------------------------------------------------------------------------
-- You already know last month's partition values. Register exactly those and
-- nothing else. This is the best fit for a scheduled job.
--
--   ALTER TABLE `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE`
--   ADD IF NOT EXISTS
--     PARTITION (`year` = '2024', `month` = '01') LOCATION 's3://REPLACE_ME_BUCKET/REPLACE_ME_PREFIX/REPLACE_ME_REPORT_NAME/REPLACE_ME_REPORT_NAME/year=2024/month=01/'
--     PARTITION (`year` = '2024', `month` = '02') LOCATION 's3://REPLACE_ME_BUCKET/REPLACE_ME_PREFIX/REPLACE_ME_REPORT_NAME/REPLACE_ME_REPORT_NAME/year=2024/month=02/'
--     PARTITION (`year` = '2024', `month` = '03') LOCATION 's3://REPLACE_ME_BUCKET/REPLACE_ME_PREFIX/REPLACE_ME_REPORT_NAME/REPLACE_ME_REPORT_NAME/year=2024/month=03/'
--   ;
--
-- The LOCATION of each partition must be the exact S3 prefix containing that
-- month's Parquet files, with a trailing slash. If it is wrong the partition
-- exists and returns zero rows - again, silently.
--
-- ----------------------------------------------------------------------------
-- OPTION C (best if you control the table): PARTITION PROJECTION
-- ----------------------------------------------------------------------------
-- Athena computes partition values and locations from table properties
-- instead of looking them up in the Glue Data Catalog. No partition
-- registration, no MSCK REPAIR, no GetPartitions call. See
-- ../docs/COST-CONTROL-ATHENA.md section 7 for the full explanation and the
-- failure modes (out-of-range queries return zero rows with no error;
-- enabling projection makes Athena ignore registered partition metadata).
--
--   ALTER TABLE `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE`
--   SET TBLPROPERTIES (
--       'projection.enabled'          = 'true',
--       'projection.year.type'        = 'integer',
--       'projection.year.range'       = '2022,2030',
--       'projection.year.digits'      = '4',
--       'projection.month.type'       = 'integer',
--       'projection.month.range'      = '1,12',
--       'projection.month.digits'     = '2',
--       'storage.location.template'   = 's3://REPLACE_ME_BUCKET/REPLACE_ME_PREFIX/REPLACE_ME_REPORT_NAME/REPLACE_ME_REPORT_NAME/year=${year}/month=${month}/'
--   );
--
-- TWO THINGS TO GET RIGHT:
--   * month.digits = '2' is what renders 03 rather than 3. If your S3 layout
--     uses unpadded months, set month.type = 'integer' with no digits and
--     adjust the queries' 'MM' literals accordingly.
--   * The range must cover every period you will query. A query outside the
--     range returns zero rows and no error.
--
-- To back out: SET TBLPROPERTIES ('projection.enabled' = 'false').
--
-- ============================================================================
-- STEP 3 - ADD COLUMNS YOUR REPORT HAS AND THIS DDL DOES NOT
-- ============================================================================
-- Do this from the real column list, never from memory. Get yours with:
--
--   DESCRIBE `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE`;
--   SHOW COLUMNS IN `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE`;
--
-- then add only what is missing, e.g.
--
--   ALTER TABLE `REPLACE_ME_DATABASE`.`REPLACE_ME_TABLE`
--   ADD COLUMNS (
--       `line_item_usage_account_name`  string,
--       `product_tenancy`               string,
--       `product_operating_system`      string,
--       `resource_tags_user_cost_center` string,
--       `cost_category_team`            string
--   );
--
-- COST WARNING: ALTER TABLE ... ADD COLUMNS changes the Glue Data Catalog
-- metadata, not the data. It does not read your CUR. It is safe.
-- The DANGEROUS operation is the query you run next.
--
-- NOTE ON TYPES: a column declared with the wrong type will read as NULL or
-- error rather than fail loudly. Use the types in this DDL as a guide -
-- *_cost, *_rate (double in the report), *_amount, *_fee, *_factor and
-- *_quantity are numeric; *_start_date / *_end_date / *_time on the line
-- item and bill families are timestamp; the resource_tags_*, cost_category_*
-- and product_* families are string. Verify against AWS's own DDL for your
-- report where you can (see setup/README.md).
-- ============================================================================
