# Unit tests

Unit tests for every function in `ollama-smart-router-install.sh` and
`manage-model-servers.sh`, plus the alerting rules in the `monitor.py` the
installer generates. Nothing here touches a Proxmox host, a Gitea server, an
Ollama backend or a real deployment — every external command is stubbed and the
Python suite replaces the webhook and the clock.

## Running

```bash
cd tests
./run-tests.sh                 # every suite + coverage report
./run-tests.sh installer       # one suite
./run-tests.sh manage
./run-tests.sh monitor
./run-tests.sh --coverage      # coverage only, no tests
./run-tests.sh --list          # list suite names
```

Exit status is non-zero if any assertion fails **or** any function has no
`describe` block, so this drops straight into CI.

Requirements: `bash` 4.4+, `python3`, and the usual coreutils. No network.

Current state: **835 assertions, 74/74 + 53/53 functions covered** (plus an integration
tests for the generated `apply-config.sh` and the four systemd units, which are
not functions).

| Suite | Script under test | Functions | Assertions |
|---|---|---|---|
| `installer` | `ollama-smart-router-install.sh` | 74 | 478 |
| `manage` | `manage-model-servers.sh` | 53 | 239 |
| `monitor` | generated `monitor.py` | — | 51 |
| `router` | generated `router.py` | — | 67 |

The coverage gate is a *shell* gate: it enumerates bash functions, so the Python
suite sits outside it. `monitor` and `router` are listed in `PY_SUITES` and run
after the others.

## Layout

