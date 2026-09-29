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
```

Exit status is non-zero if any assertion fails **or** any function has no
`describe` block, so this drops straight into CI.

Requirements: `bash` 4.4+, `python3`, and the usual coreutils. No network.

Current state: **736 assertions in the two main suites, 156/156 functions covered.**

| Suite | Script under test | Functions | Assertions |
|---|---|---|---|
| `installer` | `ollama-smart-router-install.sh` | 63 | 296 |
| `manage` | `install/manage-model-servers.sh` | 93 | 440 |

`run-tests.sh` also runs these suites, which have no per-function coverage:

| Suite | What it checks |
|---|---|
| `repo` | installer heredocs match the repo files (`tools/sync-embedded.py --check`), the installer-owned code list, no CRLF files, no secrets in `env/*.env`, every unit hardened, every `targets/*` has the standard scripts and no nested `.git`, the Ollama drop-in is hardened, the AirLLM hash lock, a single management tool, LiteLLM's own venv, `[proxy]` extra and hash lock |
| `update` | `tests/test-update.sh`: `install/update-router.sh` against a temporary config repo — owned-file list parsed as text, CRLF/syntax refusals, dry run, tunables and env kept, venv refresh, undo on a failed apply or pip install (end-to-end cases need root) |
| `nvidia` | `tests/test-nvidia.sh`: driver version parsing, host/LXC match check, headers package, verified `.part` download, idempotent re-runs |
| `llamacpp-*` | each `targets/llamacpp/test-*.sh`, including `test-upgrade.sh` (end-to-end `--upgrade` with rollback, needs root) |
| `bridge` | `targets/llamacpp/test_bridge.py` with pytest (skipped when pytest/fastapi/httpx are missing) |
| `ollama-*` | `targets/ollama/test-install.sh` (adopting a community-script CT, re-runs, `--upgrade` with checksum checks and rollback; end-to-end cases need root) and `test-provision.sh` (dry-run plans for the community script and presets) |
| `airllm-*` | `targets/airllm/test-install.sh` (helpers, fresh install, legacy migration, `--upgrade` with rollback; end-to-end cases need root) and `test-provision.sh` (dry-run plans) |
| `airllm` | `targets/airllm/test_server.py` with pytest: packet shapes, readiness gating, context-window fitting, cancellation, load-failure exit (airllm/torch are stubbed; runs under `BRIDGE_PYTHON`) |
| `router` | `tests/test_router.py`: keyword matching, classification scope, failover, header hygiene, vision handling and capability probing, API key, LM Studio discovery (v1/v0/OpenAI) and dispatch (pytest) |
| `monitor` | `tests/test_monitor.py`: host/service discovery, debounce, per-host alerts, delivery retry, parallel probes, keep-alive thread, LM Studio probes and token (pytest) |

Set `ROUTER_PYTHON` / `BRIDGE_PYTHON` to run the pytest suites under a
specific interpreter; the router and the bridge pin different fastapi versions.
CI (`.gitea/workflows/tests.yml`) builds one venv for each. Test tooling is
pinned in `tests/requirements-dev.txt`.

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
