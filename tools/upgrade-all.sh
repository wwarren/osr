#!/usr/bin/env bash
# Upgrade the router and every OSR target in this Proxmox cluster (or on this
# standalone host) to the versions in this repository, keeping each one's
# recorded settings and configuration.
#
# It runs on one node. CTs on the other nodes are reached through
# tools/pct-cluster.sh, installed first on PATH as "pct" for this script and
# every provisioner it runs: it runs the real pct on the node that holds the
# CT, over root SSH for another node, the way Proxmox reaches its nodes. The
# provisioners also get PVE_LXC_DIR pointing at a view of every node's CT
# configurations, which is where their shared helpers look up tags and
# addresses, so they handle CTs anywhere in the cluster without changes.
#
# Each component is upgraded through its own supported path (the router's
# update-router-services.sh, a target's install-target.sh --upgrade, or its
# provisioner's --reconfigure), so the settings records, snapshots and
# rollbacks described in the target READMEs all still apply. Around each one
# this script adds a before/after functional check and, where the storage
# allows it, a Proxmox snapshot. When an upgrade fails, or leaves something
# that worked before broken, it says what broke and asks whether to retry,
# roll back or skip that component and carry on with the rest.
set -uo pipefail
umask 077

SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -P -- "$SCRIPT_DIR/.." && pwd)
# Every node's CT configurations, and corosync's member list (online state
# and address of each node), both shared by the cluster filesystem.
PVE_NODES_DIR=${PVE_NODES_DIR:-/etc/pve/nodes}
PVE_MEMBERS=${PVE_MEMBERS:-/etc/pve/.members}
PVE_FW_DIR=${PVE_FW_DIR:-/etc/pve/firewall}
LOG_ROOT=${OSR_UPGRADE_LOG_DIR:-/var/log/osr-upgrade}
LOCK_FILE=${OSR_UPGRADE_LOCK:-/run/lock/osr-upgrade-all.lock}
# Held while a run is upgrading, so a second run started on another node stops.
CLUSTER_LOCK=${OSR_UPGRADE_CLUSTER_LOCK:-/etc/pve/priv/osr-upgrade-all.lock}
# Checks and repairs root SSH between the nodes (the installer runs it too).
CLUSTER_SSH_TOOL=${OSR_CLUSTER_SSH_TOOL:-$REPO_ROOT/tools/setup-cluster-ssh.sh}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-300}
POLL_INTERVAL=${POLL_INTERVAL:-10}
MANAGE=/usr/local/bin/manage-model-servers
PROBE_PATH=/root/.osr-upgrade-probe.sh

usage() {
    cat <<'USAGE'
Usage: bash tools/upgrade-all.sh [options]

Run as root on any node of the Proxmox cluster (or on a standalone host), from
a clone of this repository with LF line endings (preferably inside tmux or
screen). It finds, on every node, the router CT (tag osr-router), every target
CT (tag osr-target plus the target's name) and every CT with hcom installed,
then upgrades them in dependency order:

  router -> Open WebUI -> Gitea, Mattermost -> model targets -> ComfyUI,
  Open Terminal -> Honcho -> Hermes, OpenClaw, DeepSeek Harness, OpenCode ->
  MQTT -> hcom

Settings are kept. The router updater never touches env/*.env, tiers,
litellm_config.yaml, router.ini, monitor.ini or secrets; target installers
reuse their settings records; provisioners take their recorded answers. Only
versions move to this repository's pins; an interactive run asks before moving
a Honcho, DeepSeek Harness or OpenCode release you pinned, and --yes accepts the move.
Open WebUI and ComfyUI are
never downgraded. Gitea and Mattermost releases are not pinned here: their setup
is re-applied (accounts, token and webhook kept) and their version stays.
Hermes Agent itself is not pinned either: its integration (units, dispatcher,
settings) is upgraded and Hermes stays at its installed version unless
--update-hermes is given (never past a HERMES_COMMIT pin).
Stopped CTs are left alone unless --include-stopped.

Everything runs from this node. CTs on other nodes are reached as root over
SSH, the way Proxmox reaches its nodes (pvecm sets up the keys), through
tools/pct-cluster.sh. A node that is offline or does not answer is reported,
and its CTs are not run. Only one run at a time is allowed in the cluster
(lock: /etc/pve/priv/osr-upgrade-all.lock).

For each component it records what works (services, listening ports, router
health, the router's view of a model server), takes a snapshot, upgrades and
checks again. If the upgrade fails or something that worked before no longer
does, it alerts you (terminal bell, and Mattermost through the router's
webhook when one is set) and asks: retry, retry interactively, roll back to
the snapshot, skip it, or abort.

Options:
  --dry-run             show the plan (and the router's pending diff); change nothing
  --list                list the components found and exit
  --only LIST           only these: comma-separated target names, CT IDs or
                        name@ID (router, open-webui and hcom are names too)
  --skip LIST           everything except these
  --node LIST           only CTs on these cluster nodes (comma-separated)
  -y, --yes             unattended: no questions; provisioners keep their
                        recorded settings (NONINTERACTIVE=true); failures
                        follow --on-failure
  --on-failure ACTION   ask (default with a terminal), rollback (default
                        without one), skip or abort
  --keep-pins           keep releases you pinned yourself instead of asking
  --update-hermes       also run `hermes update` in each Hermes CT (not one
                        pinned with HERMES_COMMIT) and restart its gateway and
                        dashboard; checked and rolled back like the rest
  --include-stopped     start stopped CTs, upgrade them, then stop them again
  --no-snapshot         take no Proxmox snapshots
  --require-snapshot    skip a CT that cannot be snapshotted
  --keep-snapshots      keep snapshots after successful upgrades
  --no-notify           do not post problems to Mattermost
  --health-timeout SEC  how long a component may take to recover (300)
  -h, --help            this help

Environment: ROUTER_CT_ID (when the cluster has several router CTs and --node
does not narrow them to one), MQTT_CT_ID
and MATTERMOST_CT_ID (when not exactly one CT carries that tag),
OPENWEBUI_ADMIN_TOKEN (otherwise asked once, and checked against Open WebUI,
when Honcho, or Hermes or OpenClaw with an Open WebUI connection, will be
reconfigured: with --yes or without stdin at the start of the run, on the
terminal; with no terminal at all, as under cron, those are not run without
it), HCOM_EXTRA_CTS (untagged CTs to check for hcom).
Logs: /var/log/osr-upgrade/<time>/, one file per component plus summary.txt.
USAGE
}

# --- What each component is ----------------------------------------------------------

# Upgrade order of the tagged targets: services the others use first, Honcho
# before the agents that use it, the broker before hcom.
TARGET_ORDER=(gitea mattermost llamacpp airllm ollama strata basalt maya xolotl avalon kindi
              comfyui open-terminal honcho hermes openclaw deepseek-harness opencode mqtt)
MODEL_TARGETS=" llamacpp airllm ollama strata basalt maya xolotl avalon kindi "

# Services that must be active afterwards if they were active before.
declare -A UNITS=(
    [router]='ollama-router litellm-proxy ollama-monitor open-webui'
    [open-webui]='open-webui ollama-router'
    [llamacpp]='llama-server llama-ollama-bridge'
    [airllm]='airllm-ollama-api'
    [ollama]='ollama'
    [strata]='strata' [basalt]='basalt' [maya]='maya' [xolotl]='xolotl' [avalon]='avalon' [kindi]='kindi'
    [comfyui]='comfyui'
    # The workspace gateway; per-user open-terminal-ws@<id> instances start on
    # demand and stop when idle, so neither they nor their ports are checked.
    [open-terminal]='open-terminal-gateway open-terminal-spawner'
    [honcho]='postgresql honcho-api honcho-deriver honcho-embedding honcho-mcp honcho-proxy honcho-gateway'
    [hermes]='hermes-gateway hermes-direct hermes-dashboard'
    [openclaw]='openclaw-gateway openclaw-direct'
    [deepseek-harness]='deepseek-harness'
    # opencode-api (the Open WebUI chat endpoint) runs only when it is on; a
    # unit that was not active before is not checked afterwards.
    [opencode]='opencode opencode-direct opencode-api'
    [gitea]='gitea'
    [mattermost]='mattermost'
    [mqtt]='mosquitto'
    [hcom]='osr-hcom-relay osr-hcom-mattermost'
)

# Targets upgraded inside their CT: the deployment directory and the files
# their provisioner copies there (tests/test-upgrade-all.sh keeps them equal).
declare -A GUEST_DIR=(
    [strata]=strata-target-deploy [basalt]=basalt-target-deploy [maya]=maya-target-deploy
    [xolotl]=xolotl-target-deploy [avalon]=avalon-target-deploy [kindi]=kindi-target-deploy
    [airllm]=airllm-target-deploy [llamacpp]=llama-target-deploy [ollama]=ollama-target-deploy
    [comfyui]=comfyui-target-deploy [open-terminal]=open-terminal-deploy
)
declare -A GUEST_FILES=(
    [strata]='install-target.sh strata.service'
    [basalt]='install-target.sh cuda-toolkit.sh basalt.service'
    [maya]='install-target.sh maya.service cuda-toolkit.sh'
    [xolotl]='install-target.sh cuda-toolkit.sh engram-index.py xolotl.service xolotl-weights.txt upstream-commit.txt'
    [avalon]='install-target.sh rocm-toolkit.sh cuda-toolkit.sh avalon.service avalon-weights.txt upstream-commit.txt'
    [kindi]='install-target.sh cuda-toolkit.sh kindi.service kindi-weights.txt upstream-commit.txt requirements-cpu.lock requirements-cuda.lock uv.lock'
    [airllm]='install-target.sh server.py requirements.txt requirements.lock airllm.env.example airllm-ollama-api.service README.md'
    [llamacpp]='install-target.sh bridge.py requirements.txt llama-server.service llama-ollama-bridge.service llama-server.env.example bridge.env.example'
    [ollama]='install-target.sh ollama.env.example ollama-target.conf README.md'
    [comfyui]='install-target.sh comfyui-target.conf comfyui.env.example README.md klein-weights.txt'
    [open-terminal]='install-target.sh open-terminal-gateway.service open-terminal-spawner.service open-terminal-ws@.service gateway.py spawner.py open-terminal-clients requirements.in requirements.lock'
)

# Gitea and Mattermost come from community scripts that install the newest
# release; their provisioners' --reconfigure re-applies the OSR setup
# (accounts, token, webhook: all kept) but never changes the release.
unpinned_service() { [[ $1 == gitea || $1 == mattermost ]]; }

method_of() {
    case $1 in
        router) echo router ;;
        open-webui) echo webui ;;
        hcom) echo hcom ;;
        gitea|mattermost|honcho|hermes|openclaw|deepseek-harness|opencode|mqtt) echo reconfigure ;;
        *) if [[ -n ${GUEST_DIR[$1]:-} ]]; then echo guest; else echo unknown; fi ;;
    esac
}

# --- Output and questions ------------------------------------------------------------

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
section() { printf '\n==== %s ====\n' "$*" >&2; }
csort() { LC_ALL=C sort "$@"; }

INTERACTIVE=false
PROMPT_FD=0
setup_prompts() {
    if [[ -n ${OSR_UPGRADE_ANSWERS:-} ]]; then
        # The tests answer from a file.
        exec {PROMPT_FD}<"$OSR_UPGRADE_ANSWERS" || die "Cannot read $OSR_UPGRADE_ANSWERS"
        INTERACTIVE=true
    elif ! $ASSUME_YES && [[ -t 0 ]]; then
        PROMPT_FD=0
        INTERACTIVE=true
    fi
}

# ask TEXT DEFAULT: the answer in REPLY (DEFAULT on Enter or at end of input).
ask() {
    printf '%s' "$1" >&2
    if ! IFS= read -r -u "$PROMPT_FD" REPLY; then REPLY=''; printf '\n' >&2; fi
    REPLY=${REPLY:-$2}
}
ask_yes() {  # ask_yes TEXT y|n
    local hint='[y/N]'
    [[ $2 == y ]] && hint='[Y/n]'
    while true; do
        ask "$1 $hint " "$2"
        case ${REPLY,,} in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
    done
}

# --- The cluster ---------------------------------------------------------------------

# setup_cluster: find this node, build PVE_LXC_DIR (every node's CT
# configurations, as links named <ID>.conf, so the provisioners' helpers and
# this script see the whole cluster) and put tools/pct-cluster.sh first on
# PATH as "pct". A generated stub runs it with bash, so its exec bit does not
# matter. Everything is exported for the provisioners.
declare -A CT_NODE=() NODE_STATE=()
LOCAL_NODE=''
setup_cluster() {
    local conf id node dir real
    [[ -d $PVE_NODES_DIR ]] || die "$PVE_NODES_DIR is missing: run this on a Proxmox node."
    LOCAL_NODE=${OSR_LOCAL_NODE:-}
    if [[ -z $LOCAL_NODE ]] && dir=$(readlink -f /etc/pve/lxc 2>/dev/null) && [[ $dir == */lxc ]]; then
        LOCAL_NODE=$(basename -- "$(dirname -- "$dir")")
    fi
    [[ -n $LOCAL_NODE ]] || LOCAL_NODE=$(hostname -s)
    [[ -d $PVE_NODES_DIR/$LOCAL_NODE ]] || die "This node ($LOCAL_NODE) is not in $PVE_NODES_DIR."
    PVE_LXC_DIR=$RUN_DIR/pve-lxc
    install -d -m 0700 "$PVE_LXC_DIR" "$RUN_DIR/bin" "$RUN_DIR/ssh" || die "Cannot write to $RUN_DIR"
    for conf in "$PVE_NODES_DIR"/*/lxc/*.conf; do
        [[ -f $conf ]] || continue
        id=${conf##*/}; id=${id%.conf}
        node=${conf%/lxc/*}; node=${node##*/}
        CT_NODE[$id]=$node
        ln -sfn -- "$conf" "$PVE_LXC_DIR/$id.conf"
    done
    real=$(command -v pct) || die 'Missing command: pct (run this on a Proxmox node).'
    printf '#!/bin/sh\nexec bash %q "$@"\n' "$REPO_ROOT/tools/pct-cluster.sh" > "$RUN_DIR/bin/pct"
    chmod 0700 "$RUN_DIR/bin/pct"
    export PVE_LXC_DIR OSR_REAL_PCT=$real OSR_LOCAL_NODE=$LOCAL_NODE OSR_PVE_NODES_DIR=$PVE_NODES_DIR \
           OSR_PVE_MEMBERS=$PVE_MEMBERS OSR_SSH_CONTROL_DIR=$RUN_DIR/ssh PATH="$RUN_DIR/bin:$PATH"
}

