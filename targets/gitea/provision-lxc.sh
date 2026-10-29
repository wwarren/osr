#!/usr/bin/env bash
# Run on the PVE host to create a Debian Gitea server for the router's
# configuration repository. The CT and the Gitea install come from the Proxmox
# VE community script (ct/gitea.sh), run with this target's settings preset.
# Then install-target.sh finishes Gitea's setup inside the CT without the
# browser: registration off, an administrator, a non-admin router account and
# its token (see README.md). --create-only stops after the community script and
# prints the browser steps instead.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
readonly COMMUNITY_SCRIPT_DEFAULT_URL=https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/gitea.sh
usage() {
    cat <<'USAGE'
Usage: bash targets/gitea/provision-lxc.sh [--dry-run] [--create-only | --reconfigure]

Runs the community script
  var_os='debian' bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/gitea.sh)"
with the settings below preset as its var_* variables. It creates an
unprivileged Debian 13 CT with Gitea and SQLite support, serving
http://<CT address>:3000. This script waits for the web UI to answer, then
runs install-target.sh in the CT: SQLite, ROOT_URL http://<CT address>:3000,
registration off, the administrator GITEA_SITE_ADMIN (password in
/etc/gitea-target/admin-password) and the non-admin GITEA_ROUTER_USER with a
write:repository,write:user token in /etc/gitea-target/router-token.

