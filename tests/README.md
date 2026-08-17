# Shell unit tests

Unit tests for every function in `ollama-smart-router-install.sh` and
`manage-model-servers.sh`. Nothing here touches a Proxmox host, a Gitea server,
an Ollama backend or a real deployment — every external command is stubbed.

## Running

```bash
cd tests
./run-tests.sh                 # both suites + coverage report
./run-tests.sh installer       # one suite
./run-tests.sh manage
./run-tests.sh --coverage      # coverage only, no tests
./run-tests.sh --list          # list suite names
```

Exit status is non-zero if any assertion fails **or** any function has no
`describe` block, so this drops straight into CI.

Requirements: `bash` 4.4+, `python3`, and the usual coreutils. No network.

Current state: **415 assertions, 104/104 functions covered.**

| Suite | Script under test | Functions | Assertions |
|---|---|---|---|
| `installer` | `ollama-smart-router-install.sh` | 55 | 245 |
| `manage` | `manage-model-servers.sh` | 49 | 170 |

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
python3 lib/extract-functions.py ../manage-model-servers.sh --only cmd_add
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

Each fix is in place and pinned by a regression assertion.

## Adding a test

1. `describe <function-name>` — the runner's coverage gate keys off this line,
   so the name must match the function exactly, one function per block.
2. Set whatever globals the function reads (the suite headers show the pattern).
3. Stub the external commands it shells out to.
4. Assert on both the return value and, where it matters, on `mock_calls`.

Adding a function to either script without a `describe` block makes
`./run-tests.sh` exit non-zero.
