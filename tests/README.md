# Shell unit tests

Unit tests for every function in `ollama-smart-router-install.sh` and
`manage-model-servers.sh`. Nothing here touches a Proxmox host, a Gitea server,
an Ollama backend or a real deployment — every external command is stubbed.

## Running

```bash
cd tests
./run-tests.sh                 # every suite + coverage report
./run-tests.sh installer       # one suite
./run-tests.sh manage
./run-tests.sh --coverage      # coverage only, no tests
./run-tests.sh --list          # list suite names
./run-tests.sh --strict        # also fail if any cases were skipped
```

Exit status is non-zero if any assertion fails **or** any function has no
`describe` block, so this drops straight into CI.

**Skipped cases.** Most end-to-end cases of the target installers need root,
and their suites skip them otherwise ("SKIP …"). The runner also recognizes
other leading `skip`/`skipped:` lines and pytest/unittest skipped counts. The
run then still passes and lists the skips. With `--strict`, or when `CI=true`,
any skip fails the run, so CI cannot go green without them. Suites are
registered in `run-tests.sh` with one `add_suite NAME KIND FILE [PYTHON]` line
each. The CI workflow uses
`--strict`, so its job must run as root. The provisioner suites (Hermes, Gitea,
Mattermost) need no root: they stub `id`, so their whole runs always run.

Requirements: `bash` 4.4+, `python3`, and the usual coreutils. No network.

`run-tests.sh` reports current assertion totals and function coverage at the
end of each run. Use `--coverage` for the function coverage report alone.

| Suite | Script under test |
|---|---|
| `installer` | `ollama-smart-router-install.sh` |
| `manage` | `install/manage-model-servers.sh` |

`run-tests.sh` also runs these suites, which have no per-function coverage:

