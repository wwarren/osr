#!/usr/bin/env bash
# Run every test suite (shell, repo consistency, llama.cpp target, bridge
# pytest) and report per-function coverage for the two main scripts.
#
#   ./run-tests.sh                 # run everything
#   ./run-tests.sh installer       # run one suite
#   ./run-tests.sh --coverage      # coverage report only, no tests
#   ./run-tests.sh --list          # list suites
#   ./run-tests.sh --strict        # also fail if any cases were skipped
#
# Exit status is non-zero if any suite fails OR any function is untested, so
# this can be wired straight into CI. Suites skip cases they cannot run here
# (most end-to-end cases need root); the result lists them. With --strict, or
# when CI=true, a skip fails the run, so CI cannot pass without running them.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
EXTRACT="${HERE}/lib/extract-functions.py"

# suite-name : script-under-test : test-file
SUITES=(
  "installer:${ROOT}/ollama-smart-router-install.sh:${HERE}/test-installer.sh"
  "manage:${ROOT}/install/manage-model-servers.sh:${HERE}/test-manage.sh"
)
# Suites without per-function coverage: repo consistency, the inference-target
# scripts (llama.cpp, AirLLM), and their Python tests.
EXTRA_NAMES=(repo nvidia update remote-update mattermost gitea)
EXTRA_KINDS=(shell shell shell shell shell shell)
EXTRA_PATHS=("${HERE}/test-repo.sh" "${HERE}/test-nvidia.sh" "${HERE}/test-update.sh" "${HERE}/test-remote-update.sh" "${HERE}/test-mattermost.sh" "${HERE}/test-gitea.sh")
EXTRA_PYTHONS=("" "" "" "" "" "")
EXTRA_TESTS=("" "" "" "" "" "")
for _t in "${ROOT}"/targets/*/test-*.sh; do
  [[ -f "$_t" ]] || continue
  _target=$(basename "$(dirname "$_t")")
  EXTRA_NAMES+=("${_target}-$(basename "$_t" .sh | sed 's/^test-//')")
  EXTRA_KINDS+=(shell)
  EXTRA_PATHS+=("$_t")
  EXTRA_PYTHONS+=("")
  EXTRA_TESTS+=("")
done
# The router and the llama.cpp bridge pin different fastapi versions, so each
# pytest suite can run under its own interpreter (CI builds one venv per
# service from its requirements.txt). Both default to python3. The AirLLM
# server tests stub airllm/torch and only need the bridge's fastapi stack.
ROUTER_PYTHON="${ROUTER_PYTHON:-python3}"
BRIDGE_PYTHON="${BRIDGE_PYTHON:-python3}"
EXTRA_NAMES+=(bridge airllm router monitor)
EXTRA_KINDS+=(pytest pytest pytest pytest)
EXTRA_PATHS+=("" "" "" "")
EXTRA_PYTHONS+=("${BRIDGE_PYTHON}" "${BRIDGE_PYTHON}" "${ROUTER_PYTHON}" "${ROUTER_PYTHON}")
EXTRA_TESTS+=(
  "${ROOT}/targets/llamacpp/test_bridge.py"
  "${ROOT}/targets/airllm/test_server.py"
  "${HERE}/test_router.py"
  "${HERE}/test_monitor.py"
)
# Standard-library unittest scripts: no venv needed.
EXTRA_NAMES+=(open-terminal-integration open-terminal-webui-probe hermes-integration)
EXTRA_KINDS+=(python python python)
EXTRA_PATHS+=("${ROOT}/targets/open-terminal/test-integration.py" "${ROOT}/targets/open-terminal/test-webui-probe.py"
              "${ROOT}/targets/hermes/test-integration.py")
EXTRA_PYTHONS+=(python3 python3 python3)
EXTRA_TESTS+=("" "" "")

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_bld=$'\033[1m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_red=""; c_grn=""; c_yel=""; c_bld=""; c_off=""; }

want=""; coverage_only=false; list_only=false; strict=false
case "${CI:-}" in true|1) strict=true ;; esac
for arg in "$@"; do
  case "$arg" in
    --coverage) coverage_only=true ;;
    --list)     list_only=true ;;
    --strict)   strict=true ;;
    -h|--help)  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)         echo "unknown option: $arg" >&2; exit 2 ;;
    *)          want="$arg" ;;
  esac
done

if $list_only; then
  for entry in "${SUITES[@]}"; do echo "${entry%%:*}"; done
  printf '%s\n' "${EXTRA_NAMES[@]}"
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
skipped=()
ran_any=false
suite_out="$(mktemp "${TMPDIR:-/tmp}/run-tests.XXXXXX")"
trap 'rm -f -- "$suite_out"' EXIT

# run_suite NAME CMD...: run one suite, showing its output, and note any cases
# it skipped: "SKIP ..." lines, or assert.sh skips for want of root.
run_suite() {
  local name=$1 rc line
  shift
  "$@" 2>&1 | tee "$suite_out"
  rc=${PIPESTATUS[0]}
  while IFS= read -r line; do
    skipped+=("${name}: ${line#SKIP }")
  done < <(sed 's/\x1b\[[0-9;]*m//g' "$suite_out" | grep -E '^SKIP |^ *skip .*needs? root' | sed 's/^ *skip *//')
  return "$rc"
}
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
  run_suite "$name" bash "$test" "$script" || failed_suites+=("$name")
done

for i in "${!EXTRA_NAMES[@]}"; do
  name="${EXTRA_NAMES[$i]}"
  [[ -n "$want" && "$want" != "$name" ]] && continue
  ran_any=true
  printf '\n%s══ %s ══════════════════════════════════════════%s\n' "$c_bld" "$name" "$c_off"
  case "${EXTRA_KINDS[$i]}" in
    shell)
      run_suite "$name" bash "${EXTRA_PATHS[$i]}" || failed_suites+=("$name")
      ;;
    pytest)
      if ! "${EXTRA_PYTHONS[$i]}" -c 'import pytest, fastapi, httpx' 2>/dev/null; then
        printf '  %sskip%s %s (needs: pip install pytest fastapi httpx)\n' "$c_yel" "$c_off" "$name"
        skipped+=("${name}: the whole suite (needs: pip install pytest fastapi httpx)")
        continue
      fi
      "${EXTRA_PYTHONS[$i]}" -m pytest -q "${EXTRA_TESTS[$i]}" || failed_suites+=("$name")
      ;;
    python)
      "${EXTRA_PYTHONS[$i]}" "${EXTRA_PATHS[$i]}" || failed_suites+=("$name")
      ;;
    *)
      printf 'ERROR: unknown suite type for %s\n' "$name" >&2
      failed_suites+=("$name")
      ;;
  esac
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
if (( ${#skipped[@]} > 0 )); then
  if $strict; then
    printf '%sSKIPPED cases (not allowed with --strict or CI=true; run as root):%s\n' "$c_red" "$c_off"
    rc=1
  else
    printf '%sskipped cases (run as root to include them; --strict fails on this):%s\n' "$c_yel" "$c_off"
  fi
  printf '  %s\n' "${skipped[@]}"
fi
exit $rc
