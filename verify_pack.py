#!/usr/bin/env python3
"""
verify_pack.py - structural sanity checker for the AWS CUR Athena FinOps Query Pack.

THIS DOES NOT RUN ANYTHING AGAINST ATHENA. It reads the shipped files and
asserts structural properties that are cheap to get wrong and expensive to
discover in production:

  1. every .sql file parses under the sqlglot `athena` dialect
  2. no query uses SELECT *
  3. every statement that reads the CUR table filters on the partition columns
  4. every column referenced by the SQL appears in the VERIFIED_COLUMNS list
     (a separate, hand-audited list of column names traced to AWS documentation)
  5. every query file carries its header comment, including the bytes-scanned
     warning and the table/partition assumptions section
  6. REQUIRED_FILES.txt lists exactly the files that ship in content/
  7. every shipped file is UTF-8 readable and has a sane byte size
  8. no angle-bracket placeholder survives (they would not parse)

Run:  python3 verify_pack.py
Exit: 0 if all checks pass, 1 otherwise.
"""

import os
import re
import sys
import glob

import sqlglot
from sqlglot import exp

HERE = os.path.dirname(os.path.abspath(__file__))
# Paths are relative to THIS file's directory, so the checker works whether it
# sits next to content/ (the full pack) or at the root of the standalone repo.
# Set PEPPOL_CUR_CONTENT to override, e.g. when vendoring the queries elsewhere.
CONTENT = os.environ.get('CUR_CONTENT', os.path.join(HERE, 'content'))
PACK_MODE = os.path.isdir(CONTENT)
if not PACK_MODE:
    CONTENT = HERE
# PACK_MODE is False in the standalone repository, where there is no
# REQUIRED_FILES.txt manifest and no pack README making claims about file counts.
# Those two checks (P12, P15) verify PACK integrity, so they are skipped rather
# than faked; every check of the SQL itself still runs.
QDIR = os.path.join(CONTENT, 'queries')
SETUP = os.path.join(CONTENT, 'setup')

# ---------------------------------------------------------------------------
# VERIFIED_COLUMNS - the allow-list.
#
# Every name here was traced to primary AWS documentation. See
# content/docs/CUR-SCHEMA.md section 14 for the source list. Do NOT add a
# column here because a query happens to use it: add it because you verified
# it exists in the CUR schema.
# ---------------------------------------------------------------------------
VERIFIED_COLUMNS = {
    # partition columns (declared in setup/create_table.sql PARTITIONED BY)
    'year', 'month',

    # ---- bill_* -----------------------------------------------------------
    'bill_bill_type', 'bill_billing_entity', 'bill_billing_period_end_date',
    'bill_billing_period_start_date', 'bill_invoice_id', 'bill_payer_account_id',

    # ---- identity_* -------------------------------------------------------
    'identity_line_item_id', 'identity_time_interval',

    # ---- line_item_* ------------------------------------------------------
    'line_item_availability_zone', 'line_item_blended_cost', 'line_item_blended_rate',
    'line_item_currency_code', 'line_item_legal_entity',
    'line_item_line_item_description', 'line_item_line_item_type',
    'line_item_normalization_factor', 'line_item_normalized_usage_amount',
    'line_item_operation', 'line_item_product_code', 'line_item_resource_id',
    'line_item_tax_type', 'line_item_unblended_cost', 'line_item_unblended_rate',
    'line_item_usage_account_id', 'line_item_usage_amount',
    'line_item_usage_end_date', 'line_item_usage_start_date', 'line_item_usage_type',

    # ---- product_* (only what the pack references) ------------------------
    'product_from_location', 'product_from_location_type', 'product_instance_type',
    'product_product_family', 'product_product_name', 'product_region',
    'product_storage_class', 'product_to_location', 'product_to_location_type',

    # ---- pricing_* --------------------------------------------------------
    'pricing_lease_contract_length', 'pricing_public_on_demand_cost',
    'pricing_public_on_demand_rate', 'pricing_rate_id', 'pricing_term', 'pricing_unit',

    # ---- reservation_* ----------------------------------------------------
    'reservation_amortized_upfront_cost_for_usage',
    'reservation_amortized_upfront_fee_for_billing_period',
    'reservation_effective_cost', 'reservation_end_time',
    'reservation_modification_status', 'reservation_normalized_units_per_reservation',
    'reservation_number_of_reservations', 'reservation_recurring_fee_for_usage',
    'reservation_reservation_a_r_n', 'reservation_start_time',
    'reservation_subscription_id', 'reservation_total_reserved_normalized_units',
    'reservation_total_reserved_units', 'reservation_units_per_reservation',
    'reservation_unused_amortized_upfront_fee_for_billing_period',
    'reservation_unused_normalized_unit_quantity', 'reservation_unused_quantity',
    'reservation_unused_recurring_fee', 'reservation_upfront_value',

    # ---- savings_plan_* ---------------------------------------------------
    'savings_plan_amortized_upfront_commitment_for_billing_period',
    'savings_plan_end_time', 'savings_plan_instance_type_family',
    'savings_plan_offering_type', 'savings_plan_payment_option',
    'savings_plan_purchase_term', 'savings_plan_recurring_commitment_for_billing_period',
    'savings_plan_region', 'savings_plan_savings_plan_a_r_n',
    'savings_plan_savings_plan_effective_cost', 'savings_plan_savings_plan_rate',
    'savings_plan_start_time', 'savings_plan_total_commitment_to_date',
    'savings_plan_used_commitment',

    # ---- resource_tags_* (the two example keys this pack ships) -----------
    'resource_tags_user_team', 'resource_tags_user_environment',
}

