#!/usr/bin/env bash
# Run on a Proxmox VE host. Creates an unprivileged CT for OpenClaw, points it
# at an existing ollama-smart-router with the router's API key, and (by
# default) registers OpenClaw's Gateway in that router's Open WebUI. The
# router can be a CT on this host (reached with pct) or any LXC or VM that root
# can log in to over SSH.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
# shellcheck source=targets/open-terminal/client-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../open-terminal/client-lib.sh"
# shellcheck source=targets/honcho/client-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../honcho/client-lib.sh"
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run] [--reconfigure | --integrate-only]

Creates a dedicated unprivileged Debian 12/13 LXC, installs OpenClaw (nvm,
Node through nvm, npm install -g openclaw), configures a CT-local dispatcher
to discover models from the router and call their servers directly, and adds
OpenClaw to Open WebUI as the model "openclaw". It asks for an Open WebUI
admin API key or session JWT unless OPENWEBUI_ADMIN_TOKEN is set (or
OPENWEBUI=false).

The router is given as ROUTER:
  ROUTER=<CT ID>            a CT on this Proxmox host, reached with pct
  ROUTER=<IP or hostname>   any LXC or VM, reached as root over SSH
When ROUTER is not set, the script asks for it. ROUTER_CT_ID or ROUTER_SSH_HOST
force one kind.

Required: ROUTER (or the prompt); for a new CT also TEMPLATE (Debian
          12/13 amd64), STORAGE (active rootdir storage), IP_CIDR, GATEWAY.
          A new CT's CT_ID defaults to the cluster's next free ID (set it to
          choose another); --reconfigure and --integrate-only ask for it.
