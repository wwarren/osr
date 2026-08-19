#!/usr/bin/env python3
"""Unit tests for the alerting rules in the generated monitor.py.

Everything the daemon does that is worth testing lives between "a probe came
back" and "a message was posted" — so this suite extracts monitor.py from the
installer's heredoc, imports it with the webhook and the clock replaced, and
drives `evaluate_cycle` / `announce` through scripted outages.

No network, no sleeping, no Mattermost. Run directly or via ../run-tests.sh:

    python3 test-monitor.py [path/to/ollama-smart-router-install.sh]

The rule under test throughout: the monitor is EDGE-triggered. A message means
a backend CHANGED state. Steady state — up or down — is silent.
"""
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    HERE, os.pardir, "ollama-smart-router-install.sh")

failures = []
checks = 0


# ── extraction ────────────────────────────────────────────────────────────────
def extract(repo_path, dest):
    """Pull one generated file back out of the installer's heredoc."""
    with open(INSTALLER, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    start = re.compile(r'''^cat > "\$\{REPO_DIR\}/%s" <<'?([A-Za-z_]+)'?$'''
                       % re.escape(repo_path))
    for i, line in enumerate(lines):
        m = start.match(line)
        if not m:
            continue
        body = []
        for nxt in lines[i + 1:]:
            if nxt == m.group(1):
                with open(dest, "w", encoding="utf-8") as out:
                    out.write("\n".join(body) + "\n")
                return dest
            body.append(nxt)
        raise SystemExit("unterminated heredoc for %s" % repo_path)
    raise SystemExit("no heredoc for %s in %s" % (repo_path, INSTALLER))


WORK = tempfile.mkdtemp(prefix="monitor-tests-")
MONITOR_PY = extract("services/ollama-monitor/monitor.py",
                     os.path.join(WORK, "monitor.py"))
MONITOR_INI = extract("services/ollama-monitor/monitor.ini",
                      os.path.join(WORK, "monitor.ini"))

# Env vars the tests toggle. They must be cleared between imports: os.environ is
# process-global, so a leftover from one case silently configures the next —
# which is exactly how an early draft of this file "passed" a threshold test.
OVERRIDES = ("MONITOR_FAILURE_THRESHOLD", "MONITOR_RECOVERY_THRESHOLD",
             "MONITOR_REPEAT_SECONDS", "MONITOR_STARTUP_NOTICE", "MONITOR_INI")

A = "http://a.example:11434"
B = "http://b.example:11434"
UP = {A: True, B: True}
A_DOWN = {A: False, B: True}


def start(env=None, state_file=None):
    """Import monitor.py fresh — the equivalent of the daemon starting."""
    for key in OVERRIDES:
        os.environ.pop(key, None)
    os.environ.update({
        # a backs fast+medium+large, b backs large+xlarge: one host, many tiers,
        # which is the shape that used to multiply every alert.
        "BACKEND_FAST": A,
        "BACKEND_MEDIUM": A,
        "BACKEND_LARGE": "%s,%s" % (A, B),
        "BACKEND_XLARGE": B,
        "MATTERMOST_WEBHOOK_URL": "http://webhook.invalid/hooks/test",
        "MONITOR_INI": MONITOR_INI,
        "MONITOR_STATE_FILE": state_file or os.path.join(WORK, "state.json"),
    })
    os.environ.update(env or {})
    sys.modules.pop("monitor", None)
    spec = importlib.util.spec_from_file_location("monitor", MONITOR_PY)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["monitor"] = mod
    spec.loader.exec_module(mod)
    mod.posted = []
    mod.post_mattermost = lambda msg, emoji=":warning:": (
        mod.posted.append(msg), True)[1]
    return mod


def cycles(mod, results, start_ts=1000.0, step=15.0):
    """Run one process lifetime over a list of {url: healthy} probe results.

    This mirrors run_health_checks()'s body exactly, including the save AFTER
    announce -- that second write persists the "what did we last say"
    fingerprint. Omitting it here (an earlier draft did) made a second outage
    look suppressed, because the recovery that should have cleared the
    fingerprint never reached disk.
    """
    state = mod.load_state()
    for i, health in enumerate(results):
        now = start_ts + i * step
        down, up, still, changed = mod.evaluate_cycle(health, state, now)
        if changed:
            mod.save_state(state)
        if mod.announce(down, up, still, state, now):
            mod.save_state(state)
    return state


def check(label, got, want):
    global checks
    checks += 1
    if got == want:
        print("    ok   %s" % label)
    else:
        failures.append(label)
        print("    FAIL %s\n           got  %r\n           want %r" % (label, got, want))


def describe(name):
    print("\n  %s" % name)


# ── one host, many tiers ──────────────────────────────────────────────────────
describe("a host backing three tiers alerts once, not once per tier")
m = start()
cycles(m, [UP] + [A_DOWN] * 10)
check("a single message", len(m.posted), 1)
check("naming every tier it served",
      all(t in m.posted[0] for t in ("fast", "medium", "large")), True)
check("and nothing further while it stays down",
      [p for p in m.posted if "Recovery" in p], [])

# ── silence ───────────────────────────────────────────────────────────────────
describe("steady state is silent")
m = start(state_file=os.path.join(WORK, "s-steady.json"))
cycles(m, [UP] * 240)
check("240 healthy cycles post nothing", len(m.posted), 0)

describe("a flapping backend is damped")
flap = [A_DOWN if i % 2 else UP for i in range(200)]
m = start(state_file=os.path.join(WORK, "s-flap.json"))
cycles(m, flap)
check("alternating results never reach a threshold", len(m.posted), 0)

describe("thresholds of 1 reproduce the original flood")
m = start(env={"MONITOR_FAILURE_THRESHOLD": "1", "MONITOR_RECOVERY_THRESHOLD": "1"},
          state_file=os.path.join(WORK, "s-flood.json"))
cycles(m, flap)
check("the same input posts on every flip", len(m.posted) > 100, True)

# ── transitions ───────────────────────────────────────────────────────────────
describe("a real outage posts exactly one alert and one recovery")
m = start(state_file=os.path.join(WORK, "s-cycle.json"))
cycles(m, [UP] + [A_DOWN] * 5 + [UP] * 5)
check("two messages total", len(m.posted), 2)
check("the second is the recovery", "Recovery" in m.posted[1], True)

describe("the failure threshold is honoured exactly")
m = start(state_file=os.path.join(WORK, "s-thresh.json"))
cycles(m, [UP] + [A_DOWN] * 2)
check("two failures with threshold 3 stay quiet", len(m.posted), 0)
m = start(state_file=os.path.join(WORK, "s-thresh2.json"))
cycles(m, [UP] + [A_DOWN] * 3)
check("the third failure opens the alert", len(m.posted), 1)

describe("a newly added backend is assumed healthy")
m = start(state_file=os.path.join(WORK, "s-new.json"))
cycles(m, [UP] * 3)
check("adding a server does not announce it", len(m.posted), 0)

# ── restarts ──────────────────────────────────────────────────────────────────
describe("a restart mid-outage does not re-announce")
sf = os.path.join(WORK, "s-restart.json")
m = start(state_file=sf)
cycles(m, [UP] + [A_DOWN] * 5)
check("the first process alerts once", len(m.posted), 1)
check("and records it", json.load(open(sf))["servers"][A]["healthy"], False)
m2 = start(state_file=sf)
cycles(m2, [A_DOWN] * 20)
check("the restarted process is silent", len(m2.posted), 0)
m3 = start(state_file=sf)
cycles(m3, [A_DOWN] * 2 + [UP] * 5)
check("but still reports the recovery", len(m3.posted), 1)
check("as a recovery", "Recovery" in m3.posted[0], True)

describe("the startup notice fires only when the start is news")
sf = os.path.join(WORK, "s-startup.json")
m = start(state_file=sf)
m.send_startup_notice(m.load_state())
check("first ever start posts", len(m.posted), 1)
cycles(m, [UP])
m2 = start(state_file=sf)
m2.send_startup_notice(m2.load_state())
check("an unchanged restart is silent", len(m2.posted), 0)
m3 = start(env={"BACKEND_XLARGE": "http://c.example:11434"}, state_file=sf)
m3.send_startup_notice(m3.load_state())
check("a changed backend set posts again", len(m3.posted), 1)
m4 = start(env={"MONITOR_STARTUP_NOTICE": "always"}, state_file=sf)
m4.send_startup_notice(m4.load_state())
check("startup_notice=always always posts", len(m4.posted), 1)
m5 = start(env={"MONITOR_STARTUP_NOTICE": "never"},
           state_file=os.path.join(WORK, "s-never.json"))
m5.send_startup_notice(m5.load_state())
check("startup_notice=never never posts", len(m5.posted), 0)

# ── the unchanged-state backstop ──────────────────────────────────────────────
describe("an unchanged cluster cannot post, whatever announce() is handed")
m = start(state_file=os.path.join(WORK, "s-digest.json"))
st = cycles(m, [UP] + [A_DOWN] * 5)
check("the outage posted once", len(m.posted), 1)
check("and the fingerprint was recorded", st["last_posted_digest"],
      "%s=down|%s=up" % (A, B))
# Hand announce() a transition it should refuse: the state it describes is the
# state we already announced. This is the backstop for a bug anywhere upstream.
check("a replayed 'went down' is dropped", m.announce([A], [], [], st, 2000.0), False)
check("nothing was posted", len(m.posted), 1)

describe("the fingerprint tracks real transitions")
m = start(state_file=os.path.join(WORK, "s-digest2.json"))
st = cycles(m, [UP] + [A_DOWN] * 5 + [UP] * 5)
check("down then up posted twice", len(m.posted), 2)
check("fingerprint back to all-up", st["last_posted_digest"],
      "%s=up|%s=up" % (A, B))
st2 = cycles(m, [A_DOWN] * 5, start_ts=5000.0)
check("a second outage still posts", len(m.posted), 3)

describe("the last raw check is recorded alongside the debounced view")
m = start(state_file=os.path.join(WORK, "s-lastcheck.json"))
st = cycles(m, [UP] + [A_DOWN] * 5)
check("last_check holds what the probe saw", st["last_check"], {A: False, B: True})
check("timestamped", st["last_check_at"], 1000.0 + 5 * 15.0)
check("separate from the debounced belief", st["servers"][B]["healthy"], True)

describe("a single flap does not disturb the recorded belief")
m = start(state_file=os.path.join(WORK, "s-oneflap.json"))
st = cycles(m, [UP] * 5 + [A_DOWN] + [UP] * 5)
check("nothing posted", len(m.posted), 0)
check("no fingerprint was ever written", "last_posted_digest" in st, False)
check("but the flap is visible in last_check", st["last_check"], {A: True, B: True})

# ── reminders ─────────────────────────────────────────────────────────────────
describe("repeat_seconds re-reports an ongoing outage")
m = start(env={"MONITOR_REPEAT_SECONDS": "3600"},
          state_file=os.path.join(WORK, "s-repeat.json"))
cycles(m, [UP] + [A_DOWN] * 520)          # ~2h10m at 15s
check("one alert plus two hourly reminders", len(m.posted), 3)
check("worded as a reminder", "Still down" in m.posted[1], True)
check("carrying the elapsed time", "down 60m" in m.posted[1], True)

describe("repeat_seconds=0 reports an outage exactly once")
m = start(state_file=os.path.join(WORK, "s-norepeat.json"))
cycles(m, [UP] + [A_DOWN] * 1000)
check("no reminders over four hours", len(m.posted), 1)

# ── degradation ───────────────────────────────────────────────────────────────
describe("an unwritable state file degrades to memory-only")
m = start(state_file="/proc/definitely/not/writable/state.json")
cycles(m, [UP] + [A_DOWN] * 5)
check("alerting still works", len(m.posted), 1)
check("and it says so once", m._state_writable, False)

describe("a corrupt state file is ignored, not fatal")
sf = os.path.join(WORK, "s-corrupt.json")
open(sf, "w").write("{not json")
m = start(state_file=sf)
check("load_state returns empty", m.load_state(), {})
cycles(m, [UP] + [A_DOWN] * 5)
check("alerting still works", len(m.posted), 1)

describe("a monitor.ini missing sections still imports")
trimmed = os.path.join(WORK, "trimmed.ini")
open(trimmed, "w").write("[polling]\ninterval_seconds = 20\n")
m = start(env={"MONITOR_INI": trimmed}, state_file=os.path.join(WORK, "s-ini.json"))
check("no NoSectionError, polling honoured", m.CHECK_INTERVAL, 20)
check("missing [alerting] falls back", m.ALERT_FAILURES, 3)
check("missing [keep_alive] falls back", m.KEEP_ALIVE_MODE, "auto")

describe("a non-numeric setting falls back instead of crashing")
m = start(env={"MONITOR_FAILURE_THRESHOLD": "banana"},
          state_file=os.path.join(WORK, "s-bad.json"))
check("threshold reverts to the default", m.ALERT_FAILURES, 3)

describe("the shipped monitor.ini parses and matches the documented defaults")
m = start(state_file=os.path.join(WORK, "s-shipped.json"))
check("failure_threshold", m.ALERT_FAILURES, 3)
check("recovery_threshold", m.ALERT_RECOVERIES, 2)
check("repeat_seconds", m.REPEAT_SECONDS, 0)
check("startup_notice", m.STARTUP_NOTICE, "auto")

describe("a removed backend is pruned from the state file")
sf = os.path.join(WORK, "s-prune.json")
m = start(state_file=sf)
cycles(m, [UP])
m2 = start(env={"BACKEND_LARGE": A, "BACKEND_XLARGE": ""}, state_file=sf)
cycles(m2, [{A: True}])
check("only configured hosts survive", sorted(json.load(open(sf))["servers"]), [A])

# ── result ────────────────────────────────────────────────────────────────────
shutil.rmtree(WORK, ignore_errors=True)
print("\n  %d checks, %d failed" % (checks, len(failures)))
if failures:
    for f in failures:
        print("    - %s" % f)
sys.exit(1 if failures else 0)
