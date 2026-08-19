#!/usr/bin/env python3
"""Unit tests for the generated router.py — scoring, classification, logging.

Extracts router.py and router.ini from the installer's heredocs, imports the
module with a throwaway decision log, and calls the pure functions directly.
No network, no uvicorn, no Ollama.

    python3 test-router.py [path/to/ollama-smart-router-install.sh]

The point of most of these is the decision log. Scoring can only be judged
against what it *rejected*, so the assertions below care as much about the
per-candidate breakdown being complete and arithmetically honest as they do
about the winner being right.
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


def extract(repo_path, dest):
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
    raise SystemExit("no heredoc for %s" % repo_path)


WORK = tempfile.mkdtemp(prefix="router-tests-")
ROUTER_PY = extract("services/ollama-router/router.py",
                    os.path.join(WORK, "router.py"))
ROUTER_INI = extract("services/ollama-router/router.ini",
                     os.path.join(WORK, "router.ini"))

OVERRIDES = ("ROUTER_INI", "ROUTER_DECISION_FILE", "LOGS_DIRECTORY",
             "BACKEND_FAST", "BACKEND_MEDIUM", "BACKEND_LARGE", "BACKEND_XLARGE")


def start(ini=None, decision_file=None, env=None):
    """Import router.py fresh, as if the service had just started."""
    for key in OVERRIDES:
        os.environ.pop(key, None)
    os.environ.update({
        "ROUTER_INI": ini or ROUTER_INI,
        "ROUTER_DECISION_FILE": decision_file or os.path.join(WORK, "d.jsonl"),
        "BACKEND_FAST": "http://a.example:11434",
        "BACKEND_LARGE": "http://b.example:11434",
    })
    os.environ.update(env or {})
    sys.modules.pop("router", None)
    spec = importlib.util.spec_from_file_location("router", ROUTER_PY)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["router"] = mod
    spec.loader.exec_module(mod)
    return mod


_ini_seq = [0]


def ini_with(**sections):
    """A router.ini containing ONLY the given options.

    Deliberately not "the shipped ini plus overrides": appending a second
    [logging] block makes configparser raise DuplicateSectionError. Everything
    omitted here falls back to router.py's built-in _DEFAULTS, which is the
    behaviour being relied on anyway.
    """
    _ini_seq[0] += 1
    path = os.path.join(WORK, "ini-%d.ini" % _ini_seq[0])
    with open(path, "w", encoding="utf-8") as fh:
        for section, opts in sections.items():
            fh.write("[%s]\n" % section)
            for key, value in opts.items():
                fh.write("%s = %s\n" % (key, value))
            fh.write("\n")
    return path


def entry(mod, name, params, server="http://a.example:11434",
          code=False, vision=False, embed=False):
    return {"server": server, "name": name, "params_b": params,
            "is_code": code, "is_vision": vision, "is_embedding": embed,
            "family": "", "quant": ""}


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


m = start()

# ── the score breakdown must be the score ────────────────────────────────────
describe("score_breakdown is exactly score_entry, itemised")
need_code = m.classify_request([{"role": "user", "content": "fix this function please"}])
need_plain = m.classify_request([{"role": "user", "content": "hello there"}])
cases = [
    (entry(m, "qwen3:8b", 8.0), need_plain),
    (entry(m, "qwen2.5-coder:14b", 14.0, code=True), need_code),
    (entry(m, "qwen2.5-coder:14b", 14.0, code=True), need_plain),
    (entry(m, "llava:13b", 13.0, vision=True), need_plain),
    (entry(m, "mystery", 0.0), need_plain),
    (entry(m, "llama3.3:70b", 70.0), need_plain),
]
agree = all(
    abs(m.score_entry(e, n) - m.score_breakdown(e, n)["score"]) < 1e-12
    for e, n in cases)
check("the two never disagree", agree, True)
sums = all(
    abs(sum(m.score_breakdown(e, n)["terms"].values())
        - m.score_breakdown(e, n)["score"]) < 1e-9
    for e, n in cases)
check("the terms sum to the total", sums, True)

describe("the terms attribute the score to the right cause")
d = m.score_breakdown(entry(m, "qwen2.5-coder:14b", 14.0, code=True), need_code)
check("a code model on a code request earns the code term", d["terms"]["code"] > 0, True)
d = m.score_breakdown(entry(m, "qwen2.5-coder:14b", 14.0, code=True), need_plain)
check("and is penalised on a plain request", d["terms"]["code"] < 0, True)
d = m.score_breakdown(entry(m, "llava:13b", 13.0, vision=True), need_plain)
check("an off-task vision model is penalised", d["terms"]["vision"] < 0, True)
d = m.score_breakdown(entry(m, "qwen3:8b", 8.0), need_plain)
check("an in-band model is flagged in band", d["in_band"], True)
check("with zero distance", d["band_distance"], 0.0)
check("terms are unrounded so the sum is exact",
      sum(d["terms"].values()), d["score"])
check("and a band position", 0.0 <= d["band_position"] <= 1.0, True)
d = m.score_breakdown(entry(m, "llama3.3:70b", 70.0), need_plain)
check("an out-of-band model is not", d["in_band"], False)
check("and reports how far out it is", d["band_distance"] > 0, True)
check("with no band position", d["band_position"], None)
d = m.score_breakdown(entry(m, "mystery", 0.0), need_plain)
check("an unknown size gets the benefit of the doubt", d["band_fit"], m.W_UNKNOWN)
check("but is not claimed to be in band", d["in_band"], False)

# ── classification now explains itself ───────────────────────────────────────
describe("classify_request reports why, not just what")
n = m.classify_request([{"role": "user", "content": "please derive the closed form"}])
check("keyword class", n["class"], "xlarge")
check("names the rule", n["reason"], "xlarge keyword")
check("and the keyword that fired", "derive" in n["matched"]["xlarge"], True)
n = m.classify_request([{"role": "user", "content": "def foo(): pass"}])
check("code wins under code_first", n["class"], "fast")
check("and says so", n["reason"], "code keyword (code_first)")
n = m.classify_request([{"role": "user", "content": "word " * 400}])
check("length class", n["class"], "medium")
check("reason names the threshold", n["reason"].startswith("length >"), True)
n = m.classify_request([{"role": "user", "content": "hi"}])
check("the default is fast", (n["class"], n["reason"]), ("fast", "default"))
check("character count recorded", n["chars"], 2)
check("message count recorded", n["messages"], 1)

describe("classification is unchanged by the added fields")
# The routing-relevant keys must be exactly what they were before logging.
for text, want in (("hi", "fast"), ("word " * 400, "medium"),
                   ("word " * 700, "large"), ("word " * 1700, "xlarge"),
                   ("analyze this", "large"), ("prove it", "xlarge")):
    got = m.classify_request([{"role": "user", "content": text}])["class"]
    check("%r -> %s" % (text[:18], want), got, want)

# ── prompt capture ───────────────────────────────────────────────────────────
describe("prompt capture honours prompt_chars")
check("default keeps 200 characters", m.PROMPT_CHARS, 200)
long_text = "x" * 500
n = m.classify_request([{"role": "user", "content": long_text}])
check("truncated to the limit plus an ellipsis", len(n["prompt"]), 203)
check("marked as truncated", n["prompt"].endswith("..."), True)
n = m.classify_request([{"role": "user", "content": "line one\nline two"}])
check("newlines collapsed so a record stays one line",
      "\n" in n["prompt"], False)

m0 = start(ini=ini_with(logging={"prompt_chars": "0"}),
           decision_file=os.path.join(WORK, "d0.jsonl"))
n = m0.classify_request([{"role": "user", "content": "something private"}])
check("prompt_chars=0 stores no text at all", n["prompt"], "")
check("but still stores the features", n["chars"] > 0, True)

# ── the decision log ─────────────────────────────────────────────────────────
describe("record_decision writes one JSON object per line")
df = os.path.join(WORK, "rec.jsonl")
mr = start(decision_file=df)
mr._init_decision_log()
mr.record_decision({"id": "abc", "n": 1})
mr.record_decision({"id": "def", "n": 2, "nested": {"a": [1, 2]}})
for h in mr._decision_log.handlers:
    h.flush()
with open(df, encoding="utf-8") as fh:
    lines = [json.loads(x) for x in fh if x.strip()]
check("two records", len(lines), 2)
check("round-trips nested structure", lines[1]["nested"], {"a": [1, 2]})
check("one line each", open(df, encoding="utf-8").read().count("\n"), 2)

describe("the decision log is not world-readable")
# It holds prompt text. systemd's LogsDirectoryMode protects the directory, but
# the file's own mode is inherited from the process umask (0644) unless it is
# set explicitly — and 0644 is what the logrotate policy claims is 0640.
mode = oct(os.stat(df).st_mode & 0o777)
check("mode is 0640", mode, "0o640")

describe("an unwritable decision log is not fatal")
mbad = start(decision_file="/proc/definitely/not/writable/d.jsonl")
mbad._init_decision_log()
check("logging turns itself off", mbad.LOG_DECISIONS, False)
mbad.record_decision({"id": "x"})          # must not raise
check("and recording becomes a no-op", True, True)

describe("decisions = false writes nothing")
df2 = os.path.join(WORK, "off.jsonl")
moff = start(ini=ini_with(logging={"decisions": "false"}), decision_file=df2)
moff._init_decision_log()
moff.record_decision({"id": "x"})
check("no file created", os.path.exists(df2), False)

describe("the log rotates instead of growing without bound")
df3 = os.path.join(WORK, "rot.jsonl")
mrot = start(ini=ini_with(logging={"max_bytes": "2000", "backup_count": "2"}),
             decision_file=df3)
mrot._init_decision_log()
for i in range(400):
    mrot.record_decision({"id": i, "padding": "y" * 100})
for h in mrot._decision_log.handlers:
    h.flush()
check("a backup exists", os.path.exists(df3 + ".1"), True)
check("bounded to backup_count files",
      sorted(os.path.basename(f) for f in os.listdir(WORK)
             if f.startswith("rot.jsonl")),
      ["rot.jsonl", "rot.jsonl.1", "rot.jsonl.2"])
check("the live file stayed small", os.path.getsize(df3) < 5000, True)

# ── candidate explanation ────────────────────────────────────────────────────
describe("explain_candidates mirrors the ranking")
inv = {"models": [entry(m, "qwen3:8b", 8.0),
                  entry(m, "qwen3:14b", 14.0),
                  entry(m, "llama3.3:70b", 70.0)],
       "servers": {"http://a.example:11434": {"up": True}}}
need = {"class": "medium", "code": False, "vision": False}
ranked = m.rank_candidates(need, inv)
detail = m.explain_candidates(need, ranked)
check("one entry per candidate", len(detail), len(ranked))
check("ranks are 0..n", [d["rank"] for d in detail], list(range(len(ranked))))
check("order matches the ranking",
      [d["model"] for d in detail], [e["name"] for e in ranked])
check("scores are non-increasing",
      all(detail[i]["score"] >= detail[i + 1]["score"] for i in range(len(detail) - 1)),
      True)
check("the 14b wins the medium band", detail[0]["model"], "qwen3:14b")
check("and is marked in band", detail[0]["in_band"], True)
# The logged terms are rounded for readability, so they reconcile to within
# the rounding, not exactly. The exact invariant is asserted on score_breakdown.
check("logged terms still reconcile with the logged score",
      all(abs(sum(c["terms"].values()) - c["score"]) < 1e-3 for c in detail), True)

describe("log_candidates caps how many are stored")
mcap = start(ini=ini_with(logging={"log_candidates": "2"}),
             decision_file=os.path.join(WORK, "cap.jsonl"))
check("capped", len(mcap.explain_candidates(need, ranked)), 2)
check("0 means all", len(mcap.explain_candidates(need, ranked, 0)), 3)

describe("rank_meta describes the ranking itself")
meta = m.rank_meta(need, ranked)
check("counts candidates", meta["candidates"], 3)
check("nothing was distance-ranked", meta["distance_ranked"], False)
check("no tie among different sizes", meta["tied"], 1)

# Two identical models on two hosts: a genuine tie, which is what the rotation
# is for — and a tie group that never shrinks is the signal tie_epsilon is wrong.
inv2 = {"models": [entry(m, "qwen3:14b", 14.0, server="http://a.example:11434"),
                   entry(m, "qwen3:14b", 14.0, server="http://b.example:11434")],
        "servers": {"http://a.example:11434": {"up": True},
                    "http://b.example:11434": {"up": True}}}
meta = m.rank_meta(need, m.rank_candidates(need, inv2))
check("identical models tie", meta["tied"], 2)

# Nothing in band: the case the distance ranking exists for.
need_x = {"class": "xlarge", "code": False, "vision": False}
meta = m.rank_meta(need_x, m.rank_candidates(need_x, inv2))
check("flagged when nothing is in band", meta["distance_ranked"], True)
check("empty candidate list is handled",
      m.rank_meta(need, []), {"candidates": 0, "tied": 0, "distance_ranked": False})

# ── the ini itself ───────────────────────────────────────────────────────────
describe("the shipped router.ini carries the documented defaults")
check("decisions on", m.LOG_DECISIONS, True)
check("prompt_chars", m.PROMPT_CHARS, 200)
check("log_candidates", m.LOG_CANDIDATES, 10)
check("level", m.LOG_LEVEL, "INFO")

describe("a router.ini with no [logging] section still starts")
trimmed = os.path.join(WORK, "trimmed.ini")
with open(trimmed, "w", encoding="utf-8") as fh:
    fh.write("[discovery]\nrefresh_seconds = 30\n")
mt = start(ini=trimmed, decision_file=os.path.join(WORK, "t.jsonl"))
check("built-in defaults fill the gap", mt.PROMPT_CHARS, 200)
check("and the rest of the ini still applies", mt.DISCOVERY_REFRESH, 30)

shutil.rmtree(WORK, ignore_errors=True)
print("\n  %d checks, %d failed" % (checks, len(failures)))
if failures:
    for f in failures:
        print("    - %s" % f)
sys.exit(1 if failures else 0)
