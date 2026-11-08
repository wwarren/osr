#!/usr/bin/env bash
# Run on the Proxmox host. Create or reconfigure a dedicated DeepSeek Harness
# LXC that uses an existing local OSR CT as its model provider and, optionally,
# Honcho as its long-term memory.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
usage() {
  cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run | --reconfigure]
Creates a dedicated unprivileged Debian 12/13 LXC for DeepSeek Harness Web.
The OSR router must be a running CT on the same Proxmox host. Its API key is
read from /app/router/secrets.env and copied to the new CT as a 0600 file.

Required: ROUTER_CT_ID; for a new CT also TEMPLATE, STORAGE, IP_CIDR, GATEWAY
  (interactive runs prompt for missing values). A new CT's CT_ID defaults to
  the cluster's next free ID (set it to choose another); --reconfigure asks.
Settings: DSH_MODEL=auto, DSH_CONTEXT_WINDOW=32768, DSH_MAX_TOKENS=8192,
  DSH_VERSION=0.2.1-rc.5 (or latest), DSH_PORT=3080,
  DSH_ACCESS_CIDR=<CT subnet>, DSH_ROUTER_FIREWALL=true.
Honcho memory: HONCHO_URL=http://<honcho-ip>:8000 with HONCHO_CT_ID (or
  HONCHO_API_KEY_FILE); HONCHO_MCP_URL overrides the derived
  http://<honcho-ip>:3000/mcp. HONCHO_URL= (set, empty) turns it off.
CT: BRIDGE=vmbr0, CT_HOSTNAME=deepseek-harness, CORES=2, MEMORY_MB=4096,
  SWAP_MB=1024, ROOTFS_GB=32, ONBOOT=1, NAMESERVER, VLAN_TAG.

--reconfigure updates the router key, model overlay, npm release, Honcho
memory and service inside the existing CT. It never creates or deletes a CT.
Settings it is not given keep the values the CT recorded on its last run.
USAGE
}

