#!/usr/bin/env python3
"""test-pinned-upstream.py AVALON_CHECKOUT

Check install-target.sh against Avalon's real code at the commit this target
is tested with (upstream-commit.txt), without a GPU, a model or a build:

  * validate_checkout accepts the checkout (files, CMake options, server flags);
  * the llama-server arguments the unit gets carry every setting of upstream's
    own launcher (install.sh's avalon-server), with the same model files from
    the same Hugging Face repository as avalon-weights.txt;
  * the RDNA 3 targets the installer accepts are the ones upstream's install.sh
    detects, and the HIP build still takes AMDGPU_TARGETS;
  * /health stays public, and /v1/models still answers with "owned_by":
    "llamacpp" and the alias as "id" (the readiness probe, the router and the
    manager's detection rely on them);
  * --api-key-file still reads one key per line.

Change upstream-commit.txt only after this passes against the new commit.
"""
import os
import re
import shlex
import subprocess
import sys
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
    return subprocess.run(["bash", "-c", prelude + script],
                          env={**os.environ, **env, "AVALON_DIR": str(checkout)},
                          capture_output=True, text=True)


def launcher_args(install_sh):
    """The llama-server arguments of the avalon-server launcher upstream's
    install.sh writes, with its shell continuations joined."""
    m = re.search(r'exec "\$SERVER" (.*?)"\\\$@"', install_sh, re.S)
    if not m:
        return None
    text = m.group(1).replace("\\\\\n", " ").replace("\\\n", " ")
    return shlex.split(text)


def pairs(args):
    """Flag -> value (or True) for a llama-server argument list."""
    out, i = {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("-") and i + 1 < len(args) and not args[i + 1].startswith("-"):
            out[a] = args[i + 1]
            i += 2
        else:
            out[a] = True
            i += 1
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    if (root / ".git").exists():
        head = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        check(head == PIN, f"the checkout is at the pin {PIN}")

    r = helpers(root, {}, f"validate_checkout '{root}'")
    check(r.returncode == 0, "validate_checkout accepts the pinned checkout" + (f": {r.stderr.strip()}" if r.returncode else ""))

    install_sh = (root / "install.sh").read_text()
    upstream = launcher_args(install_sh)
    check(upstream is not None, "install.sh still writes the avalon-server launcher")
    env = {"AVALON_DATA_DIR": "/var/lib/avalon", "AVALON_CONFIG_DIR": "/etc/avalon", "AVALON_CONTEXT": "262144",
           "AVALON_MTP": "true", "AVALON_MODEL_NAME": "qwen3.8-flash-next-avalon", "AVALON_PORT": "8080"}
    ours = helpers(root, env, "server_args").stdout.split()
    if upstream:
        theirs, mine = pairs(upstream), pairs(ours)
        for flag, value in theirs.items():
            if flag in ("-m", "-md", "--host", "--port"):
                continue
            check(mine.get(flag) == value, f"the unit passes {flag} {value if value is not True else ''}".rstrip()
                  + " like upstream's launcher")
        check(Path(theirs.get("-m", "")).name == Path(mine.get("-m", "")).name,
              f"the same model file: {theirs.get('-m')}")
        check(theirs.get("-md") is not None and mine.get("-md", "").endswith("/" + theirs["-md"]),
              f"the same MTP draft head: {theirs.get('-md')}")

    repo = re.search(r"^HF_REPO=(\S+)", install_sh, re.M)
    manifest = (HERE / "avalon-weights.txt").read_text()
    check(bool(repo) and f"https://huggingface.co/{repo.group(1)}/resolve/" in manifest,
          f"avalon-weights.txt downloads from upstream's repository {repo.group(1) if repo else '?'}")

    gfx = set(re.findall(r"\bgfx110[0-9]\b", re.search(r"for g in ([^;]+);", install_sh).group(1)))
    check(gfx == {"gfx1100", "gfx1101", "gfx1102"}, f"upstream detects the RDNA 3 targets the installer accepts ({sorted(gfx)})")
    hip = (root / "ggml/src/ggml-hip/CMakeLists.txt").read_text()
    check("AMDGPU_TARGETS" in hip and "CMAKE_HIP_ARCHITECTURES" in hip, "the HIP build still takes AMDGPU_TARGETS")

    http = (root / "tools/server/server-http.cpp").read_text()
    public = re.search(r"get_public_endpoints = \[\]\(\) \{(.*?)\};", http, re.S)
    check(bool(public) and '"/health"' in public.group(1), "/health is a public endpoint (no key needed)")
    ctx = (root / "tools/server/server-context.cpp").read_text()
    info = re.search(r"static json get_res_model_info\(.*?\n\}", ctx, re.S)
    check(bool(info) and '{"owned_by", "llamacpp"}' in info.group(0) and '{"id",       meta.model_name}' in info.group(0),
          '/v1/models lists the model as "id" with "owned_by": "llamacpp"')
    check(re.search(r"model_name = \*params_base\.model_alias\.begin\(\)", ctx) is not None,
          "the alias (--alias) is the model id")
    server = (root / "tools/server/server.cpp").read_text()
    check('ctx_http.get ("/v1/models"' in server and 'ctx_http.get ("/health"' in server, "/health and /v1/models are served")
    arg = (root / "common/arg.cpp").read_text()
    key = re.search(r'\{"--api-key-file"\}.*?getline\(key_file, key\)', arg, re.S)
    check(key is not None, "--api-key-file reads the keys line by line")

    if failures:
        print(f"{len(failures)} check(s) failed against {PIN}", file=sys.stderr)
        return 1
    print(f"Avalon {PIN}: every check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