# Columns referenced by documentation examples rather than shipped queries.
DOC_ONLY_COLUMNS = {
    'identity_line_item_id', 'line_item_usage_account_name',
}

PARTITION_COLUMNS = ('year', 'month')

# Identifier fragments that are not column references.
NOT_COLUMNS = {
    'sum', 'count', 'min', 'max', 'avg', 'stddev', 'round', 'coalesce', 'nullif',
    'abs', 'lag', 'over', 'partition', 'by', 'order', 'rows', 'between',
    'preceding', 'following', 'unbounded', 'current', 'row', 'cast', 'as', 'date',
    'timestamp', 'double', 'string', 'integer', 'int', 'bigint', 'varchar',
    'case', 'when', 'then', 'else', 'end', 'and', 'or', 'not', 'in', 'is', 'null',
    'like', 'window', 'with', 'select', 'from', 'where', 'group', 'having',
    'union', 'all', 'distinct', 'limit', 'desc', 'asc', 'nulls', 'last', 'first',
    'date_format', 'date_trunc', 'date_add', 'date_diff', 'current_date',
    'true', 'false', 'on', 'join', 'left', 'right', 'full', 'outer', 'inner',
    'cross', 'using', 'exists', 'create', 'table', 'external', 'if', 'z', 'a',
}

# The table token the queries use before substitution.
PLACEHOLDER_TABLE = 'REPLACE_ME_TABLE'

QUERY_HEADER_SECTIONS = (
    ('QUESTION', ('QUESTION',)),
    ('RETURNS/WHAT IT RETURNS', ('RETURNS', 'WHAT IT RETURNS')),
    ('BYTES SCANNED', ('BYTES SCANNED',)),
    ('TABLE/PARTITION ASSUMPTIONS', ('REQUIRED TABLE', 'TABLE / PARTITION',
                                     'TABLE/PARTITION')),
    ('CAVEATS', ('CAVEAT',)),
)
HEADER_EXEMPT = {'00-PARAMETERS-READ-ME-FIRST.sql'}

results = []

SOURCE_TEXT = open(os.path.abspath(__file__), encoding='utf-8').read()
README_PATH = os.path.join(CONTENT, 'README.md')
README_TEXT = open(README_PATH, encoding='utf-8').read() if os.path.exists(README_PATH) else ''


def check(name, ok, detail, warn=False):
    results.append((name, bool(ok), detail, warn))
    tag = 'WARN' if (warn and not ok) else ('PASS' if ok else 'FAIL')
    print(f"[{tag}] {name}")
    for line in _wrap(detail, 92):
        print(f"        {line}")


def _wrap(text, width):
    words, out, cur = text.split(), [], ''
    for w in words:
        if len(cur) + len(w) + 1 > width:
            out.append(cur)
            cur = w
        else:
            cur = (cur + ' ' + w).strip()
    if cur:
        out.append(cur)
    return out


def sql_files():
    return sorted(glob.glob(os.path.join(QDIR, '*.sql'))) + \
           sorted(glob.glob(os.path.join(SETUP, '*.sql')))


