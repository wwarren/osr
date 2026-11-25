#!/usr/bin/env bash
# Runs inside the dedicated PolyStrata LXC after matching NVIDIA userspace is ready.
#
#   bash install-target.sh             install or update PolyStrata and start it
#   bash install-target.sh --upgrade   move to POLYSTRATA_COMMIT or an explicit POLYSTRATA_REF;
#                                      roll back to the previous commit on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# PolyStrata (https://github.com/simplexai-labs/PolyStrata) is a descendant of
# Strata: the same setup.sh, run-<model>.sh launchers and /health contract,
# with eleven more model families on its own engine ("strata-poly"). Its
# setup.sh options differ between releases, so this script reads the
# checked-out setup.sh --help and passes only options it supports, and refuses
# to continue when a required one is missing instead of guessing.
#
# Settings are POLYSTRATA_*: upstream setup and its engines read STRATA_*
# variables of their own (STRATA_CUDA, STRATA_UV, ...), and these must not
# reach them by accident.
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

POLYSTRATA_URL=https://github.com/simplexai-labs/PolyStrata.git
# Paths are overridable for tests only; the unit file uses the defaults.
POLYSTRATA_DIR=${POLYSTRATA_DIR:-/opt/polystrata}
POLYSTRATA_DATA_DIR=${POLYSTRATA_DATA_DIR:-/var/lib/polystrata}
POLYSTRATA_ETC_DIR=${POLYSTRATA_ETC_DIR:-/etc/polystrata-target}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
POLYSTRATA_STATE_DIR=${POLYSTRATA_STATE_DIR:-/var/lib/polystrata-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-polystrata}
# GPU device nodes whose group the service user joins (glob-expanded).
GPU_NODES=${GPU_NODES:-'/dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm'}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh [--dry-run] [--upgrade]
Installs PolyStrata from https://github.com/simplexai-labs/PolyStrata.git as the "polystrata"
service account, sets up the model with upstream setup.sh, and starts the
hardened polystrata systemd service. Re-running fetches the tested default commit,
an explicit POLYSTRATA_COMMIT or the tip of an explicit POLYSTRATA_REF before stopping
anything. When the commit, settings and unit are unchanged and PolyStrata is healthy
it does nothing;
otherwise it upgrades with rollback to the previous commit on failure.

