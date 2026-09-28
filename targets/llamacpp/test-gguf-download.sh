#!/usr/bin/env bash
# Exercise only install-target.sh's requested GGUF downloader.  All external
# commands that could download or change ownership are mocked; no network or
# system files are touched.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

source <(awk '
    /^download_requested_gguf\(\)/ { capture=1 }
    /^MODE=install$/ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
declare -F download_requested_gguf >/dev/null || die 'Installer downloader extraction failed.'

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/llama-target-download-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/llama-target-download-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT

passed=0
CALL_LOG=''
CURL_MODE='success'

record_call() {
    local command=$1 argument
    shift
    printf '%s' "$command" >> "$CALL_LOG"
    for argument in "$@"; do
        printf '|%s' "$argument" >> "$CALL_LOG"
    done
    printf '\n' >> "$CALL_LOG"
}

# The downloader calls runuser solely to run test and curl as its service
# account.  Executing those mocked/built-in commands directly is enough to
# exercise its control flow without switching users.
runuser() {
    [[ $1 == -u && $2 == llama-target && $3 == -- ]] || die "Unexpected runuser call: $*"
    record_call runuser "$@"
    shift 3
    "$@"
}

curl() {
    local output='' argument url=''
    record_call curl "$@"
    while (( $# )); do
        argument=$1
        shift
        case "$argument" in
            --output)
                (( $# )) || die 'Mock curl was called without an output filename.'
                output=$1
                shift
                ;;
            --*)
                # These options are all flags; their values, when present,
                # follow separately and do not matter to the mock.
                case "$argument" in
                    --proto|--proto-redir|--max-redirs|--retry|--connect-timeout)
                        (( $# )) || die "Mock curl option lacks a value: $argument"
                        shift
                        ;;
                esac
                ;;
            *) url=$argument ;;
        esac
    done
    [[ -n $output && -n $url ]] || die 'Mock curl did not receive output and URL arguments.'
    case "$CURL_MODE" in
        success) printf 'GGUFmock-payload\n' > "$output" ;;
        bad-magic) printf 'HTMLnot-a-model\n' > "$output" ;;
        empty) : > "$output" ;;
        missing) : ;;
        failure) return 22 ;;
        *) die "Unsupported mock curl mode: $CURL_MODE" ;;
    esac
}

# Keep ownership calls harmless even when the test is not running as root.
chown() { record_call chown "$@"; }
chmod() {
    record_call chmod "$@"
    command chmod "$@"
}
mv() {
    record_call mv "$@"
    command mv "$@"
}

prepare_case() {
    local case_name=$1
    CASE_DIR="$tmp_root/$case_name"
    MODEL_DIR="$CASE_DIR/models"
    MODEL_PATH="$MODEL_DIR/model.gguf"
    MODEL_DOWNLOAD_URL='https://huggingface.co/example/model-GGUF/resolve/main/model.gguf'
    CALL_LOG="$CASE_DIR/calls.log"
    CURL_MODE=success
    mkdir -p -- "$MODEL_DIR"
    : > "$CALL_LOG"
}

expect_status() {
    local label=$1 expected=$2 output status=0
    shift 2
    output="$CASE_DIR/output.log"
    if ( "$@" ) > "$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [[ $expected == ok ]]; then
        (( status == 0 )) || die "$label: unexpected failure: $(<"$output")"
    else
        (( status != 0 )) || die "$label: expected failure but downloader succeeded"
    fi
}

require_log() {
    local label=$1 needle=$2
    grep -F -- "$needle" "$CALL_LOG" >/dev/null || die "$label: expected '$needle' in $(<"$CALL_LOG")"
}

require_no_log() {
    local label=$1 needle=$2
    ! grep -F -- "$needle" "$CALL_LOG" >/dev/null || die "$label: did not expect '$needle' in $(<"$CALL_LOG")"
}

