#!/usr/bin/env python3
"""parse_all_sql.py - parse every bundled .sql with sqlglot's Athena dialect.

Wrapper so `python3 parse_all_sql.py` keeps working from a clone. The
implementation lives in `cur_athena_lint/parse_all_sql.py`.

Run:  python3 parse_all_sql.py
Exit: 0 all parsed, 1 at least one failure, 2 nothing found to parse.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cur_athena_lint.parse_all_sql import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
