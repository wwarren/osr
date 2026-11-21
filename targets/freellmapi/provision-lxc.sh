#!/usr/bin/env bash
# Run on the Proxmox host, never inside a CT.
#
# FreeLLMAPI (https://github.com/tashfeenahmed/freellmapi) is published as a
# container image only. Proxmox VE 9.1 turns such an image into an LXC by
# itself ("application container", a technology preview there), so this target
# has no guest installer: the CT's root file system is the image, its init is
# the image's entrypoint, and everything that must outlive an image change (the
# database, the encryption key, the settings record) is on a second volume
# mounted at the image's data directory.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"

# The tested release: its tag, the commit the tag names (the image carries it
# as org.opencontainers.image.revision) and, when known, the registry digest
# `skopeo inspect --format '{{.Digest}}' docker://IMAGE:VERSION` prints.
# tools/upgrade-all.sh reads DEFAULT_FREELLMAPI_VERSION; CI checks the commit
# (targets/freellmapi/upstream-commit.txt) against this file.
FREELLMAPI_IMAGE_REPO=ghcr.io/tashfeenahmed/freellmapi
DEFAULT_FREELLMAPI_VERSION=v0.16.31
DEFAULT_FREELLMAPI_DIGEST=

FW_TAG='open-smart-router freellmapi'
CT_DESCRIPTION='FreeLLMAPI for Open Smart Router'
GUEST_DATA=/app/server/data
GUEST_DIR=$GUEST_DATA/osr-target
IMAGE_ENTRYPOINT='/usr/local/bin/docker-entrypoint.sh node server/dist/index.js'
IMAGE_ENTRYPOINT_RE='^(/usr/bin/env PORT=[1-9][0-9]{0,4} )?/usr/local/bin/docker-entrypoint\.sh node server/dist/index\.js$'
MAINTENANCE_ENTRYPOINT='sleep infinity'

usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run]
       bash provision-lxc.sh --reconfigure [--dry-run]
       bash provision-lxc.sh --register

Creates an unprivileged Proxmox VE LXC directly from the FreeLLMAPI container
image (no Docker or Podman in the CT) and starts it. FreeLLMAPI puts the free
tiers of many cloud providers behind one OpenAI-compatible endpoint and one
key. OSR offers its models as freellmapi/<id>, used only when a request names
one: prompts sent to them leave your network for those providers.

Needs Proxmox VE 9.1 or later (OCI images as CT templates) and skopeo, which
Proxmox uses for the same purpose.

The installer asks for the CT ID (default: the cluster's next free ID), the
storage, a static IP/CIDR and its gateway. Preset CT_ID, STORAGE, IP_CIDR and
GATEWAY for unattended runs.

Optional: CT_HOSTNAME=freellmapi, BRIDGE=vmbr0, CORES=2, MEMORY_MB=1024,
          SWAP_MB=0, ROOTFS_GB=4 (the image), DATA_GB=2 (database and keys),
          ONBOOT=1, NAMESERVER, VLAN_TAG,
          TEMPLATE_STORAGE=local (a storage for container templates),
          FREELLMAPI_VERSION=<the tested release tag> (with --reconfigure,
                    keep: stay on the CT's release, as tools/upgrade-all.sh
                    passes when it keeps it),
          FREELLMAPI_DIGEST=<sha256:... the registry digest of that tag>,
          FREELLMAPI_PORT=3001,
          FREELLMAPI_ACCESS_CIDR=<the CT's network> (who may open the
                    dashboard and API; the router is always admitted),
          FREELLMAPI_RATE_LIMIT_RPM=600 (requests per minute per client
                    address; the router is one client; 0 turns it off),
          FREELLMAPI_ADMIN_EMAIL=admin@osr.local,
          FREELLMAPI_ADMIN_PASSWORD=<asked; empty: one is generated in the CT>,
          FREELLMAPI_READY_TIMEOUT=120,
          ROUTER_CT_ID=<the router CT; default the one tagged osr-router>
                    (registers the endpoint and its key there; "none" skips).

--reconfigure  CT_ID names an existing FreeLLMAPI CT. Its settings are kept.
               When the wanted release differs from the CT's, the CT is
               replaced by one made from the new image, with the same ID,
               address and data; a failed start restores the old CT from a
               backup taken first. Nothing happens when nothing changed.
--register     Hand the endpoint and its key to the router again (after the
               key was regenerated in the dashboard, or for a new router).
--dry-run      Validate the settings and print the plan.

Provider API keys are added in the dashboard (http://<CT address>:3001).
USAGE
}