# Provision helpers
ipv4() {
  local octet
  local -a parts
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$1"
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
# cidr_network CIDR: the network address with its prefix (192.0.2.81/24 ->
# 192.0.2.0/24), the form a Proxmox firewall -source accepts.
cidr_network() {
  local address=${1%/*} prefix=${1#*/} a b c d value mask
  IFS=. read -r a b c d <<< "$address"
  value=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  value=$(( value & mask ))
  printf '%d.%d.%d.%d/%d\n' $(( value >> 24 & 255 )) $(( value >> 16 & 255 )) $(( value >> 8 & 255 )) $(( value & 255 )) "$prefix"
}
# record_value TEXT KEY: KEY's value in a KEY=VALUE record (never sourced).
record_value() {
  awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1; exit } END { exit !found }' <<< "$1"
}
# honcho_mcp_url API_URL: Honcho's MCP endpoint on the API's host (the Honcho
# target serves it on port 3000 at /mcp).
honcho_mcp_url() {
  [[ $1 =~ ^(https?)://([A-Za-z0-9][A-Za-z0-9._-]*)(:[0-9]{1,5})?/?$ ]] || return 1
  printf '%s://%s:3000/mcp\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# router_fw_with_dsh FILE IP PORT: FILE with this target's one rule (IP to the
# router API PORT) first in [RULES]; an older one is dropped, the rest kept.
router_fw_with_dsh() {
  awk -v rule="IN ACCEPT -source $2/32 -p tcp -dport $3 -log nolog # osr-deepseek-harness-router" '
    / # osr-deepseek-harness-router$/ { next }
    $0 == "[RULES]" && !seen { print; print rule; seen=1; next }
    { print }
    END { if (!seen) { print ""; print "[RULES]"; print rule } }
  ' "$1"
}
# Keep the old Web UI rule until the reconfigured guest is healthy. The new
# port is also reachable while its service starts; other rules stay in place.
harness_fw_transition() {
  awk -v rule="$2" '
    / # osr-deepseek-harness$/ {
      if (!seen) { print; if ($0 != rule) print rule; seen=1 }
      next
    }
    { print }
    END { if (!seen) exit 1 }
  ' "$1"
}
harness_fw_final() {
  awk -v rule="$2" '
    / # osr-deepseek-harness$/ { next }
    { print; if ($0 == "[RULES]") print rule }
  ' "$1"
}
# fw_swap FILE SEEN NEW: use Proxmox's per-CT firewall lock and an atomic rename.
# 0: replaced; 1: changed meanwhile; 2: staging, rename, or readback failed.
fw_swap() {
  local vmid=${1##*/}
  vmid=${vmid%.fw}
  perl "$source_dir/../pve-firewall-swap.pl" "$1" "$2" "$3" "$vmid" "${PVE_ETC:-}"
}
# guest_state BEFORE AFTER PORT: the record alone can prove a successful
# switchover. An unchanged record means the previous service only if the guest
# also cleared its rollback snapshot; the caller checks that separately.
guest_state() {
  local port
  if [[ $2 == "$1" ]]; then echo previous
  elif port=$(record_value "$2" DSH_PORT) && [[ $port == "$3" ]]; then echo switched
  else echo unknown; fi
}
# End provision helpers.
positive() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( ! dry_run )); then "$@"; fi
}

# PVE_ETC: tests point this at a fake /etc/pve so whole runs need no root.
PVE_ETC=${PVE_ETC:-/etc/pve}
[[ $PVE_ETC == / ]] || PVE_ETC=${PVE_ETC%/}
FW_DIR=$PVE_ETC/firewall
dry_run=0
mode=create
while (( $# )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --reconfigure) mode=reconfigure ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

ROUTER_CT_ID=${ROUTER_CT_ID:-${ROUTER:-}}
CT_ID=${CT_ID:-}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
BRIDGE=${BRIDGE:-vmbr0}
CT_HOSTNAME=${CT_HOSTNAME:-deepseek-harness}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-4096}
SWAP_MB=${SWAP_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-32}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
DSH_ROUTER_FIREWALL=${DSH_ROUTER_FIREWALL:-true}
DEFAULT_DSH_VERSION=0.2.1-rc.5
# Harness settings: DSH_* or the installer's DEEPSEEK_HARNESS_* names. Unset
# ones keep the CT's recorded value on a reconfigure, else take the default.
declare -A dsh_default=([MODEL]=auto [CONTEXT_WINDOW]=32768 [MAX_TOKENS]=8192 [VERSION]=$DEFAULT_DSH_VERSION [PORT]=3080)
declare -A dsh_given=()
for name in MODEL CONTEXT_WINDOW MAX_TOKENS VERSION PORT; do
  short=DSH_$name long=DEEPSEEK_HARNESS_$name
  if [[ -n ${!short:-} ]]; then dsh_given[$name]=${!short}
  elif [[ -n ${!long:-} ]]; then dsh_given[$name]=${!long}; fi
done
DSH_ACCESS_CIDR=${DSH_ACCESS_CIDR:-${DEEPSEEK_HARNESS_ACCESS_CIDR:-}}
honcho_url_set=${HONCHO_URL+set} honcho_mcp_set=${HONCHO_MCP_URL+set}
HONCHO_URL=${HONCHO_URL:-}
HONCHO_MCP_URL=${HONCHO_MCP_URL:-}
HONCHO_CT_ID=${HONCHO_CT_ID:-}
HONCHO_API_KEY_FILE=${HONCHO_API_KEY_FILE:-}

template_re='^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
valid_template() { [[ $1 =~ $template_re ]]; }
valid_storage() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_model() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]]; }
valid_tokens() { [[ $1 =~ ^[1-9][0-9]{3,8}$ ]]; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
valid_version() { [[ $1 =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)$ ]]; }
valid_honcho_url() { [[ -z $1 ]] || honcho_mcp_url "$1" >/dev/null; }
# recorded_or KEY DEFAULT: the CT's recorded KEY (a reconfigure), else DEFAULT.
recorded_or() {
  local value
  if [[ -n $recorded ]] && value=$(record_value "$recorded" "$1") && [[ -n $value ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$2"
  fi
}
for name in MODEL CONTEXT_WINDOW MAX_TOKENS VERSION PORT; do
  var=DSH_$name
  printf -v "$var" '%s' "${dsh_given[$name]:-}"
done

# --- Questions, one section at a time -----------------------------------------
recorded=''
if [[ $mode == create ]]; then
  pve_ask_router
  pve_ask_new_ct 'DeepSeek Harness'
  positive ROOTFS_GB "$ROOTFS_GB"
  pve_select_template TEMPLATE "$template_re"
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
  pve_suggest TEMPLATE 'Debian 12/13 amd64 template' '' valid_template 'Use a downloaded Debian 12/13 amd64 template (storage:vztmpl/...).'
  pve_suggest STORAGE 'Root disk storage' '' valid_storage
  pve_ask_network 'Harness'
else
  pve_ask_existing_ct deepseek-harness 'DeepSeek Harness'
  pve_valid_ct_id "$CT_ID" || die 'CT_ID must be a numeric Proxmox ID (100 or greater).'
  if (( ! dry_run )); then
    # What the CT records: the defaults for every question below.
    pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "Harness CT $CT_ID is not running."
    pve_ct_described "$CT_ID" 'DeepSeek Harness for Ollama Smart Router' ||
      die 'The selected CT is not this target; refusing to reconfigure it.'
    IP_CIDR=$(pct exec "$CT_ID" -- ip -4 -o addr show dev eth0 | awk 'NR==1 {print $4}')
    valid_cidr "$IP_CIDR" || die 'Cannot determine the Harness CT IPv4 address.'
    recorded=$(pct exec "$CT_ID" -- cat /etc/deepseek-harness/settings 2>/dev/null | tr -d '\r' || true)
    [[ -n $recorded ]] || note "CT $CT_ID has no settings record (made by the first version of this target); the defaults below are this target's."
    recorded_router=$(record_value "$recorded" DSH_ROUTER_URL 2>/dev/null || true)
    if [[ $recorded_router =~ ^https?://([0-9.]+): ]]; then
      # shellcheck disable=SC2034  # read by pve_ask_router
      PVE_ROUTER_SUGGESTION=$(pve_ct_with_ip "${BASH_REMATCH[1]}")
    fi
  fi
  pve_ask_router
fi
pve_valid_ct_id "$ROUTER_CT_ID" && pve_valid_ct_id "$CT_ID" ||
  die 'ROUTER_CT_ID and CT_ID must be numeric Proxmox IDs (100 or greater).'
[[ $ROUTER_CT_ID != "$CT_ID" ]] || die 'Harness and router CT IDs must differ.'

pve_section 'DeepSeek Harness settings'
pve_note 'A concrete OSR model that calls tools gives steadier agent sessions than a tier (auto, fast, ...).'
pve_ask DSH_MODEL 'OSR model or tier' "$(recorded_or DSH_MODEL "${dsh_default[MODEL]}")" valid_model
pve_ask DSH_CONTEXT_WINDOW 'Context window the model serves (tokens)' \
  "$(recorded_or DSH_CONTEXT_WINDOW "${dsh_default[CONTEXT_WINDOW]}")" valid_tokens 'Use a whole number of tokens, 1000 or more.'
pve_ask DSH_MAX_TOKENS 'Max reply tokens' "$(recorded_or DSH_MAX_TOKENS "${dsh_default[MAX_TOKENS]}")" valid_tokens \
  'Use a whole number of tokens, 1000 or more (less than the context window).'
pve_ask DSH_PORT 'Web UI port' "$(recorded_or DSH_PORT "${dsh_default[PORT]}")" valid_port 'Use a port from 1 to 65535.'
access_default=''
if [[ $mode == reconfigure && -r $FW_DIR/${CT_ID}.fw ]]; then
  access_default=$(sed -nE 's/.*-source ([0-9.]+\/[0-9]+).*# osr-deepseek-harness$/\1/p' "$FW_DIR/${CT_ID}.fw" | head -n1)
elif valid_cidr "${IP_CIDR:-}"; then
  access_default=$(cidr_network "$IP_CIDR")
fi
# A dry-run reconfigure cannot read the CT's firewall; it plans without a range.
valid_access() { valid_cidr "$1" || [[ -z $1 && $mode == reconfigure && $dry_run == 1 ]]; }
pve_ask DSH_ACCESS_CIDR 'Web UI allowed from (IPv4 CIDR)' "$access_default" valid_access 'Use a.b.c.d/nn, e.g. your LAN.'
pve_ask DSH_VERSION 'Harness npm release' "$(recorded_or DSH_VERSION "${dsh_default[VERSION]}")" valid_version \
  'Use an exact npm version (e.g. 0.2.1-rc.5) or latest.'
if [[ $DSH_VERSION != "$DEFAULT_DSH_VERSION" && -n $recorded ]]; then
  note "This target is tested with $DEFAULT_DSH_VERSION; answer $DEFAULT_DSH_VERSION to move to it."
fi

# Honcho memory: given, else on a reconfigure the recorded one, else (asked) the
# Honcho CT on this host. An unattended create never turns it on by itself.
honcho_mcp=''
if [[ -n $HONCHO_MCP_URL ]]; then honcho_mcp=$HONCHO_MCP_URL
elif [[ -z $honcho_url_set && -z $honcho_mcp_set ]]; then
  honcho_recorded=$(recorded_or DSH_HONCHO_MCP_URL '')
  honcho_ct_here=$(pve_tagged_ct honcho)
  honcho_offer=''
  if [[ $honcho_recorded =~ ^(https?://[^/:]+) ]]; then honcho_offer="${BASH_REMATCH[1]}:8000"
  elif [[ -n $honcho_ct_here && $mode == create ]]; then
    honcho_ip_here=$(pve_ct_net "$honcho_ct_here" ip)
    [[ -z $honcho_ip_here ]] || honcho_offer="http://$honcho_ip_here:8000"
  fi
  pve_section 'Honcho memory'
  pve_note 'Shared long-term memory with Hermes and OpenClaw (the osr workspace).'
  if [[ -n $honcho_recorded ]]; then
    # A recorded Honcho stays on unattended; "none" turns it off.
    pve_ask HONCHO_URL 'Honcho API URL (none to turn off)' "$honcho_offer" valid_honcho_url
  else
    pve_offer HONCHO_URL 'Honcho API URL' "$honcho_offer" valid_honcho_url
  fi
fi
[[ -n $honcho_mcp || -z $HONCHO_URL ]] || honcho_mcp=$(honcho_mcp_url "$HONCHO_URL")
if [[ -n $honcho_mcp && -z $HONCHO_CT_ID && -z $HONCHO_API_KEY_FILE ]]; then
  # The workspace key comes from the Honcho CT at that address, when it is here.
  [[ ! $honcho_mcp =~ ^https?://([0-9.]+)[:/] ]] || HONCHO_CT_ID=$(pve_ct_with_ip "${BASH_REMATCH[1]}")
fi
[[ -z $HONCHO_CT_ID || ( $HONCHO_CT_ID =~ ^[1-9][0-9]{2,8}$ && $HONCHO_CT_ID != "$CT_ID" ) ]] ||
  die 'HONCHO_CT_ID must be the Honcho CT ID (100 or greater), not this CT.'

# --- Checks ---------------------------------------------------------------------
for name in CORES MEMORY_MB ROOTFS_GB; do positive "$name" "${!name}"; done
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ && $ONBOOT =~ ^[01]$ ]] || die 'Invalid SWAP_MB or ONBOOT.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'Invalid CT_HOSTNAME.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be IPv4.'
[[ -z $VLAN_TAG ]] || { positive VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be <=4094.'; }
[[ -z $DSH_ACCESS_CIDR ]] || valid_cidr "$DSH_ACCESS_CIDR" || die 'DSH_ACCESS_CIDR must be an IPv4 CIDR.'
[[ $DSH_ROUTER_FIREWALL =~ ^(true|false)$ ]] || die 'DSH_ROUTER_FIREWALL must be true or false.'
[[ -z $HONCHO_URL ]] || honcho_mcp_url "$HONCHO_URL" >/dev/null ||
  die 'HONCHO_URL must be the Honcho API origin, e.g. http://192.0.2.85:8000.'
[[ -z $HONCHO_MCP_URL || $HONCHO_MCP_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] ||
  die 'HONCHO_MCP_URL must be an HTTP(S) URL such as http://192.0.2.85:3000/mcp.'
[[ -z $HONCHO_API_KEY_FILE || -r $HONCHO_API_KEY_FILE ]] || die "Cannot read HONCHO_API_KEY_FILE: $HONCHO_API_KEY_FILE"
if [[ $mode == create ]]; then
  valid_template "$TEMPLATE" || die 'TEMPLATE must be a Debian 12/13 amd64 archive.'
  valid_storage "$STORAGE" || die 'Invalid STORAGE.'
  valid_cidr "$IP_CIDR" && ipv4 "$GATEWAY" || die 'IP_CIDR and GATEWAY must be valid IPv4 settings.'
fi
for name in DSH_PORT DSH_CONTEXT_WINDOW DSH_MAX_TOKENS; do positive "$name" "${!name}"; done
(( DSH_PORT <= 65535 && DSH_MAX_TOKENS < DSH_CONTEXT_WINDOW )) || die 'Invalid port or token capacity (max reply tokens must be below the context window).'
valid_version "$DSH_VERSION" || die 'Invalid DSH_VERSION.'
valid_model "$DSH_MODEL" || die 'Invalid DSH_MODEL.'
[[ -z $DSH_ACCESS_CIDR ]] || DSH_ACCESS_CIDR=$(cidr_network "$DSH_ACCESS_CIDR")
if [[ -n $honcho_mcp ]]; then
  (( DSH_CONTEXT_WINDOW >= 32768 )) ||
    die 'Honcho memory adds about 40 tool definitions; set DSH_CONTEXT_WINDOW to 32768 or more.'
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in install-target.sh configure.mjs deepseek-harness.service ../pve-firewall-swap.pl; do
  [[ -r $source_dir/$file ]] || die "Deployment file missing: $source_dir/$file"
done
stage=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-target.XXXXXX")
firewall_txn_active=false
preserve_stage=false
interrupted=''
ct_fw_before='' router_fw_before='' router_fw_written=false
# restore_fw FILE BEFORE WRITTEN LABEL: put FILE back as it was before this run,
# but only while it still holds what this run wrote (WRITTEN). An edit made
# meanwhile (the GUI, another provisioner) is kept and the backup is reported.
restore_fw() {
  local file=$1 before=$2 written=$3 label=$4 result=0
  fw_swap "$file" "$written" "$before" || result=$?
  case $result in
    0) return 0 ;;
    1) note "The $label firewall $file changed during this run; it was not restored." ;;
    *) note "Could not restore the $label firewall $file." ;;
  esac
  note "  Its previous content is in $before."
  return 1
}
finish() {
  local status=$? keep_backups=false
  trap - EXIT
  [[ -z $interrupted ]] || status=$interrupted
  if (( status != 0 )) && $firewall_txn_active; then
    if [[ -n $interrupted ]]; then
      # The guest may still be installing: both Web UI rules stay, so neither
      # the old nor the new port is shut. A rerun finishes the change.
      note "Interrupted: the CT firewall still admits the old and new Web UI rules. Rerun with --reconfigure to finish."
    else
      restore_fw "$FW_DIR/${CT_ID}.fw" "$ct_fw_before" "$stage/firewall.transition" 'Harness CT' || keep_backups=true
      if $router_fw_written; then
        restore_fw "$FW_DIR/${ROUTER_CT_ID}.fw" "$router_fw_before" "$stage/router.fw" 'router CT' || keep_backups=true
      fi
    fi
  fi
  if $keep_backups || $preserve_stage; then
    # Only the firewall copies are kept: never the router or Honcho key.
    rm -f -- "$stage/router-api-key" "$stage/honcho-api-key"
    note "Firewall backups remain in $stage for manual recovery."
  else
    rm -rf -- "$stage"
  fi
  exit "$status"
}
trap finish EXIT
# Without these, bash runs the EXIT trap with $? = 0 after a signal.
trap 'interrupted=130; exit 130' INT
trap 'interrupted=143; exit 143' TERM
trap 'interrupted=129; exit 129' HUP
deploy=/root/deepseek-harness-deploy

if (( ! dry_run )); then
  # id, not $EUID, so the tests can run the whole flow without root.
  [[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'
  for command_name in pct pvesh pvesm perl; do
    command -v "$command_name" >/dev/null || die "Missing command: $command_name"
  done
  [[ -d $PVE_ETC/nodes ]] || die 'Proxmox cluster filesystem is unavailable.'
  pct status "$ROUTER_CT_ID" | grep -q 'status: running' || die 'The router CT is not running.'
  pct exec "$ROUTER_CT_ID" -- test -f /app/router/router.py || die 'The selected CT is not an OSR router.'
  if [[ $mode == create ]]; then
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "CT ID $CT_ID is already used."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge does not exist: $BRIDGE"
    [[ -r $(pvesm path "$TEMPLATE") ]] || die "Template is unreadable: $TEMPLATE"
    pve_select_storage_rows rootdir | awk -F '\t' -v s="$STORAGE" '$1==s {found=1} END {exit !found}' ||
      die 'STORAGE is inactive or does not support rootdir.'
    [[ ! -e $FW_DIR/${CT_ID}.fw ]] || die "Firewall file already exists for CT $CT_ID."
  else
    valid_cidr "$DSH_ACCESS_CIDR" || die 'Set DSH_ACCESS_CIDR to reconfigure this CT.'
  fi
fi

honcho_key_push=false
if (( ! dry_run )); then
  pct exec "$ROUTER_CT_ID" -- awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' \
    /app/router/secrets.env > "$stage/router-api-key" 2>/dev/null || : > "$stage/router-api-key"
  router_ip=$(pct exec "$ROUTER_CT_ID" -- ip -4 -o addr show dev eth0 | awk 'NR==1 {split($4,a,"/"); print a[1]}')
  router_ip=${router_ip//[$'\r\n ']/}
  ipv4 "$router_ip" || die 'Cannot determine the OSR router CT IPv4 address.'
  router_port=$(pct exec "$ROUTER_CT_ID" -- sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env 2>/dev/null | head -n1" || true)
  router_port=${router_port//[$'\r\n ']/}
  router_port=${router_port:-8000}
  positive ROUTER_PORT "$router_port"
  (( router_port <= 65535 )) || die 'Invalid router port.'
  if [[ -n $honcho_mcp ]]; then
    # The Honcho target's client key is scoped to the shared osr workspace.
    if [[ -n $HONCHO_CT_ID ]]; then
      pct exec "$HONCHO_CT_ID" -- cat /etc/honcho-target/client-api-key > "$stage/honcho-api-key" 2>/dev/null ||
        die "Honcho CT $HONCHO_CT_ID has no osr workspace key. Run targets/honcho/provision-lxc.sh --reconfigure for it first."
      honcho_key_push=true
    elif [[ -n $HONCHO_API_KEY_FILE ]]; then
      cp -- "$HONCHO_API_KEY_FILE" "$stage/honcho-api-key"
      honcho_key_push=true
    elif [[ $mode == reconfigure ]] && pct exec "$CT_ID" -- test -s /etc/deepseek-harness/honcho-api-key; then
      note "Using the Honcho key already in CT $CT_ID; set HONCHO_CT_ID to fetch it again."
    else
      die 'Honcho memory needs HONCHO_CT_ID (the Honcho target) or HONCHO_API_KEY_FILE.'
    fi
    [[ $honcho_key_push == false || -s $stage/honcho-api-key ]] || die 'The Honcho API key is empty.'
    # The Honcho target admits agents by address; say how before changing anything.
    honcho_fw=$FW_DIR/${HONCHO_CT_ID}.fw
    if [[ -n $HONCHO_CT_ID && -f $honcho_fw && -n $IP_CIDR ]] &&
       ! grep -q -- "-source ${IP_CIDR%/*}/32 -p tcp -dport 3000 " "$honcho_fw"; then
      die "Honcho CT $HONCHO_CT_ID does not admit ${IP_CIDR%/*} to its MCP port. Add it on this host with:
  CT_ID=$HONCHO_CT_ID ROUTER_CT_ID=$ROUTER_CT_ID HONCHO_CLIENT_IPS='<other agent IPs> ${IP_CIDR%/*}' bash targets/honcho/provision-lxc.sh --reconfigure"
    fi
  fi
else
  router_ip='<router-ct-ip>'
  router_port=8000
  [[ $mode != reconfigure ]] || IP_CIDR=${IP_CIDR:-<existing-ct-ip>/32}
  printf '+ read ROUTER_API_KEY from router CT %s into a temporary 0600 file\n' "$ROUTER_CT_ID"
  if [[ -n $honcho_mcp ]]; then
    if [[ -n $HONCHO_CT_ID ]]; then key_from="Honcho CT $HONCHO_CT_ID"
    elif [[ -n $HONCHO_API_KEY_FILE ]]; then key_from=$HONCHO_API_KEY_FILE
    else key_from="the key already in CT $CT_ID"; fi
    printf '+ read the osr workspace key from %s into a temporary 0600 file\n' "$key_from"
  fi
fi
ROUTER_URL="http://$router_ip:$router_port"

pve_summary "DeepSeek Harness: $mode"
pve_row 'Router' "CT $ROUTER_CT_ID, $ROUTER_URL"
if [[ $mode == create ]]; then
  pve_row 'Harness CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
  pve_row 'Template' "$TEMPLATE"
  pve_row 'Network' "$IP_CIDR via $GATEWAY on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
else
  pve_row 'Harness CT' "$CT_ID at ${IP_CIDR:-<existing address>}"
fi
pve_row 'Model' "$DSH_MODEL (context $DSH_CONTEXT_WINDOW, replies up to $DSH_MAX_TOKENS tokens)"
pve_row 'Harness release' "$DSH_VERSION"
pve_row 'Web UI' "port $DSH_PORT, allowed from $DSH_ACCESS_CIDR"
pve_row 'Honcho memory' "${honcho_mcp:-off}"
pve_confirm "$( [[ $mode == create ]] && printf 'Create DeepSeek Harness CT %s?' "$CT_ID" || printf 'Reconfigure DeepSeek Harness CT %s?' "$CT_ID")"

if [[ $mode == create ]]; then
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --tags 'ai;ai-tools;osr-target;deepseek-harness'
    --description 'DeepSeek Harness for Ollama Smart Router')
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  # Proxmox extracts an unprivileged template as the mapped root user, with
  # this process's umask: under 077 the rootfs path is 0700 and tar cannot
  # open it. Scope 022 to pct create only; keys and staging stay private.
  (umask 022; run "${create[@]}")
  firewall_file="$FW_DIR/${CT_ID}.fw"
  firewall=$(printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\n\n[RULES]\nIN ACCEPT -source %s -p tcp -dport %s -log nolog # osr-deepseek-harness\n' \
    "$DSH_ACCESS_CIDR" "$DSH_PORT")
  if (( dry_run )); then printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
  else printf '%s' "$firewall" > "$firewall_file"; fi
  run pct start "$CT_ID"
  if (( ! dry_run )); then
    ready=false
    for (( attempt=0; attempt<60; attempt++ )); do
      if pct exec "$CT_ID" -- test -d /run/systemd/system 2>/dev/null &&
         pct exec "$CT_ID" -- getent hosts registry.npmjs.org >/dev/null 2>&1; then ready=true; break; fi
      sleep 3
    done
    $ready || die "CT $CT_ID has no working systemd or DNS after 180 seconds. Resume with --reconfigure."
  else
    printf '+ wait for systemd and DNS in CT %s\n' "$CT_ID"
  fi
else
  rule="IN ACCEPT -source $DSH_ACCESS_CIDR -p tcp -dport $DSH_PORT -log nolog # osr-deepseek-harness"
  if (( ! dry_run )); then
    firewall_file="$FW_DIR/${CT_ID}.fw"
    grep -q '# osr-deepseek-harness$' "$firewall_file" || die 'Refusing to replace an unrecognized CT firewall.'
    grep -qx '\[RULES\]' "$firewall_file" || die 'The CT firewall has no [RULES] section.'
    router_fw=$FW_DIR/${ROUTER_CT_ID}.fw
    ct_fw_before=$stage/harness.fw.before
    cp -- "$firewall_file" "$ct_fw_before"
    harness_fw_transition "$ct_fw_before" "$rule" > "$stage/firewall.transition"
    swap=0
    fw_swap "$firewall_file" "$ct_fw_before" "$stage/firewall.transition" || swap=$?
    if (( swap != 0 )); then
      preserve_stage=true
      die "Could not safely update $firewall_file (status $swap). Its previous content is in $ct_fw_before; check the live file and rerun --reconfigure."
    fi
    firewall_txn_active=true
  else
    printf '+ keep the current Web UI rule while adding %s in %s/%s.fw; finalize after the guest is healthy\n' "$rule" "$FW_DIR" "$CT_ID"
  fi
fi

# The router CT's own firewall must let Harness reach the router API. One owned
# rule, replaced when the Harness address or router port changes; everything
# else in that file stays as it is.
router_fw=$FW_DIR/${ROUTER_CT_ID}.fw
if [[ $DSH_ROUTER_FIREWALL == true ]]; then
  if (( dry_run )); then
    printf '+ admit %s to the router API in %s, if that file exists\n' "${IP_CIDR%/*}" "$router_fw"
  elif [[ -f $router_fw ]]; then
    cp -- "$router_fw" "$stage/router.fw.before"
    router_fw_with_dsh "$stage/router.fw.before" "${IP_CIDR%/*}" "$router_port" > "$stage/router.fw"
    if ! cmp -s "$stage/router.fw" "$stage/router.fw.before"; then
      swap=0
      fw_swap "$router_fw" "$stage/router.fw.before" "$stage/router.fw" || swap=$?
      if (( swap != 0 )); then
        preserve_stage=true
        die "Could not safely update the router CT firewall $router_fw (status $swap). Its previous content is in $stage/router.fw.before; check the live file and rerun --reconfigure."
      fi
      if [[ $mode == reconfigure ]]; then
        router_fw_before=$stage/router.fw.before
        router_fw_written=true
      fi
    fi
  fi
fi

run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
run pct push "$CT_ID" "$stage/router-api-key" "$deploy/router-api-key" --perms 0600
if [[ $honcho_key_push == true ]] || { (( dry_run )) && [[ -n $honcho_mcp && ( -n $HONCHO_CT_ID || -n $HONCHO_API_KEY_FILE ) ]]; }; then
  run pct push "$CT_ID" "$stage/honcho-api-key" "$deploy/honcho-api-key" --perms 0600
fi
for file in install-target.sh configure.mjs deepseek-harness.service; do
  perms=0644
  [[ $file == *.sh || $file == *.mjs ]] && perms=0755
  run pct push "$CT_ID" "$source_dir/$file" "$deploy/$file" --perms "$perms"
done
guest_status=0
run pct exec "$CT_ID" -- env "DSH_ROUTER_URL=$ROUTER_URL" "DSH_BIND_IP=${IP_CIDR%/*}" \
  "DSH_MODEL=$DSH_MODEL" "DSH_CONTEXT_WINDOW=$DSH_CONTEXT_WINDOW" \
  "DSH_MAX_TOKENS=$DSH_MAX_TOKENS" "DSH_PORT=$DSH_PORT" "DSH_VERSION=$DSH_VERSION" \
  "DSH_HONCHO_MCP_URL=$honcho_mcp" bash "$deploy/install-target.sh" || guest_status=$?

if (( guest_status != 0 )); then
  # install-target.sh writes its settings record only once the new service
  # is healthy. A failure after that (such as removing old releases) leaves
  # the new service running: its firewall rule must stay, not be rolled back.
  # Create has no previous service to protect; its CT is kept for inspection.
  [[ $mode == reconfigure && $dry_run == 0 ]] || exit "$guest_status"
  # A missing record reads as empty (no completed run yet); an unreadable one
  # or a failing pct exec leaves the state unknown.
  state=unknown
  # A failed rollback retains this snapshot. Settings can still be old if the
  # new service became healthy but writing its record failed before rollback.
  if rollback_state=$(pct exec "$CT_ID" -- sh -c 'if [ -e /var/lib/deepseek-harness-target/rollback ]; then echo pending; else echo clear; fi' 2>/dev/null) &&
     [[ $rollback_state == clear ]] &&
     after=$(pct exec "$CT_ID" -- sh -c 'f=/etc/deepseek-harness/settings; [ ! -e "$f" ] || cat "$f"' 2>/dev/null); then
    state=$(guest_state "$recorded" "${after//$'\r'/}" "$DSH_PORT")
  fi
  case $state in
    previous) exit "$guest_status" ;;  # the EXIT trap restores the firewall
    switched) note "The guest run failed after Harness switched to the new settings; keeping the new Web UI rule." ;;
    *)
      # Closing either port could shut the one being served: keep both.
      firewall_txn_active=false
      note "Cannot tell whether Harness serves port $DSH_PORT or the previous one, so $firewall_file keeps both Web UI rules."
      note "Check with: pct exec $CT_ID -- cat /etc/deepseek-harness/settings; then run --reconfigure again."
      exit "$guest_status" ;;
  esac
fi

if [[ $mode == reconfigure && $dry_run == 0 ]]; then
  # The guest has committed its new service. Keep the transitional two-rule
  # firewall if finalization fails, so the new Web UI port stays reachable.
  firewall_txn_active=false
  cp -- "$firewall_file" "$stage/firewall.seen"
  if ! harness_fw_final "$stage/firewall.seen" "$rule" > "$stage/firewall.final"; then
    preserve_stage=true
    die "Harness is running, but its final firewall rule could not be built. Check $firewall_file."
  fi
  swap=0
  fw_swap "$firewall_file" "$stage/firewall.seen" "$stage/firewall.final" || swap=$?
  case $swap in
    0) ;;
    1) preserve_stage=true
       die "Harness is running, but $firewall_file changed while the run finished; it was left as it is. Check the live file and rerun --reconfigure." ;;
    *)
      preserve_stage=true
      note "The previous content is in $stage/firewall.seen; check the live file before restoring it."
      die "Harness is running, but its firewall rule could not be finalized. Check $firewall_file." ;;
  esac
fi
(( guest_status == 0 )) || exit "$guest_status"

printf 'DeepSeek Harness CT %s: http://%s:%s/\n' "$CT_ID" "${IP_CIDR%/*}" "$DSH_PORT"
[[ -z $honcho_mcp ]] || printf 'Honcho memory: %s (workspace osr; peers user and deepseek-harness).\n' "$honcho_mcp"
printf 'Read its tokenized login URL with: pct exec %s -- journalctl -u deepseek-harness.service -b --no-pager | grep "dsh web:" | tail -n1\n' "$CT_ID"
