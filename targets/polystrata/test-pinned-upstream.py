#!/usr/bin/env python3
"""Check targets/polystrata against PolyStrata's real code at the pinned commit.

Usage: python3 test-pinned-upstream.py /path/to/PolyStrata
The directory is a checkout of the pinned commit (git fetch it, then
git checkout FETCH_HEAD). It needs Python 3.10+, no model, GPU, network or
Python packages: setup.py imports only the standard library and its own
modules.

Checked:
- the commit is PIN, and PIN matches POLYSTRATA_DEFAULT_COMMIT in
  install-target.sh and provision-lxc.sh;
- setup.py --help offers every option the installer passes or requires, and
  the family, model and KV cache choices families.sh uses;
- families.sh lists upstream's families with their engine, sizes and RAM
  estimates (FAMILIES, family_models) and its KV cache formats (POLY_KV,
  STRATA_KV);
- upstream's real run-script generator writes the launcher the unit runs, and
  setup prints "start script: run-<model>.sh" before --no-start returns;
- /health answers status, loaded and service the way install-target.sh and
  the router read it;
- the environment variables the target sets (STRATA_EXECV in the unit,
  STRATA_CACHE_MESSAGE_BOUNDARY for the message cache) are still read.
"""

import ast
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace

PIN = "36e654b1b7eb4cb462202445be296ba012c75edf"
HERE = Path(__file__).resolve().parent

# Families upstream lists that families.sh leaves out on purpose:
# qwen36-strata configures nothing at the pin (setup says the engine does not
# run it yet); hy4-flash has its own installer and ignores --kv, so it is
# accepted from the environment (KV auto only) but not offered in the menu.
NOT_IN_MENU = {"qwen36-strata", "hy4-flash"}

passed = 0


def ok(message):
    global passed
    passed += 1
    print(f"PASS {message}")


def git(repo, *args):
    return subprocess.check_output(
        ["git", "-c", f"safe.directory={repo}", "-C", str(repo), *args], text=True).strip()


def bash(script):
    return subprocess.check_output(["bash", "-c", script], text=True, cwd=HERE)


def catalog():
    """families.sh's rows: {family: (engine, default, {model: ram_gb})}."""
    rows = {}
    out = bash("source ./families.sh && polystrata_catalog")
    for line in out.splitlines():
        family, engine, default, _title, sizes = line.split("|")
        models = {}
        for size in sizes.split():
            name, ram = size.split(":")
            models[name] = int(ram)
        assert family not in rows, f"families.sh lists {family} twice"
        rows[family] = (engine, default, models)
    return rows


def poly_kv():
    out = bash("source ./families.sh && polystrata_poly_kv")
    table = {}
    for line in out.splitlines():
        fmt, families = line.split("|")
        table[fmt] = tuple(families.split())
    return table


def upstream_tables(repo):
    """FAMILIES, family_models, POLY_KV and STRATA_KV from the pinned setup.py."""
    probe = r"""
import importlib.util, json, sys
root = sys.argv[1]
sys.argv = ["setup.py"]
sys.path.insert(0, root)
spec = importlib.util.spec_from_file_location("ps_setup", root + "/setup.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
fams = {}
for name, fam in m.FAMILIES.items():
    sizes = {k: (v.get("ram_gb") if v.get("ram_gb") is not None else v.get("arena_gb"))
             for k, v in m.family_models(name).items()}
    fams[name] = {"engine": fam.get("engine") or "strata", "models": sizes}
print(json.dumps({"families": fams, "own": list(m.PREVIEW_FAMILIES), "hy4": list(m.HY4_FAMILIES),
                  "poly_kv": {k: list(v) for k, v in m.POLY_KV.items()}, "strata_kv": list(m.STRATA_KV)}))
"""
    with tempfile.TemporaryDirectory(prefix="polystrata-probe-") as cwd:
        out = subprocess.check_output([sys.executable, "-c", probe, str(repo / "terminal")], text=True, cwd=cwd)
    return json.loads(out)


