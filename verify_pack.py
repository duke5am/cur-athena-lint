#!/usr/bin/env python3
"""
verify_pack.py - structural sanity checker for the AWS CUR Athena FinOps Query Pack.

This wrapper exists so `python3 verify_pack.py` keeps working exactly as
documented, from a clone with no install. The same checker is installed as the
`cur-athena-lint` console script; the implementation lives in
`cur_athena_lint/cli.py` so that the installed package and the checkout are the
same code, not two versions of it.

Run:  python3 verify_pack.py
Exit: 0 if all checks pass, 1 otherwise.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cur_athena_lint.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
