#!/usr/bin/env python3
"""test-pinned-upstream.py KINDI_CHECKOUT

Check install-target.sh against Kindi's real code at the commit this target is
tested with (upstream-commit.txt), without a GPU, a model or a venv:

  * validate_checkout accepts the checkout (files, config keys, commands,
    engine settings and Dockerfile pins);
  * Kindi's own config loader (kindi/config.py) reads the kindi.conf the
    target writes, and gets every value from it: pack, address, key, model id,
    context and head;
  * every KINDI_* variable the unit's environment sets for any profile is one
    Kindi reads, or one of its config keys;
  * kindi-weights.txt has the files, sizes and SHA-256 of Kindi's own catalog
    (kindi/catalog.py), from the same Hugging Face repositories;
  * requirements-cuda.in pins exactly what docker/Dockerfile installs;
  * the profiles, models and contexts follow upstream's install.sh (card_class,
    card_models, profile_of, model_name);
  * /health stays public and names "kindi" and the model; /v1/models still
    answers with "owned_by": "kindi" and context_length (the readiness probe,
    the router and the manager's detection rely on them);
  * /health's busy entry carries elapsed_s from each request's own start, and a
    request whose client hung up is cancelled (the drain gate relies on both).

Change upstream-commit.txt only after this passes against the new commit.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIN = (HERE / "upstream-commit.txt").read_text().strip()
if not re.fullmatch(r"[0-9a-f]{40}", PIN):
    raise SystemExit("Invalid upstream-commit.txt")
INSTALLER = HERE / "install-target.sh"
failures = []


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def helpers(checkout, env, script):
    """Run SCRIPT with install-target.sh's helper block sourced."""
    prelude = ("note() { printf '%s\\n' \"$*\" >&2; }; die() { note \"$*\"; exit 1; }\n"
               "source <(awk '/^# Install helpers/ {c=1; next} /^# End install helpers\\./ {c=0} c' "
               f"'{INSTALLER}')\n")
    base = {"KINDI_DIR": str(checkout), "KINDI_DATA_DIR": "/var/lib/kindi", "KINDI_CONFIG_DIR": "/etc/kindi",
            "KINDI_PACK_FORMAT": "1", "CUDA_HOME_DIR": "/usr/local/cuda-10.2", "source_dir": str(HERE),
            "KINDI_BACKEND": "cuda", "KINDI_MODEL": "bonsai-27b", "KINDI_PROFILE": "tc", "KINDI_PORT": "8093",
            "KINDI_CONTEXT": "131072", "KINDI_HEAD": "exact", "KINDI_SPEC": "auto", "KINDI_THREADS": "auto",
            "KINDI_MODEL_NAME": "bonsai2-27b", "KINDI_PYTHON_VERSION": "3.9.25", "KINDI_VERIFY": "true"}
    return subprocess.run(["bash", "-c", prelude + script], env={**os.environ, **base, **env},
                          capture_output=True, text=True)


