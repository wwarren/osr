#!/usr/bin/env bash
# Runs inside the dedicated Xolotl LXC after matching NVIDIA userspace is ready.
#
#   bash install-target.sh             install or update Xolotl and start it
#   bash install-target.sh --upgrade   move to XOLOTL_COMMIT or XOLOTL_REF (default
#                                      tested commit in upstream-commit.txt);
#                                      roll back to the previous commit
#                                      and runtime on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# Xolotl (https://github.com/Indras-Mirror/Xolotl) is a Strata fork with its own
# DeepSeek-V4.1-Flash engine. This target builds that engine (ds41_generate),
# downloads the pinned DeepSeek-V4.1-Flash-1017 V4 quant and Engram tables
# listed in xolotl-weights.txt, and serves them through Strata's OpenAI- and
# Anthropic-compatible server (tools/v41/serve/serve_ds41.py).
set -Eeuo pipefail

XOLOTL_URL=https://github.com/Indras-Mirror/Xolotl.git
# Paths are overridable for tests only; the unit file uses the defaults.
XOLOTL_DIR=${XOLOTL_DIR:-/opt/xolotl}
XOLOTL_DATA_DIR=${XOLOTL_DATA_DIR:-/var/lib/xolotl}
XOLOTL_ETC_DIR=${XOLOTL_ETC_DIR:-/etc/xolotl-target}
# The server config (it holds the API key): root may change it, the xolotl
# group may only read it. Kept apart from the root-only records above.
XOLOTL_CONFIG_DIR=${XOLOTL_CONFIG_DIR:-/etc/xolotl}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
XOLOTL_STATE_DIR=${XOLOTL_STATE_DIR:-/var/lib/xolotl-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-xolotl}
# GPU device nodes whose group the service user joins (glob-expanded).
GPU_NODES=${GPU_NODES:-'/dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm'}
MEMINFO=${MEMINFO:-/proc/meminfo}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh [--dry-run] [--upgrade]
Installs Xolotl from https://github.com/Indras-Mirror/Xolotl.git as the
"xolotl" service account, builds its DeepSeek-V4.1 engine with the CUDA
toolkit installed here, downloads the pinned DeepSeek-V4.1-Flash-1017 V4 quant
and Engram tables (about 372 GB, see xolotl-weights.txt), and starts the
hardened xolotl systemd service. Re-running fetches XOLOTL_COMMIT or XOLOTL_REF
before stopping anything: when the commit, settings, weights and unit are
unchanged and Xolotl is healthy it does nothing; otherwise it rebuilds and
restarts, rolling back to the previous commit and runtime on failure.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or installed-settings for older installs); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment: by default, use the tested commit in upstream-commit.txt.
XOLOTL_REF=<branch or tag, e.g. main> or XOLOTL_COMMIT=<full SHA-1 pin>
overrides that default (XOLOTL_COMMIT wins if both are set).
XOLOTL_CUDA_VERSION=13.0,
XOLOTL_CUDA_ARCH=auto (the GPU's compute capability, e.g. 89 for RTX 40; 75 or
newer), XOLOTL_PORT=8080, XOLOTL_CONTEXT=131072, XOLOTL_ARENA_GIB=60 (the
pinned RAM expert arena), XOLOTL_DSPARK=true (speculative decoding with the
5.7 GB DSpark sidecar), XOLOTL_MODEL_NAME=deepseek-v4.1-flash (the API's model
id), XOLOTL_READY_TIMEOUT=1800 (seconds).
USAGE
}

# Install helpers (sourced by test-install.sh) ---------------------------------

# The files a checkout must carry, and the CMake options this installer passes.
REQUIRED_FILES=(CMakeLists.txt requirements.txt tools/xolotl/fetch-llama.sh tools/v41/serve/serve_ds41.py
    tools/v41/serve/dspark_expert_counts.txt tools/v41/engine/ds41_generate.cpp serve/server.py)
REQUIRED_CMAKE_OPTIONS=(STRATA_ENABLE_CUDA STRATA_GGML_CUDA STRATA_MMQ_KQUANTS STRATA_GGML_DIR
    STRATA_DSV41_FQ_OP STRATA_DSV41_HC_MIX)
# The engine flags the server config passes (checked against ds41_generate.cpp).
REQUIRED_ENGINE_FLAGS=(-m --backend --experts --engram --rank --ctx --stop --arena-adapt --kv-fp4
    --route-bias --route-bias-file --arena-gib --tier-batch-pcie --prompt-batch)

