#!/usr/bin/env python3
"""Check the Colibri target against colibri's real code at the pinned commit.

Usage: python3 test-pinned-upstream.py /path/to/fetched/colibri
The repository must have fetched the pinned commit (COLIBRI_DEFAULT_COMMIT in
install-target.sh) into FETCH_HEAD. Nothing is built or started: coli's own
argument parser runs from an exported tree, the rest is read from the source.

What install-target.sh, colibri.service and OSR rely on:
- c/Makefile installs coli to $(PREFIX)/bin and the engines to
  $(PREFIX)/libexec/colibri, with PREFIX overridable, and builds CUDA against
  $(CUDA_HOME) (default /usr/local/cuda);
- `coli serve` takes the flags the generated launcher passes, its --api-key
  defaults to COLI_API_KEY (the key comes from secrets.env, never argv), and it
  needs a model (so a model-less install parks instead of serving);
- upstream's own `coli start` uses --auto-tier, --gpu auto for CUDA and
  COLI_VULKAN=1 / COLI_VK_SHADERS for Vulkan, as the launcher does;
- the Host guard admits loopback, the bind address, --allowed-host and *
  (the router reaches a 0.0.0.0 bind by the CT's address);
- /v1/models lists the model owned_by colibri with capabilities and
  context_length (manage-model-servers detection, the router's sizes, tools);
- the ids router.ini sizes are ids colibri announces.
"""

import configparser
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import types

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def pin():
    text = (HERE / "install-target.sh").read_text(encoding="utf-8")
    pins = set(re.findall(r"^COLIBRI_DEFAULT_COMMIT=([0-9a-f]{40})$", text, re.M))
    provision = (HERE / "provision-lxc.sh").read_text(encoding="utf-8")
    pins |= set(re.findall(r"^COLIBRI_DEFAULT_COMMIT=([0-9a-f]{40})$", provision, re.M))
    assert len(pins) == 1, f"install-target.sh and provision-lxc.sh pin different commits: {pins}"
    return pins.pop()


