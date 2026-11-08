#!/usr/bin/env bash
# Inspect the running router installation from its Proxmox host or from a
# separate clone inside the CT, then use the in-container updater to install
# the changed files and restart the affected services.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: bash /path/to/repo/tools/update-router-services.sh [options]

Run as root from any working directory. Choose Proxmox host or inside the
router CT when prompted. Host mode lists running CTs and asks for the router
CT_ID (set CT_ID to skip that prompt). Container mode uses this script's clone
directly; it must be separate from the deployed config repository.

Before updating, the script checks that the target really is a router
installation: the four service units, the runtime files and venv, and the
config repository. Only the standard layout the installer creates is supported
(/app/router, /app/openwebui, units in /etc/systemd/system); anything else is
refused rather than overwritten. The files to send are checked here first
(present, not symlinks, LF line endings).

The existing in-container updater copies changed files into the config repo
and their runtime locations, then restarts and health-checks affected services.

Location options (skip the location prompt):
  --host            run on the Proxmox host
  --container       run from a separate clone inside the router CT

Options passed to the in-container updater:
  --dry-run         show what would change; do not apply or push
  --diff            show the full diff (implies --dry-run)
  --with-tunables   also replace router.ini and monitor.ini
  --no-apply        commit without applying (requirements changes need --no-push)
  --no-push         apply locally without pushing to Gitea
  -h, --help        show this help
USAGE
}

ct_id=${CT_ID:-}
location=''
update_args=()
while (( $# )); do
    case $1 in
        --host|--container)
            [[ -z $location ]] || die 'Choose only one of --host or --container.'
            location=${1#--} ;;
        --dry-run|--diff|--with-tunables|--no-apply|--no-push)
            update_args+=("$1") ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
[[ $(id -u) -eq 0 ]] || die 'Run as root (pct and the in-container updater need it).'
script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -P -- "$script_dir/.." && pwd)
[[ -f $repo_root/ollama-smart-router-install.sh && -f $repo_root/install/update-router.sh ]] ||
    die "Cannot locate the router repository beside this script: $repo_root"

# The in-container updater uses this text list too. Do not source the installer
# on the host: sourcing it would run its provisioning code.
mapfile -t owned < <(sed -n '/^INSTALLER_OWNED_CODE=(/,/^)/p' "$repo_root/ollama-smart-router-install.sh" |
    sed -e '1d' -e '$d' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
    sed '/^$/d')