run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
note() { printf '%s\n' "$*" >&2; }
# set -E hands the ERR trap to every subshell and command substitution. A
# rollback run there would act on the CT, then the subshell's failure would
# run it again in the script: so trap actions run only in the script itself,
# and a subshell that fails just reports it.
main_shell() { [[ $BASHPID == "$$" ]]; }
positive_int() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
valid_storage_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_version() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_digest() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }
valid_optional_digest() { [[ -z $1 ]] || valid_digest "$1"; }
valid_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] && (( ${#1} <= 254 )); }
# The dashboard wants 8 characters or more; control characters would break
# the one-line hand-over to the CT.
valid_password() { (( ${#1} >= 8 && ${#1} <= 128 )) && [[ $1 != *[[:cntrl:]]* ]]; }
valid_optional_password() { [[ -z $1 ]] || valid_password "$1"; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
valid_router_ct() { [[ $1 == none ]] || pve_valid_ct_id "$1"; }

# network_of CIDR: the network a.b.c.d/nn lies in (192.0.2.75/24 -> 192.0.2.0/24).
network_of() {
    local a b c d prefix mask ip
    IFS=./ read -r a b c d prefix <<< "$1"
    ip=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    mask=$(( prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff ))
    ip=$(( ip & mask ))
    printf '%d.%d.%d.%d/%d\n' $(( ip >> 24 )) $(( (ip >> 16) & 255 )) $(( (ip >> 8) & 255 )) $(( ip & 255 )) "$prefix"
}

# firewall_config ACCESS_CIDR PORT [ROUTER_IP]: the CT's firewall file. Inbound:
# the access range and the router to the one port. Outbound stays open:
# FreeLLMAPI calls whichever providers have a key.
firewall_config() {
    printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\n\n[RULES]\n'
    printf 'IN ACCEPT -source %s -p tcp -dport %s -log nolog # %s-web\n' "$1" "$2" "$FW_TAG"
    [[ -z ${3:-} ]] || printf 'IN ACCEPT -source %s/32 -p tcp -dport %s -log nolog # %s-router\n' "$3" "$2" "$FW_TAG"
}
# fw_access FILE: the access range in a FreeLLMAPI firewall file.
fw_access() {
    sed -nE "s/^IN ACCEPT -source ([0-9.]+\/[0-9]+) -p tcp -dport [0-9]+ -log nolog # ${FW_TAG}-web\$/\1/p" "$1" 2>/dev/null | head -n 1
}
fw_router_ip() {
    sed -nE "s/^IN ACCEPT -source ([0-9.]+)\/32 -p tcp -dport [0-9]+ -log nolog # ${FW_TAG}-router\$/\1/p" "$1" 2>/dev/null | head -n 1
}
sync_firewall() {
    if (( dry_run )); then printf '+ update FreeLLMAPI rules in %s\n' "$firewall_file"; return; fi
    grep -qxF '[RULES]' "$firewall_file" || die "Missing [RULES] in $firewall_file."
    # Keep operator-added rules and options; replace only rules owned by us.
    awk -v access="$FREELLMAPI_ACCESS_CIDR" -v port="$FREELLMAPI_PORT" -v router="$router_ip" -v tag="$FW_TAG" '
        $0 == "[RULES]" {
            print
            print "IN ACCEPT -source " access " -p tcp -dport " port " -log nolog # " tag "-web"
            if (router != "") print "IN ACCEPT -source " router "/32 -p tcp -dport " port " -log nolog # " tag "-router"
            next
        }
        index($0, " # " tag "-web") || index($0, " # " tag "-router") { next }
        { print }
    ' "$firewall_file" > "$firewall_file.new"
    mv -- "$firewall_file.new" "$firewall_file"
}

# --- The image ---------------------------------------------------------------

image_ref() { printf '%s:%s\n' "$FREELLMAPI_IMAGE_REPO" "$1"; }
template_volume() { printf '%s:vztmpl/freellmapi_%s.tar\n' "$TEMPLATE_STORAGE" "$1"; }
# pinned_commit: the commit of the tested release (upstream-commit.txt).
pinned_commit() { sed -n '/^[0-9a-f]\{40\}$/p' "$source_dir/upstream-commit.txt" 2>/dev/null | head -n 1; }

# ensure_template VERSION DIGEST: the image of VERSION as a CT template, pulled
# when it is not there yet. Sets image_digest (the registry's digest of the
# tag) and image_revision (the commit the image was built from). A pinned
# DIGEST must be what the registry serves, and for the tested release the image
# must name the tested commit, so a moved tag is refused before any CT changes.
image_digest='' image_revision=''
ensure_template() {
    local version=$1 want=$2 ref volume path tmp expect
    ref=$(image_ref "$version"); volume=$(template_volume "$version")
    if (( dry_run )); then
        image_digest=${want:-<digest of $ref>}
        printf '+ skopeo inspect docker://%s (its digest%s and revision label are checked)\n' "$ref" "${want:+ $want}"
        printf '+ skopeo copy docker://%s@%s oci-archive:<%s> (unless that template exists)\n' "$FREELLMAPI_IMAGE_REPO" "$image_digest" "$volume"
        return 0
    fi
    image_digest=$(skopeo inspect --format '{{.Digest}}' "docker://$ref") ||
        die "Could not read $ref from the registry (skopeo inspect). Check this host's access to ghcr.io."
    valid_digest "$image_digest" || die "The registry gave no usable digest for $ref: $image_digest"
    [[ -z $want || $image_digest == "$want" ]] ||
        die "$ref is $image_digest in the registry, not the pinned $want. The tag was moved, or FREELLMAPI_DIGEST is for another release."
    image_revision=$(skopeo inspect --format '{{index .Labels "org.opencontainers.image.revision"}}' "docker://$ref") || image_revision=''
    expect=''
    [[ $version != "$DEFAULT_FREELLMAPI_VERSION" ]] || expect=$(pinned_commit)
    if [[ -n $expect && $image_revision != "$expect" ]]; then
        die "$ref says it was built from commit ${image_revision:-(none)}, not the tested $expect."
    fi
    path=$(pvesm path "$volume") || die "Storage $TEMPLATE_STORAGE cannot hold container templates: $volume"
    if [[ -f $path ]]; then
        tmp=$(skopeo inspect --format '{{index .Labels "org.opencontainers.image.revision"}}' "oci-archive:$path") ||
            die "The existing template $volume is not a readable OCI archive. Remove it and run again."
        [[ -z $image_revision || $tmp == "$image_revision" ]] ||
            die "The existing template $volume was built from ${tmp:-(none)}, not $image_revision. Remove it and run again."
        # pct create reads the image inside the CT's user namespace, as its
        # mapped root: a template pulled under umask 077 (tools/upgrade-all.sh)
        # is unreadable there. It is a public image, so it is made readable.
        chmod 0644 -- "$path" || die "Could not make $volume readable for pct create."
        note "Using the existing template $volume."
        return 0
    fi
    [[ -d ${path%/*} ]] || die "Template directory is missing: ${path%/*}"
    tmp="$path.tmp.$$"
    note "Pulling $ref ($image_digest) to $volume."
    if ! (umask 022; skopeo copy "docker://$FREELLMAPI_IMAGE_REPO@$image_digest" "oci-archive:$tmp"); then
        rm -f -- "$tmp"
        die "Could not pull $ref."
    fi
    # Readable by the CT's mapped root, which unpacks it (see above).
    chmod 0644 -- "$tmp" && mv -- "$tmp" "$path" || { rm -f -- "$tmp"; die "Could not store $volume."; }
}

# --- The CT's node ----------------------------------------------------------
# Under tools/upgrade-all.sh, pct is tools/pct-cluster.sh and the CT may live
# on another node of the cluster: pct reaches it there, but vzdump, pvesm and
# a pct create or restore (of a CT that does not exist at that moment) act on
# the node they run on. vzdump even succeeds with no backup for a guest of
# another node ("skip external VMs"). So the replacement runs them on the CT's
# node (pct --osr-on-node) and streams the backup to and from this one. With
# Proxmox's own pct (no --osr-node) the CT is on this node.
ct_node=''
find_ct_node() {
    local node here
    node=$(pct --osr-node "$CT_ID" 2>/dev/null) || node=''
    here=$(pct --osr-local-node 2>/dev/null) || here=''
    if [[ -n $node && -n $here && $node != "$here" ]]; then ct_node=$node; fi
    return 0
}
# on_ct_node COMMAND...: on the CT's node; stdin and stdout pass through.
on_ct_node() {
    if [[ -n $ct_node ]]; then pct --osr-on-node "$ct_node" "$@"; else "$@"; fi
}
# sync_template: the template of the release on the CT's node too, when that
# is another node (its template storage may be its own): copied from here
# unless the node already has the same file.
sync_template() {
    [[ -n $ct_node ]] || return 0
    local volume path remote sum
    volume=$(template_volume "$FREELLMAPI_VERSION")
    path=$(pvesm path "$volume") || die "Storage $TEMPLATE_STORAGE cannot hold container templates: $volume"
    remote=$(on_ct_node pvesm path "$volume" </dev/null) ||
        die "Storage $TEMPLATE_STORAGE on node $ct_node cannot hold container templates: $volume"
    sum=$(sha256sum < "$path") || die "Could not read $path."
    if [[ $(on_ct_node sh -c 'sha256sum < "$1"' sh "$remote" </dev/null 2>/dev/null) == "$sum" ]]; then
        note "Node $ct_node has the template $volume."
        return 0
    fi
    note "Copying the template $volume to node $ct_node (CT $CT_ID is there)."
    # Readable by the CT's mapped root, which unpacks it (see ensure_template).
    on_ct_node sh -c 'umask 022; [ -d "${1%/*}" ] || exit 1; t="$1.tmp.$$"
        if cat > "$t" && chmod 0644 "$t" && mv -f -- "$t" "$1"; then exit 0; fi
        rm -f -- "$t"; exit 1' sh "$remote" < "$path" ||
        die "Could not copy the template $volume to node $ct_node."
    [[ $(on_ct_node sh -c 'sha256sum < "$1"' sh "$remote" </dev/null) == "$sum" ]] ||
        die "The template $volume on node $ct_node differs from $path after the copy."
}

# --- Inside the CT -----------------------------------------------------------
# The image is Debian with Node: sh, coreutils, tar and setpriv are there. None
# of these scripts carries a secret; secrets travel on stdin.

guest() { pct exec "$CT_ID" -- "$@"; }

# GUEST_PREPARE PORT RATE bootstrap|keep: the data directory belongs to the
# image's node account (so its entrypoint leaves it alone); our directory in it
# is root's, readable by node. The env file keeps its ENCRYPTION_KEY and any
# line an operator added; ours are rewritten. /app/.env is where the server
# looks for it.
GUEST_PREPARE='set -eu
data=/app/server/data; dir=$data/osr-target; env=$dir/freellmapi.env
id node >/dev/null
chown node:node "$data"
install -d -o root -g node -m 0750 "$dir"
umask 027
{
  if [ -s "$env" ]; then
    grep -v -E "^(PORT|HOST|PROXY_RATE_LIMIT_RPM|FREELLMAPI_UPDATE_CHECK|FREEAPI_CONFIG_PATH)=" "$env" || true
  fi
  printf "PORT=%s\nHOST=0.0.0.0\nPROXY_RATE_LIMIT_RPM=%s\nFREELLMAPI_UPDATE_CHECK=off\n" "$1" "$2"
  [ "$3" != bootstrap ] || printf "FREEAPI_CONFIG_PATH=%s\n" "$dir/bootstrap.json"
} > "$env.new"
if ! grep -q -E "^ENCRYPTION_KEY=[0-9a-f]{64}$" "$env.new"; then
  if grep -q "^ENCRYPTION_KEY=" "$env.new"; then
    echo "ENCRYPTION_KEY in $env is not 64 hex digits; it is left for you to repair." >&2; rm -f "$env.new"; exit 1
  fi
  if [ -e "$data/freeapi.db" ] || [ -e "$data/freellmapi.db" ]; then
    echo "A database exists but $env has no ENCRYPTION_KEY: a new key could not read the stored provider keys." >&2
    rm -f "$env.new"; exit 1
  fi
  key=$(head -c 32 /dev/urandom | od -An -v -tx1 | tr -d " \n")
  [ "${#key}" -eq 64 ]
  printf "ENCRYPTION_KEY=%s\n" "$key" >> "$env.new"
fi
chown root:node "$env.new"; chmod 0640 "$env.new"; mv "$env.new" "$env"
ln -sfn "$env" /app/.env'

# GUEST_BOOTSTRAP: stdin is the admin e-mail, then the password (empty: one is
# generated and kept in initial-admin-password for root). FreeLLMAPI creates
# the account from this file before it listens, and only while it has none.
GUEST_BOOTSTRAP='const fs=require("fs"),c=require("crypto"),d=process.argv[1];
let [email,password]=fs.readFileSync(0,"utf8").split("\n");
if(!password){password=c.randomBytes(18).toString("base64url");
fs.writeFileSync(d+"/initial-admin-password",password+"\n",{mode:0o600});}
fs.writeFileSync(d+"/bootstrap.json",JSON.stringify({admin:{email,password}}),{mode:0o640});'

# GUEST_BOOTSTRAP_DONE: the account exists; the file with its password and the
# line naming it go.
GUEST_BOOTSTRAP_DONE='set -eu
dir=/app/server/data/osr-target; env=$dir/freellmapi.env
umask 027
grep -v "^FREEAPI_CONFIG_PATH=" "$env" > "$env.new"
chown root:node "$env.new"; chmod 0640 "$env.new"; mv "$env.new" "$env"
rm -f "$dir/bootstrap.json"'

GUEST_PING='fetch("http://127.0.0.1:"+process.argv[1]+"/api/ping").then(r=>r.json()).then(j=>process.exit(j.status==="ok"?0:1)).catch(()=>process.exit(1))'
GUEST_ACCOUNT='fetch("http://127.0.0.1:"+process.argv[1]+"/api/auth/status").then(r=>r.json()).then(j=>process.exit(j.needsSetup===false?0:1)).catch(()=>process.exit(1))'
# GUEST_KEY: the unified API key, from the settings table (the dashboard shows
# the same value on its Keys page). Run as node, which owns the database.
GUEST_KEY='const{createRequire}=require("node:module"),fs=require("fs"),r=createRequire("/app/server/");
const p=["freeapi.db","freellmapi.db"].map(n=>process.argv[1]+"/"+n).find(f=>fs.existsSync(f));if(!p)process.exit(2);
let d;try{d=new(r("better-sqlite3"))(p,{readonly:true,fileMustExist:true})}catch(e){d=new(require("node:sqlite").DatabaseSync)(p,{readOnly:true})}
const v=d.prepare("SELECT value FROM settings WHERE key = ?").get("unified_api_key");
if(!v||!/^freellmapi-[0-9a-f]{16,}$/.test(v.value))process.exit(3);process.stdout.write(v.value)'
# GUEST_KEY_WORKS PORT: does the key on stdin open /v1/models?
GUEST_KEY_WORKS='const k=require("fs").readFileSync(0,"utf8").trim();
fetch("http://127.0.0.1:"+process.argv[1]+"/v1/models?available=true",{headers:{Authorization:"Bearer "+k}}).then(r=>process.exit(r.status===200?0:1)).catch(()=>process.exit(1))'

ct_running() { [[ $(pct status "$CT_ID" 2>/dev/null) == 'status: running' ]]; }
ct_value() { pct config "$CT_ID" 2>/dev/null | sed -n "s/^$1: //p" | head -n 1; }
wait_exec() {
    local attempt
    for (( attempt = 0; attempt < 30; attempt++ )); do
        if guest true 2>/dev/null; then return 0; fi
        sleep 1
    done
    die "CT $CT_ID did not accept commands within 30 seconds."
}
wait_healthy() {
    local deadline=$(( SECONDS + FREELLMAPI_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        ct_running || return 1   # the server is the CT's init: it stopped
        if guest node -e "$GUEST_PING" "$FREELLMAPI_PORT" 2>/dev/null; then return 0; fi
        sleep 2
    done
    return 1
}
read_key() {
    local key
    key=$(guest setpriv --reuid=node --regid=node --init-groups node -e "$GUEST_KEY" "$GUEST_DATA") || return 1
    [[ $key =~ ^freellmapi-[0-9a-f]{16,}$ ]] || return 1
    printf '%s\n' "$key"
}
key_works() { printf '%s\n' "$1" | guest node -e "$GUEST_KEY_WORKS" "$FREELLMAPI_PORT"; }
recorded() { guest sed -n "s/^$1=//p" "$GUEST_DIR/settings" 2>/dev/null | head -n 1 | tr -d '\r'; }

# maintenance_boot / service_boot ENTRYPOINT: the CT started with a process
# that only waits (to prepare files while the server is down), and with the
# image's own entrypoint again.
maintenance_boot() {
    run pct set "$CT_ID" --entrypoint "$MAINTENANCE_ENTRYPOINT"
    run pct start "$CT_ID"
    (( dry_run )) || wait_exec
}
service_boot() {
    if (( ! dry_run )) && ct_running; then pct stop "$CT_ID"; fi
    run pct set "$CT_ID" --entrypoint "$1"
    run pct start "$CT_ID"
}
write_settings() {
    if (( dry_run )); then printf '+ record the settings in %s/settings\n' "$GUEST_DIR"; return 0; fi
    printf '%s\n' "FREELLMAPI_VERSION=$FREELLMAPI_VERSION" "FREELLMAPI_VERSION_SOURCE=$version_source" \
        "FREELLMAPI_DIGEST=$image_digest" "FREELLMAPI_COMMIT=$image_revision" "FREELLMAPI_PORT=$FREELLMAPI_PORT" \
        "FREELLMAPI_RATE_LIMIT_RPM=$FREELLMAPI_RATE_LIMIT_RPM" "FREELLMAPI_ADMIN_EMAIL=$FREELLMAPI_ADMIN_EMAIL" \
        "FREELLMAPI_ACCESS_CIDR=$FREELLMAPI_ACCESS_CIDR" "ROUTER_CT_ID=$ROUTER_CT_ID" \
        "TEMPLATE=$(template_volume "$FREELLMAPI_VERSION")" |
        guest sh -c 'umask 022; cat > "$1.new" && mv "$1.new" "$1"' sh "$GUEST_DIR/settings"
}

# register_with_router: the endpoint and its key to the router CT's
# manage-model-servers (the key on stdin, twice: it asks to confirm), then one
# apply. The key never reaches a command line or this host's disk.
register_with_router() {
    local key url="http://$ct_ip:$FREELLMAPI_PORT"
    [[ $ROUTER_CT_ID != none ]] || return 0
    if (( dry_run )); then
        printf '+ read the unified API key in CT %s and check it\n' "$CT_ID"
        printf '+ pct exec %s -- /usr/local/bin/manage-model-servers set-freellmapi %s --apply (key on stdin)\n' "$ROUTER_CT_ID" "$url"
        return 0
    fi
    key=$(read_key) || { note "Could not read the unified API key in CT $CT_ID."; return 1; }
    key_works "$key" || { note "FreeLLMAPI in CT $CT_ID refused its own unified API key."; return 1; }
    printf '%s\n%s\n' "$key" "$key" |
        pct exec "$ROUTER_CT_ID" -- /usr/local/bin/manage-model-servers set-freellmapi "$url" --apply ||
        { note "The router CT $ROUTER_CT_ID did not take the FreeLLMAPI endpoint."; return 1; }
    registered=1
}

# --- Settings ----------------------------------------------------------------

dry_run=0 mode=create
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --reconfigure) [[ $mode == create ]] || { usage >&2; exit 2; }; mode=reconfigure ;;
        --register) [[ $mode == create ]] || { usage >&2; exit 2; }; mode=register ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PVE_ETC=${PVE_ETC:-/etc/pve}
[[ $PVE_ETC == / ]] || PVE_ETC=${PVE_ETC%/}
PVE_LXC_DIR=${PVE_LXC_DIR:-$PVE_ETC/lxc}
STATE_DIR=${OSR_FREELLMAPI_STATE:-/var/lib/osr-freellmapi}

CT_ID=${CT_ID:-}
STORAGE=${STORAGE:-}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
CT_HOSTNAME=${CT_HOSTNAME:-freellmapi}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-1024}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-4}
DATA_GB=${DATA_GB:-2}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
version_source=default
[[ -z ${FREELLMAPI_VERSION:-} ]] || version_source=explicit
FREELLMAPI_VERSION=${FREELLMAPI_VERSION:-}
FREELLMAPI_DIGEST=${FREELLMAPI_DIGEST:-}
FREELLMAPI_PORT=${FREELLMAPI_PORT:-}
FREELLMAPI_ACCESS_CIDR=${FREELLMAPI_ACCESS_CIDR:-}
FREELLMAPI_RATE_LIMIT_RPM=${FREELLMAPI_RATE_LIMIT_RPM:-}
FREELLMAPI_ADMIN_EMAIL=${FREELLMAPI_ADMIN_EMAIL:-}
FREELLMAPI_READY_TIMEOUT=${FREELLMAPI_READY_TIMEOUT:-120}
ROUTER_CT_ID=${ROUTER_CT_ID:-}
# The password leaves the environment at once: no child process inherits it.
admin_password=${FREELLMAPI_ADMIN_PASSWORD:-}
unset FREELLMAPI_ADMIN_PASSWORD
registered=0 ct_ip='' router_ip='' old_version='' old_entrypoint=''

require_host() {
    local command_name version
    [[ $EUID -eq 0 ]] || die 'Run as root on the PVE host.'
    # zstd checks a release replacement's backup before the old CT is destroyed.
    for command_name in pveversion pct pvesh pvesm skopeo zstd; do
        command -v "$command_name" >/dev/null ||
            die "Missing command: $command_name$([[ $command_name != skopeo ]] || printf ' (apt install skopeo; Proxmox VE 9.1 uses it to pull OCI images)')"
    done
    version=$(pveversion)
    [[ $version =~ ^pve-manager/([0-9]+)\.([0-9]+) ]] || die "Cannot read the Proxmox VE version: $version"
    (( BASH_REMATCH[1] > 9 || ( BASH_REMATCH[1] == 9 && BASH_REMATCH[2] >= 1 ) )) ||
        die "Proxmox VE 9.1 or later is needed to make a CT from a container image (this host: ${BASH_REMATCH[1]}.${BASH_REMATCH[2]})."
    [[ -d $PVE_ETC/nodes ]] || die "$PVE_ETC is unavailable."
}

# ask_router: ROUTER_CT_ID (or none) and the router's address for the firewall.
ask_router() {
    local suggestion
    suggestion=$(pve_tagged_ct osr-router)
    pve_section 'Router'
    pve_note 'The router CT is given the endpoint and its key (none: do that yourself later).'
    pve_ask ROUTER_CT_ID 'Router CT ID (or none)' "${suggestion:-none}" valid_router_ct 'Use a CT ID, or none.'
    valid_router_ct "$ROUTER_CT_ID" || die 'ROUTER_CT_ID must be a CT ID or none.'
    router_ip=''
    [[ $ROUTER_CT_ID == none ]] || router_ip=$(pve_ct_net "$ROUTER_CT_ID" ip)
    if [[ $ROUTER_CT_ID != none && -z $router_ip ]] && (( ! dry_run )); then
        die "CT $ROUTER_CT_ID has no static address on this node; set ROUTER_CT_ID=none and register the endpoint on the router yourself."
    fi
}

if [[ $mode == create ]]; then
    pve_ask_new_ct FreeLLMAPI
    pve_select_storage STORAGE rootdir "$(( ROOTFS_GB + DATA_GB ))"
    pve_suggest STORAGE 'Storage for the CT' '' valid_storage_id
    pve_ask_network FreeLLMAPI
    pve_valid_cidr "$IP_CIDR" || die 'IP_CIDR must be a static IPv4 address/CIDR (the router needs a fixed address).'
    pve_valid_ipv4 "$GATEWAY" || die 'GATEWAY must be a valid IPv4 address.'
    pve_section 'FreeLLMAPI'
    pve_note 'Its dashboard is where provider API keys are added. The first account:'
    pve_ask FREELLMAPI_ADMIN_EMAIL 'Dashboard e-mail' admin@osr.local valid_email 'Use an e-mail address (it is only a sign-in name).'
    if [[ -z $admin_password ]] && pve_asks; then
        _pve_heading
        while true; do
            printf '  Dashboard password (8 or more characters; empty: generate one in the CT): ' >&2
            IFS= read -r -s admin_password || die 'Input ended while reading the password.'
            printf '\n' >&2
            [[ -n $admin_password ]] || break
            if ! valid_password "$admin_password"; then printf '    Use 8 to 128 characters.\n' >&2; continue; fi
            printf '  Again: ' >&2
            IFS= read -r -s again || die 'Input ended while reading the password.'
            printf '\n' >&2
            [[ $again == "$admin_password" ]] && break
            printf '    The passwords differ.\n' >&2
        done
        unset again
    fi
    pve_ask FREELLMAPI_ACCESS_CIDR 'Dashboard and API allowed from' "$(network_of "$IP_CIDR")" pve_valid_cidr 'Use a.b.c.d/nn.'
    ask_router
    ct_ip=${IP_CIDR%/*}
    FREELLMAPI_PORT=${FREELLMAPI_PORT:-3001}
    FREELLMAPI_RATE_LIMIT_RPM=${FREELLMAPI_RATE_LIMIT_RPM:-600}
    FREELLMAPI_VERSION=${FREELLMAPI_VERSION:-$DEFAULT_FREELLMAPI_VERSION}
    [[ $version_source == explicit || -n $FREELLMAPI_DIGEST ]] || FREELLMAPI_DIGEST=$DEFAULT_FREELLMAPI_DIGEST
else
    [[ -n $CT_ID ]] || pve_suggest CT_ID 'FreeLLMAPI CT ID' "$(pve_tagged_ct freellmapi)" pve_valid_ct_id 'Use the CT ID.'
fi

pve_valid_ct_id "$CT_ID" || die 'CT_ID must be a numeric ID of 100 or more.'
firewall_file=$PVE_ETC/firewall/$CT_ID.fw

if [[ $mode != create ]]; then
    if (( dry_run )) && ! command -v pct >/dev/null; then
        # A plan away from Proxmox: the settings stand in for the CT's record.
        ct_ip=${IP_CIDR%/*}
        old_version=${OSR_DRY_RUN_OLD_VERSION:-$DEFAULT_FREELLMAPI_VERSION}
        old_entrypoint=$IMAGE_ENTRYPOINT
        FREELLMAPI_PORT=${FREELLMAPI_PORT:-3001}
        FREELLMAPI_ACCESS_CIDR=${FREELLMAPI_ACCESS_CIDR:-$(network_of "${IP_CIDR:-192.0.2.80/24}")}
        FREELLMAPI_RATE_LIMIT_RPM=${FREELLMAPI_RATE_LIMIT_RPM:-600}
        FREELLMAPI_ADMIN_EMAIL=${FREELLMAPI_ADMIN_EMAIL:-admin@osr.local}
        old_source=default old_digest=''
    else
        require_host
        pct status "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID does not exist on this node."
        pve_ct_described "$CT_ID" "$CT_DESCRIPTION" ||
            die "CT $CT_ID is not a FreeLLMAPI CT made by this script (its description differs)."
        ct_ip=$(pve_ct_net "$CT_ID" ip)
        [[ -n $ct_ip ]] || die "CT $CT_ID has no static address."
        ct_running || die "CT $CT_ID is not running. Start it (pct start $CT_ID) so its settings can be read; if it does not stay up, see targets/freellmapi/README.md (Troubleshooting)."
        old_entrypoint=$(ct_value entrypoint)
        [[ $old_entrypoint =~ $IMAGE_ENTRYPOINT_RE ]] ||
            die "CT $CT_ID runs '$old_entrypoint', not the image's entrypoint. A run was interrupted while the CT was being prepared: see targets/freellmapi/README.md (Troubleshooting)."
        old_version=$(recorded FREELLMAPI_VERSION)
        valid_version "$old_version" || die "CT $CT_ID has no settings record ($GUEST_DIR/settings)."
        old_source=$(recorded FREELLMAPI_VERSION_SOURCE); old_digest=$(recorded FREELLMAPI_DIGEST)
        FREELLMAPI_PORT=${FREELLMAPI_PORT:-$(recorded FREELLMAPI_PORT)}
        FREELLMAPI_RATE_LIMIT_RPM=${FREELLMAPI_RATE_LIMIT_RPM:-$(recorded FREELLMAPI_RATE_LIMIT_RPM)}
        FREELLMAPI_ADMIN_EMAIL=$(recorded FREELLMAPI_ADMIN_EMAIL)
    fi
    # keep: the CT's own release, and whether it follows the tested one.
    if [[ $FREELLMAPI_VERSION == keep ]]; then
        FREELLMAPI_VERSION=$old_version version_source=${old_source:-default}
        [[ $version_source == explicit ]] || version_source=default
        FREELLMAPI_DIGEST=${FREELLMAPI_DIGEST:-$old_digest}
    fi
    # A release chosen for this CT stays until another one is named; a CT on
    # the tested release follows it.
    if [[ -z $FREELLMAPI_VERSION ]]; then
        if [[ $old_source == explicit ]]; then
            FREELLMAPI_VERSION=$old_version version_source=explicit
            FREELLMAPI_DIGEST=${FREELLMAPI_DIGEST:-$old_digest}
        else
            FREELLMAPI_VERSION=$DEFAULT_FREELLMAPI_VERSION
            FREELLMAPI_DIGEST=${FREELLMAPI_DIGEST:-$DEFAULT_FREELLMAPI_DIGEST}
        fi
    fi
    if [[ -z $FREELLMAPI_ACCESS_CIDR && -r $firewall_file ]]; then FREELLMAPI_ACCESS_CIDR=$(fw_access "$firewall_file"); fi
    if [[ $mode == register ]]; then ask_router
    else
        [[ -r $firewall_file || $dry_run == 1 ]] || die "Missing firewall file: $firewall_file"
        # sync_firewall rewrites the rules after the server restarts: a file it
        # cannot rewrite must stop the run before the CT is touched.
        [[ $dry_run == 1 ]] || grep -qxF '[RULES]' "$firewall_file" ||
            die "$firewall_file has no [RULES] section; add it (or restore the file) and run again."
        if [[ -z $ROUTER_CT_ID && $dry_run == 0 ]]; then
            ROUTER_CT_ID=$(recorded ROUTER_CT_ID)
            if [[ -z $ROUTER_CT_ID && -r $firewall_file ]]; then
                # Older installations did not record the router CT ID.
                candidate=$(pve_tagged_ct osr-router)
                if [[ -n $candidate && $(pve_ct_net "$candidate" ip) == "$(fw_router_ip "$firewall_file")" ]]; then ROUTER_CT_ID=$candidate; fi
                [[ -n $ROUTER_CT_ID || -z $(fw_router_ip "$firewall_file") ]] ||
                    die "Cannot identify the router CT allowed by $firewall_file; set ROUTER_CT_ID to its ID."
            fi
        fi
        ROUTER_CT_ID=${ROUTER_CT_ID:-none}
        valid_router_ct "$ROUTER_CT_ID" || die 'ROUTER_CT_ID must be a CT ID or none.'
        if [[ $ROUTER_CT_ID != none ]]; then
            router_ip=$(pve_ct_net "$ROUTER_CT_ID" ip)
            [[ -n $router_ip || $dry_run == 1 ]] || die "Router CT $ROUTER_CT_ID has no static address."
        fi
    fi
fi

valid_version "$FREELLMAPI_VERSION" || die 'FREELLMAPI_VERSION must be a release tag such as v0.16.31.'
# Naming the tested release is following it (tools/upgrade-all.sh passes it).
[[ $FREELLMAPI_VERSION != "$DEFAULT_FREELLMAPI_VERSION" ]] || version_source=default
valid_optional_digest "$FREELLMAPI_DIGEST" || die 'FREELLMAPI_DIGEST must be sha256: and 64 hex digits.'
valid_port "$FREELLMAPI_PORT" || die 'FREELLMAPI_PORT must be 1..65535.'
pve_valid_cidr "$FREELLMAPI_ACCESS_CIDR" || die 'FREELLMAPI_ACCESS_CIDR must be a.b.c.d/nn.'
[[ $FREELLMAPI_RATE_LIMIT_RPM =~ ^(0|[1-9][0-9]{0,6})$ ]] || die 'FREELLMAPI_RATE_LIMIT_RPM must be a nonnegative integer.'
[[ $FREELLMAPI_READY_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'FREELLMAPI_READY_TIMEOUT must be a positive number of seconds.'
valid_storage_id "$TEMPLATE_STORAGE" || die 'TEMPLATE_STORAGE must be a Proxmox storage ID.'
valid_email "$FREELLMAPI_ADMIN_EMAIL" || die 'FREELLMAPI_ADMIN_EMAIL must be an e-mail address.'
valid_optional_password "$admin_password" || die 'FREELLMAPI_ADMIN_PASSWORD must have 8 to 128 characters and no control characters.'
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing deployment file: $source_dir/upstream-commit.txt"

if [[ $mode == create ]]; then
    valid_storage_id "$STORAGE" || die 'STORAGE must be a Proxmox rootdir storage ID.'
    [[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
    [[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
    for name in CORES MEMORY_MB ROOTFS_GB DATA_GB; do positive_int "$name" "${!name}"; done
    (( MEMORY_MB >= 512 )) || die 'MEMORY_MB must be at least 512 for FreeLLMAPI.'
    (( ROOTFS_GB >= 2 )) || die 'ROOTFS_GB must be at least 2 for the FreeLLMAPI image.'
    [[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
    [[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
    [[ -z $NAMESERVER ]] || pve_valid_ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
    if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
    pve_valid_cidr "$FREELLMAPI_ACCESS_CIDR" || die 'FREELLMAPI_ACCESS_CIDR must be a.b.c.d/nn.'
    if (( ! dry_run )); then
        require_host
        if ! pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null; then
            if pct status "$CT_ID" >/dev/null 2>&1; then
                die "CT $CT_ID already exists. This run only creates a new FreeLLMAPI CT; change an existing one with: CT_ID=$CT_ID bash $0 --reconfigure"
            fi
            die "CT ID $CT_ID is unavailable in this cluster."
        fi
        [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge interface is missing: $BRIDGE"
        [[ ! -e $firewall_file ]] || die "Refusing to replace existing firewall file: $firewall_file"
    fi
fi

# --- Signal rollback ---------------------------------------------------------
# Signal rollback helper
# A signal (Ctrl-C, a closed SSH session, kill) runs the same rollback as a
# failure: whatever the ERR trap holds at that moment, so a half-applied
# upgrade is undone; outside a rollback window it just stops the run. Further
# signals are ignored meanwhile, and after a hangup the output goes to
# OSR_INTERRUPT_LOG, so writes to the closed terminal cannot fail the rollback.
# Every copy matches targets/signal-rollback.sh (tests/test-signal-rollback.sh).
on_signal() {
    local status=$1 handler action
    local -a parts=()
    trap '' INT TERM HUP
    if [[ $status == 129 ]]; then
        exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
    fi
    printf '%s: stopped by a signal (status %s).\n' "${0##*/}" "$status" >&2
    handler=$(trap -p ERR)
    if [[ -n $handler ]]; then
        eval "parts=($handler)"
        action=${parts[2]}
        # The rollback handlers end in "exit 1": keep the signal's status.
        [[ $action != *'; exit 1' ]] || action="${action%exit 1}exit $status"
        trap - ERR
        eval "$action"
    fi
    exit "$status"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
# End signal rollback helper.

# --- Register only -----------------------------------------------------------

if [[ $mode == register ]]; then
    [[ $ROUTER_CT_ID != none ]] || die 'Nothing to do: ROUTER_CT_ID is none.'
    pve_summary 'FreeLLMAPI: register with the router'
    pve_row 'FreeLLMAPI CT' "$CT_ID (http://$ct_ip:$FREELLMAPI_PORT)"
    pve_row 'Router CT' "$ROUTER_CT_ID"
    pve_confirm "Give router CT $ROUTER_CT_ID the endpoint and key of CT $CT_ID?"
    register_with_router || die 'The endpoint was not registered.'
    (( dry_run )) || printf 'Router CT %s now offers the models of CT %s as freellmapi/<id>.\n' "$ROUTER_CT_ID" "$CT_ID"
    exit 0
fi

# --- Create or replace -------------------------------------------------------

# create_ct TEMPLATE NET0 ROOTFS DATA [extra pct create options...]: the CT
# from the image, with its data volume. Proxmox reads the image's entrypoint,
# environment and working directory into the CT's configuration, manages the
# network itself (the image has no network setup) and detects Debian.
create_ct() {
    local template=$1 net=$2 rootfs=$3 data=$4
    shift 4
    local -a create=(pct create "$CT_ID" "$template" --unprivileged 1 --rootfs "$rootfs"
        --mp0 "$data,mp=$GUEST_DATA,backup=1" --net0 "$net" --tags 'ai;ai-model;osr-target;freellmapi'
        --description "$CT_DESCRIPTION"$'\n'"OpenAI-compatible API and dashboard on TCP $FREELLMAPI_PORT" "$@")
    if [[ -n $ct_node ]]; then
        # The replacement of a CT on another node: made again there.
        printf '+ on node %s:' "$ct_node"; printf ' %q' "${create[@]}"; printf '\n'
        on_ct_node sh -c 'umask 022; exec "$@"' sh "${create[@]}"
    else
        (umask 022; run "${create[@]}")
    fi || { note "pct create failed for CT $CT_ID (see its message above)."; return 1; }
    (( dry_run )) && return 0
    old_entrypoint=$(ct_value entrypoint)
    [[ $old_entrypoint =~ $IMAGE_ENTRYPOINT_RE ]] || {
        note "CT $CT_ID did not take the image's entrypoint (found '${old_entrypoint:-none}'). Is $template the FreeLLMAPI image, and this Proxmox VE 9.1 or later?"
        return 1
    }
}
# The OCI image exports PORT=3001; dotenv does not replace an exported value.
# Set PORT in the server's init environment while retaining the other image env.
runtime_entrypoint() { printf '/usr/bin/env PORT=%s %s\n' "$FREELLMAPI_PORT" "$IMAGE_ENTRYPOINT"; }

# first_start bootstrap|keep: prepare the data directory while the server is
# down, then start the image's own entrypoint and wait for it.
first_start() {
    maintenance_boot
    printf '+ prepare %s in the CT (env file with the encryption key, /app/.env)\n' "$GUEST_DIR"
    (( dry_run )) || guest sh -c "$GUEST_PREPARE" sh "$FREELLMAPI_PORT" "$FREELLMAPI_RATE_LIMIT_RPM" "$1"
    if [[ $1 == bootstrap ]]; then
        if (( dry_run )); then
            printf '+ write %s/bootstrap.json (the first dashboard account; e-mail and password on stdin)\n' "$GUEST_DIR"
        else
            printf '%s\n%s' "$FREELLMAPI_ADMIN_EMAIL" "$admin_password" | guest node -e "$GUEST_BOOTSTRAP" "$GUEST_DIR"
            guest chown root:node "$GUEST_DIR/bootstrap.json"
            admin_password=''
        fi
    fi
    [[ ${2:-} != restore ]] || restore_data
    write_settings
    service_boot "$(runtime_entrypoint)"
    (( dry_run )) && { printf '+ wait up to %ss for http://127.0.0.1:%s/api/ping in the CT\n' "$FREELLMAPI_READY_TIMEOUT" "$FREELLMAPI_PORT"; return 0; }
    wait_healthy || { note "FreeLLMAPI in CT $CT_ID did not answer /api/ping within ${FREELLMAPI_READY_TIMEOUT}s."; return 1; }
}

if [[ $mode == create ]]; then
    net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
    [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
    pve_summary 'FreeLLMAPI: create'
    pve_row 'FreeLLMAPI CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB}+${DATA_GB} GiB on $STORAGE"
    pve_row 'Image' "$(image_ref "$FREELLMAPI_VERSION")${FREELLMAPI_DIGEST:+ ($FREELLMAPI_DIGEST)}"
    pve_row 'Network' "$IP_CIDR via $GATEWAY on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
    pve_row 'Dashboard and API' "port $FREELLMAPI_PORT, allowed from $FREELLMAPI_ACCESS_CIDR${router_ip:+ and the router ($router_ip)}"
    pve_row 'Dashboard account' "$FREELLMAPI_ADMIN_EMAIL, $([[ -n $admin_password ]] && echo 'the password you gave' || echo 'a password generated in the CT')"
    pve_row 'Router' "$([[ $ROUTER_CT_ID == none ]] && echo 'not registered' || echo "CT $ROUTER_CT_ID gets the endpoint and key")"
    [[ -n $FREELLMAPI_DIGEST ]] || note '  No digest is pinned for this release: the tag is trusted as the registry serves it now.'
    pve_confirm "Create FreeLLMAPI CT $CT_ID?"
    ensure_template "$FREELLMAPI_VERSION" "$FREELLMAPI_DIGEST"
    trap 'main_shell || exit 1; printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
    extra=(--hostname "$CT_HOSTNAME" --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" --onboot "$ONBOOT")
    [[ -z $NAMESERVER ]] || extra+=(--nameserver "$NAMESERVER")
    create_ct "$(template_volume "$FREELLMAPI_VERSION")" "$net" "$STORAGE:$ROOTFS_GB" "$STORAGE:$DATA_GB" "${extra[@]}" ||
        die "CT $CT_ID was not created as expected; anything created is kept for inspection."
    firewall=$(firewall_config "$FREELLMAPI_ACCESS_CIDR" "$FREELLMAPI_PORT" "$router_ip")
    if (( dry_run )); then
        printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
    else
        printf '%s\n' "$firewall" > "$firewall_file"
    fi
    first_start bootstrap || die "See: pct exec $CT_ID -- true; pct console $CT_ID (the server's output). The CT is kept."
    if (( dry_run )); then
        printf '+ check the dashboard account exists, then remove %s/bootstrap.json\n' "$GUEST_DIR"
    else
        guest node -e "$GUEST_ACCOUNT" "$FREELLMAPI_PORT" ||
            die "FreeLLMAPI started without the dashboard account. $GUEST_DIR/bootstrap.json is kept in the CT; see pct console $CT_ID."
        guest sh -c "$GUEST_BOOTSTRAP_DONE"
    fi
    trap - ERR
    register_with_router || note 'Register it later with: CT_ID='"$CT_ID"' bash '"$0"' --register'
    (( dry_run )) && exit 0
    printf '\nFreeLLMAPI CT %s: dashboard and API at http://%s:%s (from %s).\n' "$CT_ID" "$ct_ip" "$FREELLMAPI_PORT" "$FREELLMAPI_ACCESS_CIDR"
    printf 'Sign in as %s' "$FREELLMAPI_ADMIN_EMAIL"
    if guest test -s "$GUEST_DIR/initial-admin-password" 2>/dev/null; then
        printf '; the generated password:\n  pct exec %s -- cat %s/initial-admin-password\n' "$CT_ID" "$GUEST_DIR"
        printf 'Change it in the dashboard, then: pct exec %s -- rm %s/initial-admin-password\n' "$CT_ID" "$GUEST_DIR"
    else
        printf ' with the password you gave.\n'
    fi
    printf 'Add provider API keys on its Keys page: without one, no model answers.\n'
    if (( registered )); then
        printf 'Router CT %s offers its models as freellmapi/<id> (freellmapi/auto picks one).\n' "$ROUTER_CT_ID"
    else
        printf 'On the router: manage-model-servers set-freellmapi http://%s:%s --apply (it asks for the key\n' "$ct_ip" "$FREELLMAPI_PORT"
        printf '  shown on the dashboard Keys page).\n'
    fi
    printf 'Server output: pct console %s. Later releases: CT_ID=%s bash %s --reconfigure\n' "$CT_ID" "$CT_ID" "$0"
    exit 0
fi

# --- Reconfigure: settings, and a new image when the release changed ----------

stage='' dump='' data_tar=''
# export_data / restore_data: the data directory as a tar stream, read and
# written inside the CT so owners need no translation, kept root-only on this
# host until the new CT has it.
# The data directory is the root of the mp0 volume, so it holds the file
# system's lost+found: owned by the host's root, it is "nobody" inside an
# unprivileged CT and cannot be read there. vzdump leaves it out for the same
# reason; the new volume has its own.
export_data() {
    guest tar --exclude=lost+found -C "${GUEST_DATA%/*}" -cf - "${GUEST_DATA##*/}" > "$data_tar" || return 1
    tar -tf "$data_tar" | grep -qx "${GUEST_DATA##*/}/osr-target/freellmapi.env"
}
restore_data() {
    if (( dry_run )); then printf '+ restore the data directory into the new CT\n'; return 0; fi
    guest tar -C "${GUEST_DATA%/*}" -xpf - < "$data_tar"
}
# rollback: the CT as the backup has it, started and checked.
rolled_back=0
rollback() {
    main_shell || return 1
    trap - ERR
    (( ! rolled_back )) || return 1
    rolled_back=1
    note "Restoring CT $CT_ID from the backup taken before the change."
    # Nothing is destroyed unless the backup to restore from is there.
    if [[ -z $dump || ! -s $dump ]]; then
        note "The backup ${dump:-(none)} is missing: CT $CT_ID is left as it is."
        return 1
    fi
    if pct status "$CT_ID" >/dev/null 2>&1; then
        pct stop "$CT_ID" 2>/dev/null || true
        pct destroy "$CT_ID" || { note "Could not remove the new CT $CT_ID. The backup is kept: $dump"; return 1; }
    fi
    # pct restore creates /var/lib/lxc/<CT>/rootfs with the caller's umask and
    # unpacks as the CT's mapped root, like pct create (see create_ct).
    if [[ -n $ct_node ]]; then
        # On the CT's node, from a copy of the backup streamed there.
        on_ct_node sh -c 'umask 022; d=$(mktemp -d -p /var/tmp osr-freellmapi.XXXXXX) || exit 1
            cat > "$d/$2" && pct restore "$1" "$d/$2" --storage "$3"; r=$?; rm -rf -- "$d"; exit $r' \
            sh "$CT_ID" "${dump##*/}" "$ct_storage" < "$dump"
    else
        (umask 022; pct restore "$CT_ID" "$dump" --storage "$ct_storage")
    fi || {
        if [[ -n $ct_node ]]; then
            note "pct restore failed on node $ct_node. The backup is kept on this node: $dump"
            note "Copy it to node $ct_node and restore it there, as targets/freellmapi/README.md (Troubleshooting) shows:"
            note "after pct destroy, the cluster wrapper no longer knows CT $CT_ID belongs on $ct_node and would restore it here."
        else
            note "pct restore failed. The backup is kept: $dump (umask 022; pct restore $CT_ID $dump --storage $ct_storage)"
        fi
        return 1
    }
    pct start "$CT_ID" || { note "The restored CT $CT_ID did not start. The backup is kept: $dump"; return 1; }
    FREELLMAPI_PORT=$old_port
    ROUTER_CT_ID=$old_router
    if wait_healthy; then
        note "CT $CT_ID is running FreeLLMAPI $old_version again."
        # The backup is kept: a release that failed is worth a look, and it is
        # the only copy of the CT as it was. Later runs are not blocked by it.
        kept="$stage.rolled-back-$(date +%Y%m%d-%H%M%S)"
        rm -f -- "$data_tar"
        if mv -- "$stage" "$kept"; then
            note "The backup is kept in $kept; delete it once CT $CT_ID is fine."
        fi
    else
        note "The restored CT $CT_ID did not become healthy either. The backup is kept: $dump"
        return 1
    fi
}

pve_summary 'FreeLLMAPI: reconfigure'
pve_row 'FreeLLMAPI CT' "$CT_ID (http://$ct_ip:$FREELLMAPI_PORT)"
pve_row 'Release' "$old_version -> $FREELLMAPI_VERSION${FREELLMAPI_DIGEST:+ ($FREELLMAPI_DIGEST)}"
pve_row 'Rate limit' "$FREELLMAPI_RATE_LIMIT_RPM requests per minute per client"

same_release=0
[[ $old_version != "$FREELLMAPI_VERSION" ]] || same_release=1
old_port=$FREELLMAPI_PORT old_router=$ROUTER_CT_ID old_router_ip=''
if (( ! dry_run )); then
    old_port=$(recorded FREELLMAPI_PORT)
    old_router=$(recorded ROUTER_CT_ID)
    old_router=${old_router:-$ROUTER_CT_ID}
    old_router_ip=$(fw_router_ip "$firewall_file")
fi
rollback_settings() {
    main_shell || return 1
    trap - ERR
    note "Restoring FreeLLMAPI settings in CT $CT_ID."
    pct stop "$CT_ID" 2>/dev/null || true
    maintenance_boot || return 1
    guest tar -C "$GUEST_DATA" -xpf - < "$settings_stage/config.tar" || return 1
    cp -- "$settings_stage/firewall.fw" "$firewall_file" || return 1
    FREELLMAPI_PORT=$old_port
    ROUTER_CT_ID=$old_router
    service_boot "$old_entrypoint" || return 1
    wait_healthy || return 1
    rm -rf -- "$settings_stage"
}
if (( same_release && ! dry_run )); then
    same_settings=1
    [[ $old_port == "$FREELLMAPI_PORT" && $(recorded FREELLMAPI_RATE_LIMIT_RPM) == "$FREELLMAPI_RATE_LIMIT_RPM" &&
       $(fw_access "$firewall_file") == "$FREELLMAPI_ACCESS_CIDR" && $(fw_router_ip "$firewall_file") == "$router_ip" &&
       $old_router == "$ROUTER_CT_ID" ]] || same_settings=0
    if (( same_settings )) && guest node -e "$GUEST_PING" "$FREELLMAPI_PORT" 2>/dev/null; then
        pve_ensure_tags "$CT_ID" ai ai-model osr-target freellmapi
        printf 'FreeLLMAPI CT %s runs %s and answers: nothing to do.\n' "$CT_ID" "$FREELLMAPI_VERSION"
        exit 0
    fi
fi

if (( same_release )); then
    # Settings only: the same image, its env file rewritten while it is down.
    pve_confirm "Apply the settings to FreeLLMAPI CT $CT_ID (a short restart)?"
    image_digest=${old_digest:-} image_revision=''
    (( dry_run )) || image_revision=$(recorded FREELLMAPI_COMMIT)
    if (( ! dry_run )); then
        install -d -m 0700 "$STATE_DIR"
        settings_stage=$(mktemp -d "$STATE_DIR/$CT_ID-settings.XXXXXXXX")
        guest tar -C "$GUEST_DATA" -cf - osr-target/freellmapi.env osr-target/settings > "$settings_stage/config.tar" ||
            { rm -rf -- "$settings_stage"; die 'Could not back up the FreeLLMAPI settings.'; }
        cp -- "$firewall_file" "$settings_stage/firewall.fw" || { rm -rf -- "$settings_stage"; die 'Could not back up the FreeLLMAPI firewall.'; }
    fi
    trap 'main_shell || exit 1; note "Stopped at line $LINENO."; rollback_settings || note "Settings backup kept: $settings_stage"; exit 1' ERR
    run pct stop "$CT_ID"
    if ! first_start keep; then rollback_settings || note "Settings backup kept: $settings_stage"; exit 1; fi
    sync_firewall
    if [[ $old_port != "$FREELLMAPI_PORT" || $old_router != "$ROUTER_CT_ID" || $old_router_ip != "$router_ip" ]]; then
        if ! register_with_router; then rollback_settings || note "Settings backup kept: $settings_stage"; exit 1; fi
    fi
    trap - ERR
    (( dry_run )) || rm -rf -- "$settings_stage"
    (( dry_run )) || printf 'FreeLLMAPI CT %s was restarted with its settings.\n' "$CT_ID"
    exit 0
fi

# A new image: the CT is made again from it. What it must keep is read first.
if (( dry_run )) && ! command -v pct >/dev/null; then
    ct_storage=${STORAGE:-<storage>} rootfs_size=${ROOTFS_GB}G data_size=${DATA_GB}G net=${OSR_DRY_RUN_NET:-<net0 of the CT>}
    keep=(--hostname "$CT_HOSTNAME")
else
    rootfs=$(ct_value rootfs); data=$(ct_value mp0); net=$(ct_value net0)
    [[ $rootfs =~ ^([^:,]+):[^,]+,.*size=([0-9]+[MGT]) && -n $net ]] || die "Cannot read the root disk of CT $CT_ID: $rootfs"
    ct_storage=${BASH_REMATCH[1]} rootfs_size=${BASH_REMATCH[2]}
    [[ $data =~ ^([^:,]+):[^,]+,.*size=([0-9]+[MGT]) && $data == *"mp=$GUEST_DATA"* ]] ||
        die "CT $CT_ID has no data volume at $GUEST_DATA (mp0: ${data:-none}); it was not made by this script."
    data_storage=${BASH_REMATCH[1]} data_size=${BASH_REMATCH[2]}
    [[ $data_storage == "$ct_storage" ]] ||
        die "CT $CT_ID keeps its data on $data_storage and its root disk on $ct_storage; this script replaces only CTs with both on one storage."
    [[ $rootfs_size == *G && $data_size == *G ]] || die "CT $CT_ID has disk sizes this script cannot create again ($rootfs_size, $data_size)."
    keep=()
    for option in hostname cores memory swap onboot nameserver searchdomain startup; do
        value=$(ct_value "$option")
        [[ -z $value ]] || keep+=("--$option" "$value")
    done
fi
[[ -r $firewall_file || $dry_run == 1 ]] || die "Missing firewall file: $firewall_file"
(( dry_run )) || find_ct_node
if [[ -n $ct_node ]]; then
    pve_row 'Node' "$ct_node (backup, template and new CT handled there; the backup is kept on this node)"
    on_ct_node sh -c 'command -v vzdump && command -v zstd && command -v pvesm' </dev/null >/dev/null ||
        die "Node $ct_node, which holds CT $CT_ID, lacks vzdump, zstd or pvesm (or cannot be reached); nothing was changed."
fi

pve_row 'Change' "replace the CT with one made from the new image; data, ID and address stay"
note '  Options set on the CT by hand (other than cores, memory, swap, start order,'
note '  DNS and the network device) are not carried over; the backup has them.'
pve_confirm "Replace FreeLLMAPI CT $CT_ID with release $FREELLMAPI_VERSION (it is down for a few minutes)?"

ensure_template "$FREELLMAPI_VERSION" "$FREELLMAPI_DIGEST"
(( dry_run )) || sync_template
if (( dry_run )); then
    stage="$STATE_DIR/$CT_ID" dump="$stage/vzdump-lxc-$CT_ID-<time>.tar.zst" data_tar="$stage/data.tar"
    printf '+ vzdump %s --mode stop --compress zstd --dumpdir %s --tmpdir /var/tmp (the whole CT, for rollback)\n' "$CT_ID" "$stage"
    printf '+ start the old CT without the server and save its data directory to %s\n' "$data_tar"
    run pct destroy "$CT_ID"
else
    command -v vzdump >/dev/null || die 'Missing command: vzdump'
    install -d -m 0700 "$STATE_DIR"
    stage="$STATE_DIR/$CT_ID"
    [[ ! -e $stage ]] || die "$stage exists: an earlier replacement of CT $CT_ID did not finish. Its backup is in there; see targets/freellmapi/README.md (Troubleshooting) before removing it."
    install -d -m 0700 "$stage"
    data_tar=$stage/data.tar
    key_before=$(read_key | sha256sum) || die "Could not read the unified API key in CT $CT_ID."
    cp -- "$firewall_file" "$stage/firewall.fw"
    # From here the old CT is touched: any failure starts it again.
    trap 'main_shell || exit 1; note "Stopped at line $LINENO."; pct stop "$CT_ID" 2>/dev/null || true; service_boot "$old_entrypoint" || true; rm -rf -- "$stage"; exit 1' ERR
    pct stop "$CT_ID"
    # For an unprivileged CT, vzdump's tar runs as the CT's mapped root and
    # reads the CT config from vzdump's temporary directory, by default inside
    # the dump directory, which is root-only here (the backup holds the keys).
    # /var/tmp (vzdump's own fallback) keeps that temporary copy reachable, and
    # umask 022 lets vzdump create it reachable: tools/upgrade-all.sh runs with
    # umask 077. The archive is written by root into the root-only directory.
    if [[ -z $ct_node ]]; then
        (umask 022; vzdump "$CT_ID" --mode stop --compress zstd --dumpdir "$stage" --tmpdir /var/tmp >&2)
    else
        # vzdump backs up only its own node's guests: it runs on the CT's
        # node and streams the archive here, into the root-only directory.
        # Its documented stream is the plain tar (--stdout), compressed there
        # with the zstd its own --compress zstd uses; pipefail keeps a vzdump
        # failure a failure.
        note "Backing up CT $CT_ID on node $ct_node into $stage."
        on_ct_node bash -c 'set -o pipefail; umask 022; vzdump "$1" --mode stop --stdout 1 --tmpdir /var/tmp | zstd -q' bash "$CT_ID" \
            </dev/null > "$stage/vzdump-lxc-$CT_ID-$(date +%Y_%m_%d-%H_%M_%S).tar.zst"
    fi
    dumps=("$stage"/vzdump-lxc-"$CT_ID"-*.tar.zst)
    [[ ${#dumps[@]} -eq 1 && -s ${dumps[0]} ]] ||
        { note "vzdump left no backup in $stage (a CT on another node is skipped by this node's vzdump)."; false; }
    dump=${dumps[0]}
    # A skipped --stdout backup still leaves a nonempty zstd frame. Read the
    # complete archive and require the CT configuration, under the name pct
    # restore looks for (./etc/vzdump/pct.conf), before destroying the CT.
    # awk consumes the whole file list so pipefail also catches a truncated
    # compressed stream or tar archive.
    zstd -dc -- "$dump" | tar -tf - | awk '
        $0 == "./etc/vzdump/pct.conf" { found = 1 }
        END { exit !found }
    ' || { note "The backup of CT $CT_ID is unreadable or lacks its CT configuration; leaving the old CT in place."; false; }
    maintenance_boot
    export_data || { note "Could not save the data directory of CT $CT_ID."; false; }
    pct stop "$CT_ID"
    pct set "$CT_ID" --entrypoint "$old_entrypoint"
    pct destroy "$CT_ID"
    # From here the old CT is gone: any failure restores it from the backup.
    trap 'main_shell || exit 1; note "Stopped at line $LINENO."; rollback || true; exit 1' ERR
fi
if ! create_ct "$(template_volume "$FREELLMAPI_VERSION")" "$net" "$ct_storage:${rootfs_size%G}" "$ct_storage:${data_size%G}" "${keep[@]}"; then
    (( dry_run )) || { rollback || true; exit 1; }
fi
if (( dry_run )); then
    sync_firewall
else
    cp -- "$stage/firewall.fw" "$firewall_file"
    sync_firewall
fi
if ! first_start keep restore; then
    (( dry_run )) || { rollback || true; exit 1; }
fi
if (( dry_run )); then
    printf '+ check the unified API key is unchanged and works; on any failure: pct restore %s %s --storage %s\n' "$CT_ID" "$dump" "$ct_storage"
    exit 0
fi
key_after=$(read_key | sha256sum) || key_after=''
if [[ $key_after != "$key_before" ]] || ! key_works "$(read_key)"; then
    note "Release $FREELLMAPI_VERSION started, but the unified API key is not the one the router has."
    rollback || true
    exit 1
fi
if [[ $old_port != "$FREELLMAPI_PORT" || $old_router != "$ROUTER_CT_ID" || $old_router_ip != "$router_ip" ]]; then
    if ! register_with_router; then rollback || true; exit 1; fi
fi
trap - ERR
rm -rf -- "$stage"
pve_ensure_tags "$CT_ID" ai ai-model osr-target freellmapi
printf 'FreeLLMAPI CT %s now runs %s (was %s). Its data, key and address are unchanged.\n' "$CT_ID" "$FREELLMAPI_VERSION" "$old_version"
