#!/usr/bin/env bash
# targets/freellmapi/provision-lxc.sh without Proxmox: dry-run plans and
# validation, then (as root) whole runs against fake-pve.sh, which keeps each
# CT as a directory and runs the provisioner's own guest scripts in it:
# create, register, settings-only reconfigure, the replacement of the CT for a
# new release, and its rollbacks. Nothing is pulled and no CT is made.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/provision-lxc.sh
bash_bin=$(command -v bash)
common=(CT_ID=280 IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1 STORAGE=local-lvm)
passed=0
out=''
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n%s\n' "$1" "$out" >&2; exit 1; }
has() { [[ $out == *"$1"* ]] || fail "output lacks: $1"; }
lacks() { [[ $out != *"$1"* ]] || fail "output contains: $1"; }
plan() {
    local -a flags=() vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
    out=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" "$bash_bin" "$tool" --dry-run "${flags[@]}" 2>&1) ||
        fail "plan failed: $*"
}
refuse() {
    local expect=$1; shift
    local -a flags=() vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
    if out=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" "$bash_bin" "$tool" --dry-run "${flags[@]}" 2>&1); then
        fail "accepted: $*"
    fi
    has "$expect"
    lacks '+ pct create'
}

default_version=$(sed -n 's/^DEFAULT_FREELLMAPI_VERSION=//p' "$tool")
[[ $default_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'DEFAULT_FREELLMAPI_VERSION is not a release tag'
[[ $(cat "$here/upstream-commit.txt") =~ ^[0-9a-f]{40}$ ]] || fail 'upstream-commit.txt is not one commit'
pass 'the tested release is a tag with one commit'

plan
has "ghcr.io/tashfeenahmed/freellmapi:$default_version"
has "+ pct create 280 local:vztmpl/freellmapi_$default_version.tar --unprivileged 1 --rootfs local-lvm:4 --mp0 local-lvm:2\\,mp=/app/server/data\\,backup=1 --net0 name=eth0\\,bridge=vmbr0\\,ip=192.0.2.80/24\\,gw=192.0.2.1\\,firewall=1 --tags ai\\;ai-model\\;osr-target\\;freellmapi --description"
has '--hostname freellmapi --cores 2 --memory 1024 --swap 0 --onboot 1'
lacks 'nesting'; lacks 'keyctl'; lacks '--ostype'
has 'IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 3001 -log nolog # open-smart-router freellmapi-web'
has 'policy_in: DROP'; has 'policy_out: ACCEPT'; lacks 'freellmapi-router'
has '+ pct set 280 --entrypoint sleep\ infinity'
has 'No digest is pinned for this release'
has 'a password generated in the CT'; has 'not registered'
has "wait up to 120s for http://127.0.0.1:3001/api/ping"
pass 'create: the CT comes from the image, with a data volume, a firewall and no container runtime'

plan FREELLMAPI_ADMIN_PASSWORD='correct horse battery' FREELLMAPI_ADMIN_EMAIL=me@example.org \
    FREELLMAPI_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000001 \
    FREELLMAPI_VERSION=v0.99.1 FREELLMAPI_PORT=3100 FREELLMAPI_ACCESS_CIDR=198.51.100.0/24 \
    ROUTER_CT_ID=210 VLAN_TAG=30 NAMESERVER=192.0.2.53 BRIDGE=vmbr1 TEMPLATE_STORAGE=nas
lacks 'correct horse battery'; has 'me@example.org, the password you gave'
has 'freellmapi:v0.99.1 (sha256:0000'; lacks 'No digest is pinned'
has 'nas:vztmpl/freellmapi_v0.99.1.tar'; has 'tag=30'; has '--nameserver 192.0.2.53'; has 'bridge=vmbr1'
has 'IN ACCEPT -source 198.51.100.0/24 -p tcp -dport 3100'
has 'PORT=3100'
has 'pct exec 210 -- /usr/local/bin/manage-model-servers set-freellmapi http://192.0.2.80:3100 --apply (key on stdin)'
pass 'create: settings are passed through and the password never appears'

refuse 'static IPv4' IP_CIDR=dhcp
refuse 'MEMORY_MB must be at least' MEMORY_MB=256
refuse 'ROOTFS_GB must be at least' ROOTFS_GB=1
refuse 'FREELLMAPI_VERSION must be a release tag' FREELLMAPI_VERSION=latest
refuse 'FREELLMAPI_DIGEST must be' FREELLMAPI_DIGEST=sha256:abc
refuse 'FREELLMAPI_ADMIN_EMAIL' FREELLMAPI_ADMIN_EMAIL=nobody
refuse 'FREELLMAPI_ADMIN_PASSWORD must have' FREELLMAPI_ADMIN_PASSWORD=short
refuse 'FREELLMAPI_PORT' FREELLMAPI_PORT=70000
refuse 'FREELLMAPI_ACCESS_CIDR' FREELLMAPI_ACCESS_CIDR=everyone
refuse 'FREELLMAPI_RATE_LIMIT_RPM' FREELLMAPI_RATE_LIMIT_RPM=-1
refuse 'ROUTER_CT_ID must be' ROUTER_CT_ID=router
refuse 'TEMPLATE_STORAGE' TEMPLATE_STORAGE='bad store'
refuse 'CT_ID' CT_ID=12
refuse 'Set IP_CIDR for unattended provisioning' IP_CIDR=
pass 'create: bad settings are refused before anything is planned'

plan --reconfigure FREELLMAPI_VERSION=v0.99.1 OSR_DRY_RUN_OLD_VERSION=v0.16.31
has 'v0.16.31 -> v0.99.1'; has 'vzdump 280 --mode stop --compress zstd --dumpdir /var/lib/osr-freellmapi/280 --tmpdir /var/tmp'
has '+ pct destroy 280'; has '+ pct create 280 local:vztmpl/freellmapi_v0.99.1.tar'
has 'restore the data directory into the new CT'; has 'pct restore 280 '
has 'are not carried over'
[[ $(grep -n 'vzdump 280\|pct destroy 280' <<< "$out" | cut -d: -f1 | paste -sd' ') =~ ^([0-9]+)\ ([0-9]+)$ ]] &&
    (( BASH_REMATCH[1] < BASH_REMATCH[2] )) || fail 'the backup is not planned before the CT is destroyed'
pass '--reconfigure to another release: backup, then a new CT from the new image with the old data'

plan --register ROUTER_CT_ID=210
has 'set-freellmapi http://192.0.2.80:3001 --apply'; lacks 'pct create'; lacks 'pct stop'
pass '--register only talks to the router'

out=$("$bash_bin" "$tool" --help 2>&1) || fail '--help failed'
has 'Proxmox VE 9.1'; has 'leave your network'; has '--reconfigure'; has '--register'
if out=$("$bash_bin" "$tool" --reconfigure --register 2>&1); then fail 'two modes were accepted'; fi
pass '--help names the requirement and the modes; two modes are refused'

if (( EUID != 0 )); then
    printf 'SKIP the runs against the fake Proxmox need root (the script checks for it)\n'
    printf 'passed %s\n' "$passed"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
commit=$(cat "$here/upstream-commit.txt")
image_entrypoint='/usr/bin/env PORT=3001 /usr/local/bin/docker-entrypoint.sh node server/dist/index.js'
# fresh: an empty fake host with a router CT 210 at 192.0.2.10.
fresh() {
    rm -rf -- "${tmp:?}/host"
    FAKE=$tmp/host/fake PVE_ETC=$tmp/host/pve
    mkdir -p "$FAKE/ct/210" "$PVE_ETC/nodes" "$PVE_ETC/lxc" "$PVE_ETC/firewall" "$tmp/host/bin" "$tmp/host/state"
    printf '%s\n' "$commit" > "$FAKE/commit"; : > "$FAKE/calls"
    printf 'tags: ai;osr-router\nnet0: name=eth0,bridge=vmbr0,ip=192.0.2.10/24,gw=192.0.2.1\n' > "$PVE_ETC/lxc/210.conf"
    : > "$FAKE/ct/210/running"
    local name
    for name in pct pvesh pvesm pveversion skopeo vzdump zstd; do ln -s "$here/fake-pve.sh" "$tmp/host/bin/$name"; done
}
# host [--flag ...] [VAR=value ...]: a real run on the fake host; its status in rc.
host() {
    local -a flags=() vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
    rc=0
    # tools/upgrade-all.sh runs provisioners with umask 077.
    out=$(umask 077; env -i "PATH=$tmp/host/bin:$PATH" FAKE="$FAKE" PVE_ETC="$PVE_ETC" OSR_FREELLMAPI_STATE="$tmp/host/state" \
        BRIDGE=lo FREELLMAPI_READY_TIMEOUT=3 "${vars[@]}" "$bash_bin" "$tool" "${flags[@]}" 2>&1) || rc=$?
}
create() { host "${common[@]}" ROUTER_CT_ID=210 "$@"; }
calls() { cat "$FAKE/calls"; }
conf() { cat "$PVE_ETC/lxc/280.conf"; }
data=''; set_data() { data=$FAKE/ct/280/fs/app/server/data; }
env_file() { cat "$data/osr-target/freellmapi.env"; }
setting() { sed -n "s/^$1=//p" "$data/osr-target/settings"; }
ok() { (( rc == 0 )) || fail "$1 (status $rc)"; }
bad() { (( rc != 0 )) || fail "$1 succeeded"; }

fresh; create; ok 'create'; set_data
[[ $(conf) == *"entrypoint: $image_entrypoint"* ]] || fail 'the image entrypoint was not put back'
[[ -e $FAKE/ct/280/running ]] || fail 'the CT is not running'
[[ $(conf) == *'tags: ai;ai-model;osr-target;freellmapi'* && $(conf) == *'description: FreeLLMAPI%20for%20Open%20Smart%20Router%0A'* ]] || fail 'tags or description'
[[ $(conf) == *'mp=/app/server/data,backup=1'* && $(conf) == *'unprivileged: 1'* ]] || fail 'data volume or unprivileged'
[[ $(grep -c -E '^ENCRYPTION_KEY=[0-9a-f]{64}$' "$data/osr-target/freellmapi.env") == 1 ]] || fail 'no encryption key'
[[ $(env_file) == *$'PORT=3001\nHOST=0.0.0.0\nPROXY_RATE_LIMIT_RPM=600\nFREELLMAPI_UPDATE_CHECK=off'* ]] || fail 'env file'
[[ $(env_file) != *FREEAPI_CONFIG_PATH* && ! -e $data/osr-target/bootstrap.json ]] || fail 'the bootstrap file outlived the first start'
[[ $(readlink "$FAKE/ct/280/fs/app/.env") == "$data/osr-target/freellmapi.env" ]] || fail '/app/.env does not point at the env file'
[[ $(stat -c %a "$data/osr-target/freellmapi.env") == 640 && $(stat -c %a "$data/osr-target") == 750 ]] || fail 'modes'
[[ $(cat "$data/account") == '{"admin":{"email":"admin@osr.local","password":"generated-password"}}' ]] || fail 'the account'
[[ $(stat -c %a "$data/osr-target/initial-admin-password") == 600 ]] || fail 'the generated password is not root-only'
has 'pct exec 280 -- cat /app/server/data/osr-target/initial-admin-password'; lacks 'generated-password'
[[ $(setting FREELLMAPI_VERSION) == "$default_version" && $(setting FREELLMAPI_VERSION_SOURCE) == default &&
   $(setting FREELLMAPI_COMMIT) == "$commit" && $(setting FREELLMAPI_DIGEST) == sha256:* ]] || fail 'the settings record'
fw=$(cat "$PVE_ETC/firewall/280.fw")
[[ $fw == *'-source 192.0.2.0/24 -p tcp -dport 3001 -log nolog # open-smart-router freellmapi-web'* &&
   $fw == *'-source 192.0.2.10/32 -p tcp -dport 3001 -log nolog # open-smart-router freellmapi-router'* ]] || fail 'firewall rules'
key=$(cat "$data/freeapi.db")
[[ $(cat "$FAKE/router-call") == "set-freellmapi http://192.0.2.80:3001 --apply"$'\n'"$key"$'\n'"$key" ]] || fail 'the router did not get the endpoint and key'
lacks "$key"; [[ $(calls) != *"$key"* ]] || fail 'the key reached a command line'
has 'Router CT 210 offers its models as freellmapi/<id>'
[[ $(calls) == *"skopeo copy docker://ghcr.io/tashfeenahmed/freellmapi@sha256:"* ]] || fail 'the image was not pulled by digest'
[[ $(grep -c '^pct start 280' "$FAKE/calls") == 2 && $(cat "$FAKE/ct/280/started") == "$default_version" ]] || fail 'one maintenance boot and one server start were expected'
pass 'create: a running CT with key, account, settings, firewall and the router registration'

fresh; create FREELLMAPI_PORT=3100; ok 'custom port create'; set_data
[[ $(cat "$FAKE/ct/280/listening") == PORT=3100 && $(setting FREELLMAPI_PORT) == 3100 &&
   $(cat "$FAKE/router-call") == "set-freellmapi http://192.0.2.80:3100 --apply"$'\n'"$(cat "$data/freeapi.db")"$'\n'"$(cat "$data/freeapi.db")" ]] || fail 'custom port did not reach the server and router'
pass 'a custom port overrides the image environment and reaches the router'
fresh; create; ok 'create for reconfigure'; set_data

host CT_ID=280 --reconfigure; ok 'unchanged reconfigure'
has 'nothing to do'
[[ $(grep -c '^pct \(stop\|set\|start\|destroy\) 280' "$FAKE/calls") == 5 ]] || fail 'an unchanged CT was touched'
pass '--reconfigure: an unchanged, healthy CT is left alone'

create; bad 'a second create'; has 'CT 280 already exists'
pass 'create refuses an existing CT'

fresh; create FREELLMAPI_ADMIN_PASSWORD='my own password' ROUTER_CT_ID=none; ok 'create with a password'; set_data
[[ $(cat "$data/account") == *'"password":"my own password"'* && ! -e $data/osr-target/initial-admin-password ]] || fail 'the given password'
lacks 'my own password'; [[ $(calls) != *'my own password'* ]] || fail 'the password reached a command line'
[[ $(calls) != *PASSWORD-IN-ENVIRONMENT* ]] || fail 'the password stayed in the environment of the commands'
[[ ! -e $FAKE/router-call ]] || fail 'the router was contacted'
has 'manage-model-servers set-freellmapi http://192.0.2.80:3001 --apply'; has 'with the password you gave'
[[ $(cat "$PVE_ETC/firewall/280.fw") != *freellmapi-router* ]] || fail 'a router rule without a router'
pass 'create: a given password is used and kept off command lines; without a router the hand-over is explained'

fresh; create FAKE_PVE_VERSION=9.0.11; bad 'PVE 9.0'; has 'Proxmox VE 9.1 or later'
[[ $(calls) != *'pct create'* ]] || fail 'a CT was created'
fresh; rm "$tmp/host/bin/skopeo"
rc=0; out=$(env -i "PATH=$tmp/host/bin:/usr/bin:/bin" FAKE="$FAKE" PVE_ETC="$PVE_ETC" BRIDGE=lo "${common[@]}" ROUTER_CT_ID=none "$bash_bin" "$tool" 2>&1) || rc=$?
if command -v skopeo >/dev/null 2>&1; then :; else bad 'no skopeo'; has 'Missing command: skopeo'; fi
fresh; create FREELLMAPI_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000001; bad 'another digest'
has 'not the pinned sha256:0000'; [[ $(calls) != *'pct create'* && $(calls) != *'skopeo copy'* ]] || fail 'a moved tag was used'
fresh; create FAKE_REVISION=1111111111111111111111111111111111111111; bad 'another commit'
has "not the tested $commit"; [[ $(calls) != *'pct create'* ]] || fail 'an image of another commit was used'
fresh; create FAKE_REGISTRY_DOWN=1; bad 'registry down'; has "access to ghcr.io"
fresh; create FAKE_NO_ENTRYPOINT=1; bad 'no entrypoint'; has "did not take the image's entrypoint"
pass 'create: an old Proxmox, a moved tag, another commit, an unreachable registry and a non-OCI create are refused'

fresh; create FAKE_START_FAILS="$default_version"; bad 'a server that exits'
has 'did not answer /api/ping'; has 'The CT is kept'
[[ -f $PVE_ETC/lxc/280.conf && ! -e $FAKE/router-call ]] || fail 'the failed CT was removed or registered'
fresh; create FAKE_ROUTER_REFUSES=1; ok 'a router that refuses'
has 'did not take the FreeLLMAPI endpoint'; has '--register'; lacks 'offers its models'
pass 'create: a server that does not start stops the run; a refusing router leaves a working CT and a hint'

host CT_ID=280 ROUTER_CT_ID=210 --register; ok '--register'; set_data
[[ $(sed -n 2p "$FAKE/router-call") == "$(cat "$data/freeapi.db")" ]] || fail '--register did not hand over the key'
host CT_ID=280 ROUTER_CT_ID=none --register; bad '--register without a router'; has 'Nothing to do'
host CT_ID=280 ROUTER_CT_ID=210 FAKE_NO_KEY=1 --register; bad '--register without a key'; has 'Could not read the unified API key'
rm -f "$FAKE/router-call"
host CT_ID=280 ROUTER_CT_ID=210 FAKE_KEY_REFUSED=1 --register; bad '--register with a key the server refuses'
has 'refused its own unified API key'; [[ ! -e $FAKE/router-call ]] || fail 'a refused key was handed to the router'
host CT_ID=210 --reconfigure; bad 'another CT'; has 'not a FreeLLMAPI CT'
pass '--register hands the key over again; a CT of another kind is refused'

# A port move updates the firewall and router. A failed start restores both.
fresh; create; ok 'create for port changes'; set_data
printf 'IN ACCEPT -source 203.0.113.10/32 -p tcp -dport 9000 # operator rule\n' >> "$PVE_ETC/firewall/280.fw"
host CT_ID=280 FREELLMAPI_PORT=3100 --reconfigure; ok 'port change'
[[ $(cat "$FAKE/ct/280/listening") == PORT=3100 && $(setting FREELLMAPI_PORT) == 3100 &&
   $(cat "$PVE_ETC/firewall/280.fw") == *'-dport 3100 -log nolog # open-smart-router freellmapi-web'* &&
   $(cat "$PVE_ETC/firewall/280.fw") == *'operator rule'* &&
   $(head -n 1 "$FAKE/router-call") == 'set-freellmapi http://192.0.2.80:3100 --apply' ]] || fail 'port change did not update all endpoints'
host CT_ID=280 FREELLMAPI_ACCESS_CIDR=198.51.100.0/24 --reconfigure; ok 'access change'
[[ $(cat "$PVE_ETC/firewall/280.fw") == *'IN ACCEPT -source 198.51.100.0/24 -p tcp -dport 3100'* &&
   $(cat "$PVE_ETC/firewall/280.fw") == *'operator rule'* ]] || fail 'access-only change did not update the firewall'
before=$(env_file); fw_before=$(cat "$PVE_ETC/firewall/280.fw")
host CT_ID=280 FREELLMAPI_PORT=3200 FAKE_UNHEALTHY_PORT=3200 --reconfigure; bad 'failed port change'
[[ $(cat "$FAKE/ct/280/listening") == PORT=3100 && $(setting FREELLMAPI_PORT) == 3100 &&
   $(env_file) == "$before" && $(cat "$PVE_ETC/firewall/280.fw") == "$fw_before" && -z $(ls -A "$tmp/host/state") ]] || fail 'settings rollback did not restore port and firewall'
sed -i '/^ROUTER_CT_ID=/d' "$data/osr-target/settings"
host CT_ID=280 FREELLMAPI_PORT=3200 --reconfigure; ok 'port change with an older settings record'
[[ $(head -n 1 "$FAKE/router-call") == 'set-freellmapi http://192.0.2.80:3200 --apply' &&
   $(setting ROUTER_CT_ID) == 210 ]] || fail 'the router was not found from the older firewall rule'
pass 'port and access changes update all endpoints; a failed restart restores settings'
fresh; create ROUTER_CT_ID=none; ok 'create for settings'; set_data

# Settings only: an operator's own line and the key stay.
printf 'HTTPS_PROXY=http://proxy.example:3128\n' >> "$data/osr-target/freellmapi.env"
before=$(grep '^ENCRYPTION_KEY=' "$data/osr-target/freellmapi.env"); key=$(cat "$data/freeapi.db")
: > "$FAKE/calls"
host CT_ID=280 FREELLMAPI_RATE_LIMIT_RPM=0 --reconfigure; ok 'a settings change'
[[ $(env_file) == *'PROXY_RATE_LIMIT_RPM=0'* && $(env_file) == *'HTTPS_PROXY=http://proxy.example:3128'* &&
   $(grep '^ENCRYPTION_KEY=' "$data/osr-target/freellmapi.env") == "$before" && $(grep -c '^PORT=' "$data/osr-target/freellmapi.env") == 1 ]] || fail 'the env file after a settings change'
[[ $(setting FREELLMAPI_RATE_LIMIT_RPM) == 0 && $(conf) == *"entrypoint: $image_entrypoint"* && -e $FAKE/ct/280/running ]] || fail 'record, entrypoint or state'
[[ $(calls) != *'pct destroy'* && $(calls) != *vzdump* && $(calls) != *skopeo* ]] || fail 'a settings change replaced the CT'
[[ $(env_file) != *FREEAPI_CONFIG_PATH* ]] || fail 'the bootstrap came back'
pass '--reconfigure with a new setting restarts the same image and keeps the key and added lines'

sed -i 's/^entrypoint: .*/entrypoint: sleep infinity/' "$PVE_ETC/lxc/280.conf"
host CT_ID=280 --reconfigure; bad 'an interrupted CT'; has 'A run was interrupted'
sed -i "s|^entrypoint: .*|entrypoint: $image_entrypoint|" "$PVE_ETC/lxc/280.conf"
pass 'a CT left with the waiting entrypoint is named, not changed'

# A new release: the CT is replaced; data, settings, address and rules stay.
upgrade_ready() {
    fresh; create; ok 'create'; set_data
    printf 'cores: 4\n' >> "$PVE_ETC/lxc/280.conf"; sed -i 's/^memory: .*/memory: 2048/' "$PVE_ETC/lxc/280.conf"
    printf 'HTTPS_PROXY=http://proxy.example:3128\n' >> "$data/osr-target/freellmapi.env"
    printf 'provider keys\n' > "$data/freeapi.db-wal"
    key=$(cat "$data/freeapi.db"); env_before=$(env_file); fw_before=$(cat "$PVE_ETC/firewall/280.fw")
    net_before=$(grep '^net0:' "$PVE_ETC/lxc/280.conf"); sed -i '/^cores: 2$/d' "$PVE_ETC/lxc/280.conf"
    : > "$FAKE/calls"
}
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 --reconfigure; ok 'an upgrade'
[[ $(cat "$FAKE/ct/280/image") == v0.99.1 && -e $FAKE/ct/280/running ]] || fail 'the new image does not run'
[[ $(cat "$data/freeapi.db") == "$key" && $(cat "$data/freeapi.db-wal") == 'provider keys' && $(env_file) == "$env_before" ]] || fail 'the data did not survive'
[[ $(cat "$PVE_ETC/firewall/280.fw") == "$fw_before" && $(grep '^net0:' "$PVE_ETC/lxc/280.conf") == "$net_before" ]] || fail 'firewall or network device changed'
[[ $(conf) == *'cores: 4'* && $(conf) == *'memory: 2048'* && $(conf) == *'hostname: freellmapi'* && $(conf) == *'size=4G'* && $(conf) == *'mp=/app/server/data,backup=1,size=2G'* ]] || fail 'CT options were not kept'
[[ $(conf) == *"entrypoint: $image_entrypoint"* && $(conf) == *'tags: ai;ai-model;osr-target;freellmapi'* ]] || fail 'entrypoint or tags'
[[ $(setting FREELLMAPI_VERSION) == v0.99.1 && $(setting FREELLMAPI_VERSION_SOURCE) == explicit ]] || fail 'the settings record after the upgrade'
[[ -z $(ls -A "$tmp/host/state") ]] || fail 'the backup and the data copy were left behind'
[[ $(grep -o '^\(skopeo copy\|pct stop\|vzdump\|pct destroy\|pct create\)' "$FAKE/calls" | paste -sd'|') == 'skopeo copy|pct stop|vzdump|pct stop|pct destroy|pct create|pct stop' ]] ||
    fail "order: $(grep -o '^\(skopeo copy\|pct stop\|vzdump\|pct destroy\|pct create\)' "$FAKE/calls" | paste -sd'|')"
has 'now runs v0.99.1'; lacks "$key"
[[ $(env_file) != *FREEAPI_CONFIG_PATH* && ! -e $data/osr-target/bootstrap.json ]] || fail 'the upgrade wrote a bootstrap file'
[[ $(calls) == *'vzdump 280 --mode stop --compress zstd --dumpdir '*' --tmpdir /var/tmp'* ]] || fail 'vzdump was not given a temporary directory the CT root can reach'
[[ $(stat -c %a "$tmp/host/state") == 700 ]] || fail 'the backup directory is no longer root-only'
pass '--reconfigure to a new release: image pulled first, backup, new CT, same data, key, options and rules'

: > "$FAKE/calls"
host CT_ID=280 --reconfigure; ok 'reconfigure after an explicit release'
has 'runs v0.99.1 and answers: nothing to do'; [[ $(calls) != *'pct destroy'* ]] || fail 'an explicit release was replaced by the default'
pass 'a release chosen for the CT stays until another is named'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_UNHEALTHY=v0.99.2 --reconfigure; bad 'an unhealthy release'
has 'did not answer /api/ping'; has "is running FreeLLMAPI $default_version again"
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running && $(cat "$data/freeapi.db") == "$key" && $(env_file) == "$env_before" ]] || fail 'the old CT was not restored'
[[ $(cat "$PVE_ETC/firewall/280.fw") == "$fw_before" && $(conf) == *'cores: 4'* && $(conf) == *"entrypoint: $image_entrypoint"* ]] || fail 'the restored CT differs'
[[ $(setting FREELLMAPI_VERSION) == "$default_version" && $(ls -A "$tmp/host/state") == 280.rolled-back-* ]] || fail 'record or kept backup after rollback'
kept=$(echo "$tmp"/host/state/280.rolled-back-*)
[[ -s $(echo "$kept"/vzdump-lxc-280-*.tar.zst) && ! -e $kept/data.tar && $(stat -c %a "$kept") == 700 ]] || fail 'the kept backup is missing, has the data copy, or is not root-only'
has "The backup is kept in $kept"
host CT_ID=280 --reconfigure; ok 'a run after a rollback'
has 'nothing to do'
pass 'after a rollback the backup is kept, root-only, and does not block the next run'
[[ $(calls) == *"pct restore 280 $tmp/host/state/280/vzdump-lxc-280-"*' --storage local-lvm'* ]] || fail 'pct restore was not used'
pass 'a release that does not become healthy is rolled back from the backup'