validate_node_filter() {
    local node count=0
    [[ -n $NODES ]] || return 0
    for node in ${NODES//,/ }; do
        [[ -d $PVE_NODES_DIR/$node ]] || die "No cluster node named $node."
        count=$((count + 1))
    done
    (( count > 0 )) || die '--node needs a node name.'
}

node_of() { printf '%s\n' "${CT_NODE[$1]:-?}"; }  # node_of ID: the node holding it

# node_usable ID: can this run act on the node holding CT ID? The node's state
# (local, ok, offline, unreachable, unknown) is checked once and kept.
node_usable() {
    local node
    node=$(node_of "$1")
    if [[ -z ${NODE_STATE[$node]:-} ]]; then
        if [[ $node == '?' ]]; then NODE_STATE[$node]=unknown
        else NODE_STATE[$node]=$(pct --osr-node-state "$node" 2>/dev/null || echo unreachable); fi
    fi
    [[ ${NODE_STATE[$node]} == local || ${NODE_STATE[$node]} == ok ]]
}

# node_problem ID: why the node holding CT ID cannot be used, for the plan.
node_problem() {
    local node
    node=$(node_of "$1")
    case ${NODE_STATE[$node]:-} in
        offline) echo "node $node is offline in the cluster" ;;
        unreachable) echo "node $node does not answer as root over SSH (check and repair: bash tools/setup-cluster-ssh.sh --node $node)" ;;
        *) echo "CT $1 is not on any node of this cluster" ;;
    esac
}

# offer_cluster_ssh: before anything is planned, find the nodes that hold OSR
# CTs (or the router) but do not answer as root over SSH. On a terminal, offer
# to check and repair them with tools/setup-cluster-ssh.sh, then look again;
# otherwise say how. Their CTs are not run while they stay unreachable.
offer_cluster_ssh() {
    local id node list
    local -a bad=()
    local -A seen=()
    while read -r id; do
        [[ -n $id ]] || continue
        node=$(node_of "$id")
        [[ -z ${seen[$node]:-} ]] || continue
        seen[$node]=1
        node_usable "$id" || [[ ${NODE_STATE[$node]:-} != unreachable ]] || bad+=("$node")
    done < <(tagged_cts osr-router
             for id in $(tagged_cts osr-target); do on_listed_node "$id" "$NODES" && printf '%s\n' "$id"; done)
    (( ${#bad[@]} )) || return 0
    list=$(IFS=,; printf '%s' "${bad[*]}")
    note ''
    note "These nodes hold OSR CTs but do not answer as root over SSH: ${bad[*]}."
    if ! $INTERACTIVE || $DRY_RUN; then
        note "Their CTs are not upgraded. Check and repair with: bash $CLUSTER_SSH_TOOL --node $list"
        return 0
    fi
    ask_yes 'Check and repair their SSH now (tools/setup-cluster-ssh.sh)?' y || return 0
    bash "$CLUSTER_SSH_TOOL" --node "$list" || note 'SSH to some of them is still missing; their CTs are not upgraded.'
    for node in "${bad[@]}"; do unset "NODE_STATE[$node]"; done
}

# take_cluster_lock: one upgrade-all.sh at a time in the whole cluster. The
# lock file lives in the cluster filesystem and names its holder; one left
# behind by a run on this node that no longer exists is taken over.
CLUSTER_LOCKED=false
take_cluster_lock() {
    local holder attempt
    [[ -d ${CLUSTER_LOCK%/*} ]] || die "Cluster lock directory ${CLUSTER_LOCK%/*} is unavailable."
    for attempt in 1 2; do
        if ( set -o noclobber; printf 'node=%s pid=%s started=%s\n' "$LOCAL_NODE" "$$" "$(date -Is)" > "$CLUSTER_LOCK" ) 2>/dev/null; then
            CLUSTER_LOCKED=true
            return 0
        fi
        # No lock file after a failed create: this is not a held lock. Loss of
        # quorum makes /etc/pve read-only; a bad path or permission can also
        # prevent creation.
        if [[ ! -f $CLUSTER_LOCK ]]; then
            die "Cannot create the cluster lock $CLUSTER_LOCK. Check quorum (pvecm status), whether /etc/pve is writable, and the lock path and permissions."
        fi
        holder=$(head -n 1 "$CLUSTER_LOCK" 2>/dev/null)
        if (( attempt == 1 )) && [[ $holder =~ ^node=([^ ]+)\ pid=([0-9]+) ]] &&
           [[ ${BASH_REMATCH[1]} == "$LOCAL_NODE" ]] && ! kill -0 "${BASH_REMATCH[2]}" 2>/dev/null; then
            note "Taking over the cluster lock left by an earlier run on this node ($holder)."
            rm -f -- "$CLUSTER_LOCK"
            continue
        fi
        break
    done
    die "Another upgrade-all.sh holds the cluster lock (${holder:-unreadable}). If that run is gone, delete $CLUSTER_LOCK."
}

# --- Proxmox helpers -----------------------------------------------------------------

ct_running() { [[ $(pct status "$1" 2>/dev/null) == 'status: running' ]]; }
ct_config_value() { pct config "$1" 2>/dev/null | sed -n "s/^$2: //p" | head -n 1; }

# The tags of a CT config's first section (later sections are snapshots).
conf_tags() {
    awk '/^\[/ { exit } /^tags:/ { sub(/^tags:[[:space:]]*/, ""); gsub(/[;, ]+/, " "); print }' "$1"
}
tagged_cts() {  # tagged_cts TAG: every CT in the cluster with that tag, by ID
    local conf id
    for conf in "$PVE_LXC_DIR"/*.conf; do
        [[ -f $conf ]] || continue
        id=${conf##*/}; id=${id%.conf}
        [[ " $(conf_tags "$conf") " == *" $1 "* ]] && printf '%s\n' "$id"
    done | sort -n
}
single_tagged() {  # single_tagged TAG: the one CT with that tag, else nothing
    local -a ids
    mapfile -t ids < <(tagged_cts "$1")
    if (( ${#ids[@]} == 1 )); then printf '%s\n' "${ids[0]}"; fi
}

# The names and addresses a router entry may use for this CT.
ct_identity() {
    ct_config_value "$1" hostname
    pct exec "$1" -- hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
}

# --- Discovery -----------------------------------------------------------------------

I_TARGET=() I_CT=() I_INFO=() I_RESULT=() I_NOTE=()
ROUTER_CT=''
add_item() {
    I_TARGET+=("$1"); I_CT+=("$2"); I_INFO+=("${3:-}"); I_RESULT+=(''); I_NOTE+=('')
}
item_label() { printf '%s@%s' "${I_TARGET[$1]}" "${I_CT[$1]}"; }

info_value() {  # info_value ITEM KEY (values never contain spaces)
    local word
    for word in ${I_INFO[$1]}; do
        if [[ $word == "$2="* ]]; then printf '%s\n' "${word#*=}"; return 0; fi
    done
}

# Run in a CT: prints target=…, native=…, mattermost=true and instructions=…
# when hcom is installed there; exits 3 when it is not. The hcom installer
# records its target in /etc/osr-hcom/target; the units are only a fallback.
# Native Hermes mode is what gives the gateway its HCOM_DIR drop-in and the
# hcom plugin. (State under /home/hermes/.osr-hcom does not tell: earlier
# releases kept non-native state there too, and the installer moves it out.)
# The instructions file is passed back only when the block sits in a custom
# file; the installer itself moves it out of Hermes's legacy .hermes/AGENTS.md.
# OSR_PROBE_ROOT is for the tests; in a CT it is unset.
HCOM_PROBE='
r=${OSR_PROBE_ROOT:-}
has() { systemctl list-unit-files --no-legend "$1.service" 2>/dev/null | grep -q .; }
has osr-hcom-relay || exit 3
t=$(cat "$r/etc/osr-hcom/target" 2>/dev/null | tr -d "[:space:]")
case $t in
  hermes|openclaw|deepseek-harness|opencode|observer) ;;
  *) if has osr-hcom-mattermost; then t=observer
     elif has hermes-gateway; then t=hermes
     elif has openclaw-gateway; then t=openclaw
     elif has deepseek-harness; then t=deepseek-harness
     elif has opencode; then t=opencode
     else t=observer; fi ;;
esac
echo "target=$t"
if [ "$t" = hermes ] && { grep -qs "^Environment=HCOM_DIR=" "$r/etc/systemd/system/hermes-gateway.service.d/30-osr-hcom.conf" ||
                         [ -d "$r/home/hermes/.hermes/plugins/hcom" ]; }; then
  echo native=true
else
  echo native=false
fi
if has osr-hcom-mattermost || [ -e "$r/etc/osr-hcom/mattermost-webhook" ]; then echo mattermost=true; fi
case $t in
  hermes) d=$r/home/hermes/AGENTS.md ;;
  openclaw) d=$r/home/openclaw/.openclaw/workspace/AGENTS.md ;;
  deepseek-harness) d=$r/var/lib/deepseek-harness/home/AGENTS.md ;;
  opencode) d=$r/home/opencode/.config/opencode/AGENTS.md ;;
  *) d= ;;
