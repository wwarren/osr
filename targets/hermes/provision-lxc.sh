#!/usr/bin/env bash
# Run on a Proxmox VE host. Creates an unprivileged CT for Hermes Agent, points
# it at an existing ollama-smart-router with the router's API key, and (by
# default) registers Hermes's API server in that router's Open WebUI. The
# router can be a CT on this host (reached with pct) or any LXC or VM that root
# can log in to over SSH.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run] [--reconfigure | --integrate-only]
   or: CT_ID=282 ROUTER=280 TEMPLATE=local:vztmpl/debian-13-standard_..._amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.168.11.82/24 GATEWAY=192.168.11.1 \
       bash provision-lxc.sh [--dry-run] [--reconfigure | --integrate-only]

Creates a dedicated unprivileged Debian 12/13 LXC, installs Hermes Agent with
its official installer, configures a CT-local dispatcher to discover models
from the router and call their servers directly, and adds Hermes to Open WebUI as the
model "hermes-agent". It asks for an Open WebUI admin API key or session JWT
unless OPENWEBUI_ADMIN_TOKEN is set (or OPENWEBUI=false).

The router is given as ROUTER:
  ROUTER=280                a CT on this Proxmox host, reached with pct
  ROUTER=192.168.11.80      any LXC or VM, reached as root over SSH
When ROUTER is not set, the script asks for it. ROUTER_CT_ID or ROUTER_SSH_HOST
force one kind.

Required: CT_ID, ROUTER (or the prompt); for a new CT also TEMPLATE (Debian
          12/13 amd64), STORAGE (active rootdir storage), IP_CIDR, GATEWAY.
Interactive runs list downloaded templates and eligible rootdir storage when
those values are unset. CT_ID is the Hermes CT,
separate from the existing router CT ID or IP address.
Hermes:   HERMES_MODEL=auto, HERMES_CONTEXT_LENGTH=65536 (>=64000; the model's
          host must serve it), HERMES_CHANNEL=stable, HERMES_COMMIT,
          HERMES_INSTALLER_SHA256, HERMES_API_PORT=8642,
          HERMES_API_MODEL_NAME=hermes-agent.