# The CT on another cluster node, as tools/upgrade-all.sh sees it from this one
# (pct is tools/pct-cluster.sh): this node's vzdump would skip it and succeed.
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 FAKE_CT_NODE=pve2 --reconfigure; ok 'an upgrade of a CT on another node'
[[ $(cat "$FAKE/ct/280/image") == v0.99.1 && -e $FAKE/ct/280/running && $(cat "$FAKE/ct/280/node") == pve2 ]] ||
    fail 'the new CT does not run on the node the old one was on'
[[ $(cat "$data/freeapi.db") == "$key" && $(cat "$data/freeapi.db-wal") == 'provider keys' && $(env_file) == "$env_before" ]] ||
    fail 'the data did not survive on the other node'
[[ $(cat "$PVE_ETC/firewall/280.fw") == "$fw_before" && $(conf) == *'cores: 4'* ]] || fail 'firewall or options changed on the other node'
has 'pve2 (backup, template and new CT handled there'; has 'Copying the template'; has 'Backing up CT 280 on node pve2'
remote_template=$FAKE/node-pve2/template/cache/freellmapi_v0.99.1.tar
cmp -s "$remote_template" "$FAKE/template/cache/freellmapi_v0.99.1.tar" && [[ $(stat -c %a "$remote_template") == 644 ]] ||
    fail 'the template was not copied to the node, readable'