esac
if [ -n "$d" ] && ! grep -qsF "<!-- osr-hcom:start -->" "$d"; then
  f=$(find "$r/home" "$r/var/lib" "$r/root" -maxdepth 6 -name "*.md" -size -1024k -exec grep -lF "<!-- osr-hcom:start -->" {} + 2>/dev/null |
      grep -vxF "$r/home/hermes/.hermes/AGENTS.md" | head -n 2)
  if [ -n "$f" ] && [ "$(printf "%s\n" "$f" | wc -l)" -eq 1 ]; then echo "instructions=${f#"$r"}"; fi
fi
'

on_listed_node() {  # on_listed_node ID LIST: is CT ID on a node in LIST (or is LIST empty)?
    local node word
    local -a words
    [[ -n $2 ]] || return 0
    node=$(node_of "$1")
    IFS=', ' read -r -a words <<< "$2"
    for word in "${words[@]}"; do [[ $word != "$node" ]] || return 0; done
    return 1
}

# Run in a Hermes CT: prints http:hermes-gateway, http:hermes-direct and
# http:hermes-dashboard for each of Hermes's HTTP endpoints that answers the
# way its installer requires (the gateway's /health with "status": "ok" on
# API_SERVER_PORT from Hermes's .env, the direct dispatcher's /healthz on
# 127.0.0.1:8765, the dashboard's /api/status on 9119). Whatever answered before
# an upgrade must answer again afterwards. OSR_PROBE_ROOT is for the tests.
read -r -d '' HERMES_HTTP_PROBE <<'PROBE'
r=${OSR_PROBE_ROOT:-}
command -v curl >/dev/null 2>&1 || exit 0
port=$(sed -n 's/^API_SERVER_PORT=//p' "$r/home/hermes/.hermes/.env" 2>/dev/null | tail -n 1 | tr -d "\"' \r")
case $port in ''|*[!0-9]*) port=8642 ;; esac
if curl -fsS -m 10 "http://127.0.0.1:$port/health" 2>/dev/null | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    echo http:hermes-gateway
fi
if curl -fsS -m 10 -o /dev/null http://127.0.0.1:8765/healthz 2>/dev/null; then echo http:hermes-direct; fi
if [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/api/status 2>/dev/null)" = 200 ]; then
    echo http:hermes-dashboard
fi
exit 0
PROBE

discover() {
    local -a routers=() all_routers tagged candidates order=() observers=()
    local id t name tags info i described
    mapfile -t all_routers < <(tagged_cts osr-router)
    # The router is used for checks even when --node leaves it out of the
    # run. Only when several OSR installations share the cluster does --node
    # say which one the selected CTs belong to.
    for id in "${all_routers[@]}"; do on_listed_node "$id" "$NODES" && routers+=("$id"); done
    if [[ -n ${ROUTER_CT_ID:-} ]]; then
        ROUTER_CT=$ROUTER_CT_ID
    elif (( ${#all_routers[@]} == 1 )); then
        ROUTER_CT=${all_routers[0]}
    elif (( ${#routers[@]} == 1 )); then
        ROUTER_CT=${routers[0]}
    elif (( ${#all_routers[@]} > 1 )); then
        described=''
        for id in "${all_routers[@]}"; do described+="${described:+, }$id on $(node_of "$id")"; done
        die "Several CTs are tagged osr-router ($described). Set ROUTER_CT_ID to the one to upgrade, or limit the run with --node."
    else
        note 'No router CT (tag osr-router) in the cluster: the router is not upgraded and router checks are off.'
    fi
    if [[ -n $ROUTER_CT ]] && ! node_usable "$ROUTER_CT"; then
        note "The router CT $ROUTER_CT: $(node_problem "$ROUTER_CT"); router checks are off."
    fi
    if [[ -n $ROUTER_CT ]]; then
        add_item router "$ROUTER_CT"
        add_item open-webui "$ROUTER_CT"
    fi

    # The first known target name among a CT's tags says what it is.
    declare -A target_of=()
    mapfile -t tagged < <(tagged_cts osr-target)
    for id in "${tagged[@]}"; do
        tags=" $(conf_tags "$PVE_LXC_DIR/$id.conf") "
        for name in "${TARGET_ORDER[@]}"; do
            if [[ $tags == *" $name "* ]]; then target_of[$id]=$name; break; fi
        done
        [[ -n ${target_of[$id]:-} ]] || note "CT $id is tagged osr-target but names no target this script knows; it is left alone."
    done
    for t in "${TARGET_ORDER[@]}"; do
        for id in "${tagged[@]}"; do
            [[ ${target_of[$id]:-} != "$t" ]] || add_item "$t" "$id"
        done
    done

    # hcom lives inside existing CTs (agents, or an observer that may share the
    # broker CT), so look for its relay unit in every running OSR CT.
    mapfile -t candidates < <({ printf '%s\n' "${tagged[@]}" "${all_routers[@]}"
                                 sed 's/[, ][, ]*/\n/g' <<< "${HCOM_EXTRA_CTS:-}"; } | sed '/^$/d' | sort -nu)
    for id in "${candidates[@]}"; do
        on_listed_node "$id" "$NODES" && node_usable "$id" || continue
        ct_running "$id" || continue
        info=$(pct exec "$id" -- sh -c "$HCOM_PROBE" 2>/dev/null) || continue
        [[ $info == target=* ]] || continue
        add_item hcom "$id" "$(tr '\n' ' ' <<< "$info")"
    done
    # Agents before the observer.
    for i in "${!I_TARGET[@]}"; do
        if [[ ${I_TARGET[$i]} == hcom && ${I_INFO[$i]} == *target=observer* ]]; then observers+=("$i"); else order+=("$i"); fi
    done
    reorder_items "${order[@]}" "${observers[@]}"
}

reorder_items() {
    local -a new_target=() new_ct=() new_info=() new_result=() new_note=()
    local i
    for i in "$@"; do
        new_target+=("${I_TARGET[$i]}"); new_ct+=("${I_CT[$i]}"); new_info+=("${I_INFO[$i]}")
        new_result+=("${I_RESULT[$i]}"); new_note+=("${I_NOTE[$i]}")
    done
    I_TARGET=("${new_target[@]}"); I_CT=("${new_ct[@]}"); I_INFO=("${new_info[@]}")
    I_RESULT=("${new_result[@]}"); I_NOTE=("${new_note[@]}")
}

# in_list ITEM LIST: does the comma-separated LIST name this item?
in_list() {
    local i=$1 word
    local -a words
    IFS=', ' read -r -a words <<< "$2"
    for word in "${words[@]}"; do
        [[ -n $word ]] || continue
        if [[ $word == "${I_TARGET[$i]}" || $word == "${I_CT[$i]}" || $word == "$(item_label "$i")" ]]; then return 0; fi
    done
    return 1
}

apply_filters() {
    local i
    for i in "${!I_TARGET[@]}"; do
        if [[ -n $ONLY ]] && ! in_list "$i" "$ONLY"; then I_RESULT[i]=filtered; fi
        if [[ -n $SKIP ]] && in_list "$i" "$SKIP"; then I_RESULT[i]=filtered; fi
        on_listed_node "${I_CT[$i]}" "$NODES" || I_RESULT[i]=filtered
    done
}

# check_nodes: a CT whose node is offline or does not answer is not run;
# neither is anything that needs the router on such a node.
check_nodes() {
    local i t
    for i in "${!I_TARGET[@]}"; do
        [[ -z ${I_RESULT[$i]} ]] || continue
        t=${I_TARGET[$i]}
        if ! node_usable "${I_CT[$i]}"; then
            I_RESULT[i]=not-run; I_NOTE[i]=$(node_problem "${I_CT[$i]}")
        elif [[ -n $ROUTER_CT ]] && ! node_usable "$ROUTER_CT" &&
             [[ $t == honcho || $t == hermes || $t == openclaw || $t == deepseek-harness || $t == opencode ]]; then
            I_RESULT[i]=not-run; I_NOTE[i]="needs the router CT $ROUTER_CT: $(node_problem "$ROUTER_CT")"
        fi
    done
}

selected() {  # selected TARGET: is any item of TARGET still to be handled?
    local i
    for i in "${!I_TARGET[@]}"; do
        [[ ${I_TARGET[$i]} == "$1" && ${I_RESULT[$i]} != filtered ]] && return 0
    done
    return 1
}

result_of() {  # result_of TARGET: the result of its first item
    local i
    for i in "${!I_TARGET[@]}"; do
        if [[ ${I_TARGET[$i]} == "$1" ]]; then printf '%s\n' "${I_RESULT[$i]}"; return 0; fi
    done
}

# --- Router probes -------------------------------------------------------------------

# Copied into the router CT once per run, so the router key is read there and
# reaches curl on stdin, never on a command line.
write_probe() {
    cat > "$1" <<'PROBE'
#!/bin/sh
key=$(sed -n 's/^ROUTER_API_KEY=//p' /app/router/secrets.env 2>/dev/null | tail -n 1)
key=${key#\"}; key=${key%\"}; key=${key#\'}; key=${key%\'}
auth() { if [ -n "$key" ]; then printf 'Authorization: Bearer %s\n' "$key"; fi; }
case $1 in
  healthz) curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8000/healthz ;;
  models) auth | curl -s -o /dev/null -m 30 -w '%{http_code}' -H @- http://127.0.0.1:8000/v1/models ;;
  inventory) auth | curl -fsS -m 120 -H @- -X POST http://127.0.0.1:8000/routing/refresh ;;
  webui) port=$(sed -n 's/^PORT=//p' /app/openwebui/.env 2>/dev/null | tail -n 1)
         curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${port:-8080}/health" ;;
  # An Open WebUI token, as an Authorization header on stdin: /openai/config
  # answers 200 only to an administrator.
  webui-admin) port=$(sed -n 's/^PORT=//p' /app/openwebui/.env 2>/dev/null | tail -n 1)
         curl -s -o /dev/null -m 15 -w '%{http_code}' -H @- "http://127.0.0.1:${port:-8080}/openai/config" ;;
esac
PROBE
}
PROBE_READY=false
router_probe() {  # router_probe CHECK: stdin goes to the probe (webui-admin reads it)
    [[ -n $ROUTER_CT ]] && ct_running "$ROUTER_CT" || return 1
    if ! $PROBE_READY; then
        write_probe "$RUN_DIR/probe.sh"
        pct push "$ROUTER_CT" "$RUN_DIR/probe.sh" "$PROBE_PATH" --perms 0700 >/dev/null 2>&1 || return 1
        PROBE_READY=true
    fi
    pct exec "$ROUTER_CT" -- sh "$PROBE_PATH" "$1" 2>/dev/null
}

# up_servers HOST...: "server:<entry>" for each router entry that is up with
# models and whose host is one of HOST (* for all).
INVENTORY_FILTER='
import json, sys
from urllib.parse import urlsplit
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
want = {a.lower() for a in sys.argv[2:]}
for entry, state in (data.get("server_status") or {}).items():
    scheme = entry.split("://", 1)[0]
    url = entry.split("+", 1)[1] if "+" in scheme else entry
    try:
        host = (urlsplit(url).hostname or "").lower()
    except ValueError:
        host = ""
    if "*" not in want and host not in want:
        continue
    if state.get("up") and int(state.get("model_count") or 0) > 0:
        print("server:" + entry)
'
up_servers() {
    local file=$RUN_DIR/inventory.json
    router_probe inventory > "$file" || return 0
    python3 -c "$INVENTORY_FILTER" "$file" "$@"
}

# --- Functional state ----------------------------------------------------------------

# One line per thing that works: ct:running, unit:<name>, port:<n>,
# http:<check> and server:<router entry>. Whatever worked before the upgrade
# must work again afterwards.
collect_state() {
    local i=$1 t=${I_TARGET[$1]} id=${I_CT[$1]} units agent
    local -a ident
    if ! ct_running "$id"; then echo ct:stopped; return 0; fi
    echo ct:running
    units=${UNITS[$t]:-}
    if [[ $t == hcom ]]; then
        agent=$(info_value "$i" target)
        [[ $agent == observer ]] || units+=" ${UNITS[$agent]:-}"
    fi
    # shellcheck disable=SC2086  # unit names are single words
    pct exec "$id" -- sh -c 'for u in "$@"; do systemctl is-active --quiet "$u.service" 2>/dev/null && echo "unit:$u"; done
        if command -v ss >/dev/null 2>&1; then ss -Hltn 2>/dev/null | sed "s/^/ss: /"; fi' sh $units 2>/dev/null |
        # Ephemeral ports (such as Ollama's per-model runners) come and go by
        # themselves, and so do Open Terminal's workspaces (20000-29999).
        awk -v t="$t" '$1 == "ss:" { a = $5; sub(/.*:/, "", a)
            if (a ~ /^[0-9]+$/ && a + 0 < 32768 && !(t == "open-terminal" && a + 0 >= 20000 && a + 0 <= 29999)) print "port:" a
            next } { print }'
    case $t in
        router|open-webui)
            [[ $(router_probe healthz) == 200 ]] && echo http:router-healthz
            [[ $(router_probe models) == 200 ]] && echo http:router-models
            [[ $(router_probe webui) == 200 ]] && echo http:openwebui-health
            [[ $t == router ]] && up_servers '*'
            ;;
    esac
    if [[ $MODEL_TARGETS == *" $t "* && -n $ROUTER_CT && $id != "$ROUTER_CT" ]]; then
        mapfile -t ident < <(ct_identity "$id")
        (( ${#ident[@]} == 0 )) || up_servers "${ident[@]}"
    fi
    # Hermes's own HTTP checks: an active unit with a listening port can still
    # answer errors (for example after hcom restarts the gateway).
    if [[ $t == hermes || ( $t == hcom && ${agent:-} == hermes ) ]]; then
        pct exec "$id" -- sh -c "$HERMES_HTTP_PROBE" 2>/dev/null | grep -E '^http:hermes-(gateway|direct|dashboard)$'
    fi
    return 0
}

describe_missing() {
    local line
    while IFS= read -r line; do
        case $line in
            ct:running) echo "  - the CT is not running" ;;
            unit:*) echo "  - service ${line#unit:} is no longer active" ;;
            port:*) echo "  - nothing listens on TCP port ${line#port:} any more" ;;
            http:router-healthz) echo "  - the router's /healthz does not answer 200" ;;
            http:router-models) echo "  - the router's /v1/models does not answer 200" ;;
            http:openwebui-health) echo "  - Open WebUI's /health does not answer 200" ;;
            http:hermes-gateway) echo "  - Hermes's API server /health (on its API port) no longer answers \"status\": \"ok\"" ;;
            http:hermes-direct) echo "  - Hermes's direct dispatcher (127.0.0.1:8765/healthz) no longer answers" ;;
            http:hermes-dashboard) echo "  - the Hermes dashboard (port 9119, /api/status) no longer answers 200" ;;
            server:*) echo "  - the router no longer lists ${line#server:} as up with models" ;;
            *) echo "  - $line" ;;
        esac
    done
}

