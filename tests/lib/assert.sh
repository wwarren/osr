#!/usr/bin/env bash
# Minimal assertion library for the shell unit tests.
#
# Deliberately does NOT set -e: a failing assertion must record the failure and
# let the suite continue, so one bad function does not hide the rest.

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_FUNC="(none)"
FAILED_NAMES=()

_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
[[ -t 1 ]] || { _c_red=""; _c_grn=""; _c_yel=""; _c_dim=""; _c_off=""; }

# describe <function-name> — groups the assertions that follow.
describe() {
  CURRENT_FUNC="$1"
  printf '\n%s── %s%s\n' "$_c_dim" "$1" "$_c_off"
}

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '  %sok%s   %s\n' "$_c_grn" "$_c_off" "$1"
}
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_NAMES+=("${CURRENT_FUNC}: $1")
  printf '  %sFAIL%s %s\n' "$_c_red" "$_c_off" "$1"
  [[ -n "${2:-}" ]] && printf '       expected: %s\n' "$2"
  [[ -n "${3:-}" ]] && printf '       actual:   %s\n' "$3"
  return 0
}
skip() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf '  %sskip%s %s%s\n' "$_c_yel" "$_c_off" "$1" "${2:+ — $2}"
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "'$2'" "'$3'"; fi
}

# assert_ne <label> <not-expected> <actual>
assert_ne() {
  if [[ "$2" != "$3" ]]; then _pass "$1"; else _fail "$1" "anything but '$2'" "'$3'"; fi
}

# assert_contains <label> <needle> <haystack>
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then _pass "$1"; else _fail "$1" "to contain '$2'" "'$3'"; fi
}

# assert_not_contains <label> <needle> <haystack>
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then _pass "$1"; else _fail "$1" "not to contain '$2'" "'$3'"; fi
}

# assert_ok <label> <command...> — command must exit 0
assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then _pass "$label"; else _fail "$label" "exit 0" "exit $?"; fi
}

# assert_fail <label> <command...> — command must exit non-zero
#
# Runs in a subshell. Many functions under test end in `die`, which calls
# `exit`; called in-process that would terminate the whole suite at the first
# expected-failure assertion. The subshell absorbs it. Side effects of a
# failing call are discarded, which is what we want anyway.
assert_fail() {
  local label="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then _fail "$label" "non-zero exit" "exit 0"; else _pass "$label"; fi
}

# assert_status <label> <expected-code> <command...> — subshelled, same reason.
assert_status() {
  local label="$1" want="$2"; shift 2
  local got=0
  ( "$@" ) >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then _pass "$label"; else _fail "$label" "exit ${want}" "exit ${got}"; fi
}

# assert_file_contains <label> <needle> <path>
assert_file_contains() {
  if [[ -f "$3" ]] && grep -qF -- "$2" "$3"; then
    _pass "$1"
  else
    _fail "$1" "file '$3' to contain '$2'" "$( [[ -f "$3" ]] && echo 'not found in file' || echo 'file missing')"
  fi
}

# assert_file_mode <label> <expected-mode> <path>
assert_file_mode() {
  local got; got="$(stat -c '%a' "$3" 2>/dev/null || echo missing)"
  if [[ "$got" == "$2" ]]; then _pass "$1"; else _fail "$1" "mode $2" "mode $got"; fi
}

summary() {
  printf '\n%s\n' "────────────────────────────────────────────────"
  printf 'ran %d   %spassed %d%s   %sfailed %d%s   %sskipped %d%s\n' \
    "$TESTS_RUN" "$_c_grn" "$TESTS_PASSED" "$_c_off" \
    "$_c_red" "$TESTS_FAILED" "$_c_off" "$_c_yel" "$TESTS_SKIPPED" "$_c_off"
  if (( TESTS_FAILED > 0 )); then
    printf '\nfailures:\n'
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    return 1
  fi
  return 0
}