Router:   ROUTER_URL (default http://<router address>:<router port>),
          ROUTER_IP (the address the router uses to reach this CT; detected),
          ROUTER_SSH_PORT=22.
Open WebUI: OPENWEBUI=true (false: CLI only, no API server), OPENWEBUI_PORT
          (read from the router), TASK_MODEL=fast (router model for Open WebUI
          titles and tags; blank leaves the setting alone).
Network:  EGRESS=restricted (outbound to router, registered model servers,
          DNS and internet HTTP(S); other private destinations dropped) or open.
          Model server host names are resolved inside the Hermes CT; a URL
          without a port means port 80 (http) or 443 (https).
CT:       BRIDGE=vmbr0, CT_HOSTNAME=hermes-agent, CORES=2, MEMORY_MB=4096,
          SWAP_MB=1024, ROOTFS_GB=32, ONBOOT=1, NAMESERVER, VLAN_TAG.

--dry-run         print the plan without touching Proxmox or the router.
--reconfigure     an existing Hermes CT (CT_ID): push the current router key,
                  installer, dispatcher and units, rerun with these settings,
                  update its API firewall rule, then register it again. Use
                  after set-api-key on the router.
--integrate-only  register an existing Hermes CT's API server in Open WebUI.
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
FW_TAG='ollama-smart-router hermes'

# hermes_fw_rules ROUTER_IP API_PORT ROUTER_DEST ROUTER_PORT RESTRICTED: the
# owned rules. Inbound: only the router, to the API server (an empty API_PORT
# admits nothing). Restricted egress also admits inventory model hosts.
hermes_fw_rules() {
  local rule
  [[ -z $2 ]] || printf 'IN ACCEPT -source %s/32 -p tcp -dport %s -log nolog # %s-api\n' "$1" "$2" "$FW_TAG"
  [[ $5 != true ]] || printf 'OUT ACCEPT -dest %s/32 -p tcp -dport %s -log nolog # %s-router\n' "$3" "$4" "$FW_TAG"
  if [[ $5 == true ]]; then
    for rule in "${model_rules[@]-}"; do [[ -z $rule ]] || printf '%s\n' "$rule"; done
  fi
}

# firewall_config EGRESS ROUTER_IP ROUTER_DEST ROUTER_PORT API_PORT: the CT's
# /etc/pve/firewall/<id>.fw. The owned rules, then for restricted outbound: DNS,
# then HTTP(S) to anything that is not a private, CGNAT or link-local address.
# Proxmox applies the first matching rule.
firewall_config() {
  local egress=$1 router_ip=$2 router_dest=$3 router_port=$4 api_port=$5 net restricted=false
  [[ $egress != restricted ]] || restricted=true
  printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n'
  if $restricted; then printf 'policy_out: DROP\n'; else printf 'policy_out: ACCEPT\n'; fi
  printf '\n[RULES]\n'
  hermes_fw_rules "$router_ip" "$api_port" "$router_dest" "$router_port" "$restricted"
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

# hermes_fw_update FILE KEEP ROUTER_IP API_PORT ROUTER_DEST ROUTER_PORT
#                  OLD_API_SERVER OLD_API_PORT: FILE
# with this target's rules replaced by the current ones, at the top of [RULES]
# so they match first; every other line is kept as it is. KEEP=keep also keeps
# the old owned rules (marked), so a reconfigure that fails half-way leaves the
# CT reachable as before. The egress mode is read from the file's policy_out.
#
# Owned rules are found by their comment. Files written before the comment have
# none: there the generated layout is recognised (the API rule first in [RULES]
# with the port recorded in the guest's prior settings, then the router rule;
# or the API rule between "# BEGIN/END ollama-smart-router Hermes API" lines).
# An unmarked inbound rule in a previously CLI-only CT is never adopted.
hermes_fw_update() {
  local file=$1 keep=$2 router_ip=$3 api_port=$4 router_dest=$5 router_port=$6
  local old_api_server=${7:-unknown} old_api_port=${8:-}
  local begin='# BEGIN ollama-smart-router Hermes API' end='# END ollama-smart-router Hermes API'
  local in_re='^IN ACCEPT -source [0-9.]+/32 -p tcp -dport [0-9]+ -log nolog$'
  local out_re='^OUT ACCEPT -dest [0-9.]+/32 -p tcp -dport [0-9]+ -log nolog$'
  local mark_re=" # ${FW_TAG}-(api|router|model)\$"
  local -a lines=() rest=() old=() rules=()
  local -A owned=()
  local rule_re='^(IN|OUT) '
  local i line section='' sections=0 begins=0 bad_block=0 in_block=0 marked=0 restricted=false
  local pos=0 n_in=0 n_out=0 idx rule have seen_rules=0
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
    if [[ $line == "$begin" ]]; then
      (( ! in_block )) || bad_block=1
      begins=$((begins + 1)); in_block=1; owned[$i]=1; continue
    fi
    if [[ $line == "$end" ]]; then
      (( in_block )) || bad_block=1
      in_block=0; owned[$i]=1; continue
    fi
    if (( in_block )); then
      owned[$i]=1; [[ ! $line =~ $rule_re ]] || old+=("$line"); continue
    fi
    if [[ $line =~ $mark_re ]]; then
      owned[$i]=1; old+=("$line")
      [[ $line == *" # ${FW_TAG}-model" ]] || marked=$((marked + 1))
      continue
    fi
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] || rest+=("$i")
  done
  if (( sections > 1 )); then
    printf 'Multiple [RULES] sections in %s; inspect the file before reconfiguring.\n' "$file" >&2
    return 1
  fi
  if (( begins > 1 || bad_block || in_block )); then
    printf 'Malformed "# BEGIN/END ollama-smart-router Hermes API" lines in %s; inspect the file.\n' "$file" >&2
    return 1
  fi
  if (( marked == 0 )); then
    for idx in "${rest[@]}"; do
      line=${lines[$idx]%$'\r'}
      [[ ! $line =~ $in_re ]] || n_in=$((n_in + 1))
      [[ ! $line =~ $out_re ]] || n_out=$((n_out + 1))
    done
    # The legacy API rule: unmarked, only without the BEGIN/END lines.
    if (( begins == 0 && n_in > 0 )); then
      line=${lines[${rest[0]}]%$'\r'}
      if [[ $old_api_server != true || ! $old_api_port =~ ^[1-9][0-9]{0,4}$ ]] ||
         (( n_in != 1 )) || [[ ! $line =~ $in_re || $line != *" -dport $old_api_port -log nolog" ]]; then
        printf 'Cannot tell which inbound rule in %s is the Hermes API rule; inspect it before reconfiguring.\n' "$file" >&2
        return 1
      fi
      owned[${rest[0]}]=1; old+=("$line"); pos=1
    fi
    # The legacy router rule: the first rule after the API rule.
    if $restricted && (( n_out > 0 )); then
      if (( n_out != 1 )) || (( ${#rest[@]} <= pos )) || [[ ! ${lines[${rest[$pos]}]%$'\r'} =~ $out_re ]]; then
        printf 'Cannot tell which outbound rule in %s is the Hermes router rule; inspect it before reconfiguring.\n' "$file" >&2
        return 1
      fi
      owned[${rest[$pos]}]=1; old+=("${lines[${rest[$pos]}]%$'\r'}")
    fi
  fi
  mapfile -t rules < <(hermes_fw_rules "$router_ip" "$api_port" "$router_dest" "$router_port" "$restricted")
  if [[ $keep == keep ]]; then
    for line in "${old[@]}"; do
      local old_tag=${line##* # ${FW_TAG}-}
      line=${line%% \#*}
      if [[ $line == IN\ * ]]; then rule="$line # ${FW_TAG}-api"
      elif [[ $old_tag == model ]]; then rule="$line # ${FW_TAG}-model"
      else rule="$line # ${FW_TAG}-router"; fi
      have=0
      for idx in "${rules[@]}"; do [[ $idx != "$rule" ]] || have=1; done
      (( have )) || rules+=("$rule")
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

# write_if_changed FILE CONTENT: replace FILE's content, unless it is the same.
write_if_changed() {
  [[ "$(cat -- "$1")" == "$2" ]] || printf '%s\n' "$2" > "$1"
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
    raise SystemExit("Router discovery is disabled; enable [discovery] before installing Hermes")
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
# End provision helpers. --------------------------------------------------------

positive() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }

# model_rules_for ips|all: the egress rules for model_endpoints. A host name is
# resolved INSIDE the Hermes CT, by the same resolver (glibc getaddrinfo) its
# dispatcher connects with, so the rules admit the addresses the dispatcher
# will actually use; every IPv4 address is admitted. "ips" leaves host names
# out, for a CT that is not running yet.
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
        note "Warning: CT $CT_ID cannot resolve model server $host, so it is not admitted; Hermes skips it. Fix the CT's DNS, then rerun --reconfigure."
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
prompt_required() {
  local name=$1 label=$2
  [[ -n ${!name} ]] && return 0
  [[ -t 0 ]] || die "Set ${name} for an unattended run (or run interactively to be prompted)."
  read -r -p "$label" "$name" || die "No ${name} was entered."
  [[ -n ${!name} ]] || die "${name} is required."
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
CT_HOSTNAME=${CT_HOSTNAME:-hermes-agent}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-4096}
SWAP_MB=${SWAP_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-32}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
EGRESS=${EGRESS:-restricted}
OPENWEBUI=${OPENWEBUI:-true}
OPENWEBUI_PORT=${OPENWEBUI_PORT:-}
TASK_MODEL=${TASK_MODEL-fast}
HERMES_MODEL=${HERMES_MODEL:-auto}
HERMES_CONTEXT_LENGTH=${HERMES_CONTEXT_LENGTH:-65536}
HERMES_CHANNEL=${HERMES_CHANNEL:-stable}
HERMES_COMMIT=${HERMES_COMMIT:-}
HERMES_INSTALLER_SHA256=${HERMES_INSTALLER_SHA256:-}
HERMES_API_PORT=${HERMES_API_PORT:-8642}
HERMES_API_MODEL_NAME=${HERMES_API_MODEL_NAME:-hermes-agent}
# Taken out of the environment at once so no child process (pct, ssh) inherits it.
saved_admin_token=${OPENWEBUI_ADMIN_TOKEN:-}
unset OPENWEBUI_ADMIN_TOKEN

# --- which router -------------------------------------------------------------------
if [[ -n $ROUTER_CT_ID && -n $ROUTER_SSH_HOST ]] ||
   [[ -n $ROUTER && ( -n $ROUTER_CT_ID || -n $ROUTER_SSH_HOST ) ]]; then
  die 'Set only one of ROUTER, ROUTER_CT_ID, or ROUTER_SSH_HOST.'
fi
if [[ -z $ROUTER_CT_ID && -z $ROUTER_SSH_HOST ]]; then
  if [[ -z $ROUTER ]]; then
    [[ -t 0 ]] || die 'Set ROUTER to the router CT ID on this host, or the IP/hostname of the router LXC/VM (root SSH login).'
    printf 'Existing ollama-smart-router:\n' >&2
    printf '  a CT ID on this Proxmox host (e.g. 280), or\n' >&2
    printf '  the IP address or hostname of its LXC/VM, reached as %s over SSH\n' "$ROUTER_SSH_USER" >&2
    read -r -p 'Router CT ID or IP address: ' ROUTER || die 'No router location was entered.'
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
  [[ $ROUTER_SSH_USER == root ]] || die 'ROUTER_SSH_USER must be root (it reads /app/router/secrets.env).'
  [[ $ROUTER_SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( ROUTER_SSH_PORT <= 65535 )) || die 'Invalid ROUTER_SSH_PORT.'
  router_kind=ssh
  router_label="router ${ROUTER_SSH_USER}@${ROUTER_SSH_HOST}"
fi

# --- validation, before anything is touched ---------------------------------------
if [[ $mode == create ]]; then
  prompt_required CT_ID 'New Hermes CT ID on this Proxmox host (unused, at least 100): '
else
  prompt_required CT_ID 'Existing Hermes CT ID on this Proxmox host: '
fi
[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'Hermes CT_ID must be numeric and at least 100; it is separate from the router CT ID or IP.'
[[ $router_kind == ssh || $CT_ID != "$ROUTER_CT_ID" ]] || die 'Hermes and router CT IDs must differ.'
if [[ $mode == create ]]; then
  pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
  positive ROOTFS_GB "$ROOTFS_GB"
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
  prompt_required TEMPLATE 'Downloaded Debian 12/13 amd64 template (e.g. local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst): '
  prompt_required STORAGE 'Storage for the new Hermes CT root disk (e.g. local-lvm): '
  prompt_required IP_CIDR 'Static IP/CIDR for the new Hermes CT: '
  prompt_required GATEWAY 'Gateway for the new Hermes CT: '
fi
for name in CORES MEMORY_MB ROOTFS_GB HERMES_API_PORT; do positive "$name" "${!name}"; done
(( HERMES_API_PORT <= 65535 )) || die 'HERMES_API_PORT must be <=65535.'
(( HERMES_API_PORT < 8644 || HERMES_API_PORT > 8646 )) || die 'HERMES_API_PORT 8644-8646 are reserved by Hermes.'
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
[[ $mode != integrate || $OPENWEBUI == true ]] || die '--integrate-only needs OPENWEBUI=true.'
if [[ -n $OPENWEBUI_PORT ]]; then
  positive OPENWEBUI_PORT "$OPENWEBUI_PORT"
  (( OPENWEBUI_PORT <= 65535 )) || die 'OPENWEBUI_PORT must be <=65535.'
fi
[[ -z $TASK_MODEL || $TASK_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid TASK_MODEL.'
[[ $TASK_MODEL != "$HERMES_API_MODEL_NAME" ]] || die 'TASK_MODEL must be a router model, not Hermes itself.'
if [[ -n $ROUTER_URL ]]; then
  [[ $ROUTER_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] ||
    die 'ROUTER_URL must be an HTTP(S) host and port, such as http://192.168.11.80:8000 (no /v1).'
  ROUTER_URL=${ROUTER_URL%/}
fi
[[ $HERMES_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid HERMES_MODEL.'
[[ $HERMES_CONTEXT_LENGTH =~ ^[1-9][0-9]{4,6}$ ]] && (( HERMES_CONTEXT_LENGTH >= 64000 )) ||
  die 'HERMES_CONTEXT_LENGTH must be at least 64000 (Hermes needs 64K context for tools).'
[[ $HERMES_CHANNEL =~ ^(stable|main)$ ]] || die 'HERMES_CHANNEL must be stable or main.'
[[ -z $HERMES_COMMIT || $HERMES_COMMIT =~ ^[0-9a-f]{40}$ ]] || die 'HERMES_COMMIT must be a full 40-digit lowercase SHA-1.'
[[ -z $HERMES_INSTALLER_SHA256 || $HERMES_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
  die 'HERMES_INSTALLER_SHA256 must be 64 lowercase hex digits.'
[[ $HERMES_API_MODEL_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$ ]] || die 'Invalid HERMES_API_MODEL_NAME.'
if [[ $mode == create ]]; then
  [[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] ||
    die 'TEMPLATE must be a downloaded Debian 12/13 amd64 LXC template.'
  [[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
  valid_cidr "$IP_CIDR" || die 'IP_CIDR must be a static IPv4/CIDR address.'
  ipv4 "$GATEWAY" || die 'GATEWAY must be IPv4.'
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Open WebUI is checked with the Open Terminal target's probe (same router).
verify_webui=$source_dir/../open-terminal/verify-webui.py
for file in "$source_dir/install-target.sh" "$source_dir/hermes-gateway.service" \
            "$source_dir/direct-dispatch.py" "$source_dir/hermes-direct.service" \
            "$source_dir/integrate-webui.py" "$verify_webui"; do
  [[ -r $file ]] || die "Deployment file is missing: $file"
done
# Overridable for tests only.
PVE_ETC=${PVE_ETC:-/etc/pve}
SYS_NET_DIR=${SYS_NET_DIR:-/sys/class/net}
firewall_file=$PVE_ETC/firewall/${CT_ID}.fw
deploy=/root/hermes-deploy

stage=$(mktemp -d "${TMPDIR:-/tmp}/hermes-setup.XXXXXX")
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
  rm -f -- "$stage/admin-token" "$stage/router-api-key" "$stage/backend-keys" "$stage/hermes-api-key" "$stage/router-auth" 2>/dev/null || true
  rm -rf -- "$stage" 2>/dev/null || true
  if (( rc != 0 && ! dry_run )); then
    printf 'Setup stopped. CT %s, if created, is retained: fix the error and re-run with --reconfigure.\n' "$CT_ID" >&2
  fi
}
trap cleanup EXIT

# --- the router: reachable, its key, its address and port ----------------------------
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
  # Straight into a 0600 file: the key never passes through argv or a variable.
  router_exec awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' /app/router/secrets.env \
    > "$stage/router-api-key" 2>/dev/null || : > "$stage/router-api-key"
  router_exec awk -F= '$1 ~ /^(LMSTUDIO_API_TOKEN|STRATA_API_KEY|BASALT_API_KEY|MAYA_API_KEY|XOLOTL_API_KEY)$/ {print}' /app/router/secrets.env \
    > "$stage/backend-keys" 2>/dev/null || : > "$stage/backend-keys"
  if [[ -s $stage/router-api-key ]]; then
    note "Read ROUTER_API_KEY from ${router_label}."
  else
    note "Warning: ${router_label} has no ROUTER_API_KEY (authentication is off). Hermes will use a placeholder key."
  fi
  router_port=$(router_exec sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env 2>/dev/null | head -n1" || true)
  router_port=${router_port//[$'\r\n ']/}
  router_port=${router_port:-8000}
  positive ROUTER_PORT "$router_port"
  if [[ $OPENWEBUI == true ]]; then
    router_exec systemctl is-active --quiet open-webui.service ||
      die "Open WebUI (open-webui.service) is not active on ${router_label}. Set OPENWEBUI=false for a CLI-only Hermes."
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

# --- the Hermes CT's address, and the router's address as seen from it ----------
if [[ $mode == create ]]; then
  HERMES_IP=${IP_CIDR%%/*}
  if (( ! dry_run )); then
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null 2>&1 || die "CT ID $CT_ID is already used. To change an existing Hermes CT, use --reconfigure."
    [[ -d $SYS_NET_DIR/$BRIDGE ]] || die "Bridge does not exist: $BRIDGE"
    [[ -r $(pvesm path "$TEMPLATE") ]] || die "Template is unreadable: $TEMPLATE"
    pvesm status --content rootdir | awk -v s="$STORAGE" '$1==s && $3=="active" {found=1} END {exit !found}' ||
      die 'STORAGE is inactive or does not support rootdir.'
    [[ ! -e $firewall_file ]] || die "Refusing to replace existing firewall file: $firewall_file"
  fi
elif (( dry_run )); then
  HERMES_IP='<hermes-eth0-ip>'
else
  pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "Hermes CT $CT_ID is not running on this host."
  pct exec "$CT_ID" -- test -f /etc/hermes-target/settings || die "CT $CT_ID has no Hermes installation from this target."
  if [[ $mode == integrate ]]; then
    pct exec "$CT_ID" -- test -s /etc/hermes-target/api-key ||
      die "CT $CT_ID runs no Hermes API server; use --reconfigure (with OPENWEBUI=true) to add it."
  fi
  HERMES_IP=$(pct exec "$CT_ID" -- sh -c "ip -4 -o addr show dev eth0 | awk 'NR==1 {split(\$4,a,\"/\"); print a[1]}'")
  ipv4 "$HERMES_IP" || die "Cannot detect CT $CT_ID's IPv4 on eth0."
fi
if [[ -z $ROUTER_IP ]]; then
  if (( dry_run )); then
    ROUTER_IP='<router-source-ip>'
  else
    ROUTER_IP=$(router_exec ip -4 route get "$HERMES_IP" | route_src)
    ipv4 "$ROUTER_IP" || die "Cannot tell which address ${router_label} uses to reach ${HERMES_IP}; set ROUTER_IP."
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
  printf '+ discover model-server endpoints from %s/routing/inventory for firewall rules\n' "$ROUTER_URL"
elif [[ $mode != integrate ]]; then
  : > "$stage/router-auth"
  if [[ -s $stage/router-api-key ]]; then
    printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$stage/router-api-key")" > "$stage/router-auth"
  fi
  status=$(curl --silent --max-time 10 -o /dev/null -w '%{http_code}' -H "@$stage/router-auth" "$ROUTER_URL/v1/models" || true)
  case $status in
    200) ;;
    401|403) die "The router at $ROUTER_URL rejected the key from ${router_label}'s secrets.env (HTTP $status)." ;;
    *) die "The router at $ROUTER_URL did not answer /v1/models from this host (HTTP ${status:-none}). Check ROUTER_URL and the router CT's firewall (API_ALLOW_CIDR must include $HERMES_IP)." ;;
  esac
fi

model_rules=()
model_endpoints=()
model_egress=$EGRESS
if [[ $mode == reconfigure && -f $firewall_file ]] &&
   grep -Eq '^policy_out:[[:space:]]*DROP[[:space:]]*$' "$firewall_file"; then
  model_egress=restricted
fi
if [[ $mode != integrate && $model_egress == restricted ]]; then
  if (( ! dry_run )); then
    status=$(curl --silent --show-error --max-time 15 -o "$stage/inventory" -w '%{http_code}' \
      -H "@$stage/router-auth" "$ROUTER_URL/routing/inventory" || true)
    [[ $status == 200 ]] || die "Could not read router model inventory (HTTP ${status:-none})."
    endpoints=$(inventory_endpoints "$stage/inventory") || die 'Could not parse router model inventory.'
    mapfile -t model_endpoints <<< "$endpoints"
  else
    model_endpoints=('<inventory-model-server> <port>')
  fi
  # An existing CT resolves model server host names now; a new one once it runs.
  if [[ $mode == create ]]; then model_rules_for ips; else model_rules_for all; fi
fi

admin_token=''
if [[ $OPENWEBUI == true ]] && (( ! dry_run )); then
  note "Verifying Open WebUI on ${router_label} (localhost:${OPENWEBUI_PORT})..."
  webui_version=$(router_exec python3 -c "$(cat "$verify_webui")" "$OPENWEBUI_PORT") ||
    die "No healthy Open WebUI responded on ${router_label} port ${OPENWEBUI_PORT}; nothing was created."
  note "Verified Open WebUI ${webui_version} on ${router_label}."
  admin_token=$saved_admin_token
  if [[ -z $admin_token ]]; then
    [[ -t 0 ]] || die 'Set OPENWEBUI_ADMIN_TOKEN to an Open WebUI admin API key or JWT for unattended use (or OPENWEBUI=false).'
    read -r -s -p 'Open WebUI admin API key or JWT: ' admin_token
    printf '\n'
  fi
  [[ -n $admin_token ]] || die 'An Open WebUI admin API key or JWT is required.'
  printf '%s\n' "$admin_token" > "$stage/admin-token"
fi
unset admin_token saved_admin_token

api_server=false
[[ $OPENWEBUI == false ]] || api_server=true
api_rule_port=''
[[ $api_server == false ]] || api_rule_port=$HERMES_API_PORT
fw_router_port=$(url_port "$ROUTER_URL")

# --- the Hermes CT -------------------------------------------------------------------
if [[ $mode == create ]]; then
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --description 'Hermes Agent for Ollama Smart Router')
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  run "${create[@]}"

  firewall=$(firewall_config "$EGRESS" "$ROUTER_IP" "$router_dest" "$fw_router_port" "$api_rule_port")
  if (( dry_run )); then
    printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
  else
    printf '%s\n' "$firewall" > "$firewall_file"
  fi
  run pct start "$CT_ID"
  if (( ! dry_run )); then
    ready=0
    for (( attempt=0; attempt<60; attempt++ )); do
      if pct exec "$CT_ID" -- sh -c 'test -d /run/systemd/system && ip route show default | grep -q . && getent hosts deb.debian.org >/dev/null && getent hosts hermes-agent.nousresearch.com >/dev/null' 2>/dev/null; then
        ready=1; break
      fi
      sleep 3
    done
    (( ready )) || die "CT $CT_ID has no systemd, default route or DNS after 180 seconds; check GATEWAY, NAMESERVER and the bridge."
  else
    printf '+ wait for systemd, a default route and DNS in CT %s\n' "$CT_ID"
  fi
  # QEMU guest agent: Proxmox does not use it for an LXC (no virtio-serial port, so
  # the service stays inactive), but every guest carries it. A failure is not fatal.
  run pct exec "$CT_ID" -- sh -c 'export DEBIAN_FRONTEND=noninteractive; for i in 1 2 3 4 5; do apt-get update -q && apt-get install -y -q qemu-guest-agent && exit 0; sleep 5; done; exit 1' ||
      printf 'Warning: qemu-guest-agent did not install in CT %s; continuing.\n' "$CT_ID" >&2
  # Model servers given by host name: admitted now that the CT can resolve them.
  if (( ${#model_endpoints[@]} )); then
    if (( dry_run )); then
      printf '+ resolve model server host names inside CT %s and admit their addresses in %s\n' "$CT_ID" "$firewall_file"
    else
      model_rules_for all
      write_if_changed "$firewall_file" "$(firewall_config "$EGRESS" "$ROUTER_IP" "$router_dest" "$fw_router_port" "$api_rule_port")" ||
        die "Could not write $firewall_file."
    fi
  fi
fi

# --reconfigure: the CT's owned firewall rules follow the new settings (router
# address, API port, CLI-only). Before anything in the CT changes, the file
# must be readable as ours, and the new rules are added next to the old ones:
# the guest installer reaches the router through them, and a failed run leaves
# the CT reachable as before. After the guest step, only the new rules stay.
if [[ $mode == reconfigure ]]; then
  if (( ! dry_run )); then
    old_settings=$(pct exec "$CT_ID" -- cat /etc/hermes-target/settings) ||
      die "Could not read CT $CT_ID's existing Hermes settings."
    old_api_server=$(sed -n 's/^HERMES_API_SERVER=//p' <<< "$old_settings" | head -n 1)
    old_api_port=$(sed -n 's/^HERMES_API_PORT=//p' <<< "$old_settings" | head -n 1)
  fi
  if (( dry_run )); then
    printf '+ check the Hermes rules in %s, and admit the new router address and port next to the old ones\n' "$firewall_file"
  elif [[ -e $firewall_file ]]; then
    fw_new=$(hermes_fw_update "$firewall_file" keep "$ROUTER_IP" "$api_rule_port" "$router_dest" "$fw_router_port" "$old_api_server" "$old_api_port") ||
      die "Nothing was changed. Fix $firewall_file (or move it aside), then rerun --reconfigure."
    write_if_changed "$firewall_file" "$fw_new" || die "Could not write $firewall_file."
  else
    note "Warning: $firewall_file does not exist, so CT $CT_ID's traffic is not filtered by Proxmox. Leaving it that way; a new Hermes CT gets one."
  fi
fi

if [[ $mode != integrate ]]; then
  run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
  run pct push "$CT_ID" "$source_dir/install-target.sh" "$deploy/install-target.sh" --perms 0755
  run pct push "$CT_ID" "$source_dir/hermes-gateway.service" "$deploy/hermes-gateway.service" --perms 0644
  run pct push "$CT_ID" "$source_dir/direct-dispatch.py" "$deploy/direct-dispatch.py" --perms 0644
  run pct push "$CT_ID" "$source_dir/hermes-direct.service" "$deploy/hermes-direct.service" --perms 0644
  run pct push "$CT_ID" "$stage/backend-keys" "$deploy/backend-keys" --perms 0600
  if (( dry_run )) || [[ -s $stage/router-api-key ]]; then
    run pct push "$CT_ID" "$stage/router-api-key" "$deploy/router-api-key" --perms 0600
  fi
  run pct exec "$CT_ID" -- env "ROUTER_URL=$ROUTER_URL" "HERMES_MODEL=$HERMES_MODEL" \
    "HERMES_CONTEXT_LENGTH=$HERMES_CONTEXT_LENGTH" "HERMES_CHANNEL=$HERMES_CHANNEL" \
    "HERMES_COMMIT=$HERMES_COMMIT" "HERMES_INSTALLER_SHA256=$HERMES_INSTALLER_SHA256" \
    "HERMES_API_SERVER=$api_server" "HERMES_API_PORT=$HERMES_API_PORT" \
    "HERMES_API_MODEL_NAME=$HERMES_API_MODEL_NAME" bash "$deploy/install-target.sh"
fi

# The guest step succeeded: drop the old rules (a stale router address or API
# port, or the API port of a CT that is now CLI-only).
if [[ $mode == reconfigure ]]; then
  if (( dry_run )); then
    printf '+ sync Hermes API rule in %s (router %s, port %s)\n' "$firewall_file" "$ROUTER_IP" "${api_rule_port:-closed}"
  elif [[ -e $firewall_file ]]; then
    fw_new=$(hermes_fw_update "$firewall_file" replace "$ROUTER_IP" "$api_rule_port" "$router_dest" "$fw_router_port" "$old_api_server" "$old_api_port") ||
      die "Hermes is reconfigured, but $firewall_file changed meanwhile and still admits the old router address or port. Fix it, then rerun --reconfigure."
    write_if_changed "$firewall_file" "$fw_new" || die "Could not write $firewall_file."
  fi
fi

# --- register it with Open WebUI on the router ---------------------------------------
if [[ $OPENWEBUI == true ]]; then
  run pct pull "$CT_ID" /etc/hermes-target/api-key "$stage/hermes-api-key"
  if (( dry_run )); then
    router_stage='<router-stage>'
    router_run mktemp -d /root/hermes-integration.XXXXXX
  else
    # Validated before it is recorded: cleanup removes router_stage recursively.
    made=$(router_exec mktemp -d /root/hermes-integration.XXXXXX)
    made=${made//[$'\r\n']/}
    [[ $made =~ ^/root/hermes-integration\.[A-Za-z0-9]{6}$ ]] ||
      die "Unexpected router staging path: $made (not removed; check ${router_label} by hand)"
    router_stage=$made
  fi
  router_push "$stage/hermes-api-key" "$router_stage/hermes-api-key"
  router_push "$stage/admin-token" "$router_stage/admin-token"
  router_push "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py"
  router_run python3 "$router_stage/integrate-webui.py" \
    --webui-url "http://127.0.0.1:${OPENWEBUI_PORT}" \
    --hermes-url "http://${HERMES_IP}:${HERMES_API_PORT}/v1" \
    --model-name "$HERMES_API_MODEL_NAME" --task-model "$TASK_MODEL" \
    --admin-token-file "$router_stage/admin-token" --hermes-key-file "$router_stage/hermes-api-key"
  (( dry_run )) && router_stage=''
fi

printf 'Hermes CT %s discovers via %s and dispatches model %s directly.\n' "$CT_ID" "$ROUTER_URL" "$HERMES_MODEL"
if [[ $OPENWEBUI == true ]]; then
  printf 'Open WebUI: choose "%s" in the model list. Check its visibility under Admin Settings > Models before sharing it:\n' "$HERMES_API_MODEL_NAME"
  printf 'whoever can chat with it runs tools as the hermes account in CT %s and shares one Hermes memory.\n' "$CT_ID"
fi
printf 'CLI: pct exec %s -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes\n' "$CT_ID"
