#!/usr/bin/env python3
"""Print skip evidence from a suite's captured output, one line per report."""

import re
import sys
from pathlib import Path


ANSI = re.compile(r"\x1b\[[0-9;]*m")
LINE_SKIP = re.compile(r"^\s*skip(?:ped)?(?:\s+|:|$)", re.IGNORECASE)
PYTEST_SUMMARY = re.compile(r"(?<!\w)[1-9][0-9]*\s+skipped\b", re.IGNORECASE)
UNITTEST_SUMMARY = re.compile(r"\bskipped=[1-9][0-9]*\b", re.IGNORECASE)
# tests/lib/assert.sh's own summary: "ran 9   passed 7   failed 2   skipped 0".
# Only its skipped count matters; "failed 2   skipped" is not a pytest summary.
ASSERT_SUMMARY = re.compile(r"^ran \d+\s+passed \d+\s+failed \d+\s+skipped (\d+)\s*$")


def skip_reports(output):
    for raw in output.splitlines():
        line = ANSI.sub("", raw).strip()
        summary = ASSERT_SUMMARY.match(line)
        if summary:
            if int(summary.group(1)):
                yield line
            continue
        if (LINE_SKIP.search(line) or PYTEST_SUMMARY.search(line)
                or UNITTEST_SUMMARY.search(line)):
            yield line


if __name__ == "__main__":
    for report in skip_reports(Path(sys.argv[1]).read_text(errors="replace")):
        print(report)
