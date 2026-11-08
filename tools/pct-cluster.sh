#!/usr/bin/env bash
# pct for a Proxmox VE cluster. Proxmox's own pct only acts on CTs of the node
# it runs on; this wrapper takes the same arguments and runs the real pct on
# whichever cluster node holds the CT: here for a local CT, otherwise as root
# over SSH, exactly the way Proxmox VE 9 reaches its other nodes (BatchMode,
# the node name as HostKeyAlias, its address from /etc/pve/.members, and only
# the host key the node pinned in /etc/pve/nodes/<node>/ssh_known_hosts).
# Files given to push and pull are streamed through that connection, so they
# may be local paths. tools/setup-cluster-ssh.sh checks and repairs that SSH
# and sources this file for the same options.
#
# tools/upgrade-all.sh puts it first on PATH, as "pct", for itself and every
# provisioner it runs, so they work on CTs anywhere in the cluster unchanged.
# It can also be run directly: bash tools/pct-cluster.sh exec 205 -- uptime
#
#   pct list                         every node's CTs (unreachable nodes skipped)
#   pct --osr-node ID                the node that holds CT ID
#   pct --osr-check-node NODE        exit 0 when NODE answers over SSH
#   pct --osr-node-state NODE        local, ok, offline, unreachable or unknown
#   pct --osr-close                  end the shared SSH connections
#
# A remote "exec" gets no terminal and reads nothing from one (its stdin is
# /dev/null when ours is a terminal), so it cannot swallow what is typed for a
# later question; OSR_PCT_TTY=1 gives it one, for an installer that asks
# questions itself. "enter" always gets one.
#
# Environment: OSR_REAL_PCT (this node's pct; /usr/sbin/pct), OSR_REMOTE_PCT
# (the other nodes' pct; /usr/sbin/pct), OSR_LOCAL_NODE (this node's name;
# from /etc/pve/lxc), OSR_PVE_NODES_DIR (/etc/pve/nodes), OSR_PVE_MEMBERS
# (/etc/pve/.members), OSR_SSH_CONTROL_DIR (a private directory for shared SSH
# connections; none when unset), OSR_SSH_CONNECT_TIMEOUT (10).
set -uo pipefail

NODES_DIR=${OSR_PVE_NODES_DIR:-/etc/pve/nodes}
MEMBERS=${OSR_PVE_MEMBERS:-/etc/pve/.members}
REMOTE_PCT=${OSR_REMOTE_PCT:-/usr/sbin/pct}
CONTROL_DIR=${OSR_SSH_CONTROL_DIR:-}

die() { printf 'pct-cluster: %s\n' "$*" >&2; exit 2; }

# The real pct on this node, never this wrapper (it is installed as "pct";
# _OSR_PCT_CLUSTER, set before the real pct runs, catches a loop through a
# stub as well).
real_pct() {
    local real=${OSR_REAL_PCT:-/usr/sbin/pct} self
    self=$(readlink -f -- "${BASH_SOURCE[0]}")
    [[ -x $real && $(readlink -f -- "$real") != "$self" ]] || die "no real pct at $real (set OSR_REAL_PCT)"
    printf '%s\n' "$real"
}
if [[ ${_OSR_PCT_CLUSTER:-} == running-real-pct ]]; then
    die "OSR_REAL_PCT (${OSR_REAL_PCT:-/usr/sbin/pct}) leads back to this wrapper; set it to Proxmox's pct"
fi

# This node's name: /etc/pve/lxc links to /etc/pve/nodes/<this node>/lxc.
local_node() {
    local dir
    if [[ -n ${OSR_LOCAL_NODE:-} ]]; then printf '%s\n' "$OSR_LOCAL_NODE"; return; fi
    dir=$(readlink -f /etc/pve/lxc 2>/dev/null) && [[ $dir == */lxc ]] &&
        { basename -- "$(dirname -- "$dir")"; return; }
    hostname -s
}

node_of() {  # node_of ID: the node whose configuration holds CT ID, or nothing
    local conf node
    for conf in "$NODES_DIR"/*/lxc/"$1".conf; do
        [[ -f $conf ]] || continue
        node=${conf%/lxc/*}; node=${node##*/}
        printf '%s\n' "$node"
        return 0
    done
}