[[ $(calls) == *'vzdump 280 --mode stop --stdout 1 --tmpdir /var/tmp'* && $(calls) == *$'\nzstd -q\n'* && $(calls) != *'--dumpdir'* ]] ||
    fail 'the backup was not taken on the CT'"'"'s node'
[[ $(calls) != *'skip external'* && -z $(ls -A "$tmp/host/state") ]] || fail 'the backup was left behind'
pass 'a CT on another node: template copied there, backup taken there and streamed here, new CT made there'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_UNHEALTHY=v0.99.2 FAKE_CT_NODE=pve2 --reconfigure; bad 'an unhealthy release on another node'
has "is running FreeLLMAPI $default_version again"
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && $(cat "$FAKE/ct/280/node") == pve2 && -e $FAKE/ct/280/running ]] ||
    fail 'the CT was not restored on its node'
[[ $(cat "$data/freeapi.db") == "$key" && $(env_file) == "$env_before" ]] || fail 'the restored CT lost its data'
[[ $(calls) == *'pct restore 280 /var/tmp/osr-freellmapi.'*'/vzdump-lxc-280-'*'.tar.zst --storage local-lvm'* ]] ||
    fail 'the backup was not restored from a copy on the node'
[[ -z $(ls -d /var/tmp/osr-freellmapi.* 2>/dev/null) ]] || fail 'the copy of the backup was left on the node'
[[ -s $(echo "$tmp"/host/state/280.rolled-back-*/vzdump-lxc-280-*.tar.zst) ]] || fail 'the backup is not kept here'
pass 'a CT on another node that fails is restored there from the backup kept here'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 FAKE_CT_NODE=pve2 FAKE_VZDUMP_FAILS=1 --reconfigure; bad 'a failed backup on another node'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running && $(calls) != *'pct destroy'* ]] ||
    fail 'the CT was changed although no backup was taken'
