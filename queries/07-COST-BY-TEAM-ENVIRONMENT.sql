-- ============================================================================
-- Q07  COST PER TEAM AND ENVIRONMENT, WITH AN EXPLICIT UNALLOCATED BUCKET
-- ============================================================================
--
-- QUESTION
--   What does each team spend, split by environment, and what fraction of
--   the bill is genuinely unallocated?
--
-- WHAT IT RETURNS
--   One row per (team, environment) pair with amortized cost, an
--   allocated_vs_unallocated label, account and resource counts, and
--   share_of_period_pct. Rows missing either tag land in '(no team)' /
--   '(no env)' cells rather than disappearing from the report.
--
-- WHY TWO TAGS AND NOT TWENTY
--   Every extra tag column in a GROUP BY is another column read for every row
--   and another dimension in the shuffle. Two reads cleanly. If you need a
--   genuine multi-tag hierarchy, the supported answer is cost categories:
--   define the rules once in Billing and read the cost_category_* columns, so
--   that every query applies the same logic instead of each query
--   re-implementing its own fallback chain.
--
--   The fallback here is deliberately shallow: team tag, else environment
--   tag, else '(no team)'. Nesting a fourth level usually means the
--   allocation rules are not settled, and a SQL query is the wrong place to
--   settle them.
--
-- BYTES SCANNED
--   Same scale as Q01, slightly wider - the two tag columns plus the
--   grouping columns. One month.
--
-- REQUIRED TABLE / PARTITION ASSUMPTIONS
--   * Partitions year / month as in Q01.
--   * resource_tags_user_team and resource_tags_user_environment must exist,
--     which means the report was configured with those tag keys. This is the
--     most common reason a tag query fails - see Q06's header for how to
--     check with SHOW COLUMNS.
--   * No cost_category_* column is referenced. If you have cost categories
--     defined, add them here deliberately - do not assume this query reads
--     them.
--
-- CAVEATS
--   * A resource has at most one value per tag key, so a (team, env) cell is
--     unambiguous. A resource that matches two DIFFERENT cost categories will
--     appear twice, because cost categories are additive by design. Do not
--     sum a cost-category breakdown and expect the invoice.
--   * Untagged spend is concentrated in exactly the services you cannot tag.
--     A team's unallocated share therefore looks worse for teams that lean on
--     managed services. That is a property of CUR, not of this query.
--   * The 'allocated' label only means "at least one of the two tags is
--     present". It is not a quality score - a resource tagged with team but
--     no environment is still an allocation gap at the environment level.
-- ============================================================================

SELECT
    COALESCE(NULLIF(resource_tags_user_team, ''), '(no team)')            AS team,
    COALESCE(NULLIF(resource_tags_user_environment, ''), '(no env)')      AS environment,
    CASE
        WHEN COALESCE(NULLIF(resource_tags_user_team, ''),
                      NULLIF(resource_tags_user_environment, '')) IS NULL
        THEN 'unallocated'
        ELSE 'allocated'
    END                                                                   AS allocated_vs_unallocated,
    ROUND(SUM(
              COALESCE(line_item_unblended_cost, 0)
            + COALESCE(reservation_amortized_upfront_fee_for_billing_period, 0)
            + COALESCE(reservation_recurring_fee_for_usage, 0)
          ), 2)                                                           AS amortized_cost,
    COUNT(DISTINCT line_item_usage_account_id)                            AS accounts,
    COUNT(*)                                                              AS line_items,
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
    , 2)                                                                  AS share_of_period_pct
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year  = 'REPLACE_ME_YYYY'
  AND month = 'REPLACE_ME_MONTH'
  AND line_item_usage_start_date >= TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
  AND line_item_usage_start_date <  TIMESTAMP '<YYYY-MM-DDT00:00:00Z'
GROUP BY 1, 2, 3
ORDER BY amortized_cost DESC
;