def git(repo, *args, binary=False):
    out = subprocess.check_output(["git", "-c", f"safe.directory={repo}", "-C", str(repo), *args])
    return out if binary else out.decode("utf-8")


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL {message}")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: test-pinned-upstream.py /path/to/fetched/colibri")
    repo = Path(sys.argv[1]).resolve()
    expected = pin()
    actual = git(repo, "rev-parse", "FETCH_HEAD").strip()
    check(actual == expected, f"expected colibri {expected}, got {actual}")

    def show(path):
        return git(repo, "show", f"FETCH_HEAD:{path}")

    makefile = show("c/Makefile")
    for line in ("PREFIX     ?= /usr/local", "BINDIR     ?= $(PREFIX)/bin",
                 "LIBEXECDIR ?= $(PREFIX)/libexec/colibri", "CUDA_HOME ?= /usr/local/cuda",
                 "NVCC      ?= $(CUDA_HOME)/bin/nvcc"):
        check(f"\n{line}\n" in makefile, f"c/Makefile lacks: {line}")
    install = makefile[makefile.index("\ninstall:"):makefile.index("\nuninstall:")]
    check("$(INSTALL) -m 755 coli $(DESTDIR)$(BINDIR)/coli" in install, "make install no longer puts coli in BINDIR")
    check("$(DESTDIR)$(LIBEXECDIR)/qwen36$(EXE)" in install, "make install no longer puts the engines in LIBEXECDIR")
    check("shaders" not in install, "make install now installs shaders; COLI_VK_SHADERS may be wrong")
    check("VK_SPV    = shaders/qmatmul.spv" in makefile, "the Vulkan shaders are no longer built into c/shaders")
    check("glslc" in makefile, "the VK=1 build no longer uses glslc")

    coli = show("c/coli")
    check(re.search(r'_LIBEXEC = os\.path\.join\(os\.path\.dirname\(HERE\), "libexec", "colibri"\)', coli),
          "coli no longer finds its engines in ../libexec/colibri")
    check('ps.add_argument("--api-key",default=os.environ.get("COLI_API_KEY"))' in coli,
          "coli serve's --api-key no longer defaults to COLI_API_KEY")
    serve = coli[coli.index("def cmd_serve(a):"):]
    serve = serve[:serve.index("\ndef ")]
    check(serve.lstrip().startswith("def cmd_serve(a):\n    need_model(a.model)"),
          "coli serve no longer requires a model first")

    # coli's own parser, from an exported tree (no engine, no network).
    archive = git(repo, "archive", "--format=tar", "FETCH_HEAD", "c", binary=True)
    with tempfile.TemporaryDirectory(prefix="colibri-pinned-") as temporary:
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(temporary, filter="data")
        env = {k: v for k, v in os.environ.items() if not k.startswith("COLI")}
        helptext = subprocess.run([sys.executable, str(Path(temporary) / "c" / "coli"), "serve", "--help"],
                                  capture_output=True, text=True, env=env, timeout=120)
        check(helptext.returncode == 0, f"coli serve --help failed: {helptext.stderr[-2000:]}")
        for flag in ("--host", "--port", "--api-key", "--allowed-host", "--model", "--auto-tier", "--gpu"):
            check(re.search(rf"(^|[\s\[,]){re.escape(flag)}\b", helptext.stdout), f"coli serve has no {flag}")

    flow = show("c/setup_flow.py")
    launcher = flow[flow.index("def launcher_args("):]
    launcher = launcher[:launcher.index("\ndef ")]
    check('args += ["--gpu", "auto"]' in launcher, "coli start no longer passes --gpu auto for CUDA")
    check('args.append("--auto-tier")' in launcher, "coli start no longer passes --auto-tier")
    runenv = flow[flow.index("def run_environment("):]
    runenv = runenv[:runenv.index("\ndef ")]
    check('env["COLI_VULKAN"] = "1"' in runenv, "a Vulkan start no longer needs COLI_VULKAN=1")
    check('env["COLI_VK_SHADERS"]' in runenv, "a Vulkan start no longer sets COLI_VK_SHADERS")
    check('getenv("COLI_VK_SHADERS")' in show("c/backend_vulkan.c"), "the Vulkan backend no longer reads COLI_VK_SHADERS")

    server = show("c/openai_server.py")
    guard = server[server.index("def _check_host(self):"):]
    guard = guard[:guard.index("\n    def ")]
    check('LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1", ""}' in server, "the loopback hosts changed")
    check("allowed.update(self.server.allowed_hosts)" in guard, "--allowed-host no longer extends the Host guard")
    check('if "*" in allowed:' in guard, "--allowed-host '*' no longer turns the Host guard off")
    check("server_address[0]" in guard, "the bind address is no longer an allowed Host")
    check(re.search(r'"owned_by": "colibri"', server), "/v1/models no longer says owned_by colibri")
    entry = server[server.index("def model_entry(self):"):]
    entry = entry[:entry.index("\n    def ")]
    for key in ('entry["capabilities"]', 'entry["input_modalities"]', 'entry["context_length"]'):
        check(key in entry, f"/v1/models entries lack {key}")
    check('return ["image_generation"]' in server and 'return ["systemone", "decision"]' in server
          and 'return ["chat", "systemone"]' in server, "the capabilities /v1/models lists changed")

    # model-select.sh is colibri's whole text catalog: the same IDs, repos,
    # sizes, RAM, excludes and post-download steps, each pinned to a commit
    # (upstream's own where it pins one). The catalog module is standard
    # library only, so it is loaded from the pinned source as it is.
    catalog_module = types.ModuleType("setup_catalog")
    sys.modules["setup_catalog"] = catalog_module
    exec(compile(show("c/setup_catalog.py"), "c/setup_catalog.py", "exec"), catalog_module.__dict__)
    upstream_models = {entry.id: entry for entry in catalog_module.CATALOG if entry.modality == "text"}
    select = (HERE / "model-select.sh").read_text(encoding="utf-8")
    listed = re.search(r"COLIBRI_MODEL_IDS=\(([^)]*)\)", select).group(1).split()
    details = select[select.index("colibri_model_details() {"):select.index("        *) return 1 ;;")]
    blocks = dict(re.findall(r"\n        ([a-z0-9.-]+)\)\n(.*?);;", details, re.S))
    check(sorted(listed) == sorted(upstream_models),
          f"model-select.sh lists {sorted(listed)}; colibri's text catalog is {sorted(upstream_models)}")
    check(sorted(blocks) == sorted(listed), f"COLIBRI_MODEL_IDS {sorted(listed)} != the entries {sorted(blocks)}")
    sizes = [upstream_models[model_id].disk_gb for model_id in listed]
    check(sizes == sorted(sizes), "COLIBRI_MODEL_IDS is not smallest first")
    for model_id in listed:
        entry, body = upstream_models[model_id], blocks[model_id]
        fields = {k: v.strip("'") for k, v in re.findall(r"COLIBRI_MODEL_([A-Z_]+)=('[^']*'|\S+)", body)}
        check(fields.get("REPO") == entry.repo, f"{model_id}: repo {fields.get('REPO')} != catalog {entry.repo}")
        check(fields.get("NAME") == entry.name, f"{model_id}: name {fields.get('NAME')} != catalog {entry.name}")
        check(float(fields.get("GB", "0")) == entry.disk_gb, f"{model_id}: size {fields.get('GB')} != catalog {entry.disk_gb}")
        check(int(fields["MIN_MIB"]) == round(entry.ram_min_gb * 1024),
              f"{model_id}: RAM minimum {fields['MIN_MIB']} MiB != the catalog's {entry.ram_min_gb} GB")
        check(int(fields["GOOD_MIB"]) == round(entry.ram_good_gb * 1024),
              f"{model_id}: RAM comfort point {fields['GOOD_MIB']} MiB != the catalog's {entry.ram_good_gb} GB")
        check(re.fullmatch(r"[0-9a-f]{40}", fields.get("REVISION", "")), f"{model_id}: no pinned revision")
        if entry.revision != "main":
            check(fields["REVISION"] == entry.revision, f"{model_id}: pin {fields['REVISION']} != upstream's {entry.revision}")
        check(not entry.include, f"{model_id}: the catalog now has includes, which install-target.sh does not pass")
        check(fields.get("EXCLUDE", "").split() == list(entry.exclude),
              f"{model_id}: excludes {fields.get('EXCLUDE')} != catalog {entry.exclude}")
        post = ",".join(f"{tool}:{creates}" for tool, creates in entry.post_install)
        check(fields.get("POST", "") == post, f"{model_id}: post-download step {fields.get('POST')} != catalog {post}")
        # install-target.sh runs it as upstream's setup does: python3
        # <libexec>/tools/<tool>.py <model dir>, with the standard library only.
        for tool, _ in entry.post_install:
            source = show(f"c/tools/{tool}.py")
            imported = set(re.findall(r"^(?:import|from) ([A-Za-z_][A-Za-z0-9_]*)", source, re.M))
            check(imported <= set(sys.stdlib_module_names),
                  f"c/tools/{tool}.py imports beyond the standard library: {sorted(imported - set(sys.stdlib_module_names))}")
            check("sys.argv" in source or "argparse" in source, f"c/tools/{tool}.py no longer takes the model folder")
    check("$(LIBEXECDIR)/tools/" in install, "make install no longer installs tools/ (the post-download steps)")
    downloader = show("c/setup_download.py")
    for signature in ("def hf_token():", "def list_repo_files(repo, revision=",
                      "def bytes_present(model_dir, files", "def download_repo(repo, revision, model_dir, files, *, token=None, progress=None",
                      "def is_complete(model_dir", "class DownloadError("):
        check(signature in downloader, f"setup_download.py lacks: {signature}")
    check("setup_download.py" in install, "make install no longer installs setup_download.py")

    # The ids router.ini sizes (and the two the router keeps from tools) exist.
    registry = show("c/family_registry.py")
    announced = set(re.findall(r'model_id="([a-z0-9.\-]+)"', registry))
    ini = configparser.ConfigParser()
    ini.read(ROOT / "services/osr-router/router.ini")
    sized = [k for k in ini["model_sizes"] if k.endswith("-colibri") or k.startswith("mimo-v2.6")]
    check(len(sized) >= 10, f"router.ini sizes too few Colibri ids: {sized}")
    for name in sized + ["inkling-colibri", "olmoe-colibri"]:
        check(name in announced, f"router.ini's {name} is not an id colibri announces")
    print(f"PASS colibri {expected}: build layout, serve flags, key, Host guard, GPU run flags, "
          f"the {len(listed)} text-catalog models and their downloader, "
          f"/v1/models and {len(sized)} sized ids match the target")


if __name__ == "__main__":
    main()