[[ -z $(ls -A "$tmp/host/state") ]] || fail 'an empty backup was left behind'
pass 'a backup that fails on another node leaves the CT as it was'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 FAKE_CT_NODE=pve2 FAKE_VZDUMP_SKIPS=1 --reconfigure; bad 'a skipped backup on another node'
has 'lacks its CT configuration'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running && $(calls) != *'pct destroy'* ]] ||
    fail 'the CT was changed after vzdump returned an empty stream'
[[ -z $(ls -A "$tmp/host/state") ]] || fail 'the rejected backup was left behind'
pass 'a successful but empty remote backup is rejected before the CT is destroyed'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 FAKE_BARE_CONF=1 --reconfigure; bad 'a backup whose configuration pct restore would not find'
has 'lacks its CT configuration'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running && $(calls) != *'pct destroy'* ]] ||
    fail 'the CT was replaced with a backup pct restore cannot read'
pass 'the backup must hold ./etc/vzdump/pct.conf, the name pct restore looks for'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 FAKE_CT_NODE=pve2 FAKE_NODE_LACKS=zstd --reconfigure; bad 'a node without zstd'
has 'Node pve2, which holds CT 280, lacks vzdump, zstd or pvesm'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running ]] || fail 'the CT was changed on a node without zstd'
[[ $(calls) != *'pct stop'* && $(calls) != *'skopeo copy'* && -z $(ls -A "$tmp/host/state") ]] ||
    fail 'the run went on before finding the node unready'
