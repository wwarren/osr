#!/usr/bin/env bash
# Check, and repair, root SSH between the nodes of a Proxmox VE 9 cluster, so
# tools/upgrade-all.sh can be run from any node and reach CTs on every other.
#
# Proxmox sets this up when a node joins: root's /root/.ssh/authorized_keys is
# a link to the cluster-wide /etc/pve/priv/authorized_keys, which holds every
# node's root key, and each node pins its own host key in
# /etc/pve/nodes/<node>/ssh_known_hosts, which the others check it against.
# "pvecm updatecerts" restores all of that for the node it runs on (pve-cluster
# runs it at every start). This script checks it the way Proxmox and
# tools/pct-cluster.sh connect, from this node to every node and from every
# node to every other, and repairs what it can:
#
#   * this node: pvecm updatecerts, when its key pair, its key in the cluster
#     file, its authorized_keys link or its published host key is missing or
#     wrong;
#   * a node this node reaches: pvecm updatecerts there, over that SSH, when it
#     cannot reach another node or another node cannot reach it;
#   * a node this node cannot reach: on a terminal, it offers to sign in there
#     once as root with that node's password (typed at ssh's own prompt, never
#     seen by this script) to run pvecm updatecerts. A host key that cannot be
#     verified against the cluster is shown first, and is trusted for that one
#     connection only if you confirm it matches the node's own.
#
# A repair runs with --yes, or on a terminal when you agree; otherwise it is
# only reported. pvecm updatecerts turns a regular /root/.ssh/authorized_keys
# into the link to the cluster file. It temporarily saves the old file as
# authorized_keys.org, merges its keys into the shared cluster file, then
# removes the backup. Keys only in the old file would therefore work on every
# node. They are listed first: on a terminal you may allow that cluster-wide
# access or leave the node alone; unattended, that node is left alone. Leaving
# it alone only postpones the import: pve-cluster runs pvecm updatecerts itself
# whenever it starts (at boot, or a restart). To keep such keys on that node
# only, remove them from its authorized_keys and delete its authorized_keys.org.
#
# Usage: bash tools/setup-cluster-ssh.sh [--check] [--yes] [--node LIST]
#   --check, --dry-run  report only; change nothing
#   --yes               no questions: repairs on this node and over existing
#                       SSH (never a password sign-in or an unapproved
#                       cluster-wide key import)
#   --node LIST         only these nodes (comma-separated; this node is always
#                       checked)
# Exit status: 0 every online node reaches every other (or a standalone host),
# 1 something is still missing (what to do is printed), 2 usage.
set -uo pipefail
umask 077

SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The same node lookup and SSH options as the cluster pct wrapper.
# shellcheck source=tools/pct-cluster.sh
source "$SCRIPT_DIR/pct-cluster.sh"

ROOT_SSH_DIR=${OSR_ROOT_SSH_DIR:-/root/.ssh}
PVE_PRIV_DIR=${OSR_PVE_PRIV_DIR:-/etc/pve/priv}
HOST_RSA_KEY=${OSR_SSH_HOST_RSA_KEY:-/etc/ssh/ssh_host_rsa_key.pub}
PVECM=${OSR_PVECM:-pvecm}
# The same programs and cluster filesystem, as the other nodes see them.
REMOTE_PVECM=${OSR_REMOTE_PVECM:-/usr/bin/pvecm}
REMOTE_SSH=${OSR_REMOTE_SSH:-/usr/bin/ssh}
REMOTE_NODES_DIR=${OSR_REMOTE_PVE_NODES_DIR:-/etc/pve/nodes}

note() { printf '%s\n' "$*" >&2; }
section() { printf '\n== %s ==\n' "$*" >&2; }

usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

INTERACTIVE=false
PROMPT_FD=0
MODE=fix
ask_yes() {  # ask_yes TEXT y|n
    local hint='[y/N]' reply
    [[ $2 == y ]] && hint='[Y/n]'
    while true; do
        printf '%s %s ' "$1" "$hint" >&2
        IFS= read -r -u "$PROMPT_FD" reply || { printf '\n' >&2; reply=''; }
        reply=${reply:-$2}
        case ${reply,,} in y|yes) return 0 ;; n|no) return 1 ;; esac
    done
}

# consent QUESTION: may a repair run? --yes says yes, a terminal is asked,
# anything else (no terminal, --check) says no.
consent() {
    case $MODE in
        yes) return 0 ;;
        fix) $INTERACTIVE && ask_yes "$1" y ;;
        *) return 1 ;;
    esac
}