check_success_download() {
    prepare_case success
    expect_status 'successful GGUF download' ok download_requested_gguf
    [[ -f $MODEL_PATH ]] || die 'successful GGUF download: final GGUF was not created'
    [[ ! -e $MODEL_PATH.part && ! -L $MODEL_PATH.part ]] || die 'successful GGUF download: partial file was not promoted'
    [[ $(head -c 4 -- "$MODEL_PATH") == GGUF ]] || die 'successful GGUF download: final file lacks GGUF header'
    [[ $(<"$MODEL_PATH") == 'GGUFmock-payload' ]] || die 'successful GGUF download: payload changed during promotion'
    # Windows-backed workspaces can ignore chmod; the recorded command below
    # verifies the requested restrictive mode even when the host filesystem
    # cannot report it.  Linux CI additionally observes the resulting mode.
    if [[ $(uname -s) != MINGW* && $(uname -s) != MSYS* ]]; then
        [[ $(stat -c '%a' -- "$MODEL_PATH") == 640 ]] || die 'successful GGUF download: expected mode 0640'
    fi
    require_log 'successful GGUF download' 'curl|--disable|--fail|--location|--show-error|--proto|=https|--proto-redir|=https|--max-redirs|5|--retry|3|--retry-all-errors|--connect-timeout|30|--output'
    require_log 'successful GGUF download' "|$MODEL_DOWNLOAD_URL"
    require_log 'successful GGUF download' "chown|root:llama-target|$MODEL_PATH.part"
    require_log 'successful GGUF download' "chmod|0640|$MODEL_PATH.part"
    require_log 'successful GGUF download' "mv|-n|--|$MODEL_PATH.part|$MODEL_PATH"
    require_log 'successful GGUF download' "runuser|-u|llama-target|--|test|-w|$MODEL_DIR"
    require_log 'successful GGUF download' "runuser|-u|llama-target|--|test|-r|$MODEL_PATH"
    passed=$((passed + 1))
    printf 'PASS successful HTTPS-only GGUF download is checked and atomically promoted\n'
}

check_existing_final_is_preserved() {
    prepare_case existing-final
    printf 'GGUFexisting-model\n' > "$MODEL_PATH"
    expect_status 'existing final GGUF' ok download_requested_gguf
    [[ $(<"$MODEL_PATH") == 'GGUFexisting-model' ]] || die 'existing final GGUF: existing model was overwritten'
    require_no_log 'existing final GGUF' 'curl|'
    require_no_log 'existing final GGUF' 'mv|'
    grep -F -- 'will not overwrite it' "$CASE_DIR/output.log" >/dev/null || die 'existing final GGUF: expected preservation message'
    passed=$((passed + 1))
    printf 'PASS existing final GGUF is never overwritten\n'
}

check_invalid_or_missing_partial() {
    local mode=$1 expected_message=$2 case_name=$3
    prepare_case "$case_name"
    CURL_MODE=$mode
    expect_status "$case_name" fail download_requested_gguf
    [[ ! -e $MODEL_PATH && ! -L $MODEL_PATH ]] || die "$case_name: invalid download was promoted"
    grep -F -- "$expected_message" "$CASE_DIR/output.log" >/dev/null || die "$case_name: expected '$expected_message' in $(<"$CASE_DIR/output.log")"
    require_no_log "$case_name" 'mv|'
    passed=$((passed + 1))
    printf 'PASS %s is rejected before final promotion\n' "$case_name"
}

check_preexisting_partial_blocks_download() {
    prepare_case existing-partial
    printf 'GGUFinterrupted\n' > "$MODEL_PATH.part"
    expect_status 'existing partial GGUF' fail download_requested_gguf
    [[ -f $MODEL_PATH.part ]] || die 'existing partial GGUF: partial was unexpectedly removed'
    require_no_log 'existing partial GGUF' 'curl|'
    grep -F -- 'partial GGUF download already exists' "$CASE_DIR/output.log" >/dev/null || die 'existing partial GGUF: expected safety error'
    passed=$((passed + 1))
    printf 'PASS existing partial GGUF blocks an unsafe retry\n'
}

check_curl_failure_never_promotes() {
    prepare_case curl-failure
    CURL_MODE=failure
    expect_status 'curl failure' fail download_requested_gguf
    [[ ! -e $MODEL_PATH && ! -L $MODEL_PATH ]] || die 'curl failure: failed transfer was promoted'
    require_log 'curl failure' 'curl|'
    require_no_log 'curl failure' 'mv|'
    passed=$((passed + 1))
    printf 'PASS failed HTTPS transfer is never promoted\n'
}

check_no_url_is_a_noop() {
    prepare_case no-url
    MODEL_DOWNLOAD_URL=''
    expect_status 'empty download URL' ok download_requested_gguf
    [[ ! -e $MODEL_PATH ]] || die 'empty download URL: unexpectedly created a model'
    require_no_log 'empty download URL' 'curl|'
    passed=$((passed + 1))
    printf 'PASS empty download URL is a no-op\n'
}

check_success_download
check_existing_final_is_preserved
check_invalid_or_missing_partial bad-magic 'does not have a GGUF header' bad-magic
check_invalid_or_missing_partial empty 'downloaded GGUF is empty' empty-partial
check_invalid_or_missing_partial missing 'downloaded GGUF is empty' missing-partial
check_preexisting_partial_blocks_download
check_curl_failure_never_promotes
check_no_url_is_a_noop

printf '%s GGUF downloader cases passed. No network, ownership, or system-file changes were made.\n' "$passed"
