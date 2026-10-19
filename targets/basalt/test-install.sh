#!/usr/bin/env bash
# Focused local checks; no model, GPU, network or system service is required.
# Helpers are sourced from install-target.sh; the variables below are read by them.
# shellcheck disable=SC1090,SC2034
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target=$here/install-target.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/basalt-target-test.XXXXXX")
cleanup() {
    [[ $tmp == "${TMPDIR:-/tmp}"/basalt-target-test.* ]] || return
    rm -rf -- "$tmp"
}
trap cleanup EXIT

# Exercise the real download helper, with only the service-user wrapper and
# network command replaced. A failed curl must leave an incomplete .part file.
source <(sed -n '/^download_model() {/,/^}/p' "$target")
source <(sed -n '/^generate_run_script() {/,/^}/p' "$target")
source <(sed -n '/^start_env() {/,/^}/p' "$target")
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
as_service() { "$@"; }
install() { mkdir -p "${@: -1}"; }
chown() { :; }
BASALT_DATA_DIR=$tmp/data
BASALT_MODEL=fixture.basalt
BASALT_HF_REPO=https://huggingface.co/example/model
SERVICE_USER=basalt
dry_run=0
mkdir -p "$BASALT_DATA_DIR/models" "$tmp/bin"
BASALT_DIR=$tmp/source
BASALT_PORT=8080 BASALT_ALIAS=qwen3.8-flash-next BASALT_GPUS=0
BASALT_CONTEXT=32768 BASALT_ALLOW_NO_KEY=false api_key=secret-for-test
model_path=$BASALT_DATA_DIR/models/$BASALT_MODEL
run_script=$tmp/run-basalt.sh
generate_run_script
sh -n "$run_script"
grep -q -- '--max-context 32768' "$run_script"
grep -q -- '--api-key secret-for-test' "$run_script"
if [[ $(uname -s) == Linux ]]; then
    [[ $(stat -c %a "$run_script") == 700 ]] || { echo 'FAIL launcher permissions' >&2; exit 1; }
fi
[[ $(start_env) != *secret-for-test* ]] || { echo 'FAIL key leaked into EnvironmentFile' >&2; exit 1; }
cat > "$tmp/bin/curl" <<'CURL'
#!/bin/sh
printf 'partial' > "${BASALT_MODEL}.part"
exit 22
CURL
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
if (download_model) > "$tmp/download.log" 2>&1; then
    printf 'FAIL failed transfer was accepted\n' >&2; exit 1
fi
[[ -f $BASALT_DATA_DIR/models/fixture.basalt.part ]] || {
    printf 'FAIL missing .part\n%s\n' "$(cat "$tmp/download.log")" >&2; exit 1;
}
[[ ! -e $BASALT_DATA_DIR/models/fixture.basalt ]] || { echo 'FAIL incomplete model promoted' >&2; exit 1; }

# A stale truncated final file must not be accepted as a valid model either.
printf 'truncated' > "$BASALT_DATA_DIR/models/fixture.basalt"
if (download_model) > "$tmp/existing.log" 2>&1; then
    printf 'FAIL truncated existing model was accepted\n' >&2; exit 1
fi
grep -q 'Existing model is too small' "$tmp/existing.log" || {
    printf 'FAIL unexpected existing-model result\n%s\n' "$(cat "$tmp/existing.log")" >&2; exit 1;
}

if output=$(CUDA_VERSION=13.1 CUDA_TOOLKIT_PKG=cuda-toolkit-13-0 bash "$here/cuda-toolkit.sh" 2>&1); then
    printf 'FAIL mismatched CUDA package was accepted\n' >&2; exit 1
fi
[[ $output == *'does not match CUDA_VERSION=13.1'* ]] || {
    printf 'FAIL unexpected CUDA error: %s\n' "$output" >&2; exit 1;
}

printf 'Basalt model transfer failure and CUDA package validation passed.\n'