pass 'a node that lacks a needed command is found before anything changes'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_UNHEALTHY=v0.99.2 FAKE_CT_NODE=pve2 FAKE_RESTORE_FAILS=1 --reconfigure
bad 'a failed restore on another node'
has 'pct restore failed on node pve2. The backup is kept on this node:'; has 'Copy it to node pve2 and restore it there'
lacks '(umask 022; pct restore 280'
[[ -s $(echo "$tmp"/host/state/280/vzdump-lxc-280-*.tar.zst) ]] || fail 'the backup was not kept after a failed remote restore'
pass 'a failed restore on another node says to copy the backup there first'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_REKEY=v0.99.2 --reconfigure; bad 'a release with another key'
has 'the unified API key is not the one the router has'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running && $(cat "$data/freeapi.db") == "$key" ]] || fail 'no rollback after the key changed'
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_START_FAILS=v0.99.2 --reconfigure; bad 'a release that exits'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running ]] || fail 'no rollback after the server exited'
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_UNHEALTHY=v0.99.2 FAKE_RESTORE_FAILS=1 --reconfigure; bad 'a failed restore'
has 'The backup is kept:'; [[ -s $(echo "$tmp"/host/state/280/vzdump-lxc-280-*.tar.zst) ]] || fail 'the backup was removed after a failed restore'
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 --reconfigure; bad 'a run after a failed restore'
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_UNHEALTHY="$default_version v0.99.2" --reconfigure; bad 'a rollback to an unhealthy release'
has "The restored CT 280 did not become healthy either. The backup is kept: $tmp/host/state/280/vzdump-lxc-280-"
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -s $(echo "$tmp"/host/state/280/vzdump-lxc-280-*.tar.zst) ]] || fail 'the old CT or its backup is missing'
pass 'a server that exits is rolled back too; a failed restore keeps the backup'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_VZDUMP_FAILS=1 --reconfigure; bad 'a failed backup'
[[ $(calls) != *'pct destroy'* && $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running &&
   $(conf) == *"entrypoint: $image_entrypoint"* && -z $(ls -A "$tmp/host/state") ]] || fail 'a failed backup did not leave the old CT running'
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_REVISION=1111111111111111111111111111111111111111 --reconfigure; ok 'another release has no tested commit'
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_REGISTRY_DOWN=1 --reconfigure; bad 'registry down'
[[ $(calls) != *'pct stop'* && -e $FAKE/ct/280/running ]] || fail 'the CT was stopped before the image was there'
upgrade_ready; mkdir -p "$tmp/host/state/280"
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 --reconfigure; bad 'a leftover backup directory'
has 'did not finish'; [[ $(calls) != *'pct stop'* ]] || fail 'the CT was stopped despite a leftover'
upgrade_ready; sed -i 's/^mp0: local-lvm:/mp0: other:/' "$PVE_ETC/lxc/280.conf"
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 --reconfigure; bad 'two storages'; has 'both on one storage'
pass 'a failed backup, an unreachable registry, a leftover and an unusual CT stop before the CT is destroyed'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_DESTROY_FAILS=1 --reconfigure; bad 'a failed destroy'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && -e $FAKE/ct/280/running && $(conf) == *"entrypoint: $image_entrypoint"* ]] || fail 'the old CT is gone or down'
[[ $(calls) != *'pct restore'* && $(cat "$data/freeapi.db") == "$key" ]] || fail 'a restore ran over a CT that still existed'
pass 'a destroy that fails leaves the old CT running'


