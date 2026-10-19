#!/usr/bin/env bash
# Runs inside the dedicated Maya LXC after matching NVIDIA userspace is ready.
#
#   bash install-target.sh             install or update Maya and start it
#   bash install-target.sh --upgrade   move to MAYA_COMMIT or MAYA_REF (default:
#                                      the latest vX.Y.Z release tag);
#                                      roll back to the previous commit on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# Check upstream setup options before downloading a model or stopping a service.
set -Eeuo pipefail

MAYA_URL=https://github.com/mw00/project-maya.git
# Paths are overridable for tests only; the unit file uses the defaults.
MAYA_DIR=${MAYA_DIR:-/opt/maya}
MAYA_DATA_DIR=${MAYA_DATA_DIR:-/var/lib/maya}
MAYA_ETC_DIR=${MAYA_ETC_DIR:-/etc/maya-target}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
MAYA_STATE_DIR=${MAYA_STATE_DIR:-/var/lib/maya-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-maya}
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
Installs Maya from https://github.com/mw00/project-maya.git as the "maya"
service account, sets up the model with upstream setup.sh, and starts the
hardened maya systemd service. Re-running fetches MAYA_COMMIT or MAYA_REF
(the latest vX.Y.Z release tag by default) before stopping anything: when the commit,
settings and unit are unchanged and Maya is healthy it does nothing;
otherwise it upgrades with rollback to the previous commit on failure.

--upgrade moves an existing install to MAYA_COMMIT (or what MAYA_REF names
now), re-runs setup for the configured model (nothing is downloaded
twice), restarts and health-checks the service, and returns to the previous
commit if any step fails.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or installed-settings for older installs); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment: MAYA_REF=latest (the newest vX.Y.Z tag; or a branch/tag name
such as main), MAYA_COMMIT=<optional full SHA-1 pin, overrides MAYA_REF>,
MAYA_MODEL=Maya-S-v2-IQ2_XXS, MAYA_CONTEXT=32768, MAYA_DRAFT=mtp,
MAYA_NO_VISION=false, MAYA_CUDA_VERSION=12.8, MAYA_PORT=8080,
MAYA_READY_TIMEOUT=900 (seconds).

Setup is told --draft and --nvcc explicitly when the checkout offers them, so
the build uses the CUDA toolkit installed here and a rerun never inherits a
DFlash2 choice (whose first start runs a 5-20 minute speed calibration).
USAGE
}

# Install helpers (sourced by test-install.sh) ---------------------------------
# SETUP_HELP holds setup.sh --help output. It is parsed as text, never run.

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
        die "This Maya checkout does not accept $1 $2 (it offers: $choices). Choose one of those, or pin MAYA_REF/MAYA_COMMIT to a release that has it."
}