# --- The nodes -----------------------------------------------------------------------

# members: "NAME ONLINE ADDRESS" for every node of the cluster but this one,
# from corosync's member list (a removed node's leftover directory in
# /etc/pve/nodes is not a member). Nothing on a standalone host.
members() {
    [[ -r $MEMBERS ]] || return 0
    python3 - "$MEMBERS" "$LOCAL" <<'PY' 2>/dev/null
import json, sys
try:
    nodes = json.load(open(sys.argv[1])).get("nodelist") or {}
except (OSError, ValueError):
    sys.exit(0)
for name in sorted(nodes):
    if name != sys.argv[2]:
        node = nodes[name] or {}
        print(name, node.get("online", 1), node.get("ip") or name)
PY
}

# --- This node -----------------------------------------------------------------------

key_of() { awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh|ecdsa|sk)-/) { print $i, $(i + 1); exit } }' "$1" 2>/dev/null; }
has_key() {  # has_key FILE "TYPE BLOB": is the key in that authorized_keys/known_hosts file?
    [[ -n $2 && -r $1 ]] && awk -v k="$2" '{ for (i = 1; i < NF; i++) if ($i " " $(i + 1) == k) f = 1 } END { exit !f }' "$1"
}

# local_problems: what keeps this node's root SSH from working cluster-wide.
local_problems() {
    local pub key ours='' pinned=$NODES_DIR/$LOCAL/ssh_known_hosts
    for pub in "$ROOT_SSH_DIR"/id_rsa.pub "$ROOT_SSH_DIR"/id_ecdsa.pub "$ROOT_SSH_DIR"/id_ed25519.pub; do
        [[ -f $pub && -f ${pub%.pub} ]] || continue
        key=$(key_of "$pub")
        if has_key "$PVE_PRIV_DIR/authorized_keys" "$key"; then ours=authorized; break; fi
        ours=unlisted
    done
    case $ours in
        '') echo "root has no SSH key pair in $ROOT_SSH_DIR, so it cannot sign in to the other nodes" ;;
        unlisted) echo "root's key is not in $PVE_PRIV_DIR/authorized_keys, so the other nodes refuse it" ;;
    esac
    [[ -L $ROOT_SSH_DIR/authorized_keys && $ROOT_SSH_DIR/authorized_keys -ef $PVE_PRIV_DIR/authorized_keys ]] ||
        echo "$ROOT_SSH_DIR/authorized_keys is not a link to $PVE_PRIV_DIR/authorized_keys, so this node does not accept the other nodes' keys"
    if [[ ! -f $pinned ]]; then
        echo "this node has not published its host key ($pinned), so the other nodes cannot verify it"
    elif ! has_key "$pinned" "$(key_of "$HOST_RSA_KEY")"; then
        echo "the host key this node published ($pinned) is not its current one, so the other nodes reject it"
    fi
}

# stray_keys FILE: key entries in FILE absent verbatim from the cluster file.
# Compare the full entry: the same public key with different SSH options may
# grant different access when updatecerts merges it.
stray_keys() {
    local line key
    while IFS= read -r line || [[ -n $line ]]; do
        [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
        key=$(key_of <(printf '%s\n' "$line"))
        [[ -n $key ]] || continue
        if [[ ! -r $PVE_PRIV_DIR/authorized_keys ]] ||
           ! grep -Fxq -- "$line" "$PVE_PRIV_DIR/authorized_keys"; then
            printf '%s\n' "$line"
        fi
    done < "$1"
}

# key_labels LINES: one short label per key line (its comment, else its type).
key_labels() {
    awk '{ for (i = 1; i < NF; i++) if ($i ~ /^(ssh|ecdsa|sk)-/) {
               c = ""; for (j = i + 2; j <= NF; j++) c = c (c == "" ? "" : " ") $j
               print "    - " (c != "" ? c : $i " key"); next } }' <<< "$1" >&2
}

# guard_stray_keys NODE LINES: before pvecm updatecerts on NODE. LINES come
# from a regular authorized_keys or a pre-existing authorized_keys.org. 0:
# allow Proxmox to import them cluster-wide; 1: leave NODE alone.
guard_stray_keys() {
    local node=$1 lines=$2 file=$PVE_PRIV_DIR/authorized_keys
    [[ -n $lines ]] || return 0
    note "  $node has $(grep -c '' <<< "$lines") root SSH key entry/entries in authorized_keys or authorized_keys.org absent from $file:"
    key_labels "$lines"
    note "  pvecm updatecerts may import these entries into $file, changing root SSH access on every node."
    if [[ $MODE == check ]]; then
        note '  A repair would first ask before importing them.'
        import_pending "$node"
        return 1
    fi
    if ! $INTERACTIVE; then
        note '  Not repaired without a terminal.'
        import_pending "$node"
        return 1
    fi
    ask_yes "  Allow pvecm updatecerts to merge these entries cluster-wide?" n ||
        { note "  $node was left as it is."; import_pending "$node"; return 1; }
}

