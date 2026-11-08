#!/usr/bin/env bash
# Runs inside the dedicated Kindi LXC once its GPU is passed through (and, for
# CUDA, matching NVIDIA user space is installed), or in a CPU-only CT.
#
#   bash install-target.sh             install or update Kindi and start it
#   bash install-target.sh --upgrade   move to KINDI_COMMIT or KINDI_REF (default
#                                      tested commit in upstream-commit.txt);
#                                      roll back to the previous commit
#                                      and runtime on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# Kindi (https://github.com/ahtx/kindi, AGPL-3.0) is an inference engine for
# Prism ML's Ternary-Bonsai-2 models (2B, 4B, 9B, 27B) and AH-Nanbeige4.3-33B
# on small and old NVIDIA cards (Kepler to RTX 50) or on the CPU. This target
# installs it natively, as Kindi's docker/Dockerfile builds its image: the
# CUDA 10.2 toolkit, a standalone Python 3.9 and CuPy 9.6 in a hash-locked
# venv. It downloads the pinned GGUF of the model the card holds (see
# kindi-weights.txt), converts it into Kindi's pack, checks the output against
# llama.cpp's (kindi verify) and serves the OpenAI-compatible API.
set -Eeuo pipefail
# Upgrade signal guard
# upgrade_guard on|rollback|off: a signal (Ctrl-C, a closed SSH session,
# kill) during an upgrade must not stop this script before it can roll back.
# on: a signal is recorded in upgrade_interrupted; the upgrade's subshell dies
# from it, so its failure takes the rollback path. rollback: further signals
# are ignored while the previous release is restored. off: the defaults are
# back. After a hangup the output goes to OSR_INTERRUPT_LOG, so writes to the
# closed terminal cannot fail the rollback.
# Every copy matches targets/upgrade-guard.sh (tests/test-signal-rollback.sh).
upgrade_interrupted=''
upgrade_hangup() {
    upgrade_interrupted=${upgrade_interrupted:-129}
    exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
}
upgrade_guard() {
    case $1 in
        on)
            upgrade_interrupted=''
            trap 'upgrade_interrupted=${upgrade_interrupted:-130}' INT
            trap 'upgrade_interrupted=${upgrade_interrupted:-143}' TERM
            trap upgrade_hangup HUP ;;
        rollback) trap '' INT TERM HUP ;;
        off) trap - INT TERM HUP ;;
    esac
}
# End upgrade signal guard.

KINDI_URL=https://github.com/ahtx/kindi.git
# Paths are overridable for tests only; the unit file uses the defaults.
KINDI_DIR=${KINDI_DIR:-/opt/kindi}
KINDI_DATA_DIR=${KINDI_DATA_DIR:-/var/lib/kindi}
KINDI_ETC_DIR=${KINDI_ETC_DIR:-/etc/kindi-target}
# The server's config file (it holds the API key): root may change it, the
# kindi group may only read it. Kept apart from the root-only records above.
KINDI_CONFIG_DIR=${KINDI_CONFIG_DIR:-/etc/kindi}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
KINDI_STATE_DIR=${KINDI_STATE_DIR:-/var/lib/kindi-target}
# uv (its own venv) and the standalone Pythons it installs; root-owned and
# readable by the service, outside the checkout so a rollback keeps them.
KINDI_RUNTIME_DIR=${KINDI_RUNTIME_DIR:-/opt/kindi-runtime}
CUDA_HOME_DIR=${CUDA_HOME_DIR:-/usr/local/cuda-10.2}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-kindi}
# GPU device nodes whose group the service user joins (glob-expanded).
GPU_NODES=${GPU_NODES:-}
MEMINFO=${MEMINFO:-/proc/meminfo}
CPUINFO=${CPUINFO:-/proc/cpuinfo}
# The distro's python3, which builds uv's own venv.
BOOT_PYTHON=${BOOT_PYTHON:-/usr/bin/python3}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh [--dry-run] [--upgrade]
Installs Kindi from https://github.com/ahtx/kindi.git as the "kindi" service
account: the CUDA 10.2 toolkit (KINDI_BACKEND=cuda) or nothing (cpu), a
standalone Python 3.9 and Kindi's hash-locked venv; downloads the pinned GGUF
of KINDI_MODEL (see kindi-weights.txt), converts it into Kindi's pack, checks
it against llama.cpp's reference output (kindi verify) and starts the
hardened kindi systemd service. Re-running fetches KINDI_COMMIT or KINDI_REF
before stopping anything: when the commit, settings, weights and unit are
unchanged and Kindi is healthy it does nothing; otherwise it rebuilds and
restarts, rolling back to the previous commit and runtime on failure.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or installed-settings for older installs); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment: by default, use the tested commit in upstream-commit.txt.
KINDI_REF=<branch or tag, e.g. main> or KINDI_COMMIT=<full SHA-1 pin>
overrides that default (KINDI_COMMIT wins if both are set).
KINDI_BACKEND=auto (cuda when an NVIDIA GPU is passed in, else cpu),
KINDI_MODEL=auto (the largest Ternary-Bonsai-2 model the card holds: bonsai-2b,
bonsai-4b, bonsai-9b or bonsai-27b; the CPU gets bonsai-2b; nanbeige-33b only
when asked for), KINDI_PROFILE=auto (Kindi's engine settings for the card: tc,
pascal8, p100, kepler, maxwell, nanbeige or cpu), KINDI_PORT=8093,
KINDI_CONTEXT=auto (the profile's: 24576 to 131072 tokens; the engine fits it
to the free card memory), KINDI_HEAD=exact (fast: the shortlist output head,
about 15% faster, not token-exact), KINDI_SPEC=auto (the 27B on an RTX 30 or
newer drafts with the 2B; off), KINDI_THREADS=auto (CPU engine: the CT's
cores), KINDI_MODEL_NAME=auto (the API's model id: bonsai2-2b ... bonsai2-27b,
nanbeige-33b-iq3), KINDI_VERIFY=true, KINDI_PYTHON_VERSION=3.9.25,
KINDI_READY_TIMEOUT=1800 (seconds).
USAGE
}

# Install helpers (sourced by test-install.sh) ---------------------------------

# The files a checkout must carry, and what the target relies on in them.
REQUIRED_FILES=(kindi/__main__.py kindi/server.py kindi/config.py kindi/convert.py kindi/verify.py
    kindi/catalog.py kindi/cpu.py kindi/kcpu.c docker/Dockerfile)
# Config keys the target writes into kindi.conf (Kindi refuses unknown keys).
REQUIRED_CONFIG_KEYS=(pack state_dir host port api_key model_name ctx head)
REQUIRED_COMMANDS=(convert verify serve fast-head)
# The engine settings engine_env writes: Kindi reads each one itself, or as
# a config key through KINDI_<KEY>.
REQUIRED_ENGINE_VARS=(KINDI_DEVICE KINDI_CARDS KINDI_BLOCKING_SYNC KINDI_DENSE_SPACING KINDI_TC KINDI_FD
    KINDI_ATT_TC KINDI_CKPT_VRAM KINDI_SPEC KINDI_SPEC_K KINDI_SPEC_PACK KINDI_SPEC_WINDOW KINDI_TC_TMAX
    KINDI_MEM_RESERVE_MB KINDI_CPU_CACHE)
REQUIRED_ENGINE_KEYS=(repeat_stop checkpoint_budget_mb park_max prefix_max max_tokens)
# Kindi's own pins (docker/Dockerfile): requirements-cuda.in must name the same.
REQUIRED_PINS=("numpy==1.19.5" "fastrlock==0.8.3" "cupy-cuda102==9.6.0" "fastapi==0.79.1" "uvicorn==0.16.0"
    "pydantic==1.9.2")