def main(checkout):
    checkout = Path(checkout).resolve()
    commit = subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"], capture_output=True, text=True)
    check(commit.stdout.strip() == PIN, f"the checkout is the pinned commit {PIN}")

    r = helpers(checkout, {}, f"validate_checkout '{checkout}'")
    check(r.returncode == 0, "validate_checkout accepts the pinned checkout" + (f": {r.stderr.strip()}" if r.stderr else ""))
    r = helpers(checkout, {}, f"pack_format '{checkout}'")
    check(r.stdout.strip().isdigit(), f"the converter names its pack format ({r.stdout.strip()})")

    sys.path.insert(0, str(checkout))
    from kindi import catalog, config  # noqa: E402  (the pinned checkout's own modules)

    # The config file the unit's Kindi reads, through Kindi's own loader.
    r = helpers(checkout, {"api_key": "sk-pinned-test"}, "server_config")
    with tempfile.TemporaryDirectory() as tmp:
        conf = Path(tmp) / "kindi.conf"
        conf.write_text(r.stdout)
        clean = {k: v for k, v in os.environ.items() if not k.startswith("KINDI_")}
        old_env = dict(os.environ)
        os.environ.clear()
        os.environ.update(clean)
        try:
            cfg = config.load(str(conf), {})
        except SystemExit as exc:
            cfg = None
            check(False, f"Kindi refuses the target's kindi.conf: {exc}")
        finally:
            os.environ.clear()
            os.environ.update(old_env)
    if cfg is not None:
        want = {"pack": "/var/lib/kindi/packs/bonsai-27b-f1", "state_dir": "/var/lib/kindi/state", "host": "0.0.0.0",
                "port": 8093, "api_key": "sk-pinned-test", "model_name": "bonsai2-27b", "ctx": 131072, "head": "exact"}
        got = {k: cfg[k] for k in want}
        check(got == want, f"Kindi's config loader reads the target's kindi.conf: {got}")

    # Every KINDI_* the unit's environment sets, for every profile.
    keys = {"KINDI_" + k.upper() for k in config.DEFAULTS}
    code = "\n".join(p.read_text(errors="replace") for p in (checkout / "kindi").glob("*.py"))
    seen = set()
    for env in ({"KINDI_PROFILE": p, "KINDI_MODEL": m}
                for p in ("tc", "pascal8", "p100", "kepler", "maxwell", "nanbeige")
                for m in ("bonsai-2b", "bonsai-27b", "nanbeige-33b")):
        r = helpers(checkout, env, "engine_env")
        seen |= {line.split("=", 1)[0] for line in r.stdout.splitlines() if line.startswith("KINDI_")}
    r = helpers(checkout, {"KINDI_BACKEND": "cpu", "KINDI_PROFILE": "cpu", "KINDI_MODEL": "bonsai-2b",
                           "KINDI_THREADS": "4"}, "engine_env")
    seen |= {line.split("=", 1)[0] for line in r.stdout.splitlines() if line.startswith("KINDI_")}
    unknown = sorted(v for v in seen if v not in keys and f'"{v}"' not in code)
    check(not unknown, f"Kindi reads every KINDI_* setting of the unit's environment ({len(seen)}){': ' + ' '.join(unknown) if unknown else ''}")

    # The weights manifest against Kindi's own catalog.
    rows = {}
    for line in (HERE / "kindi-weights.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            model, name, size, digest, url = line.split()
            rows[model] = (name, int(size), digest.removeprefix("sha256:"), url)
    for model, (name, size, digest, url) in rows.items():
        m = catalog.MODELS.get(model)
        ok = m is not None and (m["file"], m["size"], m["sha"]) == (name, size, digest) and \
            url.startswith(f"https://huggingface.co/{m['repo']}/resolve/")
        check(ok, f"{model}: {name} is Kindi's catalog file, size and SHA-256, from {m['repo'] if m else '?'}")

    # The venv pins against Kindi's Dockerfile.
    dockerfile = (checkout / "docker" / "Dockerfile").read_text()
    upstream_pins = set(re.findall(r'"([A-Za-z0-9_.-]+==[0-9][^"]*)"', dockerfile))
    ours = set()
    for name in ("requirements-cpu.in", "requirements-cuda.in"):
        for line in (HERE / name).read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if "==" in line:
                ours.add(line)
    missing = {p for p in upstream_pins if p.lower() not in {o.lower() for o in ours}}
    check(not missing and upstream_pins, f"requirements-*.in pins what docker/Dockerfile installs ({len(upstream_pins)}){': missing ' + ' '.join(sorted(missing)) if missing else ''}")

    # The profiles, models, contexts and ids against upstream's install.sh.
    install_sh = (checkout / "install.sh").read_text()
    for pattern, what in (
            (r'"\$c" -ge 80 \] && \[ "\$V" -ge 9500 \]; then echo tc', "tc: sm_80+, 9500 MiB+"),
            (r'"\$c" -ge 61 \] && \[ "\$V" -ge 7500 \]; then echo pascal8', "pascal8: sm_61+, 7500 MiB+"),
            (r'"\$c" -eq 60 \] && \[ "\$V" -ge 12000 \]; then echo p100', "p100: sm_60, 12000 MiB+"),
            (r'"\$c" -lt 50 \]; then echo kepler', "kepler: below sm_50"),
            (r'tc\|pascal8\) echo "27b ', "tc and pascal8 take the 27B first"),
            (r'kepler\) if \[ "\$V" -ge 11000 \]; then echo "27b .*?elif \[ "\$V" -ge 3800 \]; then echo "9b .*?elif \[ "\$V" -ge 1900 \]; then echo "4b', "Kepler: 27B from 11000, 9B from 3800, 4B from 1900 MiB"),
            (r'tc\) C=\$\{CTX/auto/131072\}', "tc asks for 131072 tokens"),
            (r'pascal8\) C=\$\{CTX/auto/65536\}', "pascal8 asks for 65536 tokens"),
            (r'PROFILE=nanbeige; C=\$\{CTX/auto/16384\}', "Nanbeige asks for 16384 tokens"),
            (r'C=\$\{CTX/auto/23808\}', "the 4B on a 2 GB Kepler card asks for 23808 tokens"),
            (r'\[ "\$PROFILE" = tc \] \|\| ENV\+=\(-e KINDI_BLOCKING_SYNC=0\)', "blocking sync stays on only for tc"),
            (r'nanbeige\) echo "nanbeige-33b-iq3"', "Nanbeige's model id"),
            (r'\*\) echo "bonsai2-\$1"', "the Bonsai model ids"),
    ):
        check(re.search(pattern, install_sh, re.S) is not None, f"upstream install.sh: {what}")

    # The API the probe, the router and the manager rely on.
    server = (checkout / "kindi" / "server.py").read_text()
    health = re.search(r'@app\.get\("/health"\)\s*def health\(\):(.*?)@app\.', server, re.S)
    check(health is not None and "_auth(" not in health.group(1) and '"ok": True' in health.group(1)
          and '"kindi": __version__' in health.group(1) and '"model": model_id' in health.group(1)
          and '"ctx": K.eng.ctx' in health.group(1),
          "/health is public and gives ok, the kindi version, the model id and the context")
    models = re.search(r'@app\.get\("/v1/models"\)(.*?)@app\.', server, re.S)
    check(models is not None and "_auth(request)" in models.group(1) and '"owned_by": "kindi"' in models.group(1)
          and '"context_length": K.eng.ctx' in models.group(1) and '"id": model_id' in models.group(1),
          "/v1/models needs the key and lists the model id, owned_by kindi, with its context_length")
    check('request.headers.get("authorization", "") == "Bearer " + key' in server,
          "the API key is a bearer token")
    # The router's and dispatchers' drain gate: after hanging up on a request,
    # they reopen Kindi when /health shows it idle, or busy with a request that
    # began later (busy.elapsed_s from that request's own start). It also
    # relies on Kindi stopping a request whose client went away.
    check(health is not None and '"busy": busy' in health.group(1)
          and re.search(r'"elapsed_s": round\(time\.time\(\) - b\["started"\]\)', health.group(1)) is not None,
          "/health reports busy, with elapsed_s since the current request started")
    engine = "\n".join(p.read_text(errors="replace") for p in (checkout / "kindi").glob("*.py"))
    starts = [engine[m.start():m.start() + 200] for m in re.finditer(r"busy\.update\(active=True", engine)]
    check(len(starts) >= 3 and all("started=" in start for start in starts),
          f"every generation path resets busy.started ({len(starts)})")
    check("cancel.set()" in server and "is_disconnected()" in server,
          "a request whose client disconnected is cancelled")

    print(f"{'FAILED' if failures else 'OK'}: {len(failures)} failure(s) against Kindi {PIN}")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1]))