--upgrade moves an existing install to POLYSTRATA_COMMIT (or the current tip of
POLYSTRATA_REF), re-runs setup for the configured model (nothing is downloaded
twice), restarts and health-checks the service, and returns to the previous
commit if any step fails.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or the installed-settings fingerprint when that is lost); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment: POLYSTRATA_COMMIT=36e654b1b7eb4cb462202445be296ba012c75edf (tested default),
POLYSTRATA_REF=<branch or tag> (follow it when no commit is set); POLYSTRATA_COMMIT=
explicitly follows main,
POLYSTRATA_FAMILY=qwen (any family the checkout's setup.sh lists: qwen, swift,
coder, unsloth, gyro, nvfp4 on the Strata engine; glm, deepseek, lfm25, inkling,
flint, kolibri, groot, qwen36, clover, ornith, gemma4, tiel, minicpmv, ornith122
on PolyStrata's experimental engine), POLYSTRATA_MODEL=<the family's default in
families.sh, e.g. IQ2_XS for qwen>, POLYSTRATA_CONTEXT=65536,
POLYSTRATA_PARALLEL=1 (concurrent requests; requires checkout --parallel above 1),
POLYSTRATA_KV=auto (the KV cache; auto passes no --kv and keeps the engine's
default: int8 on the Strata engine, fp16 on PolyStrata's. Strata-engine
families also take k8v4 or q4_0, PolyStrata-engine families fp16 and the
formats families.sh lists for them, e.g. q8_0 for qwen36),
POLYSTRATA_MESSAGE_CACHE=false (true: also checkpoint a long conversation
before its last message, for agents that rewrite it; the service then runs
with upstream's STRATA_CACHE_MESSAGE_BOUNDARY=1; Strata engine only),
POLYSTRATA_VISION=no, POLYSTRATA_PORT=8080, POLYSTRATA_READY_TIMEOUT=900 (seconds),
POLYSTRATA_ALLOW_NO_KEY=false (true: accept a checkout without --api-key support).
USAGE
}

# Install helpers (sourced by test-install.sh) ---------------------------------
# SETUP_HELP holds setup.sh --help output. It is parsed as text, never run.
# The helpers use the family catalog (families.sh, sourced by the caller).

# help_has FLAG: does this setup.sh accept the long option FLAG?
help_has() { grep -Eq -- "(^|[][[:space:],])$1([][[:space:]=,]|$)" <<< "$SETUP_HELP"; }

# help_choices FLAG: the {a,b,c} choices argparse lists for FLAG, space separated
# (empty when the option is free-form or absent).
help_choices() {
    sed -nE "s/.*(^|[][[:space:],])$1[[:space:]]+\{([^}]*)\}.*/\2/p" <<< "$SETUP_HELP" |
        head -n1 | tr ',' ' '
}

# check_choice FLAG VALUE: refuse VALUE when setup.sh lists choices that lack it.
check_choice() {
    local choices
    choices=$(help_choices "$1")
    [[ -z $choices || " $choices " == *" $2 "* ]] ||
        die "This PolyStrata checkout does not accept $1 $2 (it offers: $choices). Choose one of those, or pin POLYSTRATA_REF/POLYSTRATA_COMMIT to a release that has it."
}

# validate_setup_options: every option this installer depends on must exist.
validate_setup_options() {
    local flag
    local -a missing=()
    for flag in --setup --no-start --yes --model --port --host; do
        help_has "$flag" || missing+=("$flag")
    done
    if ! help_has --api-key && [[ $POLYSTRATA_ALLOW_NO_KEY != true ]]; then
        missing+=(--api-key)
    fi
    (( ${#missing[@]} == 0 )) ||
        die "This PolyStrata checkout's setup.sh does not accept: ${missing[*]}. The router reaches PolyStrata over the network (--host) with a key (--api-key); without them the API listens on 127.0.0.1 only or unauthenticated. Pin POLYSTRATA_REF/POLYSTRATA_COMMIT to a release that supports them (set POLYSTRATA_ALLOW_NO_KEY=true to accept a keyless API)."
    help_has --family || [[ $POLYSTRATA_FAMILY == qwen ]] ||
        die "This PolyStrata checkout has no --family option, so POLYSTRATA_FAMILY=$POLYSTRATA_FAMILY cannot be selected."
    check_choice --family "$POLYSTRATA_FAMILY"
    check_choice --model "$POLYSTRATA_MODEL"
    check_choice --vision "$POLYSTRATA_VISION"
    # auto passes no --kv: the engine's default cache, on any checkout.
    if [[ $POLYSTRATA_KV != auto ]]; then
        help_has --kv ||
            die "This PolyStrata checkout has no --kv option, so POLYSTRATA_KV=$POLYSTRATA_KV cannot be selected. Set POLYSTRATA_KV=auto, or pin POLYSTRATA_REF/POLYSTRATA_COMMIT to a release that has --kv."
        check_choice --kv "$POLYSTRATA_KV"
    fi
    help_has --parallel || [[ $POLYSTRATA_PARALLEL == 1 ]] ||
        die 'This PolyStrata checkout has no --parallel option; choose POLYSTRATA_PARALLEL=1 or a newer POLYSTRATA_COMMIT.'
}

# setup_args: setup.sh arguments, one per line, for installing or refreshing
# the model without starting it. The service uses upstream's run-<model>.sh.
# The API key is never included here: it would end up in the unit and in logs.
setup_args() {
    printf '%s\n' --setup --no-start
    printf '%s\n' --yes
    if help_has --no-browser; then printf '%s\n' --no-browser; fi
    if help_has --family; then printf '%s\n' --family "$POLYSTRATA_FAMILY"; fi
    printf '%s\n' --model "$POLYSTRATA_MODEL"
    if help_has --context; then printf '%s\n' --context "$POLYSTRATA_CONTEXT"; fi
    if help_has --kv && [[ $POLYSTRATA_KV != auto ]]; then printf '%s\n' --kv "$POLYSTRATA_KV"; fi
    if help_has --parallel && (( POLYSTRATA_PARALLEL > 1 )); then printf '%s\n' --parallel "$POLYSTRATA_PARALLEL"; fi
    if help_has --vision; then printf '%s\n' --vision "$POLYSTRATA_VISION"; fi
    printf '%s\n' --host 0.0.0.0 --port "$POLYSTRATA_PORT"
    if help_has --data-dir; then
        printf '%s\n' --data-dir "$POLYSTRATA_DATA_DIR"
    elif help_has --models-dir; then
        printf '%s\n' --models-dir "$POLYSTRATA_DATA_DIR/models"
    fi
}

# setup_home: where setup.py writes its run scripts, configs and .venv. Since
# PolyStrata 0.2.19-poly.1 (Strata's "0.2.16 layout") that is terminal/:
# setup.sh runs terminal/setup.py, which moves an older checkout's run scripts
# there. Older checkouts (an explicit POLYSTRATA_COMMIT) write in the checkout.
setup_home() {
    if [[ -f $POLYSTRATA_DIR/terminal/setup.py ]]; then printf '%s\n' "$POLYSTRATA_DIR/terminal"
    else printf '%s\n' "$POLYSTRATA_DIR"; fi
}

# select_run_script LOG MARKER: the launcher setup.py just generated. Setup
# prints "start script: run-<model>.sh" (the name only, in setup_home); when
# that line is missing (reworded in another release), fall back to the one
# run-*.sh written after MARKER was touched. Refuse an ambiguous or missing
# launcher rather than starting an older model's script.
select_run_script() {
    local log_file=$1 marker=${2:-} line name candidate found='' home
    local -a fresh=()
    home=$(setup_home)
    while IFS= read -r line; do
        [[ $line =~ start[[:space:]]script:[[:space:]]*(run-[a-z0-9._-]+\.sh) ]] || continue
        name=${BASH_REMATCH[1]}
        if [[ -n $found && $found != "$name" ]]; then
            printf 'Error: PolyStrata setup reported more than one run script.\n' >&2
            return 1
        fi
        found=$name
    done < "$log_file"
    if [[ -z $found && -n $marker && -e $marker ]]; then
        mapfile -t fresh < <(find "$home" -maxdepth 1 -type f -name 'run-*.sh' -newer "$marker" -printf '%f\n')
        if (( ${#fresh[@]} == 1 )); then
            found=${fresh[0]}
            printf 'Note: setup did not name its start script; using %s, the launcher it just wrote.\n' "$found" >&2
        elif (( ${#fresh[@]} > 1 )); then
            printf 'Error: PolyStrata setup wrote several run scripts (%s) and named none of them.\n' "${fresh[*]}" >&2
            return 1
        fi
    fi
    if [[ -z $found ]]; then
        printf 'Error: PolyStrata setup did not report or write a run-<model>.sh script.\n' >&2
        return 1
    fi
    candidate=$home/$found
    if [[ ! -f $candidate || ! -x $candidate || -L $candidate ]]; then
        printf 'Error: PolyStrata did not generate an executable %s.\n' "$candidate" >&2
        return 1
    fi
    run_script=$candidate
}

# settings_fingerprint: what the running service was set up with. A re-run that
# finds the same commit, these settings and the same unit does nothing.
settings_fingerprint() {
    local key_hash
    key_hash=$(printf '%s' "${api_key:-}" | sha256sum | cut -d' ' -f1) || return 1
    printf 'family=%s\nmodel=%s\ncontext=%s\nvision=%s\nport=%s\ndata_dir=%s\nallow_no_key=%s\nkey_sha256=%s\n' \
        "$POLYSTRATA_FAMILY" "$POLYSTRATA_MODEL" "$POLYSTRATA_CONTEXT" "$POLYSTRATA_VISION" "$POLYSTRATA_PORT" \
        "$POLYSTRATA_DATA_DIR" "$POLYSTRATA_ALLOW_NO_KEY" "$key_hash" || return 1
    # Default values add no line, so the fingerprint stays short and stable.
    if [[ $POLYSTRATA_KV != auto ]]; then printf 'kv=%s\n' "$POLYSTRATA_KV"; fi
    if [[ $POLYSTRATA_PARALLEL != 1 ]]; then printf 'parallel=%s\n' "$POLYSTRATA_PARALLEL"; fi
    if [[ $POLYSTRATA_MESSAGE_CACHE == true ]]; then printf 'message_cache=true\n'; fi
}

# The settings that decide how setup runs. save_settings records them after
# every successful install or upgrade, so a failed upgrade can roll back to
# what last worked rather than re-running setup with the settings that failed.
SETTING_KEYS=(POLYSTRATA_FAMILY POLYSTRATA_MODEL POLYSTRATA_CONTEXT POLYSTRATA_PARALLEL POLYSTRATA_KV POLYSTRATA_MESSAGE_CACHE POLYSTRATA_VISION POLYSTRATA_PORT
              POLYSTRATA_ALLOW_NO_KEY)
# Settings added after records existed, with the value those installs ran with.
# A record without one of them is still complete. (None yet: every record this
# target writes holds all of SETTING_KEYS. A setting added later goes here.)
declare -gA SETTING_LEGACY_DEFAULTS=()

# required_setting_keys: the settings every record must hold.
required_setting_keys() {
    local key
    for key in "${SETTING_KEYS[@]}"; do
        [[ -v SETTING_LEGACY_DEFAULTS[$key] ]] || printf '%s\n' "$key"
    done
}

# validate_settings: die unless every setting has a value this script accepts.
# (Family, model and vision are also checked against setup.sh --help later.)
validate_settings() {
    [[ $POLYSTRATA_FAMILY =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die 'Invalid POLYSTRATA_FAMILY.'
    [[ $POLYSTRATA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid POLYSTRATA_MODEL.'
    [[ $POLYSTRATA_CONTEXT =~ ^[1-9][0-9]{0,8}$ ]] || die 'Invalid POLYSTRATA_CONTEXT.'
    [[ $POLYSTRATA_PARALLEL =~ ^[1-8]$ ]] || die 'POLYSTRATA_PARALLEL must be 1 to 8.'
    [[ $POLYSTRATA_KV =~ ^(auto|int8|k8v4|q4_0|fp16|q8_0|int8k)$ ]] ||
        die 'POLYSTRATA_KV must be auto, int8, k8v4, q4_0, fp16, q8_0 or int8k.'
    local kv_choices
    kv_choices=$(polystrata_kv_choices "$POLYSTRATA_FAMILY")
    [[ " $kv_choices " == *" $POLYSTRATA_KV "* ]] ||
        die "POLYSTRATA_KV=$POLYSTRATA_KV does not fit the $POLYSTRATA_FAMILY family's engine; choose one of: $kv_choices."
    [[ $POLYSTRATA_MESSAGE_CACHE =~ ^(true|false)$ ]] || die 'POLYSTRATA_MESSAGE_CACHE must be true or false.'
    [[ $POLYSTRATA_MESSAGE_CACHE == false || $(polystrata_family_engine "$POLYSTRATA_FAMILY" 2>/dev/null) == strata ]] ||
        die "POLYSTRATA_MESSAGE_CACHE=true is a Strata-engine setting; the $POLYSTRATA_FAMILY family runs on another engine. Set it to false."
    [[ $POLYSTRATA_VISION =~ ^(yes|no|gpu|cpu)$ ]] || die 'Invalid POLYSTRATA_VISION.'
    [[ $POLYSTRATA_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( POLYSTRATA_PORT <= 65535 )) || die 'Invalid POLYSTRATA_PORT.'
    [[ $POLYSTRATA_ALLOW_NO_KEY =~ ^(true|false)$ ]] || die 'POLYSTRATA_ALLOW_NO_KEY must be true or false.'
}

# settings_env: the settings as KEY=value lines (no secrets).
settings_env() {
    local key
    for key in "${SETTING_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}" || return 1; done
}

# load_settings FILE: set the recorded settings from FILE. The file is parsed,
# never sourced: only the known keys are read, and nothing is changed unless
# every key is present and valid (a key in SETTING_LEGACY_DEFAULTS may be
# missing: it takes that value). Returns 1 otherwise, for example for an
# install made by an earlier version of this script (fingerprint only).
load_settings() {
    local file=$1 line key
    local -A found=()
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^(POLYSTRATA_[A-Z_]+)=(.*)$ ]] || continue
        [[ " ${SETTING_KEYS[*]} " == *" ${BASH_REMATCH[1]} "* ]] || continue
        found[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    done < "$file"
    for key in "${!SETTING_LEGACY_DEFAULTS[@]}"; do
        [[ -v found[$key] ]] || found[$key]=${SETTING_LEGACY_DEFAULTS[$key]}
    done
    for key in "${SETTING_KEYS[@]}"; do [[ -v found[$key] ]] || return 1; done
    # Validate in a subshell first: validate_settings dies on a bad value.
    (
        for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
        validate_settings
    ) >/dev/null 2>&1 || return 1
    for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
}

# start_env: the unit's EnvironmentFile: the launcher path ExecStart expands,
# and engine settings (the server passes its environment to the engine).
start_env() {
    printf '# Written by install-target.sh for this PolyStrata checkout; do not edit.\n'
    # Opt-in upstream: one more checkpoint at the previous turn boundary of a
    # prompt of 8192+ tokens, so a rewritten last message reuses the history.
    if [[ ${POLYSTRATA_MESSAGE_CACHE:-false} == true ]]; then printf 'STRATA_CACHE_MESSAGE_BOUNDARY=1\n'; fi
    printf 'POLYSTRATA_RUN_SCRIPT=%s\n' "$run_script"
}

# fingerprint_env FILE: an installed-settings fingerprint as the KEY=value
# lines load_settings reads. The fingerprint names a setting at its default
# (kv auto, parallel 1, message cache off) by leaving its line out, so those
# defaults are filled in.
fingerprint_env() {
    local out
    out=$(sed -n -e 's/^family=/POLYSTRATA_FAMILY=/p' \
        -e 's/^model=/POLYSTRATA_MODEL=/p' \
        -e 's/^context=/POLYSTRATA_CONTEXT=/p' \
        -e 's/^parallel=/POLYSTRATA_PARALLEL=/p' \
        -e 's/^kv=/POLYSTRATA_KV=/p' \
        -e 's/^message_cache=/POLYSTRATA_MESSAGE_CACHE=/p' \
        -e 's/^vision=/POLYSTRATA_VISION=/p' \
        -e 's/^port=/POLYSTRATA_PORT=/p' \
        -e 's/^allow_no_key=/POLYSTRATA_ALLOW_NO_KEY=/p' "$1") || return 1
    [[ -z $out ]] || printf '%s\n' "$out"
    grep -q '^POLYSTRATA_PARALLEL=' <<< "$out" || printf 'POLYSTRATA_PARALLEL=1\n'
    grep -q '^POLYSTRATA_KV=' <<< "$out" || printf 'POLYSTRATA_KV=auto\n'
    grep -q '^POLYSTRATA_MESSAGE_CACHE=' <<< "$out" || printf 'POLYSTRATA_MESSAGE_CACHE=false\n'
}

# saved_settings: an existing installation keeps its settings on every rerun,
# with or without --upgrade: the record of its last good install, or for an
# install made before that record existed, its installed-settings fingerprint.
# Explicit, non-empty environment values win. Only a fresh install with no
# checkout, unit or settings record uses the defaults below.
saved_settings() {
    local key
    local -A overrides=()
    for key in "${SETTING_KEYS[@]}"; do
        if [[ -n ${!key-} ]]; then overrides[$key]=${!key}; fi
    done
    if [[ -e $POLYSTRATA_ETC_DIR/installed-env ]]; then
        load_settings "$POLYSTRATA_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $POLYSTRATA_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $POLYSTRATA_ETC_DIR/installed-settings || -L $POLYSTRATA_ETC_DIR/installed-settings ||
            -e $POLYSTRATA_ETC_DIR/pending-env || -L $POLYSTRATA_ETC_DIR/pending-env ||
            -e $POLYSTRATA_DIR/.git || -L $POLYSTRATA_DIR/.git ||
            -e $UNIT_DIR/polystrata.service || -L $UNIT_DIR/polystrata.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $POLYSTRATA_ETC_DIR/installed-settings && -r $POLYSTRATA_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$POLYSTRATA_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $POLYSTRATA_ETC_DIR/installed-settings (an install from before installed-env)."
        elif [[ ! -e $POLYSTRATA_ETC_DIR/installed-settings && ! -L $POLYSTRATA_ETC_DIR/installed-settings &&
                -f $POLYSTRATA_ETC_DIR/pending-env && -r $POLYSTRATA_ETC_DIR/pending-env ]] &&
                load_settings "$POLYSTRATA_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($POLYSTRATA_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $POLYSTRATA_ETC_DIR/installed-settings || -L $POLYSTRATA_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $POLYSTRATA_ETC_DIR/installed-settings"
            else
                missing="Found an existing PolyStrata installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $POLYSTRATA_ETC_DIR)"
            fi
            local -a required
            mapfile -t required < <(required_setting_keys)
            for key in "${required[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${required[*]} explicitly, or restore a record."
            done
        fi
    fi
    # A different family needs its own default model unless one is given (the
    # saved model may not exist for it, and setup would fail after the stop).
    if [[ -v overrides[POLYSTRATA_FAMILY] && ! -v overrides[POLYSTRATA_MODEL] &&
          ${overrides[POLYSTRATA_FAMILY]} != "${POLYSTRATA_FAMILY:-}" ]]; then
        unset POLYSTRATA_MODEL
    fi
    for key in "${!overrides[@]}"; do printf -v "$key" '%s' "${overrides[$key]}"; done
}

# End install helpers. ----------------------------------------------------------

# as_service CMD...: run CMD as the service account. The installer lock's
# descriptor is closed for it, so nothing it leaves running in the background
# (git's detached housekeeping, an upstream script's helper) holds the lock
# after the installer has exited.
as_service() {
    if [[ -n ${install_lock_fd:-} ]]; then
        runuser -u "$SERVICE_USER" -- env HOME="$POLYSTRATA_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$POLYSTRATA_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$POLYSTRATA_DIR" -C "$POLYSTRATA_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$POLYSTRATA_URL" ]] || die "Existing $POLYSTRATA_DIR origin is not official: $origin"
}

# Fetch POLYSTRATA_COMMIT (or the tip of POLYSTRATA_REF) into FETCH_HEAD without
# touching the checkout, and print the fetched commit. A fetch by commit works
# for any commit, not only a branch tip.
fetch_target() {
    local fetched
    if [[ ! -d $POLYSTRATA_DIR/.git ]]; then
        as_service git init -q "$POLYSTRATA_DIR"
        as_service git -C "$POLYSTRATA_DIR" remote add origin "$POLYSTRATA_URL"
    fi
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$POLYSTRATA_DIR" fetch -q --depth 1 origin "${POLYSTRATA_COMMIT:-$POLYSTRATA_REF}" >&2 || return 1
    fetched=$(git_root rev-parse FETCH_HEAD) || return 1
    if [[ -n $POLYSTRATA_COMMIT && ${fetched,,} != "${POLYSTRATA_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $POLYSTRATA_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# drop_venv_before_layout_move: the terminal/ layout's setup.sh moves an older
# checkout's .venv into terminal/ (mv .venv terminal/.venv) before it runs
# setup.py. A virtualenv cannot be moved: the launchers pip wrote in it, such
# as cmake, still start with #!<checkout>/.venv/bin/python and no longer run,
# while its record of installed packages says they are there, so setup stops
# with "cmake / ninja not found after installing them". A checkout that brings
# that layout therefore lets setup.sh make a new .venv in terminal/ (it
# reinstalls the Python packages). An upgrade's rollback snapshot, taken
# before the checkout, still holds the old .venv.
drop_venv_before_layout_move() {
    [[ -f $POLYSTRATA_DIR/terminal/setup.py && ! -e $POLYSTRATA_DIR/terminal/.venv && -e $POLYSTRATA_DIR/.venv ]] || return 0
    note "This PolyStrata keeps its Python environment in terminal/; a virtualenv cannot be moved there, so setup makes a new one (the Python packages are installed again)."
    rm -rf -- "$POLYSTRATA_DIR/.venv"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$POLYSTRATA_DIR" checkout -q --detach "$1"
    printf 'PolyStrata source commit: %s\n' "$(git_root rev-parse HEAD)"
    drop_venv_before_layout_move
}

probe_setup_help() {
    # setup.sh creates its .venv on first use, then prints argparse help.
    SETUP_HELP=$(cd "$POLYSTRATA_DIR" && as_service bash ./setup.sh --help 2>&1) ||
        die "bash setup.sh --help failed in $POLYSTRATA_DIR:"$'\n'"$SETUP_HELP"
    validate_setup_options
}

# Upstream setup runs as the unprivileged service account, so its sudo package
# commands cannot succeed. Choose a toolkit NVIDIA publishes for this CT;
# cuda-toolkit-X-Y does not install a kernel driver.
cuda_toolkit_target() {
    local ID VERSION_ID
    # shellcheck disable=SC1090,SC1091
    . "${POLYSTRATA_OS_RELEASE:-/etc/os-release}"
    case $ID:$VERSION_ID in
        ubuntu:22.04) printf 'ubuntu2204 13.0\n' ;;
        ubuntu:24.04) printf 'ubuntu2404 13.0\n' ;;
        debian:12) printf 'debian12 13.0\n' ;;
        debian:13) printf 'debian13 13.1\n' ;;
        *) return 1 ;;
    esac
}

install_cuda_toolkit() {
    local version distro package keyring keyring_url temporary nvcc
    read -r distro version < <(cuda_toolkit_target) || return 1
    [[ -n $distro && -n $version ]] || return 1
    package=cuda-toolkit-${version/./-}
    nvcc=${POLYSTRATA_NVCC:-/usr/local/cuda-$version/bin/nvcc}
    keyring=cuda-keyring_1.1-1_all.deb
    keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/$distro/x86_64/$keyring"
    note "PolyStrata needs build tools for a local engine build; installing $package from NVIDIA's $distro repository as root."
    apt-get update
    apt-get install -y ca-certificates curl build-essential
    temporary=$(mktemp "${TMPDIR:-/tmp}/polystrata-cuda-keyring.XXXXXX.deb")
    if ! curl -fsSL --retry 3 -o "$temporary" "$keyring_url"; then
        rm -f -- "$temporary"
        die "Could not download NVIDIA's CUDA keyring from $keyring_url."
    fi
    if ! dpkg -i "$temporary"; then
        rm -f -- "$temporary"
        die "Could not install NVIDIA's CUDA keyring for $distro."
    fi
    rm -f -- "$temporary"
    apt-get update
    apt-cache show "$package" >/dev/null 2>&1 ||
        die "NVIDIA's $distro repository does not offer $package."
    apt-get install -y "$package"
    [[ -x $nvcc ]] || die "$package installed but $nvcc is missing."
    "$nvcc" --version | grep -Fq "release $version" ||
        die "$nvcc does not report CUDA $version after installing $package."
    as_service nvidia-smi -L >/dev/null || die 'NVIDIA GPU access failed after the CUDA toolkit install.'
    note "CUDA $version toolkit is ready; retrying PolyStrata setup as $SERVICE_USER."
}

run_setup() {
    local -a args
    local setup_log marker attempt sudo_guard
    mapfile -t args < <(setup_args)
    setup_log=$(mktemp "$POLYSTRATA_ETC_DIR/setup-output.XXXXXX")
    # A second in the past, so a launcher written in the same second still
    # counts as newer on filesystems with coarse timestamps.
    marker=$(mktemp "$POLYSTRATA_ETC_DIR/setup-start.XXXXXX")
    touch -d "@$(( $(date +%s) - 1 ))" "$marker"
    # Upstream calls sudo when a build needs system packages. The service user
    # has no sudo password. Shadow sudo for this setup invocation so it fails
    # promptly without detaching the build from the caller's terminal.
    sudo_guard=$(mktemp -d /tmp/polystrata-sudo-guard.XXXXXX)
    cat > "$sudo_guard/sudo" <<'NO_SUDO'
#!/bin/sh
printf 'polystrata-target: upstream setup requested sudo; the target installer will provision build tools as root.\n' >&2
exit 1
NO_SUDO
    chmod 0755 "$sudo_guard" "$sudo_guard/sudo"
    for attempt in 1 2; do
        if help_has --api-key; then
            printf '+ bash setup.sh %s --api-key [redacted]\n' "${args[*]}"
            if (cd "$POLYSTRATA_DIR" && umask 027 && as_service env PATH="$sudo_guard:$PATH" bash ./setup.sh "${args[@]}" --api-key "$api_key") 2>&1 | tee "$setup_log"; then
                break
            fi
        else
            note "WARNING: this PolyStrata checkout has no --api-key option; its API is unauthenticated."
            printf '+ bash setup.sh %s\n' "${args[*]}"
            if (cd "$POLYSTRATA_DIR" && umask 027 && as_service env PATH="$sudo_guard:$PATH" bash ./setup.sh "${args[@]}") 2>&1 | tee "$setup_log"; then
                break
            fi
        fi
        if (( attempt == 1 )) &&
            { grep -Fq 'the CUDA Toolkit can be installed automatically on Ubuntu' "$setup_log" ||
              grep -Fq 'polystrata-target: upstream setup requested sudo' "$setup_log"; } &&
            cuda_toolkit_target >/dev/null; then
            install_cuda_toolkit
            continue
        fi
        rm -f "$setup_log" "$marker" "$sudo_guard/sudo"
        rmdir "$sudo_guard"
        return 1
    done
    if ! select_run_script "$setup_log" "$marker"; then
        rm -f "$setup_log" "$marker" "$sudo_guard/sudo"
        rmdir "$sudo_guard"
        return 1
    fi
    rm -f "$setup_log" "$marker" "$sudo_guard/sudo"
    rmdir "$sudo_guard"
}

# Serialize real runs before reading saved settings. Keep the descriptor open
# for the entire installer; never unlink the lock file while another run may
# be waiting on its inode. Dry runs do not write or take the lock.
acquire_install_lock() {
    (( dry_run )) && return 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the PolyStrata LXC.'
    [[ $POLYSTRATA_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $POLYSTRATA_ETC_DIR != *..* ]] || die 'Invalid POLYSTRATA_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$POLYSTRATA_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another PolyStrata installer is already running (or a process it started still holds the lock).'
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
    install -d -m 0700 "$POLYSTRATA_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$POLYSTRATA_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$POLYSTRATA_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$POLYSTRATA_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$POLYSTRATA_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$POLYSTRATA_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$POLYSTRATA_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$POLYSTRATA_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    # installed.service was written by an earlier revision and is not used.
    rm -f -- "$POLYSTRATA_ETC_DIR/installed.service" "$POLYSTRATA_ETC_DIR/pending-env" || return 1
    sync -- "$POLYSTRATA_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$POLYSTRATA_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$POLYSTRATA_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $POLYSTRATA_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$POLYSTRATA_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$POLYSTRATA_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$POLYSTRATA_ETC_DIR/api-key"
    sync -- "$POLYSTRATA_ETC_DIR/api-key" "$POLYSTRATA_ETC_DIR" || return 1
    api_key=$(< "$POLYSTRATA_ETC_DIR/api-key")
}

# Unchanged since the last successful install or upgrade, and serving?
nothing_to_do() {
    [[ -f $POLYSTRATA_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$POLYSTRATA_ETC_DIR/installed-settings")" ]] &&
        cmp -s "$source_dir/polystrata.service" "$UNIT_DIR/polystrata.service" &&
        systemctl is-active --quiet polystrata.service &&
        probe_health
}

write_unit() {
    start_env > "$POLYSTRATA_ETC_DIR/polystrata.env"
    chmod 0644 "$POLYSTRATA_ETC_DIR/polystrata.env"
    install -m 0644 "$source_dir/polystrata.service" "$UNIT_DIR/polystrata.service"
    systemctl daemon-reload
}

# Upstream answers /health without a key. A 200 alone is insufficient: the
# response can report loaded=false while the engine is still coming up.
probe_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${POLYSTRATA_PORT}/health" 2>/dev/null |
        python3 -c 'import json,sys; h=json.load(sys.stdin); sys.exit(0 if h.get("status") == "ok" and h.get("loaded") is True else 1)' \
            >/dev/null 2>&1
}

wait_ready() {
    local deadline=$(( SECONDS + POLYSTRATA_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        probe_health && return 0
        if systemctl is-failed --quiet polystrata.service; then
            note "polystrata.service failed; see journalctl -u polystrata."
            return 1
        fi
        sleep 5
    done
    note "PolyStrata has not answered on port $POLYSTRATA_PORT within ${POLYSTRATA_READY_TIMEOUT}s; see journalctl -u polystrata."
    return 1
}

ensure_service_user() {
    local node group gid
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$POLYSTRATA_DATA_DIR" \
            --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    # GPU access: join each passed-through node's non-root group. A root-group
    # node may still be usable when the service account itself has read/write
    # access (for example mode 0666); never add the account to group root.
    # The account joins video (gid 44, provision-lxc.sh's GPU_GID default)
    # anyway, so the service keeps its GPU when the mapping is later tightened
    # to gid=44,mode=0660 and the CT restarts.
    # shellcheck disable=SC2086  # GPU_NODES is a glob list by design
    for node in $GPU_NODES; do
        [[ -e $node ]] || continue
        gid=$(stat -c %g "$node")
        if [[ $gid == 0 ]]; then
            if as_service test -r "$node" && as_service test -w "$node"; then
                note "WARNING: $node is group root, but $SERVICE_USER can read and write it. Check its actual permissions against the PVE --devN setting; mode 0666 exposes the GPU to all CT users."
                if getent group video >/dev/null; then
                    usermod -aG video "$SERVICE_USER"
                fi
                continue
            fi
            die "$node is group root and $SERVICE_USER cannot read and write it. On the PVE host compare 'pct config <CT_ID>' with the node's actual CT permissions. If its --devN mapping is missing or wrong, set path=$node,gid=44,mode=0660 (44 is video), reboot the CT, and retry; otherwise investigate the device mount and NVIDIA setup."
        fi
        group=$(stat -c %G "$node")
        usermod -aG "$group" "$SERVICE_USER"
        as_service test -r "$node" && as_service test -w "$node" ||
            die "$SERVICE_USER cannot read and write $node after joining group $group (gid $gid); check its CT mode and Proxmox --devN mapping."
    done
    as_service nvidia-smi -L >/dev/null ||
        die "$SERVICE_USER cannot use the NVIDIA GPU even though the device nodes are visible; inspect the CT's --devN mappings and permissions."
}

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $POLYSTRATA_DIR/.git && -f $UNIT_DIR/polystrata.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 python3-venv python3-pip
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s\n' "$SERVICE_USER" "$GPU_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$POLYSTRATA_URL" "${POLYSTRATA_COMMIT:-$POLYSTRATA_REF}" "$POLYSTRATA_DIR" "$SERVICE_USER"
        printf '+ bash setup.sh --help: keep only the options this checkout supports\n'
        printf '+ bash setup.sh --setup --no-start --yes [--no-browser] [--family %s] --model %s [--context %s]%s [--vision %s] --host 0.0.0.0 --port %s [--data-dir %s] --api-key [redacted]\n' \
            "$POLYSTRATA_FAMILY" "$POLYSTRATA_MODEL" "$POLYSTRATA_CONTEXT" \
            "$( [[ $POLYSTRATA_KV == auto ]] || printf ' [--kv %s]' "$POLYSTRATA_KV" )" "$POLYSTRATA_VISION" "$POLYSTRATA_PORT" "$POLYSTRATA_DATA_DIR"
        printf '+ if setup needs a local engine build: install NVIDIA CUDA toolkit as root (13.0 on Ubuntu/Debian 12, 13.1 on Debian 13), then retry setup once\n'
        printf '+ verify setup generated run-<model>.sh; write %s/polystrata.env (%sPOLYSTRATA_RUN_SCRIPT) and %s/polystrata.service\n' \
            "$POLYSTRATA_ETC_DIR" "$( [[ $POLYSTRATA_MESSAGE_CACHE == true ]] && printf 'STRATA_CACHE_MESSAGE_BOUNDARY=1, ' )" "$UNIT_DIR"
        run systemctl enable polystrata.service
        run systemctl restart polystrata.service
        printf '+ wait for http://127.0.0.1:%s/health to report loaded=true (up to %ss)\n' "$POLYSTRATA_PORT" "$POLYSTRATA_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -m 0700 "$POLYSTRATA_ETC_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$POLYSTRATA_DATA_DIR"
    if [[ -d $POLYSTRATA_DIR/.git ]]; then
        verify_source_origin
        # Earlier versions of this script installed as root: hand the tree over.
        chown -R "$SERVICE_USER:$SERVICE_USER" "$POLYSTRATA_DIR" "$POLYSTRATA_DATA_DIR"
        printf 'Resuming the incomplete PolyStrata checkout at %s.\n' "$POLYSTRATA_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$POLYSTRATA_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $POLYSTRATA_URL ${POLYSTRATA_COMMIT:-$POLYSTRATA_REF}."
    checkout_local "$target"
    probe_setup_help
    run_setup
    write_unit
    systemctl enable polystrata.service
    systemctl restart polystrata.service
    wait_ready || die 'PolyStrata did not become ready.'
    save_settings
}

# Check out COMMIT (already local) and bring the service up on it. Runs in a
# subshell with errexit, so any failure returns non-zero to the caller.
apply_checkout() {
    set -e
    checkout_local "$1"
    probe_setup_help
    run_setup
    write_unit
    systemctl restart polystrata.service
    wait_ready
}

# Keep a complete runnable checkout at its original absolute path on rollback.
# Models in the separate data directory are not copied. Stop the service before
# taking this snapshot so configs, venv and binaries form one consistent state.
snapshot_runtime() {
    # Snapshots of an earlier revision lived in $POLYSTRATA_ETC_DIR.
    rm -f -- "$POLYSTRATA_ETC_DIR/rollback-runtime.tar" "$POLYSTRATA_ETC_DIR/rollback-runtime.tar.new" "$POLYSTRATA_ETC_DIR/rollback.service" "$POLYSTRATA_ETC_DIR/rollback.env"
    install -d -m 0700 "$POLYSTRATA_STATE_DIR"
    (umask 077
     tar -C "$POLYSTRATA_DIR" --exclude='./.git' -cpf "$POLYSTRATA_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$POLYSTRATA_STATE_DIR/rollback-runtime.tar.new" "$POLYSTRATA_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$POLYSTRATA_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/polystrata.service" "$POLYSTRATA_STATE_DIR/rollback.service" || return 1
    cp -p -- "$POLYSTRATA_ETC_DIR/polystrata.env" "$POLYSTRATA_STATE_DIR/rollback.env"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    rm -f -- "$POLYSTRATA_STATE_DIR/rollback-runtime.tar" "$POLYSTRATA_STATE_DIR/rollback-runtime.tar.new" "$POLYSTRATA_STATE_DIR/rollback.service" "$POLYSTRATA_STATE_DIR/rollback.env"
}

# restore_probe_settings: the port from the fingerprint, for installs made
# before installed-env existed.
restore_probe_settings() {
    local port
    port=$(sed -n 's/^port=//p' "$POLYSTRATA_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then POLYSTRATA_PORT=$port; fi
}

# No setup, pip, compiler or model download is invoked on this path. The
# caller has set the settings the previous runtime ran with (wait_ready uses
# its port).
restore_runtime() {
    set -e
    [[ $POLYSTRATA_DIR != / && -d $POLYSTRATA_DIR/.git && -s $POLYSTRATA_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$POLYSTRATA_DIR" reset -q --hard "$1"
    find "$POLYSTRATA_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$POLYSTRATA_DIR" -xpf "$POLYSTRATA_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$POLYSTRATA_STATE_DIR/rollback.service" "$UNIT_DIR/polystrata.service"
    cp -p -- "$POLYSTRATA_STATE_DIR/rollback.env" "$POLYSTRATA_ETC_DIR/polystrata.env"
    systemctl daemon-reload
    systemctl restart polystrata.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$POLYSTRATA_URL" "${POLYSTRATA_COMMIT:-$POLYSTRATA_REF}"
        printf '+ same commit, settings and unit, and /health healthy: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop polystrata.service; checkout; setup.sh --setup --no-start ...; restart; wait for /health loaded=true\n'
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout, launcher and unit without setup or downloads (%s/rollback-runtime.tar, removed afterwards)\n' "$POLYSTRATA_STATE_DIR"
        return 0
    fi
    [[ -d $POLYSTRATA_DIR/.git && -f $UNIT_DIR/polystrata.service ]] ||
        die "No PolyStrata installation at $POLYSTRATA_DIR; run without --upgrade first."
    verify_source_origin
    ensure_api_key
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$POLYSTRATA_DIR" "$POLYSTRATA_DATA_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$POLYSTRATA_DIR" update-ref refs/polystrata/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $POLYSTRATA_URL ${POLYSTRATA_COMMIT:-$POLYSTRATA_REF}; PolyStrata was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching legacy fingerprint is sufficient to migrate its records.
        if [[ ! -f $POLYSTRATA_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        printf 'PolyStrata is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying PolyStrata %s (settings, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading PolyStrata from %s to %s.\n' "$previous" "$target"
    fi
    upgrade_guard on
    systemctl stop polystrata.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$POLYSTRATA_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart polystrata.service; wait_ready) ||
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
        printf 'PolyStrata is running %s.\n' "$(git_root rev-parse HEAD)"
        upgrade_guard off
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    upgrade_guard rollback
    systemctl stop polystrata.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port for older installs). wait_ready checks
    # the restored service on that port.
    if load_settings "$POLYSTRATA_ETC_DIR/installed-env"; then
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
        : > "$POLYSTRATA_STATE_DIR/rollback-failed" || true
        die "Rollback to $previous failed too; inspect journalctl -u polystrata and $POLYSTRATA_DIR; the snapshot is kept in $POLYSTRATA_STATE_DIR."
    fi
    clear_snapshot
    die "Upgrade failed; PolyStrata is running $previous again."
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
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/families.sh ]] || die "Missing $source_dir/families.sh"
# shellcheck source=families.sh
source "$source_dir/families.sh"
acquire_install_lock
saved_settings
# A failed rollback keeps the last good runtime in $POLYSTRATA_STATE_DIR; an upgrade
# would snapshot over it and an unchanged run would hide it, so stop until
# someone has looked (see the README).
if (( ! dry_run )) && [[ -e $POLYSTRATA_STATE_DIR/rollback-failed ]]; then
    die "A rollback failed earlier; the previous runtime is kept in $POLYSTRATA_STATE_DIR. Inspect or restore it, then delete $POLYSTRATA_STATE_DIR/rollback-failed and rerun."
fi
# A fresh invocation without a commit or ref uses the tested source. An
# explicit ref, or an explicitly empty commit, keeps branch-based upgrades
# available without silently following an upstream change by default.
POLYSTRATA_DEFAULT_COMMIT=36e654b1b7eb4cb462202445be296ba012c75edf
if [[ ! ${POLYSTRATA_COMMIT+x} && ! ${POLYSTRATA_REF+x} ]]; then
    POLYSTRATA_COMMIT=$POLYSTRATA_DEFAULT_COMMIT
else
    POLYSTRATA_COMMIT=${POLYSTRATA_COMMIT:-}
fi
POLYSTRATA_REF=${POLYSTRATA_REF:-main}
POLYSTRATA_FAMILY=${POLYSTRATA_FAMILY:-qwen}
# Default model per family (families.sh). A family the catalog does not list
# (one a newer checkout adds) needs its model named.
[[ $POLYSTRATA_FAMILY =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die 'Invalid POLYSTRATA_FAMILY.'
if [[ -z ${POLYSTRATA_MODEL:-} ]]; then
    POLYSTRATA_MODEL=$(polystrata_family_default "$POLYSTRATA_FAMILY") ||
        die "families.sh has no default size for POLYSTRATA_FAMILY=$POLYSTRATA_FAMILY; set POLYSTRATA_MODEL too."
fi
POLYSTRATA_CONTEXT=${POLYSTRATA_CONTEXT:-65536}
POLYSTRATA_PARALLEL=${POLYSTRATA_PARALLEL:-1}
POLYSTRATA_KV=${POLYSTRATA_KV:-auto}
POLYSTRATA_MESSAGE_CACHE=${POLYSTRATA_MESSAGE_CACHE:-false}
POLYSTRATA_VISION=${POLYSTRATA_VISION:-no}
POLYSTRATA_PORT=${POLYSTRATA_PORT:-8080}
POLYSTRATA_READY_TIMEOUT=${POLYSTRATA_READY_TIMEOUT:-900}
POLYSTRATA_ALLOW_NO_KEY=${POLYSTRATA_ALLOW_NO_KEY:-false}
[[ $POLYSTRATA_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $POLYSTRATA_REF != HEAD && $POLYSTRATA_REF != *..* ]] || die 'Invalid POLYSTRATA_REF.'
[[ -z $POLYSTRATA_COMMIT || $POLYSTRATA_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid POLYSTRATA_COMMIT.'
# The families are checked against setup.sh --help choices once it is fetched.
validate_settings
[[ $POLYSTRATA_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid POLYSTRATA_READY_TIMEOUT.'
for path_var in POLYSTRATA_DIR POLYSTRATA_DATA_DIR POLYSTRATA_ETC_DIR POLYSTRATA_STATE_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'

[[ -r $source_dir/polystrata.service ]] || die "Missing $source_dir/polystrata.service"
SETUP_HELP=''
api_key='[generated inside CT]'
if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root inside the PolyStrata LXC.'
    if [[ -e $POLYSTRATA_DIR && ! -d $POLYSTRATA_DIR/.git ]] && [[ -n $(ls -A "$POLYSTRATA_DIR" 2>/dev/null) ]]; then
        die "$POLYSTRATA_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    command -v nvidia-smi >/dev/null || die 'nvidia-smi is missing; install host-matched guest NVIDIA userspace first.'
    nvidia-smi -L || die 'NVIDIA GPU is not accessible inside the CT.'
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'PolyStrata is configured on TCP %s; API key: %s/api-key\n' "$POLYSTRATA_PORT" "$POLYSTRATA_ETC_DIR"