# validate_checkout DIR: refuse a checkout this installer does not know how to
# set up or serve, before anything is built or stopped.
validate_checkout() {
    local dir=$1 file key command var pin
    local -a missing=()
    for file in "${REQUIRED_FILES[@]}"; do
        [[ -f $dir/$file ]] || missing+=("$file")
    done
    (( ${#missing[@]} == 0 )) ||
        { note "This Kindi checkout lacks: ${missing[*]}. Pin a compatible KINDI_COMMIT."; return 1; }
    for key in "${REQUIRED_CONFIG_KEYS[@]}" "${REQUIRED_ENGINE_KEYS[@]}"; do
        grep -qE "^[[:space:]]*\"$key\":" "$dir/kindi/config.py" || missing+=("config key $key")
    done
    for command in "${REQUIRED_COMMANDS[@]}"; do
        grep -qF "add_parser(\"$command\"" "$dir/kindi/__main__.py" || missing+=("kindi $command")
    done
    for var in "${REQUIRED_ENGINE_VARS[@]}"; do
        grep -rqF -- "\"$var\"" "$dir/kindi" || missing+=("$var")
    done
    grep -qF '"owned_by": "kindi"' "$dir/kindi/server.py" || missing+=('/v1/models owned_by kindi')
    grep -qF '"kindi": __version__' "$dir/kindi/server.py" || missing+=('/health kindi version')
    grep -qF '"context_length": K.eng.ctx' "$dir/kindi/server.py" || missing+=('/v1/models context_length')
    grep -qE '^PACK_FORMAT = [0-9]+$' "$dir/kindi/convert.py" || missing+=('PACK_FORMAT')
    for pin in "${REQUIRED_PINS[@]}"; do
        grep -qF -- "\"$pin\"" "$dir/docker/Dockerfile" || missing+=("Dockerfile pin $pin")
    done
    (( ${#missing[@]} == 0 )) ||
        { note "This Kindi checkout does not provide: ${missing[*]}. Pin a compatible KINDI_COMMIT."; return 1; }
}

# pack_format DIR: the pack format of a checkout's converter (PACK_FORMAT).
pack_format() { sed -n 's/^PACK_FORMAT = \([0-9][0-9]*\)$/\1/p' "$1/kindi/convert.py" | head -n1; }

# The models: id, the API's default model id, the card memory one card needs
# (Kindi's catalog), and whether the CPU engine runs it.
MODEL_IDS=(bonsai-2b bonsai-4b bonsai-9b bonsai-27b nanbeige-33b)
model_field() {
    local spec
    case $1 in
        bonsai-2b) spec='bonsai2-2b|900|cpu|3584' ;;
        bonsai-4b) spec='bonsai2-4b|1900|cpu|3584' ;;
        bonsai-9b) spec='bonsai2-9b|3800|cpu|5632' ;;
        bonsai-27b) spec='bonsai2-27b|7600|gpu|13824' ;;
        nanbeige-33b) spec='nanbeige-33b-iq3|16200|gpu|9728' ;;
        *) return 1 ;;
    esac
    local name vram cpu ram
    IFS='|' read -r name vram cpu ram <<< "$spec"
    case $2 in
        name) printf '%s\n' "$name" ;;
        vram) printf '%s\n' "$vram" ;;
        cpu) [[ $cpu == cpu ]] ;;
        ram) printf '%s\n' "$ram" ;;
        *) return 1 ;;
    esac
}

# compute_cap_arch: "8.9" (nvidia-smi --query-gpu=compute_cap) -> 89.
compute_cap_arch() {
    local cap
    cap=$(head -n1 | tr -d '[:space:]')
    [[ $cap =~ ^([0-9]+)\.([0-9])$ ]] || return 1
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# kepler_by_name NAME: the 470 driver Kepler cards need does not report the
# compute capability, so they are known by name (as Kindi's installer does).
kepler_by_name() {
    [[ $1 =~ (Quadro\ K[0-9]+|Tesla\ K[0-9]+|GeForce\ GTX?\ ?(6[0-9]{2}|7[0-9]{2})|NVS\ 5[0-9]{2}) ]] &&
        [[ $1 != *"GTX 750"* && $1 != *"GTX 745"* ]]
}

# profile_for ARCH VRAM_MIB: Kindi's engine settings for one card (its
# install.sh card_class): tc (sm_80+, 9.5 GB+), pascal8 (sm_61+, 7.5 GB+),
# p100 (sm_60, 12 GB+), kepler (below sm_50) or maxwell (the rest).
profile_for() {
    local arch=$1 vram=$2
    if (( arch >= 80 && vram >= 9500 )); then echo tc
    elif (( arch >= 61 && vram >= 7500 )); then echo pascal8
    elif (( arch == 60 && vram >= 12000 )); then echo p100
    elif (( arch < 50 )); then echo kepler
    else echo maxwell; fi
}

# auto_model PROFILE VRAM_MIB: the best model of Kindi's list for the card
# (its install.sh card_models, first choice).
auto_model() {
    local profile=$1 vram=${2:-0}
    case $profile in
        cpu) echo bonsai-2b ;;
        tc|pascal8|p100) echo bonsai-27b ;;
        kepler)
            if (( vram >= 11000 )); then echo bonsai-27b
            elif (( vram >= 3800 )); then echo bonsai-9b
            elif (( vram >= 1900 )); then echo bonsai-4b
            else echo bonsai-2b; fi ;;
        *)
            if (( vram >= 3800 )); then echo bonsai-9b
            elif (( vram >= 1900 )); then echo bonsai-4b
            else echo bonsai-2b; fi ;;
    esac
}

# auto_context PROFILE VRAM_MIB MODEL: the context Kindi's installer asks for
# with that profile (its profile_of); the engine fits it to the free memory.
auto_context() {
    local profile=$1 vram=${2:-0} model=$3
    case $profile in
        nanbeige) echo 16384 ;;
        tc) echo 131072 ;;
        pascal8|p100) echo 65536 ;;
        kepler)
            if [[ $model == bonsai-4b ]] && (( vram < 2500 )); then echo 23808
            elif (( vram >= 1500 )); then echo 65536
            else echo 24576; fi ;;
        *) echo 24576 ;;
    esac
}

# spec_active: the 27B on a tensor-core card drafts with the 2B (Kindi 0.4.0's
# speculative decoding; docs/MTP.md).
spec_active() { [[ $KINDI_PROFILE == tc && $KINDI_MODEL == bonsai-27b && $KINDI_SPEC == auto ]]; }
# needed_models: the models this install downloads and converts.
needed_models() {
    printf '%s\n' "$KINDI_MODEL"
    if spec_active; then printf '%s\n' bonsai-2b; fi
}