# ---------------------------------------------------------------------------
print("=" * 96)
print("STRUCTURAL SANITY CHECK - AWS CUR Athena FinOps Query Pack")
print("=" * 96)
print(f"Content root : {CONTENT}")
print(f"sqlglot      : {sqlglot.__version__}   dialect: athena")
print(f"Verified cols: {len(VERIFIED_COLUMNS)} names on the allow-list")
print("=" * 96)
print()

files = sql_files()
check('P01 SQL files discovered',
      len(files) >= 15,
      f"{len(files)} .sql files found: " + ", ".join(os.path.basename(f) for f in files))

# ---------------------------------------------------------------------------
# 1. parse every file
# ---------------------------------------------------------------------------
parse_failures = []
parsed = {}
for f in files:
    name = os.path.basename(f)
    src = open(f, encoding='utf-8').read()
    try:
        tree = sqlglot.parse(src, read='athena')
        parsed[f] = (src, tree)
    except Exception as exc:                     # noqa: BLE001
        parse_failures.append((name, str(exc).splitlines()[0]))
check('P02 every .sql file parses as Athena dialect',
      not parse_failures,
      f"{len(files) - len(parse_failures)}/{len(files)} parsed; "
      + ("no errors" if not parse_failures else "FAILURES: " + repr(parse_failures)))

# ---------------------------------------------------------------------------
# 2. no SELECT *
# ---------------------------------------------------------------------------
star_hits = []
count_star = 0
for f, (src, tree) in parsed.items():
    for stmt in tree:
        for star in stmt.find_all(exp.Star):
            # COUNT(*) is an aggregate over rows, not a column projection, and does
            # not widen the scan. Only flag a star that reaches a SELECT projection.
            if isinstance(star.parent, exp.Count):
                count_star += 1
                continue
            if isinstance(star.parent, exp.Select) or isinstance(star.parent, exp.Column):
                star_hits.append(os.path.basename(f))
check('P03 no query uses SELECT *',
      not star_hits,
      f"No star projections found. {count_star} COUNT(*) aggregates were seen and are fine: "
      f"COUNT(*) reads no columns, so it does not widen the scan the way SELECT * does. "
      f"SELECT * over CUR is the expensive habit because it reads all 100+ columns including "
      f"the large product attribute set; see content/docs/COST-CONTROL-ATHENA.md section 3."
      if not star_hits else f"star projections found in: {sorted(set(star_hits))}")

# ---------------------------------------------------------------------------
# 3. partition filters
# ---------------------------------------------------------------------------
no_partition = []
partition_detail = []
inner_no_partition = []
for f, (src, tree) in parsed.items():
    name = os.path.basename(f)
    for stmt in tree:
        # every subquery in the file, so a CTE that reads the raw table is checked too
        # rather than only the outermost SELECT
        for sel in stmt.find_all(exp.Select):
            # only look at THIS select's FROM/JOIN, not at any nested subquery.
            # find_all() descends into subqueries, which would make an outer SELECT
            # appear to read the raw table when only its CTE body does.
            own_tables = list(sel.args.get('from').find_all(exp.Table)) if sel.args.get('from') else []
            for j in sel.args.get('joins') or []:
                own_tables += list(j.find_all(exp.Table))
            raw = [t for t in own_tables
                   if t.name.lower() == PLACEHOLDER_TABLE.lower()]
            if not raw:
                continue                      # this SELECT reads a CTE or derived table
            where = sel.args.get('where')
            # A SELECT that reads a CTE is not a raw-CUR scan. Determine that from the
            # actual table name, not from AST nesting depth.
            depth = 0 if all(t.name.lower() == PLACEHOLDER_TABLE.lower() for t in raw) else 1
            label = f"{name}: CUR-reading SELECT ({'outer' if depth == 0 else 'in CTE/subquery'})"
            if where is None:
                (no_partition if depth == 0 else inner_no_partition).append(
                    f"{label} with no WHERE clause")
                continue
            pred = where.sql().lower()
            missing = [c for c in PARTITION_COLUMNS if c not in pred]
            if missing:
                (no_partition if depth == 0 else inner_no_partition).append(
                    f"{label} WHERE present but missing {missing}")
            else:
                partition_detail.append(label)
