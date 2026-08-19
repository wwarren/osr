#!/usr/bin/env bash
# Run every shell unit-test suite and report per-function coverage.
#
#   ./run-tests.sh                 # run everything
#   ./run-tests.sh installer       # run one suite
#   ./run-tests.sh --coverage      # coverage report only, no tests
#   ./run-tests.sh --list          # list suites
#
# Exit status is non-zero if any suite fails OR any function is untested, so
# this can be wired straight into CI.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
EXTRACT="${HERE}/lib/extract-functions.py"

# suite-name : script-under-test : test-file
SUITES=(
  "installer:${ROOT}/ollama-smart-router-install.sh:${HERE}/test-installer.sh"
  "manage:${ROOT}/manage-model-servers.sh:${HERE}/test-manage.sh"
)

# Python suites. These test code the installer GENERATES rather than the
# installer itself, so the shell coverage gate does not apply to them — there
# are no bash functions to enumerate. Same argument convention: the suite is
# handed the script it should extract from.
PY_SUITES=(
  "monitor:${ROOT}/ollama-smart-router-install.sh:${HERE}/test-monitor.py"
  "router:${ROOT}/ollama-smart-router-install.sh:${HERE}/test-router.py"
)

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_yel=""; c_bld=""; c_off=""; }

want=""; coverage_only=false; list_only=false
for arg in "$@"; do
  case "$arg" in
    --coverage) coverage_only=true ;;
    --list)     list_only=true ;;
    -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $arg" >&2; exit 2 ;;
    *)          want="$arg" ;;
  esac
done

if $list_only; then
  for entry in "${SUITES[@]}" "${PY_SUITES[@]}"; do echo "${entry%%:*}"; done
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# ── coverage: which extracted functions have a `describe` block ───────────────
uncovered_total=0
coverage_report() {
  local name script test all cov missing count described
  printf '\n%s── coverage ──────────────────────────────────────%s\n' "$c_bld" "$c_off"
  for entry in "${SUITES[@]}"; do
    IFS=: read -r name script test <<< "$entry"
    [[ -n "$want" && "$want" != "$name" ]] && continue
    [[ -f "$script" && -f "$test" ]] || { printf '  %sskip%s %s (missing file)\n' "$c_yel" "$c_off" "$name"; continue; }

    all="$(python3 "$EXTRACT" "$script" --list | sort -u)"
    # `describe <name>` lines name the function under test.
    cov="$(grep -oE '^describe [a-z_][a-z0-9_]*' "$test" | awk '{print $2}' | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$cov"))"
    count="$(printf '%s\n' "$all" | grep -c . || true)"
    described="$(comm -12 <(printf '%s\n' "$all") <(printf '%s\n' "$cov") | grep -c . || true)"

    if [[ -z "$missing" ]]; then
      printf '  %s%3d/%-3d%s %s — every function has a test\n' \
        "$c_grn" "$described" "$count" "$c_off" "$name"
    else
      printf '  %s%3d/%-3d%s %s — untested:\n' "$c_red" "$described" "$count" "$c_off" "$name"
      printf '           %s\n' $missing
      uncovered_total=$(( uncovered_total + $(printf '%s\n' "$missing" | grep -c .) ))
    fi
  done
}

if $coverage_only; then
  coverage_report
  (( uncovered_total == 0 )) || exit 1
  exit 0
fi

# ── run the suites ────────────────────────────────────────────────────────────
failed_suites=()
ran_any=false
for entry in "${SUITES[@]}"; do
  IFS=: read -r name script test <<< "$entry"
  [[ -n "$want" && "$want" != "$name" ]] && continue
  ran_any=true
  if [[ ! -f "$test" ]]; then
    printf '%sMISSING%s suite file: %s\n' "$c_red" "$c_off" "$test"; failed_suites+=("$name"); continue
  fi
  if [[ ! -f "$script" ]]; then
    printf '%sMISSING%s script under test: %s\n' "$c_red" "$c_off" "$script"; failed_suites+=("$name"); continue
  fi
  printf '\n%s══ %s ══════════════════════════════════════════%s\n' "$c_bld" "$name" "$c_off"
  bash "$test" "$script" || failed_suites+=("$name")
done

for entry in "${PY_SUITES[@]}"; do
  IFS=: read -r name script test <<< "$entry"
  [[ -n "$want" && "$want" != "$name" ]] && continue
  ran_any=true
  if [[ ! -f "$test" || ! -f "$script" ]]; then
    printf '%sMISSING%s python suite: %s\n' "$c_red" "$c_off" "$test"
    failed_suites+=("$name"); continue
  fi
  printf '\n%s══ %s ══════════════════════════════════════════%s\n' "$c_bld" "$name" "$c_off"
  python3 "$test" "$script" || failed_suites+=("$name")
done

if ! $ran_any; then
  echo "no such suite: ${want}" >&2
  exit 2
fi

coverage_report

printf '\n%s══ result ═══════════════════════════════════════%s\n' "$c_bld" "$c_off"
rc=0
if (( ${#failed_suites[@]} > 0 )); then
  printf '%sFAILED suites:%s %s\n' "$c_red" "$c_off" "${failed_suites[*]}"
  rc=1
else
  printf '%sall suites passed%s\n' "$c_grn" "$c_off"
fi
if (( uncovered_total > 0 )); then
  printf '%s%d function(s) have no test%s\n' "$c_red" "$uncovered_total" "$c_off"
  rc=1
fi
exit $rc
