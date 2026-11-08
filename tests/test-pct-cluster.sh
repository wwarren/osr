#!/usr/bin/env bash
# tools/pct-cluster.sh: pct for CTs on any node of a Proxmox cluster. A fake
# ssh runs the "remote" command here, tagged with the node it was meant for,
# and a mock pct records what each node was asked to do.
set -uo pipefail
exec </dev/null

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
WRAPPER=$ROOT/tools/pct-cluster.sh
# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/shim" "$tmp/mock" "$tmp/remote-tmp"
mkdir -p "$tmp/nodes/pve1/lxc" "$tmp/nodes/pve2/lxc" "$tmp/nodes/pve3/lxc" "$tmp/nodes/pve4/lxc"
for id in 101 102; do : > "$tmp/nodes/pve1/lxc/$id.conf"; done
for id in 201 202 998 999; do : > "$tmp/nodes/pve2/lxc/$id.conf"; done
: > "$tmp/nodes/pve3/lxc/301.conf"
: > "$tmp/nodes/pve4/lxc/401.conf"
cat > "$tmp/members" <<'JSON'
{"nodename": "pve1", "version": 7, "cluster": {"name": "lab", "nodes": 3, "quorate": 1},
 "nodelist": {"pve1": {"id": 1, "online": 1, "ip": "10.0.0.1"},
              "pve2": {"id": 2, "online": 1, "ip": "10.0.0.2"},
              "pve3": {"id": 3, "online": 0, "ip": "10.0.0.3"}}}
JSON

# The mock pct, used as this node's and every other node's pct.
cat > "$tmp/bin/pct-real" <<'MOCK'
#!/usr/bin/env bash
node=${OSR_MOCK_NODE:-pve1}
printf '%s %s\n' "$node" "$*" >> "$MOCK/pct.log"
sub=$1 id=${2:-}
case $sub in
    status) [[ $id != 999 ]] || { echo 'CT 999 is broken' >&2; exit 7; }
            echo 'status: running' ;;
    exec) shift 3; exec "$@" ;;
    push) cat -- "$3" > "$MOCK/pushed-$id"; printf '%s\n' "$3" > "$MOCK/pushed-from-$id" ;;
    pull) [[ $id != 998 ]] || { echo 'no such file' >&2; exit 5; }
          printf 'from %s on %s\n' "$3" "$node" > "$4" ;;
    list) printf 'VMID       Status     Lock         Name\n'
          for conf in "$MOCK_NODES/$node"/lxc/*.conf; do id=${conf##*/}; printf '%-10s running                 ct%s\n' "${id%.conf}" "${id%.conf}"; done ;;
esac
exit 0
MOCK
# The fake ssh: runs the command here as the node named by HostKeyAlias.
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
node='' dest='' cmd='' flags='' cpath='' known='' global='' dashdash=false
while (( $# )); do
    case $1 in
        -o) case $2 in HostKeyAlias=*) node=${2#*=} ;; ControlPath=*) cpath=${2#*=} ;;
                       UserKnownHostsFile=*) known=${2#*=} ;; GlobalKnownHostsFile=*) global=${2#*=} ;; esac; shift 2 ;;
        -e) shift 2 ;;
        -O) exit 0 ;;
        -fN) printf '%s MASTER %s\n' "$node" "$cpath" >> "$MOCK/ssh.log"
             # A persistent master lives on with whatever output it was given.
             [[ $(readlink /proc/self/fd/1) == /dev/null ]] || (sleep 20 &)
             exit 0 ;;
        -n|-T|-tt) flags+=" $1"; shift ;;
        # Like OpenSSH: a "--" after the destination ends its options and is
        # not part of the command.
        root@*) dest=$1; shift; if [[ ${1:-} == -- ]]; then dashdash=true; shift; fi; cmd=${1:-}; break ;;
        *) dest=$1; shift ;;
    esac
done
printf '%s %s%s%s :: %s%s%s%s\n' "$node" "$dest" "$flags" "$($dashdash && echo ' --')" "$cmd" "${cpath:+ via $cpath}" "${known:+ known=$known}" "${global:+ global=$global}" >> "$MOCK/ssh.log"
if [[ -e $MOCK/down-$node ]]; then echo "ssh: connect to host $dest port 22: Connection refused" >&2; exit 255; fi
# Like real ssh: without -n it reads all of our stdin and forwards it.
if [[ $flags == *' -n'* ]]; then exec </dev/null
else forwarded=$(mktemp); cat > "$forwarded"; exec < "$forwarded"; rm -f -- "$forwarded"; fi
OSR_MOCK_NODE=$node TMPDIR=$MOCK_REMOTE_TMP exec bash -c "$cmd"
MOCK
chmod +x "$tmp/bin/"*
# Installed the way upgrade-all.sh installs it: a stub that needs no exec bit.
printf '#!/bin/sh\nexec bash %q "$@"\n' "$WRAPPER" > "$tmp/shim/pct"
chmod +x "$tmp/shim/pct"

