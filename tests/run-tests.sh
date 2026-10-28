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
SKIP_PARSER="${HERE}/lib/parse-skips.py"

# suite-name : script-under-test : test-file
SUITES=(
  "installer:${ROOT}/ollama-smart-router-install.sh:${HERE}/test-installer.sh"
  "manage:${ROOT}/install/manage-model-servers.sh:${HERE}/test-manage.sh"
)
# Suites without per-function coverage: repo consistency, the inference-target
# scripts, the services' Python tests and the runner's own tests. Each suite is
# one record, so its name, kind, interpreter and file cannot drift apart:
#
#   add_suite NAME shell  SCRIPT          bash SCRIPT
#   add_suite NAME pytest FILE PYTHON     PYTHON -m pytest -q FILE
#   add_suite NAME python FILE PYTHON     PYTHON FILE (standard-library unittest)
EXTRA_NAMES=(); EXTRA_KINDS=(); EXTRA_PATHS=(); EXTRA_PYTHONS=()
add_suite() {
  local name=$1 kind=$2 path=$3 python=${4:-}
  case "$kind" in
    shell) [[ -z "$python" ]] || { echo "add_suite ${name}: a shell suite takes no interpreter" >&2; exit 2; } ;;
    pytest|python) [[ -n "$python" ]] || { echo "add_suite ${name}: ${kind} needs an interpreter" >&2; exit 2; } ;;
    *) echo "add_suite ${name}: unknown suite kind '${kind}'" >&2; exit 2 ;;
  esac
  [[ -n "$path" ]] || { echo "add_suite ${name}: no test file" >&2; exit 2; }
  EXTRA_NAMES+=("$name"); EXTRA_KINDS+=("$kind"); EXTRA_PATHS+=("$path"); EXTRA_PYTHONS+=("$python")
}
add_suite repo          shell "${HERE}/test-repo.sh"
add_suite nvidia        shell "${HERE}/test-nvidia.sh"
add_suite host-gpu      shell "${HERE}/test-host-gpu.sh"
add_suite gpu-drivers   shell "${HERE}/test-gpu-drivers.sh"
add_suite update        shell "${HERE}/test-update.sh"
add_suite remote-update shell "${HERE}/test-remote-update.sh"
add_suite mattermost    shell "${HERE}/test-mattermost.sh"
add_suite gitea         shell "${HERE}/test-gitea.sh"
add_suite runner-skips  shell "${HERE}/test-runner-skips.sh"
for _t in "${ROOT}"/targets/*/test-*.sh; do
  [[ -f "$_t" ]] || continue
  _target=$(basename "$(dirname "$_t")")
  add_suite "${_target}-$(basename "$_t" .sh | sed 's/^test-//')" shell "$_t"
done
add_suite pve-select shell "${ROOT}/targets/test-pve-select.sh"
add_suite nvidia-lxc shell "${ROOT}/targets/test-nvidia-lxc.sh"
# The router and the llama.cpp bridge pin different fastapi versions, so each
# pytest suite can run under its own interpreter (CI builds one venv per
# service from its requirements.txt). Both default to python3. The AirLLM
# server tests stub airllm/torch and only need the bridge's fastapi stack.
ROUTER_PYTHON="${ROUTER_PYTHON:-python3}"
BRIDGE_PYTHON="${BRIDGE_PYTHON:-python3}"
add_suite bridge  pytest "${ROOT}/targets/llamacpp/test_bridge.py" "$BRIDGE_PYTHON"
add_suite airllm  pytest "${ROOT}/targets/airllm/test_server.py"   "$BRIDGE_PYTHON"
add_suite router  pytest "${HERE}/test_router.py"                  "$ROUTER_PYTHON"
add_suite monitor pytest "${HERE}/test_monitor.py"                 "$ROUTER_PYTHON"
# Standard-library unittest scripts: no venv needed.
add_suite open-terminal-integration python "${ROOT}/targets/open-terminal/test-integration.py" python3
add_suite open-terminal-webui-probe python "${ROOT}/targets/open-terminal/test-webui-probe.py" python3
add_suite hermes-integration        python "${ROOT}/targets/hermes/test-integration.py"        python3
add_suite hermes-direct-dispatch    python "${ROOT}/targets/hermes/test-direct-dispatch.py"    python3
add_suite comfyui-integration       python "${ROOT}/targets/comfyui/test-integration.py"       python3
add_suite skip-report               python "${HERE}/test-skip-report.py"                       python3

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

# run_suite NAME CMD...: show and capture every kind of suite so skip reports
# from shell, pytest and unittest all reach the strict-mode gate.
run_suite() {
  local name=$1 rc line reports
  shift
  "$@" 2>&1 | tee "$suite_out"
  rc=${PIPESTATUS[0]}
  reports="$(python3 "$SKIP_PARSER" "$suite_out")" || return 1
  if [[ -n "$reports" ]]; then
    while IFS= read -r line; do
      skipped+=("${name}: ${line}")
    done <<< "$reports"
  fi
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
      run_suite "$name" "${EXTRA_PYTHONS[$i]}" -m pytest -q "${EXTRA_PATHS[$i]}" || failed_suites+=("$name")
      ;;
    python)
      run_suite "$name" "${EXTRA_PYTHONS[$i]}" "${EXTRA_PATHS[$i]}" || failed_suites+=("$name")
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
    printf '%sSKIPPED cases (not allowed with --strict or CI=true):%s\n' "$c_red" "$c_off"
    rc=1
  else
    printf '%sskipped cases (--strict fails on this):%s\n' "$c_yel" "$c_off"
  fi
  printf '  %s\n' "${skipped[@]}"
fi
exit $rc
