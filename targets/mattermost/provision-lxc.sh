#!/usr/bin/env bash
# Run on the PVE host to create a Mattermost server for the router's alerts.
# The CT and the install come from the Proxmox VE community script
# (ct/mattermost.sh), run with this target's settings preset. Then
# install-target.sh sets Mattermost up inside the CT with mmctl in local mode:
# an administrator, a team, the alert channel and the incoming webhook the
# router's health monitor posts to (see README.md). --create-only stops after
# the community script and prints the browser steps instead.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
readonly COMMUNITY_SCRIPT_DEFAULT_URL=https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/mattermost.sh
usage() {
    cat <<'USAGE'
Usage: bash targets/mattermost/provision-lxc.sh [--dry-run] [--create-only | --reconfigure]

Runs the community script
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/mattermost.sh)"
with the settings below preset as its var_* variables. It creates an
unprivileged Ubuntu 24.04 CT with PostgreSQL 16 and Mattermost from
Mattermost's apt repository, serving http://<CT address>:8065. This script
waits for the server to answer, then runs install-target.sh in the CT: the
administrator MATTERMOST_ADMIN_USER (password in
/etc/mattermost-target/admin-password), the team MATTERMOST_TEAM, the channel
MATTERMOST_CHANNEL and an incoming webhook whose URL is written to
/etc/mattermost-target/webhook-url.

The community script still shows its own menu; pick "Default" (or "My
Defaults") to accept the presets below.

Settings (environment; all optional):
  CT_ID=<next free>  CT_HOSTNAME=mattermost  CORES=2  MEMORY_MB=4096  ROOTFS_GB=16
  TEMPLATE_STORAGE=<vztmpl storage>  STORAGE=<rootdir storage>
  BRIDGE=vmbr0  IP_CIDR=<a.b.c.d/nn|dhcp>  GATEWAY=<a.b.c.d>
  NAMESERVER=<a.b.c.d>  VLAN_TAG=<1-4094>  SSH_PUBLIC_KEY=<file>
  MATTERMOST_CHANNEL=ollama-monitor   the alert channel (its URL name)
  MATTERMOST_TEAM=ollama  MATTERMOST_ADMIN_USER=mmadmin  MATTERMOST_ADMIN_EMAIL
  READY_TIMEOUT=120                   seconds to wait for Mattermost to answer
  MATTERMOST_CT_VERSION=24.04         the CT's Ubuntu release: 22.04, 24.04 or 26.04
                                      (Mattermost's apt repository is Ubuntu-only)
  COMMUNITY_SCRIPT_URL=<url>          default: the ProxmoxVE main-branch ct/mattermost.sh
  COMMUNITY_SCRIPT_SHA256=<hex>       refuse to run a script with any other checksum
The checksum pins ct/mattermost.sh only: that script downloads the shared
build.func and install/mattermost-install.sh from the community repositories
when it runs.
--dry-run validates inputs and prints the commands without running anything.
--create-only creates the CT only and prints the browser setup steps.
--reconfigure runs install-target.sh again in the existing CT_ID (no community
script), e.g. to repair the setup or after a failed first run.
USAGE
}

# Container configuration helpers (read-only).
positive_int() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
ipv4() {
    local value=$1 octet
    local -a octets
    [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
}
valid_container_id() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( $1 >= 100 )); }
valid_container_ip() {
    local address prefix
    [[ $1 != dhcp ]] || return 0
    [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    ipv4 "$address" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 ))
}
# The community script's var_* presets for these settings, one NAME=value per line.
community_vars() {
    printf '%s\n' "var_ctid=$CT_ID" "var_hostname=$CT_HOSTNAME" "var_cpu=$CORES" "var_ram=$MEMORY_MB" \
        "var_disk=$ROOTFS_GB" "var_unprivileged=1" "var_nesting=1" "var_gpu=no" "var_brg=$BRIDGE" \
        "var_os=ubuntu" "var_version=$MATTERMOST_CT_VERSION"
    [[ -z $IP_CIDR ]] || printf '%s\n' "var_net=$IP_CIDR"
    [[ -z $GATEWAY || $IP_CIDR == dhcp ]] || printf '%s\n' "var_gateway=$GATEWAY"
    [[ -z $NAMESERVER ]] || printf '%s\n' "var_ns=$NAMESERVER"
    [[ -z $VLAN_TAG ]] || printf '%s\n' "var_vlan=$VLAN_TAG"
    [[ -z $TEMPLATE_STORAGE ]] || printf '%s\n' "var_template_storage=$TEMPLATE_STORAGE"
    [[ -z $STORAGE ]] || printf '%s\n' "var_container_storage=$STORAGE"
    if [[ -n $SSH_PUBLIC_KEY ]]; then
        # The community script takes the key itself, not a path.
        printf '%s\n' "var_ssh=yes" "var_ssh_authorized_key=$(head -n1 -- "$SSH_PUBLIC_KEY" 2>/dev/null || printf '%s' "$SSH_PUBLIC_KEY")"
    fi
    return 0
}
# End container configuration helpers.