def help_text(repo):
    with tempfile.TemporaryDirectory(prefix="polystrata-help-") as cwd:
        return subprocess.check_output([sys.executable, str(repo / "terminal" / "setup.py"), "--help"],
                                       text=True, cwd=cwd, stderr=subprocess.STDOUT)


def help_choices(text, flag):
    m = re.search(r"(?:^|[\s\[,])" + re.escape(flag) + r"\s+\{([^}]*)\}", text)
    return m.group(1).split(",") if m else None


def check_pin_everywhere():
    for name in ("install-target.sh", "provision-lxc.sh"):
        text = (HERE / name).read_text(encoding="utf-8")
        pins = re.findall(r"^POLYSTRATA_DEFAULT_COMMIT=([0-9a-f]{40})$", text, re.M)
        assert pins == [PIN], f"{name}: POLYSTRATA_DEFAULT_COMMIT {pins} is not {PIN}"
    ok("install-target.sh and provision-lxc.sh pin the commit this check runs at")


def check_help(text, rows, kv):
    required = ["--setup", "--no-start", "--yes", "--model", "--port", "--host", "--api-key", "--family",
                "--context", "--kv", "--parallel", "--vision", "--data-dir", "--no-browser"]
    for flag in required:
        assert re.search(r"(?:^|[\s\[,])" + re.escape(flag) + r"(?:[\s\]=,]|$)", text, re.M), \
            f"setup.py --help has no {flag}"
    families = help_choices(text, "--family")
    models = help_choices(text, "--model")
    kvs = help_choices(text, "--kv")
    visions = help_choices(text, "--vision")
    assert families and models and kvs and visions, "setup.py --help lists no choices for a menu option"
    for family, (_engine, default, sizes) in rows.items():
        assert family in families, f"setup.py does not accept --family {family}"
        assert default in sizes, f"{family}: default {default} is not one of its sizes"
        for model in sizes:
            assert model in models, f"setup.py does not accept --model {model} ({family})"
    for fmt in {"int8", "k8v4", "q4_0", "fp16", *kv}:
        assert fmt in kvs, f"setup.py does not accept --kv {fmt}"
    for vision in ("yes", "no", "gpu", "cpu"):
        assert vision in visions, f"setup.py does not accept --vision {vision}"
    ok(f"setup.py --help offers the installer's options, {len(rows)} families and their sizes")


def check_catalog(up, rows, kv):
    upstream = up["families"]
    expected = set(upstream) | set(up["own"]) | set(up["hy4"])
    missing = expected - set(rows) - NOT_IN_MENU
    extra = set(rows) - set(upstream)
    assert not missing, f"families.sh lacks upstream families: {sorted(missing)}"
    assert not extra, f"families.sh lists families upstream does not have: {sorted(extra)}"
    for family, (engine, _default, sizes) in rows.items():
        fam = upstream[family]
        assert engine == fam["engine"], f"{family}: engine {engine}, upstream {fam['engine']}"
        assert list(sizes) == list(fam["models"]), f"{family}: sizes {list(sizes)}, upstream {list(fam['models'])}"
        for model, ram in sizes.items():
            want = math.ceil(fam["models"][model])
            assert ram == want, f"{family} {model}: {ram} GB, upstream {fam['models'][model]}"
    assert kv == {k: tuple(v) for k, v in up["poly_kv"].items()}, f"polystrata_poly_kv {kv} != POLY_KV {up['poly_kv']}"
    strata_kv = bash("source ./families.sh && polystrata_kv_choices qwen").split()
    assert strata_kv[0] == "auto" and sorted(strata_kv[1:]) == sorted(up["strata_kv"]), \
        f"strata-engine KV {strata_kv} != auto + STRATA_KV {up['strata_kv']}"
    ok("families.sh matches FAMILIES, family_models, POLY_KV and STRATA_KV")