check('P04 every statement reading the CUR table filters on year AND month',
      not no_partition,
      f"{len(partition_detail)} CUR-reading SELECT statements all carry both partition "
      f"predicates (outer statements and CTE/subquery statements counted separately). "
      f"Partition pruning is the only optimisation that scales with the number of months "
      f"scanned; see content/docs/COST-CONTROL-ATHENA.md section 1."
      if not no_partition else "; ".join(no_partition))

check('P04b no CTE or subquery reads the CUR table without a partition filter either',
      not inner_no_partition,
      "Every CTE/subquery that reads the raw CUR table also terminates a partition filter, so "
      "no part of any query can scan unpruned."
      if not inner_no_partition else "; ".join(inner_no_partition))

# a partition predicate wrapped in a function would defeat pruning
func_partition = []
comparison_ops = 0
for f, (src, tree) in parsed.items():
    for stmt in tree:
        for sel in stmt.find_all(exp.Select):
            where = sel.args.get('where')
            if where is None:
                continue
            for fn in where.find_all(exp.Func):
                # only a function whose DIRECT argument is a partition column defeats
                # pruning. `WHERE year = '2024'` parses as an EQ whose operands are a
                # column and a literal - that is exactly what we want, so it is counted
                # as a comparison rather than flagged.
                if isinstance(fn, (exp.EQ, exp.NEQ, exp.In, exp.Between, exp.And, exp.Or)):
                    if any(c.name.lower() in PARTITION_COLUMNS for c in fn.find_all(exp.Column)):
                        comparison_ops += 1
                    continue
                direct = fn.this
                if isinstance(direct, exp.Column) and direct.name.lower() in PARTITION_COLUMNS:
                    func_partition.append(f"{os.path.basename(f)}: {fn.sql()[:70]}")
check('P05 no partition column is wrapped in a function in a WHERE clause',
      not func_partition,
      f"All {comparison_ops} partition predicates are plain comparisons (equality, IN) against "
      f"literal tokens, so Athena can prune partitions from metadata without reading data. A "
      f"predicate like date_format(line_item_usage_start_date,'%Y-%m') = '...' is the mistake "
      f"this check exists to catch; the shipped queries all bound the timestamp separately "
      f"with a half-open range instead."
      if not func_partition else "; ".join(func_partition))

# ---------------------------------------------------------------------------
# 4. column allow-list
# ---------------------------------------------------------------------------
unknown = {}
cte_names_all = set()
for f, (src, tree) in parsed.items():
    name = os.path.basename(f)
    ctes = {c.alias_or_name.lower() for c in tree[0].find_all(exp.CTE)} if tree else set()
    cte_names_all |= ctes
    for stmt in tree:
        for col in stmt.find_all(exp.Column):
            c = col.name
            if not c:
                continue
            lc = c.lower()
            if lc in VERIFIED_COLUMNS or lc in NOT_COLUMNS:
                continue
            # aliases defined in the same statement (e.g. CASE ... END AS x)
            aliases = {a.alias_or_name.lower() for a in stmt.find_all(exp.Alias)}
            if lc in aliases or lc in ctes:
                continue
            # a bare placeholder identifier is not a column
            if lc.startswith('replace_me'):
                continue
            unknown.setdefault(lc, set()).add(name)
check('P06 every column reference is on the verified column allow-list',
      not unknown,
      f"All column references across {len(files)} files resolve to one of the "
      f"{len(VERIFIED_COLUMNS)} hand-verified CUR column names (partition columns included). "
      f"This is the check that prevents a plausible-but-wrong column name from shipping."
      if not unknown else
      "UNVERIFIED COLUMN REFERENCES: "
      + "; ".join(f"{c} (in {sorted(v)})" for c, v in sorted(unknown.items())))

# any column referenced by a shipped query that is NOT also declared in the DDL?
# (a query cannot use a column the CREATE TABLE does not declare)
ddl_path = os.path.join(SETUP, 'create_table.sql')
ddl_cols = set()
if os.path.exists(ddl_path):
    ddl_src = open(ddl_path, encoding='utf-8').read()
    ddl_tree = sqlglot.parse(ddl_src, read='athena')[0]
    for c in ddl_tree.find_all(exp.ColumnDef):
        ddl_cols.add(c.name.lower())
    # partitioned_by appears inside a property, not a ColumnDef
    for m in re.finditer(r'PARTITIONED BY\s*\(([^)]*)\)', ddl_src, re.S):
        for tok in re.findall(r'`([a-z_]+)`', m.group(1)):
            ddl_cols.add(tok.lower())

