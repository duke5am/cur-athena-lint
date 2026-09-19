# cur-athena-lint

Check AWS **Cost and Usage Report** Athena SQL for the mistakes that inflate your
query bill and silently produce wrong numbers — without an AWS account.

```
$ python3 verify_pack.py
sqlglot      : 26.16.4   dialect: athena
Verified cols: 80 names on the allow-list

[PASS] P02 every .sql file parses as Athena dialect          17/17 parsed; no errors
[PASS] P03 no query uses SELECT *                     10 COUNT(*) aggregates, all fine
[PASS] P04 every statement reading the CUR table filters on year AND month
[PASS] P04b no CTE or subquery reads the CUR table without a partition filter either
[PASS] P06 every column reference is on the verified column allow-list
[PASS] P07 every column the queries use is also declared in setup/create_table.sql
RESULT: 15/15 structural checks passed, 0 failed
```

## Why CUR SQL goes wrong

The CUR table is a **100+ column monster** where cost is split across many columns
and the obvious one is usually the wrong one. Three failures are common:

**You scan a year of data to answer a question about one month.** The table is
partitioned by `year`/`month`, and a missing predicate means Athena reads
everything. This checker requires **both** predicates on every CUR-reading
statement — including inside CTEs, because a subquery that scans unpruned is just
as expensive.

**You use the wrong cost column.** `line_item_unblended_cost` is not the number
you want for most questions, and for EC2/RDS line items with a reservation
applied it is **0** — the cost lives in `reservation_effective_cost`. Summing the
wrong column gives you a confident, wrong total.

**You double-count a discount.** Savings Plan covered usage is recorded at
on-demand list price and offset by a separate `SavingsPlanNegation` line. Count one
without the other and your January total is inflated — by exactly the negation
amount, which can be substantial.

## What the checker enforces

- every `.sql` file parsed with **sqlglot's `athena` dialect** — a real grammar, not a regex
- no `SELECT *` (with `COUNT(*)` correctly allowed — it reads no columns)
- `year` AND `month` on every CUR-reading statement, including CTEs and subqueries
- no function wrapping a partition column in `WHERE` (that defeats pruning)
- every column reference against an **80-name verified allow-list**
- internal consistency between the queries and the shipped `CREATE EXTERNAL TABLE`
- a header comment with a bytes-scanned warning on every query

## What it does NOT check

Stated by the tool itself, not buried: **no query here was executed against
Athena**, no CUR data was read from S3, and no output was compared to Cost
Explorer. Column *existence* is asserted from AWS documentation, not from a live
`DESCRIBE`. Bytes scanned and cost are not measured.

Only your own `INFORMATION_SCHEMA` can tell you a column exists in your dataset.

## The queries

Fifteen analysis queries answering one question each — cost by service, account,
resource and tag; month-over-month movers with contribution to change; anomaly
detection against a trailing baseline; RI/SP coverage and unused commitment; data
transfer; S3 storage and requests; and a partition-pruned variant that proves
pruning changes cost, not answers.

`CUR-SCHEMA.md` explains the `line_item_*` cost columns and the
`line_item_line_item_type` values that decide whether you double-count.

## Setup

```bash
apt install python3-sqlglot        # or: pip install sqlglot
python3 verify_pack.py
```

Requires `sqlglot` only. Refresh the DDL with `setup/create_table.sql`.

## The full pack

The paid pack adds `COST-CONTROL-ATHENA.md`, `VALIDATION.md` (how to prove a query
against Cost Explorer before trusting it), the reconciliation query, and the
synthetic-CUR validation harness.

<!-- RELATED:START -->

## Related tools

- **[bank-csv-reconcile](https://github.com/duke5am/bank-csv-reconcile)** — Turn a bank CSV or Excel export into one clean table and reconcile the running balance, so a dropped row shows up instead of silently changing totals.
  *(if you were searching for "bank statement csv to excel")*
- **[ga4-bigquery-lint](https://github.com/duke5am/ga4-bigquery-lint)** — Lint GA4 BigQuery SQL for the session, event_params and cost mistakes that quietly give you wrong numbers, using sqlglot's real BigQuery grammar.
  *(if you were searching for "ga4 bigquery queries")*

All 28 tools in this set, grouped by what they check: **[dev-tools-index](https://duke5am.github.io/dev-tools-index/)**

If you arrived here searching for one of these, this is the tool: **aws cur athena query** · **cost and usage report sql** · **athena partition pruning cost** · **aws cost anomaly query**

<!-- RELATED:END -->

→ More developer tooling like this: **[duke5am.gumroad.com](https://duke5am.gumroad.com)** <!-- GUMROAD-LINK -->
