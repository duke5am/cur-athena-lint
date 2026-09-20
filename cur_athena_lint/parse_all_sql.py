#!/usr/bin/env python3
"""
parse_all_sql.py - parse every .sql file in this pack with sqlglot using the
Athena dialect.

This is the primary verification method for this pack's SQL: it proves each
file is syntactically valid Athena/Trino. It does NOT prove any query runs
against a real table, because no AWS account was available. See README.md.

The SQL ships inside the package (cur_athena_lint/queries/ and
cur_athena_lint/setup/), so this reads the installed location first and the
pack layout (content/) second; CUR_CONTENT overrides both.

Run:  python3 parse_all_sql.py
Exit: 0 all files parsed, 1 at least one file failed, 2 nothing was found to parse.
"""
import glob
import os
import sys
import traceback

import sqlglot
from sqlglot import parse
from sqlglot.errors import ParseError

HERE = os.path.dirname(os.path.abspath(__file__))


def content_root():
    """Where the SQL lives: installed/checkout package data first, content/ second."""
    override = os.environ.get('CUR_CONTENT')
    if override:
        return override
    pack = os.path.join(HERE, 'content')
    if os.path.isdir(pack):
        return pack
    return HERE


def sql_files(root=None):
    root = root or content_root()
    return (sorted(glob.glob(os.path.join(root, 'queries', '*.sql')))
            + sorted(glob.glob(os.path.join(root, 'setup', '*.sql'))))


def _run():
    files = sql_files()

    print(f"sqlglot {sqlglot.__version__}  |  dialect=athena  |  files={len(files)}")
    print("=" * 84)

    if not files:
        # Before, an empty file list printed "files=0 ... files_with_errors=0" and
        # exited 0: a clean bill of health for having checked nothing at all.
        sys.stderr.write(
            "error: no .sql files found under %s -- nothing was parsed.\n"
            "  looked in: %s\n"
            % (content_root(), os.path.join(content_root(), 'queries')))
        return 2

    statements = errors = 0
    for f in files:
        name = os.path.basename(f)
        try:
            src = open(f, encoding='utf-8').read()
        except (OSError, UnicodeDecodeError) as exc:
            errors += 1
            print(f"ERROR {name:44s} could not read: {type(exc).__name__}: {exc}")
            continue
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
    print(f"files={len(files)}  statements_parsed={statements}  files_with_errors={errors}")
    return 0 if errors == 0 else 1


def main(argv=None):
    try:
        return _run()
    except KeyboardInterrupt:
        sys.stderr.write("interrupted\n")
        return 130
    except Exception as exc:
        sys.stderr.write("error: %s: %s\n" % (type(exc).__name__, exc))
        return 3


if __name__ == "__main__":
    sys.exit(main())