Interactive runs list downloaded templates and eligible rootdir storage when
those values are unset. CT_ID is the OpenClaw CT, separate from the existing
router CT ID or IP address.
OpenClaw: OPENCLAW_MODEL=auto, OPENCLAW_CONTEXT_LENGTH=65536 (>=32768; the
          model's host must serve it), OPENCLAW_MAX_TOKENS=8192,
          OPENCLAW_VERSION=latest (npm version or dist-tag),
          OPENCLAW_NODE_VERSION=24, NVM_VERSION=v0.40.4, NVM_INSTALLER_SHA256,
          OPENCLAW_PORT=18789.
Dashboard: OPENCLAW_DASHBOARD=true (Control UI on all CT IPv4 addresses, on
           OPENCLAW_PORT); false disables it.
Router:   ROUTER_URL (default http://<router address>:<router port>),
          ROUTER_IP (the address the router uses to reach this CT; detected),
          ROUTER_SSH_PORT=22.
Open WebUI: OPENWEBUI=true (false: no /v1/chat/completions, no registration),
          OPENWEBUI_PORT (read from the router), TASK_MODEL=fast (router model
          for Open WebUI titles and tags; blank leaves the setting alone).
Network:  EGRESS=restricted (outbound to router, registered model servers,
          DNS and internet HTTP(S); other private destinations dropped) or open.
          Model server host names are resolved inside the OpenClaw CT; a URL
          without a port means port 80 (http) or 443 (https).
Open Terminal: OPEN_TERMINAL_URL (the terminal CT's gateway, http://IP:port;
          offered when a CT tagged open-terminal is on this host) gives
          OpenClaw its own workspace there, as MCP server open-terminal. With
          OPEN_TERMINAL_CT_ID (detected from the address) this script issues
          the CT's client key and admits it in the terminal's firewall;
          OPEN_TERMINAL_KEY_FILE uses a key issued by hand instead.
          --reconfigure keeps it; OPEN_TERMINAL_URL= disconnects and revokes.
CT:       BRIDGE=vmbr0, CT_HOSTNAME=openclaw, CORES=2, MEMORY_MB=4096,
          SWAP_MB=1024, ROOTFS_GB=32, ONBOOT=1, NAMESERVER, VLAN_TAG.

--dry-run         print the plan without touching Proxmox or the router.
--reconfigure     an existing OpenClaw CT (CT_ID): push the current router key,
                  installer, dispatcher and units, rerun with these settings,
                  update its firewall rules, then register it again. Use after
                  set-api-key on the router, or after adding a model server or
                  models.
--integrate-only  register an existing OpenClaw CT's Gateway in Open WebUI.
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
# IPv4 address or hostname; returns 1 for anything else.
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

# url_host URL / url_port URL: the host and port of http(s)://host:port.
url_host() { local rest=${1#*://}; rest=${rest%%/*}; printf '%s\n' "${rest%:*}"; }
url_port() { local rest=${1#*://}; rest=${rest%%/*}; printf '%s\n' "${rest##*:}"; }

# The rules this target owns carry a rule comment, which Proxmox keeps when
# the firewall is edited in its GUI or API (comment-only lines are dropped).
FW_TAG='ollama-smart-router openclaw'
OPENCLAW_CT_DESCRIPTION='OpenClaw for Ollama Smart Router'

# openclaw_fw_rules ROUTER_IP API_PORT ROUTER_DEST ROUTER_PORT RESTRICTED DASHBOARD_PORT:
# the owned rules. Inbound: the router to the Gateway's API (an empty API_PORT
# admits nothing), and, with the Control UI, anyone to the same port.
# Restricted egress also admits the router and the inventory's model hosts.
openclaw_fw_rules() {
  local rule
  [[ -z $2 ]] || printf 'IN ACCEPT -source %s/32 -p tcp -dport %s -log nolog # %s-api\n' "$1" "$2" "$FW_TAG"
  [[ -z ${6:-} ]] || printf 'IN ACCEPT -p tcp -dport %s -log nolog # %s-dashboard\n' "$6" "$FW_TAG"
  [[ $5 != true ]] || printf 'OUT ACCEPT -dest %s/32 -p tcp -dport %s -log nolog # %s-router\n' "$3" "$4" "$FW_TAG"
  if [[ $5 == true ]]; then
    for rule in "${model_rules[@]-}"; do [[ -z $rule ]] || printf '%s\n' "$rule"; done
  fi
}

# firewall_config EGRESS ROUTER_IP ROUTER_DEST ROUTER_PORT API_PORT DASHBOARD_PORT:
# the CT's /etc/pve/firewall/<id>.fw. The owned rules, then for restricted
# outbound: DNS, then HTTP(S) to anything that is not a private, CGNAT or
# link-local address (npm, nvm, Node downloads, OpenClaw's web tools).
# Proxmox applies the first matching rule.
firewall_config() {
  local egress=$1 router_ip=$2 router_dest=$3 router_port=$4 api_port=$5 dashboard_port=${6:-} net restricted=false
  [[ $egress != restricted ]] || restricted=true
  printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n'
  if $restricted; then printf 'policy_out: DROP\n'; else printf 'policy_out: ACCEPT\n'; fi
  printf '\n[RULES]\n'
  openclaw_fw_rules "$router_ip" "$api_port" "$router_dest" "$router_port" "$restricted" "$dashboard_port"
  if $restricted; then
    printf 'OUT ACCEPT -p udp -dport 53 -log nolog\n'
    printf 'OUT ACCEPT -p tcp -dport 53 -log nolog\n'
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
      printf 'OUT DROP -dest %s -log nolog\n' "$net"
    done
    printf 'OUT ACCEPT -p tcp -dport 443 -log nolog\n'
    printf 'OUT ACCEPT -p tcp -dport 80 -log nolog\n'
  fi
}

# openclaw_fw_update FILE KEEP ROUTER_IP API_PORT ROUTER_DEST ROUTER_PORT DASHBOARD_PORT:
# FILE with this target's rules (found by their comment, wherever they are)
# replaced by the current ones, at the top of [RULES] so they match first;
# every other line is kept as it is. KEEP=keep also keeps the old owned rules,
# so a reconfigure that fails half-way leaves the CT reachable as before. The
# egress mode is read from the file's policy_out.
openclaw_fw_update() {
  local file=$1 keep=$2 router_ip=$3 api_port=$4 router_dest=$5 router_port=$6 dashboard_port=${7:-}
  local mark_re=" # ${FW_TAG}-(api|router|model|dashboard)\$"
  local -a lines=() old=() rules=()
  local -A owned=()
  local i line section='' sections=0 restricted=false idx have seen_rules=0
  [[ -f $file ]] || { printf 'Missing firewall file: %s\n' "$file" >&2; return 1; }
  mapfile -t lines < "$file" || return 1
  for i in "${!lines[@]}"; do
    line=${lines[$i]%$'\r'}
    if [[ $line =~ ^\[([A-Za-z_]+)\]$ ]]; then
      section=${BASH_REMATCH[1]}
      [[ $section != RULES ]] || sections=$((sections + 1))
      continue
    fi
    if [[ $section == OPTIONS && $line =~ ^policy_out:[[:space:]]*DROP[[:space:]]*$ ]]; then restricted=true; fi
    [[ $section == RULES ]] || continue
    if [[ $line =~ $mark_re ]]; then owned[$i]=1; old+=("$line"); fi
  done
  if (( sections > 1 )); then
    printf 'Multiple [RULES] sections in %s; inspect the file before reconfiguring.\n' "$file" >&2
    return 1
  fi
  mapfile -t rules < <(openclaw_fw_rules "$router_ip" "$api_port" "$router_dest" "$router_port" "$restricted" "$dashboard_port")
  if [[ $keep == keep ]]; then
    for line in "${old[@]}"; do
      have=0
      for idx in "${rules[@]}"; do [[ $idx != "$line" ]] || have=1; done
      (( have )) || rules+=("$line")
    done
  fi
  for i in "${!lines[@]}"; do
    [[ -z ${owned[$i]:-} ]] || continue
    printf '%s\n' "${lines[$i]}"
    if [[ ${lines[$i]%$'\r'} == '[RULES]' ]]; then
      seen_rules=1
      (( ${#rules[@]} == 0 )) || printf '%s\n' "${rules[@]}"
    fi
  done
  if (( ! seen_rules )); then
    printf '\n[RULES]\n'
    (( ${#rules[@]} == 0 )) || printf '%s\n' "${rules[@]}"
  fi
}

# fw_replace FILE SEEN CONTENT: FILE becomes CONTENT through the shared
# targets/pve-firewall-swap.pl (the CT's Proxmox firewall lock and a staged
# rename), only while FILE still holds SEEN, the copy CONTENT was built from.
# An edit made meanwhile (the GUI, another provisioner) is never overwritten.
# 0: replaced or unchanged; 1: FILE changed meanwhile, left as it is; 2: failed.
fw_replace() {
  local vmid=${1##*/} new
  vmid=${vmid%.fw}
  new=$(mktemp "$stage/firewall.new.XXXXXX") || return 2
  printf '%s\n' "$3" > "$new" || { rm -f -- "$new"; return 2; }
  local status=0
  perl "$source_dir/../pve-firewall-swap.pl" "$1" "$2" "$new" "$vmid" "$PVE_ETC" || status=$?
  rm -f -- "$new"
  return "$status"
}
# fw_snapshot FILE: a private copy of FILE in the stage, to build its update from.
fw_snapshot() {
  cp -- "$1" "$stage/firewall.seen" || die "Could not read $1."
  printf '%s\n' "$stage/firewall.seen"
}
# inventory_endpoints FILE: one host and port per registered model server. A
# URL without a port uses its scheme's default (80 for http, 443 for https).
# Validation is deliberately strict: the firewall only admits exact endpoints.
inventory_endpoints() {
  python3 - "$1" <<'PY'
import json, sys
from urllib.parse import urlsplit
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not data.get("enabled") or not isinstance(data.get("servers"), list):
    raise SystemExit("Router discovery is disabled; enable [discovery] before installing OpenClaw")
seen = set()
for item in data["servers"]:
    if not isinstance(item, str):
        raise SystemExit("Invalid model server in router inventory")
    url = item.split("+", 1)[-1]
    parsed = urlsplit(url)
    try:
        port = parsed.port
        if port is None:
            port = {"http": 80, "https": 443}[parsed.scheme]
    except (KeyError, ValueError):
        port = None
    if parsed.scheme not in ("http", "https") or not port or not parsed.hostname \
            or parsed.username or parsed.password \
            or parsed.query or parsed.fragment:
        raise SystemExit("Invalid model server URL in router inventory: " + item)
    pair = (parsed.hostname, port)
    if pair not in seen:
        seen.add(pair)
        print(*pair)
PY
}
# inventory_targets FILE: NAME=ENTRY per registered model server, the direct
# targets OpenClaw can pick as provider NAME without the router. Plain HTTP
# IPv4 endpoints keep their kind-host-port name; other endpoints get a suffix
# derived from their URL so removing a peer cannot rename them. The names are
# the Hermes target's, so both agents call a server the same.
inventory_targets() {
  python3 - "$1" <<'PY'
import hashlib, ipaddress, json, re, sys
from urllib.parse import urlsplit
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not data.get("enabled") or not isinstance(data.get("servers"), list):
    raise SystemExit("Router discovery is disabled; enable [discovery] before installing OpenClaw")
kinds = ("lmstudio", "strata", "basalt", "maya", "xolotl", "avalon", "kindi")
names = {}
seen = set()
for item in data["servers"]:
    if not isinstance(item, str):
        raise SystemExit("Invalid model server in router inventory")
    kind, _, url = item.partition("+")
    if kind not in kinds or not url:
        kind, url = "ollama", item
    parsed = urlsplit(url)
    try:
        # Port 0 is invalid, not "no port": only None takes the default.
        port = parsed.port
        if port is None:
            port = {"http": 80, "https": 443}[parsed.scheme]
    except (KeyError, ValueError):
        port = None
    if parsed.scheme not in ("http", "https") or not port or not parsed.hostname \
            or parsed.username or parsed.password or parsed.query or parsed.fragment \
            or any(c.isspace() for c in item):
        raise SystemExit("Invalid model server URL in router inventory: " + item)
    host = re.sub(r"[^a-z0-9]+", "-", parsed.hostname.lower()).strip("-")
    identity = f"{kind}|{parsed.scheme}|{parsed.hostname.lower()}|{port}|{parsed.path.rstrip('/')}"
    if identity in seen:
        continue
    seen.add(identity)
    base = f"{kind}-{host}-{port}"
    try:
        ipv4 = isinstance(ipaddress.ip_address(parsed.hostname), ipaddress.IPv4Address)
    except ValueError:
        ipv4 = False
    if ipv4 and parsed.scheme == "http" and parsed.path in ("", "/"):
        name = base
    else:
        suffix = hashlib.sha256(identity.encode()).hexdigest()[:12]
        name = f"{base[:50].rstrip('-')}-{suffix}"
    if name in names:
        raise SystemExit("Direct target name collision in router inventory: " + name)
    names[name] = identity
    print(f"{name}={item.rstrip('/')}")
PY
}
# End provision helpers. --------------------------------------------------------

positive() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }

# model_rules_for ips|all: the egress rules for model_endpoints. A host name is
# resolved INSIDE the OpenClaw CT, by the same resolver (glibc getaddrinfo)
# its dispatcher connects with, so the rules admit the addresses the
# dispatcher will actually use; every IPv4 address is admitted. "ips" leaves
# host names out, for a CT that is not running yet.
model_rules_for() {
  local pass=$1 entry host port addr
  local -a addrs
  local -A seen=()
  model_rules=()
  for entry in "${model_endpoints[@]}"; do
    read -r host port <<< "$entry"
    [[ -n $host ]] || continue
    if ipv4 "$host" || (( dry_run )); then
      addrs=("$host")
    elif [[ $pass == ips ]]; then
      continue
    else
      mapfile -t addrs < <(pct exec "$CT_ID" -- getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
      if (( ${#addrs[@]} == 0 )); then
        note "Warning: CT $CT_ID cannot resolve model server $host, so it is not admitted; OpenClaw skips it. Fix the CT's DNS, then rerun --reconfigure."
        continue
      fi
    fi
    for addr in "${addrs[@]}"; do
      ipv4 "$addr" || (( dry_run )) || continue
      [[ -z ${seen[$addr:$port]:-} ]] || continue
      seen[$addr:$port]=1
      model_rules+=("OUT ACCEPT -dest $addr/32 -p tcp -dport $port -log nolog # ${FW_TAG}-model")
    done
  done
}
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( ! dry_run )); then "$@"; fi
}

dry_run=0
mode=create
while (( $# )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --reconfigure) [[ $mode == create ]] || die 'Use only one of --reconfigure and --integrate-only.'; mode=reconfigure ;;
    --integrate-only) [[ $mode == create ]] || die 'Use only one of --reconfigure and --integrate-only.'; mode=integrate ;;
    -h|--help) usage; exit 0 ;;
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
ROUTER_URL=${ROUTER_URL:-}
ROUTER_IP=${ROUTER_IP:-}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
BRIDGE=${BRIDGE:-vmbr0}
CT_HOSTNAME=${CT_HOSTNAME:-openclaw}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-4096}
SWAP_MB=${SWAP_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-32}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
EGRESS=${EGRESS:-restricted}
OPENWEBUI=${OPENWEBUI:-}
OPENWEBUI_PORT=${OPENWEBUI_PORT:-}
TASK_MODEL=${TASK_MODEL-fast}
OPENCLAW_MODEL=${OPENCLAW_MODEL:-}
OPENCLAW_CONTEXT_LENGTH=${OPENCLAW_CONTEXT_LENGTH:-}
OPENCLAW_MAX_TOKENS=${OPENCLAW_MAX_TOKENS:-}
OPENCLAW_VERSION=${OPENCLAW_VERSION:-latest}
OPENCLAW_NODE_VERSION=${OPENCLAW_NODE_VERSION:-24}
NVM_VERSION=${NVM_VERSION:-v0.40.4}
nvm_sha_set=${NVM_INSTALLER_SHA256+set}
NVM_INSTALLER_SHA256=${NVM_INSTALLER_SHA256-}
OPENCLAW_PORT=${OPENCLAW_PORT:-18789}
OPENCLAW_DASHBOARD=${OPENCLAW_DASHBOARD:-}
# Taken out of the environment at once so no child process (pct, ssh) inherits it.
saved_admin_token=${OPENWEBUI_ADMIN_TOKEN:-}
unset OPENWEBUI_ADMIN_TOKEN

# --- Questions, one section at a time -----------------------------------------
template_re='^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
valid_template() { [[ $1 =~ $template_re ]]; }
valid_storage() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_router() { classify_router "$1" >/dev/null; }
valid_model() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]]; }
valid_context() { [[ $1 =~ ^[1-9][0-9]{4,6}$ ]] && (( $1 >= 32768 )); }
valid_tokens() { [[ $1 =~ ^[1-9][0-9]{2,6}$ ]]; }
valid_honcho_url() { [[ -z $1 || $1 =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]]; }
# recorded_or KEY DEFAULT: the CT's recorded KEY (a reconfigure), else DEFAULT.
openclaw_recorded=''
recorded_or() {
  local value
  value=$(awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' <<< "$openclaw_recorded")
  printf '%s\n' "${value:-$2}"
}
if [[ -n $ROUTER_CT_ID && -n $ROUTER_SSH_HOST ]] ||
   [[ -n $ROUTER && ( -n $ROUTER_CT_ID || -n $ROUTER_SSH_HOST ) ]]; then
  die 'Set only one of ROUTER, ROUTER_CT_ID, or ROUTER_SSH_HOST.'
fi
# ask_router: the Router section. A CT ID on this host, or the IP/hostname
# of the router's LXC/VM, reached as root over SSH.
ask_router() {
  [[ -z $ROUTER_CT_ID && -z $ROUTER_SSH_HOST ]] || return 0
  [[ -n $ROUTER ]] || pve_interactive ||
    die 'Set ROUTER to the router CT ID on this host, or the IP/hostname of the router LXC/VM (root SSH login).'
  pve_section 'Router'
  pve_note "A router CT ID on this Proxmox host, or the IP/hostname of its LXC/VM (reached as $ROUTER_SSH_USER over SSH)."
  pve_suggest ROUTER 'Router CT ID or address' "${PVE_ROUTER_SUGGESTION:-$(pve_tagged_ct osr-router)}" valid_router \
    'Use a CT ID (100 or more), an IPv4 address or a hostname.'
}
if [[ $mode == create ]]; then
  ask_router
else
  if [[ $mode == integrate ]]; then pve_ask_existing_ct openclaw OpenClaw register; else pve_ask_existing_ct openclaw OpenClaw; fi
  [[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'OpenClaw CT_ID must be numeric and at least 100; it is separate from the router CT ID or IP.'
  if (( ! dry_run )) && command -v pct >/dev/null && pct status "$CT_ID" 2>/dev/null | grep -q 'status: running'; then
    # What the CT records: the defaults for every question below.
    openclaw_recorded=$(pct exec "$CT_ID" -- cat /etc/openclaw-target/settings 2>/dev/null | tr -d '\r' || true)
    if [[ $(recorded_or ROUTER_URL '') =~ ^https?://([0-9.]+): ]]; then
      # shellcheck disable=SC2034  # read by ask_router
      PVE_ROUTER_SUGGESTION=$(pve_ct_with_ip "${BASH_REMATCH[1]}")
    fi
  fi
  ask_router
fi
if [[ -z $ROUTER_CT_ID && -z $ROUTER_SSH_HOST ]]; then
  [[ -n $ROUTER ]] || die 'Set ROUTER to the router CT ID on this host, or the IP/hostname of the router LXC/VM (root SSH login).'
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
  [[ $ROUTER_SSH_USER == root ]] || die 'ROUTER_SSH_USER must be root (it reads /app/router/secrets.env).'
  [[ $ROUTER_SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( ROUTER_SSH_PORT <= 65535 )) || die 'Invalid ROUTER_SSH_PORT.'
  router_kind=ssh
  router_label="router ${ROUTER_SSH_USER}@${ROUTER_SSH_HOST}"
fi
if [[ $mode == create ]]; then
  pve_ask_new_ct OpenClaw
  [[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'OpenClaw CT_ID must be numeric and at least 100; it is separate from the router CT ID or IP.'
  pve_select_template TEMPLATE "$template_re"
  positive ROOTFS_GB "$ROOTFS_GB"
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
  pve_suggest TEMPLATE 'Debian 12/13 amd64 template' '' valid_template 'Use a downloaded Debian 12/13 amd64 template (storage:vztmpl/...).'
  pve_suggest STORAGE 'Root disk storage' '' valid_storage
  pve_ask_network OpenClaw
fi
[[ $router_kind == ssh || $CT_ID != "$ROUTER_CT_ID" ]] || die 'OpenClaw and router CT IDs must differ.'

if [[ $mode != integrate ]]; then
  pve_section 'OpenClaw settings'
  pve_note 'OpenClaw needs an OSR model that calls tools, with 32768 tokens of context or more.'
  pve_ask OPENCLAW_MODEL 'OSR model or tier' "$(recorded_or OPENCLAW_MODEL auto)" valid_model
  pve_ask OPENCLAW_CONTEXT_LENGTH 'Context window the model serves (tokens)' "$(recorded_or OPENCLAW_CONTEXT_LENGTH 65536)" valid_context \
    'Use a whole number of tokens, 32768 or more.'
  pve_ask OPENCLAW_MAX_TOKENS 'Max reply tokens' "$(recorded_or OPENCLAW_MAX_TOKENS 8192)" valid_tokens 'Use a whole number of tokens.'
  pve_ask_yes_no OPENWEBUI 'Offer OpenClaw in Open WebUI (as openclaw)?' "$(recorded_or OPENCLAW_API true)"
  pve_ask_yes_no OPENCLAW_DASHBOARD 'Run the OpenClaw Control UI?' "$(recorded_or OPENCLAW_DASHBOARD true)"
  # Honcho memory: on a reconfigure the recorded one ("none" turns it off); on
  # a create the Honcho CT on this host is offered. Unattended creates never
  # turn it on by themselves.
  if [[ -z ${HONCHO_URL+set} ]]; then
    pve_section 'Honcho memory'
    pve_note 'Long-term memory in a Honcho workspace of OpenClaw'"'"'s own (like its Open Terminal workspace).'
    honcho_recorded=$(recorded_or HONCHO_URL '')
    if [[ -n $honcho_recorded ]]; then
      pve_ask HONCHO_URL 'Honcho API URL (none to turn off)' "$honcho_recorded" valid_honcho_url
    elif [[ $mode == create ]]; then
      honcho_ct_here=$(pve_tagged_ct honcho) honcho_offer=''
      [[ -z $honcho_ct_here ]] || honcho_offer="http://$(pve_ct_net "$honcho_ct_here" ip):8000"
      [[ $honcho_offer != 'http://:8000' ]] || honcho_offer=''
      HONCHO_URL=''
      pve_offer HONCHO_URL 'Honcho API URL' "$honcho_offer" valid_honcho_url
      [[ -n $HONCHO_URL ]] || unset HONCHO_URL
    else
      # A reconfigure of a CT without Honcho can turn it on; Enter keeps it off.
      honcho_ct_here=$(pve_tagged_ct honcho) honcho_offer=''
      [[ -z $honcho_ct_here ]] || honcho_offer="http://$(pve_ct_net "$honcho_ct_here" ip):8000"
      [[ $honcho_offer == 'http://:8000' || -z $honcho_offer ]] ||
        pve_note "Honcho CT $honcho_ct_here is at $honcho_offer; enter that to turn Honcho memory on."
      HONCHO_URL=''
      pve_offer HONCHO_URL 'Honcho API URL (Enter keeps it off)' '' valid_honcho_url
      [[ -n $HONCHO_URL ]] || unset HONCHO_URL
    fi
  fi
  if [[ -n ${HONCHO_URL:-} && -z ${HONCHO_CT_ID:-} && -z ${HONCHO_API_KEY_FILE:-} &&
        $HONCHO_URL =~ ^https?://([0-9.]+): ]]; then
    # This CT's gateway key comes from the Honcho CT at that address, when it is here.
    HONCHO_CT_ID=$(pve_ct_with_ip "${BASH_REMATCH[1]}")
    [[ -n $HONCHO_CT_ID ]] || unset HONCHO_CT_ID
  fi
  # Open Terminal: the same pattern (the recorded one on a reconfigure, the
  # terminal CT on this host offered on a create).
  if [[ -z ${OPEN_TERMINAL_URL+set} ]]; then
    pve_section 'Open Terminal workspace'
    pve_note 'A private workspace for OpenClaw in the Open Terminal CT, as MCP tools beside its own exec tool.'
    ot_recorded=$(recorded_or OPEN_TERMINAL_URL '')
    if [[ -n $ot_recorded ]]; then
      pve_ask OPEN_TERMINAL_URL 'Open Terminal URL (none to turn off)' "$ot_recorded" ot_valid_url
    elif [[ $mode == create ]]; then
      ot_ct_here=$(pve_tagged_ct open-terminal) ot_offer=''
      [[ -z $ot_ct_here ]] || ot_offer="http://$(pve_ct_net "$ot_ct_here" ip):8000"
      [[ $ot_offer != 'http://:8000' ]] || ot_offer=''
      OPEN_TERMINAL_URL=''
      pve_offer OPEN_TERMINAL_URL 'Open Terminal URL' "$ot_offer" ot_valid_url
      [[ -n $OPEN_TERMINAL_URL ]] || unset OPEN_TERMINAL_URL
    fi
  fi
fi
OPENWEBUI=${OPENWEBUI:-true}
OPENCLAW_MODEL=${OPENCLAW_MODEL:-auto}
OPENCLAW_CONTEXT_LENGTH=${OPENCLAW_CONTEXT_LENGTH:-65536}
OPENCLAW_MAX_TOKENS=${OPENCLAW_MAX_TOKENS:-8192}
OPENCLAW_DASHBOARD=${OPENCLAW_DASHBOARD:-true}
for name in CORES MEMORY_MB ROOTFS_GB OPENCLAW_PORT; do positive "$name" "${!name}"; done
(( OPENCLAW_PORT <= 65535 )) || die 'OPENCLAW_PORT must be <=65535.'
(( OPENCLAW_PORT != 8765 )) || die 'OPENCLAW_PORT 8765 is the local dispatcher.'
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'Invalid SWAP_MB.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'Invalid CT_HOSTNAME.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be IPv4.'
[[ -z $ROUTER_IP ]] || ipv4 "$ROUTER_IP" || die 'ROUTER_IP must be IPv4.'
if [[ -n $VLAN_TAG ]]; then
  positive VLAN_TAG "$VLAN_TAG"
  (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be <=4094.'
fi
[[ $EGRESS =~ ^(restricted|open)$ ]] || die 'EGRESS must be restricted or open.'
[[ $OPENWEBUI =~ ^(true|false)$ ]] || die 'OPENWEBUI must be true or false.'
[[ $OPENCLAW_DASHBOARD =~ ^(true|false)$ ]] || die 'OPENCLAW_DASHBOARD must be true or false.'
[[ $mode != integrate || $OPENWEBUI == true ]] || die '--integrate-only needs OPENWEBUI=true.'
if [[ -n $OPENWEBUI_PORT ]]; then
  positive OPENWEBUI_PORT "$OPENWEBUI_PORT"
  (( OPENWEBUI_PORT <= 65535 )) || die 'OPENWEBUI_PORT must be <=65535.'
fi
[[ -z $TASK_MODEL || $TASK_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid TASK_MODEL.'
[[ $TASK_MODEL != openclaw && $TASK_MODEL != openclaw/* && $TASK_MODEL != openclaw:* ]] ||
  die 'TASK_MODEL must be a router model, not an OpenClaw agent.'
if [[ -n $ROUTER_URL ]]; then
  [[ $ROUTER_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] ||
    die 'ROUTER_URL must be an HTTP(S) host and port, such as http://router-address:8000 (no /v1).'
  ROUTER_URL=${ROUTER_URL%/}
fi
[[ $OPENCLAW_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid OPENCLAW_MODEL.'
[[ $OPENCLAW_CONTEXT_LENGTH =~ ^[1-9][0-9]{4,6}$ ]] && (( OPENCLAW_CONTEXT_LENGTH >= 32768 )) ||
  die 'OPENCLAW_CONTEXT_LENGTH must be at least 32768 (OpenClaw needs room for its prompt, tools and history).'
[[ $OPENCLAW_MAX_TOKENS =~ ^[1-9][0-9]{2,6}$ ]] && (( OPENCLAW_MAX_TOKENS >= 256 && OPENCLAW_MAX_TOKENS * 2 <= OPENCLAW_CONTEXT_LENGTH )) ||
  die 'OPENCLAW_MAX_TOKENS must be at least 256 and at most half of OPENCLAW_CONTEXT_LENGTH.'
[[ $OPENCLAW_VERSION =~ ^([a-z][a-z0-9-]{0,31}|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$ ]] ||
  die 'OPENCLAW_VERSION must be an npm dist-tag (latest, beta) or an exact version such as 2026.10.9.'
[[ $OPENCLAW_NODE_VERSION =~ ^(24|26)(\.[0-9]+\.[0-9]+)?$ ]] ||
  die 'OPENCLAW_NODE_VERSION must be 24 or 26, or an exact 24.x.y or 26.x.y.'
[[ $NVM_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'NVM_VERSION must be an nvm release tag such as v0.40.4.'
[[ -z $NVM_INSTALLER_SHA256 || $NVM_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
  die 'NVM_INSTALLER_SHA256 must be 64 lowercase hex digits.'
if [[ $mode == create ]]; then
  [[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] ||
    die 'TEMPLATE must be a downloaded Debian 12/13 amd64 LXC template.'
  [[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
  valid_cidr "$IP_CIDR" || die 'IP_CIDR must be a static IPv4/CIDR address.'
  ipv4 "$GATEWAY" || die 'GATEWAY must be IPv4.'
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Open WebUI is checked with the Open Terminal target's probe (same router);
# the dispatcher is the Hermes target's, run with this target's files.
verify_webui=$source_dir/../open-terminal/verify-webui.py
direct_dispatch=$source_dir/../hermes/direct-dispatch.py
for file in "$source_dir/../pve-firewall-swap.pl" "$source_dir/install-target.sh" "$source_dir/openclaw-gateway.service" \
            "$source_dir/openclaw-direct.service" "$direct_dispatch" \
            "$source_dir/integrate-webui.py" "$verify_webui"; do
  [[ -r $file ]] || die "Deployment file is missing: $file"
done
# A given OPEN_TERMINAL_URL is checked now; unset, a reconfigure takes the
# recorded one below.
ot_valid_url "${OPEN_TERMINAL_URL:-}" || die 'OPEN_TERMINAL_URL must be the terminal gateway as http://IPv4:port.'
[[ -z ${OPEN_TERMINAL_CT_ID:-} || $OPEN_TERMINAL_CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'OPEN_TERMINAL_CT_ID must be a CT ID.'
[[ -z ${OPEN_TERMINAL_KEY_FILE:-} || -s ${OPEN_TERMINAL_KEY_FILE:-} ]] || die "OPEN_TERMINAL_KEY_FILE is empty or missing: ${OPEN_TERMINAL_KEY_FILE:-}"
# Overridable for tests only.
PVE_ETC=${PVE_ETC:-/etc/pve}
[[ $PVE_ETC == / ]] || PVE_ETC=${PVE_ETC%/}
SYS_NET_DIR=${SYS_NET_DIR:-/sys/class/net}
firewall_file=$PVE_ETC/firewall/${CT_ID}.fw
deploy=/root/openclaw-deploy

stage=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-setup.XXXXXX")
router_stage=''
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
  rm -f -- "$stage/admin-token" "$stage/router-api-key" "$stage/backend-keys" "$stage/openclaw-api-key" "$stage/router-auth" "$stage/honcho-api-key" "$stage/open-terminal-key" 2>/dev/null || true
  rm -rf -- "$stage" 2>/dev/null || true
  if (( rc != 0 && ! dry_run )); then
    printf 'Setup stopped. CT %s, if created, is retained: fix the error and re-run with --reconfigure.\n' "$CT_ID" >&2
  fi
}
trap cleanup EXIT

# --- the router: reachable, its key, its address and port ----------------------------
# The router's Kindi read budget; a dry run shows where it comes from.
kindi_timeout='<router.ini kindi_read_timeout_seconds>'
if (( ! dry_run )); then
  # id, not $EUID, so the tests can run the whole flow without root.
  [[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'
  for command_name in pveversion pct pvesh pvesm curl python3; do
    command -v "$command_name" >/dev/null || die "Missing command: $command_name"
  done
  [[ -d $PVE_ETC/nodes ]] || die 'Proxmox cluster filesystem is unavailable.'
  if [[ $router_kind == ct ]]; then
    pct status "$ROUTER_CT_ID" 2>/dev/null | grep -q 'status: running' ||
      die "Router CT ${ROUTER_CT_ID} is not a running CT on this host. For a router elsewhere, set ROUTER to its IP address or hostname."
  else
    command -v ssh >/dev/null || die 'Missing command: ssh'
    note "Connecting to ${router_label} over SSH..."
    router_exec true || die "Cannot log in to ${router_label} on port ${ROUTER_SSH_PORT}."
  fi
  router_exec test -f /app/router/router.py ||
    die "No ollama-smart-router at /app/router on ${router_label}."
  kindi_timeout=$(router_exec python3 -c 'import configparser, math, sys; c=configparser.ConfigParser(); c.read(sys.argv[1]); print(math.ceil(max(c.getfloat("http", "read_timeout_seconds", fallback=300), c.getfloat("http", "kindi_read_timeout_seconds", fallback=3600))))' /app/router/router.ini) ||
    die "Cannot read the router timeout on ${router_label}."
  kindi_timeout=${kindi_timeout//[$'\r\n ']/}
  [[ $kindi_timeout =~ ^[1-9][0-9]{0,5}$ ]] || die "Invalid router Kindi timeout: $kindi_timeout"
  # Straight into a 0600 file: the key never passes through argv or a variable.
  router_exec awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' /app/router/secrets.env \
    > "$stage/router-api-key" 2>/dev/null || : > "$stage/router-api-key"
  router_exec awk -F= '$1 ~ /^(LMSTUDIO_API_TOKEN|STRATA_API_KEY|BASALT_API_KEY|MAYA_API_KEY|XOLOTL_API_KEY|AVALON_API_KEY|KINDI_API_KEY)$/ {print}' /app/router/secrets.env \
    > "$stage/backend-keys" 2>/dev/null || : > "$stage/backend-keys"
  if [[ -s $stage/router-api-key ]]; then
    note "Read ROUTER_API_KEY from ${router_label}."
  else
    note "Warning: ${router_label} has no ROUTER_API_KEY (authentication is off). OpenClaw will use a placeholder key."
  fi
  router_port=$(router_exec sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env 2>/dev/null | head -n1" || true)
  router_port=${router_port//[$'\r\n ']/}
  router_port=${router_port:-8000}
  positive ROUTER_PORT "$router_port"
  if [[ $OPENWEBUI == true ]]; then
    router_exec systemctl is-active --quiet open-webui.service ||
      die "Open WebUI (open-webui.service) is not active on ${router_label}. Set OPENWEBUI=false for an OpenClaw without Open WebUI."
    router_exec sh -c 'command -v python3 >/dev/null' || die "python3 is missing on ${router_label}."
    if [[ -z $OPENWEBUI_PORT ]]; then
      OPENWEBUI_PORT=$(router_exec sh -c "sed -n 's/^PORT=//p' /app/openwebui/.env 2>/dev/null | head -n1" || true)
      OPENWEBUI_PORT=${OPENWEBUI_PORT//[$'\r\n ']/}
      OPENWEBUI_PORT=${OPENWEBUI_PORT:-8080}
      positive OPENWEBUI_PORT "$OPENWEBUI_PORT"
    fi
  fi
else
  router_port=8000
  OPENWEBUI_PORT=${OPENWEBUI_PORT:-8080}
  printf '+ read ROUTER_API_KEY from /app/router/secrets.env on %s into a 0600 file\n' "$router_label"
  printf '+ read model-server keys from /app/router/secrets.env on %s into a 0600 file\n' "$router_label"
fi

# --- the OpenClaw CT's address, and the router's address as seen from it --------
if [[ $mode == create ]]; then
  OPENCLAW_IP=${IP_CIDR%%/*}
  if (( ! dry_run )); then
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null 2>&1 || die "CT ID $CT_ID is already used. To change an existing OpenClaw CT, use --reconfigure."
    [[ -d $SYS_NET_DIR/$BRIDGE ]] || die "Bridge does not exist: $BRIDGE"
    [[ -r $(pvesm path "$TEMPLATE") ]] || die "Template is unreadable: $TEMPLATE"
    pvesm status --content rootdir | awk -v s="$STORAGE" '$1==s && $3=="active" {found=1} END {exit !found}' ||
      die 'STORAGE is inactive or does not support rootdir.'
    [[ ! -e $firewall_file ]] || die "Refusing to replace existing firewall file: $firewall_file"
  fi
elif (( dry_run )); then
  OPENCLAW_IP='<openclaw-eth0-ip>'
else
  pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "OpenClaw CT $CT_ID is not running on this host."
  if pct exec "$CT_ID" -- test -f /etc/openclaw-target/settings; then
    :
  elif [[ $mode == reconfigure && -f $firewall_file ]] &&
       pve_ct_described "$CT_ID" "$OPENCLAW_CT_DESCRIPTION"; then
    note "CT $CT_ID has no completed OpenClaw settings; resuming its partial installation."
  else
    die "CT $CT_ID has no completed OpenClaw installation. A partial install can be resumed only when this target's CT description and firewall file remain."
  fi
  if [[ $mode == integrate ]]; then
    pct exec "$CT_ID" -- grep -qx 'OPENCLAW_API=true' /etc/openclaw-target/settings ||
      die "CT $CT_ID has OpenClaw's chat completions endpoint off; use --reconfigure (with OPENWEBUI=true) to turn it on."
  fi
  OPENCLAW_IP=$(pct exec "$CT_ID" -- sh -c "ip -4 -o addr show dev eth0 | awk 'NR==1 {split(\$4,a,\"/\"); print a[1]}'")
  ipv4 "$OPENCLAW_IP" || die "Cannot detect CT $CT_ID's IPv4 on eth0."
  # Unset, HONCHO_URL keeps the Honcho memory recorded by the last run, so a
  # plain --reconfigure keeps its firewall rule; HONCHO_URL= turns it off.
  # The recorded URL also names the Honcho to revoke this CT's key on when
  # Honcho is turned off or moved.
  honcho_prev_url=$(pct exec "$CT_ID" -- sh -c 'sed -n "s/^HONCHO_URL=//p" /etc/openclaw-target/settings 2>/dev/null | head -n 1' | tr -d '\r')
  if [[ $mode == reconfigure && -z ${HONCHO_URL+set} ]]; then
    HONCHO_URL=$honcho_prev_url
    [[ -z $HONCHO_URL ]] || note "Keeping Honcho memory at $HONCHO_URL (set HONCHO_URL= to turn it off)."
    if [[ -n $HONCHO_URL && -z ${HONCHO_CT_ID:-} && -z ${HONCHO_API_KEY_FILE:-} ]]; then
      HONCHO_CT_ID=$(pve_ct_with_ip "$(hc_url_ip "$HONCHO_URL")")
      [[ -n $HONCHO_CT_ID ]] || unset HONCHO_CT_ID
    fi
  fi
  # The same for Open Terminal; the recorded URL also names the terminal to
  # disconnect from when it is turned off or moved.
  ot_prev_url=$(pct exec "$CT_ID" -- sh -c 'sed -n "s/^OPEN_TERMINAL_URL=//p" /etc/openclaw-target/settings 2>/dev/null | head -n 1' | tr -d '\r')
  if [[ $mode == reconfigure && -z ${OPEN_TERMINAL_URL+set} ]]; then
    OPEN_TERMINAL_URL=$ot_prev_url
    [[ -z $OPEN_TERMINAL_URL ]] || note "Keeping the Open Terminal workspace at $OPEN_TERMINAL_URL (set OPEN_TERMINAL_URL= to disconnect)."
  fi
fi
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL:-}
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL%/}
ot_valid_url "$OPEN_TERMINAL_URL" || die "The recorded OPEN_TERMINAL_URL is invalid: $OPEN_TERMINAL_URL"
ot_prev_url=${ot_prev_url:-}
honcho_prev_url=${honcho_prev_url:-}
if [[ -n $OPEN_TERMINAL_URL && -z ${OPEN_TERMINAL_CT_ID:-} && -z ${OPEN_TERMINAL_KEY_FILE:-} ]]; then
  # The key is issued by the terminal CT at that address, when it is here.
  OPEN_TERMINAL_CT_ID=$(pve_ct_with_ip "$(ot_url_ip "$OPEN_TERMINAL_URL")")
fi
OPEN_TERMINAL_CT_ID=${OPEN_TERMINAL_CT_ID:-}
if [[ -z $ROUTER_IP ]]; then
  if (( dry_run )); then
    ROUTER_IP='<router-source-ip>'
  else
    ROUTER_IP=$(router_exec ip -4 route get "$OPENCLAW_IP" | route_src)
    ipv4 "$ROUTER_IP" || die "Cannot tell which address ${router_label} uses to reach ${OPENCLAW_IP}; set ROUTER_IP."
  fi
fi
ROUTER_URL=${ROUTER_URL:-http://$ROUTER_IP:$router_port}
router_host=$(url_host "$ROUTER_URL")
router_dest=$router_host
if ! ipv4 "$router_dest"; then
  if (( dry_run )); then
    router_dest="<$router_host>"
  else
    router_dest=$(getent ahostsv4 "$router_host" | awk 'NR==1 {print $1}')
    ipv4 "$router_dest" || die "Cannot resolve $router_host to IPv4 for the firewall; use an IPv4 ROUTER_URL or EGRESS=open."
  fi
fi

# The router's API must answer with this key before a CT is made for it.
if (( dry_run )); then
  printf '+ verify %s/v1/models answers with the router key\n' "$ROUTER_URL"
  printf '+ discover model servers from %s/routing/inventory for direct targets and firewall rules\n' "$ROUTER_URL"
elif [[ $mode != integrate ]]; then
  : > "$stage/router-auth"
  if [[ -s $stage/router-api-key ]]; then
    printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$stage/router-api-key")" > "$stage/router-auth"
  fi
  status=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' -H "@$stage/router-auth" "$ROUTER_URL/v1/models" || true)
  case $status in
    200) ;;
    401|403) die "The router at $ROUTER_URL rejected the key from ${router_label}'s secrets.env (HTTP $status)." ;;
    *) die "The router at $ROUTER_URL did not answer /v1/models from this host (HTTP ${status:-none}). Check ROUTER_URL and the router CT's firewall (API_ALLOW_CIDR must include $OPENCLAW_IP)." ;;
  esac
fi

model_rules=()
model_endpoints=()
model_egress=$EGRESS
if [[ $mode == reconfigure && -f $firewall_file ]] &&
   grep -Eq '^policy_out:[[:space:]]*DROP[[:space:]]*$' "$firewall_file"; then
  model_egress=restricted
fi
# The registered model servers: OpenClaw's direct targets, and with restricted
# egress the firewall's model endpoints.
: > "$stage/targets"
if [[ $mode != integrate ]] && (( ! dry_run )); then
  status=$(curl --silent --show-error --max-time 15 -o "$stage/inventory" -w '%{http_code}' \
    -H "@$stage/router-auth" "$ROUTER_URL/routing/inventory" || true)
  [[ $status == 200 ]] || die "Could not read router model inventory (HTTP ${status:-none})."
  inventory_targets "$stage/inventory" > "$stage/targets" || die 'Could not parse router model inventory.'
fi
if [[ $mode != integrate && $model_egress == restricted ]]; then
  if (( ! dry_run )); then
    endpoints=$(inventory_endpoints "$stage/inventory") || die 'Could not parse router model inventory.'
    mapfile -t model_endpoints <<< "$endpoints"
  else
    model_endpoints=('<inventory-model-server> <port>')
  fi
  # An existing CT resolves model server host names now; a new one once it runs.
  if [[ $mode == create ]]; then model_rules_for ips; else model_rules_for all; fi
fi
add_honcho_rule() {
  [[ -n ${HONCHO_URL:-} && $model_egress == restricted ]] || return 0
  [[ $HONCHO_URL =~ ^http://([0-9]+(\.[0-9]+){3}):([0-9]{2,5})$ ]] ||
    die 'HONCHO_URL must use an IPv4 address and port for restricted egress.'
  model_rules+=("OUT ACCEPT -dest ${BASH_REMATCH[1]}/32 -p tcp -dport ${BASH_REMATCH[3]} -log nolog # ${FW_TAG}-model")
}
add_honcho_rule
# The Open Terminal gateway, owned like the model rules (replaced on reconfigure).
add_open_terminal_rule() {
  [[ -n $OPEN_TERMINAL_URL && $model_egress == restricted ]] || return 0
  model_rules+=("OUT ACCEPT -dest $(ot_url_ip "$OPEN_TERMINAL_URL")/32 -p tcp -dport $(ot_url_port "$OPEN_TERMINAL_URL") -log nolog # ${FW_TAG}-model")
}
add_open_terminal_rule

pve_summary "OpenClaw: $mode"
pve_row 'Router' "$router_label, $ROUTER_URL"
if [[ $mode == create ]]; then
  pve_row 'OpenClaw CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
  pve_row 'Template' "$TEMPLATE"
  pve_row 'Network' "$IP_CIDR via $GATEWAY on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
else
  pve_row 'OpenClaw CT' "$CT_ID at $OPENCLAW_IP"
fi
if [[ $mode != integrate ]]; then
  pve_row 'Model' "$OPENCLAW_MODEL (context $OPENCLAW_CONTEXT_LENGTH, replies up to $OPENCLAW_MAX_TOKENS tokens)"
  pve_row 'OpenClaw release' "$OPENCLAW_VERSION (Node.js $OPENCLAW_NODE_VERSION)"
  pve_row 'Open WebUI' "$( [[ $OPENWEBUI == true ]] && printf 'offered as openclaw' || printf 'not offered')"
  pve_row 'Control UI' "$( [[ $OPENCLAW_DASHBOARD == true ]] && printf 'on (port %s)' "$OPENCLAW_PORT" || printf 'off')"
  pve_row 'Egress' "$model_egress"
  pve_row 'Honcho memory' "${HONCHO_URL:-off}"
  pve_row 'Open Terminal' "${OPEN_TERMINAL_URL:-off}"
fi
case $mode in
  create) pve_confirm "Create OpenClaw CT $CT_ID?" ;;
  reconfigure) pve_confirm "Reconfigure OpenClaw CT $CT_ID?" ;;
  *) pve_confirm "Register OpenClaw CT $CT_ID in Open WebUI?" ;;
esac

admin_token=''
if [[ $OPENWEBUI == true ]] && (( ! dry_run )); then
  note "Verifying Open WebUI on ${router_label} (localhost:${OPENWEBUI_PORT})..."
  webui_version=$(router_exec python3 -c "$(cat "$verify_webui")" "$OPENWEBUI_PORT") ||
    die "No healthy Open WebUI responded on ${router_label} port ${OPENWEBUI_PORT}; nothing was created."
  note "Verified Open WebUI ${webui_version} on ${router_label}."
  admin_token=$saved_admin_token
  if [[ -z $admin_token ]]; then
    [[ -t 0 ]] || die 'Set OPENWEBUI_ADMIN_TOKEN to an Open WebUI admin API key or JWT for unattended use (or OPENWEBUI=false).'
    printf '\n== Open WebUI ==\n' >&2
    read -r -s -p '  Open WebUI admin API key or JWT (not shown): ' admin_token
    printf '\n'
  fi
  [[ -n $admin_token ]] || die 'An Open WebUI admin API key or JWT is required.'
  printf '%s\n' "$admin_token" > "$stage/admin-token"
fi
unset admin_token saved_admin_token

api_rule_port=''
[[ $OPENWEBUI == false ]] || api_rule_port=$OPENCLAW_PORT
dashboard_rule_port=''
[[ $OPENCLAW_DASHBOARD == false ]] || dashboard_rule_port=$OPENCLAW_PORT
fw_router_port=$(url_port "$ROUTER_URL")

# --- the OpenClaw CT ---------------------------------------------------------------
if [[ $mode == create ]]; then
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT" --tags 'ai;ai-tools;osr-target;openclaw'
    --description "$OPENCLAW_CT_DESCRIPTION")
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  # Keep the mapped rootfs traversable while Proxmox extracts the template.
  (umask 022; run "${create[@]}")

  firewall=$(firewall_config "$EGRESS" "$ROUTER_IP" "$router_dest" "$fw_router_port" "$api_rule_port" "$dashboard_rule_port")
  if (( dry_run )); then
    printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
  else
    printf '%s\n' "$firewall" > "$firewall_file"
  fi
  run pct start "$CT_ID"
  if (( ! dry_run )); then
    ready=0
    for (( attempt=0; attempt<60; attempt++ )); do
      if pct exec "$CT_ID" -- sh -c 'test -d /run/systemd/system && ip route show default | grep -q . && getent hosts deb.debian.org >/dev/null && getent hosts registry.npmjs.org >/dev/null' 2>/dev/null; then
        ready=1; break
      fi
      sleep 3
    done
    (( ready )) || die "CT $CT_ID has no systemd, default route or DNS after 180 seconds; check GATEWAY, NAMESERVER and the bridge."
  else
    printf '+ wait for systemd, a default route and DNS in CT %s\n' "$CT_ID"
  fi
  # Model servers given by host name: admitted now that the CT can resolve them.
  if (( ${#model_endpoints[@]} )); then
    if (( dry_run )); then
      printf '+ resolve model server host names inside CT %s and admit their addresses in %s\n' "$CT_ID" "$firewall_file"
    else
      model_rules_for all
      add_honcho_rule
      add_open_terminal_rule
      fw_seen=$(fw_snapshot "$firewall_file")
      fw_replace "$firewall_file" "$fw_seen" "$(firewall_config "$EGRESS" "$ROUTER_IP" "$router_dest" "$fw_router_port" "$api_rule_port" "$dashboard_rule_port")" ||
        die "Could not update $firewall_file (it changed meanwhile, or the write failed). CT $CT_ID is kept: fix the file, then rerun --reconfigure."
    fi
  fi
fi
# A reconfigured CT made by hand or by an older version gets the tags
# tools/upgrade-all.sh finds it by (--integrate-only leaves the CT as it is).
if [[ $mode == reconfigure ]]; then pve_ensure_tags "$CT_ID" ai ai-tools osr-target openclaw; fi

# --reconfigure: the CT's owned firewall rules follow the new settings (router
# address, port, Open WebUI, Control UI). Before anything in the CT changes,
# the file must be readable as ours, and the new rules are added next to the
# old ones: the guest installer reaches the router through them, and a failed
# run leaves the CT reachable as before. After the guest step, only the new
# rules stay.
if [[ $mode == reconfigure ]]; then
  if (( dry_run )); then
    printf '+ check the OpenClaw rules in %s, and admit the new router address and port next to the old ones\n' "$firewall_file"
  elif [[ -e $firewall_file ]]; then
    fw_seen=$(fw_snapshot "$firewall_file")
    fw_new=$(openclaw_fw_update "$fw_seen" keep "$ROUTER_IP" "$api_rule_port" "$router_dest" "$fw_router_port" "$dashboard_rule_port") ||
      die "Nothing was changed. Fix $firewall_file (or move it aside), then rerun --reconfigure."
    fw_replace "$firewall_file" "$fw_seen" "$fw_new" ||
      die "Nothing was changed: $firewall_file changed while it was read, or could not be written. Rerun --reconfigure."
  else
    note "Warning: $firewall_file does not exist, so CT $CT_ID's traffic is not filtered by Proxmox. Leaving it that way; a new OpenClaw CT gets one."
  fi
fi

if [[ $mode != integrate ]]; then
  guest_env=("ROUTER_URL=$ROUTER_URL" "OPENCLAW_MODEL=$OPENCLAW_MODEL"
    "OPENCLAW_CONTEXT_LENGTH=$OPENCLAW_CONTEXT_LENGTH" "OPENCLAW_MAX_TOKENS=$OPENCLAW_MAX_TOKENS"
    "OPENCLAW_VERSION=$OPENCLAW_VERSION" "OPENCLAW_NODE_VERSION=$OPENCLAW_NODE_VERSION"
    "NVM_VERSION=$NVM_VERSION" "OPENCLAW_API=$OPENWEBUI" "OPENCLAW_PORT=$OPENCLAW_PORT"
    "OPENCLAW_DASHBOARD=$OPENCLAW_DASHBOARD")
  # Unset, the guest pins the known SHA-256 of nvm v0.40.4; set (even empty), it is passed on.
  [[ $nvm_sha_set != set ]] || guest_env+=("NVM_INSTALLER_SHA256=$NVM_INSTALLER_SHA256")
  # Empty turns off a Honcho memory set up earlier.
  guest_env+=("HONCHO_URL=${HONCHO_URL:-}")
  # Empty disconnects an Open Terminal workspace set up earlier.
  guest_env+=("OPEN_TERMINAL_URL=$OPEN_TERMINAL_URL")
  guest_env+=("KINDI_READ_TIMEOUT_SECONDS=$kindi_timeout")
  run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
  run pct push "$CT_ID" "$source_dir/install-target.sh" "$deploy/install-target.sh" --perms 0755
  run pct push "$CT_ID" "$source_dir/openclaw-gateway.service" "$deploy/openclaw-gateway.service" --perms 0644
  run pct push "$CT_ID" "$source_dir/openclaw-direct.service" "$deploy/openclaw-direct.service" --perms 0644
  run pct push "$CT_ID" "$direct_dispatch" "$deploy/direct-dispatch.py" --perms 0644
  run pct push "$CT_ID" "$stage/backend-keys" "$deploy/backend-keys" --perms 0600
  run pct push "$CT_ID" "$stage/targets" "$deploy/targets" --perms 0644
  if (( dry_run )) || [[ -s $stage/router-api-key ]]; then
    run pct push "$CT_ID" "$stage/router-api-key" "$deploy/router-api-key" --perms 0600
  fi
  if [[ -n ${HONCHO_URL:-} ]]; then
    honcho_key_push=true
    if [[ -n ${HONCHO_CT_ID:-} ]]; then
      # This CT's own key for the Honcho CT's gateway, pinned to a workspace
      # of this CT's own. A key Honcho still accepts is kept, so a
      # reconfigure does not rotate it.
      honcho_have=''
      (( dry_run )) || honcho_have=$(hc_key_sha256 "$CT_ID" "$deploy/honcho-api-key")
      hc_connect "$HONCHO_CT_ID" "$(hc_client_name openclaw "$CT_ID")" "$honcho_have" "$stage/honcho-api-key"
      if (( ! dry_run )) && [[ ! -s $stage/honcho-api-key ]]; then honcho_key_push=false; fi
    elif (( ! dry_run )); then
      if [[ -n ${HONCHO_API_KEY_FILE:-} ]]; then
        cp -- "$HONCHO_API_KEY_FILE" "$stage/honcho-api-key"
      elif pct exec "$CT_ID" -- test -s "$deploy/honcho-api-key"; then
        honcho_key_push=false
        note "Using the Honcho key already in CT $CT_ID; set HONCHO_CT_ID to fetch it again."
      else
        die 'Set HONCHO_CT_ID or HONCHO_API_KEY_FILE with HONCHO_URL.'
      fi
      [[ $honcho_key_push == false || -s $stage/honcho-api-key ]] || die 'Honcho API key is empty.'
    fi
    [[ $honcho_key_push == false ]] ||
      run pct push "$CT_ID" "$stage/honcho-api-key" "$deploy/honcho-api-key" --perms 0600
  fi
  # Open Terminal: this CT's own client key, issued by the terminal CT, which
  # also admits this CT in its firewall. A key the terminal still accepts is
  # kept, so a reconfigure does not rotate it.
  ot_client=$(ot_client_name openclaw "$CT_ID")
  if [[ -n $OPEN_TERMINAL_URL ]]; then
    if [[ -n ${OPEN_TERMINAL_KEY_FILE:-} ]]; then
      run pct push "$CT_ID" "$OPEN_TERMINAL_KEY_FILE" "$deploy/open-terminal-key" --perms 0600
    elif [[ -n $OPEN_TERMINAL_CT_ID ]]; then
      ot_have=''
      if (( ! dry_run )); then
        ot_have=$(pct exec "$CT_ID" -- sh -c "[ -s $deploy/open-terminal-key ] && tr -d '\\r\\n\\t ' < $deploy/open-terminal-key | sha256sum | cut -d' ' -f1" | tr -d '\r' || true)
      fi
      ot_connect "$OPEN_TERMINAL_CT_ID" "$OPENCLAW_IP" "$ot_client" "$ot_have" "$stage/open-terminal-key"
      if (( ! dry_run )) && [[ -s $stage/open-terminal-key ]]; then
        run pct push "$CT_ID" "$stage/open-terminal-key" "$deploy/open-terminal-key" --perms 0600
      fi
    elif (( ! dry_run )) && pct exec "$CT_ID" -- test -s "$deploy/open-terminal-key"; then
      note "Using the Open Terminal key already in CT $CT_ID; set OPEN_TERMINAL_CT_ID to connect it again."
    else
      die 'Set OPEN_TERMINAL_CT_ID (the terminal CT on this host) or OPEN_TERMINAL_KEY_FILE with OPEN_TERMINAL_URL.'
    fi
  fi
  run pct exec "$CT_ID" -- env "${guest_env[@]}" bash "$deploy/install-target.sh"
fi

# The guest step succeeded: drop the old rules (a stale router address or port,
# or the API port of a CT that no longer serves Open WebUI).
if [[ $mode == reconfigure ]]; then
  if (( dry_run )); then
    printf '+ sync OpenClaw rules in %s (router %s, API port %s, Control UI %s)\n' "$firewall_file" "$ROUTER_IP" \
      "${api_rule_port:-closed}" "${dashboard_rule_port:-closed}"
  elif [[ -e $firewall_file ]]; then
    fw_seen=$(fw_snapshot "$firewall_file")
    fw_new=$(openclaw_fw_update "$fw_seen" replace "$ROUTER_IP" "$api_rule_port" "$router_dest" "$fw_router_port" "$dashboard_rule_port") ||
      die "OpenClaw is reconfigured, but $firewall_file changed meanwhile and still admits the old router address or port. Fix it, then rerun --reconfigure."
    fw_replace "$firewall_file" "$fw_seen" "$fw_new" ||
      die "OpenClaw is reconfigured, but $firewall_file changed while its old rules were being removed (or could not be written); it still admits the old and new rules. Check it, then rerun --reconfigure."
  fi
fi

# The guest no longer uses the Honcho it was connected to (turned off, or moved
# to another one): revoke its key there. Its memories stay in osr.
# (The same Honcho CT at another URL keeps the key it just checked.)
if [[ $mode != integrate && -n $honcho_prev_url && $honcho_prev_url != "${HONCHO_URL:-}" ]] &&
   [[ -z ${HONCHO_URL:-} || $(hc_url_ip "$honcho_prev_url") != "$(hc_url_ip "$HONCHO_URL")" ]]; then
  honcho_prev_ct=$(pve_ct_with_ip "$(hc_url_ip "$honcho_prev_url")")
  if [[ -n $honcho_prev_ct ]]; then
    hc_disconnect "$honcho_prev_ct" "$(hc_client_name openclaw "$CT_ID")"
  else
    note "Revoke client $(hc_client_name openclaw "$CT_ID") on the Honcho at $honcho_prev_url by hand (honcho-clients revoke)."
  fi
fi

# The guest no longer uses the terminal it was connected to (turned off, or
# moved to another one): revoke its key and firewall rule there.
if [[ $mode != integrate && -n $ot_prev_url && $ot_prev_url != "$OPEN_TERMINAL_URL" ]]; then
  ot_prev_ct=$(pve_ct_with_ip "$(ot_url_ip "$ot_prev_url")")
  if [[ -n $ot_prev_ct ]]; then
    ot_disconnect "$ot_prev_ct" "$(ot_client_name openclaw "$CT_ID")"
  else
    note "Revoke client $(ot_client_name openclaw "$CT_ID") on the Open Terminal at $ot_prev_url by hand (open-terminal-clients revoke)."
  fi
fi

# --- register it with Open WebUI on the router ---------------------------------------
if [[ $OPENWEBUI == true ]]; then
  run pct pull "$CT_ID" /etc/openclaw-target/api-key "$stage/openclaw-api-key"
  if (( dry_run )); then
    router_stage='<router-stage>'
    router_run mktemp -d /root/openclaw-integration.XXXXXX
  else
    # Validated before it is recorded: cleanup removes router_stage recursively.
    made=$(router_exec mktemp -d /root/openclaw-integration.XXXXXX)
    made=${made//[$'\r\n']/}
    [[ $made =~ ^/root/openclaw-integration\.[A-Za-z0-9]{6}$ ]] ||
      die "Unexpected router staging path: $made (not removed; check ${router_label} by hand)"
    router_stage=$made
  fi
  router_push "$stage/openclaw-api-key" "$router_stage/openclaw-api-key"
  router_push "$stage/admin-token" "$router_stage/admin-token"
  router_push "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py"
  router_run python3 "$router_stage/integrate-webui.py" \
    --webui-url "http://127.0.0.1:${OPENWEBUI_PORT}" \
    --openclaw-url "http://${OPENCLAW_IP}:${OPENCLAW_PORT}/v1" \
    --model-name openclaw --task-model "$TASK_MODEL" \
    --admin-token-file "$router_stage/admin-token" --openclaw-key-file "$router_stage/openclaw-api-key"
  (( dry_run )) && router_stage=''
fi

oc_shell="pct exec $CT_ID -- runuser -u openclaw -- env HOME=/home/openclaw PATH=/home/openclaw/.local/bin:/usr/bin:/bin openclaw"
printf 'OpenClaw CT %s discovers via %s and dispatches model osr/%s directly.\n' "$CT_ID" "$ROUTER_URL" "$OPENCLAW_MODEL"
if [[ $OPENWEBUI == true ]]; then
  printf 'Open WebUI: choose "openclaw" in the model list. Check its visibility under Admin Settings > Models before sharing it:\n'
  printf 'whoever can chat with it runs tools as the openclaw account in CT %s and shares one OpenClaw agent and memory.\n' "$CT_ID"
fi
if [[ $mode != integrate && $OPENCLAW_DASHBOARD == true ]]; then
  printf 'Control UI: http://%s:%s/ . Log in with the Gateway token, read on this host with:\n' "$OPENCLAW_IP" "$OPENCLAW_PORT"
  printf '  pct exec %s -- cat /etc/openclaw-target/api-key\n' "$CT_ID"
  printf 'then approve the browser: %s devices list ; %s devices approve <requestId>\n' "$oc_shell" "$oc_shell"
fi
printf 'CLI: %s\n' "$oc_shell"