# node_member NODE ip|online: from the cluster's member list (corosync's view).
node_member() {
    [[ -r $MEMBERS ]] || return 0
    python3 - "$MEMBERS" "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    node = (json.load(open(sys.argv[1])).get("nodelist") or {}).get(sys.argv[2]) or {}
except (OSError, ValueError):
    sys.exit(0)
value = node.get(sys.argv[3])
if value is not None:
    print(value)
PY
}

quote() { printf '%q ' "$@"; }

node_addr() {  # node_addr NODE: its cluster address, or its name when unlisted
    local addr
    addr=$(node_member "$1" ip)
    printf '%s\n' "${addr:-$1}"
}

# pve_ssh_opts NODE: PVE_SSH_OPTS becomes the options Proxmox VE itself uses
# to reach NODE (PVE::SSHInfo): no escape character, no prompts, the node name
# as HostKeyAlias and, once the node has published it, only its pinned host
# key, so a stale entry in any other known_hosts file cannot interfere.
pve_ssh_opts() {
    local pinned=$NODES_DIR/$1/ssh_known_hosts
    PVE_SSH_OPTS=(-e none -o BatchMode=yes -o "HostKeyAlias=$1")
    if [[ -f $pinned ]]; then
        PVE_SSH_OPTS+=(-o "UserKnownHostsFile=$pinned" -o GlobalKnownHostsFile=none)
    fi
    PVE_SSH_OPTS+=(-o "ConnectTimeout=${OSR_SSH_CONNECT_TIMEOUT:-10}" -o ServerAliveInterval=30)
}

# on_node NODE TTY CMD: run the shell command CMD as root on NODE. TTY is
# "tty" (a terminal), "stdin" (our stdin, forwarded) or "none" (no input: a
# loop reading its own stdin around a pct call keeps it).
on_node() {
    local node=$1 tty=$2 cmd=$3 addr status socket
    local -a opts
    pve_ssh_opts "$node"
    opts=("${PVE_SSH_OPTS[@]}")
    addr=$(node_addr "$node")
    if [[ -n $CONTROL_DIR ]]; then
        # One shared connection per node, started on its own and detached
        # from every caller's output, so no pipe or $(...) waits for it.
        socket=$CONTROL_DIR/$node.sock
        if [[ ! -S $socket ]]; then
            ssh "${opts[@]}" -o ControlMaster=yes -o "ControlPath=$socket" -o ControlPersist=600 \
                -fN "root@$addr" </dev/null >/dev/null 2>&1 || true
        fi
        opts+=(-o ControlMaster=no -o "ControlPath=$socket")
    fi
    case $tty in
        tty) opts+=(-tt) ;;
        none) opts+=(-T -n) ;;
        *) opts+=(-T) ;;
    esac
    # "--" ends ssh's option parsing, which OpenSSH continues after the
    # destination: it is not sent, and a command can never be read as an option.
    ssh "${opts[@]}" "root@$addr" -- "$cmd"
    status=$?
    (( status != 255 )) || printf 'pct-cluster: cannot reach node %s (%s) as root over SSH.\n' "$node" "$addr" >&2
    return "$status"
}