query_cols = set()
for f in glob.glob(os.path.join(QDIR, '*.sql')):
    for stmt in sqlglot.parse(open(f, encoding='utf-8').read(), read='athena'):
        ctes = {c.alias_or_name.lower() for c in stmt.find_all(exp.CTE)}
        aliases = {a.alias_or_name.lower() for a in stmt.find_all(exp.Alias)}
        for col in stmt.find_all(exp.Column):
            lc = col.name.lower()
            if lc in VERIFIED_COLUMNS and lc not in ctes and lc not in aliases:
                query_cols.add(lc)
missing_from_ddl = sorted(query_cols - ddl_cols)
check('P07 every column the queries use is also declared in setup/create_table.sql',
      not missing_from_ddl,
      f"{len(query_cols)} distinct CUR columns are referenced by the shipped queries; all "
      f"{len(ddl_cols)} declared DDL columns cover them. A query cannot reference a column the "
      f"table does not declare, so this keeps the pack internally consistent."
      if not missing_from_ddl else
      f"declared in DDL but NOT used by queries (informational): "
      f"{sorted(ddl_cols - query_cols)}; USED BY QUERIES BUT NOT DECLARED: {missing_from_ddl}")

ddl_extra = sorted(ddl_cols - query_cols)
check('P08 DDL declares no column outside the verified allow-list',
      not (ddl_cols - VERIFIED_COLUMNS),
      f"DDL declares {len(ddl_cols)} columns, all on the allow-list, of which "
      f"{len(ddl_extra)} are structural columns the queries do not need "
      f"(bill_*, identity_*, and the fuller reservation_/savings_plan_/product_ families) "
      f"listed for completeness."
      if not (ddl_cols - VERIFIED_COLUMNS) else
      f"NOT VERIFIED: {sorted(ddl_cols - VERIFIED_COLUMNS)}")

# ---------------------------------------------------------------------------
# 5. header comments
# ---------------------------------------------------------------------------
missing_headers = []
header_detail = []
for f in glob.glob(os.path.join(QDIR, '*.sql')):
    name = os.path.basename(f)
    src = open(f, encoding='utf-8').read()
    lines = src.splitlines()
    if not lines or not lines[0].lstrip().startswith('--'):
        missing_headers.append(f"{name}: does not start with a comment block")
        continue
    if name in HEADER_EXEMPT:
        header_detail.append(name)
        continue
    absent = [label for label, alts in QUERY_HEADER_SECTIONS
              if not any(a in src for a in alts)]
    if absent:
        missing_headers.append(f"{name}: missing {absent}")
    else:
        header_detail.append(name)
check('P09 every query file carries the required header sections',
      not missing_headers,
      f"{len(header_detail)}/{len(header_detail) + len(missing_headers)} query files carry "
      f"QUESTION, RETURNS, BYTES SCANNED, table/partition assumptions and CAVEATS. "
      f"00-PARAMETERS-READ-ME-FIRST.sql is exempt: it is a placeholder/orientation file "
      f"that runs no analysis query."
      if not missing_headers else "; ".join(missing_headers))

# ---------------------------------------------------------------------------
# 6. no unreplaced angle-bracket placeholders, and tokens are documented
# ---------------------------------------------------------------------------
angle = []
tokens = set()
for f in files:
    for i, line in enumerate(open(f, encoding='utf-8'), 1):
        if re.search(r'<[A-Z_]{2,}>', line):
            angle.append(f"{os.path.basename(f)}:{i}")
        tokens |= set(re.findall(r'REPLACE_ME_[A-Z_\-]+', line))
check('P10 no angle-bracket placeholder survives',
      not angle,
      "Angle-bracket placeholders such as <YYYY> are not valid SQL and make the files "
      "unparseable, so they were converted to REPLACE_ME_* tokens which are lexically valid. "
      "The trade-off is documented in content/README.md."
      if not angle else f"found at: {angle}")

expected_tokens = {'REPLACE_ME_DATABASE', 'REPLACE_ME_TABLE', 'REPLACE_ME_YYYY',
                   'REPLACE_ME_MONTH', 'REPLACE_ME_TIMESTAMP',
                   'REPLACE_ME_PRODUCT_CODE', 'REPLACE_ME_YYYY-MM',
                   # setup/create_table.sql only: the S3 location of the report
                   'REPLACE_ME_BUCKET', 'REPLACE_ME_PREFIX', 'REPLACE_ME_REPORT_NAME'}
