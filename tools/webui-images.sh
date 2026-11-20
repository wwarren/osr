#!/usr/bin/env bash
# Run on the Proxmox host: make the router Open WebUI's image generation
# engine (tools/webui-images.py, run in the router CT). Open WebUI then asks the
# router's image alias for pictures: a ComfyUI CT or a Colibri CT serving an
# image model, whichever is up.
#
#   bash tools/webui-images.sh [--dry-run] [webui-images.py options]
#
# ROUTER_CT_ID picks the router CT (default: the one CT tagged osr-router on
# this node). The Open WebUI admin API key or JWT comes from
# OPENWEBUI_ADMIN_TOKEN, or is asked for on a terminal; it reaches the router
# CT in a 0600 file that is removed afterwards, never on a command line.
# Options for webui-images.py: --expect-model NAME, --image-size WxH,
# --image-steps N, --replace-custom, --off.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/webui-images.py
[[ -r $script ]] || die "Missing $script"

dry_run=0
args=()
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --help|-h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --expect-model|--image-size|--image-steps)
            (( $# >= 2 )) || die "$1 needs a value"
            args+=("$1" "$2"); shift ;;
        --replace-custom|--off) args+=("$1") ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

# tagged_ct TAG: the one CT on this node tagged TAG, or nothing.
tagged_ct() {
    local dir=${PVE_LXC_DIR:-/etc/pve/lxc} file found=''
    [[ -d $dir ]] || return 0
    for file in "$dir"/*.conf; do
        [[ -f $file ]] || continue
        if awk -v tag="$1" '/^\[/ { exit }
            /^tags:/ { sub(/^tags:[[:space:]]*/, ""); n = split($0, t, /[;, ]+/)
                       for (i = 1; i <= n; i++) if (t[i] == tag) f = 1 }
            END { exit !f }' "$file"; then
            [[ -z $found ]] || return 0
            found=$(basename "$file" .conf)
        fi
    done
    [[ -z $found ]] || printf '%s\n' "$found"
}

router=${ROUTER_CT_ID:-$(tagged_ct osr-router)}
[[ $router =~ ^[1-9][0-9]{2,8}$ ]] || die 'Set ROUTER_CT_ID to the router CT (no single CT here is tagged osr-router).'
if (( dry_run )); then
    printf '+ pct push %s %s <stage>/webui-images.py, with the Open WebUI admin key in <stage>/admin-token (0600)\n' "$router" "$script"
    printf '+ pct exec %s -- python3 <stage>/webui-images.py --webui-url http://127.0.0.1:<PORT from /app/openwebui/.env> --admin-token-file <stage>/admin-token%s\n' \
        "$router" "$( ((${#args[@]})) && printf ' %q' "${args[@]}")"
    printf '+ remove <stage>\n'
    exit 0
fi
[[ $EUID -eq 0 ]] || die 'Run as root on the Proxmox host.'
command -v pct >/dev/null || die 'Missing pct: run this on the Proxmox host.'
[[ $(pct status "$router" 2>/dev/null) == 'status: running' ]] || die "Router CT $router is not running."
token=${OPENWEBUI_ADMIN_TOKEN:-}
unset OPENWEBUI_ADMIN_TOKEN
if [[ -z $token ]]; then
    [[ -t 0 ]] || die 'Set OPENWEBUI_ADMIN_TOKEN to an Open WebUI admin API key or JWT for unattended use.'
    read -r -s -p 'Open WebUI admin API key or JWT: ' token; printf '\n' >&2
    [[ -n $token ]] || die 'No admin key given; nothing was changed.'
fi
port=$(pct exec "$router" -- sh -c "sed -n 's/^PORT=//p' /app/openwebui/.env 2>/dev/null | head -n1" </dev/null || true)
port=${port//[$'\r\n ']/}
[[ $port =~ ^[0-9]{2,5}$ ]] || port=8080
stage=$(pct exec "$router" -- mktemp -d /root/webui-images.XXXXXX </dev/null)
stage=${stage//[$'\r\n']/}
[[ $stage =~ ^/root/webui-images\.[A-Za-z0-9]{6}$ ]] || die "Unexpected staging path in CT $router: $stage"
trap 'pct exec "$router" -- rm -rf -- "$stage" </dev/null >/dev/null 2>&1 || true' EXIT
pct push "$router" "$script" "$stage/webui-images.py" --perms 0700
for workflow in flux2-klein-4b-api.json flux2-klein-9b-api.json; do
    # OSR's own ComfyUI workflows: an engine still using one is not an admin's custom setup.
    [[ ! -r $here/../targets/comfyui/$workflow ]] ||
        pct push "$router" "$here/../targets/comfyui/$workflow" "$stage/$workflow" --perms 0600
done
printf '%s\n' "$token" | pct exec "$router" -- sh -c "umask 077; cat > '$stage/admin-token'"
pct exec "$router" -- python3 "$stage/webui-images.py" --webui-url "http://127.0.0.1:$port" \
    --admin-token-file "$stage/admin-token" ${args[@]+"${args[@]}"} </dev/null
