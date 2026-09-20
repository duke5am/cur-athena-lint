"""Lint AWS Cost and Usage Report Athena SQL without an AWS account.

The sixteen checks live in :mod:`cur_athena_lint.cli` (the `cur-athena-lint`
console script) and the lighter grammar-only sweep in
:mod:`cur_athena_lint.parse_all_sql`. The seventeen SQL files ship inside this
package as package data, so the installed tool checks the same tree the
checkout does.
"""
