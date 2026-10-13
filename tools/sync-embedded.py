#!/usr/bin/env python3
"""Keep the installer's embedded copies identical to the files in this repo.

ollama-smart-router-install.sh is a single file that is copied to a Proxmox
host on its own, so it carries every installer-owned service file as a quoted
heredoc:

    cat > "${REPO_DIR}/services/ollama-router/router.py" <<'PYEOF'
    ...
    PYEOF

The files under services/ and install/ in this repo are the SOURCE OF TRUTH.
Edit those, then run

    tools/sync-embedded.py --write     # rewrite the heredoc bodies in place
    tools/sync-embedded.py --check     # CI / tests: exit 1 on any drift

Only quoted heredocs (<<'TAG') are synced. Unquoted ones (<<EOF) expand shell
variables at install time and are generated config, not code. Files listed in
NOT_SYNCED are seeded as starting points only and are deliberately different
from the repo copy.

install/manage-model-servers.sh is the one real copy of the management tool;
the repo-root manage-model-servers.sh only execs it.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "ollama-smart-router-install.sh"
# Seeded only when the repo lacks them; intentionally not a copy of the repo file.
NOT_SYNCED = {"README.md"}
# (copy, source) pairs that must be byte-identical. (The repo-root
# manage-model-servers.sh is now a thin wrapper, so there are none today.)
MIRRORS = []

HEREDOC = re.compile(r'''^\s*cat > "\$\{REPO_DIR\}/(?P<path>[^"]+)" <<'(?P<tag>\w+)'\s*$''')


def find_blocks(lines):
    """Yield (repo_path, body_start, body_end) for each quoted heredoc.
    body_end is the index of the terminator line."""
    i = 0
    while i < len(lines):
        match = HEREDOC.match(lines[i])
        if match:
            tag = match.group("tag")
            j = i + 1
            while j < len(lines) and lines[j].rstrip("\n") != tag:
                j += 1
            if j == len(lines):
                raise SystemExit(f"unterminated heredoc {tag} at line {i + 1}")
            yield match.group("path"), i + 1, j
            i = j
        i += 1


def owned_files():
    lines = INSTALLER.read_text(encoding="utf-8").splitlines(keepends=True)
    return [p for p, _, _ in find_blocks(lines) if p not in NOT_SYNCED]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--list", action="store_true",
                      help="print the installer-owned repo paths")
    args = parser.parse_args()

    if args.list:
        print("\n".join(owned_files()))
        return 0

    text = INSTALLER.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    drift, out, cursor = [], [], 0
    for path, start, end in find_blocks(lines):
        if path in NOT_SYNCED:
            continue
        source = ROOT / path
        if not source.is_file():
            drift.append(f"{path}: embedded in the installer but missing from the repo")
            continue
        body = source.read_text(encoding="utf-8")
        if not body.endswith("\n"):
            body += "\n"
        tag = HEREDOC.match(lines[start - 1]).group("tag")
        if any(line.rstrip("\n") == tag for line in body.splitlines()):
            raise SystemExit(f"{path} contains a line equal to its heredoc tag {tag}")
        if "".join(lines[start:end]) != body:
            drift.append(f"{path}: installer copy differs from the repo file")
        out.extend(lines[cursor:start])
        out.append(body)
        cursor = end
    out.extend(lines[cursor:])

    for copy, source in MIRRORS:
        if (ROOT / copy).read_bytes() != (ROOT / source).read_bytes():
            drift.append(f"{copy}: differs from {source}")
            if args.write:
                (ROOT / copy).write_bytes((ROOT / source).read_bytes())

    if args.write:
        new = "".join(out)
        # write_text() translates LF to CRLF on Windows; the installer is a
        # Linux shell script and its embedded files must remain byte-for-byte
        # identical to the LF sources.
        if INSTALLER.read_bytes() != new.encode():
            INSTALLER.write_bytes(new.encode())
        for line in drift:
            print("synced   " + line.split(":")[0])
        return 0

    for line in drift:
        print("DRIFT    " + line, file=sys.stderr)
    if drift:
        print("Run tools/sync-embedded.py --write after editing the repo files.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
