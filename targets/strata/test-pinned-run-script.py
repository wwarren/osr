#!/usr/bin/env python3
"""Exercise Strata's real run-script generator at the pinned source commit.

Usage: python3 test-pinned-run-script.py /path/to/fetched/Strata
The checkout must have fetched the pinned commit into FETCH_HEAD. No model,
Python packages, GPU, or server process is needed.
"""

import ast
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace


PIN = "a0116b2782a5b82622358c04a06496485d12b2d6"


def git(repo, *args):
    return subprocess.check_output(
        ["git", "-c", f"safe.directory={repo}", "-C", str(repo), *args],
        text=True,
    ).strip()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test-pinned-run-script.py /path/to/fetched/Strata")
    repo = Path(sys.argv[1]).resolve()
    actual = git(repo, "rev-parse", "FETCH_HEAD")
    assert actual == PIN, f"expected Strata {PIN}, got {actual}"
    source = git(repo, "show", "FETCH_HEAD:setup.py")
    tree = ast.parse(source)
    generator = next(
        node for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "write_run_script"
    )

    # Execute only the upstream generator. It writes a launcher but cannot
    # download models or import Strata's packages.
    with tempfile.TemporaryDirectory(prefix="strata-launcher-") as temporary:
        root = Path(temporary)
        namespace = {
            "ROOT": root,
            "WIN": False,
            "sys": SimpleNamespace(executable="/opt/strata/.venv/bin/python"),
        }
        module = ast.Module(body=[generator], type_ignores=[])
        exec(compile(module, "pinned Strata setup.py", "exec"), namespace)
        for port in (8080, 11434):
            cfg = root / "strata-iq2_xs.json"
            script = namespace["write_run_script"]("IQ2_XS", cfg, port, False)
            assert script == root / "run-iq2_xs.sh"
            assert script.is_file()
            if os.name != "nt":
                assert script.stat().st_mode & 0o111, "launcher is not executable"
            lines = script.read_text(encoding="utf-8").splitlines()
            assert lines[0] == "#!/bin/sh"
            assert lines[1] == f'cd "{root}"'
            assert lines[2] == (
                'exec "/opt/strata/.venv/bin/python" '
                f'"{root / "serve" / "server.py"}" '
                f'"--engine" "strata" "--config" "{cfg}" '
                f'"--port" "{port}"'
            ), lines[2]
            assert "--open" not in lines[2]

    # Verify the same setup path writes the script before --no-start returns.
    generate_at = source.index("script = write_run_script(tag, cfg_path, port")
    no_start_at = source.index("if a.no_start:\n        return 0", generate_at)
    assert no_start_at > generate_at
    print(f"PASS Strata {PIN}: generated launcher starts the selected config on 8080 and 11434")


if __name__ == "__main__":
    main()