# verify_item ITEM PRE POST: wait until everything in PRE works again; what
# does not is left in POST.missing.
verify_item() {
    local i=$1 pre=$2 post=$3 deadline=$((SECONDS + HEALTH_TIMEOUT))
    while true; do
        collect_state "$i" | csort -u > "$post"
        LC_ALL=C comm -23 "$pre" "$post" > "$post.missing"
        [[ -s $post.missing ]] || return 0
        (( SECONDS < deadline )) || return 1
        sleep "$POLL_INTERVAL"
    done
}

# --- Snapshots -----------------------------------------------------------------------

# take_snapshot ITEM LOG: SNAP holds the snapshot's name, or stays empty.
take_snapshot() {
    local i=$1 log=$2 id=${I_CT[$1]} name
    SNAP=''
    $SNAPSHOTS || return 0
    name="osr-upg-${RUN_STAMP}-$i"
    if pct snapshot "$id" "$name" --description "Before tools/upgrade-all.sh ($REPO_REV)" >> "$log" 2>&1; then
        SNAP=$name
        note "Snapshot $name of CT $id taken."
        return 0
    fi
    note "CT $id cannot be snapshotted (storage without snapshots, a bind mount, or a lock; see $log)."
    $REQUIRE_SNAPSHOT && return 1
    note 'Without a snapshot, recovery depends on the component updater; check its log after a failure.'
    if $INTERACTIVE && ! ask_yes "Upgrade CT $id without a snapshot?" y; then return 1; fi
    return 0
}

drop_snapshot() {  # drop_snapshot ID NAME LOG
    [[ -n $2 ]] || return 0
    pct delsnapshot "$1" "$2" >> "$3" 2>&1 ||
        note "Could not delete snapshot $2 of CT $1; remove it with: pct delsnapshot $1 $2"
}

rollback_snapshot() {  # rollback_snapshot ID NAME LOG
    note "Rolling CT $1 back to $2 ..."
    if ct_running "$1"; then pct stop "$1" >> "$3" 2>&1 || return 1; fi
    pct rollback "$1" "$2" >> "$3" 2>&1 || return 1
    pct start "$1" >> "$3" 2>&1
}

# --- Upgrade commands ----------------------------------------------------------------

# How a child runs: "auto" takes recorded answers and asks only for what has
# none, "unattended" never asks, "interactive" asks everything.
child_mode() {
    if [[ $1 == interactive ]]; then echo interactive
    elif $INTERACTIVE; then echo auto
    else echo unattended; fi
}

run_router() {
    CT_ID=$ROUTER_CT bash "$REPO_ROOT/tools/update-router-services.sh" --host --no-push </dev/null
}

run_webui() {
    local version
    version=$(info_value "$1" version)
    case $(info_value "$1" action) in
        pin) pct exec "$ROUTER_CT" -- "$MANAGE" set-webui-version "$version" --apply --yes </dev/null ;;
        apply) pct exec "$ROUTER_CT" -- "$MANAGE" apply --yes </dev/null ;;
    esac
}

run_guest() {  # run_guest ITEM MODE
    local i=$1 t=${I_TARGET[$1]} id=${I_CT[$1]} dir file perms port
    local -a envs=() args=(--upgrade)
    dir=/root/${GUEST_DIR[$t]}
    pct exec "$id" -- install -d -m 0700 "$dir" || return 1
    for file in ${GUEST_FILES[$t]}; do
        case $file in *.sh|*.py) perms=0755 ;; *) perms=0644 ;; esac
        pct push "$id" "$REPO_ROOT/targets/$t/$file" "$dir/$file" --perms "$perms" || return 1
    done
    if [[ $t == open-terminal ]]; then
        # A rerun is its upgrade; without the recorded port it would reset it.
        args=()
        port=$(pct exec "$id" -- sed -n 's/^OPEN_TERMINAL_PORT=//p' /etc/open-terminal/service.env 2>/dev/null | tail -n 1)
        [[ -z $port ]] || envs+=("OPEN_TERMINAL_PORT=$port")
    fi
    if [[ $(child_mode "$2") == interactive ]]; then
        # On another node the installer gets a terminal only when asked for.
        OSR_PCT_TTY=1 pct exec "$id" -- env "${envs[@]}" bash "$dir/install-target.sh" "${args[@]}"
    else
        pct exec "$id" -- env "${envs[@]}" bash "$dir/install-target.sh" "${args[@]}" </dev/null
    fi
}

