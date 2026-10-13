#!/usr/bin/env bash
# Run on the Proxmox host. Creates a separate unprivileged CT for Open Terminal
# and registers it with an existing ollama-smart-router Open WebUI. The router
# can be a CT on this host (reached with pct) or any LXC or VM that root can
# log in to over SSH, so the terminal can be added after the fact.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: CT_ID=281 TEMPLATE=local:vztmpl/debian-13-standard_..._amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.168.11.81/24 GATEWAY=192.168.11.1 \
       bash targets/open-terminal/provision-lxc.sh [--dry-run] [--integrate-only]

Creates a dedicated unprivileged Debian 12/13 LXC, installs Open Terminal from
the open-webui/open-terminal v0.14.0 GitHub tag, and registers an admin-only
system terminal in an existing ollama-smart-router Open WebUI. It asks for an
Open WebUI admin API key or session JWT unless OPENWEBUI_ADMIN_TOKEN is set.

The router (the LXC or VM running that Open WebUI) is given as ROUTER:
  ROUTER=280                a CT on this Proxmox host, reached with pct
  ROUTER=192.168.11.80      any LXC or VM, reached as root over SSH
  ROUTER=router.lan         (hostname; root must be able to log in)
When ROUTER is not set, the script asks for it. ROUTER_CT_ID or ROUTER_SSH_HOST
force one kind. It verifies the selected host's Open WebUI before creating the
terminal CT. SSH uses one connection for the whole run, so a password is asked
for at most once; unattended runs need key-based login.

Required: CT_ID (unused ID >=100 on this host), ROUTER (or the prompt),
          TEMPLATE (downloaded Debian 12/13 amd64 LXC template),
          STORAGE (active rootdir storage), IP_CIDR (static IPv4/CIDR), GATEWAY.
Optional: BRIDGE=vmbr0, CT_HOSTNAME=open-terminal, CORES=2, MEMORY_MB=2048,
          SWAP_MB=512, ROOTFS_GB=16, ONBOOT=1, NAMESERVER, VLAN_TAG,
          ROUTER_SSH_PORT=22,
          ROUTER_IP (the address the router uses to reach the terminal; detected
          with "ip route get" on the router), OPENWEBUI_PORT (read from the
          router's /app/openwebui/.env, default 8080), OPEN_TERMINAL_PORT=8000,
          OPEN_TERMINAL_VERSION=v0.14.0, OPEN_TERMINAL_COMMIT=<reviewed SHA-1;
          required for a non-default version>, CONNECTION_NAME='Open Terminal LXC'.

--dry-run prints the command plan without touching Proxmox, logging in to the
router, or asking for a token.
--integrate-only registers an already installed terminal CT (CT_ID on this
host). Its API key is read from that CT; no new CT is created.
USAGE
}

