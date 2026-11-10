#!/usr/bin/env bash
# Create or reconfigure a dedicated CPU-only Honcho LXC on the router's PVE host.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
# Router firewall helper
# router_fw_with_honcho FILE IP PORT: FILE with this target's one rule (IP to
# the router API PORT) first in [RULES]; an older one is dropped, the rest kept.
router_fw_with_honcho() {
  awk -v rule="IN ACCEPT -source $2/32 -p tcp -dport $3 -log nolog # osr-honcho-router" '
    / # osr-honcho-router$/ { next }
    $0 == "[RULES]" && !seen { print; print rule; seen=1; next }
    { print }
    END { if (!seen) { print ""; print "[RULES]"; print rule } }
  ' "$1"
}
# honcho_router_fw_update FILE IP PORT VMID PVE_ETC STAGE SWAP: admit Honcho
# in the router CT's firewall FILE through the shared locked swap. 0: changed;
# 3: already admitted; 1: swap refused or failed and the previous content is
# saved to a private file whose path is printed; 2: no backup could be saved.
honcho_router_fw_update() {
  local file=$1 ip=$2 port=$3 vmid=$4 pve_etc=$5 stage=$6 swap=$7 backup cmp_status=0
  cp -- "$file" "$stage/router.fw.before" || return 2
  router_fw_with_honcho "$stage/router.fw.before" "$ip" "$port" > "$stage/router.fw" || return 2
  cmp -s "$stage/router.fw" "$stage/router.fw.before" || cmp_status=$?
  case $cmp_status in 0) return 3 ;; 1) ;; *) return 2 ;; esac
  perl "$swap" "$file" "$stage/router.fw.before" "$stage/router.fw" "$vmid" "$pve_etc" && return 0
  backup=$(mktemp "${TMPDIR:-/tmp}/honcho-router-fw.${vmid}.XXXXXX") || return 2
  if ! cp -- "$stage/router.fw.before" "$backup"; then
    rm -f -- "$backup"
    return 2
  fi
  printf '%s\n' "$backup"
  return 1
}
# End router firewall helper.
# Honcho firewall helpers
# honcho_rules ROUTER_IP [AGENT_IP...]: the Honcho CT's inbound rules. The
# router (Open WebUI) and every agent reach the API (8000) and MCP (3000), both
# served by the CT's client gateway: Hermes and OpenClaw use the API, DeepSeek
# Harness the MCP server, each with its own gateway key. An agent's MCP rule
# has its own tag, so the router stays distinguishable when the rules are read
# back.
honcho_rules() {
  local router=$1 ip
  shift
  for ip in "$router" "$@"; do
    printf 'IN ACCEPT -source %s/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\n' "$ip"
    if [[ $ip == "$router" ]]; then
      printf 'IN ACCEPT -source %s/32 -p tcp -dport 3000 -log nolog # osr-honcho-mcp\n' "$ip"
    else
      printf 'IN ACCEPT -source %s/32 -p tcp -dport 3000 -log nolog # osr-honcho-client-mcp\n' "$ip"
    fi
  done
}
# honcho_fw_clients FILE: the agent IPs FILE admits (API rules that are not the
# router's), space-separated.
honcho_fw_clients() {
  awk '
    / # osr-honcho-api$/ { split($4, parts, "/"); clients[parts[1]]=1 }
    / # osr-honcho-mcp$/ { split($4, parts, "/"); router[parts[1]]=1 }
    END { for (ip in clients) if (!(ip in router)) print ip }
  ' "$1" | sort -u | paste -sd' ' -
}
# honcho_ct_fw_update FILE RULES STAGE VMID PVE_ETC SWAP: FILE's owned
# Honcho rules replaced by RULES (every other line kept), through the shared
# locked swap and only while FILE still holds the copy the update was built
# from. 0: done or unchanged; 1: FILE changed meanwhile, left as it is;
# 2: the copy, the update or the write failed.
honcho_ct_fw_update() {
  local file=$1 rules=$2 stage=$3 vmid=$4 pve_etc=$5 swap=$6
  cp -- "$file" "$stage/firewall.seen" || return 2
  awk -v rules="$rules" '
    $0 == "[RULES]" { print; print rules; seen=1; next }
    $0 !~ / # osr-honcho-(api|mcp|client-mcp)$/ { print }
    END { if (!seen) { print "[RULES]"; print rules } }
  ' "$stage/firewall.seen" > "$stage/firewall.new" || return 2
  perl "$swap" "$file" "$stage/firewall.seen" "$stage/firewall.new" "$vmid" "$pve_etc"
}
# End Honcho firewall helpers.
# Model choice helpers
# router_inventory ROUTER_CT ROUTER_IP: the router's /routing/inventory JSON,
# asked with curl at ROUTER_IP from this host, else from inside the router CT
# (its firewall may admit only its clients). The router key is read in that CT
# and given to curl on stdin, never on a command line.
router_inventory() {
  local ct=$1 ip=$2 port key config
  port=$(pct exec "$ct" -- sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env | head -n1" 2>/dev/null | tr -d '\r\n') || port=''
  [[ $port =~ ^[0-9]{2,5}$ ]] || port=8000
  key=$(pct exec "$ct" -- awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' \
    /app/router/secrets.env 2>/dev/null | tr -d '\r\n') || key=''
  key=${key//\\/\\\\}; key=${key//\"/\\\"}
  config=$(printf 'silent\nshow-error\nfail\nmax-time = 10\n'
    [[ -z $key ]] || printf 'header = "Authorization: Bearer %s"\n' "$key")
  curl -K - "http://$ip:$port/routing/inventory" <<< "$config" 2>/dev/null ||
    pct exec "$ct" -- curl -K - "http://127.0.0.1:$port/routing/inventory" <<< "$config" 2>/dev/null
}
valid_model_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]]; }
# choose_from LABEL SUGGESTION VALIDATOR [NAME<TAB>DESCRIPTION<TAB>URL...]: a
# numbered list of the lines, then one answer: Enter takes SUGGESTION, a list
# number that line's name, anything else what VALIDATOR accepts. Prints the
# choice; the list and prompts go to stderr. Fails at the end of input.
choose_from() {
  local label=$1 suggestion=$2 validator=$3 line answer i=0 description
  shift 3
  local -a names=()
  for line in "$@"; do
    i=$((i + 1)); names+=("${line%%$'\t'*}")
    description=${line#*$'\t'}; description=${description%%$'\t'*}
    printf '  %d) %s  (%s)\n' "$i" "${names[i - 1]}" "$description" >&2
  done
  while true; do
    printf '%s%s: ' "$label" "${suggestion:+ [$suggestion]}" >&2
    IFS= read -r answer || { printf '\n' >&2; return 1; }
    answer=${answer:-$suggestion}
    if [[ $answer =~ ^[0-9]+$ ]] && (( ${#names[@]} > 0 )); then
      if (( 10#$answer < 1 || 10#$answer > ${#names[@]} )); then
        printf 'Choose 1-%d, or type a name.\n' "${#names[@]}" >&2; continue
      fi
      answer=${names[10#$answer - 1]}
    fi
    if [[ -n $answer ]] && "$validator" "$answer"; then printf '%s\n' "$answer"; return 0; fi
    printf 'Not a valid choice: %s\n' "${answer:-(empty)}" >&2
  done
}
# End model choice helpers.
# Reconfigure guard helper: run before changing either CT's firewall or staging
# the Open WebUI admin token. The guest repeats the embedding check before its
# backup.
honcho_reconfigure_preflight() {
  local ct=$1 previous_embedding
  pct status "$ct" 2>/dev/null | grep -q 'status: running' || die "Honcho CT $ct is not running."
  pct config "$ct" 2>/dev/null | awk '
    /^tags:/ {
      sub(/^tags:[[:space:]]*/, "")
      n = split($0, tags, /[;, ]+/)
      for (i = 1; i <= n; i++) if (tags[i] == "honcho") found = 1
    }
    END { exit !found }
  ' || die "CT $ct has no honcho tag. Check pct config $ct and select the Honcho CT."
  previous_embedding=$(pct exec "$ct" -- sed -n 's/^EMBEDDING_MODEL_CONFIG__MODEL=//p' \
    /etc/honcho-target/honcho.env 2>/dev/null | head -n1) ||
    die "Cannot read the embedding model in Honcho CT $ct."
  [[ $previous_embedding == qwen3-embedding-0.6b ]] ||
    die "Honcho CT $ct uses ${previous_embedding:-another embedding model}; --reconfigure cannot migrate stored vectors to qwen3-embedding-0.6b. See 'Changing an existing embedding model' in targets/honcho/README.md."
}
# End reconfigure guard helper.
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
usage() {
  cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run] [--reconfigure [--rotate-keys]]

Run as root on the Proxmox host. For a new CT, the installer asks for the
Honcho CT ID and IP/CIDR, router/Open WebUI CT ID and IP, gateway, the chat
model's context window, the chat model, and optional agent CT IPs. Once the
router's address is known it reads the router's model inventory (curl to
/routing/inventory) and lists the chat models Honcho can use, with a
suggestion. The new CT ID defaults to the cluster's next free ID. Set CT_ID,
IP_CIDR, ROUTER_CT_ID, ROUTER_IP, GATEWAY, HONCHO_MODEL and HONCHO_CLIENT_IPS
to preset these answers.
Unattended runs require the mandatory values as presets. The admin API token
is requested without echo unless OPENWEBUI_ADMIN_TOKEN is already set.

Creates an unprivileged Debian 13 LXC with native PostgreSQL/pgvector,
Honcho API and deriver services, Honcho's Streamable HTTP MCP server, a
loopback chat proxy and its own embedding model: llama.cpp's llama-server,
built in the CT for its CPU, runs Qwen3-Embedding-0.6B (Q8_0, 1024 dimensions,
a pinned 639 MB download) on 127.0.0.1:8766. Nothing outside the CT is needed
for embeddings. The proxy selects a chat model from router inventory and
contacts model targets directly; HONCHO_MODEL=fast by default. HONCHO_REF
(default v3.5.0) may select another upstream tag, main, or a commit. HONCHO_CLIENT_IPS is a space-separated list of agent CT addresses (Hermes,
OpenClaw, DeepSeek Harness) allowed to the API and MCP ports through the
Proxmox firewall. The router CT is always allowed.

HONCHO_CONTEXT_TOKENS sets Honcho's token budgets for the model's context
window (at least 8192); HONCHO_<SETTING> overrides one budget (see the
README). Unset, they keep the CT's last values (a first install sizes them
for 65536 tokens); set and empty, Honcho's default.
HONCHO_REF, HONCHO_MODEL, HONCHO_STRUCTURED_OUTPUT_MODE and the HONCHO_BUN_*
pins are kept the same way: a reconfigure only changes the ones it sets.
HONCHO_STRUCTURED_OUTPUT_MODE=json_object is for a selected model whose backend
lacks JSON-schema output; the install probes the model with tools and
structured output first (HONCHO_SKIP_CHAT_PROBE=true skips that). Another Bun
than 1.4.4 needs HONCHO_BUN_VERSION with HONCHO_BUN_SHA256 (bun-linux-x64.zip)
or HONCHO_BUN_BASELINE_SHA256 (CPUs without AVX2). If the router CT has a
Proxmox firewall file, a rule admitting this CT to the router API is kept in
it (HONCHO_ROUTER_FIREWALL=false leaves that file alone).

This target registers the MCP server in Open WebUI. --reconfigure updates an
existing Honcho CT and the registration without deleting its PostgreSQL data;
every reconfigure dumps the database before migrations and restores it if the
guest setup fails. A CT using another embedding model cannot switch to the
local model through --reconfigure; see the README for migration guidance.
Clients reach the API and MCP ports through the CT's client gateway, each with
its own key: Open WebUI's (registered here) gives every Open WebUI user a
memory (workspace) of their own; each agent gets a key from its own
provisioner, pinned to a workspace of that agent's own (as with Open
Terminal). honcho-clients in the CT lists, issues and revokes keys.
--rotate-keys (with --reconfigure) replaces the JWT secret, the admin key and
Open WebUI's gateway key; the agents keep their own keys.
USAGE
}
mode=create; dry_run=0; rotate_keys=false
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --reconfigure) mode=reconfigure ;;
    --rotate-keys) rotate_keys=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
CT_ID=${CT_ID:-}
ROUTER_CT_ID=${ROUTER_CT_ID:-${ROUTER:-}}
ROUTER_IP=${ROUTER_IP:-}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
BRIDGE=${BRIDGE:-vmbr0}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-8192}
SWAP_MB=${SWAP_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-48}
ONBOOT=${ONBOOT:-1}
CT_HOSTNAME=${CT_HOSTNAME:-honcho-ai}
OPENWEBUI_PORT=${OPENWEBUI_PORT:-8080}
# Settings the CT keeps between runs (its settings.env). Forwarded only when
# set here, before the defaults below fill them in: a plain --reconfigure then
# keeps the CT's release, model and output mode, and an empty value returns a
# setting to its default.
honcho_kept_names=(REF MODEL STRUCTURED_OUTPUT_MODE BUN_VERSION BUN_SHA256 BUN_BASELINE_SHA256)
kept_env=()
for name in "${honcho_kept_names[@]}"; do
  var=HONCHO_$name
  [[ -z ${!var+set} ]] || kept_env+=("$var=${!var}")
done
honcho_ref_given=${HONCHO_REF+set}
honcho_model_given=${HONCHO_MODEL:+set}
HONCHO_MODEL=${HONCHO_MODEL:-}
HONCHO_REF=${HONCHO_REF:-v3.5.0}
# Honcho embeds with its own local model; these earlier settings do nothing.
for name in HONCHO_EMBEDDING_MODEL HONCHO_EMBEDDING_DIMENSIONS HONCHO_EMBEDDING_BASE_URL HONCHO_EMBEDDING_DIMENSIONS_MODE; do
  [[ -z ${!name+set} ]] || printf 'Note: %s is no longer used: Honcho embeds with its own model in its CT.\n' "$name" >&2
  unset "$name"
done
HONCHO_STRUCTURED_OUTPUT_MODE=${HONCHO_STRUCTURED_OUTPUT_MODE:-}
HONCHO_SKIP_CHAT_PROBE=${HONCHO_SKIP_CHAT_PROBE:-false}
HONCHO_ROUTER_FIREWALL=${HONCHO_ROUTER_FIREWALL:-true}
HONCHO_BUN_VERSION=${HONCHO_BUN_VERSION:-}
HONCHO_BUN_SHA256=${HONCHO_BUN_SHA256:-}
HONCHO_BUN_BASELINE_SHA256=${HONCHO_BUN_BASELINE_SHA256:-}
honcho_clients_explicit=${HONCHO_CLIENT_IPS+x}
HONCHO_CLIENT_IPS=${HONCHO_CLIENT_IPS:-}

if (( ! dry_run )); then [[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'; fi
PVE_ETC=${PVE_ETC:-/etc/pve}
[[ $PVE_ETC == / ]] || PVE_ETC=${PVE_ETC%/}

# --- Questions, one section at a time -----------------------------------------
template_re='^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-13-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
valid_template() { [[ $1 =~ $template_re ]]; }
valid_storage() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_context() { [[ -z $1 ]] || { [[ $1 =~ ^[1-9][0-9]{3,6}$ ]] && (( $1 >= 8192 && $1 <= 1048576 )); }; }
valid_agent_ips() { local ip; for ip in $1; do pve_valid_ipv4 "${ip%%/*}" || return 1; done; }
# recorded_value KEY: KEY from the CT's proxy.settings (a reconfigure), or nothing.
recorded='' recorded_budgets=''
recorded_value() {
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' <<< "$recorded"
}
interactive=false
pve_asks && interactive=true
if [[ $mode == create ]]; then
  pve_ask_router ip
  pve_ask_new_ct Honcho
  pve_select_template TEMPLATE "$template_re"
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
  pve_suggest TEMPLATE 'Debian 13 amd64 template' '' valid_template 'Honcho needs Python 3.13: use a downloaded Debian 13 amd64 template.'
  pve_suggest STORAGE 'Root disk storage' '' valid_storage
  pve_ask_network Honcho
  inventory_ip=$ROUTER_IP
else
  pve_ask_existing_ct honcho Honcho
  pve_valid_ct_id "$CT_ID" || die 'Set a valid CT_ID (>=100).'
  if (( ! dry_run )) && pct status "$CT_ID" 2>/dev/null | grep -q 'status: running'; then
    # What the CT records: the defaults for every question below.
    recorded=$(pct exec "$CT_ID" -- cat /etc/honcho-target/proxy.settings 2>/dev/null | tr -d '\r' || true)
    recorded_budgets=$(pct exec "$CT_ID" -- cat /etc/honcho-target/budgets.env 2>/dev/null | tr -d '\r' || true)
    [[ -n $recorded ]] || printf 'CT %s has no /etc/honcho-target/proxy.settings; the questions below have no recorded answers.\n' "$CT_ID"
    if [[ -z $honcho_clients_explicit && -f $PVE_ETC/firewall/${CT_ID}.fw ]]; then
      recorded_clients=$(honcho_fw_clients "$PVE_ETC/firewall/${CT_ID}.fw")
    fi
  fi
  inventory_ip=''
  if [[ $(recorded_value ROUTER_URL) =~ ^https?://([0-9.]+): ]]; then
    inventory_ip=${BASH_REMATCH[1]}
    # shellcheck disable=SC2034  # read by pve_ask_router
    PVE_ROUTER_SUGGESTION=$(pve_ct_with_ip "$inventory_ip")
  fi
  # The router address is taken from the router's route to Honcho.
  pve_ask_router
fi
[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ && $ROUTER_CT_ID =~ ^[1-9][0-9]{2,8}$ ]] ||
  die 'Set valid CT_ID and ROUTER_CT_ID (both >=100).'

pve_section 'Honcho models'
pve_note 'Honcho needs a chat model that calls tools and returns structured output. Its embedding model runs in its own CT.'
# The context window first: it decides which chat models qualify. A set value
# (even empty: Honcho's own budgets) is the caller's; a reconfigure offers the
# CT's, and keeps it unasked when the CT never recorded one.
if [[ -z ${HONCHO_CONTEXT_TOKENS+set} ]]; then
  context_default=''
  if [[ $mode == create ]]; then context_default=65536
  else context_default=$(awk -F= '$1 == "HONCHO_CONTEXT_TOKENS" { print $2; exit }' <<< "$recorded_budgets"); fi
  if [[ $mode == create || -n $context_default ]]; then
    HONCHO_CONTEXT_TOKENS=''
    pve_ask HONCHO_CONTEXT_TOKENS "Context window the chat model serves (tokens; none = Honcho's 128k budgets)" \
      "$context_default" valid_context 'Use 8192 to 1048576 tokens, or none.'
    if [[ -n $HONCHO_CONTEXT_TOKENS || $interactive == true ]]; then export HONCHO_CONTEXT_TOKENS; else unset HONCHO_CONTEXT_TOKENS; fi
  fi
fi
choices=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/model_choices.py
chat_lines=()
# The models the router serves, to choose from: read once the router's
# address is known, and only when the chat model is still to be chosen.
if [[ $interactive == true && -n $inventory_ip && -z $honcho_model_given ]]; then
  inventory_file=$(mktemp "${TMPDIR:-/tmp}/honcho-inventory.XXXXXX")
  printf '  Reading the models router CT %s serves (http://%s, /routing/inventory)...\n' "$ROUTER_CT_ID" "$inventory_ip" >&2
  if router_inventory "$ROUTER_CT_ID" "$inventory_ip" > "$inventory_file" &&
     python3 "$choices" chat "$inventory_file" 8192 > /dev/null 2>&1; then
    # The proxy's own test: tools reported and this much context (131072 for
    # Honcho's own budgets).
    min_context=${HONCHO_CONTEXT_TOKENS-65536}
    [[ $min_context =~ ^[1-9][0-9]*$ ]] || min_context=131072
    mapfile -t chat_lines < <(python3 "$choices" chat "$inventory_file" "$min_context" 2> "$inventory_file.skipped")
  else
    printf '  Could not read the router inventory; enter the model name yourself.\n' >&2
  fi
fi
model_recorded=$(recorded_value HONCHO_MODEL)
if [[ -z $honcho_model_given ]]; then
  if [[ $interactive == true ]]; then
    printf '  Chat model: %s tokens of context or more. A tier (fast, medium, large, xlarge) lets the router pick.\n' "${min_context:-${HONCHO_CONTEXT_TOKENS:-131072}}" >&2
    if (( ${#chat_lines[@]} == 0 )) && [[ -s ${inventory_file:-} ]]; then
      printf '  No model in the inventory reports tool support and that much context, so Honcho cannot install yet.\n' >&2
    fi
    [[ ! -s ${inventory_file:-}.skipped ]] || sed 's/^/    /' "$inventory_file.skipped" >&2
    _pve_heading
    HONCHO_MODEL=$(choose_from '  Chat model (number, name or tier)' \
      "${model_recorded:-$(cut -f1 <<< "${chat_lines[0]:-fast}")}" valid_model_name "${chat_lines[@]}") ||
      die 'No chat model was chosen.'
    # Forwarded (and recorded) when it changes what the CT runs.
    [[ $HONCHO_MODEL == "$model_recorded" ]] || honcho_model_given='set'
  else
    HONCHO_MODEL=${model_recorded:-fast}
  fi
fi
[[ -z ${inventory_file:-} ]] || rm -f -- "$inventory_file" "$inventory_file.skipped"

pve_section 'Agents allowed to Honcho'
pve_note 'Hermes, OpenClaw and DeepSeek Harness CTs reach Honcho through its firewall.'
if [[ -z $honcho_clients_explicit ]]; then
  if [[ $mode == reconfigure ]]; then
    if [[ -n ${recorded_clients+set} ]]; then
      pve_ask HONCHO_CLIENT_IPS 'Agent CT IPs (space-separated; none for no agents)' "$recorded_clients" valid_agent_ips \
        'Use IPv4 addresses separated by spaces, or none.'
      # The answer replaces the firewall's list.
      honcho_clients_explicit=x
    fi
  else
    agent_offer=''
    for agent in hermes openclaw deepseek-harness; do
      agent_ct=$(pve_tagged_ct "$agent")
      [[ -z $agent_ct ]] || agent_offer+="${agent_offer:+ }$(pve_ct_net "$agent_ct" ip)"
    done
    pve_offer HONCHO_CLIENT_IPS 'Agent CT IPs (space-separated)' "$agent_offer" valid_agent_ips \
      'Use IPv4 addresses separated by spaces, or none.'
  fi
  HONCHO_CLIENT_IPS=$(for ip in $HONCHO_CLIENT_IPS; do printf '%s ' "${ip%%/*}"; done)
  HONCHO_CLIENT_IPS=${HONCHO_CLIENT_IPS% }
fi
# A chat model chosen above reaches the CT like a preset one (kept_env was
# taken from the environment before the questions).
if [[ -n $honcho_model_given && " ${kept_env[*]} " != *" HONCHO_MODEL="* ]]; then
  kept_env+=("HONCHO_MODEL=$HONCHO_MODEL")
fi
if [[ $mode == reconfigure && -z $IP_CIDR && $dry_run == 0 ]]; then
  IP_CIDR=$(pct config "$CT_ID" 2>/dev/null |
    sed -n 's/^net0:.*ip=\([^,]*\).*/\1/p' | head -n1)
fi
[[ $CT_ID != "$ROUTER_CT_ID" ]] || die 'Honcho and router CT IDs must differ.'
[[ $OPENWEBUI_PORT =~ ^[0-9]{2,5}$ ]] && (( OPENWEBUI_PORT <= 65535 )) || die 'Invalid OPENWEBUI_PORT.'
[[ $HONCHO_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid HONCHO_MODEL.'
[[ -z $HONCHO_STRUCTURED_OUTPUT_MODE || $HONCHO_STRUCTURED_OUTPUT_MODE =~ ^(json_schema|json_object)$ ]] || die 'HONCHO_STRUCTURED_OUTPUT_MODE must be json_schema or json_object.'
[[ $HONCHO_SKIP_CHAT_PROBE =~ ^(true|false)$ ]] || die 'HONCHO_SKIP_CHAT_PROBE must be true or false.'
[[ $HONCHO_ROUTER_FIREWALL =~ ^(true|false)$ ]] || die 'HONCHO_ROUTER_FIREWALL must be true or false.'
[[ -z $HONCHO_BUN_VERSION || $HONCHO_BUN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid HONCHO_BUN_VERSION.'
for sha in "$HONCHO_BUN_SHA256" "$HONCHO_BUN_BASELINE_SHA256"; do
  [[ -z $sha || $sha =~ ^[0-9a-f]{64}$ ]] || die 'HONCHO_BUN_SHA256 and HONCHO_BUN_BASELINE_SHA256 are SHA-256 hex digests.'
done
if [[ -n $HONCHO_BUN_VERSION && $HONCHO_BUN_VERSION != 1.4.4 && -z $HONCHO_BUN_SHA256$HONCHO_BUN_BASELINE_SHA256 ]]; then
  die 'HONCHO_BUN_VERSION needs HONCHO_BUN_SHA256 (bun-linux-x64.zip) or HONCHO_BUN_BASELINE_SHA256 (no AVX2).'
fi
[[ $rotate_keys == false || $mode == reconfigure ]] || die '--rotate-keys needs --reconfigure: a new CT gets new keys anyway.'
# Token budgets for small context windows; budgets.py in the CT checks ranges.
# A set variable is passed on even when empty (that returns the setting to
# Honcho's default); an unset one keeps the CT's last value.
honcho_budget_names=(CONTEXT_TOKENS DERIVER_MAX_INPUT_TOKENS DIALECTIC_MAX_INPUT_TOKENS
  DIALECTIC_MAX_OUTPUT_TOKENS DIALECTIC_SESSION_HISTORY_MAX_TOKENS SUMMARY_MAX_INPUT_TOKENS
  SUMMARY_MAX_TOKENS_SHORT SUMMARY_MAX_TOKENS_LONG LLM_DEFAULT_MAX_TOKENS LLM_MAX_TOOL_OUTPUT_CHARS
  DREAM_MAX_OUTPUT_TOKENS DREAM_DEDUCTION_MAX_TOOL_ITERATIONS DREAM_INDUCTION_MAX_TOOL_ITERATIONS
  DREAM_ENABLED)
budget_env=()
for name in "${honcho_budget_names[@]}"; do
  var=HONCHO_$name
  [[ -n ${!var+set} ]] || continue
  if [[ $name == DREAM_ENABLED ]]; then
    [[ -z ${!var} || ${!var} =~ ^(true|false)$ ]] || die "$var must be true or false."
  else
    [[ ${!var} =~ ^[0-9]*$ ]] || die "$var must be a whole number of tokens (or characters)."
  fi
  budget_env+=("$var=${!var}")
done
[[ $HONCHO_REF =~ ^(main|v[0-9][A-Za-z0-9._-]*|[0-9a-f]{40})$ ]] || die 'Invalid HONCHO_REF.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
if [[ $mode == create ]]; then [[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,61}$ ]] || die 'Invalid CT_HOSTNAME.'
for number in CORES MEMORY_MB ROOTFS_GB; do
  [[ ${!number} =~ ^[1-9][0-9]*$ ]] || die "Invalid $number."
done
[[ $SWAP_MB =~ ^(0|[1-9][0-9]*)$ && $ONBOOT =~ ^[01]$ ]] || die 'Invalid SWAP_MB or ONBOOT.'
[[ -z $VLAN_TAG || $VLAN_TAG =~ ^[1-9][0-9]{0,3}$ ]] || die 'Invalid VLAN_TAG.'
[[ -z $NAMESERVER || $NAMESERVER =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Invalid NAMESERVER.'
[[ $IP_CIDR =~ ^[0-9]+(\.[0-9]+){3}/[0-9]{1,2}$ ]] || die 'Set a static IP_CIDR.'
if [[ $mode == create ]]; then
  [[ $GATEWAY =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Set a static GATEWAY.'
  [[ $ROUTER_IP =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Set ROUTER_IP to the router address reachable from Honcho.'
  [[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-13-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] ||
    die 'TEMPLATE must be a downloaded Debian 13 amd64 LXC template.'
fi
for ip in $HONCHO_CLIENT_IPS; do
  [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "Invalid HONCHO_CLIENT_IPS address: $ip"
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/../pve-firewall-swap.pl ]] || die "Missing $source_dir/../pve-firewall-swap.pl"
for file in install-target.sh budgets.py honcho-proxy.py direct_dispatch.py honcho-proxy.service honcho-api.service \
            honcho-deriver.service honcho-mcp.service honcho-embedding.service honcho-gateway.py honcho-clients \
            honcho-gateway.service integrate-webui.py; do
  [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file"
done
honcho_ip=${IP_CIDR%/*}
[[ $mode != create || $honcho_ip != "$ROUTER_IP" ]] || die 'Honcho and router IP addresses must differ.'
for ip in $HONCHO_CLIENT_IPS; do
  [[ $ip != "$honcho_ip" ]] || die 'An agent IP address must differ from the Honcho IP.'
done
stage=$(mktemp -d "${TMPDIR:-/tmp}/honcho-target.XXXXXX")
router_stage="/root/honcho-integration-$$"
rotation_stage="/root/honcho-rotation-$$"
rotation_pending=false
rotation_staged=false
# Set just before the router CT's staging directory is made: a run that stops
# earlier (not root, no token, router CT down) has nothing there to clean.
router_stage_created=false
# What --rotate-keys replaces: the JWT secret, the admin key and Open WebUI's
# gateway key (and with it its entry in the client list).
rotation_files=(jwt-secret api-key openwebui-key clients.json)
# Rotation recovery helper
# rotation_applied: the guest replaced the JWT secret. A guest that stopped
# before rotating (model probe, leftover rollback data, apt) leaves nothing to undo.
rotation_applied() {
  # An unreachable CT is unknown, not proof that the keys stayed unchanged.
  pct exec "$CT_ID" -- true >/dev/null 2>&1 || return 2
  if pct exec "$CT_ID" -- test -f "$rotation_stage/jwt-secret"; then
    ! pct exec "$CT_ID" -- cmp -s "$rotation_stage/jwt-secret" /etc/honcho-target/jwt-secret
  else
    pct exec "$CT_ID" -- test -f /etc/honcho-target/jwt-secret
  fi
}
# restore_rotation: only the credentials go back. The rest of honcho.env stays
# as this run wrote it, matching the code and schema the guest left running
# (its own rollback copies are gone once it succeeded); only its
# AUTH_JWT_SECRET line is set to the restored secret, read inside the CT so
# the secret is never on a command line.
restore_rotation() {
  local file attempt
  for file in "${rotation_files[@]}"; do
    if pct exec "$CT_ID" -- test -f "$rotation_stage/$file"; then
      pct exec "$CT_ID" -- cp -a -- "$rotation_stage/$file" "/etc/honcho-target/$file" || return 1
    else
      pct exec "$CT_ID" -- rm -f -- "/etc/honcho-target/$file" || return 1
    fi
  done
  pct exec "$CT_ID" -- python3 -c 'import pathlib
etc = pathlib.Path("/etc/honcho-target")
secret = (etc / "jwt-secret").read_text(encoding="utf-8").strip()
env = etc / "honcho.env"
lines = env.read_text(encoding="utf-8").splitlines()
lines = ["AUTH_JWT_SECRET=" + secret if line.startswith("AUTH_JWT_SECRET=") else line for line in lines]
env.write_text("\n".join(lines) + "\n", encoding="utf-8")' || return 1
  pct exec "$CT_ID" -- systemctl restart honcho-api.service honcho-deriver.service honcho-mcp.service \
    honcho-gateway.service || return 1
  for attempt in {1..30}; do
    if pct exec "$CT_ID" -- curl -fsS --max-time 2 http://127.0.0.1:8000/health >/dev/null &&
       pct exec "$CT_ID" -- curl -fsS --max-time 2 http://127.0.0.1:3000/health >/dev/null; then break; fi
    (( attempt < 30 )) || return 1
    sleep 2
  done
  pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" --restore \
    "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" \
    "$router_stage/webui-honcho-snapshot.json" || return 1
  pct exec "$CT_ID" -- rm -rf -- "$rotation_stage" || return 1
}
# clean_router_stage: the router CT's staging directory goes, unless a key
# rotation is still unresolved; then only the saved Open WebUI connection
# stays. Recovery is a plain --reconfigure, which pushes the credentials again.
clean_router_stage() {
  [[ $router_stage_created == true ]] || return 0
  if [[ $rotation_pending == false ]]; then
    pct exec "$ROUTER_CT_ID" -- rm -rf -- "$router_stage" >/dev/null 2>&1 ||
      printf 'Could not remove router CT %s:%s; it may still hold an Open WebUI admin token. Delete it when the CT is reachable.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
  else
    pct exec "$ROUTER_CT_ID" -- rm -f -- "$router_stage/admin-token" "$router_stage/honcho-api-key" \
      "$router_stage/integrate-webui.py" >/dev/null 2>&1 ||
      printf 'Could not remove staged credentials from router CT %s:%s; delete admin-token and honcho-api-key when the CT is reachable.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
  fi
}
# End rotation recovery helper.
cleanup() {
  local rc=$? applied_rc=0
  trap - EXIT
  if (( rc != 0 )) && [[ $rotation_pending == true ]]; then
    rotation_applied || applied_rc=$?
    if (( applied_rc == 1 )); then
      rotation_pending=false
      printf 'The run stopped before the Honcho keys were rotated; they are unchanged.\n' >&2
    elif (( applied_rc != 0 )); then
      printf 'Could not verify Honcho key rotation in CT %s; recovery files remain at %s.\n' \
        "$CT_ID" "$rotation_stage" >&2
      printf 'The previous Open WebUI connection remains in router CT %s:%s/webui-honcho-snapshot.json.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
      printf 'Once CT %s is reachable and Honcho is healthy, run this provisioner again with --reconfigure\n' "$CT_ID" >&2
      printf '(without --rotate-keys): it registers Open WebUI with the key Honcho has then. The agents keep\n' >&2
      printf 'their own keys either way. Then remove both directories.\n' >&2
    fi
  fi
  if (( rc != 0 )) && [[ $rotation_pending == true && $applied_rc == 0 ]]; then
    if restore_rotation; then
      rotation_staged=false
      rotation_pending=false
      printf 'Honcho key rotation was undone after downstream setup failed.\n' >&2
    else
      printf 'Honcho key rotation could not be fully undone; the previous secret and keys remain in CT %s:%s.\n' \
        "$CT_ID" "$rotation_stage" >&2
      printf 'The previous Open WebUI connection remains in router CT %s:%s/webui-honcho-snapshot.json.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
      printf 'Open WebUI may hold a key Honcho no longer accepts. Once Honcho is healthy, run this provisioner\n' >&2
      printf 'again with --reconfigure (without --rotate-keys): it registers Open WebUI with the key Honcho has\n' >&2
      printf 'now (the agents keep their own keys). Then remove %s from CT %s.\n' \
        "$rotation_stage" "$CT_ID" >&2
      printf 'After recovery, also remove %s from router CT %s.\n' "$router_stage" "$ROUTER_CT_ID" >&2
    fi
  fi
  if [[ $rotation_staged == true && $rotation_pending == false ]]; then
    pct exec "$CT_ID" -- rm -rf -- "$rotation_stage" >/dev/null 2>&1 || true
  fi
  if (( ! dry_run )); then clean_router_stage; fi
  rm -rf -- "$stage"
  exit "$rc"
}
trap cleanup EXIT
pve_summary "Honcho: $mode"
pve_row 'Router' "CT $ROUTER_CT_ID${ROUTER_IP:+ at $ROUTER_IP}"
if [[ $mode == create ]]; then
  pve_row 'Honcho CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
  pve_row 'Template' "$TEMPLATE"
  pve_row 'Network' "$IP_CIDR via $GATEWAY on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
else
  pve_row 'Honcho CT' "$CT_ID at ${IP_CIDR:-<existing address>}"
fi
pve_row 'Chat model' "$HONCHO_MODEL"
if [[ -z ${HONCHO_CONTEXT_TOKENS+set} ]]; then context_label='kept from the CT'
elif [[ -z $HONCHO_CONTEXT_TOKENS ]]; then context_label="Honcho's own budgets (128k)"
else context_label="$HONCHO_CONTEXT_TOKENS tokens"; fi
pve_row 'Context window' "$context_label"
pve_row 'Embedding model' 'Qwen3-Embedding-0.6B (1024 dimensions), llama.cpp on the CT'"'"'s CPU'
pve_row 'Agents allowed' "${HONCHO_CLIENT_IPS:-none}"
[[ $rotate_keys == false ]] || pve_row 'Keys' "replace the JWT secret, the admin key and Open WebUI's key"
pve_confirm "$( [[ $mode == create ]] && printf 'Create Honcho CT %s?' "$CT_ID" || printf 'Reconfigure Honcho CT %s?' "$CT_ID")"
if (( dry_run )); then
  ref_label=$HONCHO_REF
  if [[ $mode == reconfigure && -z $honcho_ref_given ]]; then ref_label="its recorded release ($HONCHO_REF if none)"; fi
  printf 'Would %s Honcho CT %s at %s with %s, then register MCP in router CT %s.\n' \
    "$mode" "$CT_ID" "$honcho_ip" "$ref_label" "$ROUTER_CT_ID"
  printf 'Router IP: %s; chat model: %s; embedding: qwen3-embedding-0.6b (1024 dimensions) in the Honcho CT.\n' \
    "${ROUTER_IP:-detected from router route}" "$HONCHO_MODEL"
  printf 'Agent IPs allowed to Honcho: %s.\n' "${HONCHO_CLIENT_IPS:-none}"
  [[ $HONCHO_ROUTER_FIREWALL == false ]] ||
    printf 'Would admit %s to the router API in %s/firewall/%s.fw, if that file exists.\n' "$honcho_ip" "$PVE_ETC" "$ROUTER_CT_ID"
  [[ $rotate_keys == false ]] || printf "Would replace the JWT secret, the admin key and Open WebUI's gateway key.\n"
  (( ${#budget_env[@]} == 0 )) || printf 'Would pass these budget settings to the CT: %s\n' "${budget_env[*]}"
  (( ${#kept_env[@]} == 0 )) || printf 'Would pass these settings to the CT: %s\n' "${kept_env[*]}"
  # A dry run does not inspect the CT, so it cannot apply these checks.
  [[ $mode != reconfigure ]] ||
    printf 'Not checked by a dry run: CT %s must be running, tagged honcho, and embed with qwen3-embedding-0.6b; a real run refuses it otherwise.\n' "$CT_ID"
  exit 0
fi
# Checked before anything is created: the run ends by registering MCP.
for tool in pct pvesh pvesm curl; do command -v "$tool" >/dev/null || die "Missing $tool"; done
if [[ $mode == reconfigure ]]; then honcho_reconfigure_preflight "$CT_ID"; fi
if [[ -z ${OPENWEBUI_ADMIN_TOKEN:-} ]]; then
  [[ ${NONINTERACTIVE:-false} != true && -t 0 ]] ||
    die 'Set OPENWEBUI_ADMIN_TOKEN to register Honcho MCP in Open WebUI.'
  printf '\n== Open WebUI ==\n' >&2
  IFS= read -r -s -p '  Open WebUI admin API token (required, not shown): ' OPENWEBUI_ADMIN_TOKEN ||
    die 'No Open WebUI admin token was entered.'
  printf '\n'
  [[ -n $OPENWEBUI_ADMIN_TOKEN ]] || die 'Open WebUI admin token is required.'
fi
pct status "$ROUTER_CT_ID" 2>/dev/null | grep -q 'status: running' || die "Router CT $ROUTER_CT_ID is not running."
router_source_ip=$(pct exec "$ROUTER_CT_ID" -- ip -4 route get "$honcho_ip" |
  sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
[[ $router_source_ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Cannot detect router source IP for Honcho.'
if [[ -n $ROUTER_IP && $ROUTER_IP != "$router_source_ip" ]]; then
  die "ROUTER_IP=$ROUTER_IP differs from router CT $ROUTER_CT_ID route source $router_source_ip for Honcho $honcho_ip."
fi
router_ip=${ROUTER_IP:-$router_source_ip}
router_port=$(pct exec "$ROUTER_CT_ID" -- sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env | head -n1" | tr -d '\r\n')
router_port=${router_port:-8000}
kindi_timeout=$(pct exec "$ROUTER_CT_ID" -- python3 -c 'import configparser, math, sys; c=configparser.ConfigParser(); c.read(sys.argv[1]); print(math.ceil(max(c.getfloat("http", "read_timeout_seconds", fallback=300), c.getfloat("http", "kindi_read_timeout_seconds", fallback=3600))))' /app/router/router.ini) ||
  die 'Cannot read the router timeout.'
kindi_timeout=${kindi_timeout//[$'\r\n ']/}
[[ $kindi_timeout =~ ^[1-9][0-9]{0,5}$ ]] || die "Invalid router Kindi timeout: $kindi_timeout"
[[ $router_port =~ ^[0-9]{2,5}$ ]] || die 'Invalid router port.'
router_url="http://${router_ip}:${router_port}"
pct exec "$ROUTER_CT_ID" -- awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' \
  /app/router/secrets.env > "$stage/router-api-key"
[[ -s $stage/router-api-key ]] || printf 'no-key\n' > "$stage/router-api-key"
pct exec "$ROUTER_CT_ID" -- awk -F= '$1 ~ /^(LMSTUDIO_API_TOKEN|STRATA_API_KEY|BASALT_API_KEY|MAYA_API_KEY|XOLOTL_API_KEY|AVALON_API_KEY|KINDI_API_KEY)$/ {print}' \
  /app/router/secrets.env > "$stage/backend-keys"
# Validate the admin token and endpoint before creating or modifying a Honcho CT.
printf '%s\n' "$OPENWEBUI_ADMIN_TOKEN" > "$stage/openwebui-admin-token"
router_stage_created=true
pct exec "$ROUTER_CT_ID" -- install -d -m 0700 "$router_stage"
pct push "$ROUTER_CT_ID" "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py" --perms 0600
pct push "$ROUTER_CT_ID" "$stage/openwebui-admin-token" "$router_stage/admin-token" --perms 0600
pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" --check \
  "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token"
if [[ $rotate_keys == true ]]; then
  pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" --snapshot \
    "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" \
    "$router_stage/webui-honcho-snapshot.json"
fi

fw_file="$PVE_ETC/firewall/${CT_ID}.fw"
if [[ $mode == create && -e $fw_file ]]; then die "Refusing to replace $fw_file"; fi
if [[ $mode == reconfigure && -z $honcho_clients_explicit && -f $fw_file ]]; then
  HONCHO_CLIENT_IPS=$(honcho_fw_clients "$fw_file")
fi
for ip in $HONCHO_CLIENT_IPS; do
  [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "Invalid HONCHO_CLIENT_IPS address: $ip"
done
if [[ $mode == create ]]; then
  pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID already exists."
  [[ -r $(pvesm path "$TEMPLATE") ]] || die "Template is unreadable: $TEMPLATE"
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB"
    --swap "$SWAP_MB" --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net"
    --onboot "$ONBOOT" --tags 'ai;ai-tools;osr-target;honcho'
    --description 'Honcho AI for Ollama Smart Router')
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  (umask 022; "${create[@]}")
  pct start "$CT_ID"
else
  pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "Honcho CT $CT_ID is not running."
  # The preflight required the honcho tag; add the rest tools/upgrade-all.sh uses.
  pve_ensure_tags "$CT_ID" ai ai-tools osr-target honcho
fi

rules=$(honcho_rules "$router_ip" $HONCHO_CLIENT_IPS)
if [[ $mode == reconfigure && -f $fw_file ]]; then
  result=0
  honcho_ct_fw_update "$fw_file" "$rules" "$stage" "$CT_ID" "$PVE_ETC" "$source_dir/../pve-firewall-swap.pl" || result=$?
  case $result in
    0) ;;
    1) die "$fw_file changed while it was read; nothing was changed. Check it, then rerun --reconfigure." ;;
    *) die "Could not update $fw_file; it was left as it was. Check it, then rerun --reconfigure." ;;
  esac
else
  printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\n\n[RULES]\n%s\n' "$rules" > "$fw_file"
fi

# The router CT's own firewall must let Honcho reach the router API. One owned
# rule, replaced when the Honcho address or router port changes; everything
# else in that file stays as it is.
router_fw="$PVE_ETC/firewall/${ROUTER_CT_ID}.fw"
if [[ $HONCHO_ROUTER_FIREWALL == true && -f $router_fw ]]; then
  result=0
  backup=$(honcho_router_fw_update "$router_fw" "$honcho_ip" "$router_port" "$ROUTER_CT_ID" \
    "$PVE_ETC" "$stage" "$source_dir/../pve-firewall-swap.pl") || result=$?
  case $result in
    0) printf 'Router CT %s firewall: admitted Honcho %s to port %s.\n' "$ROUTER_CT_ID" "$honcho_ip" "$router_port" ;;
    3) ;;
    1) die "Could not safely update $router_fw. Check the live file; its previous content is in $backup." ;;
    *) die "Could not safely update $router_fw. No verified backup was saved; check the live file before rerunning." ;;
  esac
fi

for attempt in {1..60}; do
  if pct exec "$CT_ID" -- sh -c 'test -d /run/systemd/system && ip route show default | grep -q . && getent hosts github.com >/dev/null' 2>/dev/null; then break; fi
  (( attempt < 60 )) || die 'Honcho CT did not get network and systemd readiness.'
  sleep 2
done
pct exec "$CT_ID" -- install -d -m 0700 /root/honcho-deploy
for file in install-target.sh budgets.py honcho-proxy.py direct_dispatch.py honcho-proxy.service honcho-api.service \
            honcho-deriver.service honcho-mcp.service honcho-embedding.service honcho-gateway.py honcho-clients \
            honcho-gateway.service; do
  pct push "$CT_ID" "$source_dir/$file" "/root/honcho-deploy/$file" --perms 0600
done
pct push "$CT_ID" "$stage/router-api-key" /root/honcho-deploy/router-api-key --perms 0600
pct push "$CT_ID" "$stage/backend-keys" /root/honcho-deploy/backend-keys --perms 0600
if [[ $rotate_keys == true ]]; then
  pct exec "$CT_ID" -- install -d -m 0700 "$rotation_stage"
  rotation_staged=true
  for file in "${rotation_files[@]}"; do
    if pct exec "$CT_ID" -- test -f "/etc/honcho-target/$file"; then
      pct exec "$CT_ID" -- cp -a -- "/etc/honcho-target/$file" "$rotation_stage/$file"
    fi
  done
  rotation_pending=true
fi
pct exec "$CT_ID" -- env "ROUTER_URL=$router_url" \
  "HONCHO_SKIP_CHAT_PROBE=$HONCHO_SKIP_CHAT_PROBE" "HONCHO_ROTATE_KEYS=$rotate_keys" \
  "KINDI_READ_TIMEOUT_SECONDS=$kindi_timeout" \
  "${kept_env[@]}" "${budget_env[@]}" \
  bash /root/honcho-deploy/install-target.sh
pct exec "$ROUTER_CT_ID" -- curl -fsS --max-time 10 "http://${honcho_ip}:3000/health" >/dev/null ||
  die 'Router CT cannot reach Honcho MCP; check the CT firewall.'

# Open WebUI gets its own gateway key, not a Honcho key: the gateway gives
# each Open WebUI user a workspace of their own.
pct exec "$CT_ID" -- cat /etc/honcho-target/openwebui-key > "$stage/honcho-api-key"
[[ -s $stage/honcho-api-key ]] || die 'Honcho did not generate a gateway key for Open WebUI.'
pct push "$ROUTER_CT_ID" "$stage/honcho-api-key" "$router_stage/honcho-api-key" --perms 0600
pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" \
  "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" "$router_stage/honcho-api-key" \
  "http://${honcho_ip}:3000"
if [[ $rotate_keys == true ]]; then
  rotation_pending=false
  if ! pct exec "$CT_ID" -- rm -rf -- "$rotation_stage"; then
    printf 'Honcho is registered with rotated keys, but could not remove the old keys from CT %s:%s. Remove that directory manually.\n' \
      "$CT_ID" "$rotation_stage" >&2
  fi
  rotation_staged=false
fi
printf 'Honcho API: http://%s:8000; MCP: http://%s:3000/mcp\n' "$honcho_ip" "$honcho_ip"
printf 'Every Open WebUI user granted the Honcho Memory tools gets a memory of their own\n'
printf '(Admin Settings > External Tools grants access; pct exec %s -- /usr/local/sbin/honcho-clients workspaces lists them).\n' "$CT_ID"
if [[ $rotate_keys == true ]]; then
  printf 'The JWT secret, the admin key and Open WebUI'"'"'s key changed; the agents keep their own keys.\n'
fi