(( ${#owned[@]} )) || die 'The source installer has no INSTALLER_OWNED_CODE list.'
files=(ollama-smart-router-install.sh install/update-router.sh "${owned[@]}")
for arg in "${update_args[@]}"; do
    if [[ $arg == --with-tunables ]]; then
        files+=(services/ollama-router/router.ini services/ollama-monitor/monitor.ini)
        break
    fi
done
declare -A seen=()
for rel in "${files[@]}"; do
    [[ $rel =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $rel != *..* ]] ||
        die "Unsafe source path: $rel"
    [[ -z ${seen[$rel]:-} ]] || die "Duplicate source path: $rel"
    seen[$rel]=1
    path=$repo_root
    IFS=/ read -r -a parts <<< "$rel"
    for part in "${parts[@]}"; do
        path+=/$part
        [[ ! -L $path ]] || die "Symlinked source path: $rel"
    done
    [[ -f $path ]] || die "Missing source file: $rel"
done

has_carriage_return() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\r'* ]] && return 0
    done < "$1"
    return 1
}
crlf=()
for rel in "${files[@]}"; do
    if has_carriage_return "$repo_root/$rel"; then crlf+=("$rel"); fi
done
if (( ${#crlf[@]} )); then
    printf 'These files have Windows (CRLF) line endings, which bash and systemd cannot use:\n' >&2
    printf '  %s\n' "${crlf[@]}" >&2
    die 'Convert them to LF first (git add --renormalize . after a Windows checkout, or dos2unix).'
fi

if [[ -z $location ]]; then
    printf 'Where is this script running?\n  1) Proxmox host\n  2) Inside the router container\n' >&2
    printf 'Choose 1 or 2: ' >&2
    IFS= read -r answer || die 'No location selected. Use --host or --container for unattended use.'
    case $answer in
        1|host) location=host ;;
        2|container) location=container ;;
        *) die 'Choose 1 for Proxmox host or 2 for inside the container.' ;;
    esac
fi

if [[ $location == host ]]; then
    for command_name in pct tar mktemp; do
        command -v "$command_name" >/dev/null 2>&1 || die "Missing host command: $command_name"
    done
    if [[ -z $ct_id ]]; then
        printf 'Running Proxmox containers:\n'
        pct list || die 'Could not list Proxmox containers.'
        printf 'Router CT_ID: ' >&2
        IFS= read -r ct_id || die 'No CT_ID entered. Set CT_ID for unattended use.'
    fi
    [[ $ct_id =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be a numeric Proxmox CT ID of 100 or more.'
    ct_status=$(pct status "$ct_id") || die "Cannot read status of CT $ct_id."
    [[ $ct_status == 'status: running' ]] || die "CT $ct_id is not running."
    target_label="CT $ct_id"
else
    target_label='this container'
fi

inside() {
    if [[ $location == host ]]; then
        pct exec "$ct_id" -- "$@"
    else
        env "$@"
    fi
}

unit_property() {
    inside systemctl show -p "$2" --value "$1.service"
}
valid_ct_path() { [[ $1 == /* && $1 != *$'\n'* && /$1/ != */../* && /$1/ != */./* ]]; }

unit_dir=''
for service in litellm-proxy ollama-router ollama-monitor open-webui; do
    unit_path=$(unit_property "$service" FragmentPath) || die "Cannot inspect $service.service in $target_label."
    valid_ct_path "$unit_path" && [[ ${unit_path##*/} == "$service.service" ]] ||
        die "$target_label does not have an installed $service.service unit."
    inside test -f "$unit_path" || die "Missing service unit in $target_label: $unit_path"
    if [[ -z $unit_dir ]]; then unit_dir=${unit_path%/*};
    elif [[ ${unit_path%/*} != "$unit_dir" ]]; then
        die "$target_label has service units in different directories; inspect them before updating."
    fi
done
router_dir=$(unit_property ollama-router WorkingDirectory) || die 'Cannot inspect the router working directory.'
monitor_dir=$(unit_property ollama-monitor WorkingDirectory) || die 'Cannot inspect the monitor working directory.'
proxy_dir=$(unit_property litellm-proxy WorkingDirectory) || die 'Cannot inspect the LiteLLM working directory.'
webui_dir=$(unit_property open-webui WorkingDirectory) || die 'Cannot inspect the Open WebUI working directory.'
valid_ct_path "$router_dir" && valid_ct_path "$webui_dir" || die 'A service has an invalid working directory.'
[[ $monitor_dir == "$router_dir" && $proxy_dir == "$router_dir" ]] ||
    die 'The router, monitor, and proxy use different working directories; inspect the installation before updating.'

# Inspect the actual runtime directory rather than trusting a CT name or an
# assumed directory. The repo's unit templates currently install into these
# standard paths; refuse a layout they would overwrite with incorrect paths.
runtime_files=$(inside find "$router_dir" -maxdepth 1 -type f \( -name router.py -o -name monitor.py -o -name litellm_config.yaml \) -printf '%f\n') ||
    die "Cannot scan runtime files in $target_label: $router_dir"
for filename in router.py monitor.py litellm_config.yaml; do
    grep -Fxq -- "$filename" <<< "$runtime_files" || die "$target_label is missing $router_dir/$filename"
done
inside test -f "$router_dir/.env" || die "$target_label is missing $router_dir/.env"
inside test -x "$router_dir/venv/bin/python" || die "$target_label is missing the router Python venv."
[[ $router_dir == /app/router && $webui_dir == /app/openwebui && $unit_dir == /etc/systemd/system ]] ||
    die "$target_label has nonstandard runtime paths ($router_dir, $webui_dir, $unit_dir); the repository's service units target /app/router, /app/openwebui, and /etc/systemd/system."

manager_path=$(inside readlink -f /usr/local/bin/manage-model-servers 2>/dev/null || true)
repo_dir=''
if [[ $manager_path == */install/manage-model-servers.sh ]]; then
    repo_dir=${manager_path%/install/manage-model-servers.sh}
fi
if [[ -z $repo_dir ]]; then
    # Older CTs may lack the PATH symlink. Search common deployment roots.
    candidates=$(inside sh -c 'for base in /app /opt /srv /root; do if [ -d "$base" ]; then find "$base" -maxdepth 5 -type f -path "*/install/manage-model-servers.sh" -print; fi; done') ||
        die "Cannot scan $target_label for its config repository."
    while IFS= read -r candidate; do
        [[ -n $candidate ]] || continue
        root=${candidate%/install/manage-model-servers.sh}
        # In container mode the clone this script runs from also looks like a
        # config repository (often under /root); it is the source, not the target.
        if [[ $location == container && $root -ef $repo_root ]]; then continue; fi
        if inside test -d "$root/.git" >/dev/null 2>&1 &&
           inside test -f "$root/env/router.env" >/dev/null 2>&1; then
            [[ -z $repo_dir ]] || die "$target_label has multiple router config repositories; inspect it before updating."
            repo_dir=$root
        fi
    done <<< "$candidates"
fi
valid_ct_path "$repo_dir" || die "Cannot locate a router config repository in $target_label."
inside test -d "$repo_dir/.git" || die "$target_label has no config repository at $repo_dir."
inside test -f "$repo_dir/env/router.env" || die "$target_label has no router config at $repo_dir."
if [[ $location == container && $repo_dir -ef $repo_root ]]; then
    die "This script runs from the deployed config repository ($repo_dir). Run it from a separate clone."
fi
printf 'Found %s installation: config %s, runtime %s, units %s\n' "$target_label" "$repo_dir" "$router_dir" "$unit_dir"

if [[ $location == container ]]; then
    printf 'Updating this router container from %s\n' "$repo_root"
    CONFIG_REPO_DIR=$repo_dir ROUTER_DIR=$router_dir \
        bash "$repo_root/install/update-router.sh" "${update_args[@]}" "$repo_root"
    exit
fi

local_stage=$(mktemp -d)
remote_stage=''
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n $remote_stage ]]; then
        pct exec "$ct_id" -- rm -rf -- "$remote_stage" >/dev/null 2>&1 ||
            printf 'Warning: could not remove CT staging directory %s\n' "$remote_stage" >&2
    fi
    rm -rf -- "$local_stage"
    exit "$status"
}
trap cleanup EXIT

# Root-owned in the archive: the host clone's UIDs mean nothing inside the CT.
tar --owner=0 --group=0 --numeric-owner -C "$repo_root" -czf "$local_stage/source.tar.gz" -- "${files[@]}"
stage_path=$(pct exec "$ct_id" -- mktemp -d /root/osr-update.XXXXXXXX)
# An unexpected answer is never deleted automatically; it is reported instead.
[[ $stage_path =~ ^/root/osr-update\.[A-Za-z0-9]{8}$ ]] ||
    die "Unexpected CT staging path: $stage_path (not removed; check CT $ct_id by hand)"
remote_stage=$stage_path
pct push "$ct_id" "$local_stage/source.tar.gz" "$remote_stage/source.tar.gz" --perms 0600
pct exec "$ct_id" -- tar --no-same-owner -xzf "$remote_stage/source.tar.gz" -C "$remote_stage"

printf 'Updating router CT %s from %s\n' "$ct_id" "$repo_root"
pct exec "$ct_id" -- env "CONFIG_REPO_DIR=$repo_dir" "ROUTER_DIR=$router_dir" \
    bash "$remote_stage/install/update-router.sh" "${update_args[@]}"