# Network changes the settings path must carry to the firewall and the router,
# and their rollbacks.
fresh; create; ok 'create for review'; set_data
key=$(cat "$data/freeapi.db")
host CT_ID=280 FREELLMAPI_PORT=3300 FAKE_ROUTER_REFUSES=1 --reconfigure; bad 'a router that refuses a port change'
[[ $(cat "$FAKE/ct/280/listening") == PORT=3001 && $(setting FREELLMAPI_PORT) == 3001 &&
   $(cat "$PVE_ETC/firewall/280.fw") == *'-dport 3001 -log nolog # open-smart-router freellmapi-web'* &&
   $(cat "$PVE_ETC/firewall/280.fw") != *3300* && -z $(ls -A "$tmp/host/state") ]] || fail 'refused registration did not restore port and firewall'
pass 'a refused registration rolls the settings and firewall back'

sed -i 's|ip=192.0.2.10/24|ip=192.0.2.11/24|' "$PVE_ETC/lxc/210.conf"
rm -f "$FAKE/router-call"
host CT_ID=280 --reconfigure; ok 'router readdressed'
[[ $(cat "$PVE_ETC/firewall/280.fw") == *'-source 192.0.2.11/32 -p tcp -dport 3001'* &&
   $(cat "$PVE_ETC/firewall/280.fw") != *192.0.2.10/32* && -s $FAKE/router-call ]] || fail 'a readdressed router was not admitted and given the endpoint'