```
tests/
├── run-tests.sh              # runner + coverage gate
├── test-installer.sh         # suite for the installer
├── test-manage.sh            # suite for the management script
├── test-monitor.py           # suite for the generated monitor.py
├── test-router.py            # suite for the generated router.py
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
| `prompt_until_valid` hung forever on exhausted stdin | `read` returning EOF was not distinguished from an empty answer, so an invalid default re-tested itself in an infinite loop |
| One down host posted four identical Mattermost alerts | health was keyed by `(tier, url)`, and a single-server deployment points all four tiers at the same URL |
| A slow backend posted a down/up pair every polling cycle | a single failed probe was treated as an outage; no consecutive-failure threshold |
| An ongoing outage was re-announced on every service restart | health lived only in memory and defaulted to "up", and `Restart=always` restarts every 10s |
| Open WebUI never came up on a fresh install, dying on `duplicate column name: info_json` | Open WebUI's own first-run migration, upstream. The installer now starts it alone, waits for the port, and resets the empty database once — `Requires=` was a real but *separate* bug, and blaming it first cost a whole diagnosis cycle |
| The installer's embedded copy of `manage-model-servers.sh` drifted from the standalone one | only the embedded copy reaches the container, so the file next to the installer can be edited and the deployment never sees it — now pinned byte-for-byte by `describe embedded_manage_script` |
| Every request through the TLS proxy returned 502 on a clean install | `open-webui serve` has *literal* defaults `host="0.0.0.0", port=8080` and ignores `HOST`/`PORT` entirely, so it bound the port nginx owned, died with "address already in use", and nothing was listening where nginx proxied |
| Every fresh install printed "nginx rejected the configuration" and then worked | the certificate was generated *after* `apply-config.sh` installed the site that names it, so `nginx -t` could not load it — a spurious warning that teaches you to ignore the real one |
| `TLS_EXTRA_SAN` with a single name did nothing at all | the split loop used a bare `read`, and `tr` leaves no newline after the last field — so the last name was always dropped, and a one-entry list is entirely last |
| `rank_meta` reported every candidate as "tied" whenever nothing was in band | it compared scores only, but `rank_candidates` groups ties by *distance first, then score* — and in the distance-ranked case every score floors to 0.0, so the tie-group metric was wrong precisely when it mattered |
| Provisioning reported success over a dead UI | `systemctl enable --now` on a `Type=simple` unit returns as soon as the process is forked; nothing checked that the port ever opened |
| `set-webhook --username <name>` rejected every value, including valid ones | the guard was written `(( $# >= 2 && -n "$2" ))`; inside `(( ))` that is *minus variable n* followed by a bare string, which is an arithmetic syntax error, so the test was always false |
| `remove 1 1` refused to run against the server minimum | the same server counted twice toward `remaining_count`, so the check saw one more removal than would actually happen |
| Every service crash-looped with `status=226/NAMESPACE`, and the only symptom was nginx returning 502 | `PrivateTmp=`/`ProtectSystem=`/`ProtectHome=` are a private *mount namespace*, and a container that may not build one does not run the unit unhardened — it does not run it at all. The installer had *asserted* in its comments that `nesting=1` made them safe; it now probes with a real transient unit and rewrites the units when the answer is no |
| The optional ZeroTier install could destroy a fully provisioned container | it was called bare, after Open WebUI's migrations, while `CT_CREATED` was still set and the ERR trap still armed — so a transient failure fetching `install.zerotier.com` ran `pct destroy`. Same for `configure_lxc_tun_device`, whose `return 1` fired straight into the trap. Both now use the `TLS_OK` pattern |
| An HTTP error page could be piped into a root shell | `curl -s … \| sudo bash` — `-s` suppresses the message AND exits 0 on a 404, so the error body is what gets executed. Now `curl -fsSL --proto "=https"`, and no `sudo` in the pipeline: `pct exec` is already root. The `sudo` package stays installed, for the operator at a container shell rather than for the installer |
| A repair run listed all four units as `active` and then announced that some were not | `pct exec` goes through `lxc-attach`, which allocates a pty whenever the host's stdout is a terminal; ONLCR then makes `is-active` return `active\r`. That PRINTS as `active` and compares equal to nothing. In `ct_wait_for_port` it was worse — `activating\r` matched no keep-waiting case, so the installer gave up on a service that was merely slow. Every captured value now goes through `ct_out` |
| A second outage after a recovery was silently swallowed | the test harness saved state before `announce()` but not after, so the recovery never cleared the last-posted fingerprint — a harness bug, but the same omission in the daemon loop would lose real alerts |

Each fix is in place and pinned by a regression assertion.

## Adding a test

1. `describe <function-name>` — the runner's coverage gate keys off this line,
   so the name must match the function exactly, one function per block.
2. Set whatever globals the function reads (the suite headers show the pattern).
3. Stub the external commands it shells out to.
4. Assert on both the return value and, where it matters, on `mock_calls`.

Adding a function to either script without a `describe` block makes
`./run-tests.sh` exit non-zero.

## The Python suite

The `start_openwebui_verified` block is worth reading as a pattern: it drives
the whole recover-and-retry path with a `pct` stub that changes its answer once
the `mv` has happened, so the retry is exercised rather than assumed. It also
re-learns the subshell rule — the function sets `OPENWEBUI_RESET`, so it must
be run with output redirected to a file, never inside `$(...)`.

`describe verify_service_executables` deliberately asserts on the *message*, not
just the return code. A failure there trips the installer's `ERR` trap, which
destroys the container — so if the diagnosis is not printed before the function
returns, the only evidence of which executable the service account could not run
goes with it.

The TLS tests run `openssl` for real rather than asserting on a command line:
a certificate is only worth checking if openssl made it, and the assertions
that matter — the key matching the certificate, `serverAuth` being present, the
IP being an `IP:` entry — are properties of the artefact, not of the arguments.
Note also that `ct_tls_ok` is tested by stubbing `pct`, never `bash`: a stub
named `bash` on PATH would replace the shell every later assertion in the file
runs its command with.

`test-router.py` covers the scoring and the decision log. The assertion that
earns its keep is `sum(terms) == score`: the log is only trustworthy if the
itemised terms reconcile exactly with the number that decided the routing, and
an early draft rounded the terms inside `score_breakdown`, so they did not.
Rounding now happens once, in `explain_candidates`, where the record is built.

`test-monitor.py` extracts `monitor.py` and `monitor.ini` from the installer's
heredocs into a temp dir, imports the module with `post_mattermost` replaced by
a list-appender, and calls `evaluate_cycle` / `announce` directly with a
scripted list of probe results and an explicit timestamp. Nothing sleeps and
nothing resolves a hostname, so a two-hour outage runs in milliseconds.

Two traps specific to it:

**`os.environ` is process-global.** Each case re-imports the module to simulate
a restart, so an override left behind by one case silently configures the next.
`start()` clears every key in `OVERRIDES` first — an early draft "passed" a
threshold assertion purely on a leaked `MONITOR_FAILURE_THRESHOLD=1`.

**State is a file, so cases must not share one.** Every case passes its own
`state_file`; reusing the default would let one case's remembered outage
suppress the next case's alert.

`cycles()` mirrors `run_health_checks()`'s body exactly, including the second
`save_state()` after `announce()` — that write persists the last-posted
fingerprint. An earlier draft omitted it and a legitimate second outage looked
suppressed, because the recovery that should have cleared the fingerprint never
reached disk.
