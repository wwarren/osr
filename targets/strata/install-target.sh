#!/usr/bin/env bash
# Runs inside the dedicated Strata LXC after matching NVIDIA userspace is ready.
#
#   bash install-target.sh             install or update Strata and start it
#   bash install-target.sh --upgrade   move to STRATA_COMMIT or an explicit STRATA_REF;
#                                      roll back to the previous commit on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# Strata's setup.sh options differ between releases (the docs list --host,
# --api-key and --data-dir; some checkouts do not accept them). This script
# reads the checked-out setup.sh --help and passes only options it supports,
# and refuses to continue when a required one is missing instead of guessing.
set -Eeuo pipefail

STRATA_URL=https://github.com/Niko1221/Strata.git
# Paths are overridable for tests only; the unit file uses the defaults.
STRATA_DIR=${STRATA_DIR:-/opt/strata}
STRATA_DATA_DIR=${STRATA_DATA_DIR:-/var/lib/strata}
STRATA_ETC_DIR=${STRATA_ETC_DIR:-/etc/strata-target}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
STRATA_STATE_DIR=${STRATA_STATE_DIR:-/var/lib/strata-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-strata}
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
Installs Strata from https://github.com/Niko1221/Strata.git as the "strata"
service account, sets up the model with upstream setup.sh, and starts the
hardened strata systemd service. Re-running fetches the tested default commit,
an explicit STRATA_COMMIT or the tip of an explicit STRATA_REF before stopping
anything. When the commit, settings and unit are unchanged and Strata is healthy
it does nothing;
otherwise it upgrades with rollback to the previous commit on failure.

--upgrade moves an existing install to STRATA_COMMIT (or the current tip of
STRATA_REF), re-runs setup for the configured model (nothing is downloaded
twice), restarts and health-checks the service, and returns to the previous
commit if any step fails.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or installed-settings for older installs); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment: STRATA_COMMIT=a0116b2782a5b82622358c04a06496485d12b2d6 (tested default),
STRATA_REF=<branch or tag> (follow it when no commit is set); STRATA_COMMIT=
explicitly follows main,
STRATA_MODEL=IQ2_XS (IQ1_M for coder, UD-IQ4_XS for unsloth), STRATA_FAMILY=qwen (any family the
checkout's setup.sh lists, e.g. swift, coder, unsloth), STRATA_CONTEXT=32768,
STRATA_VISION=no, STRATA_PORT=8080, STRATA_READY_TIMEOUT=900 (seconds),
STRATA_ALLOW_NO_KEY=false (true: accept a checkout without --api-key support).
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
        die "This Strata checkout does not accept $1 $2 (it offers: $choices). Choose one of those, or pin STRATA_REF/STRATA_COMMIT to a release that has it."
}

