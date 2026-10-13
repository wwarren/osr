#!/usr/bin/env bash
# Runs inside the dedicated Strata LXC after matching NVIDIA userspace is ready.
#
#   bash install-target.sh             install or update Strata and start it
#   bash install-target.sh --upgrade   move to STRATA_COMMIT or the tip of STRATA_REF;
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
hardened strata systemd service. Re-running fetches STRATA_COMMIT or the
latest STRATA_REF (main by default) before stopping anything: when the commit,
settings and unit are unchanged and Strata is healthy it does nothing;
otherwise it upgrades with rollback to the previous commit on failure.

--upgrade moves an existing install to STRATA_COMMIT (or the current tip of
STRATA_REF), re-runs setup for the configured model (nothing is downloaded
twice), restarts and health-checks the service, and returns to the previous
commit if any step fails.

Environment: STRATA_REF=main, STRATA_COMMIT=<optional full SHA-1 pin>,
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
    key_hash=$(printf '%s' "${api_key:-}" | sha256sum | cut -d' ' -f1)
    printf 'family=%s\nmodel=%s\ncontext=%s\nvision=%s\nport=%s\ndata_dir=%s\nallow_no_key=%s\nkey_sha256=%s\n' \
        "$STRATA_FAMILY" "$STRATA_MODEL" "$STRATA_CONTEXT" "$STRATA_VISION" "$STRATA_PORT" \
        "$STRATA_DATA_DIR" "$STRATA_ALLOW_NO_KEY" "$key_hash"
}

# start_env: the EnvironmentFile path the unit expands into ExecStart.
start_env() {
    printf '# Written by install-target.sh for this Strata checkout; do not edit.\n'
    printf 'STRATA_RUN_SCRIPT=%s\n' "$run_script"
}
# End install helpers. ----------------------------------------------------------

as_service() { runuser -u "$SERVICE_USER" -- env HOME="$STRATA_DATA_DIR" "$@"; }
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
    as_service git -C "$STRATA_DIR" fetch -q --depth 1 origin "${STRATA_COMMIT:-$STRATA_REF}" >&2 || return 1
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

save_settings() {
    (umask 077 && settings_fingerprint > "$STRATA_ETC_DIR/installed-settings")
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

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$STRATA_URL" "${STRATA_COMMIT:-$STRATA_REF}"
        printf '+ same commit, settings and unit, and /health healthy: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop strata.service; checkout; setup.sh --setup --no-start ...; restart; wait for /health loaded=true\n'
        printf '+ on failure: check out the previous commit locally (no network), re-run setup, restart\n'
        return 0
    fi
    [[ -d $STRATA_DIR/.git && -f $UNIT_DIR/strata.service ]] ||
        die "No Strata installation at $STRATA_DIR; run without --upgrade first."
    verify_source_origin
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$STRATA_DIR" "$STRATA_DATA_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$STRATA_DIR" update-ref refs/strata/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $STRATA_URL ${STRATA_COMMIT:-$STRATA_REF}; Strata was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        printf 'Strata is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Strata %s (settings, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Strata from %s to %s.\n' "$previous" "$target"
    fi
    systemctl stop strata.service
    set +e
    ( apply_checkout "$target" )
    rc=$?
    set -e
    if (( rc == 0 )); then
        save_settings
        printf 'Strata is running %s.\n' "$(git_root rev-parse HEAD)"
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    systemctl stop strata.service || true
    set +e
    ( apply_checkout "$previous" )
    rc=$?
    set -e
    (( rc == 0 )) || die "Rollback to $previous failed too; inspect journalctl -u strata and $STRATA_DIR."
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
STRATA_REF=${STRATA_REF:-main}
STRATA_COMMIT=${STRATA_COMMIT:-}
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
[[ $STRATA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STRATA_MODEL.'
# The families are checked against setup.sh --help choices once it is fetched.
[[ $STRATA_FAMILY =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die 'Invalid STRATA_FAMILY.'
[[ $STRATA_CONTEXT =~ ^[1-9][0-9]{0,8}$ ]] || die 'Invalid STRATA_CONTEXT.'
[[ $STRATA_VISION =~ ^(yes|no|gpu|cpu)$ ]] || die 'Invalid STRATA_VISION.'
[[ $STRATA_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( STRATA_PORT <= 65535 )) || die 'Invalid STRATA_PORT.'
[[ $STRATA_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid STRATA_READY_TIMEOUT.'
[[ $STRATA_ALLOW_NO_KEY =~ ^(true|false)$ ]] || die 'STRATA_ALLOW_NO_KEY must be true or false.'
for path_var in STRATA_DIR STRATA_DATA_DIR STRATA_ETC_DIR UNIT_DIR; do
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
    install -d -m 0700 "$STRATA_ETC_DIR"
    if [[ ! -s $STRATA_ETC_DIR/api-key ]]; then
        (umask 077 && openssl rand -hex 32 > "$STRATA_ETC_DIR/api-key")
    fi
    chmod 0600 "$STRATA_ETC_DIR/api-key"
    api_key=$(< "$STRATA_ETC_DIR/api-key")
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Strata is configured on TCP %s; API key: %s/api-key\n' "$STRATA_PORT" "$STRATA_ETC_DIR"