# Provision helpers (sourced by test-provision.sh) -----------------------------
ipv4() {
  local addr=$1 octet
  local -a parts
  [[ $addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$addr"
  for octet in "${parts[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$octet <= 255 )) || return 1
  done
}
valid_cidr() {
  local address prefix
  [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
  address=${BASH_REMATCH[1]}; prefix=${BASH_REMATCH[2]}
  ipv4 "$address" && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}
valid_hostname() {
  [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

# classify_router VALUE: "ct <id>" for a Proxmox CT ID, "ssh <host>" for an
# IPv4 address or hostname; returns 1 for anything else. A bare number below
# 100 is neither (not a CT ID, and not a usable host name).
classify_router() {
  local value=$1
  if [[ $value =~ ^[0-9]+$ ]]; then
    [[ $value =~ ^[1-9][0-9]{2,8}$ ]] || return 1
    printf 'ct %s\n' "$value"
  elif [[ $value =~ ^[0-9.]+$ ]]; then
    ipv4 "$value" || return 1
    printf 'ssh %s\n' "$value"
  elif valid_hostname "$value"; then
    printf 'ssh %s\n' "$value"
  else
    return 1
  fi
}

# route_src: the "src" address from `ip -4 route get` output on stdin.
route_src() { sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1; }

# remote_command ARG...: one string a POSIX remote shell splits back into ARGs.
remote_command() {
  local arg out=''
  for arg in "$@"; do
    out+="'${arg//\'/\'\\\'\'}' "
  done
  printf '%s' "${out% }"
}
# End provision helpers. --------------------------------------------------------

positive() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( ! dry_run )); then "$@"; fi
}

dry_run=0
integrate_only=0
while (( $# )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --integrate-only) integrate_only=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

CT_ID=${CT_ID:-}
ROUTER=${ROUTER:-}
ROUTER_CT_ID=${ROUTER_CT_ID:-}
ROUTER_SSH_HOST=${ROUTER_SSH_HOST:-}
ROUTER_SSH_PORT=${ROUTER_SSH_PORT:-22}
ROUTER_SSH_USER=${ROUTER_SSH_USER:-root}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
BRIDGE=${BRIDGE:-vmbr0}
CT_HOSTNAME=${CT_HOSTNAME:-open-terminal}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-2048}
SWAP_MB=${SWAP_MB:-512}
ROOTFS_GB=${ROOTFS_GB:-16}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
ROUTER_IP=${ROUTER_IP:-}
OPENWEBUI_PORT=${OPENWEBUI_PORT:-}
OPEN_TERMINAL_PORT=${OPEN_TERMINAL_PORT:-8000}
OPEN_TERMINAL_VERSION=${OPEN_TERMINAL_VERSION:-v0.14.0}
OPEN_TERMINAL_COMMIT=${OPEN_TERMINAL_COMMIT:-}
CONNECTION_NAME=${CONNECTION_NAME:-Open Terminal LXC}
# Taken out of the environment at once so no child process (pct, ssh) inherits it.
saved_admin_token=${OPENWEBUI_ADMIN_TOKEN:-}
unset OPENWEBUI_ADMIN_TOKEN

# --- which Open WebUI to integrate with ----------------------------------------
if [[ -n $ROUTER_CT_ID && -n $ROUTER_SSH_HOST ]] ||
   [[ -n $ROUTER && ( -n $ROUTER_CT_ID || -n $ROUTER_SSH_HOST ) ]]; then
  die 'Set only one of ROUTER, ROUTER_CT_ID, or ROUTER_SSH_HOST.'
fi
if [[ -z $ROUTER_CT_ID && -z $ROUTER_SSH_HOST ]]; then
  if [[ -z $ROUTER ]]; then
    [[ -t 0 ]] || die 'Set ROUTER to the router CT ID on this host, or the IP/hostname of the router LXC/VM (root SSH login).'
    printf 'Existing ollama-smart-router Open WebUI:\n' >&2
    printf '  a CT ID on this Proxmox host (e.g. 280), or\n' >&2
    printf '  the IP address or hostname of its LXC/VM, reached as %s over SSH\n' "$ROUTER_SSH_USER" >&2
    read -r -p 'Open WebUI CT ID or IP address: ' ROUTER || die 'No Open WebUI location was entered.'
  fi
  router_spec=$(classify_router "$ROUTER") ||
    die "ROUTER '$ROUTER' is neither a CT ID (100 or more) nor an IPv4 address or hostname."
  case $router_spec in
    ct\ *) ROUTER_CT_ID=${router_spec#ct } ;;
    ssh\ *) ROUTER_SSH_HOST=${router_spec#ssh } ;;
  esac
fi
if [[ -n $ROUTER_CT_ID ]]; then
  [[ $ROUTER_CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'ROUTER_CT_ID must be numeric and at least 100.'
  router_kind=ct
  router_label="router CT ${ROUTER_CT_ID}"
else
  [[ $(classify_router "$ROUTER_SSH_HOST") == "ssh $ROUTER_SSH_HOST" ]] ||
    die 'ROUTER_SSH_HOST must be an IPv4 address or hostname.'
  [[ $ROUTER_SSH_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid ROUTER_SSH_USER.'
  [[ $ROUTER_SSH_USER == root ]] || die 'ROUTER_SSH_USER must be root for router staging and integration.'
  [[ $ROUTER_SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( ROUTER_SSH_PORT <= 65535 )) || die 'Invalid ROUTER_SSH_PORT.'
  router_kind=ssh
  router_label="router ${ROUTER_SSH_USER}@${ROUTER_SSH_HOST}"
fi

[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be numeric and at least 100.'
[[ $router_kind == ssh || $CT_ID != "$ROUTER_CT_ID" ]] || die 'Terminal and router CT IDs must differ.'
for name in CORES MEMORY_MB ROOTFS_GB OPEN_TERMINAL_PORT; do positive "$name" "${!name}"; done
(( OPEN_TERMINAL_PORT <= 65535 )) || die 'OPEN_TERMINAL_PORT must be <=65535.'
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be nonnegative.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ ${#CONNECTION_NAME} -le 64 && $CONNECTION_NAME =~ ^[[:print:]]+$ ]] || die 'CONNECTION_NAME must be 1-64 printable characters.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'Invalid CT_HOSTNAME.'
[[ $OPEN_TERMINAL_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid OPEN_TERMINAL_VERSION.'
[[ -z $OPEN_TERMINAL_COMMIT || $OPEN_TERMINAL_COMMIT =~ ^[0-9a-f]{40}$ ]] ||
  die 'OPEN_TERMINAL_COMMIT must be a full 40-digit lowercase SHA-1.'
[[ $OPEN_TERMINAL_VERSION == v0.14.0 || -n $OPEN_TERMINAL_COMMIT ]] ||
  die "Set OPEN_TERMINAL_COMMIT to the reviewed commit of ${OPEN_TERMINAL_VERSION} (tags can be moved upstream)."
[[ -z $ROUTER_IP ]] || ipv4 "$ROUTER_IP" || die 'ROUTER_IP must be IPv4.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be IPv4.'
if [[ -n $OPENWEBUI_PORT ]]; then
  positive OPENWEBUI_PORT "$OPENWEBUI_PORT"
  (( OPENWEBUI_PORT <= 65535 )) || die 'OPENWEBUI_PORT must be <=65535.'
fi
if [[ -n $VLAN_TAG ]]; then
  positive VLAN_TAG "$VLAN_TAG"
  (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be <=4094.'
fi
if (( ! integrate_only )); then
  [[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] || die 'TEMPLATE must be a downloaded Debian 12/13 amd64 LXC template.'
  [[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
  valid_cidr "$IP_CIDR" || die 'IP_CIDR must be a static IPv4/CIDR address.'
  ipv4 "$GATEWAY" || die 'GATEWAY must be IPv4.'
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy_files=(install-target.sh open-terminal.service requirements.in requirements.lock)
for file in "${deploy_files[@]}" integrate-webui.py verify-webui.py; do
  [[ -r $source_dir/$file ]] || die "Deployment file is missing: $source_dir/$file"
done

stage=$(mktemp -d "${TMPDIR:-/tmp}/open-terminal-setup.XXXXXX")
router_stage=''
# One multiplexed SSH connection for the whole run: a password, if the router
# asks for one, is entered once. ControlPath lives in the 0700 stage directory.
# Options go before the destination; everything after it is the remote command.
ssh_opts=(-p "$ROUTER_SSH_PORT" -o ConnectTimeout=15 -o ServerAliveInterval=15
  -o ControlMaster=auto -o "ControlPath=$stage/ssh-%C" -o ControlPersist=yes)
ssh_dest="${ROUTER_SSH_USER}@${ROUTER_SSH_HOST:-}"

# router_exec ARG...: run a command on the router (no dry-run handling).
router_exec() {
  if [[ $router_kind == ct ]]; then
    pct exec "$ROUTER_CT_ID" -- "$@"
  else
    ssh "${ssh_opts[@]}" "$ssh_dest" "$(remote_command "$@")"
  fi
}
# router_run ARG...: the same, but printed and skipped in a dry run.
router_run() {
  if [[ $router_kind == ct ]]; then
    run pct exec "$ROUTER_CT_ID" -- "$@"
  else
    printf '+ ssh %s@%s -- %s\n' "$ROUTER_SSH_USER" "$ROUTER_SSH_HOST" "$(remote_command "$@")"
    if (( ! dry_run )); then router_exec "$@"; fi
  fi
}
# router_push SRC DEST: copy a local file to the router, mode 0600.
router_push() {
  if [[ $router_kind == ct ]]; then
    run pct push "$ROUTER_CT_ID" "$1" "$2" --perms 0600
  else
    printf '+ ssh %s@%s -- write %s (0600) < %s\n' "$ROUTER_SSH_USER" "$ROUTER_SSH_HOST" "$2" "$1"
    if (( ! dry_run )); then
      ssh "${ssh_opts[@]}" "$ssh_dest" "umask 077 && cat > $(remote_command "$2")" < "$1"
    fi
  fi
}

cleanup() {
  local rc=$?
  if [[ -n $router_stage ]] && (( ! dry_run )); then
    router_exec rm -rf -- "$router_stage" >/dev/null 2>&1 || true
  fi
  if [[ $router_kind == ssh ]] && (( ! dry_run )); then
    ssh "${ssh_opts[@]}" -O exit "$ssh_dest" >/dev/null 2>&1 || true
  fi
  rm -f -- "$stage/admin-token" "$stage/api-key" 2>/dev/null || true
  rm -rf -- "$stage" 2>/dev/null || true
  if (( rc != 0 && ! dry_run )); then
    printf 'Setup stopped. CT %s, if created, is retained. Re-run with --integrate-only after fixing the error.\n' "$CT_ID" >&2
  fi
}
trap cleanup EXIT

# --- check the router, and what this host needs -----------------------------------
if (( ! dry_run )); then
  [[ $EUID -eq 0 ]] || die 'Run as root on the Proxmox host.'
  for command_name in pveversion pct pvesh pvesm openssl; do
    command -v "$command_name" >/dev/null || die "Missing command: $command_name"
  done
  [[ -d /etc/pve/nodes ]] || die 'Proxmox cluster filesystem is unavailable.'
  if [[ $router_kind == ct ]]; then
    pct status "$ROUTER_CT_ID" 2>/dev/null | grep -q 'status: running' ||
      die "Router CT ${ROUTER_CT_ID} is not a running CT on this host. For a router on another node or a VM, set ROUTER to its IP address or hostname."
  else
    command -v ssh >/dev/null || die 'Missing command: ssh'
    note "Connecting to ${router_label} over SSH..."
    router_exec true || die "Cannot log in to ${router_label} on port ${ROUTER_SSH_PORT}. Check that ${ROUTER_SSH_USER} may log in over SSH (key, or password at the prompt) and that the host key is known."
  fi
  router_exec test -x /app/openwebui/venv/bin/open-webui ||
    die "Open WebUI is not installed at /app/openwebui on ${router_label}. Is this an ollama-smart-router install?"
  router_exec systemctl is-active --quiet open-webui.service ||
    die "Open WebUI (open-webui.service) is not active on ${router_label}. Is this an ollama-smart-router install?"
  router_exec sh -c 'command -v python3 >/dev/null' || die "python3 is missing on ${router_label}."
  if [[ -z $OPENWEBUI_PORT ]]; then
    OPENWEBUI_PORT=$(router_exec sh -c "sed -n 's/^PORT=//p' /app/openwebui/.env 2>/dev/null | head -n1" || true)
    OPENWEBUI_PORT=${OPENWEBUI_PORT//[$'\r\n ']/}
    OPENWEBUI_PORT=${OPENWEBUI_PORT:-8080}
    positive OPENWEBUI_PORT "$OPENWEBUI_PORT"
    (( OPENWEBUI_PORT <= 65535 )) || die "Invalid PORT in /app/openwebui/.env on ${router_label}."
  fi
  note "Verifying Open WebUI on ${router_label} (localhost:${OPENWEBUI_PORT})..."
  webui_version=$(router_exec python3 -c "$(cat "$source_dir/verify-webui.py")" "$OPENWEBUI_PORT") ||
    die "No healthy Open WebUI responded on ${router_label} port ${OPENWEBUI_PORT}; terminal CT ${CT_ID} was not created."
  note "Verified Open WebUI ${webui_version} on ${router_label}."
else
  OPENWEBUI_PORT=${OPENWEBUI_PORT:-'<router-webui-port>'}
  printf '+ verify Open WebUI install, open-webui.service, /health and /api/version on %s:%s before pct create\n' \
    "$router_label" "$OPENWEBUI_PORT"
fi

if (( integrate_only )); then
  if (( dry_run )); then
    TERMINAL_IP='<terminal-eth0-ip>'
  else
    pct status "$CT_ID" | grep -q 'status: running' || die 'Terminal CT is not running.'
    TERMINAL_IP=$(pct exec "$CT_ID" -- sh -c "ip -4 -o addr show dev eth0 | awk 'NR==1 {split(\$4,a,\"/\"); print a[1]}'")
    ipv4 "$TERMINAL_IP" || die 'Cannot detect terminal CT IPv4 on eth0.'
  fi
else
  if (( ! dry_run )); then
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "CT ID ${CT_ID} is already used."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge does not exist: $BRIDGE"
    template_path=$(pvesm path "$TEMPLATE")
    [[ -r $template_path ]] || die "Template is unreadable: $TEMPLATE"
    pvesm status --content rootdir | awk -v s="$STORAGE" '$1==s && $3=="active" {found=1} END {exit !found}' || die 'STORAGE is inactive or does not support rootdir.'
  fi
  TERMINAL_IP=${IP_CIDR%%/*}
fi

# The firewall admits the address the router actually uses to reach the
# terminal: correct for a CT, a VM, or a router on another node or subnet.
if [[ -z $ROUTER_IP ]]; then
  if (( dry_run )); then
    ROUTER_IP='<router-source-ip>'
  else
    ROUTER_IP=$(router_exec ip -4 route get "$TERMINAL_IP" | route_src)
    ipv4 "$ROUTER_IP" ||
      die "Cannot tell which address ${router_label} uses to reach ${TERMINAL_IP}; set ROUTER_IP."
  fi
fi

admin_token=''
if (( ! dry_run )); then
  admin_token=$saved_admin_token
  if [[ -z $admin_token ]]; then
    [[ -t 0 ]] || die 'Set OPENWEBUI_ADMIN_TOKEN to an Open WebUI admin API key or JWT for unattended use.'
    read -r -s -p 'Open WebUI admin API key or JWT: ' admin_token
    printf '\n'
  fi
  [[ -n $admin_token ]] || die 'An Open WebUI admin API key or JWT is required.'
  printf '%s\n' "$admin_token" > "$stage/admin-token"
fi
unset admin_token saved_admin_token

# --- the terminal CT ----------------------------------------------------------------
if (( integrate_only )); then
  run pct pull "$CT_ID" /etc/open-terminal/api-key "$stage/api-key"
else
  if (( dry_run )); then
    printf '+ openssl rand -hex 32 > <stage>/api-key\n'
  else
    openssl rand -hex 32 > "$stage/api-key"
  fi
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --description 'Open Terminal workspace for Ollama Smart Router Open WebUI')
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  run "${create[@]}"

  firewall_file="/etc/pve/firewall/${CT_ID}.fw"
  firewall=$(printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source %s/32 -p tcp -dport %s -log nolog\n' \
    "$ROUTER_IP" "$OPEN_TERMINAL_PORT")
  if (( dry_run )); then
    printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
  else
    [[ ! -e $firewall_file ]] || die "Refusing to replace existing firewall file: $firewall_file"
    printf '%s\n' "$firewall" > "$firewall_file"
  fi
  run pct start "$CT_ID"
  if (( ! dry_run )); then
    ready=0
    for (( attempt=0; attempt<60; attempt++ )); do
      if pct exec "$CT_ID" -- test -d /run/systemd/system 2>/dev/null; then ready=1; break; fi
      sleep 2
    done
    (( ready )) || die 'Terminal CT did not start systemd within 120 seconds.'
    # The installer starts with apt-get: wait for a default route and DNS, or a
    # first boot can race the network and fail on "Temporary failure resolving".
    online=0
    for (( attempt=0; attempt<60; attempt++ )); do
      if pct exec "$CT_ID" -- sh -c 'ip route show default | grep -q . && getent hosts deb.debian.org >/dev/null && getent hosts github.com >/dev/null'; then
        online=1; break
      fi
      sleep 3
    done
    (( online )) || die "Terminal CT ${CT_ID} has no default route or DNS after 180 seconds; check GATEWAY, NAMESERVER and the bridge."
  else
    printf '+ wait for systemd, a default route and DNS (deb.debian.org, github.com) in CT %s\n' "$CT_ID"
  fi
  run pct exec "$CT_ID" -- install -d -m 0700 /etc/open-terminal /root/open-terminal-deploy
  run pct push "$CT_ID" "$stage/api-key" /etc/open-terminal/api-key --perms 0600
  for file in "${deploy_files[@]}"; do
    perms=0644
    [[ $file == *.sh ]] && perms=0755
    run pct push "$CT_ID" "$source_dir/$file" "/root/open-terminal-deploy/$file" --perms "$perms"
  done
  run pct exec "$CT_ID" -- env "OPEN_TERMINAL_PORT=$OPEN_TERMINAL_PORT" \
    "OPEN_TERMINAL_VERSION=$OPEN_TERMINAL_VERSION" "OPEN_TERMINAL_COMMIT=$OPEN_TERMINAL_COMMIT" \
    bash /root/open-terminal-deploy/install-target.sh
fi

# --- register it with Open WebUI on the router ---------------------------------------
if (( dry_run )); then
  router_stage='<router-stage>'
  router_run mktemp -d /root/open-terminal-integration.XXXXXX
else
  # Validated before it is recorded: cleanup removes router_stage recursively.
  made=$(router_exec mktemp -d /root/open-terminal-integration.XXXXXX)
  made=${made//[$'\r\n']/}
  [[ $made =~ ^/root/open-terminal-integration\.[A-Za-z0-9]{6}$ ]] ||
    die "Unexpected router staging path: $made (not removed; check ${router_label} by hand)"
  router_stage=$made
fi
router_push "$stage/api-key" "$router_stage/api-key"
router_push "$stage/admin-token" "$router_stage/admin-token"
router_push "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py"
router_run python3 "$router_stage/integrate-webui.py" \
  --webui-url "http://127.0.0.1:${OPENWEBUI_PORT}" \
  --terminal-url "http://${TERMINAL_IP}:${OPEN_TERMINAL_PORT}" \
  --id "open-terminal-lxc-${CT_ID}" --name "$CONNECTION_NAME" \
  --admin-token-file "$router_stage/admin-token" --terminal-key-file "$router_stage/api-key"
(( dry_run )) && router_stage=''

printf 'Open Terminal: http://%s:%s (reachable from %s at %s).\n' "$TERMINAL_IP" "$OPEN_TERMINAL_PORT" "$router_label" "$ROUTER_IP"
printf 'Select "%s" in Open WebUI chats. Workspace: /srv/open-terminal/workspace in CT %s.\n' "$CONNECTION_NAME" "$CT_ID"
printf 'Connection is admin-only. Grant trusted groups in Admin Settings > Integrations > Open Terminal if needed.\n'