| Suite | What it checks |
|---|---|
| `repo` | installer heredocs match the repo files (`tools/sync-embedded.py --check`), the installer-owned code list, no CRLF, Windows-1252 double-encoded or invalid UTF-8 text (tracked files via `git ls-files`, or a tree walk outside a checkout; a scan that cannot run fails), no secrets in `env/*.env`, every unit hardened, every `targets/*` has the standard scripts and no nested `.git`, the Ollama drop-in is hardened, the AirLLM hash lock, a single management tool, LiteLLM's own venv, `[proxy]` extra and hash lock |
| `runner-skips` / `skip-report` | `runner-skips` runs `run-tests.sh` itself: each pytest suite gets its own file and interpreter, and the last suite reaches the result line; in a scratch copy of the runner, a passing suite that reports a shell `skip`/`SKIP`/`skipped:` line, a pytest summary or a unittest summary fails `--strict` (and `CI=true`) but passes an ordinary run, which lists it. `skip-report` unit-tests the parser |
| `update` | `tests/test-update.sh`: `install/update-router.sh` against a temporary config repo — owned-file list parsed as text, CRLF/syntax refusals, dry run, tunables and env kept, venv refresh, undo on a failed apply or pip install (end-to-end cases need root) |
| `remote-update` | `tests/test-remote-update.sh`: update wrapper with mocked `pct` and container commands — location and CT prompts, arbitrary working directory, installed unit and runtime scan, host staging, container direct update, option forwarding, failure propagation, cleanup, root check, CRLF refusal before any CT is touched, root-owned archive, and container mode skipping its own clone (or refusing to run from the deployed config repo) |
| `mattermost` | `tests/test-mattermost.sh`: `tools/install-mattermost.sh` forwards to `targets/mattermost/provision-lxc.sh --create-only`, and passes an explicit mode through |
| `gitea` | `tests/test-gitea.sh`: `tools/install-gitea.sh` forwards to `targets/gitea/provision-lxc.sh --create-only`, and passes an explicit mode through |
| `nvidia` | `tests/test-nvidia.sh`: driver version parsing, host/LXC match check, headers package, verified `.part` download, idempotent re-runs; host mode: the kernel module flavour, nouveau still loaded, the boot-time modules and device-node unit, loading without a reboot |
| `host-gpu` | `tests/test-host-gpu.sh`: `tools/setup-host-gpu.sh` with stubbed `nvidia-smi`, `lspci`, `id`, `modprobe`, `apt-get` and driver helper, and a fake sysfs, `/dev`, firmware and modprobe.d. NVIDIA: a loaded driver only reported, generation answers and model numbers, the `--allow` limit, consent and a refused install, required and optional needs without a card or with one bound to `vfio-pci`, nouveau needing a reboot (exit 2), the real compute capability winning, cards outside RTX 20-50 or with an unreadable compute capability ready for unrestricted targets and refused by `--allow`, dry run. AMD Radeon and Intel Arc: a working card reported with its LLVM target and render node, vendor preference and NVIDIA-only targets, the suggestion from the PCI ID (an Intel iGPU ignored), the driver loaded now and at boot, missing firmware from `pve-firmware`, a card the loaded driver did not take (exit 2), a blacklisted driver, `vfio-pci`, a no, Arc B's 6.12 kernel floor, model numbers; and the menus on a pseudo-terminal |
| `llamacpp-*` | each `targets/llamacpp/test-*.sh`, including `test-upgrade.sh` (end-to-end `--upgrade` with rollback, needs root; the Vulkan backend's Debian 13 packages, build flags, discrete-GPU and render-node checks, and the Debian release each backend needs), `test-provision.sh` (Vulkan: a Debian 13 CT with the render node, no NVIDIA helper) and `test-gpu-selector.sh` (choosing an AMD or Intel render node) |
| `bridge` | `targets/llamacpp/test_bridge.py` with pytest (skipped when pytest/fastapi/httpx are missing) |
| `ollama-*` | `targets/ollama/test-install.sh` (adopting a community-script CT, re-runs, `--upgrade` with checksum checks and rollback; AMD: the installed release's ROCm libraries, checksum-verified before anything stops, kept by `--upgrade`; Intel Arc: Mesa's Vulkan driver; end-to-end cases need root) and `test-provision.sh` (dry-run plans for the community script and presets; `GPU=auto` finding NVIDIA, AMD by `/dev/kfd` or an Arc render node, not an iGPU) |
| `strata-*` | `targets/strata/test-install.sh` (`setup.sh --help` parsing against the documented and a minimal option set, launcher selection and its fallback, fresh install as the `strata` account, unchanged/changed/stopped reruns, a failed fetch that leaves the service running, pinned `--upgrade`, rollback without network, refusals; end-to-end cases need root) and `test-provision.sh` (dry-run plans, family defaults, device group, validation, unit hardening). `targets/strata/test-pinned-run-script.py` needs network and runs as the separate `strata-upstream` CI job |
| `xolotl-*` | `targets/xolotl/test-install.sh` (checkout checks against a fixture tree, CMake arguments, the shipped weights manifest and its strict parser, the server config with the key only there, the settings record, `engram-index.py` against good, incomplete, duplicate and broken shards; end-to-end as root with stubbed git, venv, cmake, systemd, nvidia-smi and a fake Hugging Face: fresh install with the architecture read from the GPU, weights joined part by part and indexed, an unchanged rerun that neither downloads nor rehashes, new and pinned commits, re-applied settings and hand-edited configs, a stale llama.cpp tree, a failed fetch, snapshot failure, rollback and double failure restoring config and unit, resumed joins and downloads, corrupt parts and tokenizer files, a changed upstream hash refused before downloading, too little disk, DSpark off, the CUDA/GPU/RAM/group refusals, saved-settings semantics and the shared record checks), `test-provision.sh` (dry-run plans, RAM/arena/disk floors, validation, unit hardening, the CUDA/driver and RTX 50/CUDA 13 refusals; a host without an NVIDIA driver: a note in the dry run, and a real run stopped with a pointer to `tools/setup-host-gpu.sh`) and `test-cuda-toolkit.sh`. `targets/xolotl/test-pinned-upstream.py` needs network and Xolotl's Python packages and runs as the separate `xolotl-upstream` CI job |
| `open-terminal-*` | `targets/open-terminal/test-install.sh` (dependency-drift and env-file helpers, the unit's key/CORS settings, fresh install with a hash-locked venv and root-only key files, moved tag, dependency drift, unpinned version, upgrade, rollback to the previous venv, migration from the earlier layout; end-to-end cases need root), `test-provision.sh` (router CT ID vs. SSH address parsing, route-source parsing, SSH command quoting round trip, `pct` and `ssh` dry-run plans, `--integrate-only`, validation) and `test-integration.py` (stdlib unittest: mock Open WebUI and terminal; other connections and grants preserved, failed verify, wrong terminal key, malformed responses) |
| `hermes-*` | `targets/hermes/test-install.sh` (installer validation, rollback, credentials and gateway), `test-provision.sh` (Proxmox firewall, key delivery and reconfiguration), `test-direct-dispatch.py` (stdlib HTTP fakes: router inventory and ranking, direct backend auth, task affinity, model selection), and `test-integration.py` (Open WebUI registration) |
| `comfyui-*` | `targets/comfyui/test-install.sh` (validation, PyTorch build detection and index arguments, `/system_stats` parsing, the `current` link and pruning, community data adoption, moving uv's Python out of `/root` with minor-version links; end-to-end as root with stubbed systemd, curl, git, uv and runuser: adoption and rerun, model download checksums, a server that does not come back, CPU fallback warning, upgrade before adoption, a commit-verified side-by-side build, unchanged and failed-unit reruns, a moved tag, failed build or broken venv stopping nothing, pinned versions, rollback and double failure, the drop-in restored, a stopped service kept stopped, pruning; the Klein weights against a fake Hugging Face: the shipped manifest, download, verified reruns, resume, disk space, hash and size mismatches, the gated 9B file with no, a refused or a malformed token, Hugging Face's hash and the pin, the token only in a root-only header file), `test-provision.sh` (helpers: allow list, GPU menu answer, firewall file, `net0` firewall flag, router parsing; dry-run plans for every mode, validation; whole runs against a fake Proxmox host: checks before the CT exists, presets, firewall before adoption, NVIDIA helper, the admin token staged as a file and never in argv, `--integrate-only`, `--no-webui`; the weights checked and the Hugging Face token accepted before the CT exists, pushed as a file and removed, also after a failed guest step) and `test-integration.py` (stdlib unittest: mock Open WebUI image API and ComfyUI; default workflow and node mapping, other image settings kept, checkpoint choice, custom workflow kept, no checkpoints, both `/object_info` formats, previous settings restored when Open WebUI cannot reach ComfyUI, unsupported API, wrong token) |
| `gitea-*` | `targets/gitea/test-install.sh` (helpers: reserved names, the `app.ini` it writes, token parsing; end-to-end as root against a fake `gitea` and Gitea API: fresh setup with a locked `app.ini` and root-only results, unchanged rerun keeping the token, a revoked token replaced, an adopted browser-made `app.ini`, the API never answering, no token in curl argv) and `test-provision.sh` (dry-run plans for every mode, Debian 13 presets, validation and the guest `--dry-run`; as root with mocked Proxmox commands: checksum pinning, readiness retries and timeout, CT ID clashes, failed downloads, a cancelled install, `--reconfigure` of a stopped or missing CT) |
| `mattermost-*` | `targets/mattermost/test-install.sh` (helpers, including `mmctl` JSON in all three shapes; end-to-end as root against a fake `mmctl` with a real socket: local-mode drop-in and restart only on change, admin, team, channel and webhook created once, an empty SiteURL set, a deleted webhook recreated, Mattermost never ready) and `test-provision.sh` (dry-run plans for every mode, validation; as root with mocked Proxmox commands: checksum pinning, host checks before the community script, readiness wait and timeout, `--reconfigure`) |
| `airllm-*` | `targets/airllm/test-install.sh` (helpers, fresh install, legacy migration, `--upgrade` with rollback; end-to-end cases need root) and `test-provision.sh` (dry-run plans) |
| `airllm` | `targets/airllm/test_server.py` with pytest: packet shapes, readiness gating, context-window fitting, cancellation, load-failure exit (airllm/torch are stubbed; runs under `BRIDGE_PYTHON`) |
| `router` | `tests/test_router.py`: keyword matching, classification scope, failover, header hygiene, vision handling and capability probing, tool requests (tool support per kind, filtering, class floor, 400 fail-forward, one model per agent loop, warnings), API key, LM Studio discovery (v1/v0/OpenAI) and dispatch (pytest) |
| `monitor` | `tests/test_monitor.py`: host/service discovery, debounce, per-host alerts, delivery retry, parallel probes, keep-alive thread, LM Studio probes and token (pytest) |

Set `ROUTER_PYTHON` / `BRIDGE_PYTHON` to run the pytest suites under a
specific interpreter; the router and the bridge pin different fastapi versions.
CI (`.gitea/workflows/tests.yml`) builds one venv for each. Test tooling is
pinned in `tests/requirements-dev.txt`. CI discovers every repository `.sh`
file for ShellCheck, including helper fixtures; scoped directives explain
intentional dynamic sourcing and settings consumed by extracted functions.

Every suite starts with `exec </dev/null`, so a prompt under test that is not
fed input explicitly fails instead of blocking on the runner's stdin.

## Layout

```
tests/
├── run-tests.sh              # runner + coverage gate
├── test-installer.sh         # suite for the installer
├── test-manage.sh            # suite for the management script
└── lib/
    ├── extract-functions.py  # heredoc-aware function extractor
    ├── assert.sh             # assertions, counters, summary
    └── mocks.sh              # command stubs and fixtures
```

## How a function gets tested

The scripts are single-file installers, not libraries — they run work at the
top level. Sourcing one would create a container. So `lib/extract-functions.py`
pulls out just the top-level function definitions and the suite sources *those*.

The extractor is heredoc-aware, and that is not incidental: the installer
carries a **complete copy of `manage-model-servers.sh`** inside a `MANAGEEOF`
heredoc, plus several embedded Python programs. A naive `grep '^name() {'`
would pull `cmd_add`, `git_push_authenticated` and friends out of that embedded
copy and test the wrong text. The extractor tracks heredoc state so:

- definitions inside a heredoc are skipped entirely, and
- a `}` inside a heredoc never terminates a function early.

Where the same name is defined twice, the last definition wins — matching what
bash itself would do.

Verify the extraction independently:

```bash
python3 lib/extract-functions.py ../ollama-smart-router-install.sh --list
python3 lib/extract-functions.py ../install/manage-model-servers.sh --only cmd_add
```

## Mocks

`lib/mocks.sh` prepends a temp directory to `PATH` and drops executable stubs
into it. Every stub appends its invocation to `$MOCK_LOG`, so a test can assert
on what a function *tried to do*, not just what it returned — which is how the
credential-handling tests verify a token never lands on a command line.

```bash
mock_command pct 0                  # stub: log args, exit 0
mock_command curl 0 '{"login":"x"}' # stub with stdout
mock_script  curl <<'EOF'           # stub with real logic
case "$*" in
  *-X*) echo '{}'; echo 200;;
  *)    echo '{"login":"tester"}';;
esac
EOF
mock_calls        # everything invoked so far
mock_call_count X # occurrences of a substring
```

Fixtures: `make_config_repo <dir>` builds a config repo laid out exactly as
`apply-config.sh` expects. `PVESM_REAL_OUTPUT` is the user's actual
`pvesm status` output, including the `(KiB)` unit tokens and an inactive row —
that string is what caught the storage-parsing bug.

### Two mocking traps worth knowing

**`curl` is called two different ways.** `gitea_probe_user` calls curl *without*
`-X` and parses bare JSON; `gitea_api` calls it *with* `-X` and appends a
`\n<status>` line via `-w`. A stub that answers both identically makes the probe
choke on the trailing status digits. Every curl stub in the suites branches on
`-X` first.

**`grep -c` prints `0` and exits `1`.** A `|| echo 0` fallback therefore emits
`0\n0`. `mock_call_count` swallows the exit status instead.

## Assertions

```
assert_eq / assert_ne              <label> <expected> <actual>
assert_contains / assert_not_contains
assert_ok / assert_fail            <label> <command...>
assert_status                      <label> <code> <command...>
assert_file_contains / assert_file_mode
skip                               <label> [reason]
```

`assert.sh` deliberately does **not** `set -e` — a failed assertion records the
failure and lets the suite continue, so one broken function does not hide the
rest.

`assert_fail` and `assert_status` run the command in a **subshell**. Most of
these functions end in `die`, which calls `exit`; invoked in-process that would
terminate the entire suite at the first expected-failure assertion.

## Patterns that come up when testing these scripts

**Prompt functions must not run inside `$(...)`.** They assign to a variable
named by their caller; a command substitution is a subshell, so the assignment
is discarded and the assertion always sees the old value. Redirect to a file
instead:

```bash
out="$(mktemp)"
prompt_network_config > "$out" 2>&1 <<< $'\n\n\n\n' || true
assert_eq "keeps defaults" "10.0.0.5/24" "$IP_CIDR"
```

**The same subshell rule is what the tests keep catching in the scripts.**
`key="$(tier_env_key "$tier")"` looks like it validates the tier, but
`tier_env_key`'s `die` only kills the substitution subshell — the caller
continues with an empty key. Assignment sites need `|| exit 1`. Three separate
bugs in this family have been found by these tests.

## Bugs these tests have found

| Symptom | Cause |
|---|---|
| `set-tier turbo …` accepted an unknown tier | `die` inside `$(tier_env_key …)` killed only the subshell |
| `add --tier bogus` accepted an unknown tier | same |
| `get_tier turbo` returned success and an empty list | same, nested two deep |
| `git_push_authenticated` continued with an empty remote | only the exit status of `git remote get-url` was checked |
| `large` selected the 70B model that defines `xlarge` | band ceilings were inclusive, so adjacent bands overlapped, and the size bias rewarded absolute size rather than position in the band |
| `prompt_until_valid` hung forever on exhausted stdin | `read` returning EOF was not distinguished from an empty answer, so an invalid default re-tested itself in an infinite loop |

Each fix is in place and pinned by a regression assertion.

## Adding a test

1. `describe <function-name>` — the runner's coverage gate keys off this line,
   so the name must match the function exactly, one function per block.
2. Set whatever globals the function reads (the suite headers show the pattern).
3. Stub the external commands it shells out to.
4. Assert on both the return value and, where it matters, on `mock_calls`.

Adding a function to either script without a `describe` block makes
`./run-tests.sh` exit non-zero.
