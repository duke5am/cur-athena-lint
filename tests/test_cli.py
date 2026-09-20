"""Tests for the `cur-athena-lint` checker.

Run from the repo root:

    python3 -m unittest discover -s tests -v

The checker is a whole-pack verifier rather than a one-file linter, so most
tests drive it as a subprocess with CUR_CONTENT pointed at a scratch tree. Every
bad input (a CUR_CONTENT that does not exist, an empty tree, a tree whose .sql
files cannot be decoded) must exit non-zero with a clear message and must NOT
print a Python traceback.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(REPO, "verify_pack.py")
PARSE_ALL = os.path.join(REPO, "parse_all_sql.py")

if REPO not in sys.path:
    sys.path.insert(0, REPO)

from cur_athena_lint import cli, parse_all_sql  # noqa: E402

GOOD_QUERY = """-- QUESTION IT ANSWERS: cost by service for one month
-- WHAT IT RETURNS: one row per service
-- BYTES SCANNED: one month of CUR, pruned by year and month
-- TABLE / PARTITION ASSUMPTIONS: cur_table partitioned by year, month
-- CAVEATS: unblended cost is 0 for reservation-covered usage
SELECT line_item_product_code AS service,
       sum(line_item_unblended_cost) AS cost
FROM REPLACE_ME_DATABASE.REPLACE_ME_TABLE
WHERE year = '2026' AND month = '01'
GROUP BY line_item_product_code
"""

# product_product_name IS on the verified allow-list (it is a real CUR column), so a
# plausible-but-invented name is used here instead.
WRONG_COLUMN_QUERY = GOOD_QUERY.replace(
    "line_item_product_code", "line_item_totally_bogus_column")
UNFILTERED_QUERY = GOOD_QUERY.replace(
    "WHERE year = '2026' AND month = '01'", "")


class CurTestCase(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.mkdtemp(dir="/root", prefix="curlint-test-")

    def tearDown(self):
        shutil.rmtree(self.scratch, ignore_errors=True)

    def make_tree(self, name, queries=None, ddl=False):
        """A scratch content root with a queries/ (and optional setup/) subdir."""
        root = os.path.join(self.scratch, name)
        qdir = os.path.join(root, "queries")
        os.makedirs(qdir)
        for filename, text in (queries or {}).items():
            with open(os.path.join(qdir, filename), "w", encoding="utf-8") as fh:
                fh.write(text)
        if ddl:
            sdir = os.path.join(root, "setup")
            os.makedirs(sdir)
            with open(os.path.join(sdir, "create_table.sql"), "w",
                      encoding="utf-8") as fh:
                fh.write("CREATE EXTERNAL TABLE t (year string, month string)\n"
                         "PARTITIONED BY (`year`, `month`)\n")
        return root

    def run_cli(self, script=VERIFY, env=None, cwd=None):
        full_env = dict(os.environ)
        full_env.pop("CUR_CONTENT", None)
        full_env.update(env or {})
        return subprocess.run(
            [sys.executable, script],
            cwd=cwd or self.scratch, env=full_env,
            capture_output=True, text=True, timeout=300,
        )

    def assert_no_traceback(self, proc):
        self.assertNotIn("Traceback", proc.stdout + proc.stderr,
                         "the checker printed a Python traceback:\n"
                         + proc.stdout + proc.stderr)


class TestBundledPack(CurTestCase):
    """The pack that ships inside the package must pass its own checker."""

    def test_checker_passes_on_the_bundled_pack(self):
        proc = self.run_cli()
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("RESULT: 15/15 structural checks passed, 0 failed", proc.stdout)

    def test_every_sql_file_is_packaged(self):
        queries = sorted(f for f in os.listdir(os.path.join(cli.HERE, "queries"))
                         if f.endswith(".sql"))
        self.assertEqual(len(queries), 16, queries)
        self.assertTrue(os.path.exists(
            os.path.join(cli.HERE, "setup", "create_table.sql")))
        # sql_files() is nested inside the checker body; the module-level
        # equivalent lives in parse_all_sql.
        self.assertEqual(len(parse_all_sql.sql_files()), 17)

    def test_parse_all_sql_parses_every_file(self):
        proc = self.run_cli(script=PARSE_ALL)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("files=17  statements_parsed=17  files_with_errors=0", proc.stdout)

    def test_parse_all_sql_reports_files_it_found(self):
        self.assertEqual(len(parse_all_sql.sql_files()), 17)


class TestBadInput(CurTestCase):
    def test_cur_content_that_does_not_exist(self):
        missing = os.path.join(self.scratch, "nope")
        proc = self.run_cli(env={"CUR_CONTENT": missing})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("is not a directory", proc.stderr)
        self.assertIn("nothing was checked", proc.stderr)

    def test_cur_content_that_is_a_file_not_a_directory(self):
        path = os.path.join(self.scratch, "file.txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("not a tree\n")
        proc = self.run_cli(env={"CUR_CONTENT": path})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("is not a directory", proc.stderr)

    def test_empty_tree_fails_the_discovery_check(self):
        empty = os.path.join(self.scratch, "empty")
        os.makedirs(empty)
        proc = self.run_cli(env={"CUR_CONTENT": empty})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("P01 SQL files discovered", proc.stdout)
        self.assertIn("0 .sql files found", proc.stdout)

    def test_tree_whose_sql_is_not_utf8_text(self):
        root = self.make_tree("binary", {"good.sql": GOOD_QUERY})
        with open(os.path.join(root, "queries", "binary.sql"), "wb") as fh:
            fh.write(b"select 1;\n\xff\xfe\x00junk")
        proc = self.run_cli(env={"CUR_CONTENT": root})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        # The bad file must be named, and the run must not abort early: before
        # the fix this raised UnicodeDecodeError out of P07 and every later check
        # was skipped.
        self.assertIn("binary.sql", proc.stdout)
        self.assertIn("could not read", proc.stdout)
        self.assertIn("RESULT:", proc.stdout)
        self.assertIn("P14 every analysis query has an explicit BYTES SCANNED warning",
                      proc.stdout)

    def test_parse_all_sql_with_a_missing_content_root(self):
        missing = os.path.join(self.scratch, "nope")
        proc = self.run_cli(script=PARSE_ALL, env={"CUR_CONTENT": missing})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("no .sql files found", proc.stderr)

    def test_parse_all_sql_with_a_tree_that_has_no_sql(self):
        root = self.make_tree("nosql", {})
        proc = self.run_cli(script=PARSE_ALL, env={"CUR_CONTENT": root})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("no .sql files found", proc.stderr)


class TestChecksActuallyBite(CurTestCase):
    """A checker that always passes is worthless; these prove it fails."""

    def test_a_column_outside_the_allow_list_is_caught(self):
        root = self.make_tree("badcol", {"q.sql": WRONG_COLUMN_QUERY})
        proc = self.run_cli(env={"CUR_CONTENT": root})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("[FAIL] P06 every column reference is on the verified column allow-list",
                      proc.stdout)
        self.assertIn("line_item_totally_bogus_column", proc.stdout)

    def test_a_query_with_no_partition_filter_is_caught(self):
        root = self.make_tree("nofilter", {"q.sql": UNFILTERED_QUERY})
        proc = self.run_cli(env={"CUR_CONTENT": root})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("P04 every statement reading the CUR table filters on year AND month",
                      proc.stdout)

    def test_select_star_is_caught(self):
        root = self.make_tree("star", {"q.sql": GOOD_QUERY.replace(
            "SELECT line_item_product_code AS service,\n"
            "       sum(line_item_unblended_cost) AS cost",
            "SELECT *")})
        proc = self.run_cli(env={"CUR_CONTENT": root})
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("P03 no query uses SELECT *", proc.stdout)


class TestPackagingShape(CurTestCase):
    def test_entry_point_target_exists(self):
        self.assertTrue(callable(cli.main))

    def test_content_root_defaults_to_the_package(self):
        # Both layouts (installed wheel and checkout) keep the SQL inside the
        # package, so the content root is the package directory.
        self.assertEqual(cli.CONTENT, cli.HERE)
        self.assertFalse(cli.PACK_MODE)

    def test_never_shipped_directories_are_skipped(self):
        for name in (".git", "__pycache__", "build", "dist", ".venv"):
            self.assertIn(name, cli.SKIP_DIRS)

    def test_result_line_is_fifteen_checks(self):
        proc = self.run_cli()
        self.assertIn("15/15 structural checks passed", proc.stdout)


if __name__ == "__main__":
    unittest.main()