# import_pending NODE: what leaving NODE alone does and does not prevent.
import_pending() {
    note "  Proxmox still imports these entries the next time pve-cluster starts on $1 (at boot, or a"
    note "  restart): it runs pvecm updatecerts itself then. To keep them off the other nodes, remove them"
    note "  from $1's /root/.ssh/authorized_keys and delete its /root/.ssh/authorized_keys.org; to share"
    note '  them, run this on a terminal and allow the import.'
}

# --- Connections ---------------------------------------------------------------------

# node_run NODE CMD: run the shell command CMD as root on NODE, through the
# signed-in session of repair_with_password when one is open, otherwise with
# Proxmox's own SSH options.
SESSION_SOCKET='' SESSION_ADDR=''
node_run() {
    if [[ -n $SESSION_SOCKET ]]; then
        ssh -o "ControlPath=$SESSION_SOCKET" -o BatchMode=yes -T -n "root@$SESSION_ADDR" -- "$2"
    else
        pve_ssh_opts "$1"
        ssh "${PVE_SSH_OPTS[@]}" -T -n "root@$(node_addr "$1")" -- "$2"
    fi
}

# remote_strays NODE: keys from NODE's regular authorized_keys and its
# authorized_keys.org backup, either of which updatecerts can merge. Fails
# when either file cannot be read.
remote_strays() {
    local copy status
    copy=$(mktemp) || return 1
    # shellcheck disable=SC2016  # expanded on NODE
    node_run "$1" 'f=${HOME:-/root}/.ssh/authorized_keys; if [ -f "$f" ] && [ ! -L "$f" ]; then cat -- "$f" || exit 1; printf "\n"; fi; if [ -f "$f.org" ]; then cat -- "$f.org" || exit 1; fi' > "$copy"
    status=$?
    (( status != 0 )) || stray_keys "$copy"
    rm -f -- "$copy"
    return "$status"
}

# updatecerts_on NODE: pvecm updatecerts on NODE, once its stray keys are dealt with.
updatecerts_on() {
    local strays status
    if ! strays=$(remote_strays "$1"); then
        note "  Could not read $1's /root/.ssh/authorized_keys; $1 was left as it is."
        return 1
    fi
    guard_stray_keys "$1" "$strays" || return 1
    note "  pvecm updatecerts on $1 ..."
    node_run "$1" "$(quote "$REMOTE_PVECM" updatecerts)" >&2
    status=$?
    (( status == 0 )) || note "  pvecm updatecerts on $1 failed (exit $status)."
    return "$status"
}

# probe NODE ADDRESS: try SSH from here as Proxmox does; PROBE_ERR holds what
# ssh said when it failed.
probe() {
    local status
    pve_ssh_opts "$1"
    PROBE_ERR=$(ssh "${PVE_SSH_OPTS[@]}" -T -n "root@$2" true 2>&1 >/dev/null)
    status=$?
    PROBE_ERR=$(tr -d '\r' <<< "$PROBE_ERR" | grep -v '^Warning: Permanently added' | tail -n 3)
    return "$status"
}

# mesh_probe FROM TO ADDRESS: the same, from node FROM (reached from here).
mesh_probe() {
    local inner status
    local -a opts=(-e none -o BatchMode=yes -o "HostKeyAlias=$2")
    if [[ -f $NODES_DIR/$2/ssh_known_hosts ]]; then
        opts+=(-o "UserKnownHostsFile=$REMOTE_NODES_DIR/$2/ssh_known_hosts" -o GlobalKnownHostsFile=none)
    fi
    opts+=(-o "ConnectTimeout=${OSR_SSH_CONNECT_TIMEOUT:-10}" -T -n "root@$3" true)
    inner="$(quote "$REMOTE_SSH" "${opts[@]}") 2>&1 >/dev/null"
    pve_ssh_opts "$1"
    PROBE_ERR=$(ssh "${PVE_SSH_OPTS[@]}" -T -n "root@$(node_addr "$1")" "$inner" 2>&1)
    status=$?
    PROBE_ERR=$(tr -d '\r' <<< "$PROBE_ERR" | grep -v '^Warning: Permanently added' | tail -n 3)
    return "$status"
}