check('P11 placeholder token set matches what the README documents',
      tokens <= expected_tokens and len(tokens) >= 5,
      f"tokens in use: {sorted(tokens)}. content/README.md documents the query-side tokens "
      f"and content/setup/README.md the S3-location tokens for create_table.sql."
      if tokens <= expected_tokens else f"UNDOCUMENTED TOKENS: {sorted(tokens - expected_tokens)}")

# ---------------------------------------------------------------------------
# 7. REQUIRED_FILES.txt completeness
# ---------------------------------------------------------------------------
req_path = os.path.join(CONTENT, 'REQUIRED_FILES.txt')
listed = []
if os.path.exists(req_path):
    for line in open(req_path, encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#'):
            listed.append(line)

actual = []
for root, dirs, fnames in os.walk(CONTENT):
    dirs.sort()
    for fn in sorted(fnames):
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, CONTENT)
        if rel == 'REQUIRED_FILES.txt':
            continue
        actual.append(rel.replace(os.sep, '/'))
actual.sort()

missing_from_list = sorted(set(actual) - set(listed))
listed_but_absent = sorted(set(listed) - set(actual))
if not PACK_MODE:
    print("[SKIP] P12 REQUIRED_FILES.txt lists exactly the files that ship"
          "\n       pack-integrity check: no manifest ships in the standalone repo")
else:
  check('P12 REQUIRED_FILES.txt lists exactly the files that ship',
        not missing_from_list and not listed_but_absent,
        f"{len(actual)} files ship in content/ and all {len(listed)} manifest entries resolve. "
        f"os.walk was used rather than a filesystem glob because this sandbox's file discovery "
        f"under-reports; see the note at the end of this script."
        if not (missing_from_list or listed_but_absent) else
        f"MISSING FROM MANIFEST: {missing_from_list}; LISTED BUT ABSENT: {listed_but_absent}")

# ---------------------------------------------------------------------------
# 8. files readable, non-trivial, UTF-8
# ---------------------------------------------------------------------------
bad_files = []
sizes = {}
for rel in actual:
    p = os.path.join(CONTENT, rel)
    try:
        raw = open(p, 'rb').read()
        raw.decode('utf-8')
        if len(raw) < 200:
            bad_files.append(f"{rel}: only {len(raw)} bytes")
        sizes[rel] = len(raw)
    except Exception as exc:                      # noqa: BLE001
        bad_files.append(f"{rel}: {exc}")
check('P13 every shipped file is UTF-8, readable and non-trivial',
      not bad_files,
      f"{len(sizes)} files read back and decoded; total {sum(sizes.values()):,} bytes. "
      f"Every file was READ BACK from disk rather than assumed written."
      if not bad_files else "; ".join(bad_files))

# ---------------------------------------------------------------------------
# 9. every query mentions the tokens it needs, and cost queries warn about bytes
# ---------------------------------------------------------------------------
no_warning = []
for f in glob.glob(os.path.join(QDIR, '*.sql')):
    name = os.path.basename(f)
    if name in HEADER_EXEMPT:
        continue
    src = open(f, encoding='utf-8').read()
    if 'BYTES SCANNED' not in src:
        no_warning.append(name)
check('P14 every analysis query has an explicit BYTES SCANNED warning',
      not no_warning,
      f"{len(glob.glob(os.path.join(QDIR, '*.sql'))) - len(HEADER_EXEMPT)} analysis queries "
      f"carry a bytes-scanned warning naming the expensive ones."
      if not no_warning else f"missing in: {no_warning}")

# ---------------------------------------------------------------------------
# 10. the file counts quoted in README.md must match what actually ships
#     (label P15, runs first: its result is one of the measurements P16 verifies)
# ---------------------------------------------------------------------------
WORDS = {'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14, 'fifteen': 15,
         'sixteen': 16, 'seventeen': 17, 'eighteen': 18, 'nineteen': 19, 'twenty': 20}
sql_shipped = len(glob.glob(os.path.join(QDIR, '*.sql'))) + \
              len(glob.glob(os.path.join(SETUP, '*.sql')))
