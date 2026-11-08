#!/usr/bin/env bash
# tools/setup-cluster-ssh.sh: root SSH between Proxmox VE 9 cluster nodes. A
# fake ssh plays the cluster: it knows which node a connection comes from and
# goes to, and flag files make one fail the way real SSH does; a fake pvecm
# updatecerts clears what it would really restore on its node.
set -uo pipefail
exec </dev/null

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
TOOL=$ROOT/tools/setup-cluster-ssh.sh
# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/mock"

# Flags in $tmp/mock: down-<to>, firewall-<from>-<to> (connection refused),
# denied-<to> (its authorized_keys link is broken), nokey-<from> (its key is
# not in the cluster file), hostkey-<to> (its pinned key is stale). A
# connection through a ControlPath without ControlMaster reuses a signed-in
# session; a node's root home is $FAKE/home/<node>.
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
from=${OSR_MOCK_NODE:-pve1} to='' dest='' cmd='' known='' password=false cpath='' master=false
while (( $# )); do
    case $1 in
        -o) case $2 in
                HostKeyAlias=*) to=${2#*=} ;;
                UserKnownHostsFile=*) known=${2#*=} ;;
                BatchMode=no|PreferredAuthentications=*password*) password=true ;;
                ControlPath=*) cpath=${2#*=} ;;
                ControlMaster=yes) master=true ;;
            esac; shift 2 ;;
        -e) shift 2 ;;
        -O) exit 0 ;;
        -T|-n|-t|-tt|-fN) shift ;;
        # Like OpenSSH: a "--" after the destination is not part of the command.
        root@*) dest=$1; shift; [[ ${1:-} != -- ]] || shift; cmd=${1:-}; break ;;
        *) shift ;;
    esac