# Does the router URL this CT recorded point at the router CT found here?
uses_router_ct() {
    local url host ip
    url=$(pct exec "$1" -- sh -c 'cat /etc/hermes-target/settings /etc/openclaw-target/settings /etc/deepseek-harness/settings /etc/opencode-target/settings /etc/honcho-target/proxy.settings /etc/honcho-target/settings.env 2>/dev/null' |
          sed -n 's/^\(DSH_\)\{0,1\}ROUTER_URL=//p' | head -n 1 | tr -d '"'\''\r')
    [[ -n $url ]] || return 0
    host=${url#*://}; host=${host%%[:/]*}
    while IFS= read -r ip; do [[ $ip == "$host" ]] && return 0; done < <(ct_identity "$ROUTER_CT")
    return 1
}

# mqtt_env ID STAGE: KEY=VALUE lines that reproduce the broker's settings.
mqtt_env() {
    local id=$1 stage=$2 net ip gw rule broker
    net=$(ct_config_value "$id" net0)
    ip=$(tr ',' '\n' <<< "$net" | sed -n 's/^ip=//p')
    gw=$(tr ',' '\n' <<< "$net" | sed -n 's/^gw=//p')
    [[ $ip == */* ]] || { note "Broker CT $id has no static IPv4 address in net0 ($net)."; return 1; }
    rule=$(grep -F '# osr-hcom-mqtt' "$PVE_FW_DIR/$id.fw" 2>/dev/null | head -n 1)
    [[ $rule =~ -source[[:space:]]+([0-9./]+) ]] || { note "No '# osr-hcom-mqtt' rule in $PVE_FW_DIR/$id.fw."; return 1; }
    printf 'MQTT_CLIENT_CIDR=%s\nIP_CIDR=%s\nGATEWAY=%s\n' "${BASH_REMATCH[1]}" "$ip" "$gw"
    broker=$(pct exec "$id" -- python3 -c 'import json; print(json.load(open("/etc/mqtt-target/relay.json"))["broker"])' 2>/dev/null)
    [[ $broker =~ ^mqtts?://([^/:]+):([0-9]+)$ ]] || { note "Cannot read the broker URL in CT $id."; return 1; }
    printf 'MQTT_HOST=%s\nMQTT_PORT=%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    # A TLS broker needs its certificate and key on every reconfigure: give it
    # back the ones it already serves.
    if pct exec "$id" -- test -e /etc/mosquitto/osr-hcom.crt; then
        install -d -m 0700 "$stage" || return 1
        if ! pct pull "$id" /etc/mosquitto/osr-hcom.crt "$stage/tls.crt" ||
           ! pct pull "$id" /etc/mosquitto/osr-hcom.key "$stage/tls.key"; then
            note "Cannot copy the broker's TLS files."
            return 1
        fi
        chmod 0600 "$stage/tls.crt" "$stage/tls.key"
        printf 'MQTT_TLS_CERT_FILE=%s\nMQTT_TLS_KEY_FILE=%s\n' "$stage/tls.crt" "$stage/tls.key"
    fi
}

run_reconfigure() {  # run_reconfigure ITEM MODE
    local i=$1 t=${I_TARGET[$1]} id=${I_CT[$1]} mode word line settings
    local -a envs=("CT_ID=$id")
    mode=$(child_mode "$2")
    # "auto" is how the router installer runs provisioners: recorded answers,
    # and no second confirmation of a run the user has already started.
    case $mode in
        unattended) envs+=(NONINTERACTIVE=true) ;;
        auto) envs+=(PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false) ;;
    esac
    case $t in
        honcho|hermes|openclaw|deepseek-harness|opencode)
            if [[ -n $ROUTER_CT ]] && uses_router_ct "$id"; then envs+=("ROUTER_CT_ID=$ROUTER_CT"); fi ;;
    esac
    # Through the environment, not env's arguments, which ps would show.
    # run_item runs in its own subshell, so this export ends with it.
    case $t in
        honcho|hermes|openclaw|opencode) [[ -z $WEBUI_TOKEN ]] || export OPENWEBUI_ADMIN_TOKEN=$WEBUI_TOKEN ;;
    esac
    for word in ${I_INFO[$i]}; do
        case $word in DSH_VERSION=*|HONCHO_REF=*|OPENCODE_VERSION=*) envs+=("$word") ;; esac
    done
    if [[ $t == mqtt ]]; then
        settings=$(mqtt_env "$id" "$RUN_DIR/mqtt-$id") || return 1
        while IFS= read -r line; do [[ -z $line ]] || envs+=("$line"); done <<< "$settings"
    fi
    if [[ $mode == unattended ]]; then
        env "${envs[@]}" bash "$REPO_ROOT/targets/$t/provision-lxc.sh" --reconfigure </dev/null
    else
        env "${envs[@]}" bash "$REPO_ROOT/targets/$t/provision-lxc.sh" --reconfigure
    fi
}

run_hcom() {
    local i=$1 instructions
    local -a envs=("CT_ID=${I_CT[$i]}" "MQTT_CT_ID=$HCOM_MQTT_CT" "HCOM_TARGET=$(info_value "$i" target)"
                   "HCOM_HERMES_NATIVE=$(info_value "$i" native)")
    [[ $(info_value "$i" mattermost) != true ]] || envs+=("MATTERMOST_CT_ID=$HCOM_MATTERMOST_CT")
    instructions=$(info_value "$i" instructions)
    [[ -z $instructions ]] || envs+=("HCOM_INSTRUCTIONS_FILE=$instructions")
    env "${envs[@]}" bash "$REPO_ROOT/targets/hcom/provision-lxc.sh" --reconfigure </dev/null
}

# Hermes Agent's own code is not pinned by this repository: its provisioner
# installs it once (or moves it to a HERMES_COMMIT pin) and leaves it there.
# `hermes update`, as the hermes user, is its supported update (see
# targets/hermes/README.md); --update-hermes runs it after the reconfigure.
HERMES_CHECKOUT=/home/hermes/.hermes/hermes-agent
hermes_commit() {  # hermes_commit CT: the checkout's commit, or empty
    pct exec "$1" -- git -c "safe.directory=$HERMES_CHECKOUT" -C "$HERMES_CHECKOUT" rev-parse HEAD </dev/null 2>/dev/null
}

hermes_recorded_pin() {  # hermes_recorded_pin CT: the recorded pin, or empty
    pct exec "$1" -- sed -n 's/^HERMES_COMMIT=//p' /etc/hermes-target/settings 2>/dev/null |
        tail -n 1 | tr -d "\"'\r "
}

# hermes_update_wanted ITEM: will this run update Hermes itself?
hermes_update_wanted() {
    [[ ${I_TARGET[$1]} == hermes ]] && $UPDATE_HERMES && [[ -z $(info_value "$1" hermes_pin) ]]
}

# update_hermes ITEM: hermes update, then restart what runs Hermes's code. The
# OSR-HERMES line tells process_item what happened.
update_hermes() {
    local id=${I_CT[$1]} before after pin
    if ! pin=$(hermes_recorded_pin "$id"); then
        note 'Cannot verify HERMES_COMMIT in the CT settings; Hermes itself was not updated.'
        return 1
    fi
    if [[ -n $pin ]]; then
        if [[ ! $pin =~ ^[0-9a-f]{40}$ ]]; then
            note 'The CT has an invalid HERMES_COMMIT; Hermes itself was not updated.'
            return 1
        fi
        echo "OSR-HERMES: pin ${pin:0:12}"
        return 0
    fi
    if ! before=$(hermes_commit "$id") || [[ ! $before =~ ^[0-9a-f]{40}$ ]]; then
        note 'Cannot read the installed Hermes commit; Hermes itself was not updated.'
        return 1
    fi
    note "Updating Hermes itself (--update-hermes): hermes update as the hermes user."
    if ! pct exec "$id" -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes update </dev/null; then
        note 'hermes update failed.'
        return 1
    fi
    if ! pct exec "$id" -- systemctl try-restart hermes-gateway.service hermes-dashboard.service </dev/null; then
        note 'Restarting hermes-gateway and hermes-dashboard after hermes update failed.'
        return 1
    fi
    if ! after=$(hermes_commit "$id") || [[ ! $after =~ ^[0-9a-f]{40}$ ]]; then
        note 'Hermes update finished, but its new commit could not be verified.'
        return 1
    fi
    if [[ $after == "$before" ]]; then
        echo "OSR-HERMES: same ${after:0:12}"
    else
        echo "OSR-HERMES: moved ${before:0:12} to ${after:0:12}"
    fi
}

run_item() {  # run_item ITEM MODE
    case $(method_of "${I_TARGET[$1]}") in
        router) run_router ;;
        webui) run_webui "$1" ;;
        guest) run_guest "$1" "$2" ;;
        reconfigure)
            run_reconfigure "$1" "$2" || return
            if hermes_update_wanted "$1"; then update_hermes "$1"; fi ;;
        hcom) run_hcom "$1" ;;
        *) note "No upgrade method for ${I_TARGET[$1]}."; return 1 ;;
    esac
}

describe_item() {  # what run_item does, for the plan
    local i=$1 t=${I_TARGET[$1]} id=${I_CT[$1]}
    case $(method_of "$t") in
        router) echo 'tools/update-router-services.sh --host --no-push; push after the checks' ;;
        webui)
            case $(info_value "$i" action) in
                pin) echo "manage-model-servers set-webui-version $(info_value "$i" version) --apply" ;;
                apply) echo "manage-model-servers apply (pinned to $(info_value "$i" version), not yet installed)" ;;
                *) echo 'nothing to do' ;;
            esac ;;
        guest)
            if [[ $t == open-terminal ]]; then echo "push files to /root/${GUEST_DIR[$t]}; rerun install-target.sh with its port"
            else echo "push files to /root/${GUEST_DIR[$t]}; install-target.sh --upgrade"; fi ;;
        reconfigure)
            if unpinned_service "$t"; then
                echo "targets/$t/provision-lxc.sh --reconfigure (re-applies its setup; this repository does not pin the $t release, so it stays as it is)"
            else
                echo "$(grep -oE '(DSH_VERSION|HONCHO_REF|OPENCODE_VERSION)=[^ ]*' <<< "${I_INFO[$i]}" | tr '\n' ' ')targets/$t/provision-lxc.sh --reconfigure$([[ $t != hermes ]] || echo "; $(hermes_plan "$i")")"
            fi ;;
        hcom) echo "targets/hcom/provision-lxc.sh as $(info_value "$i" target) (broker CT ${HCOM_MQTT_CT:-?})" ;;
    esac
}

hermes_plan() {  # what happens to Hermes itself, for the plan
    local pin
    pin=$(info_value "$1" hermes_pin)
    if [[ -n $pin ]]; then
        echo "Hermes stays at its HERMES_COMMIT pin ${pin:0:12}$($UPDATE_HERMES && echo ' (--update-hermes does not move a pin)')"
    elif $UPDATE_HERMES; then
        echo 'then hermes update and a restart of its gateway and dashboard'
    else
        echo 'Hermes itself stays at its installed version (--update-hermes updates it)'
    fi
}

# hermes_outcome ITEM LOG FROM: the result note for Hermes after a successful
# attempt whose output starts after line FROM of LOG.
hermes_outcome() {
    local pin line
    pin=$(info_value "$1" hermes_pin)
    line=$(tail -n "+$(($3 + 1))" "$2" | sed -n 's/^OSR-HERMES: //p' | tail -n 1)
    case $line in
        moved\ *) echo "Hermes updated: ${line#moved }" ;;
        same\ *) echo "hermes update found nothing newer (${line#same })" ;;
        pin\ *) echo "Hermes stays at its HERMES_COMMIT pin ${line#pin }" ;;
        *) if [[ -n $pin ]]; then echo "Hermes stays at its HERMES_COMMIT pin ${pin:0:12}"
           else echo 'Hermes itself stays at its installed version (--update-hermes updates it)'; fi ;;
    esac
}

# --- Decisions made before anything changes ------------------------------------------

repo_default() {  # repo_default dsh|honcho|opencode
    case $1 in
        dsh) sed -n 's/^DEFAULT_DSH_VERSION=//p' "$REPO_ROOT/targets/deepseek-harness/provision-lxc.sh" | head -n 1 ;;
        opencode) sed -n 's/^DEFAULT_OPENCODE_VERSION=//p' "$REPO_ROOT/targets/opencode/provision-lxc.sh" | head -n 1 ;;
        honcho) sed -n 's/^HONCHO_REF=\${HONCHO_REF:-\([^}]*\)}$/\1/p' "$REPO_ROOT/targets/honcho/provision-lxc.sh" | head -n 1 ;;
    esac
}

# version_newer A B: is release A newer than B? (1.2.0-rc.1 < 1.2.0; v-prefix ok)
version_newer() {
    local a=${1#v} b=${2#v}
    [[ $a =~ ^[0-9] && $b =~ ^[0-9] && $a != "$b" ]] || return 1
    a=${a//-/\~}; b=${b//-/\~}
    [[ $(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1) == "$a" ]]
}

# decide_pin ITEM KEY RECORDED DEFAULT: a release the user pinned moves to the
# repository's pin when they agree; a moving channel (latest, main) and a
# release newer than the pin are kept.
decide_pin() {
    local i=$1 key=$2 recorded=$3 default=$4
    [[ -n $recorded && -n $default && $recorded != "$default" ]] || return 0
    if [[ $recorded == latest || $recorded == main ]] || $KEEP_PINS; then
        I_NOTE[i]="keeps $key=$recorded"
        return 0
    fi
    if version_newer "$recorded" "$default"; then
        I_NOTE[i]="keeps $key=$recorded (newer than the pin $default)"
        return 0
    fi
    if $DRY_RUN; then
        I_NOTE[i]="asks whether to move $key=$recorded to $default"
        return 0
    fi
    if $INTERACTIVE && ! ask_yes "$(item_label "$i") records $key=$recorded; this repository pins $default. Move it to $default?" y; then
        I_NOTE[i]="keeps $key=$recorded"
        return 0
    fi
    I_INFO[i]+=" $key=$default"
    I_NOTE[i]="$recorded -> $default"
}

decide_webui() {
    local i=$1 id=${I_CT[$1]} pin installed ct_pin
    pin=$(sed -n 's/^open-webui==//p' "$REPO_ROOT/services/open-webui/requirements.txt" | head -n 1)
    installed=$(pct exec "$id" -- /app/openwebui/venv/bin/python -c \
        'import importlib.metadata as m; print(m.version("open-webui"))' 2>/dev/null | tr -d '\r')
    ct_pin=$(pct exec "$id" -- sed -n 's/^open-webui==//p' /app/config-repo/services/open-webui/requirements.txt 2>/dev/null | head -n 1)
    if [[ -z $pin || $installed == "$pin" ]]; then
        I_RESULT[i]=current; I_NOTE[i]="Open WebUI ${installed:-?}"
    elif version_newer "$installed" "$pin"; then
        I_RESULT[i]=current; I_NOTE[i]="keeps Open WebUI $installed (newer than the pin $pin)"
    else
        if [[ $ct_pin == "$pin" ]]; then I_INFO[i]="action=apply version=$pin"; else I_INFO[i]="action=pin version=$pin"; fi
        I_NOTE[i]="${installed:-?} -> $pin"
    fi
}

# needs_webui_token ITEM: does this item's reconfigure register with Open
# WebUI, and so stop without OPENWEBUI_ADMIN_TOKEN when nobody can be asked?
# Honcho always registers its MCP server; Hermes, OpenClaw and OpenCode do
# when their API server (the Open WebUI connection) is on.
needs_webui_token() {
    local id=${I_CT[$1]}
    case ${I_TARGET[$1]} in
        honcho) return 0 ;;
        hermes) pct exec "$id" -- grep -qx 'HERMES_API_SERVER=true' /etc/hermes-target/settings 2>/dev/null ;;
        openclaw) pct exec "$id" -- grep -qx 'OPENCLAW_API=true' /etc/openclaw-target/settings 2>/dev/null ;;
        opencode) pct exec "$id" -- grep -qx 'OPENCODE_API=true' /etc/opencode-target/settings 2>/dev/null ;;
        *) return 1 ;;
    esac
}

prepare() {
    local i t id recorded
    HCOM_MQTT_CT=${MQTT_CT_ID:-$(single_tagged mqtt)}
    HCOM_MATTERMOST_CT=${MATTERMOST_CT_ID:-$(single_tagged mattermost)}
    for i in "${!I_TARGET[@]}"; do
        [[ -z ${I_RESULT[$i]} ]] || continue
        t=${I_TARGET[$i]}; id=${I_CT[$i]}
        if ! ct_running "$id"; then
            if ! $INCLUDE_STOPPED; then I_RESULT[i]=not-run; I_NOTE[i]='CT is stopped (--include-stopped upgrades it)'; fi
            continue
        fi
        case $t in
            open-webui) decide_webui "$i" ;;
            deepseek-harness)
                recorded=$(pct exec "$id" -- sed -n 's/^DSH_VERSION=//p' /etc/deepseek-harness/settings 2>/dev/null | head -n 1 | tr -d '"'\''\r')
                decide_pin "$i" DSH_VERSION "$recorded" "$(repo_default dsh)" ;;
            opencode)
                recorded=$(pct exec "$id" -- sed -n 's/^OPENCODE_VERSION=//p' /etc/opencode-target/settings 2>/dev/null | head -n 1 | tr -d '"'\''\r')
                decide_pin "$i" OPENCODE_VERSION "$recorded" "$(repo_default opencode)" ;;
            honcho)
                recorded=$(pct exec "$id" -- sed -n 's/^HONCHO_REF=//p' /etc/honcho-target/settings.env 2>/dev/null | head -n 1 | tr -d '"'\''\r')
                decide_pin "$i" HONCHO_REF "$recorded" "$(repo_default honcho)" ;;
            hermes)
                # Its reconfigure keeps the pin; --update-hermes must not move past it.
                recorded=$(hermes_recorded_pin "$id")
                [[ ! $recorded =~ ^[0-9a-f]{40}$ ]] || I_INFO[i]+=" hermes_pin=$recorded" ;;
            hcom)
                if [[ -z $HCOM_MQTT_CT ]]; then
                    I_RESULT[i]=not-run; I_NOTE[i]='set MQTT_CT_ID: not exactly one CT is tagged mqtt'
                elif [[ $(info_value "$i" mattermost) == true && -z $HCOM_MATTERMOST_CT ]]; then
                    I_RESULT[i]=not-run; I_NOTE[i]='set MATTERMOST_CT_ID: this observer posts to Mattermost and not exactly one CT is tagged mattermost'
                elif ! node_usable "$HCOM_MQTT_CT"; then
                    I_RESULT[i]=not-run; I_NOTE[i]="needs the broker CT $HCOM_MQTT_CT: $(node_problem "$HCOM_MQTT_CT")"
                elif [[ $(info_value "$i" mattermost) == true ]] && ! node_usable "$HCOM_MATTERMOST_CT"; then
                    I_RESULT[i]=not-run; I_NOTE[i]="needs the Mattermost CT $HCOM_MATTERMOST_CT: $(node_problem "$HCOM_MATTERMOST_CT")"
                fi ;;
        esac
        # Unattended, a reconfigure that registers with Open WebUI would stop
        # at its token question: say so now instead of reporting a failure.
        if [[ -z ${I_RESULT[$i]} && -z ${OPENWEBUI_ADMIN_TOKEN:-} ]] && ! $INTERACTIVE && needs_webui_token "$i"; then
            if $DRY_RUN && token_tty >/dev/null; then
                I_NOTE[i]='asks for the Open WebUI admin token when the run starts'
            else
                I_RESULT[i]=not-run
                I_NOTE[i]='set OPENWEBUI_ADMIN_TOKEN: its reconfigure registers with Open WebUI again'
            fi
        fi
    done
}

# --- The Open WebUI admin token --------------------------------------------------------

# Honcho, and Hermes and OpenClaw with an Open WebUI connection, register with
# Open WebUI again when they are reconfigured, which needs an admin token.
# It is asked once and kept in OPENWEBUI_ADMIN_TOKEN for the whole run, as an
# unexported variable: it is never written to disk or put on a command line,
# and only those provisioners get it (run_reconfigure exports it in their own
# subshell), not the other installers or pct exec.

# check_webui_token TOKEN: 0 accepted as an admin, 1 refused, 2 cannot tell
# (no router CT, Open WebUI down): the provisioners then check it themselves.
check_webui_token() {
    local code
    code=$(printf 'Authorization: Bearer %s\n' "$1" | router_probe webui-admin) || return 2
    case $code in
        200) return 0 ;;
        401|403) return 1 ;;
        *) return 2 ;;
    esac
}

# token_needed: will a selected, running item register with Open WebUI?
token_needed() {
    local i
    for i in "${!I_TARGET[@]}"; do
        case ${I_TARGET[$i]} in honcho|hermes|openclaw|opencode) ;; *) continue ;; esac
        [[ -z ${I_RESULT[$i]} ]] && ct_running "${I_CT[$i]}" && needs_webui_token "$i" && return 0
    done
    return 1
}

# token_tty: the terminal to ask on when the run is unattended (--yes, or
# stdin not a terminal); fails when there is none, as under cron or systemd.
# OSR_UPGRADE_TTY replaces /dev/tty for the tests.
token_tty() {
    local tty=${OSR_UPGRADE_TTY:-/dev/tty} fd
    { exec {fd}<"$tty"; } 2>/dev/null || return 1
    exec {fd}<&-
    printf '%s\n' "$tty"
}

# read_token FD ENTER_MEANS: ask on FD until the token is accepted, refused
# three times, or left empty. Sets OPENWEBUI_ADMIN_TOKEN when one is given.
read_token() {
    local fd=$1 enter=$2 token tries=0
    note ''
    note 'Honcho, and Hermes and OpenClaw with an Open WebUI connection, register with'
    note 'Open WebUI again when they are reconfigured, which needs an admin token.'
    while (( tries < 3 )); do
        printf 'Open WebUI admin API key or session JWT (not shown; Enter: %s): ' "$enter" >&2
        IFS= read -rs -u "$fd" token || token=''
        printf '\n' >&2
        [[ -n $token ]] || return 0
        check_webui_token "$token"
        case $? in
            0) note 'Open WebUI accepted it as an administrator.'; break ;;
            2) note 'Could not check it against Open WebUI now; each provisioner checks it.'; break ;;
        esac
        note 'Open WebUI refused it (not an admin key or JWT, or expired).'
        token=''
        tries=$((tries + 1))
    done
    [[ -n $token ]] || return 0
    OPENWEBUI_ADMIN_TOKEN=$token  # not exported: see run_reconfigure
    WEBUI_TOKEN=$token
}

# ask_token_unattended: at the start of an unattended run, before the plan.
ask_token_unattended() {
    local tty fd
    WEBUI_TOKEN=${OPENWEBUI_ADMIN_TOKEN:-}
    [[ -z $WEBUI_TOKEN ]] && ! $INTERACTIVE && ! $DRY_RUN || return 0
    token_needed || return 0
    if ! tty=$(token_tty); then
        note 'No terminal to ask for the Open WebUI admin token on: set OPENWEBUI_ADMIN_TOKEN.'
        return 0
    fi
    exec {fd}<"$tty" || return 0
    read_token "$fd" 'skip those components'
    exec {fd}<&-
    [[ -n $WEBUI_TOKEN ]] || note 'No token: those components are not upgraded in this run.'
}

# ask_token: an interactive run asks once the plan has been accepted; Enter
# leaves each provisioner to ask for itself.
ask_token() {
    WEBUI_TOKEN=${OPENWEBUI_ADMIN_TOKEN:-}
    [[ -z $WEBUI_TOKEN ]] && $INTERACTIVE || return 0
    token_needed || return 0
    read_token "$PROMPT_FD" 'each one asks'
    [[ -n $WEBUI_TOKEN ]] || note 'No token given: each of them asks for it.'
}

# --- One component -------------------------------------------------------------------

notify() {
    $NOTIFY || return 0
    [[ -n $ROUTER_CT ]] && ct_running "$ROUTER_CT" || return 0
    pct exec "$ROUTER_CT" -- "$MANAGE" test-alert "$1" >> "$RUN_DIR/notify.log" 2>&1 || true
}

# may_stop_midway TARGET: is it upgraded through a provisioner, which can fail
# after it has already changed the CT (Hermes's "Hermes is reconfigured, but
# ..." after its guest step, for example)? A target installer or the router
# updater restores what it changed when it fails.
may_stop_midway() { [[ $(method_of "$1") == reconfigure || $(method_of "$1") == hcom ]]; }

# choose_action LABEL HAS_SNAPSHOT BROKEN LOG PREFER_ROLLBACK: CHOICE becomes
# r, i, s, b or a. Rolling back is the default (and what --on-failure rollback
# does) when PREFER_ROLLBACK is yes: something broke, or a provisioner failed
# after it may have changed the CT.
choose_action() {
    local label=$1 snap=$2 broken=$3 log=$4 prefer=${5:-$3} default=s
    [[ $snap == yes && $prefer == yes ]] && default=b
    if ! $INTERACTIVE || [[ $ON_FAILURE != ask ]]; then
        case $ON_FAILURE in
            abort) CHOICE=a ;;
            skip) CHOICE=s ;;
            *) if [[ $snap == yes && $prefer == yes ]]; then CHOICE=b; else CHOICE=s; fi ;;
        esac
        case $CHOICE in
            b) note "--on-failure=$ON_FAILURE: rolling back." ;;
            a) note "--on-failure=$ON_FAILURE: aborting." ;;
            *) note "--on-failure=$ON_FAILURE: skipping." ;;
        esac
        return 0
    fi
    while true; do
        note ''
        note "What should happen with $label?"
        note '  r) retry the upgrade'
        note "  i) retry interactively (answer the installer's questions yourself)"
        note '  s) skip it: leave it as it is now and continue with the others'
        [[ $snap != yes ]] || note '  b) roll the CT back to the snapshot taken before the upgrade, then continue'
        note '  l) show the last 40 lines of its log'
        note '  a) abort: stop here and leave the rest as they are'
        ask "Choice [$default]: " "$default"
        case ${REPLY,,} in
            r|i|s|a) CHOICE=${REPLY,,}; return 0 ;;
            b) if [[ $snap == yes ]]; then CHOICE=b; return 0; fi ;;
            l) tail -n 40 "$log" >&2 ;;
        esac
    done
}

# snapshot_kept_note CT: the end of a result note when a CT is left as it is
# after a failure, with the commands for the snapshot ($SNAP) it keeps.
snapshot_kept_note() {
    if [[ -n $SNAP ]]; then
        printf '; snapshot %s kept (back: pct rollback %s %s; drop: pct delsnapshot %s %s)' "$SNAP" "$1" "$SNAP" "$1" "$SNAP"
    else
        printf '; no snapshot was taken'
    fi
}

ABORTED=false
CURRENT_ITEM=''
process_item() {
    local i=$1 t=${I_TARGET[$1]} id=${I_CT[$1]} label log pre post status broken unit mode=auto started=false attempt_start
    local prefer_rollback
    local -a inactive=()
    label=$(item_label "$i")
    SNAP=''
    CURRENT_ITEM=$i
    log=$RUN_DIR/$label.log
    pre=$RUN_DIR/$label.pre; post=$RUN_DIR/$label.post
    section "$label on node $(node_of "$id")"
    if ! ct_running "$id"; then
        note "Starting stopped CT $id (--include-stopped)."
        if ! pct start "$id" >> "$log" 2>&1; then I_RESULT[i]=failed; I_NOTE[i]='could not start the CT'; CURRENT_ITEM=''; return; fi
        started=true
        sleep "$POLL_INTERVAL"
    fi
    collect_state "$i" | csort -u > "$pre"
    for unit in ${UNITS[$t]:-}; do grep -qx "unit:$unit" "$pre" || inactive+=("$unit"); done
    (( ${#inactive[@]} == 0 )) || note "Not active before the upgrade, so not checked afterwards: ${inactive[*]}"
    if ! take_snapshot "$i" "$log"; then
        I_RESULT[i]=skipped; I_NOTE[i]='not upgraded: no snapshot'
        if $started; then pct stop "$id" >> "$log" 2>&1; fi
        CURRENT_ITEM=''
        return
    fi
    while true; do
        note "Upgrading $label (log: $log)"
        # Only this attempt's output says whether anything changed.
        attempt_start=0
        [[ ! -f $log ]] || attempt_start=$(wc -l < "$log")
        # tee ignores signals so that an interrupted installer can still
        # print its rollback instead of dying of SIGPIPE.
        run_item "$i" "$mode" 2>&1 | (trap '' INT TERM HUP; exec tee -a "$log") >&2
        status=${PIPESTATUS[0]}
        note "Checking $label ..."
        if verify_item "$i" "$pre" "$post"; then
            broken=no
            if (( status == 0 )); then
                if tail -n "+$((attempt_start + 1))" "$log" | grep -q '^OSR-HERMES: moved '; then
                    I_RESULT[i]=upgraded
                elif tail -n "+$((attempt_start + 1))" "$log" | grep -qi 'nothing to do'; then
                    I_RESULT[i]=current
                elif unpinned_service "$t"; then
                    I_RESULT[i]=reapplied; I_NOTE[i]="setup re-applied; the $t release is not pinned here"
                else
                    I_RESULT[i]=upgraded
                fi
                if [[ $t == hermes ]]; then
                    I_NOTE[i]=$(hermes_outcome "$i" "$log" "$attempt_start")
                    [[ ${I_RESULT[$i]} != upgraded ]] || tail -n "+$((attempt_start + 1))" "$log" | grep -q '^OSR-HERMES: moved ' ||
                        I_NOTE[i]="integration upgraded; ${I_NOTE[$i]}"
                fi
                note "$label: OK"
                $KEEP_SNAPSHOTS || drop_snapshot "$id" "$SNAP" "$log"
                break
            fi
        else
            broken=yes
        fi
        printf '\a' >&2
        note ''
        note "!!!! $label: UPGRADE PROBLEM !!!!"
        prefer_rollback=$broken
        if (( status != 0 )); then
            note "The upgrade command failed (exit $status); check its log for what it changed or restored."
            if may_stop_midway "$t"; then
                prefer_rollback=yes
                note "Its provisioner can stop after it has already changed the CT, so this may not be the previous version${SNAP:+; the snapshot taken before the upgrade is the way back}."
            fi
        fi
        if [[ $broken == yes ]]; then
            note "This worked before the upgrade but not now (after waiting up to ${HEALTH_TIMEOUT}s):"
            describe_missing < "$post.missing" >&2
        else
            note 'Everything that worked before still passes the checks.'
        fi
        notify "OSR upgrade (run on $LOCAL_NODE): $label on node $(node_of "$id") $([[ $broken == yes ]] && echo 'is BROKEN after its upgrade' || echo 'failed to upgrade but still passes the checks') (exit $status); waiting for a decision. Log: $log"
        choose_action "$label" "$([[ -n $SNAP ]] && echo yes || echo no)" "$broken" "$log" "$prefer_rollback"
        case $CHOICE in
            r) mode=auto; continue ;;
            i) mode=interactive; continue ;;
            s)
                if [[ $broken == yes ]]; then
                    I_RESULT[i]=broken
                    if (( status != 0 )); then
                        I_NOTE[i]="upgrade failed (exit $status); health checks failed; CT left as it is"
                    else
                        I_NOTE[i]='health checks failed after the upgrade; CT left as it is'
                    fi
                else
                    # A failed command keeps the snapshot: what it left behind
                    # is only known from its log.
                    I_RESULT[i]=skipped
                    if may_stop_midway "$t"; then
                        I_NOTE[i]="upgrade failed (exit $status) and may have changed the CT; it passes the checks"
                    else
                        I_NOTE[i]="upgrade failed (exit $status); its own rollback should have restored it (see the log); it passes the checks"
                    fi
                fi
                I_NOTE[i]+=$(snapshot_kept_note "$id")
                undo_webui_pin "$i"
                break ;;
            b)
                if rollback_snapshot "$id" "$SNAP" "$log" && verify_item "$i" "$pre" "$post"; then
                    I_RESULT[i]=rolled-back; I_NOTE[i]="restored snapshot $SNAP"
                    drop_snapshot "$id" "$SNAP" "$log"
                    note "$label is back as it was before the upgrade."
                else
                    I_RESULT[i]=broken; I_NOTE[i]="rollback to $SNAP did not restore everything; snapshot kept"
                    note 'The rollback did not bring everything back:'
                    describe_missing < "$post.missing" >&2
                fi
                break ;;
            a)
                if [[ $broken == yes ]]; then I_RESULT[i]=broken; else I_RESULT[i]=skipped; fi
                I_NOTE[i]='aborted here'
                (( status == 0 )) || I_NOTE[i]+=" after the upgrade failed (exit $status)"
                I_NOTE[i]+=$(snapshot_kept_note "$id")
                undo_webui_pin "$i"
                ABORTED=true
                break ;;
        esac
    done
    if $started; then pct stop "$id" >> "$log" 2>&1 || note "Could not stop CT $id again."; fi
    CURRENT_ITEM=''
}

# A skipped Open WebUI pin must not stay in the router's config repository,
# where the next apply would install it.
undo_webui_pin() {
    [[ ${I_TARGET[$1]} == open-webui && $(info_value "$1" action) == pin ]] || return 0
    pct exec "$ROUTER_CT" -- git -C /app/config-repo checkout -- services/open-webui/requirements.txt 2>/dev/null ||
        note 'Could not restore services/open-webui/requirements.txt in /app/config-repo; check git status there.'
}

# The router step commits without pushing; push once the router and Open WebUI
# steps are done and something changed.
push_router_config() {
    local router webui
    router=$(result_of router); webui=$(result_of open-webui)
    case $router in
        rolled-back|broken|failed) note 'The router step did not complete, so nothing is pushed to Gitea.'; return 0 ;;
    esac
    [[ $router == upgraded || $webui == upgraded ]] || return 0
    ct_running "$ROUTER_CT" || return 0
    note 'Pushing the router configuration repository to Gitea ...'
    pct exec "$ROUTER_CT" -- "$MANAGE" commit "Upgrade router components from $REPO_REV" --yes </dev/null >&2 ||
        note 'The push failed; the commit stays in /app/config-repo. Push it later with: manage-model-servers commit'
}

# --- Main ----------------------------------------------------------------------------

print_plan() {
    local i
    printf '%-18s %-6s %-12s %s\n' COMPONENT CT NODE 'WHAT HAPPENS' >&2
    for i in "${!I_TARGET[@]}"; do
        [[ ${I_RESULT[$i]} != filtered ]] || continue
        if [[ -n ${I_RESULT[$i]} ]]; then
            printf '%-18s %-6s %-12s %s\n' "${I_TARGET[$i]}" "${I_CT[$i]}" "$(node_of "${I_CT[$i]}")" "${I_RESULT[$i]}: ${I_NOTE[$i]}" >&2
        else
            printf '%-18s %-6s %-12s %s\n' "${I_TARGET[$i]}" "${I_CT[$i]}" "$(node_of "${I_CT[$i]}")" "$(describe_item "$i")${I_NOTE[$i]:+  [${I_NOTE[$i]}]}" >&2
        fi
    done
}

print_summary() {
    local i problems=0
    section "Summary (logs: $RUN_DIR)"
    {
        printf '%-18s %-6s %-12s %-12s %s\n' COMPONENT CT NODE RESULT NOTE
        for i in "${!I_TARGET[@]}"; do
            [[ ${I_RESULT[$i]} != filtered ]] || continue
            printf '%-18s %-6s %-12s %-12s %s\n' "${I_TARGET[$i]}" "${I_CT[$i]}" "$(node_of "${I_CT[$i]}")" "${I_RESULT[$i]:-not-run}" "${I_NOTE[$i]}"
        done
    } | tee "$RUN_DIR/summary.txt" >&2
    for i in "${!I_TARGET[@]}"; do
        case ${I_RESULT[$i]} in broken|failed|rolled-back|skipped) problems=1 ;; esac
    done
    return "$problems"
}

check_repo() {
    local crlf
    [[ -f $REPO_ROOT/ollama-smart-router-install.sh && -f $REPO_ROOT/tools/update-router-services.sh ]] ||
        die "Cannot locate the router repository beside this script: $REPO_ROOT"
    crlf=$(cd "$REPO_ROOT" && grep -rlI --exclude-dir=.git --exclude-dir=__pycache__ --exclude='*.md' "$(printf '\r')" \
        install services targets tools ollama-smart-router-install.sh 2>/dev/null)
    if [[ -n $crlf ]]; then
        note 'These files have Windows (CRLF) line endings, which bash and systemd cannot use:'
        head -n 20 <<< "$crlf" | sed 's/^/  /' >&2
        die 'Convert them to LF first (git add --renormalize . after a Windows checkout, or dos2unix).'
    fi
    REPO_REV=$(git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null || echo 'working tree')
}

on_interrupt() {
    trap '' INT TERM HUP
    note ''
    note 'Interrupted. Check the current component log and CT state before retrying.'
    if [[ -n $CURRENT_ITEM ]]; then
        I_RESULT[CURRENT_ITEM]=interrupted
        I_NOTE[CURRENT_ITEM]="check $RUN_DIR/$(item_label "$CURRENT_ITEM").log${SNAP:+; snapshot $SNAP may be available}"
    fi
    print_summary || true
    exit 130
}

cleanup() {
    local status=$?
    trap - EXIT
    if $PROBE_READY; then pct exec "$ROUTER_CT" -- rm -f "$PROBE_PATH" >/dev/null 2>&1 || true; fi
    # The shared SSH connections to other nodes, then the cluster lock.
    if [[ -n ${RUN_DIR:-} && -f $RUN_DIR/bin/pct ]]; then pct --osr-close >/dev/null 2>&1 || true; fi
    if $CLUSTER_LOCKED; then rm -f -- "$CLUSTER_LOCK"; fi
    # Copies of the broker's TLS key; the whole scratch directory for a dry run.
    rm -rf -- "$RUN_DIR"/mqtt-* 2>/dev/null
    if $DRY_RUN || $LIST_ONLY; then rm -rf -- "$RUN_DIR"; fi
    exit "$status"
}

main() {
    DRY_RUN=false LIST_ONLY=false ASSUME_YES=false ON_FAILURE='' KEEP_PINS=false INCLUDE_STOPPED=false UPDATE_HERMES=false
    SNAPSHOTS=true REQUIRE_SNAPSHOT=false KEEP_SNAPSHOTS=false NOTIFY=true ONLY='' SKIP='' NODES='' WEBUI_TOKEN=''
    HCOM_MQTT_CT='' HCOM_MATTERMOST_CT=''
    while (( $# )); do
        case $1 in
            --dry-run) DRY_RUN=true ;;
            --list) LIST_ONLY=true ;;
            --only) [[ -n ${2:-} ]] || die '--only needs a component.'; ONLY=$2; shift ;;
            --only=*) ONLY=${1#*=}; [[ -n $ONLY ]] || die '--only needs a component.' ;;
            --skip) SKIP=${2:-}; shift ;;
            --skip=*) SKIP=${1#*=} ;;
            --node) [[ -n ${2:-} ]] || die '--node needs a node name.'; NODES=$2; shift ;;
            --node=*) NODES=${1#*=}; [[ -n $NODES ]] || die '--node needs a node name.' ;;
            -y|--yes) ASSUME_YES=true ;;
            --on-failure) ON_FAILURE=${2:-}; shift ;;
            --on-failure=*) ON_FAILURE=${1#*=} ;;
            --keep-pins) KEEP_PINS=true ;;
            --update-hermes) UPDATE_HERMES=true ;;
            --include-stopped) INCLUDE_STOPPED=true ;;
            --no-snapshot) SNAPSHOTS=false ;;
            --require-snapshot) REQUIRE_SNAPSHOT=true ;;
            --keep-snapshots) KEEP_SNAPSHOTS=true ;;
            --no-notify) NOTIFY=false ;;
            --health-timeout) HEALTH_TIMEOUT=${2:-}; shift ;;
            --health-timeout=*) HEALTH_TIMEOUT=${1#*=} ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done
    # A token from the environment is kept for the run but no longer exported
    # to every child (see run_reconfigure).
    WEBUI_TOKEN=${OPENWEBUI_ADMIN_TOKEN:-}
    export -n OPENWEBUI_ADMIN_TOKEN 2>/dev/null || true
    [[ $HEALTH_TIMEOUT =~ ^[0-9]+$ ]] || die '--health-timeout takes a number of seconds.'
    case $ON_FAILURE in ''|ask|rollback|skip|abort) ;; *) die '--on-failure must be ask, rollback, skip or abort.' ;; esac
    if $REQUIRE_SNAPSHOT && ! $SNAPSHOTS; then die 'Use only one of --no-snapshot and --require-snapshot.'; fi

    [[ $(id -u) -eq 0 ]] || die 'Run as root on a Proxmox node.'
    local command_name i
    for command_name in pct flock python3 tee comm awk sed sort; do
        command -v "$command_name" >/dev/null 2>&1 || die "Missing command: $command_name (run this on a Proxmox node)."
    done
    [[ -d $PVE_NODES_DIR ]] || die "$PVE_NODES_DIR is missing: run this on a Proxmox node."
    [[ -f $REPO_ROOT/tools/pct-cluster.sh ]] || die "Missing $REPO_ROOT/tools/pct-cluster.sh."
    check_repo
    setup_prompts
    if [[ -z $ON_FAILURE ]]; then
        if $INTERACTIVE; then ON_FAILURE=ask; else ON_FAILURE=rollback; fi
    fi

    if ! $DRY_RUN && ! $LIST_ONLY; then
        exec {LOCK_FD}>"$LOCK_FILE" || die "Cannot open $LOCK_FILE"
        flock -n "$LOCK_FD" || die "Another upgrade-all.sh is running (lock: $LOCK_FILE)."
    fi
    RUN_STAMP=$(date +%Y%m%d-%H%M%S)
    if $DRY_RUN || $LIST_ONLY; then
        RUN_DIR=$(mktemp -d) || die 'Cannot create a scratch directory.'
    else
        RUN_DIR=$LOG_ROOT/$RUN_STAMP
        install -d -m 0700 "$LOG_ROOT" "$RUN_DIR" || die "Cannot create $RUN_DIR"
    fi
    trap cleanup EXIT
    trap on_interrupt INT TERM HUP
    setup_cluster
    validate_node_filter
    if ! $DRY_RUN && ! $LIST_ONLY; then take_cluster_lock; fi

    note "Repository: $REPO_ROOT ($REPO_REV); running on node $LOCAL_NODE"
    $LIST_ONLY || offer_cluster_ssh
    discover
    apply_filters
    if [[ -n $ONLY || -n $NODES ]]; then
        local matches=false
        for i in "${!I_TARGET[@]}"; do
            [[ ${I_RESULT[$i]} == filtered ]] || { matches=true; break; }
        done
        $matches || die "No components match the requested --only, --skip and --node filters."
    fi
    if $LIST_ONLY; then
        for i in "${!I_TARGET[@]}"; do
            [[ ${I_RESULT[$i]} == filtered ]] ||
                printf '%s\t%s\t%s\t%s\n' "${I_TARGET[$i]}" "${I_CT[$i]}" "$(node_of "${I_CT[$i]}")" "${I_INFO[$i]}"
        done
        exit 0
    fi
    (( ${#I_TARGET[@]} )) || die 'Nothing to upgrade: no router or target CTs found in the cluster.'
    check_nodes
    ask_token_unattended
    prepare
    section 'Plan'
    print_plan
    if $DRY_RUN; then
        if selected router && [[ -z $(result_of router) ]]; then
            section 'Router components (update-router-services.sh --dry-run)'
            CT_ID=$ROUTER_CT bash "$REPO_ROOT/tools/update-router-services.sh" --host --dry-run </dev/null >&2 || true
        fi
        exit 0
    fi
    if $INTERACTIVE && ! ask_yes 'Start the upgrade?' y; then note 'Nothing was changed.'; exit 0; fi
    ask_token

    for i in "${!I_TARGET[@]}"; do
        if $ABORTED && [[ -z ${I_RESULT[$i]} ]]; then I_RESULT[i]=not-run; I_NOTE[i]='aborted before this one'; fi
        if [[ -z ${I_RESULT[$i]} && ${I_TARGET[$i]} == open-webui ]]; then
            case $(result_of router) in
                rolled-back|broken|failed|not-run) I_RESULT[i]=not-run; I_NOTE[i]='the router step did not complete' ;;
            esac
        fi
        [[ -n ${I_RESULT[$i]} ]] || process_item "$i"
        [[ ${I_TARGET[$i]} != open-webui ]] || push_router_config
    done
    if print_summary; then exit 0; fi
    notify "OSR upgrade (run on $LOCAL_NODE) finished with problems: $(awk 'NR > 1 && $4 ~ /^(broken|failed|rolled-back|skipped)$/ { printf "%s@%s (%s) %s; ", $1, $2, $3, $4 }' "$RUN_DIR/summary.txt")see $RUN_DIR on $LOCAL_NODE"
    exit 1
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
