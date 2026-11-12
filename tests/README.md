# Tests

The default runner tests the router, monitor, installer, management commands,
target installers and integrations with stubs. It does not create a CT, contact
a model host or use the network. Live Proxmox, GPU and agent behavior still
need checks on the deployed host.

## Run

From the repository root:

```bash
bash tests/run-tests.sh                  # all suites and function coverage
bash tests/run-tests.sh --list           # suite names
bash tests/run-tests.sh installer        # one suite; e.g. manage, router, repo
bash tests/run-tests.sh --coverage       # function coverage only
bash tests/run-tests.sh --strict         # fail on any skipped case
```

Requirements: Linux, Bash 4.4+, Python 3, coreutils and the dependencies in
`tests/requirements-dev.txt`. Set `ROUTER_PYTHON` and `BRIDGE_PYTHON` for the
pytest suites; they need different FastAPI versions. Set `LITELLM_PYTHON` to
the venv built from `services/litellm-proxy/requirements.lock` for
`litellm-retries`. A missing test dependency skips its pytest suite.

The runner fails on a failed assertion or on a function in the installer or
manager without a matching `describe` block. Root-only target cases report a
skip when run without root. It also recognizes shell `SKIP` lines and
pytest/unittest skip totals. `--strict` and `CI=true` make every skip fail.
The Gitea Actions job runs as root with `--strict`; see
`.gitea/workflows/tests.yml` for its separate Python environments, ShellCheck,
ruff and pinned upstream checks. Every suite closes stdin so an unfed prompt
fails instead of blocking.

## Suite map

| Suites | Scope |
|---|---|
| `installer`, `manage` | Every extracted function in the main installer and `install/manage-model-servers.sh`; return values and external calls |
| `repo` | Embedded-file sync, owned-code list, text encoding, secret placement, unit hardening, target layout, pins and upgrade contract |
| `cloud-config`, `router`, `monitor`, `litellm-retries` | Routing, cloud/subscription configuration, health and LiteLLM retry behavior |
| `gitea`, `mattermost` | `tools/install-gitea.sh` and `tools/install-mattermost.sh` forward to their targets' `provision-lxc.sh --create-only` and pass an explicit mode through |
| `update`, `remote-update`, `signal-rollback` | In-container and host-side updates, config preservation, rollback and interrupted upgrades |
| `upgrade-all`, `pct-cluster`, `cluster-ssh` | Cluster-wide upgrade flow, remote `pct` routing and root SSH repair with mocked nodes |
| `nvidia`, `nvidia-lxc`, `host-gpu`, `gpu-drivers` | Host/guest driver matching, GPU selection, compatibility and update recovery |
| `pve-select`, `pve-firewall-swap` | Proxmox choices and locked firewall-file replacement |
| `<target>-install`, `<target>-provision`, other `<target>-*` | Each target's install, settings, upgrade, rollback and integration behavior; registered automatically from `targets/*/test-*.sh` |
| `runner-skips`, `skip-report` | Skip detection and strict-mode behavior |

The runner also registers target Python tests for the llama.cpp bridge,
AirLLM, Open Terminal, Hermes, OpenClaw, OpenCode, DeepSeek Harness, ComfyUI,
Honcho and hcom. The complete
suite list is the `add_suite` registry in `tests/run-tests.sh`; use `--list`
for exact names. Network-dependent pinned-upstream tests run in separate CI
jobs. `targets/hcom/test-live.py` is optional and uses local hcom, Mosquitto
and a temporary webhook; it is outside the default runner.

## Write a test

`tests/lib/extract-functions.py` reads top-level functions from the installer
and manager so tests can source them without executing the scripts. It skips
heredocs, including the installer's embedded copies, and uses the last
definition of a repeated function name, like Bash. Inspect extraction with:

```bash
python3 tests/lib/extract-functions.py ollama-smart-router-install.sh --list
python3 tests/lib/extract-functions.py install/manage-model-servers.sh --only cmd_add
```

Add `describe <exact-function-name>` to `test-installer.sh` or
`test-manage.sh`, set the function's globals, stub its external commands, and
assert both its result and important side effects. `tests/lib/mocks.sh`
prepends a temporary command directory to `PATH`; every stub records its
arguments in `MOCK_LOG`. `mock_command`, `mock_script`, `mock_calls` and
`mock_call_count` cover simple and conditional stubs. A credential test should
check that secrets never appear in logged command arguments.

`tests/lib/assert.sh` records failures without stopping the suite. Use
`assert_eq`, `assert_contains`, `assert_ok`, `assert_fail`, `assert_status`,
`assert_file_contains` or `assert_file_mode`. `assert_fail` and
`assert_status` run in a subshell so a function's `die` cannot exit the suite.

Two shell details matter when adding cases:

- Prompt functions assign a variable in the caller; run them directly with
  redirected output, not inside `$(...)`, which loses the assignment.
- A `die` inside `$(...)` exits only that subshell. Production callers must
  check the substitution's status (`|| return 1` or `|| exit 1`).

When stubbing curl, account for both response shapes: the Gitea user probe
expects JSON, while API calls append an HTTP status line. `grep -c` prints
`0` but exits 1 on no matches; avoid a fallback that prints a second zero.