# diagnose NODE ADDRESS ERROR: the kind of failure (hostkey, unpublished,
# denied, network or other) and what to do, as "KIND|ADVICE".
diagnose() {
    local node=$1 addr=$2 err=$3
    case $err in
        *'Permission denied'*)
            echo "denied|$node refuses the key: on $node run 'pvecm updatecerts' (it links /root/.ssh/authorized_keys to the cluster's keys); if that is in place, check that its sshd allows root to sign in with a key (PermitRootLogin)" ;;
        *'Host key verification failed'*|*'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'host key for'*'has changed'*)
            if [[ -f $NODES_DIR/$node/ssh_known_hosts ]]; then
                echo "hostkey|$node's host key is not the one it pinned (reinstalled, or its key changed): on $node run 'pvecm updatecerts'"
            else
                echo "unpublished|$node has not published its host key ($NODES_DIR/$node/ssh_known_hosts): on $node run 'pvecm updatecerts'"
            fi ;;
        *'Connection refused'*|*'timed out'*|*'No route to host'*|*'Network is unreachable'*|*'Could not resolve'*|*'Connection closed'*|*'Connection reset'*)
            echo "network|cannot connect to sshd on $node at $addr ($(tail -n 1 <<< "$err" | sed 's/^ssh: //')): check that ssh runs there and that the firewall lets the cluster's nodes reach TCP port 22" ;;
        *) echo "other|$(tail -n 1 <<< "$err")" ;;
    esac
}

# repair_remote NODE: pvecm updatecerts on NODE over the SSH that works, with
# the same consent as on this node, and once per run however many of its
# connections failed (a second call returns the first outcome).
declare -A REPAIRED=()
repair_remote() {
    local status=1
    [[ -z ${REPAIRED[$1]:-} ]] || return "${REPAIRED[$1]}"
    if consent "  Run pvecm updatecerts on $1, over SSH, to restore its side?"; then
        updatecerts_on "$1"
        status=$?
    else
        note "  $1 was not changed (run with --yes, or on a terminal, to repair it)."
    fi
    REPAIRED[$1]=$status
    return "$status"
}

# repair_with_password NODE ADDRESS KIND: sign in to NODE once with its root
# password (at ssh's own prompt) to run pvecm updatecerts there. A host key the
# cluster cannot vouch for is shown and must be confirmed first.
repair_with_password() {
    local node=$1 addr=$2 kind=$3 scanned fp known='' status session
    local -a opts
    $INTERACTIVE || return 1
    ask_yes "  Sign in to $node as root with its password once, to run 'pvecm updatecerts' there?" y || return 1
    if [[ $kind == hostkey || $kind == unpublished ]]; then
        scanned=$(ssh-keyscan -T 10 -t rsa "$addr" 2>/dev/null | grep -v '^#' | head -n 1)
        if [[ -z $scanned ]]; then note "  $node did not show a host key at $addr."; return 1; fi
        fp=$(ssh-keygen -lf - <<< "$scanned" 2>/dev/null | awk '{ print $2 }')
        note "  $node ($addr) presents RSA host key $fp."
        note "  Compare it on $node itself (its Shell in the web UI): ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub"
        ask_yes "  Is it the same key?" n || { note "  Not trusted; $node was left as it is."; return 1; }
        known=$(mktemp) || return 1
        printf '%s %s\n' "$node" "$(cut -d' ' -f2- <<< "$scanned")" > "$known"
        opts=(-e none -o "HostKeyAlias=$node" -o "UserKnownHostsFile=$known" -o GlobalKnownHostsFile=none
              -o StrictHostKeyChecking=yes)
    else
        pve_ssh_opts "$node"
        opts=("${PVE_SSH_OPTS[@]/BatchMode=yes/BatchMode=no}")
    fi
    opts+=(-o 'PreferredAuthentications=keyboard-interactive,password' -o NumberOfPasswordPrompts=3)
    # One sign-in (the password goes to ssh's own prompt on the terminal) opens
    # a private session that the stray-key check and the repair both use. It
    # is detached from our output and closed at the end.
    session=$(mktemp -d) || return 1
    if ! ssh "${opts[@]}" -o ControlMaster=yes -o "ControlPath=$session/socket" -o ControlPersist=120 \
            -fN "root@$addr" </dev/null >/dev/null 2>"$session/error"; then
        sed 's/^/  /' "$session/error" >&2
        note "  The sign-in to $node failed; it was left as it is."
        rm -rf -- "$session"; [[ -z ${known:-} ]] || rm -f -- "$known"
        return 1
    fi
    SESSION_SOCKET=$session/socket SESSION_ADDR=$addr
    updatecerts_on "$node"
    status=$?
    ssh -o "ControlPath=$session/socket" -O exit "root@$addr" >/dev/null 2>&1 || true
    SESSION_SOCKET='' SESSION_ADDR=''
    rm -rf -- "$session"; [[ -z ${known:-} ]] || rm -f -- "$known"
    return "$status"
}