# validate_setup_options: every option this installer depends on must exist.
validate_setup_options() {
    local flag
    local -a missing=()
    for flag in --setup --no-start --yes --model --port --host; do
        help_has "$flag" || missing+=("$flag")
    done
    if ! help_has --api-key && [[ $STRATA_ALLOW_NO_KEY != true ]]; then
        missing+=(--api-key)
    fi
    (( ${#missing[@]} == 0 )) ||
        die "This Strata checkout's setup.sh does not accept: ${missing[*]}. The router reaches Strata over the network (--host) with a key (--api-key); without them the API listens on 127.0.0.1 only or unauthenticated. Pin STRATA_REF/STRATA_COMMIT to a release that supports them (set STRATA_ALLOW_NO_KEY=true to accept a keyless API)."
    help_has --family || [[ $STRATA_FAMILY == qwen ]] ||
        die "This Strata checkout has no --family option, so STRATA_FAMILY=$STRATA_FAMILY cannot be selected."
    check_choice --family "$STRATA_FAMILY"
    check_choice --model "$STRATA_MODEL"
    check_choice --vision "$STRATA_VISION"
}

# setup_args: setup.sh arguments, one per line, for installing or refreshing
# the model without starting it. The service uses upstream's run-<model>.sh.
# The API key is never included here: it would end up in the unit and in logs.
setup_args() {
    printf '%s\n' --setup --no-start
    printf '%s\n' --yes
    if help_has --no-browser; then printf '%s\n' --no-browser; fi
    if help_has --family; then printf '%s\n' --family "$STRATA_FAMILY"; fi
    printf '%s\n' --model "$STRATA_MODEL"
    if help_has --context; then printf '%s\n' --context "$STRATA_CONTEXT"; fi
    if help_has --vision; then printf '%s\n' --vision "$STRATA_VISION"; fi
    printf '%s\n' --host 0.0.0.0 --port "$STRATA_PORT"
    if help_has --data-dir; then
        printf '%s\n' --data-dir "$STRATA_DATA_DIR"
    elif help_has --models-dir; then
        printf '%s\n' --models-dir "$STRATA_DATA_DIR/models"
    fi
}

# select_run_script LOG MARKER: the launcher setup.py just generated. Setup
# prints "start script: run-<model>.sh"; when that line is missing (reworded in
# another release), fall back to the one run-*.sh written after MARKER was
# touched. Refuse an ambiguous or missing launcher rather than starting an
# older model's script.
select_run_script() {
    local log_file=$1 marker=${2:-} line name candidate found=''
    local -a fresh=()
    while IFS= read -r line; do
        [[ $line =~ start[[:space:]]script:[[:space:]]*(run-[a-z0-9._-]+\.sh) ]] || continue
        name=${BASH_REMATCH[1]}
        if [[ -n $found && $found != "$name" ]]; then
            printf 'Error: Strata setup reported more than one run script.\n' >&2
            return 1
        fi
        found=$name
    done < "$log_file"
    if [[ -z $found && -n $marker && -e $marker ]]; then
        mapfile -t fresh < <(find "$STRATA_DIR" -maxdepth 1 -type f -name 'run-*.sh' -newer "$marker" -printf '%f\n')
        if (( ${#fresh[@]} == 1 )); then
            found=${fresh[0]}
            printf 'Note: setup did not name its start script; using %s, the launcher it just wrote.\n' "$found" >&2
        elif (( ${#fresh[@]} > 1 )); then
            printf 'Error: Strata setup wrote several run scripts (%s) and named none of them.\n' "${fresh[*]}" >&2
            return 1
        fi
    fi
    if [[ -z $found ]]; then
        printf 'Error: Strata setup did not report or write a run-<model>.sh script.\n' >&2
        return 1
    fi
    candidate=$STRATA_DIR/$found
    if [[ ! -f $candidate || ! -x $candidate || -L $candidate ]]; then
        printf 'Error: Strata did not generate an executable %s.\n' "$candidate" >&2
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
        "$STRATA_FAMILY" "$STRATA_MODEL" "$STRATA_CONTEXT" "$STRATA_VISION" "$STRATA_PORT" \
        "$STRATA_DATA_DIR" "$STRATA_ALLOW_NO_KEY" "$key_hash"
}

# The settings that decide how setup runs. save_settings records them after
# every successful install or upgrade, so a failed upgrade can roll back to
# what last worked rather than re-running setup with the settings that failed.
SETTING_KEYS=(STRATA_FAMILY STRATA_MODEL STRATA_CONTEXT STRATA_VISION STRATA_PORT STRATA_ALLOW_NO_KEY)

# validate_settings: die unless every setting has a value this script accepts.
# (Family, model and vision are also checked against setup.sh --help later.)
validate_settings() {
    [[ $STRATA_FAMILY =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die 'Invalid STRATA_FAMILY.'
    [[ $STRATA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STRATA_MODEL.'
    [[ $STRATA_CONTEXT =~ ^[1-9][0-9]{0,8}$ ]] || die 'Invalid STRATA_CONTEXT.'
    [[ $STRATA_VISION =~ ^(yes|no|gpu|cpu)$ ]] || die 'Invalid STRATA_VISION.'
    [[ $STRATA_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( STRATA_PORT <= 65535 )) || die 'Invalid STRATA_PORT.'
    [[ $STRATA_ALLOW_NO_KEY =~ ^(true|false)$ ]] || die 'STRATA_ALLOW_NO_KEY must be true or false.'
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
        [[ $line =~ ^(STRATA_[A-Z_]+)=(.*)$ ]] || continue
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
    printf '# Written by install-target.sh for this Strata checkout; do not edit.\n'
    printf 'STRATA_RUN_SCRIPT=%s\n' "$run_script"
}

# fingerprint_env FILE: an installed-settings fingerprint (written by every
# version of this script) as the KEY=value lines load_settings reads.
fingerprint_env() {
    sed -n -e 's/^family=/STRATA_FAMILY=/p' \
        -e 's/^model=/STRATA_MODEL=/p' \
        -e 's/^context=/STRATA_CONTEXT=/p' \
        -e 's/^vision=/STRATA_VISION=/p' \
        -e 's/^port=/STRATA_PORT=/p' \
        -e 's/^allow_no_key=/STRATA_ALLOW_NO_KEY=/p' "$1"
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
    if [[ -e $STRATA_ETC_DIR/installed-env ]]; then
        load_settings "$STRATA_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $STRATA_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $STRATA_ETC_DIR/installed-settings || -L $STRATA_ETC_DIR/installed-settings ||
            -e $STRATA_ETC_DIR/pending-env || -L $STRATA_ETC_DIR/pending-env ||
            -e $STRATA_DIR/.git || -L $STRATA_DIR/.git ||
            -e $UNIT_DIR/strata.service || -L $UNIT_DIR/strata.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $STRATA_ETC_DIR/installed-settings && -r $STRATA_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$STRATA_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $STRATA_ETC_DIR/installed-settings (an install from before installed-env)."
        elif [[ ! -e $STRATA_ETC_DIR/installed-settings && ! -L $STRATA_ETC_DIR/installed-settings &&
                -f $STRATA_ETC_DIR/pending-env && -r $STRATA_ETC_DIR/pending-env ]] &&
                load_settings "$STRATA_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($STRATA_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $STRATA_ETC_DIR/installed-settings || -L $STRATA_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $STRATA_ETC_DIR/installed-settings"
            else
                missing="Found an existing Strata installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $STRATA_ETC_DIR)"
            fi
            for key in "${SETTING_KEYS[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${SETTING_KEYS[*]} explicitly, or restore a record."
            done
        fi
    fi
    # A different family needs its own default model unless one is given (the
    # saved model may not exist for it, and setup would fail after the stop).
    if [[ -v overrides[STRATA_FAMILY] && ! -v overrides[STRATA_MODEL] &&
          ${overrides[STRATA_FAMILY]} != "${STRATA_FAMILY:-}" ]]; then
        unset STRATA_MODEL
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
        runuser -u "$SERVICE_USER" -- env HOME="$STRATA_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$STRATA_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$STRATA_DIR" -C "$STRATA_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$STRATA_URL" ]] || die "Existing $STRATA_DIR origin is not official: $origin"
}

# Fetch STRATA_COMMIT (or the tip of STRATA_REF) into FETCH_HEAD without
# touching the checkout, and print the fetched commit. A fetch by commit works
# for any commit, not only a branch tip.
fetch_target() {
    local fetched
    if [[ ! -d $STRATA_DIR/.git ]]; then
        as_service git init -q "$STRATA_DIR"
        as_service git -C "$STRATA_DIR" remote add origin "$STRATA_URL"
    fi
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$STRATA_DIR" fetch -q --depth 1 origin "${STRATA_COMMIT:-$STRATA_REF}" >&2 || return 1
    fetched=$(git_root rev-parse FETCH_HEAD) || return 1
    if [[ -n $STRATA_COMMIT && ${fetched,,} != "${STRATA_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $STRATA_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$STRATA_DIR" checkout -q --detach "$1"
    printf 'Strata source commit: %s\n' "$(git_root rev-parse HEAD)"
}

probe_setup_help() {
    # setup.sh creates its .venv on first use, then prints argparse help.
    SETUP_HELP=$(cd "$STRATA_DIR" && as_service bash ./setup.sh --help 2>&1) ||
        die "bash setup.sh --help failed in $STRATA_DIR:"$'\n'"$SETUP_HELP"
    validate_setup_options
}

run_setup() {
    local -a args
    local setup_log marker
    mapfile -t args < <(setup_args)
    setup_log=$(mktemp "$STRATA_ETC_DIR/setup-output.XXXXXX")
    # A second in the past, so a launcher written in the same second still
    # counts as newer on filesystems with coarse timestamps.
    marker=$(mktemp "$STRATA_ETC_DIR/setup-start.XXXXXX")
    touch -d "@$(( $(date +%s) - 1 ))" "$marker"
    if help_has --api-key; then
        printf '+ bash setup.sh %s --api-key [redacted]\n' "${args[*]}"
        if ! (cd "$STRATA_DIR" && umask 027 && as_service bash ./setup.sh "${args[@]}" --api-key "$api_key") 2>&1 | tee "$setup_log"; then
            rm -f "$setup_log" "$marker"
            return 1
        fi
    else
        note "WARNING: this Strata checkout has no --api-key option; its API is unauthenticated."
        printf '+ bash setup.sh %s\n' "${args[*]}"
        if ! (cd "$STRATA_DIR" && umask 027 && as_service bash ./setup.sh "${args[@]}") 2>&1 | tee "$setup_log"; then
            rm -f "$setup_log" "$marker"
            return 1
        fi
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
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Strata LXC.'
    [[ $STRATA_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $STRATA_ETC_DIR != *..* ]] || die 'Invalid STRATA_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$STRATA_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another Strata installer is already running (or a process it started still holds the lock).'
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
    install -d -m 0700 "$STRATA_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$STRATA_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$STRATA_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$STRATA_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$STRATA_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$STRATA_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$STRATA_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$STRATA_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    # installed.service was written by an earlier revision and is not used.
    rm -f -- "$STRATA_ETC_DIR/installed.service" "$STRATA_ETC_DIR/pending-env" || return 1
    sync -- "$STRATA_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$STRATA_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$STRATA_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $STRATA_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$STRATA_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$STRATA_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$STRATA_ETC_DIR/api-key"
    sync -- "$STRATA_ETC_DIR/api-key" "$STRATA_ETC_DIR" || return 1
    api_key=$(< "$STRATA_ETC_DIR/api-key")
}

# Unchanged since the last successful install or upgrade, and serving?
nothing_to_do() {
    [[ -f $STRATA_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$STRATA_ETC_DIR/installed-settings")" ]] &&
        cmp -s "$source_dir/strata.service" "$UNIT_DIR/strata.service" &&
        systemctl is-active --quiet strata.service &&
        probe_health
}

write_unit() {
    start_env > "$STRATA_ETC_DIR/strata.env"
    chmod 0644 "$STRATA_ETC_DIR/strata.env"
    install -m 0644 "$source_dir/strata.service" "$UNIT_DIR/strata.service"
    systemctl daemon-reload
}

# Upstream answers /health without a key. A 200 alone is insufficient: the
# response can report loaded=false while the engine is still coming up.
probe_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${STRATA_PORT}/health" 2>/dev/null |
        python3 -c 'import json,sys; h=json.load(sys.stdin); sys.exit(0 if h.get("status") == "ok" and h.get("loaded") is True else 1)' \
            >/dev/null 2>&1
}

wait_ready() {
    local deadline=$(( SECONDS + STRATA_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        probe_health && return 0
        if systemctl is-failed --quiet strata.service; then
            note "strata.service failed; see journalctl -u strata."
            return 1
        fi
        sleep 5
    done
    note "Strata has not answered on port $STRATA_PORT within ${STRATA_READY_TIMEOUT}s; see journalctl -u strata."
    return 1
}

ensure_service_user() {
    local node group
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$STRATA_DATA_DIR" \
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

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $STRATA_DIR/.git && -f $UNIT_DIR/strata.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 python3-venv python3-pip
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s\n' "$SERVICE_USER" "$GPU_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$STRATA_URL" "${STRATA_COMMIT:-$STRATA_REF}" "$STRATA_DIR" "$SERVICE_USER"
        printf '+ bash setup.sh --help: keep only the options this checkout supports\n'
        printf '+ bash setup.sh --setup --no-start --yes [--no-browser] [--family %s] --model %s [--context %s] [--vision %s] --host 0.0.0.0 --port %s [--data-dir %s] --api-key [redacted]\n' \
            "$STRATA_FAMILY" "$STRATA_MODEL" "$STRATA_CONTEXT" "$STRATA_VISION" "$STRATA_PORT" "$STRATA_DATA_DIR"
        printf '+ verify setup generated run-<model>.sh; write %s/strata.env (STRATA_RUN_SCRIPT) and %s/strata.service\n' "$STRATA_ETC_DIR" "$UNIT_DIR"
        run systemctl enable strata.service
        run systemctl restart strata.service
        printf '+ wait for http://127.0.0.1:%s/health to report loaded=true (up to %ss)\n' "$STRATA_PORT" "$STRATA_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -m 0700 "$STRATA_ETC_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$STRATA_DATA_DIR"
    if [[ -d $STRATA_DIR/.git ]]; then
        verify_source_origin
        # Earlier versions of this script installed as root: hand the tree over.
        chown -R "$SERVICE_USER:$SERVICE_USER" "$STRATA_DIR" "$STRATA_DATA_DIR"
        printf 'Resuming the incomplete Strata checkout at %s.\n' "$STRATA_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$STRATA_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $STRATA_URL ${STRATA_COMMIT:-$STRATA_REF}."
    checkout_local "$target"
    probe_setup_help
    run_setup
    write_unit
    systemctl enable strata.service
    systemctl restart strata.service
    wait_ready || die 'Strata did not become ready.'
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
    systemctl restart strata.service
    wait_ready
}

# Keep a complete runnable checkout at its original absolute path on rollback.
# Models in the separate data directory are not copied. Stop the service before
# taking this snapshot so configs, venv and binaries form one consistent state.
snapshot_runtime() {
    # Snapshots of an earlier revision lived in $STRATA_ETC_DIR.
    rm -f -- "$STRATA_ETC_DIR/rollback-runtime.tar" "$STRATA_ETC_DIR/rollback-runtime.tar.new" "$STRATA_ETC_DIR/rollback.service" "$STRATA_ETC_DIR/rollback.env"
    install -d -m 0700 "$STRATA_STATE_DIR"
    (umask 077
     tar -C "$STRATA_DIR" --exclude='./.git' -cpf "$STRATA_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$STRATA_STATE_DIR/rollback-runtime.tar.new" "$STRATA_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$STRATA_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/strata.service" "$STRATA_STATE_DIR/rollback.service" || return 1
    cp -p -- "$STRATA_ETC_DIR/strata.env" "$STRATA_STATE_DIR/rollback.env"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    rm -f -- "$STRATA_STATE_DIR/rollback-runtime.tar" "$STRATA_STATE_DIR/rollback-runtime.tar.new" "$STRATA_STATE_DIR/rollback.service" "$STRATA_STATE_DIR/rollback.env"
}

# restore_probe_settings: the port from the fingerprint, for installs made
# before installed-env existed.
restore_probe_settings() {
    local port
    port=$(sed -n 's/^port=//p' "$STRATA_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then STRATA_PORT=$port; fi
}

# No setup, pip, compiler or model download is invoked on this path. The
# caller has set the settings the previous runtime ran with (wait_ready uses
# its port).
restore_runtime() {
    set -e
    [[ $STRATA_DIR != / && -d $STRATA_DIR/.git && -s $STRATA_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$STRATA_DIR" reset -q --hard "$1"
    find "$STRATA_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$STRATA_DIR" -xpf "$STRATA_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$STRATA_STATE_DIR/rollback.service" "$UNIT_DIR/strata.service"
    cp -p -- "$STRATA_STATE_DIR/rollback.env" "$STRATA_ETC_DIR/strata.env"
    systemctl daemon-reload
    systemctl restart strata.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$STRATA_URL" "${STRATA_COMMIT:-$STRATA_REF}"
        printf '+ same commit, settings and unit, and /health healthy: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop strata.service; checkout; setup.sh --setup --no-start ...; restart; wait for /health loaded=true\n'
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout, launcher and unit without setup or downloads (%s/rollback-runtime.tar, removed afterwards)\n' "$STRATA_STATE_DIR"
        return 0
    fi
    [[ -d $STRATA_DIR/.git && -f $UNIT_DIR/strata.service ]] ||
        die "No Strata installation at $STRATA_DIR; run without --upgrade first."
    verify_source_origin
    ensure_api_key
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$STRATA_DIR" "$STRATA_DATA_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$STRATA_DIR" update-ref refs/strata/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $STRATA_URL ${STRATA_COMMIT:-$STRATA_REF}; Strata was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching legacy fingerprint is sufficient to migrate its records.
        if [[ ! -f $STRATA_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        printf 'Strata is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Strata %s (settings, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Strata from %s to %s.\n' "$previous" "$target"
    fi
    systemctl stop strata.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$STRATA_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart strata.service; wait_ready) ||
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
        printf 'Strata is running %s.\n' "$(git_root rev-parse HEAD)"
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    systemctl stop strata.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port for older installs). wait_ready checks
    # the restored service on that port.
    if load_settings "$STRATA_ETC_DIR/installed-env"; then
        note "Restoring the settings it last ran with: $(settings_env | tr '\n' ' ')"
    else
        restore_probe_settings
        note 'No record of the previous settings; restoring the complete runtime snapshot.'
    fi
    set +e
    ( restore_runtime "$previous" )
    rc=$?
    set -e
    (( rc == 0 )) || die "Rollback to $previous failed too; inspect journalctl -u strata and $STRATA_DIR; the snapshot is kept in $STRATA_STATE_DIR."
    clear_snapshot
    die "Upgrade failed; Strata is running $previous again."
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
# A fresh invocation without a commit or ref uses the tested source. An
# explicit ref, or an explicitly empty commit, keeps branch-based upgrades
# available without silently following an upstream change by default.
STRATA_DEFAULT_COMMIT=a0116b2782a5b82622358c04a06496485d12b2d6
if [[ ! ${STRATA_COMMIT+x} && ! ${STRATA_REF+x} ]]; then
    STRATA_COMMIT=$STRATA_DEFAULT_COMMIT
else
    STRATA_COMMIT=${STRATA_COMMIT:-}
fi
STRATA_REF=${STRATA_REF:-main}
STRATA_FAMILY=${STRATA_FAMILY:-qwen}
# Default model per family (upstream offers IQ1_M only for coder and the
# UD-* packs only for unsloth).
case $STRATA_FAMILY in
    coder) STRATA_MODEL=${STRATA_MODEL:-IQ1_M} ;;
    unsloth) STRATA_MODEL=${STRATA_MODEL:-UD-IQ4_XS} ;;
    *) STRATA_MODEL=${STRATA_MODEL:-IQ2_XS} ;;
esac
STRATA_CONTEXT=${STRATA_CONTEXT:-32768}
STRATA_VISION=${STRATA_VISION:-no}
STRATA_PORT=${STRATA_PORT:-8080}
STRATA_READY_TIMEOUT=${STRATA_READY_TIMEOUT:-900}
STRATA_ALLOW_NO_KEY=${STRATA_ALLOW_NO_KEY:-false}
[[ $STRATA_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $STRATA_REF != HEAD && $STRATA_REF != *..* ]] || die 'Invalid STRATA_REF.'
[[ -z $STRATA_COMMIT || $STRATA_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid STRATA_COMMIT.'
# The families are checked against setup.sh --help choices once it is fetched.
validate_settings
[[ $STRATA_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid STRATA_READY_TIMEOUT.'
for path_var in STRATA_DIR STRATA_DATA_DIR STRATA_ETC_DIR STRATA_STATE_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/strata.service ]] || die "Missing $source_dir/strata.service"
SETUP_HELP=''
api_key='[generated inside CT]'
if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Strata LXC.'
    if [[ -e $STRATA_DIR && ! -d $STRATA_DIR/.git ]] && [[ -n $(ls -A "$STRATA_DIR" 2>/dev/null) ]]; then
        die "$STRATA_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    command -v nvidia-smi >/dev/null || die 'nvidia-smi is missing; install host-matched guest NVIDIA userspace first.'
    nvidia-smi -L || die 'NVIDIA GPU is not accessible inside the CT.'
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Strata is configured on TCP %s; API key: %s/api-key\n' "$STRATA_PORT" "$STRATA_ETC_DIR"
