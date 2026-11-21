#!/usr/bin/env bash
# A stand-in for the Proxmox commands targets/freellmapi/provision-lxc.sh runs
# (pct, pvesh, pvesm, pveversion, skopeo, vzdump, zstd), for test-provision.sh. Each
# is a link to this file. A CT is a directory: its configuration in
# $PVE_ETC/lxc/<id>.conf as `pct config` prints it, its file system under
# $FAKE/ct/<id>/fs. `pct exec` runs the provisioner's own guest scripts against
# that tree (paths under /app are mapped into it); only the Node one-liners are
# imitated, by what they ask for.
#
# FAKE_CT_NODE=pve2 puts the CTs on another node of a cluster, the way
# tools/pct-cluster.sh (pct under tools/upgrade-all.sh) sees them from pve1:
# pct --osr-node, --osr-local-node and --osr-on-node answer, a command run with
# --osr-on-node gets FAKE_ON_NODE, and vzdump, pvesm and pct create/restore act
# for the node they run on (vzdump skips a CT of another node and succeeds).
# FAKE_VZDUMP_SKIPS makes vzdump skip the CT on its own node too, as it would
# for a CT that moved after the lookup.
set -euo pipefail
: "${FAKE:?}" "${PVE_ETC:?}"
name=${0##*/}
printf '%s' "$name" >> "$FAKE/calls"; printf ' %q' "$@" >> "$FAKE/calls"; printf '\n' >> "$FAKE/calls"
# The dashboard password must not be inherited by any command.
[[ -z ${FREELLMAPI_ADMIN_PASSWORD+x} ]] || printf 'PASSWORD-IN-ENVIRONMENT\n' >> "$FAKE/calls"
conf() { printf '%s/lxc/%s.conf\n' "$PVE_ETC" "$1"; }
fs() { printf '%s/ct/%s/fs\n' "$FAKE" "$1"; }
exists() { [[ -f $(conf "$1") ]]; }
value() { sed -n "s/^$2: //p" "$(conf "$1")" | head -n 1; }
set_value() {
    local file; file=$(conf "$1")
    if grep -q "^$2: " "$file"; then sed -i "s|^$2: .*|$2: $3|" "$file"; else printf '%s: %s\n' "$2" "$3" >> "$file"; fi
}
running() { [[ -e $FAKE/ct/$1/running ]]; }
# The node a command runs on, and its template directory.
this_node() { printf '%s\n' "${FAKE_ON_NODE:-pve1}"; }
template_dir() {
    if [[ -n ${FAKE_ON_NODE:-} && $FAKE_ON_NODE != pve1 ]]; then printf '%s/node-%s/template/cache\n' "$FAKE" "$FAKE_ON_NODE"
    else printf '%s/template/cache\n' "$FAKE"; fi
}
entrypoint='/usr/local/bin/docker-entrypoint.sh node server/dist/index.js'
runtime_entrypoint_re='^/usr/bin/env PORT=([1-9][0-9]{0,4}) /usr/local/bin/docker-entrypoint\.sh node server/dist/index\.js$'

# server_start ID: what the image's entrypoint does with the data directory.
server_start() {
    local id=$1 root data env version
    root=$(fs "$id"); data=$root/app/server/data; version=$(cat "$FAKE/ct/$id/image")
    [[ -L $root/app/.env ]] || return 1
    env=$data/osr-target/freellmapi.env
    grep -q -E '^ENCRYPTION_KEY=[0-9a-f]{64}$' "$env" 2>/dev/null || return 1
    [[ $version != "${FAKE_START_FAILS:-}" ]] || return 1
    # FAKE_REKEY: a release that loses the unified key.
    [[ $version != "${FAKE_REKEY:-}" ]] || rm -f "$data/freeapi.db"
    if [[ ! -e $data/freeapi.db ]]; then
        printf 'freellmapi-%s\n' "$(head -c 24 /dev/urandom | od -An -v -tx1 | tr -d ' \n')" > "$data/freeapi.db"
    fi
    if grep -q '^FREEAPI_CONFIG_PATH=' "$env" && [[ -s $data/osr-target/bootstrap.json && ! -e $data/account ]]; then
        cp "$data/osr-target/bootstrap.json" "$data/account"
    fi
    # The OCI image exports PORT=3001. dotenv does not override it with .env.
    local init_port=3001 init_command
    init_command=$(value "$id" entrypoint)
    if [[ $init_command =~ $runtime_entrypoint_re ]]; then init_port=${BASH_REMATCH[1]}; fi
    printf 'PORT=%s\n' "$init_port" > "$FAKE/ct/$id/listening"
    printf '%s\n' "$version" >> "$FAKE/ct/$id/started"
}
# FAKE_UNHEALTHY: releases (space-separated) that start but never answer.
healthy() { [[ " ${FAKE_UNHEALTHY:-} " != *" $(cat "$FAKE/ct/$1/image") "* && -e $FAKE/ct/$1/listening &&
    $(cat "$FAKE/ct/$1/listening") != "PORT=${FAKE_UNHEALTHY_PORT:-<none>}" ]]; }

guest_exec() {
    local id=$1 root js data; shift
    root=$(fs "$id"); data=$root/app/server/data
    running "$id" || { echo "CT $id not running" >&2; return 1; }
    [[ $1 != setpriv ]] || { while [[ $1 != node ]]; do shift; done; }
    local -a mapped=()
    local arg
    for arg in "$@"; do mapped+=("${arg//\/app\//$root/app/}"); done
    case $1 in
        true) return 0 ;;
        chown) return 0 ;;
        node)
            js=$3
            case $js in
                *'/api/ping'*) [[ $(value "$id" entrypoint) =~ $runtime_entrypoint_re ]] && healthy "$id" && grep -qx "PORT=$4" "$FAKE/ct/$id/listening" ;;
                *'/api/auth/status'*) [[ -e $data/account ]] ;;
                *'bootstrap.json'*)
                    local email password
                    IFS= read -r email; IFS= read -r password || true
                    if [[ -z $password ]]; then password=generated-password; (umask 077; printf '%s\n' "$password" > "$data/osr-target/initial-admin-password"); fi
                    printf '{"admin":{"email":"%s","password":"%s"}}' "$email" "$password" > "$data/osr-target/bootstrap.json" ;;
                *'unified_api_key'*) [[ -s $data/freeapi.db && -z ${FAKE_NO_KEY:-} ]] || return 2; tr -d '\n' < "$data/freeapi.db" ;;
                *'/v1/models?available=true'*) healthy "$id" && [[ -z ${FAKE_KEY_REFUSED:-} && $(cat) == "$(cat "$data/freeapi.db")" ]] ;;
                *) echo "fake pct exec: unknown node script" >&2; return 97 ;;
            esac ;;
        sh)
            # The guest scripts name accounts and owners a test host lacks.
            local script=${mapped[2]}
            script=${script//id node >\/dev\/null/:}
            script=${script//install -d -o root -g node -m 0750/install -d -m 0750}
            script=$(sed -E 's/^chown (node:node|root:node) /: /' <<< "$script")
            sh -c "$script" "${mapped[@]:3}" ;;
        tar)
            # The CT's root cannot read the volume's lost+found (owned by the
            # host's root): GNU tar fails on it unless it is excluded.
            # Only an archive of the whole directory (member "data") reaches it.
            if [[ " ${mapped[*]} " == *' -cf - data ' && " ${mapped[*]} " != *' --exclude=lost+found '* && -d $data/lost+found ]]; then
                printf 'tar: data/lost+found: Cannot open: Permission denied\n' >&2
                printf 'tar: Exiting with failure status due to previous errors\n' >&2
                return 2
            fi
            "${mapped[@]}" ;;
        sed|test|cat|rm) "${mapped[@]}" ;;
        /usr/local/bin/manage-model-servers)
            [[ -z ${FAKE_ROUTER_REFUSES:-} ]] || return 1
            { printf '%s\n' "${*:2}"; cat; } > "$FAKE/router-call" ;;
        *) echo "fake pct exec: unknown command $1" >&2; return 98 ;;
    esac
}