# weight_rows FILE MODEL...: the rows of those models, checked, as
# "model file size hash url" lines.
weight_rows() {
    local file=$1 model name size hash url extra found=0
    shift
    while read -r model name size hash url extra; do
        [[ -n $model && $model != \#* ]] || continue
        if [[ ! $model =~ ^[a-z0-9][a-z0-9-]*$ || ! $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.gguf$ ||
              ! $size =~ ^[1-9][0-9]{0,14}$ || ! $hash =~ ^sha256:[0-9a-f]{64}$ || -n $extra ||
              ! $url =~ ^https://huggingface\.co/[^[:space:]\'\"\`\$\\]+/resolve/[0-9a-f]{40}/[^[:space:]\'\"\`\$\\]+$ ||
              ${url##*/} != "$name" ]]; then
            printf 'Error: malformed row in %s: %s %s\n' "$file" "$model" "$name" >&2
            return 1
        fi
        [[ " $* " == *" $model "* ]] || continue
        printf '%s %s %s %s %s\n' "$model" "$name" "$size" "$hash" "$url"
        found=$((found + 1))
    done < "$file"
    (( found == $# )) || { printf 'Error: %s does not list every model of: %s\n' "$file" "$*" >&2; return 1; }
}

# Paths of the installed weights and packs.
model_file() { awk -v m="$1" '$1 == m { print $2 }' "$source_dir/kindi-weights.txt"; }
model_path() { printf '%s/models/%s\n' "$KINDI_DATA_DIR" "$(model_file "$1")"; }
# pack_dir MODEL: one pack per pack format, so a converter change after an
# upgrade writes a new pack and a rollback still has the old one.
pack_dir() { printf '%s/packs/%s-f%s\n' "$KINDI_DATA_DIR" "$1" "$KINDI_PACK_FORMAT"; }

# The settings that decide how Kindi is installed and served. save_settings
# records them after every successful install or upgrade, so a failed upgrade
# can roll back to what last worked.
SETTING_KEYS=(KINDI_BACKEND KINDI_MODEL KINDI_PROFILE KINDI_PORT KINDI_CONTEXT KINDI_HEAD KINDI_SPEC KINDI_THREADS
    KINDI_MODEL_NAME KINDI_PYTHON_VERSION)

# validate_settings: die unless every setting has a value this script accepts.
validate_settings() {
    [[ $KINDI_BACKEND =~ ^(cuda|cpu)$ ]] || die 'KINDI_BACKEND must be cuda or cpu.'
    [[ $KINDI_MODEL == auto || " ${MODEL_IDS[*]} " == *" $KINDI_MODEL "* ]] ||
        die "KINDI_MODEL must be auto or one of: ${MODEL_IDS[*]}."
    [[ $KINDI_PROFILE =~ ^(auto|tc|pascal8|p100|kepler|maxwell|nanbeige|cpu)$ ]] ||
        die 'KINDI_PROFILE must be auto, tc, pascal8, p100, kepler, maxwell, nanbeige or cpu.'
    [[ $KINDI_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( KINDI_PORT <= 65535 )) || die 'Invalid KINDI_PORT.'
    [[ $KINDI_CONTEXT == auto || ( $KINDI_CONTEXT =~ ^[1-9][0-9]{3,5}$ && $KINDI_CONTEXT -ge 1024 &&
       $KINDI_CONTEXT -le 262144 ) ]] || die 'KINDI_CONTEXT must be auto or 1024..262144 tokens.'
    [[ $KINDI_HEAD =~ ^(exact|fast)$ ]] || die 'KINDI_HEAD must be exact or fast.'
    [[ $KINDI_SPEC =~ ^(auto|off)$ ]] || die 'KINDI_SPEC must be auto or off.'
    [[ $KINDI_THREADS == auto || ( $KINDI_THREADS =~ ^[1-9][0-9]{0,2}$ && $KINDI_THREADS -le 512 ) ]] ||
        die 'KINDI_THREADS must be auto or 1..512.'
    [[ $KINDI_MODEL_NAME == auto || $KINDI_MODEL_NAME =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
        die 'Invalid KINDI_MODEL_NAME (lowercase letters, digits, ., _ and -).'
    [[ $KINDI_PYTHON_VERSION =~ ^3\.9\.[0-9]{1,2}$ ]] ||
        die 'KINDI_PYTHON_VERSION must be a Python 3.9 release (CuPy 9.6 supports 3.6 to 3.9), e.g. 3.9.25.'
    if [[ $KINDI_BACKEND == cpu ]]; then
        [[ $KINDI_PROFILE == auto || $KINDI_PROFILE == cpu ]] || die 'KINDI_BACKEND=cpu runs the cpu profile only.'
        [[ $KINDI_MODEL == auto ]] || model_field "$KINDI_MODEL" cpu ||
            die "Kindi's CPU engine runs bonsai-2b, bonsai-4b and bonsai-9b, not $KINDI_MODEL."
    else
        [[ $KINDI_PROFILE != cpu ]] || die 'The cpu profile needs KINDI_BACKEND=cpu.'
        [[ $KINDI_THREADS == auto ]] || die 'KINDI_THREADS is for the CPU engine (KINDI_BACKEND=cpu).'
    fi
    if [[ $KINDI_MODEL == nanbeige-33b ]]; then
        [[ $KINDI_PROFILE == auto || $KINDI_PROFILE == nanbeige ]] || die 'nanbeige-33b runs the nanbeige profile.'
        [[ $KINDI_HEAD == exact ]] || die 'KINDI_HEAD=fast is for the Ternary-Bonsai-2 models.'
    elif [[ $KINDI_PROFILE == nanbeige ]]; then
        die 'The nanbeige profile is for KINDI_MODEL=nanbeige-33b.'
    fi
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
        [[ $line =~ ^(KINDI_[A-Z_]+)=(.*)$ ]] || continue
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
    sed -n -e 's/^backend=/KINDI_BACKEND=/p' \
        -e 's/^model=/KINDI_MODEL=/p' \
        -e 's/^profile=/KINDI_PROFILE=/p' \
        -e 's/^port=/KINDI_PORT=/p' \
        -e 's/^context=/KINDI_CONTEXT=/p' \
        -e 's/^head=/KINDI_HEAD=/p' \
        -e 's/^spec=/KINDI_SPEC=/p' \
        -e 's/^threads=/KINDI_THREADS=/p' \
        -e 's/^model_name=/KINDI_MODEL_NAME=/p' \
        -e 's/^python=/KINDI_PYTHON_VERSION=/p' "$1"
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
    if [[ -e $KINDI_ETC_DIR/installed-env ]]; then
        load_settings "$KINDI_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $KINDI_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $KINDI_ETC_DIR/installed-settings || -L $KINDI_ETC_DIR/installed-settings ||
            -e $KINDI_ETC_DIR/pending-env || -L $KINDI_ETC_DIR/pending-env ||
            -e $KINDI_DIR/.git || -L $KINDI_DIR/.git ||
            -e $UNIT_DIR/kindi.service || -L $UNIT_DIR/kindi.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $KINDI_ETC_DIR/installed-settings && -r $KINDI_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$KINDI_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $KINDI_ETC_DIR/installed-settings (installed-env is missing)."
        elif [[ ! -e $KINDI_ETC_DIR/installed-settings && ! -L $KINDI_ETC_DIR/installed-settings &&
                -f $KINDI_ETC_DIR/pending-env && -r $KINDI_ETC_DIR/pending-env ]] &&
                load_settings "$KINDI_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($KINDI_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $KINDI_ETC_DIR/installed-settings || -L $KINDI_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $KINDI_ETC_DIR/installed-settings"
            else
                missing="Found an existing Kindi installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $KINDI_ETC_DIR)"
            fi
            for key in "${SETTING_KEYS[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${SETTING_KEYS[*]} explicitly, or restore a record."
            done
        fi
    fi
    # A changed backend or model is sized for the card again unless supplied.
    if [[ ( -v overrides[KINDI_BACKEND] && ${overrides[KINDI_BACKEND]} != "${KINDI_BACKEND:-}" ) ||
          ( -v overrides[KINDI_MODEL] && ${overrides[KINDI_MODEL]} != "${KINDI_MODEL:-}" ) ]]; then
        [[ -v overrides[KINDI_PROFILE] ]] || KINDI_PROFILE=auto
        [[ -v overrides[KINDI_CONTEXT] ]] || KINDI_CONTEXT=auto
        [[ -v overrides[KINDI_MODEL_NAME] ]] || KINDI_MODEL_NAME=auto
        if [[ -v overrides[KINDI_BACKEND] && ${overrides[KINDI_BACKEND]} != "${KINDI_BACKEND:-}" ]]; then
            [[ -v overrides[KINDI_MODEL] ]] || KINDI_MODEL=auto
            [[ -v overrides[KINDI_THREADS] ]] || KINDI_THREADS=auto
        fi
    fi
    for key in "${!overrides[@]}"; do printf -v "$key" '%s' "${overrides[$key]}"; done
}

# engine_env: the unit's EnvironmentFile, Kindi's settings for the card's
# profile (its install.sh profile_of, for one server on its own card or CPU).
# No secrets: the key is in the config file.
engine_env() {
    printf '# Written by install-target.sh; do not edit.\n'
    printf 'KINDI_CPU_CACHE=%s/.cache/kindi\n' "$KINDI_DATA_DIR"
    if [[ $KINDI_BACKEND == cpu ]]; then
        printf '%s\n' KINDI_DEVICE=cpu "OMP_NUM_THREADS=$KINDI_THREADS" OMP_PROC_BIND=close OMP_PLACES=cores
        return 0
    fi
    printf '%s\n' "CUDA_PATH=$CUDA_HOME_DIR" "LD_LIBRARY_PATH=$CUDA_HOME_DIR/lib64" CUDA_DEVICE_ORDER=PCI_BUS_ID
    case $KINDI_PROFILE in
        tc)
            printf '%s\n' KINDI_CARDS=1 KINDI_REPEAT_STOP=1 KINDI_CHECKPOINT_BUDGET_MB=1280 KINDI_PARK_MAX=1 \
                KINDI_DENSE_SPACING=2048 KINDI_PREFIX_MAX=2 KINDI_MAX_TOKENS=65536
            if [[ $KINDI_MODEL == bonsai-27b ]]; then
                printf '%s\n' KINDI_TC=1 KINDI_FD=1 KINDI_ATT_TC=1 KINDI_CKPT_VRAM=1 KINDI_TC_TMAX=4 KINDI_MEM_RESERVE_MB=160
                if spec_active; then
                    printf '%s\n' KINDI_SPEC=auto KINDI_SPEC_K=3 "KINDI_SPEC_PACK=$(pack_dir bonsai-2b)" KINDI_SPEC_WINDOW=8192
                fi
            fi ;;
        pascal8|p100) printf '%s\n' KINDI_CARDS=1 KINDI_REPEAT_STOP=1 KINDI_MAX_TOKENS=65536 ;;
        kepler)
            if [[ $KINDI_MODEL == bonsai-27b ]]; then
                printf '%s\n' KINDI_CARDS=1 KINDI_REPEAT_STOP=1 KINDI_MAX_TOKENS=65536
            fi ;;
        nanbeige) printf '%s\n' KINDI_REPEAT_STOP=1 KINDI_MAX_TOKENS=16384 ;;
    esac
    # Blocking sync frees a CPU core but costs 2-3% of the decode: Kindi keeps
    # it for its tensor-core profile only.
    [[ $KINDI_PROFILE == tc ]] || printf 'KINDI_BLOCKING_SYNC=0\n'
}

# server_config [KEY]: the config file the unit's Kindi reads (INI, [kindi]).
# KEY replaces the API key (fingerprints use a placeholder).
server_config() {
    printf '# Written by install-target.sh; do not edit.\n[kindi]\n'
    printf 'pack = %s\nstate_dir = %s/state\n' "$(pack_dir "$KINDI_MODEL")" "$KINDI_DATA_DIR"
    printf 'host = 0.0.0.0\nport = %s\napi_key = %s\n' "$KINDI_PORT" "${1-$api_key}"
    printf 'model_name = %s\nctx = %s\nhead = %s\n' "$KINDI_MODEL_NAME" "$KINDI_CONTEXT" "$KINDI_HEAD"
}
config_file() { printf '%s/kindi.conf\n' "$KINDI_CONFIG_DIR"; }

# settings_fingerprint: what the running service was set up with. A rerun that
# finds the same commit, this fingerprint and the same unit does nothing.
settings_fingerprint() {
    local env_hash config_hash toolkit_hash weights_hash locks_hash
    env_hash=$(engine_env | sha256sum | cut -d' ' -f1) || return 1
    config_hash=$(server_config '[key]' | sha256sum | cut -d' ' -f1) || return 1
    toolkit_hash=$(sha256sum "$source_dir/cuda-toolkit.sh" | cut -d' ' -f1) || return 1
    weights_hash=$(sha256sum "$source_dir/kindi-weights.txt" | cut -d' ' -f1) || return 1
    locks_hash=$(cat "$source_dir/requirements-cpu.lock" "$source_dir/requirements-cuda.lock" "$source_dir/uv.lock" |
        sha256sum | cut -d' ' -f1) || return 1
    printf 'backend=%s\nmodel=%s\nprofile=%s\nport=%s\ncontext=%s\nhead=%s\nspec=%s\nthreads=%s\nmodel_name=%s\npython=%s\nverify=%s\ntoolkit_sha256=%s\nweights_sha256=%s\nlocks_sha256=%s\nenv_sha256=%s\nconfig_sha256=%s\n' \
        "$KINDI_BACKEND" "$KINDI_MODEL" "$KINDI_PROFILE" "$KINDI_PORT" "$KINDI_CONTEXT" "$KINDI_HEAD" \
        "$KINDI_SPEC" "$KINDI_THREADS" "$KINDI_MODEL_NAME" "$KINDI_PYTHON_VERSION" "$KINDI_VERIFY" \
        "$toolkit_hash" "$weights_hash" "$locks_hash" "$env_hash" "$config_hash"
}

# End install helpers. ----------------------------------------------------------

# as_service CMD...: run CMD as the service account. The installer lock's
# descriptor is closed for it, so nothing it leaves running in the background
# (git's detached housekeeping) holds the lock after the installer has exited.
as_service() {
    if [[ -n ${install_lock_fd:-} ]]; then
        runuser -u "$SERVICE_USER" -- env HOME="$KINDI_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$KINDI_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$KINDI_DIR" -C "$KINDI_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$KINDI_URL" ]] || die "Existing $KINDI_DIR origin is not official: $origin"
}

fetch_spec() {
    if [[ -n $KINDI_COMMIT ]]; then printf '%s\n' "$KINDI_COMMIT"; else printf '%s\n' "$KINDI_REF"; fi
}

# Fetch the target into FETCH_HEAD without touching the checkout, and print
# the fetched commit. A fetch by commit works for any commit, not only a
# branch tip.
fetch_target() {
    local fetched
    if [[ ! -d $KINDI_DIR/.git ]]; then
        as_service git init -q "$KINDI_DIR"
        as_service git -C "$KINDI_DIR" remote add origin "$KINDI_URL"
    fi
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$KINDI_DIR" fetch -q --depth 1 origin "$(fetch_spec)" >&2 || return 1
    fetched=$(git_root rev-parse 'FETCH_HEAD^{commit}') || return 1
    if [[ -n $KINDI_COMMIT && ${fetched,,} != "${KINDI_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $KINDI_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$KINDI_DIR" checkout -q --detach "$1"
    printf 'Kindi source commit: %s\n' "$(git_root rev-parse HEAD)"
    KINDI_PACK_FORMAT=$(pack_format "$KINDI_DIR")
}

uv_bin() { printf '%s/uv/bin/uv\n' "$KINDI_RUNTIME_DIR"; }
venv_python() { printf '%s/.venv/bin/python\n' "$KINDI_DIR"; }

# ensure_uv: the pinned uv in its own venv (uv.lock, hash-checked), made by
# root and readable by the service account.
ensure_uv() {
    local want have
    want=$(sed -n 's/^uv==\([^ ]*\) .*/\1/p' "$source_dir/uv.lock" | head -n1)
    have=$("$(uv_bin)" --version 2>/dev/null | awk '{ print $2 }' || true)
    [[ -n $want && $have == "$want" ]] && return 0
    (umask 022
     rm -rf -- "$KINDI_RUNTIME_DIR/uv"
     "$BOOT_PYTHON" -m venv "$KINDI_RUNTIME_DIR/uv" &&
     "$KINDI_RUNTIME_DIR/uv/bin/pip" install --disable-pip-version-check -q --no-deps --require-hashes \
         -r "$source_dir/uv.lock") || return 1
    have=$("$(uv_bin)" --version 2>/dev/null | awk '{ print $2 }' || true)
    [[ $have == "$want" ]] || { note "uv $want did not install (found: ${have:-nothing})."; return 1; }
}

# build_runtime: the standalone Python (root-owned, under KINDI_RUNTIME_DIR)
# and the checkout's venv from the hash lock of the backend, built as the
# service account; then Kindi must import, and on CUDA run a kernel on the GPU.
build_runtime() {
    local python lock check
    ensure_uv || return 1
    # --no-bin: nothing goes into root's ~/.local/bin.
    (umask 022
     UV_PYTHON_INSTALL_DIR="$KINDI_RUNTIME_DIR/python" UV_CACHE_DIR="$KINDI_RUNTIME_DIR/cache" \
         "$(uv_bin)" python install --quiet --no-bin "$KINDI_PYTHON_VERSION") || return 1
    python=$(UV_PYTHON_INSTALL_DIR="$KINDI_RUNTIME_DIR/python" "$(uv_bin)" python find --managed-python \
        "$KINDI_PYTHON_VERSION" 2>/dev/null) || { note "uv installed no Python $KINDI_PYTHON_VERSION."; return 1; }
    # The service account builds the venv, so it reads the lock from its own
    # data directory (the deploy and state directories are root-only).
    lock=$KINDI_DATA_DIR/requirements.lock
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 "$source_dir/requirements-$KINDI_BACKEND.lock" "$lock"
    rm -rf -- "$KINDI_DIR/.venv"
    as_service env UV_CACHE_DIR="$KINDI_DATA_DIR/.cache/uv" "$(uv_bin)" venv --quiet --python "$python" \
        "$KINDI_DIR/.venv" || return 1
    as_service env UV_CACHE_DIR="$KINDI_DATA_DIR/.cache/uv" "$(uv_bin)" pip sync --quiet --require-hashes \
        --no-build --python "$(venv_python)" "$lock" || return 1
    check='import kindi.server, numpy, fastapi, uvicorn; print("ok")'
    if [[ $KINDI_BACKEND == cuda ]]; then
        # A CuPy reduction compiles a kernel with NVRTC and runs it on GPU 0.
        check='import kindi.server, cupy as cp; assert int(cp.arange(4).sum()) == 6; print("ok")'
    fi
    [[ $(as_service env "PYTHONPATH=$KINDI_DIR" "CUDA_PATH=$CUDA_HOME_DIR" "LD_LIBRARY_PATH=$CUDA_HOME_DIR/lib64" \
            "$(venv_python)" -c "$check" 2>&1 | tail -n1) == ok ]] ||
        { note "Kindi's venv does not work on this $KINDI_BACKEND backend (see: $(venv_python) -c '$check')."; return 1; }
}

# kindi CMD...: Kindi's command line as the service account, with the
# engine settings of this install and the CUDA paths (verify, convert, ...).
kindi_cli() {
    local -a env_lines
    mapfile -t env_lines < <(engine_env | grep -v '^#')
    as_service env "${env_lines[@]}" "PYTHONPATH=$KINDI_DIR" KINDI_CONFIG=/nonexistent \
        "$(venv_python)" -m kindi "$@"
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
# The record of weights already verified: "file hash size mtime" lines,
# root-owned, so a rerun need not hash them again.
verified_record() { printf '%s/verified-weights\n' "$KINDI_ETC_DIR"; }
is_verified() {
    local name=$1 hash=$2 file stat
    file=$KINDI_DATA_DIR/models/$name
    as_service test -f "$file" || return 1
    stat=$(as_service stat -c '%s %Y' -- "$file") || return 1
    grep -qxF -- "$name $hash $stat" "$(verified_record)" 2>/dev/null
}
record_weight() {
    local record temporary
    record=$(verified_record)
    temporary=$(mktemp "$record.XXXXXX")
    { grep -v -- "^$1 " "$record" 2>/dev/null || true; printf '%s\n' "$*"; } > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$record"
}
# hash_matches FILE HASH: sha256:<hex>, hashed as the service account, which
# owns the data directory.
hash_matches() {
    local file=$1 hash=$2 actual
    actual=sha256:$(as_service sha256sum -- "$file" | awk '{ print $1 }')
    [[ $actual == "$hash" ]] || { note "$file has SHA-256 ${actual#*:}, not ${hash#*:}."; return 1; }
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
# fetch_file NAME SIZE HASH URL: models/NAME, downloaded unless verified.
fetch_file() {
    local name=$1 size=$2 hash=$3 url=$4 file partial stat
    file=$KINDI_DATA_DIR/models/$name
    partial=$KINDI_DATA_DIR/models/.$name.part
    is_verified "$name" "$hash" && { printf 'Have %s (verified).\n' "$name"; return 0; }
    if as_service test -e "$file"; then
        stat=$(as_service stat -c '%s %Y' -- "$file")
        [[ ${stat%% *} == "$size" ]] || die "$file is ${stat%% *} bytes, not $size. Move it aside to download it again."
        printf 'Checking %s...\n' "$name"
        hash_matches "$file" "$hash" || die "$file does not match kindi-weights.txt. Move it aside to download it again."
        record_weight "$name" "$hash" "$stat"
        return 0
    fi
    download "$url" "$partial" "$size" || exit 1
    printf 'Checking %s...\n' "$name"
    if ! hash_matches "$partial" "$hash"; then
        as_service rm -f -- "$partial"
        die "Checksum mismatch for $name. The download was removed."
    fi
    as_service mv -f -- "$partial" "$file"
    record_weight "$name" "$hash" "$(as_service stat -c '%s %Y' -- "$file")"
    printf 'Installed %s.\n' "$name"
}

# install_weights: the GGUF of every needed model. Files not yet verified are
# checked against Hugging Face (status, size and SHA-256) and the free space
# is compared with what is missing before anything is downloaded; a fully
# verified set needs no network.
install_weights() {
    local rows model name size hash url status linked_size etag need=0 have avail
    local -a plan=() models=()
    mapfile -t models < <(needed_models)
    rows=$(weight_rows "$source_dir/kindi-weights.txt" "${models[@]}") || return 1
    as_service mkdir -p -- "$KINDI_DATA_DIR/models"
    while read -r model name size hash url <&3; do
        plan+=("$name $size $hash $url")
        if is_verified "$name" "$hash" || as_service test -e "$KINDI_DATA_DIR/models/$name"; then continue; fi
        read -r status linked_size etag < <(hf_head "$url")
        case $status in
            2??|3??) ;;
            *) note "$url did not answer (HTTP $status); check the CT's internet access."; return 1 ;;
        esac
        [[ $linked_size == - || $linked_size == "$size" ]] ||
            { note "$name is now $linked_size bytes upstream, not the reviewed $size. Review it and update kindi-weights.txt."; return 1; }
        if [[ $etag != - && $etag != "${hash#sha256:}" ]]; then
            note "Hugging Face reports SHA-256 $etag for $name, not the reviewed ${hash#sha256:}. Review it and update kindi-weights.txt."
            return 1
        fi
        have=$(as_service stat -c %s -- "$KINDI_DATA_DIR/models/.$name.part" 2>/dev/null || echo 0)
        (( have <= size )) || have=0
        need=$(( need + size - have ))
    done 3<<< "$rows"
    if (( need > 0 )); then
        avail=$(df -PB1 -- "$KINDI_DATA_DIR/models" | awk 'NR == 2 { print $4 }')
        [[ $avail =~ ^[0-9]+$ ]] || { note "Cannot read the free space of $KINDI_DATA_DIR/models."; return 1; }
        # Room for the pack the conversion writes beside it, and 1 GiB spare.
        if (( avail < 2 * need + 1073741824 )); then
            note "The model and its pack need $(( (2 * need + 1073741823) / 1073741824 )) GiB more, plus 1 GiB of room, but $KINDI_DATA_DIR has $(( avail / 1073741824 )) GiB free."
            note "Grow the CT's disk (pct resize <CT_ID> rootfs +<N>G on the PVE host) and rerun."
            return 1
        fi
    fi
    local entry ename esize ehash eurl
    for entry in "${plan[@]}"; do
        read -r ename esize ehash eurl <<< "$entry"
        fetch_file "$ename" "$esize" "$ehash" "$eurl"
    done
    printf 'The model files are installed: %s.\n' "${models[*]}"
}

# build_packs: Kindi's pack of every needed model, converted once per GGUF and
# pack format (kindi convert re-lays out the same weights; about a minute for
# the 2B). A pack whose manifest names another GGUF is converted again. During
# an upgrade, move a replaced pack into the rollback snapshot before publishing
# its replacement; restoring only the checkout would leave new weights behind.
build_packs() {
    local model dir gguf sha backup
    for model in $(needed_models); do
        dir=$(pack_dir "$model")
        gguf=$(model_path "$model")
        sha=$(awk -v m="$model" '$1 == m { sub(/^sha256:/, "", $4); print $4 }' "$source_dir/kindi-weights.txt")
        if as_service test -f "$dir/kindi_pack.json" &&
                as_service grep -q "\"source_sha256\": \"$sha\"" "$dir/kindi_pack.json"; then
            printf 'Have the %s pack (format %s).\n' "$model" "$KINDI_PACK_FORMAT"
            continue
        fi
        printf 'Converting %s into Kindi'\''s pack (format %s)...\n' "$model" "$KINDI_PACK_FORMAT"
        as_service rm -rf -- "$dir.new"
        as_service mkdir -p -- "${dir%/*}"
        kindi_cli convert "$gguf" --out "$dir.new" || { note "kindi convert failed for $model."; return 1; }
        if [[ ${KINDI_PACK_ROLLBACK:-0} == 1 && -e $dir ]]; then
            backup=$KINDI_STATE_DIR/rollback-packs/${dir##*/}
            [[ ! -e $backup ]] || { note "Pack backup already exists: $backup."; return 1; }
            mv -- "$dir" "$backup" || return 1
        else
            as_service rm -rf -- "$dir"
        fi
        as_service mv -- "$dir.new" "$dir"
    done
}

# check_engine: kindi verify (greedy output token for token against
# llama.cpp's reference) and, with KINDI_HEAD=fast, the fast head's cluster
# file. Runs with the GPU free (the service is stopped).
check_engine() {
    local dir
    dir=$(pack_dir "$KINDI_MODEL")
    if [[ $KINDI_VERIFY == true ]]; then
        printf 'Checking %s against llama.cpp (kindi verify)...\n' "$KINDI_MODEL"
        kindi_cli --pack "$dir" --state-dir "$KINDI_DATA_DIR/state" verify ||
            { note "kindi verify failed for $KINDI_MODEL on this $KINDI_BACKEND backend; see the output above."; return 1; }
    fi
    if [[ $KINDI_HEAD == fast ]] && ! as_service test -f "$dir/head_clusters.npz"; then
        printf 'Building the fast head (kindi fast-head)...\n'
        kindi_cli --pack "$dir" --state-dir "$KINDI_DATA_DIR/state" fast-head ||
            { note 'kindi fast-head failed.'; return 1; }
    fi
}

# Serialize real runs before reading saved settings. Keep the descriptor open
# for the entire installer; never unlink the lock file while another run may
# be waiting on its inode. Dry runs do not write or take the lock.
acquire_install_lock() {
    (( dry_run )) && return 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Kindi LXC.'
    [[ $KINDI_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $KINDI_ETC_DIR != *..* ]] || die 'Invalid KINDI_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$KINDI_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another Kindi installer is already running (or a process it started still holds the lock).'
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
    install -d -m 0700 "$KINDI_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$KINDI_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$KINDI_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$KINDI_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$KINDI_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$KINDI_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$KINDI_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$KINDI_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    rm -f -- "$KINDI_ETC_DIR/pending-env" || return 1
    sync -- "$KINDI_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$KINDI_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$KINDI_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $KINDI_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$KINDI_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$KINDI_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$KINDI_ETC_DIR/api-key"
    sync -- "$KINDI_ETC_DIR/api-key" "$KINDI_ETC_DIR" || return 1
    api_key=$(< "$KINDI_ETC_DIR/api-key")
}

# The installed config, environment and unit are what this run would write?
config_current() {
    [[ -f $(config_file) && $(server_config) == "$(< "$(config_file)")" ]] &&
        [[ -f $KINDI_ETC_DIR/kindi.env && $(engine_env) == "$(< "$KINDI_ETC_DIR/kindi.env")" ]]
}

# Unchanged since the last successful install or upgrade, and serving?
nothing_to_do() {
    [[ -f $KINDI_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$KINDI_ETC_DIR/installed-settings")" ]] &&
        config_current &&
        cmp -s "$source_dir/kindi.service" "$UNIT_DIR/kindi.service" &&
        systemctl is-active --quiet kindi.service &&
        probe_health
}

# write_unit: the server config (with the key: root and the kindi group may
# read it, nobody but root may change it), the unit's environment and the unit.
write_unit() {
    local temporary
    install -d -o root -g "$SERVICE_USER" -m 0750 "$KINDI_CONFIG_DIR"
    temporary=$(stage_record "$(config_file)" server_config) || return 1
    chgrp "$SERVICE_USER" "$temporary" && chmod 0640 "$temporary" || { rm -f -- "$temporary"; return 1; }
    publish_record "$temporary" "$(config_file)" || { rm -f -- "$temporary"; return 1; }
    engine_env > "$KINDI_ETC_DIR/kindi.env"
    chmod 0644 "$KINDI_ETC_DIR/kindi.env"
    install -m 0644 "$source_dir/kindi.service" "$UNIT_DIR/kindi.service"
    systemctl daemon-reload
}

# /health answers once the engine is loaded (the server starts listening only
# then) and names the model; /v1/models (with the key) must list it too.
probe_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${KINDI_PORT}/health" 2>/dev/null |
        KC_NAME=$KINDI_MODEL_NAME python3 -c 'import json,os,sys; h=json.load(sys.stdin); sys.exit(0 if h.get("ok") is True and h.get("model") == os.environ["KC_NAME"] else 1)' \
            >/dev/null 2>&1 &&
    curl -fsS --max-time 5 -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
        "http://127.0.0.1:${KINDI_PORT}/v1/models" 2>/dev/null |
        KC_NAME=$KINDI_MODEL_NAME python3 -c 'import json,os,sys; ids=[m.get("id") for m in json.load(sys.stdin).get("data") or []]; sys.exit(0 if os.environ["KC_NAME"] in ids else 1)' \
            >/dev/null 2>&1
}
# served_context: the context the engine fitted to the card, from /health.
served_context() {
    curl -fsS --max-time 5 "http://127.0.0.1:${KINDI_PORT}/health" 2>/dev/null |
        python3 -c 'import json,sys; print(int(json.load(sys.stdin)["ctx"]))' 2>/dev/null || true
}

wait_ready() {
    local deadline=$(( SECONDS + KINDI_READY_TIMEOUT )) ctx
    while (( SECONDS < deadline )); do
        if probe_health; then
            ctx=$(served_context)
            [[ -z $ctx || $ctx == "$KINDI_CONTEXT" ]] ||
                note "Kindi fitted the context to the free memory: $ctx tokens (asked for $KINDI_CONTEXT)."
            return 0
        fi
        if systemctl is-failed --quiet kindi.service; then
            note "kindi.service failed; see journalctl -u kindi."
            return 1
        fi
        sleep 5
    done
    note "Kindi has not answered on port $KINDI_PORT within ${KINDI_READY_TIMEOUT}s; see journalctl -u kindi."
    return 1
}

ensure_service_user() {
    local node group
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$KINDI_DATA_DIR" \
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

# install_toolkit: the CUDA 10.2 toolkit (user space only) for KINDI_BACKEND=cuda.
install_toolkit() {
    [[ $KINDI_BACKEND == cuda ]] || return 0
    if (( dry_run )); then
        printf '+ bash cuda-toolkit.sh (CUDA 10.2 toolkit from NVIDIA'\''s runfile, toolkit only, MD5-checked; about 2.6 GB)\n'
        return 0
    fi
    CUDA_HOME_DIR="$CUDA_HOME_DIR" bash "$source_dir/cuda-toolkit.sh"
}

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $KINDI_DIR/.git && -f $UNIT_DIR/kindi.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 python3-venv build-essential
    install_toolkit
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s\n' "$SERVICE_USER" "$GPU_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$KINDI_URL" "$(fetch_spec)" "$KINDI_DIR" "$SERVICE_USER"
        printf '+ check the checkout: required files, config keys, commands, engine settings and Dockerfile pins\n'
        printf '+ uv %s (uv.lock) in %s/uv; Python %s; %s/.venv from requirements-%s.lock (hash-checked)\n' \
            "$(sed -n 's/^uv==\([^ ]*\) .*/\1/p' "$source_dir/uv.lock" | head -n1)" "$KINDI_RUNTIME_DIR" \
            "$KINDI_PYTHON_VERSION" "$KINDI_DIR" "$KINDI_BACKEND"
        printf '+ download and verify the GGUF of %s (kindi-weights.txt) into %s/models\n' \
            "$(needed_models | paste -sd' ' -)" "$KINDI_DATA_DIR"
        printf '+ kindi convert into %s/packs; kindi verify%s\n' "$KINDI_DATA_DIR" \
            "$([[ $KINDI_HEAD != fast ]] || printf '; kindi fast-head')"
        printf '+ write %s (the key [redacted], root:%s 0640), %s/kindi.env and %s/kindi.service\n' \
            "$(config_file)" "$SERVICE_USER" "$KINDI_ETC_DIR" "$UNIT_DIR"
        run systemctl enable kindi.service
        run systemctl restart kindi.service
        printf '+ wait for /health and /v1/models to list %s (up to %ss)\n' "$KINDI_MODEL_NAME" "$KINDI_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$KINDI_DATA_DIR"
    install -d -m 0755 "$KINDI_RUNTIME_DIR"
    install -d -m 0700 "$KINDI_STATE_DIR"
    if [[ -d $KINDI_DIR/.git ]]; then
        verify_source_origin
        chown -R "$SERVICE_USER:$SERVICE_USER" "$KINDI_DIR"
        printf 'Resuming the incomplete Kindi checkout at %s.\n' "$KINDI_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$KINDI_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $KINDI_URL $(fetch_spec)."
    checkout_local "$target"
    validate_checkout "$KINDI_DIR" || die 'This Kindi commit is not one this installer can set up (see above).'
    # The runtime is built (and on CUDA a kernel run) before the downloads, so
    # a checkout or GPU that does not work fails in minutes.
    build_runtime || die 'Building Kindi'\''s runtime failed (see above).'
    install_weights || die 'Installing the model files failed (see above); rerun to resume.'
    build_packs || die 'Converting the model failed (see above).'
    check_engine || die 'Kindi did not pass its checks on this machine (see above).'
    write_unit
    systemctl enable kindi.service
    systemctl restart kindi.service
    wait_ready || die 'Kindi did not become ready.'
    save_settings
}

# Check out COMMIT (already local) and bring the service up on it. Runs in a
# subshell with errexit, so any failure returns non-zero to the caller.
apply_checkout() {
    set -e
    checkout_local "$1"
    validate_checkout "$KINDI_DIR"
    build_runtime
    build_packs
    check_engine
    write_unit
    systemctl restart kindi.service
    wait_ready
}

# Keep a complete runnable checkout (code and venv) at its original absolute
# path on rollback, with the unit, its environment and the server config.
# Models in the data directory are not copied. Packs being replaced during an
# upgrade are moved into rollback-packs. Stop the service before taking this
# snapshot so it forms one consistent state.
snapshot_runtime() {
    [[ -z $(ls -A -- "$KINDI_STATE_DIR/rollback-packs" 2>/dev/null) ]] || {
        note "An earlier pack backup remains in $KINDI_STATE_DIR/rollback-packs; move it back into $KINDI_DATA_DIR/packs or delete it before another upgrade."
        return 1
    }
    install -d -m 0700 "$KINDI_STATE_DIR"
    (umask 077
     tar -C "$KINDI_DIR" --exclude='./.git' -cpf "$KINDI_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$KINDI_STATE_DIR/rollback-runtime.tar.new" "$KINDI_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$KINDI_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/kindi.service" "$KINDI_STATE_DIR/rollback.service" || return 1
    cp -p -- "$KINDI_ETC_DIR/kindi.env" "$KINDI_STATE_DIR/rollback.env" || return 1
    cp -p -- "$(config_file)" "$KINDI_STATE_DIR/rollback.conf" || return 1
    install -d -m 0700 "$KINDI_STATE_DIR/rollback-packs"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    [[ $KINDI_STATE_DIR != / ]] || return 1
    rm -rf -- "$KINDI_STATE_DIR/rollback-packs" || return 1
    rm -f -- "$KINDI_STATE_DIR/rollback-runtime.tar" "$KINDI_STATE_DIR/rollback-runtime.tar.new" \
        "$KINDI_STATE_DIR/rollback.service" "$KINDI_STATE_DIR/rollback.env" "$KINDI_STATE_DIR/rollback.conf"
}

# restore_probe_settings: the port and model id from the fingerprint, for
# installs whose installed-env is missing.
restore_probe_settings() {
    local port name
    port=$(sed -n 's/^port=//p' "$KINDI_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then KINDI_PORT=$port; fi
    name=$(sed -n 's/^model_name=//p' "$KINDI_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $name =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then KINDI_MODEL_NAME=$name; fi
}

# No build, pip, conversion or download is invoked on this path. The caller
# has set the settings the previous runtime ran with (wait_ready uses its port).
restore_runtime() {
    set -e
    local backup dir
    [[ $KINDI_DIR != / && -d $KINDI_DIR/.git && -s $KINDI_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$KINDI_DIR" reset -q --hard "$1"
    find "$KINDI_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$KINDI_DIR" -xpf "$KINDI_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$KINDI_STATE_DIR/rollback.service" "$UNIT_DIR/kindi.service"
    cp -p -- "$KINDI_STATE_DIR/rollback.env" "$KINDI_ETC_DIR/kindi.env"
    cp -p -- "$KINDI_STATE_DIR/rollback.conf" "$(config_file)"
    for backup in "$KINDI_STATE_DIR"/rollback-packs/*; do
        [[ -e $backup ]] || continue
        dir=$KINDI_DATA_DIR/packs/${backup##*/}
        rm -rf -- "$dir"
        mv -- "$backup" "$dir"
    done
    systemctl daemon-reload
    systemctl restart kindi.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$KINDI_URL" "$(fetch_spec)"
        printf '+ verify (or resume downloading) the model files while the service keeps running\n'
        printf '+ same commit, settings, config and unit, and /health serving: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop kindi.service; snapshot; checkout; rebuild the venv; convert when the pack format or weights changed; kindi verify; restart; wait for /health and /v1/models\n'
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout and venv, unit, environment, config and replaced packs without building or downloading (%s/rollback-runtime.tar, removed afterwards)\n' "$KINDI_STATE_DIR"
        return 0
    fi
    [[ -d $KINDI_DIR/.git && -f $UNIT_DIR/kindi.service ]] ||
        die "No Kindi installation at $KINDI_DIR; run without --upgrade first."
    verify_source_origin
    install_toolkit
    ensure_api_key
    ensure_service_user
    install -d -m 0755 "$KINDI_RUNTIME_DIR"
    install -d -m 0700 "$KINDI_STATE_DIR"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$KINDI_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    KINDI_PACK_FORMAT=$(pack_format "$KINDI_DIR")
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$KINDI_DIR" update-ref refs/kindi/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $KINDI_URL $(fetch_spec); Kindi was not stopped or changed."
    install_weights ||
        die "The model files could not be verified or completed; Kindi was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching fingerprint without installed-env migrates its records.
        if [[ ! -f $KINDI_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        printf 'Kindi is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Kindi %s (settings, config, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Kindi from %s to %s.\n' "$previous" "$target"
    fi
    upgrade_guard on
    systemctl stop kindi.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$KINDI_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart kindi.service; wait_ready) ||
            die 'Snapshot failed and the previous service did not become ready.'
        die 'Runtime snapshot failed; the previous service is running again.'
    fi
    # build_packs moves each pack it replaces into the snapshot.
    local KINDI_PACK_ROLLBACK=1
    set +e
    ( apply_checkout "$target" )
    rc=$?
    set -e
    if (( rc == 0 )); then
        # The new commit's pack format names the pack the config now uses.
        KINDI_PACK_FORMAT=$(pack_format "$KINDI_DIR")
        save_settings
        clear_snapshot
        printf 'Kindi is running %s.\n' "$(git_root rev-parse HEAD)"
        upgrade_guard off
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    upgrade_guard rollback
    systemctl stop kindi.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port and model id otherwise). wait_ready
    # checks the restored service on that port.
    if load_settings "$KINDI_ETC_DIR/installed-env"; then
        note "Restoring the settings it last ran with: $(settings_env | tr '\n' ' ')"
    else
        restore_probe_settings
        note 'No record of the previous settings; restoring the complete runtime snapshot.'
    fi
    set +e
    ( restore_runtime "$previous" )
    rc=$?
    set -e
    if (( rc != 0 )); then
        : > "$KINDI_STATE_DIR/rollback-failed" || true
        die "Rollback to $previous failed too; inspect journalctl -u kindi and $KINDI_DIR; the snapshot is kept in $KINDI_STATE_DIR."
    fi
    clear_snapshot
    die "Upgrade failed; Kindi is running $previous again."
}

# resolve_auto: the card's profile, model, context and model id for settings
# left at auto, before anything is installed (nvidia-smi only).
resolve_auto() {
    local vram=0 arch='' name ram_kib need
    if [[ $KINDI_BACKEND == cuda ]]; then
        command -v nvidia-smi >/dev/null || die 'nvidia-smi is missing; install host-matched guest NVIDIA userspace first.'
        nvidia-smi -L || die 'NVIDIA GPU is not accessible inside the CT.'
        vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0 2>/dev/null | head -n1 | tr -d '[:space:]')
        [[ $vram =~ ^[0-9]+$ ]] || die 'Cannot read GPU 0'\''s memory with nvidia-smi; check the passed-through GPU.'
        arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader -i 0 2>/dev/null | compute_cap_arch) || arch=''
        name=$(nvidia-smi --query-gpu=name --format=csv,noheader -i 0 2>/dev/null | head -n1)
        if [[ -z $arch ]]; then
            # The 470 driver (the last for Kepler) does not report it.
            if kepler_by_name "$name"; then arch=30
            elif [[ $KINDI_PROFILE == auto ]]; then
                die "Cannot read the compute capability of GPU 0 ($name); set KINDI_PROFILE (tc, pascal8, p100, kepler or maxwell)."
            fi
        fi
        note "GPU 0: $name, ${vram} MiB${arch:+, compute capability ${arch:0:-1}.${arch: -1}}."
        if [[ $KINDI_MODEL == nanbeige-33b ]]; then
            [[ -z $arch ]] || (( arch >= 80 || arch == 60 )) ||
                die 'nanbeige-33b needs an NVIDIA card of compute capability 8.0 or newer, or a Tesla P100 (Kindi 0.4.0).'
            [[ $KINDI_PROFILE != auto ]] || KINDI_PROFILE=nanbeige
        fi
        if [[ $KINDI_PROFILE == auto ]]; then
            KINDI_PROFILE=$(profile_for "$arch" "$vram")
            note "Kindi profile for this card: $KINDI_PROFILE."
        fi
        [[ $KINDI_MODEL != auto ]] || { KINDI_MODEL=$(auto_model "$KINDI_PROFILE" "$vram"); note "Model for this card: $KINDI_MODEL."; }
        (( vram >= $(model_field "$KINDI_MODEL" vram) )) ||
            die "$KINDI_MODEL needs a card with $(model_field "$KINDI_MODEL" vram) MiB; GPU 0 has ${vram} MiB. Choose a smaller KINDI_MODEL (or auto). Nothing was downloaded."
        if [[ $KINDI_MODEL == bonsai-27b && $KINDI_PROFILE == maxwell ]]; then
            die 'bonsai-27b on one Maxwell card is not a Kindi setup (it splits the 27B over two 4 GB K1200 cards, which this target does not do); choose bonsai-9b or auto.'
        fi
    else
        KINDI_PROFILE=cpu
        [[ $KINDI_MODEL != auto ]] || KINDI_MODEL=bonsai-2b
        if [[ $KINDI_THREADS == auto ]]; then KINDI_THREADS=$(nproc); fi
        grep -qw avx2 "$CPUINFO" 2>/dev/null || die "This CPU has no AVX2; Kindi's CPU engine needs it."
        note "Kindi's CPU engine: $KINDI_MODEL on $KINDI_THREADS threads."
    fi
    [[ $KINDI_CONTEXT != auto ]] || KINDI_CONTEXT=$(auto_context "$KINDI_PROFILE" "$vram" "$KINDI_MODEL")
    [[ $KINDI_MODEL_NAME != auto ]] || KINDI_MODEL_NAME=$(model_field "$KINDI_MODEL" name)
    ram_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO" 2>/dev/null || true)
    need=$(model_field "$KINDI_MODEL" ram)
    if [[ $ram_kib =~ ^[0-9]+$ ]] && (( ram_kib / 1024 < need )); then
        die "The CT has $(( ram_kib / 1024 )) MiB of RAM; $KINDI_MODEL needs about $need MiB (its first start loads the model through host memory). Raise the CT's memory."
    fi
    validate_settings
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
# A failed rollback keeps the last good runtime in $KINDI_STATE_DIR; an upgrade
# would snapshot over it and an unchanged run would hide it, so stop until
# someone has looked (see the README).
if (( ! dry_run )) && [[ -e $KINDI_STATE_DIR/rollback-failed ]]; then
    die "A rollback failed earlier; the previous runtime is kept in $KINDI_STATE_DIR. Inspect or restore it, then delete $KINDI_STATE_DIR/rollback-failed and rerun."
fi
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing $source_dir/upstream-commit.txt"
default_commit=$(< "$source_dir/upstream-commit.txt")
[[ $default_commit =~ ^[0-9a-f]{40}$ ]] || die 'Invalid upstream-commit.txt.'
if [[ -z ${KINDI_REF:-} && -z ${KINDI_COMMIT:-} ]]; then KINDI_COMMIT=$default_commit; fi
KINDI_REF=${KINDI_REF:-main}
KINDI_COMMIT=${KINDI_COMMIT:-}
# auto: CUDA when an NVIDIA GPU is passed into the CT, else the CPU engine.
KINDI_BACKEND=${KINDI_BACKEND:-auto}
if [[ $KINDI_BACKEND == auto ]]; then
    if compgen -G "${KINDI_NVIDIA_NODE_GLOB:-/dev/nvidia[0-9]*}" >/dev/null || (( dry_run )); then
        KINDI_BACKEND=cuda
    else
        KINDI_BACKEND=cpu
    fi
fi
KINDI_MODEL=${KINDI_MODEL:-auto}
KINDI_PROFILE=${KINDI_PROFILE:-auto}
KINDI_PORT=${KINDI_PORT:-8093}
KINDI_CONTEXT=${KINDI_CONTEXT:-auto}
KINDI_HEAD=${KINDI_HEAD:-exact}
KINDI_SPEC=${KINDI_SPEC:-auto}
KINDI_THREADS=${KINDI_THREADS:-auto}
KINDI_MODEL_NAME=${KINDI_MODEL_NAME:-auto}
KINDI_PYTHON_VERSION=${KINDI_PYTHON_VERSION:-3.9.25}
KINDI_VERIFY=${KINDI_VERIFY:-true}
KINDI_READY_TIMEOUT=${KINDI_READY_TIMEOUT:-1800}
[[ $KINDI_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $KINDI_REF != HEAD && $KINDI_REF != *..* ]] || die 'Invalid KINDI_REF.'
[[ -z $KINDI_COMMIT || $KINDI_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid KINDI_COMMIT.'
validate_settings
[[ $KINDI_VERIFY =~ ^(true|false)$ ]] || die 'KINDI_VERIFY must be true or false.'
[[ $KINDI_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid KINDI_READY_TIMEOUT.'
for path_var in KINDI_DIR KINDI_DATA_DIR KINDI_ETC_DIR KINDI_CONFIG_DIR KINDI_STATE_DIR KINDI_RUNTIME_DIR CUDA_HOME_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'
if [[ -z $GPU_NODES && $KINDI_BACKEND == cuda ]]; then
    GPU_NODES='/dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm'
fi

for file in kindi.service cuda-toolkit.sh kindi-weights.txt upstream-commit.txt requirements-cpu.lock \
            requirements-cuda.lock uv.lock; do
    [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file"
done
weight_rows "$source_dir/kindi-weights.txt" "${MODEL_IDS[@]}" >/dev/null || exit 1
# The pack format of the checkout; checkout_local sets it from the commit.
KINDI_PACK_FORMAT=1
[[ ! -f $KINDI_DIR/kindi/convert.py ]] || KINDI_PACK_FORMAT=$(pack_format "$KINDI_DIR")
# Every path below is absolute. The service account runs commands from here,
# not from the root-only deploy directory the installer was started in.
cd /
api_key='[generated inside CT]'
if (( dry_run )); then
    # The plan shows what auto stands for without a GPU to read.
    if [[ $KINDI_BACKEND == cpu ]]; then
        KINDI_PROFILE=cpu
        [[ $KINDI_MODEL != auto ]] || KINDI_MODEL=bonsai-2b
    fi
    [[ $KINDI_MODEL != auto ]] || KINDI_MODEL='<the model the card holds>'
    [[ $KINDI_MODEL_NAME != auto ]] || KINDI_MODEL_NAME='<its model id>'
else
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Kindi LXC.'
    if [[ -e $KINDI_DIR && ! -d $KINDI_DIR/.git ]] && [[ -n $(ls -A "$KINDI_DIR" 2>/dev/null) ]]; then
        die "$KINDI_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    # Before anything is installed or stopped: can this distro run the
    # CUDA 10.2 runfile (or is the toolkit there already)?
    if [[ $KINDI_BACKEND == cuda ]]; then
        CUDA_HOME_DIR="$CUDA_HOME_DIR" bash "$source_dir/cuda-toolkit.sh" --check ||
            die 'The CUDA 10.2 toolkit cannot be installed in this CT (see above).'
    fi
    resolve_auto
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Kindi is configured on TCP %s (model %s, %s); API key: %s/api-key\n' "$KINDI_PORT" "$KINDI_MODEL_NAME" "$KINDI_BACKEND" "$KINDI_ETC_DIR"
