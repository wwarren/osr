#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
source "$here/pve-select.sh"
for target in airllm basalt comfyui gitea hermes mattermost maya ollama strata xolotl; do
    cmp -s "$here/pve-select.sh" "$here/$target/pve-select.sh" || die "$target has an outdated selector copy"
done

pvesm() {
    case "$*" in
        'status -content vztmpl') cat <<'TABLE'
Name Type Status Total (KiB) Used (KiB) Available (KiB) %
local dir active 100000000 1000000 99000000 1%
zstore dir active 100000000 1000000 99000000 1%
offline dir inactive 100000000 0 100000000 0%
TABLE
            ;;
        'status -content rootdir') cat <<'TABLE'
Name Type Status Total (KiB) Used (KiB) Available (KiB) %
small dir active 10000000 1000000 9000000 10%
large zfspool active 100000000 1000000 99000000 1%
offline dir inactive 100000000 0 100000000 0%
TABLE
            ;;
        *) return 1 ;;
    esac
}
pveam() {
    [[ $1 == list ]] || return 1
    case $2 in
        local) printf 'Volid Format Type Size\nlocal:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst tar.zst vztmpl 1000\n' ;;
        zstore) printf 'Volid Format Type Size\nzstore:vztmpl/debian-12-standard_12.9-1_amd64.tar.zst tar.zst vztmpl 1000\n' ;;
        *) return 1 ;;
    esac
}
pve_select_available() { return 0; }
TEMPLATE=''
pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-.*_amd64\.tar\.zst$' <<< '' 2>/dev/null
[[ $TEMPLATE == local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst ]] || die "wrong default template: $TEMPLATE"
TEMPLATE=''
pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-.*_amd64\.tar\.zst$' <<< $'9\n2\n' 2>/dev/null
[[ $TEMPLATE == zstore:vztmpl/debian-12-standard_12.9-1_amd64.tar.zst ]] || die "wrong selected template: $TEMPLATE"
STORAGE=''
pve_select_storage STORAGE rootdir 16 <<< $'1\n\n' 2>/dev/null
[[ $STORAGE == large ]] || die "undersized storage was accepted: $STORAGE"
TEMPLATE_STORAGE=''
pve_select_storage TEMPLATE_STORAGE vztmpl 0 <<< $'2\n' 2>/dev/null
[[ $TEMPLATE_STORAGE == zstore ]] || die "wrong template storage: $TEMPLATE_STORAGE"

cfg=$(mktemp)
trap 'rm -f -- "$cfg"' EXIT
printf 'dir: local\n  content vztmpl,iso\nlvmthin: pool\n  content rootdir,images\n' > "$cfg"
# shellcheck disable=SC2034  # read by the sourced pve-select.sh
STORAGE_CFG=$cfg
pvesm() {
    if [[ $* == 'status -content '* ]]; then printf 'Name Type Status Available (KiB)\n'; return 0; fi
    [[ $* == status ]] || return 1
    printf 'Name Type Status Available (KiB)\nlocal dir active 50000000\npool lvmthin active 30000000\n'
}
[[ $(pve_select_storage_rows rootdir) == $'pool\tlvmthin\t30000000' ]] || die 'rootdir fallback failed'
[[ $(pve_select_storage_rows vztmpl) == $'local\tdir\t50000000' ]] || die 'template fallback failed'

source "$here/pve-select.sh"
# shellcheck disable=SC2034  # read by pve_select_available
dry_run=1
TEMPLATE=''
pve_select_template TEMPLATE '^.*$' <<< ''
[[ -z $TEMPLATE ]] || die 'dry run queried the template menu'
printf 'Template and storage selector tests passed.\n'