cluster_list() {
    local here real node dir
    here=$(local_node); real=$(real_pct) || exit 2
    _OSR_PCT_CLUSTER=running-real-pct "$real" list || return
    for dir in "$NODES_DIR"/*/; do
        node=$(basename -- "$dir")
        [[ $node != "$here" && -d $dir/lxc ]] || continue
        [[ $(node_member "$node" online) != 0 ]] || continue
        on_node "$node" none "$(quote "$REMOTE_PCT" list)" 2>/dev/null | tail -n +2
    done
    return 0
}

# remote_push NODE ID SRC DEST [OPTION...]: the file goes through SSH's stdin
# into a private temporary file on NODE, which pct pushes, then removes.
remote_push() {
    local node=$1 id=$2 src=$3
    shift 3
    [[ -f $src && -r $src ]] || die "cannot read $src"
    on_node "$node" stdin "t=\$(mktemp) || exit 1; cat > \"\$t\" && $(quote "$REMOTE_PCT" push "$id") \"\$t\" $(quote "$@"); r=\$?; rm -f -- \"\$t\"; exit \$r" < "$src"
}

# remote_pull NODE ID SRC DEST [OPTION...]: pulled on NODE into a private
# temporary file, streamed back, and moved into place only when complete.
remote_pull() {
    local node=$1 id=$2 src=$3 dest=$4 tmp status perms='' arg
    shift 4
    local -a opts=("$@")
    for (( arg = 0; arg < ${#opts[@]}; arg++ )); do
        [[ ${opts[arg]} != --perms ]] || perms=${opts[arg + 1]:-}
        [[ ${opts[arg]} != --perms=* ]] || perms=${opts[arg]#--perms=}
    done
    tmp=$(mktemp "$(dirname -- "$dest")/.pct-pull.XXXXXX") || die "cannot write beside $dest"
    on_node "$node" none "t=\$(mktemp) || exit 1; $(quote "$REMOTE_PCT" pull "$id" "$src") \"\$t\" $(quote "$@") >&2 && cat -- \"\$t\"; r=\$?; rm -f -- \"\$t\"; exit \$r" > "$tmp"
    status=$?
    if (( status != 0 )); then rm -f -- "$tmp"; return "$status"; fi
    if [[ -n $perms ]] && ! chmod "$perms" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$dest"
}

main() {
    local sub=${1:-} id=${2:-} node here real tty=none
    case $sub in
        --osr-node) node_of "$id"; return ;;
        --osr-check-node) [[ -n $id ]] || die '--osr-check-node needs a node name'
                          on_node "$id" none true ;
                          return ;;
        --osr-node-state)
            [[ -n $id ]] || die '--osr-node-state needs a node name'
            if [[ $id == "$(local_node)" ]]; then echo local
            elif [[ ! -d $NODES_DIR/$id ]]; then echo unknown
            elif [[ $(node_member "$id" online) == 0 ]]; then echo offline
            elif on_node "$id" none true 2>/dev/null; then echo ok
            else echo unreachable; fi
            return 0 ;;
        --osr-close)
            [[ -n $CONTROL_DIR && -d $CONTROL_DIR ]] || return 0
            local socket
            for socket in "$CONTROL_DIR"/*.sock; do
                [[ ! -S $socket ]] || ssh -o "ControlPath=$socket" -O exit "root@${socket##*/}" >/dev/null 2>&1 || true
            done
            return 0 ;;
        list) cluster_list; return ;;
    esac
    here=$(local_node)
    if [[ $id =~ ^[0-9]+$ ]]; then node=$(node_of "$id"); else node=''; fi
    if [[ -z $node || $node == "$here" ]]; then
        # Local, unknown (pct reports it) or not about one CT: the real pct.
        real=$(real_pct) || exit 2
        _OSR_PCT_CLUSTER=running-real-pct exec "$real" "$@"
    fi
    [[ $(node_member "$node" online) != 0 ]] || die "CT $id is on node $node, which the cluster reports offline."
    case $sub in
        push) (( $# >= 4 )) || die 'usage: pct push ID FILE DEST [OPTIONS]'
              shift 2; remote_push "$node" "$id" "$@" ;;
        pull) (( $# >= 4 )) || die 'usage: pct pull ID PATH FILE [OPTIONS]'
              shift 2; remote_pull "$node" "$id" "$@" ;;
        enter) on_node "$node" tty "$(quote "$REMOTE_PCT" "$@")" ;;
        exec)
            if [[ ${OSR_PCT_TTY:-} == 1 && -t 0 ]]; then tty='tty'
            elif [[ ! -t 0 ]]; then tty='stdin'; fi
            on_node "$node" "$tty" "$(quote "$REMOTE_PCT" "$@")" ;;
        *) on_node "$node" none "$(quote "$REMOTE_PCT" "$@")" ;;
    esac
}

# Sourced (by tools/setup-cluster-ssh.sh) it only defines its functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