# validate_setup_options: every option this installer depends on must exist.
validate_setup_options() {
    local flag
    local -a missing=()
    for flag in --setup --no-start --yes --model --port --host --api-key --download-model --models-dir; do
        help_has "$flag" || missing+=("$flag")
    done
    (( ${#missing[@]} == 0 )) ||
        die "This Maya checkout's setup.sh does not accept: ${missing[*]}. Pin a compatible MAYA_COMMIT."
    if [[ $MAYA_NO_VISION == true ]]; then
        help_has --no-vision || die 'This Maya checkout has no --no-vision option.'
    fi
    check_choice --model "$MAYA_MODEL"
    # --draft: older checkouts always use the MTP block, so only another
    # choice needs the option.
    if help_has --draft; then
        check_choice --draft "$MAYA_DRAFT"
    elif [[ $MAYA_DRAFT != mtp ]]; then
        die "This Maya checkout has no --draft option, so MAYA_DRAFT=$MAYA_DRAFT cannot be set."
    fi
}

# setup_args: setup.sh arguments, one per line, for installing or refreshing
# the model without starting it. The service uses upstream's run-<model>.sh.
# The API key is never included here: it would end up in the unit and in logs.
setup_args() {
    printf '%s\n' --setup --no-start --yes --download-model
    if help_has --plain; then printf '%s\n' --plain; fi
    printf '%s\n' --model "$MAYA_MODEL"
    if help_has --draft; then printf '%s\n' --draft "$MAYA_DRAFT"; fi
    # Build with the toolkit cuda-toolkit.sh installed, not "the newest nvcc
    # that fits": a newer toolkit already in the CT (CUDA 13) cannot build for V100.
    if help_has --nvcc; then printf '%s\n' --nvcc "$MAYA_NVCC"; fi
    if help_has --context; then printf '%s\n' --context "$MAYA_CONTEXT"; fi
    if [[ $MAYA_NO_VISION == true ]]; then printf '%s\n' --no-vision; fi
    printf '%s\n' --host 0.0.0.0 --port "$MAYA_PORT"
    printf '%s\n' --models-dir "$MAYA_DATA_DIR/models"
}

# select_run_script LOG MARKER: the launcher setup.py just generated. Setup
# prints "  [ok] start script: /opt/maya/run-maya-<quant>.sh" (the full path);
# a bare file name is accepted too. A path outside MAYA_DIR is refused. When
# the line is missing (reworded in another release), fall back to the one
# run-maya-*.sh written after MARKER was touched. Refuse an ambiguous or
# missing launcher rather than starting an older model's script.
select_run_script() {
    local log_file=$1 marker=${2:-} line name dir candidate found=''
    local -a fresh=()
    while IFS= read -r line; do
        [[ $line =~ start[[:space:]]script:[[:space:]]*([^[:space:]]*/)?(run-maya-[A-Za-z0-9._-]+\.sh)[[:space:]]*$ ]] || continue
        dir=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
        if [[ -n $dir && ${dir%/} != "${MAYA_DIR%/}" ]]; then
            printf 'Error: Maya setup wrote its start script outside %s: %s%s\n' "$MAYA_DIR" "$dir" "$name" >&2
            return 1
        fi
        if [[ -n $found && $found != "$name" ]]; then
            printf 'Error: Maya setup reported more than one run script.\n' >&2
            return 1
        fi
        found=$name
    done < "$log_file"
    if [[ -z $found && -n $marker && -e $marker ]]; then
        mapfile -t fresh < <(find "$MAYA_DIR" -maxdepth 1 -type f -name 'run-maya-*.sh' -newer "$marker" -printf '%f\n')
        if (( ${#fresh[@]} == 1 )); then
            found=${fresh[0]}
            printf 'Note: setup did not name its start script; using %s, the launcher it just wrote.\n' "$found" >&2
        elif (( ${#fresh[@]} > 1 )); then
            printf 'Error: Maya setup wrote several run scripts (%s) and named none of them.\n' "${fresh[*]}" >&2
            return 1
        fi
    fi
    if [[ -z $found ]]; then
        printf 'Error: Maya setup did not report or write a run-maya-<model>.sh script.\n' >&2
        return 1
    fi
    candidate=$MAYA_DIR/$found
    if [[ ! -f $candidate || ! -x $candidate || -L $candidate ]]; then
        printf 'Error: Maya did not generate an executable %s.\n' "$candidate" >&2
        return 1
    fi
    run_script=$candidate
}

# settings_fingerprint: what the running service was set up with. A re-run that
# finds the same commit, these settings and the same unit does nothing.
settings_fingerprint() {
    local key_hash toolkit_hash
    key_hash=$(printf '%s' "${api_key:-}" | sha256sum | cut -d' ' -f1) || return 1
    toolkit_hash=$(sha256sum "$source_dir/cuda-toolkit.sh" | cut -d' ' -f1) || return 1
    printf 'model=%s\ncontext=%s\ndraft=%s\nno_vision=%s\ncuda=%s\nnvcc=%s\ntoolkit_sha256=%s\nport=%s\ndata_dir=%s\nkey_sha256=%s\n' \
        "$MAYA_MODEL" "$MAYA_CONTEXT" "$MAYA_DRAFT" "$MAYA_NO_VISION" "$MAYA_CUDA_VERSION" "$MAYA_NVCC" \
        "$toolkit_hash" "$MAYA_PORT" "$MAYA_DATA_DIR" "$key_hash"
}

# newest_release_tag: read `git ls-remote --tags --refs` output on stdin and
# print the newest refs/tags/vX.Y.Z (plain version tags only, no -rc).
newest_release_tag() {
    sed -nE 's#^[0-9a-f]{40}[[:space:]]+(refs/tags/v[0-9]+\.[0-9]+\.[0-9]+)$#\1#p' |
        sort -t/ -k3,3V | tail -n1
}

# The settings that decide how setup runs. save_settings records them after
# every successful install or upgrade, so a failed upgrade can roll back to
# what last worked rather than re-running setup with the settings that failed.
SETTING_KEYS=(MAYA_MODEL MAYA_CONTEXT MAYA_DRAFT MAYA_NO_VISION MAYA_CUDA_VERSION MAYA_NVCC MAYA_PORT)

# validate_settings: die unless every setting has a value this script accepts.
validate_settings() {
    [[ $MAYA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid MAYA_MODEL.'
    [[ $MAYA_CONTEXT =~ ^[1-9][0-9]{0,8}$ ]] || die 'Invalid MAYA_CONTEXT.'
    [[ $MAYA_DRAFT =~ ^[a-z0-9]+$ ]] || die 'Invalid MAYA_DRAFT (mtp or dflash2).'
    [[ $MAYA_NO_VISION =~ ^(true|false)$ ]] || die 'MAYA_NO_VISION must be true or false.'
    [[ $MAYA_CUDA_VERSION =~ ^(12\.(8|9)|1[3-9]\.[0-9]+)$ ]] || die 'MAYA_CUDA_VERSION must be 12.8 or newer.'
    [[ $MAYA_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( MAYA_PORT <= 65535 )) || die 'Invalid MAYA_PORT.'
    [[ $MAYA_NVCC =~ ^/[A-Za-z0-9._/-]+$ && $MAYA_NVCC != *..* ]] || die 'Invalid MAYA_NVCC.'
}

# settings_env: the settings as KEY=value lines (no secrets).
settings_env() {
    local key
    for key in "${SETTING_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}" || return 1; done
}

# load_settings FILE: set the recorded settings from FILE. The file is parsed,
# never sourced: only the known keys are read, and nothing is changed unless
# every key is present and valid. Returns 1 otherwise, for example for an
# install made by an earlier version of this script (fingerprint only).
load_settings() {
    local file=$1 line key
    local -A found=()
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^(MAYA_[A-Z_]+)=(.*)$ ]] || continue
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

# start_env: the EnvironmentFile path the unit expands into ExecStart.
start_env() {
    printf '# Written by install-target.sh for this Maya checkout; do not edit.\n'
    printf 'MAYA_RUN_SCRIPT=%s\n' "$run_script"
}

# fingerprint_env FILE: an installed-settings fingerprint (written by every
# version of this script) as the KEY=value lines load_settings reads.
fingerprint_env() {
    sed -n -e 's/^model=/MAYA_MODEL=/p' \
        -e 's/^context=/MAYA_CONTEXT=/p' \
        -e 's/^draft=/MAYA_DRAFT=/p' \
        -e 's/^no_vision=/MAYA_NO_VISION=/p' \
        -e 's/^cuda=/MAYA_CUDA_VERSION=/p' \
        -e 's/^nvcc=/MAYA_NVCC=/p' \
        -e 's/^port=/MAYA_PORT=/p' "$1"
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
    if [[ -e $MAYA_ETC_DIR/installed-env ]]; then
        load_settings "$MAYA_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $MAYA_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $MAYA_ETC_DIR/installed-settings || -L $MAYA_ETC_DIR/installed-settings ||
            -e $MAYA_ETC_DIR/pending-env || -L $MAYA_ETC_DIR/pending-env ||
            -e $MAYA_DIR/.git || -L $MAYA_DIR/.git ||
            -e $UNIT_DIR/maya.service || -L $UNIT_DIR/maya.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $MAYA_ETC_DIR/installed-settings && -r $MAYA_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$MAYA_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $MAYA_ETC_DIR/installed-settings (an install from before installed-env)."
        elif [[ ! -e $MAYA_ETC_DIR/installed-settings && ! -L $MAYA_ETC_DIR/installed-settings &&
                -f $MAYA_ETC_DIR/pending-env && -r $MAYA_ETC_DIR/pending-env ]] &&
                load_settings "$MAYA_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($MAYA_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $MAYA_ETC_DIR/installed-settings || -L $MAYA_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $MAYA_ETC_DIR/installed-settings"
            else
                missing="Found an existing Maya installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $MAYA_ETC_DIR)"
            fi
            for key in "${SETTING_KEYS[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${SETTING_KEYS[*]} explicitly, or restore a record."
            done
        fi
    fi
    # A changed toolkit version needs its matching default nvcc unless supplied.
    if [[ -v overrides[MAYA_CUDA_VERSION] && ! -v overrides[MAYA_NVCC] &&
          ${overrides[MAYA_CUDA_VERSION]} != "${MAYA_CUDA_VERSION:-}" ]]; then
        unset MAYA_NVCC
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
        runuser -u "$SERVICE_USER" -- env HOME="$MAYA_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$MAYA_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$MAYA_DIR" -C "$MAYA_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$MAYA_URL" ]] || die "Existing $MAYA_DIR origin is not official: $origin"
}

# What to fetch: MAYA_COMMIT, else MAYA_REF, where "latest" means the newest
# vX.Y.Z release tag upstream has now (Maya's own updater moves between
# releases too; main can carry changes that alter answers).
fetch_spec() {
    local tags tag
    if [[ -n $MAYA_COMMIT ]]; then printf '%s\n' "$MAYA_COMMIT"; return 0; fi
    if [[ $MAYA_REF != latest ]]; then printf '%s\n' "$MAYA_REF"; return 0; fi
    tags=$(as_service git ls-remote --tags --refs "$MAYA_URL" 'v*') || {
        note "Could not list the release tags of $MAYA_URL."; return 1; }
    tag=$(newest_release_tag <<< "$tags")
    [[ -n $tag ]] || { note "$MAYA_URL has no vX.Y.Z release tag; set MAYA_REF=main or MAYA_COMMIT."; return 1; }
    note "Latest Maya release: ${tag#refs/tags/}"
    printf '%s\n' "$tag"
}

dry_run_spec() {
    if [[ -n $MAYA_COMMIT ]]; then printf '%s' "$MAYA_COMMIT"
    elif [[ $MAYA_REF == latest ]]; then printf 'the latest vX.Y.Z release tag'
    else printf '%s' "$MAYA_REF"; fi
}

# Fetch the target into FETCH_HEAD without touching the checkout, and print
# the fetched commit. A fetch by commit works for any commit, not only a
# branch tip; a tag is peeled to its commit.
fetch_target() {
    local fetched spec
    if [[ ! -d $MAYA_DIR/.git ]]; then
        as_service git init -q "$MAYA_DIR"
        as_service git -C "$MAYA_DIR" remote add origin "$MAYA_URL"
    fi
    spec=$(fetch_spec) || return 1
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$MAYA_DIR" fetch -q --depth 1 origin "$spec" >&2 || return 1
    fetched=$(git_root rev-parse 'FETCH_HEAD^{commit}') || return 1
    if [[ -n $MAYA_COMMIT && ${fetched,,} != "${MAYA_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $MAYA_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$MAYA_DIR" checkout -q --detach "$1"
    printf 'Maya source commit: %s\n' "$(git_root rev-parse HEAD)"
}

probe_setup_help() {
    # setup.sh creates its .venv on first use, then prints argparse help.
    SETUP_HELP=$(cd "$MAYA_DIR" && as_service bash ./setup.sh --help 2>&1) ||
        die "bash setup.sh --help failed in $MAYA_DIR:"$'\n'"$SETUP_HELP"
    validate_setup_options
    if help_has --nvcc && [[ ! -x $MAYA_NVCC ]]; then
        die "$MAYA_NVCC is missing; cuda-toolkit.sh should have installed CUDA $MAYA_CUDA_VERSION there."
    fi
}

run_setup() {
    local -a args
    local setup_log marker
    mapfile -t args < <(setup_args)
    setup_log=$(mktemp "$MAYA_ETC_DIR/setup-output.XXXXXX")
    # A second in the past, so a launcher written in the same second still
    # counts as newer on filesystems with coarse timestamps.
    marker=$(mktemp "$MAYA_ETC_DIR/setup-start.XXXXXX")
    touch -d "@$(( $(date +%s) - 1 ))" "$marker"
    printf '+ bash setup.sh %s --api-key [redacted]\n' "${args[*]}"
    if ! (cd "$MAYA_DIR" && umask 027 && as_service bash ./setup.sh "${args[@]}" --api-key "$api_key") 2>&1 | tee "$setup_log"; then
        rm -f "$setup_log" "$marker"
        return 1
    fi
    if ! select_run_script "$setup_log" "$marker"; then
        rm -f "$setup_log" "$marker"
        return 1
    fi
    rm -f "$setup_log" "$marker"
}

# Serialize real runs before reading saved settings. Keep the descriptor open
# for the entire installer; never unlink the lock file while another run may
# be waiting on its inode. Dry runs do not write or take the lock.
acquire_install_lock() {
    (( dry_run )) && return 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Maya LXC.'
    [[ $MAYA_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $MAYA_ETC_DIR != *..* ]] || die 'Invalid MAYA_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$MAYA_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another Maya installer is already running (or a process it started still holds the lock).'
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
    install -d -m 0700 "$MAYA_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$MAYA_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$MAYA_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$MAYA_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$MAYA_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$MAYA_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$MAYA_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$MAYA_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    # installed.service was written by an earlier revision and is not used.
    rm -f -- "$MAYA_ETC_DIR/installed.service" "$MAYA_ETC_DIR/pending-env" || return 1
    sync -- "$MAYA_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$MAYA_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$MAYA_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $MAYA_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$MAYA_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$MAYA_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$MAYA_ETC_DIR/api-key"
    sync -- "$MAYA_ETC_DIR/api-key" "$MAYA_ETC_DIR" || return 1
    api_key=$(< "$MAYA_ETC_DIR/api-key")
}

# Unchanged since the last successful install or upgrade, and serving?
nothing_to_do() {
    [[ -f $MAYA_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$MAYA_ETC_DIR/installed-settings")" ]] &&
        cmp -s "$source_dir/maya.service" "$UNIT_DIR/maya.service" &&
        systemctl is-active --quiet maya.service &&
        probe_health
}

write_unit() {
    start_env > "$MAYA_ETC_DIR/maya.env"
    chmod 0644 "$MAYA_ETC_DIR/maya.env"
    install -m 0644 "$source_dir/maya.service" "$UNIT_DIR/maya.service"
    systemctl daemon-reload
}

# /health may answer while the engine is down; /v1/models lists only a loaded
# model. Both must pass before the CT is registered as healthy.
probe_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${MAYA_PORT}/health" 2>/dev/null |
        python3 -c 'import json,sys; h=json.load(sys.stdin); sys.exit(0 if h.get("status") == "ok" and h.get("model") else 1)' \
            >/dev/null 2>&1 &&
    curl -fsS --max-time 5 -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
        "http://127.0.0.1:${MAYA_PORT}/v1/models" 2>/dev/null |
        python3 -c 'import json,sys; models=json.load(sys.stdin).get("data") or []; sys.exit(0 if models else 1)' \
            >/dev/null 2>&1
}

wait_ready() {
    local deadline=$(( SECONDS + MAYA_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        probe_health && return 0
        if systemctl is-failed --quiet maya.service; then
            note "maya.service failed; see journalctl -u maya."
            return 1
        fi
        sleep 5
    done
    note "Maya has not answered on port $MAYA_PORT within ${MAYA_READY_TIMEOUT}s; see journalctl -u maya."
    return 1
}

ensure_service_user() {
    local node group
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$MAYA_DATA_DIR" \
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
        printf '+ bash cuda-toolkit.sh (CUDA %s toolkit, user space only)\n' "$MAYA_CUDA_VERSION"
        return 0
    fi
    CUDA_VERSION="$MAYA_CUDA_VERSION" CUDA_NVCC="$MAYA_NVCC" bash "$source_dir/cuda-toolkit.sh"
}

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $MAYA_DIR/.git && -f $UNIT_DIR/maya.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 python3-venv python3-pip build-essential
    install_cuda_toolkit
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s\n' "$SERVICE_USER" "$GPU_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$MAYA_URL" "$(dry_run_spec)" "$MAYA_DIR" "$SERVICE_USER"
        printf '+ bash setup.sh --help: verify required options and model choice\n'
        printf '+ bash setup.sh --setup --no-start --yes --download-model --plain --model %s --draft %s --nvcc %s --context %s --host 0.0.0.0 --port %s --models-dir %s/models --api-key [redacted]\n' \
            "$MAYA_MODEL" "$MAYA_DRAFT" "$MAYA_NVCC" "$MAYA_CONTEXT" "$MAYA_PORT" "$MAYA_DATA_DIR"
        printf '+ verify setup generated run-maya-<model>.sh; write %s/maya.env (MAYA_RUN_SCRIPT) and %s/maya.service\n' "$MAYA_ETC_DIR" "$UNIT_DIR"
        run systemctl enable maya.service
        run systemctl restart maya.service
        printf '+ wait for /health status=ok and /v1/models to list a loaded model (up to %ss)\n' "$MAYA_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$MAYA_DATA_DIR"
    if [[ -d $MAYA_DIR/.git ]]; then
        verify_source_origin
        # Earlier versions of this script installed as root: hand the tree over.
        chown -R "$SERVICE_USER:$SERVICE_USER" "$MAYA_DIR" "$MAYA_DATA_DIR"
        printf 'Resuming the incomplete Maya checkout at %s.\n' "$MAYA_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$MAYA_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $MAYA_URL ${MAYA_COMMIT:-$MAYA_REF}."
    checkout_local "$target"
    probe_setup_help
    run_setup
    write_unit
    systemctl enable maya.service
    systemctl restart maya.service
    wait_ready || die 'Maya did not become ready.'
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
    systemctl restart maya.service
    wait_ready
}

# Keep a complete runnable checkout at its original absolute path on rollback.
# Models in the separate data directory are not copied. Stop the service before
# taking this snapshot so configs, venv and binaries form one consistent state.
snapshot_runtime() {
    # Snapshots of an earlier revision lived in $MAYA_ETC_DIR.
    rm -f -- "$MAYA_ETC_DIR/rollback-runtime.tar" "$MAYA_ETC_DIR/rollback-runtime.tar.new" "$MAYA_ETC_DIR/rollback.service" "$MAYA_ETC_DIR/rollback.env"
    install -d -m 0700 "$MAYA_STATE_DIR"
    (umask 077
     tar -C "$MAYA_DIR" --exclude='./.git' -cpf "$MAYA_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$MAYA_STATE_DIR/rollback-runtime.tar.new" "$MAYA_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$MAYA_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/maya.service" "$MAYA_STATE_DIR/rollback.service" || return 1
    cp -p -- "$MAYA_ETC_DIR/maya.env" "$MAYA_STATE_DIR/rollback.env"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    rm -f -- "$MAYA_STATE_DIR/rollback-runtime.tar" "$MAYA_STATE_DIR/rollback-runtime.tar.new" "$MAYA_STATE_DIR/rollback.service" "$MAYA_STATE_DIR/rollback.env"
}

# restore_probe_settings: the port from the fingerprint, for installs made
# before installed-env existed.
restore_probe_settings() {
    local port
    port=$(sed -n 's/^port=//p' "$MAYA_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then MAYA_PORT=$port; fi
}

# No setup, pip, compiler or model download is invoked on this path. The
# caller has set the settings the previous runtime ran with (wait_ready uses
# its port).
restore_runtime() {
    set -e
    [[ $MAYA_DIR != / && -d $MAYA_DIR/.git && -s $MAYA_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$MAYA_DIR" reset -q --hard "$1"
    find "$MAYA_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$MAYA_DIR" -xpf "$MAYA_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$MAYA_STATE_DIR/rollback.service" "$UNIT_DIR/maya.service"
    cp -p -- "$MAYA_STATE_DIR/rollback.env" "$MAYA_ETC_DIR/maya.env"
    systemctl daemon-reload
    systemctl restart maya.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$MAYA_URL" "$(dry_run_spec)"
        printf '+ same commit, settings and unit, and /health healthy: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop maya.service; checkout; setup.sh --setup --no-start ...; restart; wait for /health loaded=true\n'
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout, launcher and unit without setup or downloads (%s/rollback-runtime.tar, removed afterwards)\n' "$MAYA_STATE_DIR"
        return 0
    fi
    [[ -d $MAYA_DIR/.git && -f $UNIT_DIR/maya.service ]] ||
        die "No Maya installation at $MAYA_DIR; run without --upgrade first."
    verify_source_origin
    install_cuda_toolkit
    ensure_api_key
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$MAYA_DIR" "$MAYA_DATA_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$MAYA_DIR" update-ref refs/maya/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $MAYA_URL ${MAYA_COMMIT:-$MAYA_REF}; Maya was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching legacy fingerprint is sufficient to migrate its records.
        if [[ ! -f $MAYA_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        printf 'Maya is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Maya %s (settings, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Maya from %s to %s.\n' "$previous" "$target"
    fi
    systemctl stop maya.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$MAYA_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart maya.service; wait_ready) ||
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
        printf 'Maya is running %s.\n' "$(git_root rev-parse HEAD)"
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    systemctl stop maya.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port for older installs). wait_ready checks
    # the restored service on that port.
    if load_settings "$MAYA_ETC_DIR/installed-env"; then
        note "Restoring the settings it last ran with: $(settings_env | tr '\n' ' ')"
    else
        restore_probe_settings
        note 'No record of the previous settings; restoring the complete runtime snapshot.'
    fi
    set +e
    ( restore_runtime "$previous" )
    rc=$?
    set -e
    (( rc == 0 )) || die "Rollback to $previous failed too; inspect journalctl -u maya and $MAYA_DIR; the snapshot is kept in $MAYA_STATE_DIR."
    clear_snapshot
    die "Upgrade failed; Maya is running $previous again."
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
MAYA_REF=${MAYA_REF:-latest}
MAYA_COMMIT=${MAYA_COMMIT:-}
MAYA_CUDA_VERSION=${MAYA_CUDA_VERSION:-12.8}
MAYA_MODEL=${MAYA_MODEL:-Maya-S-v2-IQ2_XXS}
MAYA_CONTEXT=${MAYA_CONTEXT:-32768}
MAYA_DRAFT=${MAYA_DRAFT:-mtp}
MAYA_NVCC=${MAYA_NVCC:-/usr/local/cuda-$MAYA_CUDA_VERSION/bin/nvcc}
MAYA_NO_VISION=${MAYA_NO_VISION:-false}
MAYA_PORT=${MAYA_PORT:-8080}
MAYA_READY_TIMEOUT=${MAYA_READY_TIMEOUT:-900}
[[ $MAYA_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $MAYA_REF != HEAD && $MAYA_REF != *..* ]] || die 'Invalid MAYA_REF.'
[[ -z $MAYA_COMMIT || $MAYA_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid MAYA_COMMIT.'
validate_settings
[[ $MAYA_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid MAYA_READY_TIMEOUT.'
for path_var in MAYA_DIR MAYA_DATA_DIR MAYA_ETC_DIR MAYA_STATE_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/maya.service ]] || die "Missing $source_dir/maya.service"
[[ -r $source_dir/cuda-toolkit.sh ]] || die "Missing $source_dir/cuda-toolkit.sh"
SETUP_HELP=''
api_key='[generated inside CT]'
if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Maya LXC.'
    if [[ -e $MAYA_DIR && ! -d $MAYA_DIR/.git ]] && [[ -n $(ls -A "$MAYA_DIR" 2>/dev/null) ]]; then
        die "$MAYA_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    # Before anything is installed or stopped: is the requested toolkit already
    # installed at MAYA_NVCC, or can this distro's NVIDIA repository provide it?
    CUDA_VERSION="$MAYA_CUDA_VERSION" CUDA_NVCC="$MAYA_NVCC" bash "$source_dir/cuda-toolkit.sh" --check ||
        die "CUDA $MAYA_CUDA_VERSION is not available for this CT's distribution (see above)."
    command -v nvidia-smi >/dev/null || die 'nvidia-smi is missing; install host-matched guest NVIDIA userspace first.'
    nvidia-smi -L || die 'NVIDIA GPU is not accessible inside the CT.'
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Maya is configured on TCP %s; API key: %s/api-key\n' "$MAYA_PORT" "$MAYA_ETC_DIR"