dry_run=0
mode=full
while (( $# )); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --create-only) [[ $mode == full ]] || die 'Use only one of --create-only and --reconfigure.'; mode=create ;;
        --reconfigure) [[ $mode == full ]] || die 'Use only one of --create-only and --reconfigure.'; mode=reconfigure ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

CT_ID=${CT_ID:-}
CT_HOSTNAME=${CT_HOSTNAME:-mattermost}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-4096}
ROOTFS_GB=${ROOTFS_GB:-16}
STORAGE=${STORAGE:-}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-}
BRIDGE=${BRIDGE:-vmbr0}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
MATTERMOST_CHANNEL=${MATTERMOST_CHANNEL:-ollama-monitor}
READY_TIMEOUT=${READY_TIMEOUT:-120}
COMMUNITY_SCRIPT_URL=${COMMUNITY_SCRIPT_URL:-$COMMUNITY_SCRIPT_DEFAULT_URL}
COMMUNITY_SCRIPT_SHA256=${COMMUNITY_SCRIPT_SHA256:-}
MATTERMOST_CT_VERSION=${MATTERMOST_CT_VERSION:-24.04}
# Host paths, overridable for the tests only.
PVE_NODES_DIR=${PVE_NODES_DIR:-/etc/pve/nodes}
SYS_NET_DIR=${SYS_NET_DIR:-/sys/class/net}

[[ $mode != reconfigure || -n $CT_ID ]] || die '--reconfigure needs the existing CT_ID.'
if [[ -z $CT_ID ]]; then
    (( dry_run )) || CT_ID=$(pvesh get /cluster/nextid 2>/dev/null || true)
    [[ -n $CT_ID ]] || die 'Set CT_ID (the next free ID could not be read from the cluster).'