pass 'a readdressed router is admitted and registered again'

mkdir -p "$FAKE/ct/211"; : > "$FAKE/ct/211/running"
printf 'tags: ai\nnet0: name=eth0,bridge=vmbr0,ip=192.0.2.12/24,gw=192.0.2.1\n' > "$PVE_ETC/lxc/211.conf"
rm -f "$FAKE/router-call"
host CT_ID=280 ROUTER_CT_ID=211 --reconfigure; ok 'another router'
[[ $(cat "$PVE_ETC/firewall/280.fw") == *'-source 192.0.2.12/32'* && $(setting ROUTER_CT_ID) == 211 && -s $FAKE/router-call ]] || fail 'switching routers'
pass 'switching the router CT updates rule, record and registration'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 FREELLMAPI_PORT=3400 --reconfigure; ok 'release and port together'
[[ $(cat "$FAKE/ct/280/image") == v0.99.1 && $(cat "$FAKE/ct/280/listening") == PORT=3400 &&
   $(cat "$PVE_ETC/firewall/280.fw") == *'-dport 3400 -log nolog # open-smart-router freellmapi-web'* &&
   $(head -n 1 "$FAKE/router-call") == 'set-freellmapi http://192.0.2.80:3400 --apply' ]] || fail 'release and port change together'
pass 'a new release with a new port updates firewall and router'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FREELLMAPI_PORT=3400 FAKE_UNHEALTHY=v0.99.2 --reconfigure; bad 'release and port, unhealthy'
has "is running FreeLLMAPI $default_version again"
[[ $(cat "$FAKE/ct/280/listening") == PORT=3001 && $(cat "$PVE_ETC/firewall/280.fw") == "$fw_before" ]] || fail 'rollback after release and port change'
pass 'a failed release with a new port restores the old CT on its old port'

upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FREELLMAPI_PORT=3400 FAKE_ROUTER_REFUSES=1 --reconfigure; bad 'release and port, router refuses'
[[ $(cat "$FAKE/ct/280/image") == "$default_version" && $(cat "$FAKE/ct/280/listening") == PORT=3001 ]] || fail 'refused registration after replacement was not rolled back'
pass 'a refused registration after a replacement restores the backup'