export PATH="$tmp/shim:$tmp/bin:$PATH" MOCK="$tmp/mock" MOCK_NODES="$tmp/nodes" MOCK_REMOTE_TMP="$tmp/remote-tmp" \
       OSR_REAL_PCT="$tmp/bin/pct-real" OSR_REMOTE_PCT="$tmp/bin/pct-real" OSR_LOCAL_NODE=pve1 \
       OSR_PVE_NODES_DIR="$tmp/nodes" OSR_PVE_MEMBERS="$tmp/members"
reset() { rm -rf "$tmp/mock"/* "$tmp/remote-tmp"/*; }

describe 'a CT on this node uses the real pct'
reset
out=$(pct status 101)
assert_eq 'answers' 'status: running' "$out"
assert_file_contains 'on this node' 'pve1 status 101' "$tmp/mock/pct.log"
assert_eq 'no SSH' '' "$(cat "$tmp/mock/ssh.log" 2>/dev/null)"
pct status 555 >/dev/null
assert_file_contains 'an unknown CT is left to the real pct' 'pve1 status 555' "$tmp/mock/pct.log"

describe 'a CT on another node goes over SSH to that node'
reset
out=$(pct status 201)
assert_eq 'answers' 'status: running' "$out"
assert_file_contains 'that node runs it' 'pve2 status 201' "$tmp/mock/pct.log"
assert_file_contains 'as root, at its cluster address, keyed by node name' 'pve2 root@10.0.0.2' "$tmp/mock/ssh.log"
assert_status 'its exit status comes back' 7 pct status 999
assert_contains 'with its error' 'CT 999 is broken' "$(pct status 999 2>&1)"
assert_eq 'the node holding a CT' pve2 "$(pct --osr-node 201)"

describe 'exec keeps every argument as given'
reset
pct status 201 >/dev/null
assert_file_contains 'the remote command follows "--", so it is never read as an ssh option' 'pve2 root@10.0.0.2 -T -n -- :: ' "$tmp/mock/ssh.log"
reset
out=$(pct exec 201 -- sh -c 'printf "[%s][%s]\n" "$1" "$2"' sh 'two  spaces' "it's \$HOME;\"q\"")
assert_eq 'quoting survives SSH' "[two  spaces][it's \$HOME;\"q\"]" "$out"
assert_eq 'piped stdin reaches the command' hello "$(echo hello | pct exec 201 -- cat)"
assert_eq 'local exec too' hello "$(echo hello | pct exec 101 -- cat)"

describe 'host keys are checked the way Proxmox VE 9 checks them'
reset
printf 'pve2 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7\n' > "$tmp/nodes/pve2/ssh_known_hosts"
pct status 201 >/dev/null
assert_file_contains 'against the key the node pinned in the cluster filesystem' \
    "known=$tmp/nodes/pve2/ssh_known_hosts global=none" "$tmp/mock/ssh.log"
rm "$tmp/nodes/pve2/ssh_known_hosts"
reset
pct status 201 >/dev/null
assert_not_contains 'like Proxmox, the usual files until it has published one' 'known=' "$(cat "$tmp/mock/ssh.log")"

describe 'calls without input leave the caller'"'"'s stdin alone'
reset
seen=$(printf '201\n202\n101\n' | while read -r id; do pct status "$id" >/dev/null; printf '%s ' "$id"; done)
assert_eq 'a read loop sees every line' '201 202 101 ' "$seen"
assert_file_contains 'SSH gets no stdin' 'pve2 root@10.0.0.2 -T -n' "$tmp/mock/ssh.log"

describe 'push streams a local file to the other node'
reset
printf 'line one\nsecret: \001\002 end\n' > "$tmp/src"
assert_ok 'pushes' pct push 201 "$tmp/src" /root/deploy/x.sh --perms 0700
assert_eq 'the CT gets the same bytes' "$(od -c "$tmp/src")" "$(od -c "$tmp/mock/pushed-201")"
assert_file_contains 'with its destination and options' '/root/deploy/x.sh --perms 0700' "$tmp/mock/pct.log"
remote_copy=$(cat "$tmp/mock/pushed-from-201")
assert_ne 'from a copy on that node, not this path' "$tmp/src" "$remote_copy"
assert_eq 'and the copy is removed' '' "$(ls -A "$tmp/remote-tmp")"
assert_status 'an unreadable file is refused' 2 pct push 201 "$tmp/missing" /root/x

describe 'pull streams a file back from the other node'
reset
assert_ok 'pulls' pct pull 201 /etc/mqtt-target/relay.json "$tmp/out.json" --perms 0640
assert_eq 'with its content' 'from /etc/mqtt-target/relay.json on pve2' "$(cat "$tmp/out.json")"
case $(uname -s) in
    MINGW*|MSYS*) skip 'and the mode asked for' 'Git Bash on NTFS does not preserve Unix modes' ;;
    *) assert_file_mode 'and the mode asked for' 640 "$tmp/out.json" ;;
esac
assert_eq 'leaving nothing on that node' '' "$(ls -A "$tmp/remote-tmp")"
rm -f "$tmp/out2"
assert_status 'a failed pull returns its status' 5 pct pull 998 /nope "$tmp/out2"
assert_eq 'and writes nothing here' '' "$(find "$tmp" -maxdepth 1 \( -name out2 -o -name '.pct-pull.*' \))"

describe 'nodes that cannot be reached'
reset
assert_status 'an offline node is refused without SSH' 2 pct status 301
assert_contains 'saying so' 'node pve3, which the cluster reports offline' "$(pct status 301 2>&1)"
assert_eq 'no connection tried' '' "$(cat "$tmp/mock/ssh.log" 2>/dev/null)"
touch "$tmp/mock/down-pve2"
assert_status 'SSH failure is exit 255' 255 pct status 201
assert_contains 'with the node and address' 'cannot reach node pve2 (10.0.0.2) as root over SSH' "$(pct status 201 2>&1)"
assert_status '--osr-check-node fails for it' 255 pct --osr-check-node pve2
assert_eq 'an unreachable node' unreachable "$(pct --osr-node-state pve2)"
rm "$tmp/mock/down-pve2"
assert_ok '--osr-check-node passes when it answers' pct --osr-check-node pve2
assert_eq 'a reachable node' ok "$(pct --osr-node-state pve2)"
assert_eq 'this node' local "$(pct --osr-node-state pve1)"
assert_eq 'an offline node' offline "$(pct --osr-node-state pve3)"
assert_eq 'a node that is not in the cluster' unknown "$(pct --osr-node-state pve9)"
reset
pct status 401 >/dev/null
assert_file_contains 'a node missing from .members is reached by name' 'pve4 root@pve4' "$tmp/mock/ssh.log"

describe 'connections to a node are shared'
reset
mkdir -p "$tmp/ctl"
OSR_SSH_CONTROL_DIR=$tmp/ctl pct status 201 >/dev/null
assert_file_contains 'one connection per node is started on its own' "pve2 MASTER $tmp/ctl/pve2.sock" "$tmp/mock/ssh.log"
assert_file_contains 'and calls go through it' "via $tmp/ctl/pve2.sock" "$tmp/mock/ssh.log"
assert_ok '--osr-close ends them' env OSR_SSH_CONTROL_DIR="$tmp/ctl" pct --osr-close
# shellcheck disable=SC2016  # expanded by the child
assert_ok 'a caller'"'"'s $(...) does not wait for the shared connection' \
    timeout 10 env OSR_SSH_CONTROL_DIR="$tmp/ctl" bash -c 'x=$(pct status 201); [[ $x == "status: running" ]]'

describe 'list covers the cluster'
reset
out=$(pct list)
assert_eq 'one header' 1 "$(grep -c '^VMID' <<< "$out")"
assert_contains 'this node' 'ct101' "$out"
assert_contains 'other nodes' 'ct201' "$out"
assert_not_contains 'not offline ones' 'ct301' "$out"

describe 'it never calls itself'
assert_status 'refuses itself as the real pct' 2 env OSR_REAL_PCT="$WRAPPER" pct status 101
assert_contains 'saying what to set' 'set OSR_REAL_PCT' "$(OSR_REAL_PCT=$WRAPPER pct status 101 2>&1)"
assert_status 'nor through a stub' 2 env OSR_REAL_PCT="$tmp/shim/pct" pct status 101
assert_contains 'saying so' "leads back to this wrapper" "$(OSR_REAL_PCT=$tmp/shim/pct pct status 101 2>&1)"

summary
