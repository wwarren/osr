"""Regression cases for the run-tests.sh strict skip gate."""

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).parent / "lib" / "parse-skips.py"
spec = importlib.util.spec_from_file_location("parse_skips", SCRIPT)
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


class SkipReportsTest(unittest.TestCase):
    def test_shell_skip_formats(self):
        output = "SKIP end-to-end cases (needs root)\n  skip GPU path — no GPU\nskipped: no device\n"
        self.assertEqual(list(parser.skip_reports(output)), [
            "SKIP end-to-end cases (needs root)",
            "skip GPU path — no GPU",
            "skipped: no device",
        ])

    def test_pytest_and_unittest_summaries(self):
        output = "===== 42 passed, 2 skipped in 0.25s =====\nOK (skipped=3)\n"
        self.assertEqual(list(parser.skip_reports(output)), [
            "===== 42 passed, 2 skipped in 0.25s =====", "OK (skipped=3)",
        ])

    def test_zero_counts_and_unrelated_prose_are_not_skips(self):
        output = "We skip ahead in the documentation\n0 skipped\nOK (skipped=0)\n42 passed\n"
        self.assertEqual(list(parser.skip_reports(output)), [])

    def test_ansi_colours_are_removed(self):
        self.assertEqual(list(parser.skip_reports("\x1b[33m  SKIP no root\x1b[0m\n")),
                         ["SKIP no root"])


if __name__ == "__main__":
    unittest.main()