# keep (tools/upgrade-all.sh keeping a CT's release): no replacement, and the
# CT still follows the tested release afterwards.
fresh; create; ok 'create for keep'; set_data
sed -i 's/^FREELLMAPI_VERSION=.*/FREELLMAPI_VERSION=v0.15.0/' "$data/osr-target/settings"
: > "$FAKE/calls"
host CT_ID=280 FREELLMAPI_VERSION=keep --reconfigure; ok 'keep'
has 'runs v0.15.0 and answers: nothing to do'
[[ $(calls) != *vzdump* && $(calls) != *'pct destroy'* && $(setting FREELLMAPI_VERSION_SOURCE) == default ]] || fail 'keep replaced the CT or pinned it'
host CT_ID=280 FREELLMAPI_VERSION=keep FREELLMAPI_RATE_LIMIT_RPM=0 --reconfigure; ok 'keep with a setting'
[[ $(setting FREELLMAPI_VERSION) == v0.15.0 && $(setting FREELLMAPI_VERSION_SOURCE) == default && $(calls) != *vzdump* ]] || fail 'keep with a setting changed the release or its source'
: > "$FAKE/calls"
host CT_ID=280 --reconfigure; ok 'following the tested release again'
[[ $(calls) == *vzdump* && $(setting FREELLMAPI_VERSION) == "$default_version" ]] || fail 'a kept CT no longer follows the tested release'
host CT_ID=280 FREELLMAPI_VERSION=v0.99.1 --reconfigure; ok 'an explicit release'
host CT_ID=280 FREELLMAPI_VERSION=keep --reconfigure; ok 'keep on an explicit release'
[[ $(setting FREELLMAPI_VERSION) == v0.99.1 && $(setting FREELLMAPI_VERSION_SOURCE) == explicit ]] || fail 'keep dropped an explicit release'
host "${common[@]}" FREELLMAPI_VERSION=keep CT_ID=281 IP_CIDR=192.0.2.81/24 ROUTER_CT_ID=none; bad 'keep on create'
has 'FREELLMAPI_VERSION must be a release tag'
pass 'keep stays on the CT release and its source; a CT following the pin still follows it later'

# pct create refusing the new image: one rollback, in the script itself. Under
# set -E the subshell around pct create inherits the ERR trap; a rollback run
# there restored the CT and deleted the backup, then the script's own rollback
# destroyed the restored CT and found no backup (CT 163, 2026-11-17).
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_CREATE_FAILS=v0.99.2 --reconfigure; bad 'pct create refused'
has 'pct create failed for CT 280'; has "is running FreeLLMAPI $default_version again"
[[ $(grep -c '^pct restore 280' "$FAKE/calls") == 1 && $(grep -c '^pct destroy 280' "$FAKE/calls") == 1 ]] || fail 'the rollback ran more than once'
[[ -f $PVE_ETC/lxc/280.conf && -e $FAKE/ct/280/running && $(cat "$FAKE/ct/280/image") == "$default_version" &&
   $(cat "$data/freeapi.db") == "$key" && $(cat "$PVE_ETC/firewall/280.fw") == "$fw_before" ]] || fail 'the old CT is not back with its data and firewall'
[[ -s $(echo "$tmp"/host/state/280.rolled-back-*/vzdump-lxc-280-*.tar.zst) ]] || fail 'the backup was not kept'
pass 'a refused pct create is rolled back once, and the CT and its backup survive'

# A template pulled earlier under umask 077 (root-only) is made readable before
# pct create, which unpacks it as the CT's mapped root (CT 163, 2026-11-17).
upgrade_ready
printf 'revision=%s\n' "$commit" > "$FAKE/template/cache/freellmapi_v0.99.3.tar"; chmod 0600 "$FAKE/template/cache/freellmapi_v0.99.3.tar"
host CT_ID=280 FREELLMAPI_VERSION=v0.99.3 FAKE_REVISION="$commit" --reconfigure; ok 'an existing root-only template'
has 'Using the existing template'
[[ $(stat -c %a "$FAKE/template/cache/freellmapi_v0.99.3.tar") == 644 && $(cat "$FAKE/ct/280/image") == v0.99.3 ]] || fail 'the root-only template was not made readable'
[[ $(stat -c %a "$FAKE/template/cache/freellmapi_${default_version}.tar") == 644 ]] || fail 'a template pulled under umask 077 is not readable'
pass 'templates are readable for pct create, whether pulled now or earlier under umask 077'

# A rollback never destroys a CT when its backup is missing.
upgrade_ready
host CT_ID=280 FREELLMAPI_VERSION=v0.99.2 FAKE_UNHEALTHY=v0.99.2 FAKE_DUMP_VANISHES=1 --reconfigure; bad 'a vanished backup'
has 'is missing: CT 280 is left as it is'
[[ -f $PVE_ETC/lxc/280.conf && $(grep -c '^pct destroy 280' "$FAKE/calls") == 1 ]] || fail 'a CT was destroyed without a backup to restore'
pass 'a rollback without its backup leaves the CT alone'

# A firewall file sync_firewall cannot rewrite stops the run before the CT is touched.
fresh; create; ok 'create for [RULES]'; set_data
sed -i '/^\[RULES\]$/d' "$PVE_ETC/firewall/280.fw"
: > "$FAKE/calls"
host CT_ID=280 FREELLMAPI_PORT=3100 --reconfigure; bad 'no [RULES]'
has 'has no [RULES] section'
[[ $(calls) != *'pct stop'* && $(cat "$FAKE/ct/280/listening") == PORT=3001 && $(setting FREELLMAPI_PORT) == 3001 ]] || fail 'the CT was touched without a usable firewall file'
pass 'a firewall file without [RULES] stops the run before the CT is stopped'

printf 'passed %s\n' "$passed"