done
addr=${dest#root@}
[[ -n $to ]] || to=pve${addr##*.}
session=false
[[ -z $cpath ]] || $master || session=true
printf '%s -> %s%s%s%s%s :: %s\n' "$from" "$to" "${known:+ known=$known}" "$($password && echo ' PASSWORD')" \
    "$($master && echo ' MASTER')" "$($session && echo ' SESSION')" "$cmd" >> "$MOCK/ssh.log"
fail() { echo "$1" >&2; exit 255; }
# A session is already signed in and verified.
if $session; then OSR_MOCK_NODE=$to HOME=$FAKE/home/$to exec bash -c "$cmd"; fi
[[ ! -e $MOCK/down-$to && ! -e $MOCK/firewall-$from-$to ]] || fail "ssh: connect to host $addr port 22: Connection refused"
if [[ -e $MOCK/hostkey-$to ]]; then
    # A stale pinned key fails, unless the key given is the node's current one.
    grep -qs "NEWKEY_$to" "$known" || fail 'Host key verification failed.'
fi
if ! $password && [[ -e $MOCK/denied-$to || -e $MOCK/nokey-$from ]]; then
    fail "root@$addr: Permission denied (publickey,password)."
fi
[[ -n $cmd ]] || exit 0
OSR_MOCK_NODE=$to HOME=$FAKE/home/$to exec bash -c "$cmd"
MOCK
cat > "$tmp/bin/pvecm" <<'MOCK'
#!/usr/bin/env bash
node=${OSR_MOCK_NODE:-pve1}
printf '%s %s\n' "$node" "$*" >> "$MOCK/pvecm.log"
[[ $1 == updatecerts && ! -e $MOCK/stuck-$node ]] || exit 1
key=HOSTKEY_$node
[[ ! -e $MOCK/hostkey-$node ]] || key=NEWKEY_$node
rm -f "$MOCK/denied-$node" "$MOCK/nokey-$node" "$MOCK/hostkey-$node"
printf '%s ssh-rsa %s\n' "$node" "$key" > "$FAKE/nodes/$node/ssh_known_hosts"
# Like Proxmox: replace a regular authorized_keys with the cluster link, then
# merge its backup into the shared file and remove the backup.
merge_backup() {
    local backup=$1 shared=$FAKE/priv/authorized_keys
    [[ -f $backup ]] || return 0
    if [[ -s $shared && -n $(tail -c 1 "$shared") ]]; then printf '\n' >> "$shared"; fi
    cat "$backup" >> "$shared"
    rm -f -- "$backup"
}
home=$FAKE/home/$node/.ssh
if [[ -f $home/authorized_keys && ! -L $home/authorized_keys ]]; then
    mv "$home/authorized_keys" "$home/authorized_keys.org"; ln -s "$FAKE/priv/authorized_keys" "$home/authorized_keys"
fi
merge_backup "$home/authorized_keys.org"
if [[ $node == pve1 ]]; then
    # What it restores on this node: key pair, key in the cluster file, the
    # authorized_keys link and the published host key.
    [[ -f $FAKE/root-ssh/id_rsa ]] || { echo key > "$FAKE/root-ssh/id_rsa"; echo 'ssh-rsa ROOTKEY_pve1 root@pve1' > "$FAKE/root-ssh/id_rsa.pub"; }
    grep -qs ROOTKEY_pve1 "$FAKE/priv/authorized_keys" || cat "$FAKE/root-ssh/id_rsa.pub" >> "$FAKE/priv/authorized_keys"
    if [[ -f $FAKE/root-ssh/authorized_keys && ! -L $FAKE/root-ssh/authorized_keys ]]; then
        mv "$FAKE/root-ssh/authorized_keys" "$FAKE/root-ssh/authorized_keys.org"
    fi
    rm -f "$FAKE/root-ssh/authorized_keys"; ln -s "$FAKE/priv/authorized_keys" "$FAKE/root-ssh/authorized_keys"
    merge_backup "$FAKE/root-ssh/authorized_keys.org"
    printf 'pve1 %s\n' "$(cut -d' ' -f1,2 "$FAKE/host_rsa.pub")" > "$FAKE/nodes/pve1/ssh_known_hosts"
fi
MOCK
cat > "$tmp/bin/ssh-keyscan" <<'MOCK'
#!/usr/bin/env bash
addr=${*: -1}
printf '%s ssh-rsa NEWKEY_pve%s\n' "$addr" "${addr##*.}"
MOCK
cat > "$tmp/bin/ssh-keygen" <<'MOCK'
#!/usr/bin/env bash
read -r addr _ blob
printf '3072 SHA256:fp-%s %s (RSA)\n' "$blob" "$addr"
MOCK
cat > "$tmp/bin/id" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then echo "${FAKE_UID:-0}"; else /usr/bin/id "$@"; fi
MOCK
chmod +x "$tmp/bin/"*

members() {  # members NODE:ONLINE...: the cluster's member list (pve1 is this node)
    local entry list='' n
    for entry in pve1:1 "$@"; do
        n=${entry%%:*}
        list+="${list:+, }\"$n\": {\"online\": ${entry#*:}, \"ip\": \"10.0.0.${n#pve}\"}"
    done
    printf '{"nodename": "pve1", "nodelist": {%s}}\n' "$list" > "$tmp/fake/members"
}
reset() {  # a healthy cluster: pve1 (here), pve2 and pve3 online, pve4 offline
    rm -rf "$tmp/fake" "$tmp/mock"/*
    mkdir -p "$tmp/fake/root-ssh" "$tmp/fake/priv"
    for n in pve1 pve2 pve3 pve4; do
        mkdir -p "$tmp/fake/nodes/$n"
        printf '%s ssh-rsa HOSTKEY_%s\n' "$n" "$n" > "$tmp/fake/nodes/$n/ssh_known_hosts"
        echo "ssh-rsa ROOTKEY_$n root@$n" >> "$tmp/fake/priv/authorized_keys"
    done
    echo 'ssh-rsa HOSTKEY_pve1 root@pve1' > "$tmp/fake/host_rsa.pub"
    echo key > "$tmp/fake/root-ssh/id_rsa"
    echo 'ssh-rsa ROOTKEY_pve1 root@pve1' > "$tmp/fake/root-ssh/id_rsa.pub"
    ln -s "$tmp/fake/priv/authorized_keys" "$tmp/fake/root-ssh/authorized_keys"
    members pve2:1 pve3:1 pve4:0
}
run() {  # run ANSWERS ARGS...: output in $out, status in $rc
    local answers=$1; shift
    printf '%b' "$answers" > "$tmp/answers"
    rc=0
    out=$(env PATH="$tmp/bin:$PATH" MOCK="$tmp/mock" FAKE="$tmp/fake" OSR_LOCAL_NODE=pve1 \
              OSR_PVE_NODES_DIR="$tmp/fake/nodes" OSR_PVE_MEMBERS="$tmp/fake/members" \
              OSR_ROOT_SSH_DIR="$tmp/fake/root-ssh" OSR_PVE_PRIV_DIR="$tmp/fake/priv" \
              OSR_SSH_HOST_RSA_KEY="$tmp/fake/host_rsa.pub" OSR_PVECM="$tmp/bin/pvecm" \
              OSR_REMOTE_PVECM="$tmp/bin/pvecm" OSR_REMOTE_SSH="$tmp/bin/ssh" \
              OSR_REMOTE_PVE_NODES_DIR="$tmp/fake/nodes" \
              ${answers:+OSR_SETUP_SSH_ANSWERS="$tmp/answers"} bash "$TOOL" "$@" 2>&1) || rc=$?
}
log() { cat "$tmp/mock/$1.log" 2>/dev/null; }

describe 'a standalone host'
reset; members
run '' --yes
assert_eq 'has nothing to set up' 0 "$rc"
assert_contains 'and says so' 'pve1 is a standalone host' "$out"
assert_eq 'without connecting anywhere' '' "$(log ssh)"

describe 'a healthy cluster'
reset
run '' --yes
assert_eq 'passes' 0 "$rc"
assert_contains 'from here to each node' 'pve2 (10.0.0.2): ok' "$out"
assert_contains 'between the nodes' 'pve3 -> pve2: ok' "$out"
assert_contains 'and back to this node' 'pve2 -> pve1: ok' "$out"
assert_contains 'says upgrades can start anywhere' 'tools/upgrade-all.sh can run from any of them' "$out"
assert_contains 'an offline node is named, not failed' 'pve4 is offline in the cluster and was not checked' "$out"
assert_contains 'checked against the pinned host key, as Proxmox does' "pve1 -> pve2 known=$tmp/fake/nodes/pve2/ssh_known_hosts" "$(log ssh)"
assert_contains 'also from the other nodes' "pve2 -> pve3 known=$tmp/fake/nodes/pve3/ssh_known_hosts" "$(log ssh)"
assert_eq 'and nothing is changed' '' "$(log pvecm)"
reset
rm "$tmp/fake/nodes/pve3/ssh_known_hosts"
run '' --check
assert_eq 'an unpinned but reachable node is reported' 1 "$rc"
assert_contains 'with its remedy' 'pve3 has not published' "$out"
assert_eq 'and a check changes nothing' '' "$(log pvecm)"
run '' --yes
assert_eq 'a reachable node publishes its pin' 0 "$rc"
assert_contains 'by updating that node' 'pve3 updatecerts' "$(log pvecm)"
reset
rm -f "$tmp/mock/ssh.log"
run '' --node pve2 --check
assert_eq '--node checks only that node' 0 "$rc"
assert_not_contains 'and leaves the others out' 'pve3' "$(log ssh)"

describe 'this node'
reset
# A regular file holding only keys the cluster file has: nothing is lost.
rm "$tmp/fake/root-ssh/authorized_keys"; echo 'ssh-rsa ROOTKEY_pve2 root@pve2' > "$tmp/fake/root-ssh/authorized_keys"
rm "$tmp/fake/nodes/pve1/ssh_known_hosts"
run '' --check
assert_eq '--check reports a problem' 1 "$rc"
assert_contains 'a broken authorized_keys link' 'is not a link to' "$out"
assert_contains 'an unpublished host key' 'this node has not published its host key' "$out"
assert_contains 'and what it would do' 'Would run: pvecm updatecerts' "$out"
assert_eq 'without doing it' '' "$(log pvecm)"
run '' --yes
assert_eq '--yes restores it' 0 "$rc"
assert_contains 'with pvecm updatecerts' 'pve1 updatecerts' "$(log pvecm)"
assert_contains 'and says so' 'Restored.' "$out"
reset
echo 'ssh-rsa HOSTKEY_old' > "$tmp/fake/host_rsa.pub"
run 'n\n'
assert_contains 'a stale published host key' 'is not its current one' "$out"
assert_eq 'asked, and declined: nothing changes' '' "$(log pvecm)"
assert_eq 'and it is still to fix' 1 "$rc"
run 'y\n'
assert_eq 'accepted: restored' 0 "$rc"
reset
rm "$tmp/fake/root-ssh/id_rsa" "$tmp/fake/root-ssh/id_rsa.pub"
run '' --check
assert_contains 'no key pair' 'root has no SSH key pair' "$out"
reset
echo 'ssh-ed25519 ROOTKEY_other root@pve1' > "$tmp/fake/root-ssh/id_rsa.pub"
run '' --check
assert_contains 'a key the cluster does not list' "root's key is not in $tmp/fake/priv/authorized_keys" "$out"

describe 'keys only a regular authorized_keys holds are not lost'
stray_setup() {  # stray_setup: this node's authorized_keys is a regular file with an extra key
    reset
    rm "$tmp/fake/root-ssh/authorized_keys"
    { cat "$tmp/fake/priv/authorized_keys"; echo 'from="10.9.9.9" ssh-ed25519 EXTRAKEY alice@laptop'; } > "$tmp/fake/root-ssh/authorized_keys"
}
stray_setup
run '' --check
assert_eq '--check reports it' 1 "$rc"
assert_contains 'naming the key' 'alice@laptop' "$out"
assert_contains 'and what a repair would do to it' 'changing root SSH access on every node' "$out"
assert_contains 'and that Proxmox will do it at its next start anyway' 'the next time pve-cluster starts on pve1' "$out"
run '' --yes
assert_eq 'unattended, this node is left alone' 1 "$rc"
assert_contains 'saying why' 'Not repaired without a terminal.' "$out"
assert_contains 'and that Proxmox imports them when pve-cluster next starts' 'the next time pve-cluster starts on pve1' "$out"
assert_contains 'with how to keep them on this node' "remove them
  from pve1's /root/.ssh/authorized_keys and delete its /root/.ssh/authorized_keys.org" "$out"
assert_eq 'without pvecm updatecerts' '' "$(log pvecm)"
assert_contains 'and the key still works' 'EXTRAKEY' "$(cat "$tmp/fake/root-ssh/authorized_keys")"
run 'y\ny\n'
assert_eq 'kept: repaired' 0 "$rc"
assert_contains 'Proxmox imports the key into the cluster file' 'from="10.9.9.9" ssh-ed25519 EXTRAKEY alice@laptop' "$(cat "$tmp/fake/priv/authorized_keys")"
assert_contains 'then pvecm updatecerts runs' 'pve1 updatecerts' "$(log pvecm)"
assert_fail 'Proxmox removes the backup after importing' test -e "$tmp/fake/root-ssh/authorized_keys.org"
stray_setup
run 'y\nn\n'
assert_eq 'declined import: left alone' 1 "$rc"
assert_eq 'nothing run' '' "$(log pvecm)"
assert_not_contains 'the key was not shared' 'EXTRAKEY' "$(cat "$tmp/fake/priv/authorized_keys")"
assert_contains 'and remains authorized on this node' 'EXTRAKEY' "$(cat "$tmp/fake/root-ssh/authorized_keys")"
assert_contains 'and said' 'pve1 was left as it is' "$out"
assert_contains 'with what that does not prevent' 'the next time pve-cluster starts on pve1' "$out"
reset
echo 'from="10.0.0.5" ssh-ed25519 SAMEKEY alice@desk' >> "$tmp/fake/priv/authorized_keys"
rm "$tmp/fake/root-ssh/authorized_keys"
echo 'ssh-ed25519 SAMEKEY alice@desk' > "$tmp/fake/root-ssh/authorized_keys"
run '' --yes
assert_eq 'the same key with different SSH options needs approval' 1 "$rc"
assert_contains 'its entry is named' 'alice@desk' "$out"
assert_eq 'so it is not imported unattended' '' "$(log pvecm)"
reset
rm "$tmp/fake/nodes/pve1/ssh_known_hosts"
echo 'ssh-ed25519 OLDKEY old@desk' > "$tmp/fake/root-ssh/authorized_keys.org"
run '' --yes
assert_eq 'an earlier backup also blocks unattended repair' 1 "$rc"
assert_contains 'the backup key is named' 'old@desk' "$out"
assert_eq 'without publishing that backup key' '' "$(log pvecm)"
reset; touch "$tmp/mock/nokey-pve2"
mkdir -p "$tmp/fake/home/pve2/.ssh"
echo 'ssh-ed25519 BOBKEY bob@desk' > "$tmp/fake/home/pve2/.ssh/authorized_keys"
run '' --yes
assert_eq 'on another node too: unattended, it is left alone' 1 "$rc"
assert_contains 'naming its key' 'bob@desk' "$out"
assert_eq 'without pvecm updatecerts there' '' "$(log pvecm)"
run 'y\ny\n'
assert_eq 'kept: repaired' 0 "$rc"
assert_contains 'its key moves into the cluster file' 'BOBKEY bob@desk' "$(cat "$tmp/fake/priv/authorized_keys")"
assert_contains 'then pvecm updatecerts runs there' 'pve2 updatecerts' "$(log pvecm)"
reset; touch "$tmp/mock/nokey-pve2"
mkdir -p "$tmp/fake/home/pve2/.ssh"
echo 'ssh-ed25519 OLDREMOTE old@remote' > "$tmp/fake/home/pve2/.ssh/authorized_keys.org"
run '' --yes
assert_eq 'a remote backup also blocks unattended repair' 1 "$rc"
assert_contains 'its backup key is named' 'old@remote' "$out"
assert_eq 'without importing it' '' "$(log pvecm)"

describe 'repairs on other nodes need the same consent as here'
reset; touch "$tmp/mock/nokey-pve2"
run ''
assert_eq 'without a terminal or --yes nothing is repaired' 1 "$rc"
assert_eq 'on any node' '' "$(log pvecm)"
assert_contains 'saying how' 'pve2 was not changed (run with --yes, or on a terminal' "$out"
run 'n\n'
assert_eq 'declined on a terminal: nothing is repaired' '' "$(log pvecm)"
reset; rm "$tmp/fake/nodes/pve3/ssh_known_hosts"
run ''
assert_eq 'nor is an unpublished pin' '' "$(log pvecm)"

describe '--node'
reset
rm -f "$tmp/mock/ssh.log"
run '' --check --node pve1
assert_eq 'may name this node' 0 "$rc"
assert_contains 'which is always checked' 'pve1 is this node; it is always checked' "$out"
assert_eq 'and then no other node is' '' "$(log ssh)"
assert_contains 'does not claim the whole mesh was checked' 'unselected nodes were not checked' "$out"
run '' --check --node pve1,pve2
assert_contains 'with others it checks those' 'pve2 (10.0.0.2): ok' "$out"

describe 'a node this node cannot reach'
reset; touch "$tmp/mock/down-pve3"
run 'y\n'
assert_eq 'fails' 1 "$rc"
assert_contains 'explains a refused connection' 'cannot connect to sshd on pve3 at 10.0.0.3' "$out"
assert_contains 'and what to check' 'firewall lets the cluster' "$out"
assert_not_contains 'offers no password sign-in for a network problem' 'Sign in to pve3' "$out"
reset; touch "$tmp/mock/denied-pve3"
run '' --yes
assert_eq 'a refused key fails unattended' 1 "$rc"
assert_contains 'saying what to run there' "on pve3 run 'pvecm updatecerts'" "$out"
assert_not_contains 'and never signs in with a password' 'PASSWORD' "$(log ssh)"
rm -f "$tmp/mock/ssh.log"
run ''
assert_eq 'without a terminal it does not either' 1 "$rc"
assert_not_contains 'even without --yes' 'PASSWORD' "$(log ssh)"
run 'y\n'
assert_eq 'on a terminal, a password sign-in repairs it' 0 "$rc"
assert_contains 'verifying the pinned host key' "pve1 -> pve3 known=$tmp/fake/nodes/pve3/ssh_known_hosts PASSWORD" "$(log ssh)"
assert_contains 'and running pvecm updatecerts there' 'pve3 updatecerts' "$(log pvecm)"
assert_contains 'then it works' 'pve3 (10.0.0.3): ok now' "$out"
assert_eq 'signing in once' 1 "$(log ssh | grep -c ' PASSWORD MASTER ')"
assert_contains 'and checking and repairing through that session' 'pve1 -> pve3 SESSION :: ' "$(log ssh)"
reset; touch "$tmp/mock/denied-pve3"
mkdir -p "$tmp/fake/home/pve3/.ssh"
echo 'ssh-ed25519 CAROLKEY carol@x' > "$tmp/fake/home/pve3/.ssh/authorized_keys"
run 'y\ny\n'
assert_eq 'a signed-in repair also keeps stray keys when asked' 0 "$rc"
assert_contains 'carol is in the cluster file' 'CAROLKEY carol@x' "$(cat "$tmp/fake/priv/authorized_keys")"
assert_eq 'still one sign-in' 1 "$(log ssh | grep -c ' PASSWORD MASTER ')"
reset; touch "$tmp/mock/denied-pve3"
run 'n\n'
assert_eq 'declined: still to fix' 1 "$rc"
assert_eq 'nothing is run anywhere' '' "$(log pvecm)"
assert_not_contains 'and the unreachable node is not probed again from the others' 'pve2 -> pve3' "$(log ssh)"

describe 'a node whose host key changed'
reset; touch "$tmp/mock/hostkey-pve3"
run 'y\ny\n'
assert_contains 'shows the key it presents' 'presents RSA host key SHA256:fp-NEWKEY_pve3' "$out"
assert_contains 'and how to compare it on the node' 'ssh-keygen -lf /etc/ssh/ssh_host_rsa_key.pub' "$out"
signin=$(log ssh | grep ' PASSWORD ')
assert_contains 'signs in with the confirmed key' 'pve1 -> pve3 known=' "$signin"
assert_not_contains 'not the stale pinned one' "$tmp/fake/nodes/pve3/" "$signin"
oneoff=$(sed -n 's/.* known=\([^ ]*\) PASSWORD .*/\1/p' <<< "$signin")
assert_eq 'and keeps it for that connection only' '' "$(ls "$oneoff" 2>/dev/null)"
assert_contains 'runs pvecm updatecerts there' 'pve3 updatecerts' "$(log pvecm)"
assert_eq 'then it works' 0 "$rc"
reset; touch "$tmp/mock/hostkey-pve3"
run 'y\nn\n'
assert_contains 'a key not confirmed is not trusted' 'Not trusted; pve3 was left as it is' "$out"
assert_not_contains 'and no sign-in happens' 'PASSWORD' "$(log ssh)"
assert_eq 'still to fix' 1 "$rc"
reset; touch "$tmp/mock/hostkey-pve3"; rm "$tmp/fake/nodes/pve3/ssh_known_hosts"
run '' --check
assert_contains 'a node that never published its key' 'pve3 has not published its host key' "$out"

describe 'between the nodes'
reset; touch "$tmp/mock/nokey-pve2"
run '' --check
assert_eq '--check finds a node whose key the others refuse' 1 "$rc"
assert_contains 'from that node' 'pve2 -> pve1: FAILED' "$out"
assert_contains 'with the advice' "pve3 refuses pve2's key: run 'pvecm updatecerts' on pve2" "$out"
assert_contains 'and what a repair would run' 'Would run: pvecm updatecerts on pve2' "$out"
run '' --yes
assert_eq '--yes repairs it over the SSH that works' 0 "$rc"
assert_eq 'restoring that node once' 1 "$(log pvecm | grep -c '^pve2 updatecerts')"
assert_contains 'then it works' 'pve2 -> pve1: ok now' "$out"
assert_contains 'for every pair' 'pve2 -> pve3: ok' "$out"
reset; touch "$tmp/mock/nokey-pve2" "$tmp/mock/stuck-pve2"
run '' --yes
assert_eq 'a repair that does not help is reported' 1 "$rc"
assert_eq 'and tried once, not once per failing pair' 1 "$(log pvecm | grep -c '^pve2 updatecerts')"
reset; touch "$tmp/mock/firewall-pve2-pve3"
run '' --yes
assert_eq 'a firewall between two nodes is reported' 1 "$rc"
assert_contains 'naming both' 'pve2 cannot connect to sshd on pve3' "$out"
assert_eq 'and nothing is changed for it' '' "$(log pvecm)"
reset; touch "$tmp/mock/firewall-pve3-pve1"
run '' --yes
assert_contains 'a node that cannot reach this one is reported too' 'pve3 -> pve1: FAILED' "$out"

describe 'usage'
reset
FAKE_UID=1000 run '' --check
assert_eq 'needs root' 2 "$rc"
run '' --bogus
assert_eq 'an unknown option' 2 "$rc"
run '' --check --node pve9
assert_eq 'an unknown node' 2 "$rc"
run '' --check --node pve2,pve9
assert_eq 'an unknown node in a list' 2 "$rc"
run '' --check --node=
assert_eq 'an empty node filter' 2 "$rc"
run '' --help
assert_contains 'help is the header' 'Check, and repair, root SSH' "$out"

summary
