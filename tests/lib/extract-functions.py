#!/usr/bin/env python3
"""Extract top-level shell function definitions from a script.

Why this exists: both installer and management script embed other scripts and
python programs inside heredocs. A naive `grep '^name() {'` pulls functions out
of those embedded bodies — the installer, for example, contains a complete copy
of manage-model-servers.sh inside a MANAGEEOF heredoc. This walks the file
tracking heredoc state so only genuine top-level definitions are captured, and
so a `}` appearing inside a heredoc never ends a function early.

Usage:
    extract-functions.py <script> [--list] [--only name1,name2] > functions.sh
"""
import argparse
import re
import sys

# `cmd <<'EOF'`, `cmd <<EOF`, `cmd <<-EOF`, possibly several on one line.
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
# A top-level definition starts at column 0: `name() {`
FUNC_START_RE = re.compile(r"^([a-z_][a-z0-9_]*)\(\)\s*\{")


def extract(path):
    """Return (ordered list of names, list of (name, source_text))."""
    lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
    functions = []
    pending_heredocs = []      # delimiters awaiting their terminator
    active_delim = None
    i = 0
    while i < len(lines):
        line = lines[i]

        # Inside a heredoc: consume until the terminator, capture nothing.
        if active_delim is not None:
            if line.strip() == active_delim:
                active_delim = pending_heredocs.pop(0) if pending_heredocs else None
            i += 1
            continue

        stripped = line.lstrip()
        is_comment = stripped.startswith("#")

        match = FUNC_START_RE.match(line)
        if match and not is_comment:
            name = match.group(1)
            body = [line]
            # One-liner: `die() { echo x; }` — balanced on the same line.
            if line.count("{") <= line.count("}") and line.rstrip().endswith("}"):
                functions.append((name, "".join(body)))
                i += 1
                continue
            # Multi-line: read until a `}` at column 0, tracking heredocs so a
            # brace inside one does not terminate the function.
            inner_delims = []
            inner_active = None
            for delim in HEREDOC_RE.findall(line):
                inner_delims.append(delim[1])
            if inner_delims:
                inner_active = inner_delims.pop(0)
            j = i + 1
            while j < len(lines):
                cur = lines[j]
                body.append(cur)
                if inner_active is not None:
                    if cur.strip() == inner_active:
                        inner_active = inner_delims.pop(0) if inner_delims else None
                    j += 1
                    continue
                found = [d[1] for d in HEREDOC_RE.findall(cur)]
                if found and not cur.lstrip().startswith("#"):
                    inner_delims.extend(found)
                    inner_active = inner_delims.pop(0)
                    j += 1
                    continue
                if cur.rstrip("\n") == "}":
                    break
                j += 1
            functions.append((name, "".join(body)))
            i = j + 1
            continue

        # Track heredocs opened by ordinary (non-function) lines.
        if not is_comment:
            found = [d[1] for d in HEREDOC_RE.findall(line)]
            if found:
                pending_heredocs.extend(found)
                active_delim = pending_heredocs.pop(0)
        i += 1

    return functions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("--list", action="store_true", help="print names only")
    ap.add_argument("--only", default="", help="comma-separated subset")
    args = ap.parse_args()

    functions = extract(args.script)
    if args.only:
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        functions = [(n, s) for n, s in functions if n in wanted]

    if args.list:
        for name, _ in functions:
            print(name)
        return 0

    print("# Auto-extracted from %s — do not edit." % args.script)
    seen = set()
    for name, source in functions:
        # Later definitions win in bash; keep the last one, as the shell would.
        if name in seen:
            continue
        seen.add(name)
    # Emit in file order, but only the final definition of each name.
    last = {}
    for idx, (name, source) in enumerate(functions):
        last[name] = idx
    for idx, (name, source) in enumerate(functions):
        if last[name] == idx:
            print(source, end="" if source.endswith("\n") else "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
