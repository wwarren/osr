#!/usr/bin/env bash
# Exercise run-tests.sh itself: every suite runs its own file under its own
# interpreter, and the strict gate fails on each skip format the runner knows
# (shell skip/SKIP/skipped: lines, pytest summaries, unittest summaries) while
# an ordinary run passes and lists the skip. No pytest installation is needed.
#
# Messages printed here must not look like skip reports themselves, because
# the outer run-tests.sh parses this suite's output too.
set -euo pipefail
exec </dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/runner-skips.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/    | /'; failures=$((failures + 1)); }

# The inner runs decide strictness from their flags alone: CI=true (set by the
# CI runner) would otherwise make every inner run strict.
runner() { env -u CI bash "$@" 2>&1; }

# ── 1. each pytest suite gets its own file and interpreter ────────────────────
# A fake interpreter that passes the import probe and logs what it was asked
# to run, tagged with which variable selected it.
make_logging_python() {
  local path=$1 tag=$2
  cat > "$path" <<FAKE
#!/usr/bin/env bash
[[ \${1:-} == -c ]] && exit 0
printf '%s %s\n' '$tag' "\$*" >> '$tmp/argv.log'
printf 'pretend suite ran\n'
FAKE
  chmod +x "$path"
}
make_logging_python "$tmp/router-python" ROUTER
make_logging_python "$tmp/bridge-python" BRIDGE
expect_suite() {
  local suite=$1 tag=$2 file=$3 out logged
  : > "$tmp/argv.log"
  if ! out="$(ROUTER_PYTHON="$tmp/router-python" BRIDGE_PYTHON="$tmp/bridge-python" \
              runner "$here/run-tests.sh" "$suite")"; then
    fail "$suite suite did not complete" "$out"; return
  fi
  logged="$(cat "$tmp/argv.log")"
  if [[ $logged == "$tag -m pytest -q $file" ]]; then
    pass "$suite runs ${file#"$root"/} under ${tag}_PYTHON"
  else
    fail "$suite ran the wrong file or interpreter" "expected: $tag -m pytest -q $file
got:      $logged"
  fi
}
expect_suite bridge  BRIDGE "$root/targets/llamacpp/test_bridge.py"
expect_suite airllm  BRIDGE "$root/targets/airllm/test_server.py"
expect_suite router  ROUTER "$here/test_router.py"
expect_suite monitor ROUTER "$here/test_monitor.py"

# The last suite in the table must still reach the result line.
if out="$(runner "$here/run-tests.sh" skip-report)" && [[ $out == *'all suites passed'* ]]; then
  pass 'the last suite in the table runs to the result line'
else
  fail 'the last suite in the table did not reach the result line' "$out"
fi

# ── 2. every skip format makes --strict fail ──────────────────────────────────
# A copy of the runner in a scratch tree: run-tests.sh finds its suites next to
# itself, so fake suite files there stand in for the real ones.
sandbox="$tmp/sandbox"
mkdir -p "$sandbox/tests/lib"
cp "$here/run-tests.sh" "$sandbox/tests/"
cp "$here/lib/parse-skips.py" "$here/lib/extract-functions.py" "$sandbox/tests/lib/"
fake_shell() {  # fake_shell FILE OUTPUT: a passing shell suite printing OUTPUT
  printf '#!/usr/bin/env bash\nprintf %%b %q\n' "$2" > "$sandbox/tests/$1"
}
# assert.sh's coloured skip line, an upper-case SKIP banner, a skipped: line.
fake_shell test-repo.sh     '  \033[33mskip\033[0m GPU path \xe2\x80\x94 no GPU\n'
fake_shell test-nvidia.sh   'SKIP end-to-end cases (needs root)\n'
fake_shell test-update.sh   'skipped: no device\n'
fake_shell test-gitea.sh    'PASS everything ran\n'
# A real unittest run with one skipped case: "OK (skipped=1)" on stderr.
cat > "$sandbox/tests/test-skip-report.py" <<'PY'
import unittest


class Case(unittest.TestCase):
    def test_runs(self):
        pass

    @unittest.skip("needs a device")
    def test_skipped(self):
        pass


unittest.main()
PY
# A pytest-shaped summary from a fake interpreter.
cat > "$tmp/pytest-python" <<'FAKE'
#!/usr/bin/env bash
[[ ${1:-} == -c ]] && exit 0
printf '===== 3 passed, 1 skipped in 0.01s =====\n'
FAKE
chmod +x "$tmp/pytest-python"

expect_strict_failure() {  # expect_strict_failure LABEL SUITE REPORT [ENV...]
  local label=$1 suite=$2 report=$3 out
  shift 3
  if out="$(env "$@" bash -c 'env -u CI bash "$0" "$1" --strict 2>&1' \
              "$sandbox/tests/run-tests.sh" "$suite")"; then
    fail "--strict accepted a $label" "$out"
  elif [[ $out != *"$suite: $report"* ]]; then
    fail "--strict did not name the $label" "$out"
  else
    pass "--strict fails on a $label"
  fi
  if ! out="$(env "$@" bash -c 'env -u CI bash "$0" "$1" 2>&1' \
                "$sandbox/tests/run-tests.sh" "$suite")"; then
    fail "an ordinary run rejected a passing suite with a $label" "$out"
  elif [[ $out != *"$suite: $report"* ]]; then
    fail "an ordinary run did not list the $label" "$out"
  else
    pass "an ordinary run passes and lists the $label"
  fi
}
expect_strict_failure 'shell skip line'      repo        'skip GPU path — no GPU'
expect_strict_failure 'shell SKIP banner'    nvidia      'SKIP end-to-end cases (needs root)'
expect_strict_failure 'shell skipped: line'  update      'skipped: no device'
expect_strict_failure 'unittest summary'     skip-report 'OK (skipped=1)'
expect_strict_failure 'pytest summary'       router      '===== 3 passed, 1 skipped in 0.01s =====' \
  ROUTER_PYTHON="$tmp/pytest-python"

# CI=true alone turns strict mode on.
if out="$(CI=true bash "$sandbox/tests/run-tests.sh" repo 2>&1)"; then
  fail 'CI=true did not make the run strict' "$out"
else
  pass 'CI=true makes the run strict'
fi
# Control: a suite without skips passes strict mode.
if out="$(runner "$sandbox/tests/run-tests.sh" gitea --strict)"; then
  pass '--strict passes a suite that ran every case'
else
  fail '--strict rejected a suite without skips' "$out"
fi

(( failures == 0 )) || { printf '%d runner check(s) failed\n' "$failures"; exit 1; }
printf 'all runner checks passed\n'