case $name in
    # Archives here are plain tar, which zstd passes through, except that, like
    # the real zstd, empty input still gives a nonempty file (a 13-byte empty
    # frame), and that frame decompresses to nothing.
    zstd)
        empty_frame='\x28\xb5\x2f\xfd\x24\x00\x01\x00\x00\x99\xe9\xd8\x51'
        case $1 in
            -q) [[ $# -eq 1 ]] || exit 2
                stream=$(mktemp); cat > "$stream"
                if [[ -s $stream ]]; then cat -- "$stream"; else printf "$empty_frame"; fi
                rm -f -- "$stream" ;;
            -dc) [[ ${2:-} == -- && -f ${3:-} ]] || exit 2
                 cmp -s -- "$3" <(printf "$empty_frame") || cat -- "$3" ;;
            *) exit 2 ;;
        esac ;;
    pveversion) printf 'pve-manager/%s/0123abcd (running kernel: 6.17.2-1-pve)\n' "${FAKE_PVE_VERSION:-9.1.2}" ;;
    pvesh) [[ $1 == get && $2 == /cluster/nextid ]] || exit 2; ! exists "$4" ;;
    pvesm) [[ $1 == path ]] || exit 2; mkdir -p "$(template_dir)"; printf '%s/%s\n' "$(template_dir)" "${2##*/}" ;;
    skopeo)
        case "$1 ${4:-}" in
            'inspect docker://'*)
                tag=${4##*:}
                if [[ $3 == '{{.Digest}}' ]]; then
                    [[ -z ${FAKE_REGISTRY_DOWN:-} ]] || exit 1
                    printf '%s\n' "${FAKE_DIGEST:-sha256:$(printf '%s' "$tag" | sha256sum | cut -d' ' -f1)}"
                else printf '%s\n' "${FAKE_REVISION:-$(cat "$FAKE/commit")}"; fi ;;
            'inspect oci-archive:'*) sed -n 's/^revision=//p' "${4#oci-archive:}" ;;
            *)
                [[ $1 == copy && $2 == docker://*@sha256:* && $3 == oci-archive:* ]] || exit 2
                printf 'revision=%s\nsource=%s\n' "${FAKE_REVISION:-$(cat "$FAKE/commit")}" "$2" > "${3#oci-archive:}" ;;
        esac ;;
    vzdump)
        id=$1; shift
        dumpdir='' tmpdir='' stdout=''
        while (( $# )); do
            case $1 in
                --mode) [[ $2 == stop ]] || exit 1 ;;
                --compress) [[ $2 == zstd && -z $stdout ]] || exit 1 ;;
                --dumpdir) dumpdir=$2 ;;
                --tmpdir) tmpdir=$2 ;;
                --stdout) [[ $2 == 1 ]] || exit 1; stdout=1 ;;
                *) exit 1 ;;
            esac
            shift 2
        done
        # Like Proxmox's vzdump: a guest of another node is skipped, successfully.
        if [[ -n ${FAKE_VZDUMP_SKIPS:-} || ( -n ${FAKE_CT_NODE:-} && $FAKE_CT_NODE != "$(this_node)" ) ]]; then
            printf 'INFO: skip external VMs: %s\n' "$id" >&2
            exit 0
        fi
        [[ ( -n $dumpdir || -n $stdout ) && -z ${FAKE_VZDUMP_FAILS:-} ]] || exit 1
        ! running "$id" || exit 1
        # The real vzdump runs tar for an unprivileged CT as its mapped root,
        # reading the CT config from the temporary directory: by default
        # <dumpdir>/<name>.tmp, else <tmpdir>/vzdumptmp<pid>_<id>. Every
        # directory above it must let others through.
        tmp_parent=${tmpdir:-$dumpdir}
        [[ -n $tmp_parent ]] || exit 1
        # vzdump makes that directory with mkdir under the caller's umask.
        (( (8#777 & ~8#$(umask)) & 1 )) || {
            printf 'INFO: tar: %s/vzdumptmp%s_%s/: Cannot open: Permission denied\n' "$tmp_parent" "$$" "$id" >&2
            exit 1
        }
        [[ ! -d $tmp_parent ]] || {
            path=$(cd "$tmp_parent" && pwd)
            while [[ -n $path && $path != / ]]; do
                (( 8#$(stat -c %a "$path") & 1 )) || {
                    printf 'INFO: tar: %s/vzdump-lxc-%s.tmp: Cannot open: Permission denied\n' "$dumpdir" "$id" >&2
                    exit 1
                }
                path=${path%/*}
            done
        }
        cp "$(conf "$id")" "$FAKE/ct/$id/conf.saved"; cp "$PVE_ETC/firewall/$id.fw" "$FAKE/ct/$id/fw.saved"
        backup_meta=$(mktemp -d "$FAKE/backup-meta.XXXXXX")
        mkdir -p "$backup_meta/etc/vzdump"
        cp "$(conf "$id")" "$backup_meta/etc/vzdump/pct.conf"
        # FAKE_BARE_CONF: the configuration without the ./ that pct restore needs.
        member=./etc/vzdump/pct.conf
        [[ -z ${FAKE_BARE_CONF:-} ]] || member=etc/vzdump/pct.conf
        if [[ -n $stdout ]]; then tar -C "$FAKE/ct" -cf - "$id" -C "$backup_meta" "$member"
        else tar -C "$FAKE/ct" -cf "$dumpdir/vzdump-lxc-$id-2026_11_16-00_00_00.tar.zst" "$id" -C "$backup_meta" "$member"; fi
        rm -rf -- "$backup_meta" ;;
    pct)
        command=$1 id=${2:-}; shift 2 || true
        case $command in
            --osr-node) [[ -n ${FAKE_CT_NODE:-} ]] || exit 99; exists "$id" && printf '%s\n' "$FAKE_CT_NODE"; exit 0 ;;
            --osr-local-node) [[ -n ${FAKE_CT_NODE:-} ]] || exit 99; echo pve1 ;;
            --osr-on-node) [[ -n ${FAKE_CT_NODE:-} && -n $id && $# -ge 1 ]] || exit 99
                           # FAKE_NODE_LACKS=zstd: that command is not installed on the node.
                           [[ -z ${FAKE_NODE_LACKS:-} || $* != *"command -v $FAKE_NODE_LACKS"* ]] || exit 1
                           FAKE_ON_NODE=$id exec "$@" ;;
            status) exists "$id" || exit 2; if running "$id"; then echo 'status: running'; else echo 'status: stopped'; fi ;;
            config) exists "$id" || exit 2; cat "$(conf "$id")" ;;
            create)
                ! exists "$id" || exit 1
                # FAKE_DUMP_VANISHES: the backup is gone by the time a CT is created.
                [[ -z ${FAKE_DUMP_VANISHES:-} ]] || rm -f "${OSR_FREELLMAPI_STATE:-/nonexistent}"/*/vzdump-lxc-*.tar.zst
                # FAKE_CREATE_FAILS: a release whose template pct create refuses.
                [[ -z ${FAKE_CREATE_FAILS:-} || $1 != *"freellmapi_${FAKE_CREATE_FAILS}.tar" ]] || { echo 'fake: create failed' >&2; exit 1; }
                template=$1; shift
                [[ $template == *:vztmpl/freellmapi_v*.tar && -f $(template_dir)/${template##*/} ]] || { echo 'no such template' >&2; exit 1; }
                # Proxmox opens the OCI archive inside the CT's user namespace,
                # as its mapped root: the template must be readable by others.
                (( 8#$(stat -c %a "$(template_dir)/${template##*/}") & 4 )) ||
                    { echo "fake: unable to open OCI archive ${template##*/}: Permission denied" >&2; exit 1; }
                # mp0 is a fresh file system: its root has a lost+found.
                mkdir -p "$FAKE/ct/$id" "$(fs "$id")/app/server/data/lost+found"
                chmod 0700 "$(fs "$id")/app/server/data/lost+found"
                version=${template##*freellmapi_}; printf '%s\n' "${version%.tar}" > "$FAKE/ct/$id/image"
                this_node > "$FAKE/ct/$id/node"
                {
                    printf 'arch: amd64\n'
                    [[ -n ${FAKE_NO_ENTRYPOINT:-} ]] || printf 'entrypoint: %s\n' "$entrypoint"
                    while (( $# )); do
                        key=${1#--} val=$2; shift 2
                        case $key in
                            rootfs) printf 'rootfs: %s:vm-%s-disk-0,size=%sG\n' "${val%%:*}" "$id" "${val##*:}" ;;
                            mp0) store=${val%%:*} rest=${val#*:}; printf 'mp0: %s:vm-%s-disk-1,%s,size=%sG\n' "$store" "$id" "${rest#*,}" "${rest%%,*}" ;;
                            net0) [[ $val == *hwaddr=* ]] || val+=",hwaddr=BC:24:11:00:00:$(printf '%02X' $(( id % 256 )))"; printf 'net0: %s\n' "$val" ;;
                            description) printf 'description: %s\n' "$(sed ':a;N;$!ba;s/\n/%0A/g; s/ /%20/g' <<< "$val")" ;;
                            *) printf '%s: %s\n' "$key" "$val" ;;
                        esac
                    done
                } > "$(conf "$id")" ;;
            set)
                exists "$id" || exit 2
                while (( $# )); do set_value "$id" "${1#--}" "$2"; shift 2; done ;;
            start)
                exists "$id" || exit 2
                rm -f "$FAKE/ct/$id/listening"
                if [[ $(value "$id" entrypoint) == 'sleep infinity' ]]; then : > "$FAKE/ct/$id/running"
                elif server_start "$id"; then : > "$FAKE/ct/$id/running"
                fi ;;   # a server that exits leaves the CT stopped; pct start itself succeeded
            stop) exists "$id" || exit 2; rm -f "$FAKE/ct/$id/running" "$FAKE/ct/$id/listening" ;;
            destroy)
                exists "$id" && ! running "$id" || exit 1
                [[ -z ${FAKE_DESTROY_FAILS:-} ]] || exit 1
                rm -rf -- "$FAKE/ct/${id:?}" "$(conf "$id")" "$PVE_ETC/firewall/$id.fw" ;;
            restore)
                ! exists "$id" && [[ -f $1 && $2 == --storage && -z ${FAKE_RESTORE_FAILS:-} ]] || exit 1
                tar -C "$FAKE/ct" -xf "$1" "$id"
                mv "$FAKE/ct/$id/conf.saved" "$(conf "$id")"; mv "$FAKE/ct/$id/fw.saved" "$PVE_ETC/firewall/$id.fw"
                this_node > "$FAKE/ct/$id/node"
                rm -f "$FAKE/ct/$id/running" "$FAKE/ct/$id/listening" ;;
            exec) [[ $1 == -- ]] && shift; guest_exec "$id" "$@" ;;
            *) echo "fake pct: unknown command $command" >&2; exit 99 ;;
        esac ;;
    *) echo "fake-pve: unknown name $name" >&2; exit 99 ;;
esac