# validate_checkout DIR: refuse a checkout this installer does not know how to
# build or serve, before anything is built or stopped.
validate_checkout() {
    local dir=$1 file option flag
    local -a missing=()
    for file in "${REQUIRED_FILES[@]}"; do
        [[ -f $dir/$file ]] || missing+=("$file")
    done
    (( ${#missing[@]} == 0 )) ||
        { note "This Xolotl checkout lacks: ${missing[*]}. Pin a compatible XOLOTL_COMMIT."; return 1; }
    # The DeepSeek-V4.1 options are declared in tools/v41/engine/v41_engine.cmake.
    for option in "${REQUIRED_CMAKE_OPTIONS[@]}"; do
        grep -rqs --include=CMakeLists.txt --include='*.cmake' -- "$option" "$dir/CMakeLists.txt" "$dir/cmake" "$dir/tools" ||
            missing+=("-D$option")
    done
    for flag in "${REQUIRED_ENGINE_FLAGS[@]}"; do
        grep -qF -- "\"$flag\"" "$dir/tools/v41/engine/ds41_generate.cpp" || missing+=("$flag")
    done
    (( ${#missing[@]} == 0 )) ||
        { note "This Xolotl checkout's build or engine does not accept: ${missing[*]}. Pin a compatible XOLOTL_COMMIT."; return 1; }
    # Strata's server must take its API key and listen address from the config.
    grep -q 'cfg.get("api_key"' "$dir/serve/server.py" && grep -q 'cfg.get("host")' "$dir/serve/server.py" ||
        { note "This Xolotl checkout's server does not read \"api_key\" and \"host\" from its config. Pin a compatible XOLOTL_COMMIT."; return 1; }
}

# cmake_args: the configure arguments for the DeepSeek-V4.1 engine (README:
# Quick start), with this CT's nvcc, GPU architecture and the venv's ninja.
cmake_args() {
    printf '%s\n' -S . -B build-xolotl -G Ninja -DCMAKE_BUILD_TYPE=Release \
        "-DCMAKE_MAKE_PROGRAM=$XOLOTL_DIR/.venv/bin/ninja" "-DCMAKE_CUDA_COMPILER=$XOLOTL_NVCC" \
        -DSTRATA_ENABLE_CUDA=ON -DSTRATA_GGML_CUDA=ON -DSTRATA_MMQ_KQUANTS=ON \
        "-DCMAKE_CUDA_ARCHITECTURES=$XOLOTL_CUDA_ARCH" "-DSTRATA_GGML_DIR=$XOLOTL_DIR/third_party/llama.cpp" \
        -DSTRATA_DSV41_FQ_OP=ON -DSTRATA_DSV41_HC_MIX=ON
}

# compute_cap_arch: "8.9" (nvidia-smi --query-gpu=compute_cap) -> 89.
compute_cap_arch() {
    local cap
    cap=$(head -n1 | tr -d '[:space:]')
    [[ $cap =~ ^([0-9]+)\.([0-9])$ ]] || return 1
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# NVIDIA reports the memory available on GPU 0 in MiB. A marketed 16 GB card
# can report slightly less than 16384 MiB after firmware reservations.
gpu0_vram_mib() {
    local mib
    mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0 2>/dev/null | head -n1 | tr -d '[:space:]') || return 1
    [[ $mib =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$mib"
}

# Paths of the installed weights (see xolotl-weights.txt).
MODEL_SUBDIR=v41-xq-1017-v4
ENGRAM_SUBDIR=engram-1017
model_path() { printf '%s/models/%s/%s\n' "$XOLOTL_DATA_DIR" "$MODEL_SUBDIR" "$1"; }
engram_dir() { printf '%s/models/%s\n' "$XOLOTL_DATA_DIR" "$ENGRAM_SUBDIR"; }

# weight_rows FILE: the rows this install needs, checked, as
# "type path size hash url" lines (dspark rows only with XOLOTL_DSPARK=true).
weight_rows() {
    local group type path size hash url extra found=0
    while read -r group type path size hash url extra; do
        [[ -n $group && $group != \#* ]] || continue
        if [[ ! $group =~ ^(model|dspark|engram)$ || ! $type =~ ^(file|part|join)$ ||
              ! $path =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ || $path == *..* ||
              ! $size =~ ^[1-9][0-9]{0,14}$ || ! $hash =~ ^(sha256:[0-9a-f]{64}|git:[0-9a-f]{40})$ || -n $extra ]] ||
           { [[ $type == join ]] && [[ $url != - ]]; } ||
           { [[ $type != join ]] && [[ ! $url =~ ^https://huggingface\.co/[^[:space:]\'\"\`\$\\]+$ ]]; }; then
            printf 'Error: malformed row in %s: %s %s %s\n' "$1" "$group" "$type" "$path" >&2
            return 1
        fi
        [[ $group != dspark || $XOLOTL_DSPARK == true ]] || continue
        printf '%s %s %s %s %s\n' "$type" "$path" "$size" "$hash" "$url"
        found=1
    done < "$1"
    (( found )) || { printf 'Error: %s lists no weights.\n' "$1" >&2; return 1; }
}

# The settings that decide how Xolotl is built and served. save_settings
# records them after every successful install or upgrade, so a failed upgrade
# can roll back to what last worked.
SETTING_KEYS=(XOLOTL_CUDA_VERSION XOLOTL_NVCC XOLOTL_CUDA_ARCH XOLOTL_PORT XOLOTL_CONTEXT
    XOLOTL_ARENA_GIB XOLOTL_DSPARK XOLOTL_MODEL_NAME)

# validate_settings: die unless every setting has a value this script accepts.
validate_settings() {
    [[ $XOLOTL_CUDA_VERSION =~ ^(12\.(8|9)|1[3-9]\.[0-9]+)$ ]] || die 'XOLOTL_CUDA_VERSION must be 12.8 or newer.'
    [[ $XOLOTL_NVCC =~ ^/[A-Za-z0-9._/-]+$ && $XOLOTL_NVCC != *..* ]] || die 'Invalid XOLOTL_NVCC.'
    [[ $XOLOTL_CUDA_ARCH == auto || ( $XOLOTL_CUDA_ARCH =~ ^[1-9][0-9]{1,2}$ && $XOLOTL_CUDA_ARCH -ge 75 ) ]] ||
        die 'XOLOTL_CUDA_ARCH must be auto or a compute capability of 75 or newer (75, 80, 86, 89, 120, ...).'
    [[ $XOLOTL_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( XOLOTL_PORT <= 65535 )) || die 'Invalid XOLOTL_PORT.'
    [[ $XOLOTL_CONTEXT =~ ^[1-9][0-9]{3,6}$ ]] && (( XOLOTL_CONTEXT <= 1048576 )) ||
        die 'XOLOTL_CONTEXT must be 1000..1048576 tokens.'
    [[ $XOLOTL_ARENA_GIB =~ ^[1-9][0-9]{0,3}$ ]] && (( XOLOTL_ARENA_GIB >= 8 )) ||
        die 'XOLOTL_ARENA_GIB must be at least 8.'
    [[ $XOLOTL_DSPARK =~ ^(true|false)$ ]] || die 'XOLOTL_DSPARK must be true or false.'
    [[ $XOLOTL_MODEL_NAME =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die 'Invalid XOLOTL_MODEL_NAME (lowercase letters, digits, ., _ and -).'
}

# settings_env: the settings as KEY=value lines (no secrets).
settings_env() {
    local key
    for key in "${SETTING_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}" || return 1; done
}

# load_settings FILE: set the recorded settings from FILE. The file is parsed,
# never sourced: only the known keys are read, and nothing is changed unless
# every key is present and valid.
load_settings() {
    local file=$1 line key
    local -A found=()
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^(XOLOTL_[A-Z_]+)=(.*)$ ]] || continue
        [[ " ${SETTING_KEYS[*]} " == *" ${BASH_REMATCH[1]} "* ]] || continue
        found[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    done < "$file"
    for key in "${SETTING_KEYS[@]}"; do [[ -v found[$key] ]] || return 1; done
    # Validate in a subshell first: validate_settings dies on a bad value.
    (
        for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
        validate_settings
    ) >/dev/null 2>&1 || return 1
    for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
}

# fingerprint_env FILE: an installed-settings fingerprint as the KEY=value
# lines load_settings reads.
fingerprint_env() {
    sed -n -e 's/^cuda=/XOLOTL_CUDA_VERSION=/p' \
        -e 's/^nvcc=/XOLOTL_NVCC=/p' \
        -e 's/^arch=/XOLOTL_CUDA_ARCH=/p' \
        -e 's/^port=/XOLOTL_PORT=/p' \
        -e 's/^context=/XOLOTL_CONTEXT=/p' \
        -e 's/^arena_gib=/XOLOTL_ARENA_GIB=/p' \
        -e 's/^dspark=/XOLOTL_DSPARK=/p' \
        -e 's/^model_name=/XOLOTL_MODEL_NAME=/p' "$1"
}

# saved_settings: an existing installation keeps its settings on every rerun,
# with or without --upgrade. Explicit, non-empty environment values win. Only
# a fresh install with no checkout, unit or settings record uses the defaults.
saved_settings() {
    local key
    local -A overrides=()
    for key in "${SETTING_KEYS[@]}"; do
        if [[ -n ${!key-} ]]; then overrides[$key]=${!key}; fi
    done
    if [[ -e $XOLOTL_ETC_DIR/installed-env ]]; then
        load_settings "$XOLOTL_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $XOLOTL_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $XOLOTL_ETC_DIR/installed-settings || -L $XOLOTL_ETC_DIR/installed-settings ||
            -e $XOLOTL_ETC_DIR/pending-env || -L $XOLOTL_ETC_DIR/pending-env ||
            -e $XOLOTL_DIR/.git || -L $XOLOTL_DIR/.git ||
            -e $UNIT_DIR/xolotl.service || -L $UNIT_DIR/xolotl.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $XOLOTL_ETC_DIR/installed-settings && -r $XOLOTL_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$XOLOTL_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $XOLOTL_ETC_DIR/installed-settings (installed-env is missing)."
        elif [[ ! -e $XOLOTL_ETC_DIR/installed-settings && ! -L $XOLOTL_ETC_DIR/installed-settings &&
                -f $XOLOTL_ETC_DIR/pending-env && -r $XOLOTL_ETC_DIR/pending-env ]] &&
                load_settings "$XOLOTL_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($XOLOTL_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $XOLOTL_ETC_DIR/installed-settings || -L $XOLOTL_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $XOLOTL_ETC_DIR/installed-settings"
            else
                missing="Found an existing Xolotl installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $XOLOTL_ETC_DIR)"
            fi
            for key in "${SETTING_KEYS[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${SETTING_KEYS[*]} explicitly, or restore a record."
            done
        fi
    fi
    # A changed toolkit version needs its matching default nvcc unless supplied.
    if [[ -v overrides[XOLOTL_CUDA_VERSION] && ! -v overrides[XOLOTL_NVCC] &&
          ${overrides[XOLOTL_CUDA_VERSION]} != "${XOLOTL_CUDA_VERSION:-}" ]]; then
        unset XOLOTL_NVCC
    fi
    for key in "${!overrides[@]}"; do printf -v "$key" '%s' "${overrides[$key]}"; done
}

# server_config: the JSON config serve_ds41.py reads (Strata's server format:
# exe, args, cwd, tokenizer, model_name, host, api_key, env). The key is read
# from the environment of python3, never from its arguments.
server_config() {
    XC_DIR=$XOLOTL_DIR XC_MODEL=$(model_path V41-XQ-1017-v4.gguf) XC_RANK=$(model_path rank-1017-v4.bin) \
    XC_TOKENIZER=$(model_path tokenizer) XC_DSPARK_FILE=$(model_path V41-MTP-Vision-1017.Q2_K.gguf) \
    XC_ENGRAM=$(engram_dir) XC_CACHE=$XOLOTL_DATA_DIR/cache/dense-requant \
    XC_CONTEXT=$XOLOTL_CONTEXT XC_ARENA=$XOLOTL_ARENA_GIB XC_DSPARK=$XOLOTL_DSPARK \
    XC_NAME=$XOLOTL_MODEL_NAME XC_KEY=${api_key:-} python3 -c '
import json, os
e = os.environ
d = e["XC_DIR"]
env = {
    "GGML_NO_BACKTRACE": "1",
    # 4 KiB pages pin the RAM arena far faster than THP (ds41-engine.sh).
    "STRATA_NO_LARGEPAGES": "1",
    # Short turns run as exact passes; longer ones as the exact batch.
    "STRATA_SERVE_STEP_MAX": "96",
    "STRATA_SERVE_PASS_BIAS": "0",
    "STRATA_SERVE_LOOKUP": "14",
    # The dense half re-quantized to Q6_K at load (more VRAM for experts),
    # cached in the data directory.
    "STRATA_DENSE_REQUANT": "q6_K",
    "STRATA_DENSE_REQUANT_CACHE": e["XC_CACHE"],
    "STRATA_PRESTAGE_GIB": "1.5",
    "STRATA_ATTN_F16_GATHER": "1",
    # An unprivileged CT cannot open the block device under the Engram tables.
    "STRATA_ENGRAM_RAWDEV": "0",
}
if e["XC_DSPARK"] == "true":
    env.update({
        "STRATA_SERVE_DSPARK": e["XC_DSPARK_FILE"],
        "STRATA_DSPARK_KEEP": d + "/tools/v41/serve/dspark_expert_counts.txt:64",
        "STRATA_DSPARK_DEPTH": "4",
        "STRATA_DSPARK_CONF": "0.6",
        "STRATA_SERVE_DSPARK_EVICT": "4096",
    })
config = {
    "exe": d + "/build-xolotl/ds41_generate",
    "args": ["-m", e["XC_MODEL"], "--backend", "cuda", "--experts", "gpu",
             "--engram", e["XC_ENGRAM"], "--rank", e["XC_RANK"],
             "--ctx", e["XC_CONTEXT"], "--stop", "1", "--arena-adapt", "--kv-fp4",
             "--route-bias", "0.5", "--route-bias-file", "0.3",
             "--arena-gib", e["XC_ARENA"], "--tier-batch-pcie", "0.25", "--prompt-batch", "12288"],
    "cwd": d,
    "tokenizer": e["XC_TOKENIZER"],
    "model_name": e["XC_NAME"],
    "host": "0.0.0.0",
    "gpu": 0,
    "api_key": e["XC_KEY"],
    "sampling": {"temperature": 1, "top_p": 0.95},
    "reasoning_budget_tokens": 32768,
    "env": env,
}
print(json.dumps(config, indent=2))
'
}

# settings_fingerprint: what the running service was set up with. A rerun that
# finds the same commit, this fingerprint and the same unit does nothing.
settings_fingerprint() {
    local config_hash toolkit_hash weights_hash
    config_hash=$(server_config | sha256sum | cut -d' ' -f1) || return 1
    toolkit_hash=$(sha256sum "$source_dir/cuda-toolkit.sh" | cut -d' ' -f1) || return 1
    weights_hash=$(sha256sum "$source_dir/xolotl-weights.txt" | cut -d' ' -f1) || return 1
    printf 'cuda=%s\nnvcc=%s\narch=%s\nport=%s\ncontext=%s\narena_gib=%s\ndspark=%s\nmodel_name=%s\ntoolkit_sha256=%s\nweights_sha256=%s\nconfig_sha256=%s\n' \
        "$XOLOTL_CUDA_VERSION" "$XOLOTL_NVCC" "$XOLOTL_CUDA_ARCH" "$XOLOTL_PORT" "$XOLOTL_CONTEXT" \
        "$XOLOTL_ARENA_GIB" "$XOLOTL_DSPARK" "$XOLOTL_MODEL_NAME" "$toolkit_hash" "$weights_hash" "$config_hash"
}

# start_env: the EnvironmentFile the unit expands into ExecStart (no secrets).
start_env() {
    printf '# Written by install-target.sh; do not edit.\n'
    printf 'XOLOTL_PORT=%s\n' "$XOLOTL_PORT"
}

# End install helpers. ----------------------------------------------------------

# as_service CMD...: run CMD as the service account. The installer lock's
# descriptor is closed for it, so nothing it leaves running in the background
# (git's detached housekeeping, an upstream script's helper) holds the lock
# after the installer has exited.
as_service() {
    if [[ -n ${install_lock_fd:-} ]]; then
        runuser -u "$SERVICE_USER" -- env HOME="$XOLOTL_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$XOLOTL_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$XOLOTL_DIR" -C "$XOLOTL_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$XOLOTL_URL" ]] || die "Existing $XOLOTL_DIR origin is not official: $origin"
}

fetch_spec() {
    if [[ -n $XOLOTL_COMMIT ]]; then printf '%s\n' "$XOLOTL_COMMIT"; else printf '%s\n' "$XOLOTL_REF"; fi
}

# Fetch the target into FETCH_HEAD without touching the checkout, and print
# the fetched commit. A fetch by commit works for any commit, not only a
# branch tip.
fetch_target() {
    local fetched
    if [[ ! -d $XOLOTL_DIR/.git ]]; then
        as_service git init -q "$XOLOTL_DIR"
        as_service git -C "$XOLOTL_DIR" remote add origin "$XOLOTL_URL"
    fi
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$XOLOTL_DIR" fetch -q --depth 1 origin "$(fetch_spec)" >&2 || return 1
    fetched=$(git_root rev-parse 'FETCH_HEAD^{commit}') || return 1
    if [[ -n $XOLOTL_COMMIT && ${fetched,,} != "${XOLOTL_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $XOLOTL_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$XOLOTL_DIR" checkout -q --detach "$1"
    printf 'Xolotl source commit: %s\n' "$(git_root rev-parse HEAD)"
}

# build_engine: Xolotl's pinned Python packages (cmake and ninja among them),
# llama.cpp at Xolotl's pinned commit with its ggml patch, then ds41_generate.
# Everything runs as the service account inside the checkout.
build_engine() {
    local -a args
    validate_checkout "$XOLOTL_DIR" || return 1
    [[ -x $XOLOTL_NVCC ]] ||
        { note "$XOLOTL_NVCC is missing; cuda-toolkit.sh should have installed CUDA $XOLOTL_CUDA_VERSION there."; return 1; }
    if [[ ! -x $XOLOTL_DIR/.venv/bin/python ]] || ! as_service "$XOLOTL_DIR/.venv/bin/python" -m pip --version >/dev/null 2>&1; then
        rm -rf -- "$XOLOTL_DIR/.venv"
        (cd "$XOLOTL_DIR" && as_service python3 -m venv .venv) || return 1
    fi
    (cd "$XOLOTL_DIR" && as_service .venv/bin/python -m pip install --disable-pip-version-check -q -r requirements.txt) || return 1
    # fetch-llama.sh keeps a tree that already carries its patch, even when
    # this commit pins another llama.cpp commit: start that tree again.
    local pin head
    pin=$(sed -n 's/^PIN=\([0-9a-f]\{40\}\)$/\1/p' "$XOLOTL_DIR/tools/xolotl/fetch-llama.sh")
    if [[ -d $XOLOTL_DIR/third_party/llama.cpp ]]; then
        # As the account that owns the tree: root never runs git in a
        # repository another account can configure.
        head=$(as_service git -C "$XOLOTL_DIR/third_party/llama.cpp" rev-parse HEAD 2>/dev/null || true)
        if [[ -z $pin || $head != "$pin" ]]; then
            note "third_party/llama.cpp is at ${head:-an unknown commit}, not the pinned ${pin:-?}; fetching it again."
            as_service rm -rf -- "$XOLOTL_DIR/third_party/llama.cpp" || return 1
        fi
    fi
    (cd "$XOLOTL_DIR" && as_service bash tools/xolotl/fetch-llama.sh) || return 1
    mapfile -t args < <(cmake_args)
    printf '+ cmake %s\n' "${args[*]}"
    (cd "$XOLOTL_DIR" && as_service env "PATH=${XOLOTL_NVCC%/*}:/usr/local/bin:/usr/bin:/bin" \
        .venv/bin/cmake "${args[@]}") || return 1
    (cd "$XOLOTL_DIR" && as_service env "PATH=${XOLOTL_NVCC%/*}:/usr/local/bin:/usr/bin:/bin" \
        .venv/bin/cmake --build build-xolotl --target ds41_generate) || return 1
    [[ -x $XOLOTL_DIR/build-xolotl/ds41_generate && ! -L $XOLOTL_DIR/build-xolotl/ds41_generate ]] ||
        { note "The build did not produce $XOLOTL_DIR/build-xolotl/ds41_generate."; return 1; }
}

# --- weights ------------------------------------------------------------------
# hf_head URL: "<status> <X-Linked-Size> <X-Linked-Etag>" of a Hugging Face
# resolve URL, without following its redirect ("-" when absent).
hf_head() {
    curl -sS --max-time 30 --proto '=https' -I -- "$1" 2>/dev/null | tr -d '\r' | awk '
        tolower($1) ~ /^http\// { status = $2 }
        tolower($1) == "x-linked-size:" { size = $2 }
        tolower($1) == "x-linked-etag:" { etag = $2; gsub(/"/, "", etag) }
        END { printf "%s %s %s\n", status ? status : "000", size ? size : "-", etag ? tolower(etag) : "-" }'
}
# The record of weights already verified: "path hash size mtime" lines,
# root-owned, so a rerun need not hash ~370 GB again.
verified_record() { printf '%s/verified-weights\n' "$XOLOTL_ETC_DIR"; }
is_verified() {
    local path=$1 hash=$2 file stat
    file=$XOLOTL_DATA_DIR/models/$path
    as_service test -f "$file" || return 1
    stat=$(as_service stat -c '%s %Y' -- "$file") || return 1
    grep -qxF -- "$path $hash $stat" "$(verified_record)" 2>/dev/null
}
record_weight() {
    local record temporary
    record=$(verified_record)
    temporary=$(mktemp "$record.XXXXXX")
    { grep -v -- "^$1 " "$record" 2>/dev/null || true; printf '%s\n' "$*"; } > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$record"
}
# hash_matches FILE HASH: sha256:<hex> or git:<blob id>. Runs as the service
# account, which owns the data directory.
hash_matches() {
    local file=$1 hash=$2 actual
    case $hash in
        sha256:*) actual=sha256:$(as_service sha256sum -- "$file" | awk '{ print $1 }') ;;
        git:*) actual=git:$(as_service git hash-object --no-filters -- "$file") ;;
        *) return 1 ;;
    esac
    [[ $actual == "$hash" ]] || { note "$file has ${actual%%:*} ${actual#*:}, not ${hash#*:}."; return 1; }
}
# download URL FILE SIZE: FILE (as the service account), resuming FILE if it
# is a shorter partial download; FILE ends up exactly SIZE bytes or this fails.
download() {
    local url=$1 file=$2 size=$3 have attempt
    for attempt in 1 2 3 4 5; do
        have=$(as_service stat -c %s -- "$file" 2>/dev/null || echo 0)
        if (( have > size )); then as_service rm -f -- "$file"; have=0; fi
        (( have == size )) && return 0
        printf 'Downloading %s (%s of %s MB)...\n' "${file##*/}" "$(( have / 1048576 ))" "$(( size / 1048576 ))"
        if as_service curl -fSL --progress-bar --proto '=https' --speed-limit 65536 --speed-time 120 \
                -C "$have" -o "$file" -- "$url"; then
            continue
        fi
        if (( attempt < 5 )); then note 'The download was interrupted; resuming.'; sleep 5; fi
    done
    have=$(as_service stat -c %s -- "$file" 2>/dev/null || echo 0)
    (( have == size )) || { note "Downloading ${file##*/} failed ($have of $size bytes). Rerun install-target.sh to resume it."; return 1; }
}
# fetch_file PATH SIZE HASH URL: models/PATH, downloaded unless verified.
fetch_file() {
    local path=$1 size=$2 hash=$3 url=$4 file partial stat
    file=$XOLOTL_DATA_DIR/models/$path
    partial=${file%/*}/.${file##*/}.part
    is_verified "$path" "$hash" && { printf 'Have %s (verified).\n' "$path"; return 0; }
    as_service mkdir -p -- "${file%/*}"
    if as_service test -e "$file"; then
        stat=$(as_service stat -c '%s %Y' -- "$file")
        [[ ${stat%% *} == "$size" ]] || die "$file is ${stat%% *} bytes, not $size. Move it aside to download it again."
        printf 'Checking %s...\n' "$path"
        hash_matches "$file" "$hash" || die "$file does not match xolotl-weights.txt. Move it aside to download it again."
        record_weight "$path" "$hash" "$stat"
        return 0
    fi
    download "$url" "$partial" "$size" || exit 1
    printf 'Checking %s...\n' "$path"
    if ! hash_matches "$partial" "$hash"; then
        as_service rm -f -- "$partial"
        die "Checksum mismatch for $path. The download was removed."
    fi
    as_service mv -f -- "$partial" "$file"
    record_weight "$path" "$hash" "$(as_service stat -c '%s %Y' -- "$file")"
    printf 'Installed %s.\n' "$path"
}
# fetch_joined PATH SIZE HASH PARTS: models/PATH from its parts ("size hash
# url" lines, in order). Each part is downloaded, verified, appended to
# .PATH.joining and deleted, so the disk holds at most the joined bytes plus
# one part. A rerun resumes after the last whole part appended.
fetch_joined() {
    local path=$1 size=$2 hash=$3 parts=$4 file joining partial joined offset=0 index=0 psize phash purl stat
    file=$XOLOTL_DATA_DIR/models/$path
    joining=${file%/*}/.${file##*/}.joining
    is_verified "$path" "$hash" && { printf 'Have %s (verified).\n' "$path"; return 0; }
    as_service mkdir -p -- "${file%/*}"
    if as_service test -e "$file"; then
        stat=$(as_service stat -c '%s %Y' -- "$file")
        [[ ${stat%% *} == "$size" ]] || die "$file is ${stat%% *} bytes, not $size. Move it aside to download it again."
        printf 'Checking %s...\n' "$path"
        hash_matches "$file" "$hash" || die "$file does not match xolotl-weights.txt. Move it aside to download it again."
        record_weight "$path" "$hash" "$stat"
        return 0
    fi
    as_service touch -- "$joining"
    joined=$(as_service stat -c %s -- "$joining")
    # The list is read on its own descriptor: nothing run below can consume it.
    while read -r psize phash purl <&3; do
        index=$(( index + 1 ))
        if (( joined >= offset + psize )); then offset=$(( offset + psize )); continue; fi
        if (( joined != offset )); then
            # An append that stopped part-way: drop the incomplete part's bytes.
            note "Dropping $(( joined - offset )) bytes of an incomplete append of part $index."
            as_service truncate -s "$offset" -- "$joining"
            joined=$offset
        fi
        partial=${file%/*}/.${file##*/}.part-$index
        download "$purl" "$partial" "$psize" || exit 1
        printf 'Checking part %s of %s...\n' "$index" "$path"
        if ! hash_matches "$partial" "$phash"; then
            as_service rm -f -- "$partial"
            die "Checksum mismatch for part $index of $path. The download was removed; rerun to fetch it again."
        fi
        as_service sh -c 'cat -- "$1" >> "$2" && rm -f -- "$1"' sh "$partial" "$joining" ||
            die "Could not append part $index to $joining."
        offset=$(( offset + psize )); joined=$offset
    done 3<<< "$parts"
    (( joined == size )) || die "$joining is $joined bytes after every part, not $size."
    printf 'Checking %s...\n' "$path"
    hash_matches "$joining" "$hash" || {
        as_service rm -f -- "$joining"
        die "The joined $path does not match its hash; it was removed. Rerun to download it again."
    }
    as_service mv -f -- "$joining" "$file"
    record_weight "$path" "$hash" "$(as_service stat -c '%s %Y' -- "$file")"
    printf 'Installed %s.\n' "$path"
}
# install_weights: every file of xolotl-weights.txt this install needs. Files
# not yet verified are checked against Hugging Face (status, size and SHA-256)
# and the free space is compared with what is missing before anything is
# downloaded; a fully verified set needs no network.
install_weights() {
    local rows type path size hash url status linked_size etag need=0 have avail joined_parts=''
    local -a plan=()
    rows=$(weight_rows "$source_dir/xolotl-weights.txt") || return 1
    as_service mkdir -p -- "$XOLOTL_DATA_DIR/models/$MODEL_SUBDIR" "$XOLOTL_DATA_DIR/models/$ENGRAM_SUBDIR"
    while read -r type path size hash url <&3; do
        if [[ $type == join ]]; then
            if ! is_verified "$path" "$hash" && ! as_service test -e "$XOLOTL_DATA_DIR/models/$path"; then
                have=$(as_service stat -c %s -- "$XOLOTL_DATA_DIR/models/${path%/*}/.${path##*/}.joining" 2>/dev/null || echo 0)
                (( have <= size )) || have=0
                need=$(( need + size - have ))
            fi
            plan+=("join $path $size $hash")
            continue
        fi
        # The parts of a verified or present joined file are not needed.
        if [[ $type == part ]]; then
            local joined_hash
            joined_hash=$(awk -v p="$path" '$1 == "join" && $2 == p { print $4 }' <<< "$rows")
            if is_verified "$path" "$joined_hash" || as_service test -e "$XOLOTL_DATA_DIR/models/$path"; then continue; fi
        elif is_verified "$path" "$hash" || as_service test -e "$XOLOTL_DATA_DIR/models/$path"; then
            plan+=("file $path $size $hash $url")
            continue
        fi
        read -r status linked_size etag < <(hf_head "$url")
        case $status in
            2??|3??) ;;
            *) note "$url did not answer (HTTP $status); check the CT's internet access."; return 1 ;;
        esac
        [[ $linked_size == - || $linked_size == "$size" ]] ||
            { note "${url##*/} is now $linked_size bytes upstream, not the reviewed $size. Review it and update xolotl-weights.txt."; return 1; }
        if [[ $hash == sha256:* && $etag != - && $etag != "${hash#sha256:}" ]]; then
            note "Hugging Face reports SHA-256 $etag for ${url##*/}, not the reviewed ${hash#sha256:}. Review it and update xolotl-weights.txt."
            return 1
        fi
        if [[ $type == part ]]; then
            joined_parts+="$path $size $hash $url"$'\n'
        else
            have=$(as_service stat -c %s -- "$XOLOTL_DATA_DIR/models/${path%/*}/.${path##*/}.part" 2>/dev/null || echo 0)
            (( have <= size )) || have=0
            need=$(( need + size - have ))
            plan+=("file $path $size $hash $url")
        fi
    done 3<<< "$rows"
    if (( need > 0 )); then
        # One part (at most 10 GiB) sits beside the joined file while it is
        # appended; otherwise keep 1 GiB spare.
        local room=1073741824
        [[ -n $joined_parts ]] && room=16106127360
        avail=$(df -PB1 -- "$XOLOTL_DATA_DIR/models" | awk 'NR == 2 { print $4 }')
        [[ $avail =~ ^[0-9]+$ ]] || { note "Cannot read the free space of $XOLOTL_DATA_DIR/models."; return 1; }
        if (( avail < need + room )); then
            note "The weights need $(( (need + 1073741823) / 1073741824 )) GiB more, plus $(( room / 1073741824 )) GiB of room, but $XOLOTL_DATA_DIR has $(( avail / 1073741824 )) GiB free."
            note "Grow the CT's disk (pct resize <CT_ID> rootfs +<N>G on the PVE host) and rerun."
            return 1
        fi
    fi
    local entry etype epath esize ehash eurl parts
    for entry in "${plan[@]}"; do
        read -r etype epath esize ehash eurl <<< "$entry"
        if [[ $etype == join ]]; then
            parts=$(awk -v p="$epath" '$1 == p { print $2, $3, $4 }' <<< "$joined_parts")
            fetch_joined "$epath" "$esize" "$ehash" "$parts"
        else
            fetch_file "$epath" "$esize" "$ehash" "$eurl"
        fi
    done
    # The Engram index comes from the verified shards' own headers. The script
    # is read from stdin: the deploy directory is root-only.
    local -a shards=()
    mapfile -t shards < <(awk '$1 == "file" && $2 ~ /^'"$ENGRAM_SUBDIR"'\// { sub(/^.*\//, "", $2); print $2 }' <<< "$rows")
    as_service python3 -I - "$(engram_dir)" "${shards[@]}" < "$source_dir/engram-index.py" ||
        { note 'Could not index the Engram shards.'; return 1; }
    as_service mkdir -p -- "$XOLOTL_DATA_DIR/cache/dense-requant"
    printf 'The DeepSeek-V4.1-Flash-1017 V4 weights are installed.\n'
}

# Serialize real runs before reading saved settings. Keep the descriptor open
# for the entire installer; never unlink the lock file while another run may
# be waiting on its inode. Dry runs do not write or take the lock.
acquire_install_lock() {
    (( dry_run )) && return 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Xolotl LXC.'
    [[ $XOLOTL_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $XOLOTL_ETC_DIR != *..* ]] || die 'Invalid XOLOTL_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$XOLOTL_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another Xolotl installer is already running (or a process it started still holds the lock).'
}

# A rename is durable only after its containing directory has been flushed.
# In save_settings this also orders settings publication before the fingerprint.
publish_record() {
    local temporary=$1 destination=$2
    mv -fT -- "$temporary" "$destination" || return 1
    sync -- "${destination%/*}"
}

# Stage a complete, private record beside its destination. Only rename it
# after the writer succeeds, so a failed write cannot truncate a good record.
stage_record() {
    local destination=$1 temporary
    shift
    # A run killed while staging leaves its mktemp file behind (an api-key one
    # holds the key); drop such leftovers before staging a new one.
    rm -f -- "$destination".?????? || return 1
    temporary=$(mktemp "$destination.XXXXXX") || return 1
    # Flush the contents before the caller renames the file into place, so a
    # power loss cannot leave the new name pointing at an empty file.
    if ! "$@" > "$temporary" || ! sync -- "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    printf '%s\n' "$temporary"
}

# write_pending: record the settings a fresh (or resumed) install runs with
# before it changes anything, so an interrupted first install resumes with
# them instead of the defaults. save_settings removes it.
write_pending() {
    (( dry_run )) && return 0
    install -d -m 0700 "$XOLOTL_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$XOLOTL_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$XOLOTL_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$XOLOTL_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$XOLOTL_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$XOLOTL_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$XOLOTL_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$XOLOTL_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    rm -f -- "$XOLOTL_ETC_DIR/pending-env" || return 1
    sync -- "$XOLOTL_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$XOLOTL_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$XOLOTL_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $XOLOTL_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$XOLOTL_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$XOLOTL_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$XOLOTL_ETC_DIR/api-key"
    sync -- "$XOLOTL_ETC_DIR/api-key" "$XOLOTL_ETC_DIR" || return 1
    api_key=$(< "$XOLOTL_ETC_DIR/api-key")
}

config_file() { printf '%s/xolotl-ds41.json\n' "$XOLOTL_CONFIG_DIR"; }

# The installed config, unit and environment are what this run would write?
config_current() {
    [[ -f $(config_file) && $(server_config) == "$(< "$(config_file)")" ]] &&
        [[ -f $XOLOTL_ETC_DIR/xolotl.env && $(start_env) == "$(< "$XOLOTL_ETC_DIR/xolotl.env")" ]]
}

# Unchanged since the last successful install or upgrade, and serving?
nothing_to_do() {
    [[ -f $XOLOTL_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$XOLOTL_ETC_DIR/installed-settings")" ]] &&
        config_current &&
        cmp -s "$source_dir/xolotl.service" "$UNIT_DIR/xolotl.service" &&
        systemctl is-active --quiet xolotl.service &&
        probe_health
}

# write_unit: the server config (with the key: root and the xolotl group may
# read it, nobody may change it but root), the unit's environment and the unit.
write_unit() {
    local temporary
    install -d -o root -g "$SERVICE_USER" -m 0750 "$XOLOTL_CONFIG_DIR"
    temporary=$(stage_record "$(config_file)" server_config) || return 1
    chgrp "$SERVICE_USER" "$temporary" && chmod 0640 "$temporary" || { rm -f -- "$temporary"; return 1; }
    publish_record "$temporary" "$(config_file)" || { rm -f -- "$temporary"; return 1; }
    start_env > "$XOLOTL_ETC_DIR/xolotl.env"
    chmod 0644 "$XOLOTL_ETC_DIR/xolotl.env"
    install -m 0644 "$source_dir/xolotl.service" "$UNIT_DIR/xolotl.service"
    systemctl daemon-reload
}

# /health answers while the engine loads; it is ready when it reports the model
# loaded, and /v1/models (with the key) lists it.
probe_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${XOLOTL_PORT}/health" 2>/dev/null |
        XC_NAME=$XOLOTL_MODEL_NAME python3 -c 'import json,os,sys; h=json.load(sys.stdin); sys.exit(0 if h.get("loaded") is True and h.get("model") == os.environ["XC_NAME"] else 1)' \
            >/dev/null 2>&1 &&
    curl -fsS --max-time 5 -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
        "http://127.0.0.1:${XOLOTL_PORT}/v1/models" 2>/dev/null |
        XC_NAME=$XOLOTL_MODEL_NAME python3 -c 'import json,os,sys; ids=[m.get("id") for m in json.load(sys.stdin).get("data") or []]; sys.exit(0 if os.environ["XC_NAME"] in ids else 1)' \
            >/dev/null 2>&1
}

wait_ready() {
    local deadline=$(( SECONDS + XOLOTL_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        probe_health && return 0
        if systemctl is-failed --quiet xolotl.service; then
            note "xolotl.service failed; see journalctl -u xolotl."
            return 1
        fi
        sleep 5
    done
    note "Xolotl has not answered on port $XOLOTL_PORT within ${XOLOTL_READY_TIMEOUT}s; see journalctl -u xolotl."
    return 1
}

ensure_service_user() {
    local node group
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$XOLOTL_DATA_DIR" \
            --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    # GPU access: join the group that owns each passed-through node. Root's
    # group is refused: membership in it would grant far more than the GPU.
    # shellcheck disable=SC2086  # GPU_NODES is a glob list by design
    for node in $GPU_NODES; do
        [[ -e $node ]] || continue
        group=$(stat -c %G "$node")
        [[ $group != root ]] ||
            die "$node belongs to group root inside the CT. On the PVE host give the device a non-root group, e.g. pct set <CT_ID> --devN path=$node,gid=44,mode=0660 (44 is \"video\"), restart the CT and run this again."
        usermod -aG "$group" "$SERVICE_USER"
    done
}

install_cuda_toolkit() {
    if (( dry_run )); then
        printf '+ bash cuda-toolkit.sh (CUDA %s toolkit, user space only)\n' "$XOLOTL_CUDA_VERSION"
        return 0
    fi
    CUDA_VERSION="$XOLOTL_CUDA_VERSION" CUDA_NVCC="$XOLOTL_NVCC" bash "$source_dir/cuda-toolkit.sh"
}

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $XOLOTL_DIR/.git && -f $UNIT_DIR/xolotl.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 python3-venv python3-pip build-essential
    install_cuda_toolkit
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s\n' "$SERVICE_USER" "$GPU_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$XOLOTL_URL" "$(fetch_spec)" "$XOLOTL_DIR" "$SERVICE_USER"
        printf '+ check the checkout: required files, CMake options and engine flags\n'
        printf '+ .venv: pip install -r requirements.txt; bash tools/xolotl/fetch-llama.sh\n'
        printf '+ cmake %s\n' "$(cmake_args | tr '\n' ' ' | sed 's/ARCHITECTURES=auto /ARCHITECTURES=<GPU 0 compute capability> /')"
        printf '+ cmake --build build-xolotl --target ds41_generate\n'
        printf '+ download and verify xolotl-weights.txt into %s/models (about 372 GB; joined parts are appended one at a time)\n' "$XOLOTL_DATA_DIR"
        printf '+ index the Engram shards (engram-index.py)\n'
        printf '+ write %s (the server config, with the key [redacted]), %s/xolotl.env and %s/xolotl.service\n' "$(config_file)" "$XOLOTL_ETC_DIR" "$UNIT_DIR"
        run systemctl enable xolotl.service
        run systemctl restart xolotl.service
        printf '+ wait for /health loaded=true and /v1/models to list %s (up to %ss)\n' "$XOLOTL_MODEL_NAME" "$XOLOTL_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$XOLOTL_DATA_DIR"
    if [[ -d $XOLOTL_DIR/.git ]]; then
        verify_source_origin
        chown -R "$SERVICE_USER:$SERVICE_USER" "$XOLOTL_DIR"
        printf 'Resuming the incomplete Xolotl checkout at %s.\n' "$XOLOTL_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$XOLOTL_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $XOLOTL_URL $(fetch_spec)."
    checkout_local "$target"
    # The engine is built before the long download, so a checkout that does
    # not build fails in minutes rather than after hours.
    build_engine || die 'Building the Xolotl engine failed (see above).'
    install_weights || die 'Installing the weights failed (see above); rerun to resume.'
    write_unit
    systemctl enable xolotl.service
    systemctl restart xolotl.service
    wait_ready || die 'Xolotl did not become ready.'
    save_settings
}

# Check out COMMIT (already local) and bring the service up on it. Runs in a
# subshell with errexit, so any failure returns non-zero to the caller.
apply_checkout() {
    set -e
    checkout_local "$1"
    build_engine
    write_unit
    systemctl restart xolotl.service
    wait_ready
}

# Keep a complete runnable checkout (venv, llama.cpp, engine build) at its
# original absolute path on rollback, with the unit, its environment and the
# server config. Models in the data directory are not copied. Stop the service
# before taking this snapshot so it forms one consistent state.
snapshot_runtime() {
    install -d -m 0700 "$XOLOTL_STATE_DIR"
    (umask 077
     tar -C "$XOLOTL_DIR" --exclude='./.git' -cpf "$XOLOTL_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$XOLOTL_STATE_DIR/rollback-runtime.tar.new" "$XOLOTL_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$XOLOTL_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/xolotl.service" "$XOLOTL_STATE_DIR/rollback.service" || return 1
    cp -p -- "$XOLOTL_ETC_DIR/xolotl.env" "$XOLOTL_STATE_DIR/rollback.env" || return 1
    cp -p -- "$(config_file)" "$XOLOTL_STATE_DIR/rollback.json"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    rm -f -- "$XOLOTL_STATE_DIR/rollback-runtime.tar" "$XOLOTL_STATE_DIR/rollback-runtime.tar.new" \
        "$XOLOTL_STATE_DIR/rollback.service" "$XOLOTL_STATE_DIR/rollback.env" "$XOLOTL_STATE_DIR/rollback.json"
}

# restore_probe_settings: the port and model id from the fingerprint, for
# installs whose installed-env is missing.
restore_probe_settings() {
    local port name
    port=$(sed -n 's/^port=//p' "$XOLOTL_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then XOLOTL_PORT=$port; fi
    name=$(sed -n 's/^model_name=//p' "$XOLOTL_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $name =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then XOLOTL_MODEL_NAME=$name; fi
}

# No build, pip, compiler or download is invoked on this path. The caller has
# set the settings the previous runtime ran with (wait_ready uses its port).
restore_runtime() {
    set -e
    [[ $XOLOTL_DIR != / && -d $XOLOTL_DIR/.git && -s $XOLOTL_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$XOLOTL_DIR" reset -q --hard "$1"
    find "$XOLOTL_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$XOLOTL_DIR" -xpf "$XOLOTL_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$XOLOTL_STATE_DIR/rollback.service" "$UNIT_DIR/xolotl.service"
    cp -p -- "$XOLOTL_STATE_DIR/rollback.env" "$XOLOTL_ETC_DIR/xolotl.env"
    cp -p -- "$XOLOTL_STATE_DIR/rollback.json" "$(config_file)"
    systemctl daemon-reload
    systemctl restart xolotl.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$XOLOTL_URL" "$(fetch_spec)"
        printf '+ verify (or resume downloading) the weights while the service keeps running\n'
        printf '+ same commit, settings, config and unit, and /health loaded: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop xolotl.service; snapshot; checkout; rebuild ds41_generate; restart; wait for /health loaded=true\n'
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout, unit, environment and config without building or downloading (%s/rollback-runtime.tar, removed afterwards)\n' "$XOLOTL_STATE_DIR"
        return 0
    fi
    [[ -d $XOLOTL_DIR/.git && -f $UNIT_DIR/xolotl.service ]] ||
        die "No Xolotl installation at $XOLOTL_DIR; run without --upgrade first."
    verify_source_origin
    install_cuda_toolkit
    ensure_api_key
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$XOLOTL_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$XOLOTL_DIR" update-ref refs/xolotl/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $XOLOTL_URL $(fetch_spec); Xolotl was not stopped or changed."
    install_weights ||
        die "The weights could not be verified or completed; Xolotl was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching fingerprint without installed-env migrates its records.
        if [[ ! -f $XOLOTL_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        printf 'Xolotl is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Xolotl %s (settings, config, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Xolotl from %s to %s.\n' "$previous" "$target"
    fi
    systemctl stop xolotl.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$XOLOTL_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart xolotl.service; wait_ready) ||
            die 'Snapshot failed and the previous service did not become ready.'
        die 'Runtime snapshot failed; the previous service is running again.'
    fi
    set +e
    ( apply_checkout "$target" )
    rc=$?
    set -e
    if (( rc == 0 )); then
        save_settings
        clear_snapshot
        printf 'Xolotl is running %s.\n' "$(git_root rev-parse HEAD)"
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    systemctl stop xolotl.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port and model id otherwise). wait_ready
    # checks the restored service on that port.
    if load_settings "$XOLOTL_ETC_DIR/installed-env"; then
        note "Restoring the settings it last ran with: $(settings_env | tr '\n' ' ')"
    else
        restore_probe_settings
        note 'No record of the previous settings; restoring the complete runtime snapshot.'
    fi
    set +e
    ( restore_runtime "$previous" )
    rc=$?
    set -e
    (( rc == 0 )) || die "Rollback to $previous failed too; inspect journalctl -u xolotl and $XOLOTL_DIR; the snapshot is kept in $XOLOTL_STATE_DIR."
    clear_snapshot
    die "Upgrade failed; Xolotl is running $previous again."
}

dry_run=0
mode=install
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --upgrade) mode=upgrade ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
acquire_install_lock
saved_settings
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing $source_dir/upstream-commit.txt"
default_commit=$(< "$source_dir/upstream-commit.txt")
[[ $default_commit =~ ^[0-9a-f]{40}$ ]] || die 'Invalid upstream-commit.txt.'
if [[ -z ${XOLOTL_REF:-} && -z ${XOLOTL_COMMIT:-} ]]; then XOLOTL_COMMIT=$default_commit; fi
XOLOTL_REF=${XOLOTL_REF:-main}
XOLOTL_COMMIT=${XOLOTL_COMMIT:-}
XOLOTL_CUDA_VERSION=${XOLOTL_CUDA_VERSION:-13.0}
XOLOTL_NVCC=${XOLOTL_NVCC:-/usr/local/cuda-$XOLOTL_CUDA_VERSION/bin/nvcc}
XOLOTL_CUDA_ARCH=${XOLOTL_CUDA_ARCH:-auto}
XOLOTL_PORT=${XOLOTL_PORT:-8080}
XOLOTL_CONTEXT=${XOLOTL_CONTEXT:-131072}
XOLOTL_ARENA_GIB=${XOLOTL_ARENA_GIB:-60}
XOLOTL_DSPARK=${XOLOTL_DSPARK:-true}
XOLOTL_MODEL_NAME=${XOLOTL_MODEL_NAME:-deepseek-v4.1-flash}
XOLOTL_READY_TIMEOUT=${XOLOTL_READY_TIMEOUT:-1800}
[[ $XOLOTL_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $XOLOTL_REF != HEAD && $XOLOTL_REF != *..* ]] || die 'Invalid XOLOTL_REF.'
[[ -z $XOLOTL_COMMIT || $XOLOTL_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid XOLOTL_COMMIT.'
validate_settings
[[ $XOLOTL_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid XOLOTL_READY_TIMEOUT.'
for path_var in XOLOTL_DIR XOLOTL_DATA_DIR XOLOTL_ETC_DIR XOLOTL_CONFIG_DIR XOLOTL_STATE_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'

for file in xolotl.service cuda-toolkit.sh xolotl-weights.txt engram-index.py upstream-commit.txt; do
    [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file"
done
weight_rows "$source_dir/xolotl-weights.txt" >/dev/null || exit 1
# Every path below is absolute. The service account runs commands from here,
# not from the root-only deploy directory the installer was started in.
cd /
api_key='[generated inside CT]'
if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Xolotl LXC.'
    if [[ -e $XOLOTL_DIR && ! -d $XOLOTL_DIR/.git ]] && [[ -n $(ls -A "$XOLOTL_DIR" 2>/dev/null) ]]; then
        die "$XOLOTL_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    # Before anything is installed or stopped: is the requested toolkit already
    # installed at XOLOTL_NVCC, or can this distro's NVIDIA repository provide it?
    CUDA_VERSION="$XOLOTL_CUDA_VERSION" CUDA_NVCC="$XOLOTL_NVCC" bash "$source_dir/cuda-toolkit.sh" --check ||
        die "CUDA $XOLOTL_CUDA_VERSION is not available for this CT's distribution (see above)."
    command -v nvidia-smi >/dev/null || die 'nvidia-smi is missing; install host-matched guest NVIDIA userspace first.'
    nvidia-smi -L || die 'NVIDIA GPU is not accessible inside the CT.'
    vram_mib=$(gpu0_vram_mib) ||
        die 'Cannot read GPU 0 VRAM with nvidia-smi; check the passed-through GPU before installing weights.'
    (( vram_mib >= 16000 )) ||
        die "GPU 0 has ${vram_mib} MiB VRAM; Xolotl's DeepSeek-V4.1 engine needs a 16 GB card or larger. No weights were downloaded."
    if [[ $XOLOTL_CUDA_ARCH == auto ]]; then
        XOLOTL_CUDA_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader -i 0 | compute_cap_arch) ||
            die 'Cannot read GPU 0'\''s compute capability; set XOLOTL_CUDA_ARCH (e.g. 89 for an RTX 40 card).'
        note "GPU 0 has compute capability $XOLOTL_CUDA_ARCH."
    fi
    (( XOLOTL_CUDA_ARCH >= 75 )) ||
        die "GPU 0 has compute capability $XOLOTL_CUDA_ARCH; Xolotl's DeepSeek-V4.1 engine needs 7.5 or newer (RTX 20 series and later)."
    # Xolotl's RTX 50 engines built with CUDA 12.8 crashed on long prompts.
    if (( XOLOTL_CUDA_ARCH >= 120 )) && ! [[ $XOLOTL_CUDA_VERSION =~ ^1[3-9]\. ]]; then
        die "Compute capability $XOLOTL_CUDA_ARCH (RTX 50) needs XOLOTL_CUDA_VERSION=13.0 or newer, not $XOLOTL_CUDA_VERSION."
    fi
    # The arena is pinned RAM: more than the CT has fails at load, after hours.
    mem_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO" 2>/dev/null || true)
    if [[ $mem_kib =~ ^[0-9]+$ ]] && (( XOLOTL_ARENA_GIB + 16 > mem_kib / 1048576 )); then
        die "XOLOTL_ARENA_GIB=$XOLOTL_ARENA_GIB needs at least $(( XOLOTL_ARENA_GIB + 16 )) GiB of RAM in the CT; it has $(( mem_kib / 1048576 )) GiB. Lower XOLOTL_ARENA_GIB or raise the CT's memory."
    fi
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Xolotl is configured on TCP %s (model %s); API key: %s/api-key\n' "$XOLOTL_PORT" "$XOLOTL_MODEL_NAME" "$XOLOTL_ETC_DIR"
