#!/usr/bin/env python3
"""budgets.py: derived budgets, explicit overrides, persistence and validation."""
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "honcho_budgets", Path(__file__).with_name("budgets.py"))
budgets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budgets)


class DerivedTest(unittest.TestCase):
    def test_a_large_window_keeps_honchos_defaults(self):
        self.assertEqual({}, budgets.effective({"CONTEXT_TOKENS": "131072"}))
        self.assertEqual({}, budgets.effective({}))

    def test_a_32k_window(self):
        settings = budgets.effective({"CONTEXT_TOKENS": "32768"})
        self.assertEqual("24576", settings["DIALECTIC_MAX_INPUT_TOKENS"])
        self.assertEqual("4096", settings["DIALECTIC_MAX_OUTPUT_TOKENS"])
        self.assertEqual("24576", settings["SUMMARY_MAX_INPUT_TOKENS"])
        self.assertEqual("4096", settings["DREAM_DEDUCTION_MODEL_CONFIG__MAX_OUTPUT_TOKENS"])
        self.assertEqual("4096", settings["DREAM_INDUCTION_MODEL_CONFIG__MAX_OUTPUT_TOKENS"])
        self.assertNotIn("DERIVER_MAX_INPUT_TOKENS", settings, "25000 already fits")

    def test_every_window_fits_its_input_and_output(self):
        for context in (8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304):
            budget = budgets.derived(context)
            with self.subTest(context=context):
                self.assertLessEqual(budget["DIALECTIC_MAX_INPUT_TOKENS"] + budget["DIALECTIC_MAX_OUTPUT_TOKENS"], context)
                self.assertLessEqual(budget["DERIVER_MAX_INPUT_TOKENS"] + budget["LLM_DEFAULT_MAX_TOKENS"], context)
                self.assertLessEqual(budget["SUMMARY_MAX_INPUT_TOKENS"] + budget["SUMMARY_MAX_TOKENS_LONG"], context)
                self.assertGreaterEqual(budget["DERIVER_MAX_INPUT_TOKENS"], 1024)
                # Honcho's own rule; effective() would refuse otherwise.
                budgets.effective({"CONTEXT_TOKENS": str(context)})

    def test_an_explicit_value_wins_over_the_derived_one(self):
        settings = budgets.effective({"CONTEXT_TOKENS": "32768", "DIALECTIC_MAX_INPUT_TOKENS": "20000",
                                      "DREAM_ENABLED": "false"})
        self.assertEqual("20000", settings["DIALECTIC_MAX_INPUT_TOKENS"])
        self.assertEqual("false", settings["DREAM_ENABLED"])
        self.assertEqual({"DREAM_INDUCTION_MAX_TOOL_ITERATIONS": "4"},
                         budgets.effective({"DREAM_INDUCTION_MAX_TOOL_ITERATIONS": "4"}))


class ValidationTest(unittest.TestCase):
    def test_out_of_range_or_malformed_values_are_refused(self):
        for values in ({"CONTEXT_TOKENS": "4096"}, {"CONTEXT_TOKENS": "32k"},
                       {"DERIVER_MAX_INPUT_TOKENS": "30000"}, {"DERIVER_MAX_INPUT_TOKENS": "512"},
                       {"DREAM_ENABLED": "no"}, {"LLM_MAX_TOOL_OUTPUT_CHARS": "-1"}):
            with self.subTest(values=values), self.assertRaises(budgets.BudgetError):
                budgets.effective(values)

    def test_honchos_summary_rule_is_checked_before_honcho_would_refuse_to_start(self):
        with self.assertRaises(budgets.BudgetError):
            budgets.effective({"SUMMARY_MAX_INPUT_TOKENS": "10000"})  # < 2 x 6000


class PersistenceTest(unittest.TestCase):
    def run_main(self, environ, previous_text=None):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: [p.unlink() for p in directory.iterdir()] and directory.rmdir())
        previous = directory / "previous"
        if previous_text is not None:
            previous.write_text(previous_text)
        record, settings = directory / "record", directory / "settings"
        with patch.dict(os.environ, environ, clear=True), contextlib.redirect_stdout(io.StringIO()):
            budgets.main([str(previous), str(record), str(settings)])
        return record.read_text(), settings.read_text()

    def test_unset_keeps_set_empty_clears(self):
        record, settings = self.run_main({"HONCHO_CONTEXT_TOKENS": "32768", "HONCHO_DREAM_ENABLED": "false"})
        self.assertEqual("HONCHO_CONTEXT_TOKENS=32768\nHONCHO_DREAM_ENABLED=false\n", record)
        kept, kept_settings = self.run_main({}, record)
        self.assertEqual(record, kept)
        self.assertEqual(settings, kept_settings)
        cleared, cleared_settings = self.run_main({"HONCHO_CONTEXT_TOKENS": ""}, record)
        self.assertEqual("HONCHO_DREAM_ENABLED=false\n", cleared)
        self.assertEqual("DREAM_ENABLED=false\n", cleared_settings)

    def test_unknown_record_lines_are_ignored(self):
        record, _ = self.run_main({}, "HONCHO_EVIL=1\nPATH=/tmp\nHONCHO_CONTEXT_TOKENS=16384\n")
        self.assertEqual("HONCHO_CONTEXT_TOKENS=16384\n", record)


if __name__ == "__main__":
    unittest.main()