The community script still shows its own menu; pick "Default" (or "My
Defaults") to accept the presets below.

Settings (environment; all optional):
  CT_ID=<next free>  CT_HOSTNAME=gitea  CORES=1  MEMORY_MB=1024  ROOTFS_GB=8
  TEMPLATE_STORAGE=<vztmpl storage>  STORAGE=<rootdir storage>
  BRIDGE=vmbr0  IP_CIDR=<a.b.c.d/nn|dhcp>  GATEWAY=<a.b.c.d>
  NAMESERVER=<a.b.c.d>  VLAN_TAG=<1-4094>  SSH_PUBLIC_KEY=<file>
  READY_TIMEOUT=120                   seconds to wait for the Gitea web UI
  GITEA_SITE_ADMIN=gitea-admin  GITEA_ROUTER_USER=ollama-router
  GITEA_SITE_ADMIN_EMAIL, GITEA_ROUTER_EMAIL, GITEA_DOMAIN (default: the CT address)
  COMMUNITY_SCRIPT_URL=<url>          default: the ProxmoxVE main-branch ct/gitea.sh
  COMMUNITY_SCRIPT_SHA256=<hex>       refuse to run a script with any other checksum
The checksum pins ct/gitea.sh only: when it runs, that script downloads the
shared build.func and install/gitea-install.sh from the community
repositories, and the install script deploys the latest Gitea release from
GitHub, so the Gitea version is not pinned either.
--dry-run validates inputs and prints the commands without running anything.
--create-only creates the CT only and prints the browser setup steps.
--reconfigure runs install-target.sh again in the existing CT_ID (no community
script), e.g. to repair the setup or after a failed first run.
For a dry run, set CT_ID explicitly (no cluster query is made).
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
        "var_disk=$ROOTFS_GB" "var_unprivileged=1" "var_nesting=1" "var_gpu=no" "var_os=debian" "var_version=13" "var_brg=$BRIDGE"
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
CT_HOSTNAME=${CT_HOSTNAME:-gitea}
CORES=${CORES:-1}
MEMORY_MB=${MEMORY_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-8}
STORAGE=${STORAGE:-}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-}
BRIDGE=${BRIDGE:-vmbr0}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
READY_TIMEOUT=${READY_TIMEOUT:-120}
COMMUNITY_SCRIPT_URL=${COMMUNITY_SCRIPT_URL:-$COMMUNITY_SCRIPT_DEFAULT_URL}
COMMUNITY_SCRIPT_SHA256=${COMMUNITY_SCRIPT_SHA256:-}
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
(( MEMORY_MB >= 1024 )) || die 'MEMORY_MB must be at least 1024.'
(( ROOTFS_GB >= 8 )) || die 'ROOTFS_GB must be at least 8.'
[[ -z $STORAGE || $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ -z $IP_CIDR ]] || valid_container_ip "$IP_CIDR" || die 'IP_CIDR must be a.b.c.d/nn or dhcp.'
[[ -z $GATEWAY ]] || ipv4 "$GATEWAY" || die 'GATEWAY must be an IPv4 address.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY || $dry_run == 1 ]] || die "SSH_PUBLIC_KEY is not readable: $SSH_PUBLIC_KEY"
[[ $COMMUNITY_SCRIPT_URL =~ ^https://[A-Za-z0-9./_-]+\.sh$ ]] || die 'COMMUNITY_SCRIPT_URL must be an https URL of a .sh file.'
[[ -z $COMMUNITY_SCRIPT_SHA256 || $COMMUNITY_SCRIPT_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMMUNITY_SCRIPT_SHA256 must be 64 hex digits.'
[[ -z $TEMPLATE_STORAGE || $TEMPLATE_STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid TEMPLATE_STORAGE.'
if [[ $mode != reconfigure ]]; then
    pve_select_storage TEMPLATE_STORAGE vztmpl 0
    pve_select_storage STORAGE rootdir "$ROOTFS_GB"
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy=/root/gitea-target-deploy
if [[ $mode != create ]]; then
    [[ -r $source_dir/install-target.sh ]] || die "Missing $source_dir/install-target.sh."
    # The guest installer checks its own settings; a bad name fails here, before
    # anything is created.
    bash "$source_dir/install-target.sh" --dry-run >/dev/null || die 'Invalid Gitea settings (see above).'
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
    script=$(mktemp "${TMPDIR:-/tmp}/community-gitea.XXXXXX")
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
    (umask 022; run env "${presets[@]}" bash "$script")

    address='<CT address>'
    if (( dry_run )); then
        printf '+ wait up to %ss for http://127.0.0.1:3000/ inside CT %s\n' "$READY_TIMEOUT" "$CT_ID"
    else
        pct status "$CT_ID" >/dev/null 2>&1 || die "The community script did not create CT $CT_ID (did you change the ID in its menu?)."
        deadline=$(( SECONDS + READY_TIMEOUT ))
        until pct exec "$CT_ID" -- curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3000/ 2>/dev/null; do
            (( SECONDS < deadline )) ||
                die "Gitea in CT $CT_ID did not answer on port 3000 within ${READY_TIMEOUT}s; see: pct exec $CT_ID -- journalctl -u gitea"
            sleep 5
        done
        address=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{ print $1 }')
        [[ -n $address ]] || address='<CT address>'
        printf 'Gitea web UI is answering in CT %s.\n' "$CT_ID"
    fi

fi

if [[ $mode == create ]]; then
    exit_after_steps=1
else
    exit_after_steps=0
    # The address the router uses: the static IP_CIDR, else what the CT reports.
    domain=${GITEA_DOMAIN:-}
    if [[ -z $domain && -n $IP_CIDR && $IP_CIDR != dhcp ]]; then domain=${IP_CIDR%/*}; fi
    if [[ -z $domain ]] && (( ! dry_run )); then
        domain=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{ print $1 }')
    fi
    domain=${domain:-<CT address>}
    run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
    run pct push "$CT_ID" "$source_dir/install-target.sh" "$deploy/install-target.sh" --perms 0755
    run pct exec "$CT_ID" -- env "GITEA_DOMAIN=$domain" "GITEA_SITE_ADMIN=${GITEA_SITE_ADMIN:-}" "GITEA_ROUTER_USER=${GITEA_ROUTER_USER:-}" \
        "GITEA_SITE_ADMIN_EMAIL=${GITEA_SITE_ADMIN_EMAIL:-}" "GITEA_ROUTER_EMAIL=${GITEA_ROUTER_EMAIL:-}" \
        bash "$deploy/install-target.sh"
    if (( ! dry_run )); then
        url=$(pct exec "$CT_ID" -- cat /etc/gitea-target/url 2>/dev/null || true)
        admin=$(pct exec "$CT_ID" -- cat /etc/gitea-target/admin-user 2>/dev/null || true)
        router_user=$(pct exec "$CT_ID" -- cat /etc/gitea-target/router-user 2>/dev/null || true)
    fi
    printf 'Gitea is configured in CT %s: %s\n' "$CT_ID" "${url:-http://$domain:3000}"
    printf '  Administrator: %s; its password:  pct exec %s -- cat /etc/gitea-target/admin-password\n' "${admin:-<see CT>}" "$CT_ID"
    printf '  Router account: %s; its token:    pct exec %s -- cat /etc/gitea-target/router-token\n' "${router_user:-<see CT>}" "$CT_ID"
    printf 'The router installer reads these itself when it creates this target. Set them\n'
    printf 'by hand as GITEA_SERVER_URL, GITEA_ADMIN_USER (the router account) and\n'
    printf 'GITEA_DEPLOY_TOKEN otherwise. Over http:// the token travels unencrypted.\n'
fi
(( exit_after_steps )) || exit 0

cat <<NEXT

Next steps (web UI at http://$address:3000):
  1. Do this right away: until it is finished, anyone who can reach port
     3000 can complete the setup and become the administrator.
     Complete Gitea's initial configuration in the browser. Select SQLite3
     to use the database support installed by the community script, or
     configure your own external database. Under Optional Settings, tick
     Disable Self-Registration, or anyone who can reach port 3000 can register
     an account even after setup.
  2. Set Server Domain and Gitea Base URL to the address users and the router
     will use (including port 3000, or your reverse proxy's public URL).
     Create the administrator account in the setup form and finish installing.
  3. Create a dedicated non-admin account for the router (as the administrator:
     Site Administration > User Accounts > Create User Account), sign in as it,
     then Settings > Applications > Generate New Token. For an existing
     repository, use read:user and write:repository, including for
     organisation-owned repos.
     For automatic repository creation, use write:user and write:repository
     instead (write:user includes read:user). Pre-create organisation repos.
     Tokens cannot be limited to one repository; restrict the account's
     repository access instead: for a repository it does not own, add it as a
     collaborator with Write access (or to an organisation team with write
     access to that repository only). Keep the token for the router installer.
  4. In the router installer, supply GITEA_SERVER_URL as that base URL, the
     dedicated router account's name (GITEA_ADMIN_USER, despite the variable's name), and its
     token (GITEA_DEPLOY_TOKEN). GITEA_REPO_NAME defaults to ollama-smart-router; the router
     installer can create it under the token owner's account. Over http:// the
     token travels unencrypted; put a TLS reverse proxy in front of Gitea if that
     network is not trusted, and use its https:// URL instead.
NEXT