fi
valid_container_id "$CT_ID" || die 'CT_ID must be a numeric ID of 100 or more.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
for name in CORES MEMORY_MB ROOTFS_GB READY_TIMEOUT; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 2048 )) || die 'MEMORY_MB must be at least 2048 (Mattermost plus PostgreSQL).'
(( ROOTFS_GB >= 8 )) || die 'ROOTFS_GB must be at least 8.'
[[ -z $STORAGE || $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ -z $IP_CIDR ]] || valid_container_ip "$IP_CIDR" || die 'IP_CIDR must be a.b.c.d/nn or dhcp.'
[[ -z $GATEWAY ]] || ipv4 "$GATEWAY" || die 'GATEWAY must be an IPv4 address.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY || $dry_run == 1 ]] || die "SSH_PUBLIC_KEY is not readable: $SSH_PUBLIC_KEY"
[[ $MATTERMOST_CHANNEL =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || die 'MATTERMOST_CHANNEL must be a channel name (lowercase letters, digits, - and _).'
[[ $COMMUNITY_SCRIPT_URL =~ ^https://[A-Za-z0-9./_-]+\.sh$ ]] || die 'COMMUNITY_SCRIPT_URL must be an https URL of a .sh file.'
[[ -z $COMMUNITY_SCRIPT_SHA256 || $COMMUNITY_SCRIPT_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMMUNITY_SCRIPT_SHA256 must be 64 hex digits.'
# 26.04 remains selectable for future testing, but Mattermost does not currently support it.
[[ $MATTERMOST_CT_VERSION =~ ^(22\.04|24\.04|26\.04)$ ]] ||
    die 'MATTERMOST_CT_VERSION must be 22.04, 24.04 or 26.04 (Mattermost publishes for Ubuntu only).'
[[ -z $TEMPLATE_STORAGE || $TEMPLATE_STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid TEMPLATE_STORAGE.'
if [[ $mode != reconfigure ]]; then
    pve_select_storage TEMPLATE_STORAGE vztmpl 0
    pve_select_storage STORAGE rootdir "$ROOTFS_GB"
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy=/root/mattermost-target-deploy
if [[ $mode != create ]]; then
    [[ -r $source_dir/install-target.sh ]] || die "Missing $source_dir/install-target.sh."
    # The guest installer checks its own settings; a bad name fails here, before
    # anything is created.
    bash "$source_dir/install-target.sh" --dry-run >/dev/null || die 'Invalid Mattermost settings (see above).'
fi
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
mapfile -t presets < <(community_vars)

if (( ! dry_run )); then
    # id, not $EUID, so the tests can run the whole flow without root.
    [[ $(id -u) == 0 ]] || die 'Run as root on the intended PVE host.'
    for command_name in pveversion pct pvesh curl sha256sum; do command -v "$command_name" >/dev/null || die "Missing command: $command_name"; done
    [[ -d $PVE_NODES_DIR ]] || die '/etc/pve is unavailable; do not create a CT until the cluster filesystem is ready.'
    if [[ $mode == reconfigure ]]; then
        pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "CT $CT_ID is not a running CT on this host."
    else
        pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "ID $CT_ID is unavailable in this cluster."
        [[ -d $SYS_NET_DIR/$BRIDGE ]] || die "Bridge interface is not present: $BRIDGE"
    fi
fi

address='<CT address>'
if [[ $mode != reconfigure ]]; then
    script=$(mktemp "${TMPDIR:-/tmp}/community-mattermost.XXXXXX")
    trap 'rm -f -- "$script"' EXIT
    run curl -fsSL -o "$script" "$COMMUNITY_SCRIPT_URL"
    if (( ! dry_run )); then
        actual=$(sha256sum "$script" | awk '{ print $1 }')
        printf 'Community script %s\n  sha256 %s\n' "$COMMUNITY_SCRIPT_URL" "$actual"
        if [[ -n $COMMUNITY_SCRIPT_SHA256 && $actual != "${COMMUNITY_SCRIPT_SHA256,,}" ]]; then
            die "The community script changed (expected $COMMUNITY_SCRIPT_SHA256). Review it, then update COMMUNITY_SCRIPT_SHA256."
        fi
    fi
    # The community script is interactive: it needs this terminal, not a pipe.
    run env "${presets[@]}" bash "$script"

    address='<CT address>'
    if (( dry_run )); then
        printf '+ wait up to %ss for http://127.0.0.1:8065/api/v4/system/ping inside CT %s\n' "$READY_TIMEOUT" "$CT_ID"
    else
        pct status "$CT_ID" >/dev/null 2>&1 || die "The community script did not create CT $CT_ID (did you change the ID in its menu?)."
        deadline=$(( SECONDS + READY_TIMEOUT ))
        until pct exec "$CT_ID" -- curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:8065/api/v4/system/ping 2>/dev/null; do
            (( SECONDS < deadline )) ||
                die "Mattermost in CT $CT_ID did not answer on port 8065 within ${READY_TIMEOUT}s; see: pct exec $CT_ID -- journalctl -u mattermost"
            sleep 5
        done
        address=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{ print $1 }')
        [[ -n $address ]] || address='<CT address>'
        printf 'Mattermost is answering in CT %s.\n' "$CT_ID"
    fi
    # QEMU guest agent: Proxmox does not use it for an LXC (no virtio-serial port, so
    # the service stays inactive), but every guest carries it. A failure is not fatal.
    run pct exec "$CT_ID" -- sh -c 'export DEBIAN_FRONTEND=noninteractive; for i in 1 2 3 4 5; do apt-get update -q && apt-get install -y -q qemu-guest-agent && exit 0; sleep 5; done; exit 1' ||
        printf 'Warning: qemu-guest-agent did not install in CT %s; continuing.\n' "$CT_ID" >&2

fi

if [[ $mode == create ]]; then
    exit_after_steps=1
else
    exit_after_steps=0
    # The address the router uses: the static IP_CIDR, else what the CT reports.
    domain=${MATTERMOST_DOMAIN:-}
    if [[ -z $domain && -n $IP_CIDR && $IP_CIDR != dhcp ]]; then domain=${IP_CIDR%/*}; fi
    if [[ -z $domain ]] && (( ! dry_run )); then
        domain=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{ print $1 }')
    fi
    domain=${domain:-<CT address>}
    run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
    run pct push "$CT_ID" "$source_dir/install-target.sh" "$deploy/install-target.sh" --perms 0755
    run pct exec "$CT_ID" -- env "MATTERMOST_CHANNEL=$MATTERMOST_CHANNEL" "MATTERMOST_TEAM=${MATTERMOST_TEAM:-}" \
        "MATTERMOST_ADMIN_USER=${MATTERMOST_ADMIN_USER:-}" "MATTERMOST_ADMIN_EMAIL=${MATTERMOST_ADMIN_EMAIL:-}" \
        bash "$deploy/install-target.sh"
    if (( ! dry_run )); then
        url=$(pct exec "$CT_ID" -- cat /etc/mattermost-target/url 2>/dev/null || true)
        admin=$(pct exec "$CT_ID" -- cat /etc/mattermost-target/admin-user 2>/dev/null || true)
    fi
    printf 'Mattermost is configured in CT %s: %s\n' "$CT_ID" "${url:-http://$domain:8065}"
    printf '  Administrator: %s; its password: pct exec %s -- cat /etc/mattermost-target/admin-password\n' "${admin:-<see CT>}" "$CT_ID"
    printf '  Alert webhook for channel %s: pct exec %s -- cat /etc/mattermost-target/webhook-url\n' "$MATTERMOST_CHANNEL" "$CT_ID"
    printf 'The router installer reads the webhook itself when it creates this target.\n'
    printf 'On an existing router: manage-model-servers set-webhook <URL>, then test-alert.\n'
fi
(( exit_after_steps )) || exit 0

cat <<NEXT

Next steps (web UI at http://$address:8065):
  1. Do this right away: the first account created becomes the system admin,
     whoever creates it. Create that account and a team.
  2. System Console > Integrations > Integration Management: enable
     "Incoming Webhooks" and "Enable integrations to override usernames"
     (the monitor posts as MATTERMOST_MONITOR_USER).
  3. Create the channel "$MATTERMOST_CHANNEL", then Integrations > Incoming
     Webhooks > Add Incoming Webhook for that channel, and copy its URL.
  4. Give the webhook URL to the router installer when it asks. After the
     router is provisioned, test it on the router CT or Proxmox host:
       manage-model-servers set-webhook <webhook URL>
       manage-model-servers test-alert
NEXT
