#!/usr/bin/env python3
"""
parse_all_sql.py - parse every .sql file in this pack with sqlglot using the
Athena dialect.

This is the primary verification method for this pack's SQL: it proves each
file is syntactically valid Athena/Trino. It does NOT prove any query runs
against a real table, because no AWS account was available. See README.md.

Run:  python3 parse_all_sql.py
"""
import glob
import os
import sys
import traceback

import sqlglot
from sqlglot import parse
from sqlglot.errors import ParseError

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = (sorted(glob.glob(os.path.join(HERE, 'content', 'queries', '*.sql')))
         + sorted(glob.glob(os.path.join(HERE, 'content', 'setup', '*.sql'))))

print(f"sqlglot {sqlglot.__version__}  |  dialect=athena  |  files={len(FILES)}")
print("=" * 84)
statements = errors = 0
for f in FILES:
    name = os.path.basename(f)
    src = open(f, encoding='utf-8').read()
    try:
        exprs = parse(src, read='athena')
        kinds = ' '.join(type(e).__name__ for e in exprs)
        statements += len(exprs)
        print(f"OK    {name:44s} statements={len(exprs)}  {kinds}")
    except ParseError as exc:
        errors += 1
        print(f"FAIL  {name:44s} {str(exc).splitlines()[0]}")
    except Exception:                              # noqa: BLE001
        errors += 1
        print(f"ERROR {name:44s}")
        traceback.print_exc()
print("=" * 84)
print(f"files={len(FILES)}  statements_parsed={statements}  files_with_errors={errors}")
sys.exit(0 if errors == 0 else 1)
