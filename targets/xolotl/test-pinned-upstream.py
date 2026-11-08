#!/usr/bin/env python3
"""test-pinned-upstream.py XOLOTL_CHECKOUT

Check install-target.sh against Xolotl's real code at the commit this target
is tested with (PIN), without a GPU, a model or a build:

  * validate_checkout accepts the checkout (files, CMake options, engine flags);
  * the server config install-target.sh writes goes through the server's own
    read_config / engine_args / child_env / api_key_of, and the DeepSeek-V4.1
    shim (serve_ds41.py) does not refuse it;
  * every engine flag and STRATA_* variable it sets is read by the engine source;
  * /health still reports "service": "strata", "model" and "loaded", which the
    installer's readiness probe and the manager's detection rely on;
  * the Engram index engram-index.py writes is the one ds41_engram.cpp reads;
  * fetch-llama.sh still names its llama.cpp pin the way the installer parses it.

The checkout's Python packages must be importable (CI installs its
requirements.txt). Change upstream-commit.txt only after this passes against
the new commit.
"""
import importlib.util
import json
import os
import re
import struct
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
    return subprocess.run(["bash", "-c", prelude + script], env={**os.environ, **env, "XOLOTL_DIR": str(checkout)},
                          capture_output=True, text=True)


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    if (root / ".git").exists():
        head = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        check(head == PIN, f"the checkout is the pinned commit {PIN} (it is {head or 'unknown'})")

    r = helpers(root, {}, 'validate_checkout "$XOLOTL_DIR"')
    check(r.returncode == 0, "validate_checkout accepts the pinned checkout" + (f": {r.stderr.strip()}" if r.returncode else ""))

    key = "0123456789abcdef" * 4
    env = {"XOLOTL_DATA_DIR": "/var/lib/xolotl", "XOLOTL_CONTEXT": "131072", "XOLOTL_ARENA_GIB": "60",
           "XOLOTL_DSPARK": "true", "XOLOTL_MODEL_NAME": "deepseek-v4.1-flash", "api_key": key}
    r = helpers(root, env, "export api_key; server_config")
    check(r.returncode == 0, "server_config writes a config")
    if r.returncode:
        print(r.stderr, file=sys.stderr)
        return 1
    cfg_text = r.stdout
    tmp = Path(tempfile.mkdtemp(prefix="xolotl-upstream-"))
    cfg_path = tmp / "xolotl-ds41.json"
    cfg_path.write_text(cfg_text, encoding="utf-8")

    # The shim patches the server module; import it the way the unit runs it.
    sys.path[:0] = [str(root), str(root / "tools"), str(root / "tools" / "v41")]
    spec = importlib.util.spec_from_file_location("serve_ds41", root / "tools/v41/serve/serve_ds41.py")
    shim = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shim)
    S = shim.S
    cfg = S.read_config(cfg_path)
    for step in ("split_joined_args", "lift_reasoning_effort_arg"):
        if hasattr(S, step):
            getattr(S, step)(cfg)
    args = S.engine_args(cfg)
    check(args[:2] == ["-m", "/var/lib/xolotl/models/v41-xq-1017-v4/V41-XQ-1017-v4.gguf"],
          f"engine_args starts with the model: {args[:2]}")
    engine_src = "".join(p.read_text(encoding="utf-8", errors="replace")
                         for p in (root / "tools/v41/engine").glob("*.cpp"))
    unknown = [a for a in args if a.startswith("-") and not re.fullmatch(r"-?[0-9.]+", a) and f'"{a}"' not in engine_src]
    check(not unknown, f"ds41_generate reads every flag the server passes (unknown: {unknown})")
    check(cfg["exe"].endswith("/build-xolotl/ds41_generate"), "the engine is build-xolotl/ds41_generate")
    sources = engine_src + "".join(p.read_text(encoding="utf-8", errors="replace")
                                   for d in ("src", "include") for p in (root / d).rglob("*") if p.suffix in (".cpp", ".cu", ".h", ".hpp"))
    unread = [k for k in cfg["env"] if k.startswith("STRATA_") and f'"{k}"' not in sources]
    check(not unread, f"the engine reads every STRATA_* setting the config sets (unread: {unread})")
    child = S.child_env(cfg)
    check(child.get("CUDA_VISIBLE_DEVICES") == "0" and child.get("STRATA_ENGRAM_RAWDEV") == "0"
          and child.get("STRATA_SERVE_DSPARK", "").endswith("V41-MTP-Vision-1017.Q2_K.gguf"),
          "child_env runs the engine on GPU 0 with the config's settings")
    check(S.api_key_of(cfg.get("api_key", "")) == key, "the server takes the API key from the config")
    check(shim.vision_refusal(cfg) is None, "serve_ds41.py accepts the text-only config")
    main_src = Path(root / "serve/server.py").read_text(encoding="utf-8")
    check('cfg.get("host")' in main_src and 'cfg.get("api_key"' in main_src and 'cfg.get("tokenizer")' in main_src,
          "the server reads host, api_key and tokenizer from its config")
    for flag in ("--engine", "--config", "--port"):
        check(f'"{flag}"' in main_src, f"the server accepts {flag} (the unit's ExecStart)")
    health = re.search(r'path in \("/health", "/api/health"\):(.{0,900})', main_src, re.S)
    body = health.group(1) if health else ""
    check(bool(health) and '"service": "strata"' in body and '"loaded"' in body and '"model"' in body,
          '/health reports service "strata", the model id and loaded')

    # engram-index.py against the engine's own lookup (index weight_map -> shard).
    engram_src = (root / "tools/v41/engine/ds41_engram.cpp").read_text(encoding="utf-8")
    check('model.safetensors.index.json' in engram_src and '".engram.embed."' in engram_src and '"weight"' in engram_src
          and '"scale"' in engram_src, "ds41_engram.cpp reads layers.<L>.engram.embed.{weight,scale} through the index")
    shard_dir = tmp / "engram"
    shard_dir.mkdir()
    for shard, layer in (("model-00047-of-00048.safetensors", 1), ("model-00048-of-00048.safetensors", 14)):
        hdr = {f"layers.{layer}.engram.embed.weight": {"dtype": "F8_E4M3", "shape": [4, 8], "data_offsets": [0, 32]},
               f"layers.{layer}.engram.embed.scale": {"dtype": "F8_E8M0", "shape": [4, 1], "data_offsets": [32, 36]}}
        raw = json.dumps(hdr).encode()
        (shard_dir / shard).write_bytes(struct.pack("<Q", len(raw)) + raw + bytes(36))
    r = subprocess.run([sys.executable, str(HERE / "engram-index.py"), str(shard_dir),
                        "model-00047-of-00048.safetensors", "model-00048-of-00048.safetensors"], capture_output=True, text=True)
    index = json.loads((shard_dir / "model.safetensors.index.json").read_text()) if r.returncode == 0 else {}
    check(index.get("weight_map", {}).get("layers.14.engram.embed.scale") == "model-00048-of-00048.safetensors",
          "engram-index.py maps each Engram tensor to its shard")

    patch = (root / "tools/xolotl/ggml/xolotl-ggml.patch").read_text(encoding="utf-8", errors="replace")
    check("GGML_OP_DSV41_FAKE_QUANT" in patch and "GGML_OP_DSV41_HC_MIXES" in patch,
          "xolotl-ggml.patch carries the ops -DSTRATA_DSV41_FQ_OP and -DSTRATA_DSV41_HC_MIX require")
    fetch = (root / "tools/xolotl/fetch-llama.sh").read_text(encoding="utf-8")
    check(re.search(r"^PIN=[0-9a-f]{40}$", fetch, re.M) is not None, "fetch-llama.sh names its llama.cpp pin as PIN=<sha>")
    print(f"{'all' if not failures else len(failures)} upstream checks {'passed' if not failures else 'failed'} against {PIN}.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