# --- Main ----------------------------------------------------------------------------

main() {
    local only='' name online addr kind advice i j problem requested total=0 strays keys_readable=true
    local -a names=() addrs=() reach=() offline=() problems=() pending
    local -A addr_of=() known=()
    REPAIRED=()
    while (( $# )); do
        case $1 in
            --check|--dry-run) MODE=check ;;
            --yes|-y) MODE=yes ;;
            --node) [[ -n ${2:-} ]] || { note '--node needs a node name.'; return 2; }
                    only=$2; shift ;;
            --node=*) only=${1#*=}; [[ -n $only ]] || { note '--node needs a node name.'; return 2; } ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; return 2 ;;
        esac
        shift
    done
    if [[ -n ${OSR_SETUP_SSH_ANSWERS:-} ]]; then
        exec {PROMPT_FD}<"$OSR_SETUP_SSH_ANSWERS" || return 2
        [[ $MODE != fix ]] || INTERACTIVE=true
    elif [[ $MODE == fix && -t 0 ]]; then
        INTERACTIVE=true
    fi
    [[ $(id -u) == 0 ]] || { note 'Run as root on a Proxmox VE node.'; return 2; }
    LOCAL=$(local_node)
    [[ -d $NODES_DIR/$LOCAL ]] || { note "This node ($LOCAL) is not in $NODES_DIR: run this on a Proxmox VE node."; return 2; }

    while read -r name online addr; do
        known[$name]=1; total=$((total + 1))
        if [[ -n $only && ",${only// /}," != *",$name,"* ]]; then continue; fi
        if [[ $online == 0 ]]; then offline+=("$name"); continue; fi
        names+=("$name"); addrs+=("$addr"); addr_of[$name]=$addr
    done < <(members)
    if [[ -n $only ]]; then
        for requested in ${only//,/ }; do
            if [[ $requested == "$LOCAL" ]]; then
                note "$LOCAL is this node; it is always checked."
            elif [[ -z ${known[$requested]:-} ]]; then
                note "No cluster node named $requested."; return 2
            fi
        done
    fi
    if (( total == 0 )); then
        note "$LOCAL is a standalone host (no other cluster nodes): no SSH between nodes to set up."
        return 0
    fi

    section "This node ($LOCAL)"
    mapfile -t pending < <(local_problems)
    if (( ${#pending[@]} == 0 )); then
        note 'Its root key, its authorized_keys link and its published host key are in place.'
    else
        printf '  - %s\n' "${pending[@]}" >&2
        if ! strays=$(
            if [[ -f $ROOT_SSH_DIR/authorized_keys && ! -L $ROOT_SSH_DIR/authorized_keys ]]; then
                cat -- "$ROOT_SSH_DIR/authorized_keys" || exit 1
                printf '\n'
            fi
            if [[ -f $ROOT_SSH_DIR/authorized_keys.org ]]; then
                cat -- "$ROOT_SSH_DIR/authorized_keys.org" || exit 1
            fi
        ); then
            keys_readable=false
        else
            strays=$(stray_keys <(printf '%s\n' "$strays"))
        fi
        if ! $keys_readable; then
            note '  Could not read the local authorized_keys files; this node was left as it is.'
        elif [[ $MODE == check ]]; then
            note "  Would run: pvecm updatecerts"
            guard_stray_keys "$LOCAL" "$strays"
        elif ! consent '  Run pvecm updatecerts on this node to restore them?'; then
            note '  Not changed (run with --yes, or on a terminal, to repair).'
        elif guard_stray_keys "$LOCAL" "$strays"; then
            "$PVECM" updatecerts >&2 || note "  pvecm updatecerts failed (exit $?)."
            mapfile -t pending < <(local_problems)
            if (( ${#pending[@]} )); then
                printf '  still: %s\n' "${pending[@]}" >&2
            else
                note '  Restored.'
            fi
        fi
        for problem in "${pending[@]}"; do problems+=("$LOCAL: $problem; run 'pvecm updatecerts' on $LOCAL"); done
    fi

    section "From $LOCAL to every other node"
    for i in "${!names[@]}"; do
        name=${names[i]}; addr=${addrs[i]}
        if probe "$name" "$addr"; then
            if [[ ! -f $NODES_DIR/$name/ssh_known_hosts ]]; then
                note "  $name ($addr): SSH works, but its pinned host key is not published."
                if [[ $MODE == check ]]; then
                    note "    Would run: pvecm updatecerts on $name"
                    problems+=("$name has not published $NODES_DIR/$name/ssh_known_hosts; run 'pvecm updatecerts' on $name")
                elif repair_remote "$name" && [[ -f $NODES_DIR/$name/ssh_known_hosts ]] && probe "$name" "$addr"; then
                    note "  $name has published its pinned host key."
                else
                    problems+=("$name has not published $NODES_DIR/$name/ssh_known_hosts; run 'pvecm updatecerts' on $name")
                fi
            fi
            if [[ -f $NODES_DIR/$name/ssh_known_hosts ]]; then
                note "  $name ($addr): ok"
            else
                note "  $name ($addr): SSH reachable, host key pin still missing"
            fi
            reach+=("$name"); continue
        fi
        IFS='|' read -r kind advice <<< "$(diagnose "$name" "$addr" "$PROBE_ERR")"
        note "  $name ($addr): FAILED: ${PROBE_ERR##*$'\n'}"
        note "    $advice"
        if [[ $MODE == fix && $kind != network ]] && repair_with_password "$name" "$addr" "$kind" && probe "$name" "$addr"; then
            note "  $name ($addr): ok now"; reach+=("$name"); continue
        fi
        problems+=("$LOCAL -> $name: $advice")
    done

    # Every node an upgrade may start from must reach every other, so the
    # reachable nodes are checked to each other and back to this node. (One
    # this node cannot reach is already reported above, with its remedy.)
    if (( ${#reach[@]} )); then
        section 'Between the nodes'
        local -a everyone=("$LOCAL" "${reach[@]}")
        addr_of[$LOCAL]=$(node_addr "$LOCAL")
        for i in "${reach[@]}"; do
            for j in "${everyone[@]}"; do
                [[ $i != "$j" ]] || continue
                if mesh_probe "$i" "$j" "${addr_of[$j]}"; then
                    note "  $i -> $j: ok"; continue
                fi
                IFS='|' read -r kind advice <<< "$(diagnose "$j" "${addr_of[$j]}" "$PROBE_ERR")"
                note "  $i -> $j: FAILED: ${PROBE_ERR##*$'\n'}"
                if [[ $MODE != check && $kind != network ]]; then
                    # j accepts this node, so a refusal means i's key is
                    # missing from the cluster file: i restores it. A host key
                    # problem is j's to republish (this node's own was dealt
                    # with above).
                    if [[ $kind == denied ]]; then repair_remote "$i"
                    elif [[ $j != "$LOCAL" ]]; then repair_remote "$j"; fi
                    if mesh_probe "$i" "$j" "${addr_of[$j]}"; then note "  $i -> $j: ok now"; continue; fi
                elif [[ $MODE == check && $kind != network ]]; then
                    if [[ $kind == denied ]]; then note "    Would run: pvecm updatecerts on $i"
                    else note "    Would run: pvecm updatecerts on $j"; fi
                fi
                case $kind in
                    denied) advice="$j refuses $i's key: run 'pvecm updatecerts' on $i" ;;
                    network) advice=${advice/cannot connect to sshd/$i cannot connect to sshd} ;;
                esac
                note "    $advice"
                problems+=("$i -> $j: $advice")
            done
        done
    fi

    section 'Result'
    for name in "${offline[@]}"; do
        note "  $name is offline in the cluster and was not checked; run this again when it is back."
    done
    if (( ${#problems[@]} == 0 )); then
        if [[ -n $only ]]; then
            note '  No SSH problems found among the checked nodes; unselected nodes were not checked.'
        else
            note "  Root SSH works between every online node: tools/upgrade-all.sh can run from any of them."
        fi
        return 0
    fi
    note '  Still to fix:'
    printf '  - %s\n' "${problems[@]}" >&2
    note "  Then check again with: bash $SCRIPT_DIR/setup-cluster-ssh.sh"
    return 1
}

main "$@"