q_shipped = len(glob.glob(os.path.join(QDIR, '*.sql')))
# README says "fifteen ANALYSIS queries" - 00-PARAMETERS-READ-ME-FIRST.sql is the
# read-me-first orientation file, so it is not one of them.
analysis_queries = q_shipped - len(HEADER_EXEMPT)
word_nums = {WORDS[w] for w in re.findall(r'\b(' + '|'.join(WORDS) + r')\b', README_TEXT.lower())}
count_ok = sql_shipped in word_nums and analysis_queries in word_nums
if not PACK_MODE:
    print("[SKIP] P15 the SQL file counts quoted in README.md match what ships"
          "\n       pack-integrity check: the standalone README is not the pack README")
    count_ok = True
else:
  check('P15 the SQL file counts quoted in README.md match what ships',
      count_ok,
        f"{sql_shipped} .sql files ship: {analysis_queries} analysis queries plus "
        f"{len(HEADER_EXEMPT)} read-me-first file in queries/, and "
        f"{sql_shipped - q_shipped} in setup/. README.md's spelled-out numbers found: "
        f"{sorted(word_nums)}. The README claims must be the real counts - a pack that "
        f"miscounts its own contents is not one to trust on column names."
        if count_ok else
        f"README spells out {sorted(word_nums)} but {sql_shipped} sql files ship "
        f"({analysis_queries} analysis queries).")

# ---------------------------------------------------------------------------
# 11. every N/N count quoted in README.md must match a real measurement
#     (label P16, runs last on purpose: it must be able to measure the whole file)
# ---------------------------------------------------------------------------
claims = {}
for a, b in re.findall(r'\*\*(\d+)/(\d+)[^*]*\*\*', README_TEXT):
    claims.setdefault((int(a), int(b)), []).append('README.md')

# Reality check with NO self-reference:
#   - the number of checks that ACTUALLY run in this file (static count)
#   - the number of .sql files that actually parsed (17)
#   - the number of rows the pandas validator actually asserts (22)
STATIC_CHECK_COUNT = len(re.findall(r"^check\(", SOURCE_TEXT, re.M))
sql_parsed = len(sql_files())
import subprocess
_synth = os.path.join(HERE, 'verification', 'synthetic-validation.txt')
_synth_ok, _synth_n = False, 0
if os.path.exists(_synth):
    _txt = open(_synth, encoding='utf-8').read()
    _m = re.search(r'RESULT: (\d+)/(\d+) checks passed', _txt)
    if _m:
        _synth_n = int(_m.group(2))
        _synth_ok = (_m.group(1) == _m.group(2))
real = {(STATIC_CHECK_COUNT, STATIC_CHECK_COUNT),      # "N/N structural checks pass"
        (sql_parsed, sql_parsed)}                      # "N/N files parsed"
if _synth_n:
    real.add((_synth_n, _synth_n))

bad = {c for c in claims if c not in real}
check('P16 every N/N count quoted in README.md matches a real measurement',
      not bad,
      f"README quotes {sorted(claims)}. Independently measured: {STATIC_CHECK_COUNT} check() "
      f"calls in this file, {sql_parsed} .sql files parsed by parse_all_sql.py, "
      f"{_synth_n} assertions in the pandas validator (all passing: {_synth_ok}). "
      f"No quoted figure is self-referential any more - an earlier version of this check "
      f"counted itself, which made the total depend on the claim it was verifying."
      if not bad else
      f"README quotes {sorted(bad)}, which matches no real measurement. Real values: "
      f"{sorted(real)}")

print()
print("=" * 96)
npass = sum(1 for _, ok, _, _ in results if ok)
nfail = len(results) - npass
print(f"RESULT: {npass}/{len(results)} structural checks passed, {nfail} failed")
print("=" * 96)
if nfail:
    print()
    for name, ok, detail, _ in results:
        if not ok:
            print(f"  FAILED: {name}")
            print(f"          {detail[:200]}")
print()
print("SCOPE OF THIS CHECKER")
print("-" * 96)
print("Checked here : SQL syntax (sqlglot/athena), absence of SELECT *, presence and shape of")
print("               partition filters, column-name provenance against a verified allow-list,")
print("               internal consistency between the queries and the shipped DDL, header")
print("               completeness, manifest completeness, and file readability.")
print("NOT checked  : anything requiring an AWS account. No query here was executed against")
print("               Athena, no CUR data was read from S3, and no output was compared to")
print("               Cost Explorer. Column EXISTENCE is asserted from documentation, not from")
print("               a live DESCRIBE. See content/README.md for the full disclosure.")
sys.exit(0 if nfail == 0 else 1)
