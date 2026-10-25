#!/usr/bin/env python3
"""Print skip evidence from a suite's captured output, one line per report."""

import re
import sys
from pathlib import Path


ANSI = re.compile(r"\x1b\[[0-9;]*m")
LINE_SKIP = re.compile(r"^\s*skip(?:ped)?(?:\s+|:|$)", re.IGNORECASE)
PYTEST_SUMMARY = re.compile(r"(?<!\w)[1-9][0-9]*\s+skipped\b", re.IGNORECASE)
UNITTEST_SUMMARY = re.compile(r"\bskipped=[1-9][0-9]*\b", re.IGNORECASE)


def skip_reports(output):
    for raw in output.splitlines():
        line = ANSI.sub("", raw).strip()
        if (LINE_SKIP.search(line) or PYTEST_SUMMARY.search(line)
                or UNITTEST_SUMMARY.search(line)):
            yield line


if __name__ == "__main__":
    for report in skip_reports(Path(sys.argv[1]).read_text(errors="replace")):
        print(report)