def check_launcher(repo):
    source = (repo / "terminal" / "setup.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    generator = next(node for node in tree.body
                     if isinstance(node, ast.FunctionDef) and node.name == "write_run_script")
    with tempfile.TemporaryDirectory(prefix="polystrata-launcher-") as temporary:
        root = Path(temporary)
        namespace = {"ROOT": root, "WIN": False, "home": lambda: root,
                     "sys": SimpleNamespace(executable="/opt/polystrata/terminal/.venv/bin/python")}
        exec(compile(ast.Module(body=[generator], type_ignores=[]), "pinned PolyStrata setup.py", "exec"),
             namespace)
        for model, port in (("IQ2_XS", 8080), ("UD-Q3_K_M", 11434)):
            cfg = root / f"strata-{model.lower()}.json"
            script = namespace["write_run_script"](model, cfg, port, False)
            assert script == root / f"run-{model.lower()}.sh", script
            if os.name != "nt":
                assert script.stat().st_mode & 0o111, "launcher is not executable"
            lines = script.read_text(encoding="utf-8").splitlines()
            assert lines[0] == "#!/bin/sh", lines[0]
            assert lines[1] == f'cd "{root}"', lines[1]
            assert lines[2] == (
                'exec "/opt/polystrata/terminal/.venv/bin/python" '
                f'"{root / "serve" / "server.py"}" "--engine" "strata" "--config" "{cfg}" "--port" "{port}"'
            ), lines[2]
            assert re.fullmatch(r"run-[a-z0-9._-]+\.sh", script.name), \
                f"{script.name} does not match select_run_script's pattern"
    # Every setup path that writes a launcher names it before --no-start returns.
    prints = [m.start() for m in re.finditer(r'ok\(f"start script: \{script\.name\}"\)', source)]
    assert len(prints) >= 3, "setup no longer prints 'start script: <name>' on its install paths"
    for at in prints:
        # Next comes the --no-start return, or (the Mac path) a plain return 0
        # that never starts the model.
        ends = [i for i in (source.find("if a.no_start:", at), source.find("return 0", at)) if i > at]
        end = min(ends) if ends else -1
        assert 0 < end - at < 4000, "a 'start script' line is not followed by the --no-start return"
        assert not re.search(r"\bstart\(", source[at:end]), "a setup path starts the model before --no-start returns"
    ok("the generated launcher runs serve/server.py with the config and port; setup names it before --no-start")


def check_health(repo):
    server = (repo / "terminal" / "serve" / "server.py").read_text(encoding="utf-8")
    m = re.search(r'path in \("/health", "/api/health"\):\s*\n\s*self\._json\(200, \{(.*?)\}\)', server, re.S)
    assert m, "no /health handler found in serve/server.py"
    body = m.group(1)
    for part in ('"status": "ok"', '"loaded": svc.loaded()', '"service": "strata"', '"model": svc.model'):
        assert part in body, f"/health no longer answers {part}"
    ok("/health answers status ok, loaded, model and service strata")


def check_environment(repo):
    setup = (repo / "terminal" / "setup.py").read_text(encoding="utf-8")
    assert 'os.environ.get("STRATA_EXECV")' in setup, "setup.py no longer reads STRATA_EXECV (polystrata.service sets it)"
    engine = subprocess.run(["grep", "-rlF", "STRATA_CACHE_MESSAGE_BOUNDARY", str(repo / "engine" / "src")],
                            capture_output=True, text=True).stdout
    assert engine.strip(), "the engine no longer reads STRATA_CACHE_MESSAGE_BOUNDARY (POLYSTRATA_MESSAGE_CACHE)"
    assert "the CUDA Toolkit can be installed automatically on Ubuntu" in setup, \
        "setup's CUDA toolkit message changed (install-target.sh retries setup on it)"
    ok("STRATA_EXECV, STRATA_CACHE_MESSAGE_BOUNDARY and the CUDA toolkit message are still there")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test-pinned-upstream.py /path/to/PolyStrata (a checkout of PIN)")
    repo = Path(sys.argv[1]).resolve()
    head = git(repo, "rev-parse", "HEAD")
    assert head == PIN, f"expected PolyStrata {PIN}, got {head}"
    check_pin_everywhere()
    rows, kv = catalog(), poly_kv()
    check_help(help_text(repo), rows, kv)
    check_catalog(upstream_tables(repo), rows, kv)
    check_launcher(repo)
    check_health(repo)
    check_environment(repo)
    print(f"PASS PolyStrata {PIN}: {passed} checks")


if __name__ == "__main__":
    main()
