#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
source "$here/pve-select.sh"
# Every target that sources the shared selector carries an identical copy.
for provisioner in "$here"/*/provision-lxc.sh; do
    [[ -f $provisioner ]] || continue
    target=$(basename "$(dirname "$provisioner")")
    grep -q 'pve-select\.sh' "$provisioner" || continue
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
CT_ID=159
pve_prompt_required CT_ID 'Container ID'
[[ $CT_ID == 159 ]] || die 'an explicit CT ID was changed'
CT_ID=''
# shellcheck disable=SC2034  # read by the sourced pve-select.sh
NONINTERACTIVE=true
if message=$(pve_prompt_required CT_ID 'Container ID' 2>&1); then
    die 'an unattended install accepted a missing CT ID'
fi
[[ $message == *'Set CT_ID for unattended provisioning'* ]] || die "missing CT ID gave the wrong error: $message"
unset NONINTERACTIVE dry_run

# --- guided prompts -----------------------------------------------------------
lxc=$(mktemp -d)
trap 'rm -f -- "$cfg"; rm -rf -- "$lxc"' EXIT
export PVE_LXC_DIR=$lxc
printf 'hostname: router\nnet0: name=eth0,bridge=vmbr0,gw=192.0.2.1,hwaddr=AA:BB,ip=192.0.2.80/24,type=veth\ntags: ai;ai-tools;osr-router;openwebui\n[snap]\ntags: honcho\n' > "$lxc/250.conf"
printf 'hostname: honcho\nnet0: name=eth0,bridge=vmbr1,ip=192.0.2.85/24,gw=192.0.2.1\ntags: ai;ai-tools;osr-target;honcho\n' > "$lxc/285.conf"
printf 'hostname: h1\ntags: osr-target;hermes\n' > "$lxc/290.conf"
printf 'hostname: h2\ntags: hermes;osr-target\n' > "$lxc/291.conf"
[[ $(pve_tagged_ct osr-router) == 250 ]] || die 'the router CT was not found by its tag'
[[ $(pve_tagged_ct honcho) == 285 ]] || die 'a tag in a snapshot section counted'
[[ -z $(pve_tagged_ct hermes) ]] || die 'two CTs with one tag gave an answer'
[[ -z $(pve_tagged_ct osr) ]] || die 'a tag prefix matched'
[[ $(pve_ct_net 250 ip) == 192.0.2.80 && $(pve_ct_net 250 cidr) == 192.0.2.80/24 ]] || die 'router address'
[[ $(pve_ct_net 250 gw) == 192.0.2.1 && $(pve_ct_net 285 bridge) == vmbr1 ]] || die 'router gateway or bridge'
[[ -z $(pve_ct_net 999 ip) ]] || die 'a missing CT has an address'
[[ $(pve_ct_with_ip 192.0.2.85) == 285 && -z $(pve_ct_with_ip 192.0.2.8) ]] || die 'CT by address'

pve_valid_optional_url() { [[ -z $1 || $1 =~ ^https?:// ]]; }
export PVE_INTERACTIVE=true
# A create run asks Router, then the container, in that order, offering the
# router CT, its address and gateway; Enter takes them.
ROUTER_CT_ID='' ROUTER_IP='' CT_ID='' IP_CIDR='' GATEWAY=''
prompts=$( { pve_ask_router ip; pve_ask_new_ct Honcho; pve_ask_network Honcho
  printf 'ROUTER_CT_ID=%s ROUTER_IP=%s CT_ID=%s IP_CIDR=%s GATEWAY=%s\n' "$ROUTER_CT_ID" "$ROUTER_IP" "$CT_ID" "$IP_CIDR" "$GATEWAY" >&2
  } 2>&1 >/dev/null <<< $'\n\n286\n192.0.2.86/24\n\n')
order=$(grep -oE '== [A-Za-z ]+ ==|Router CT ID|Router IP|New Honcho CT ID|Honcho IP/CIDR|Honcho gateway' <<< "$prompts" | paste -sd'|')
[[ $order == '== Router ==|Router CT ID|Router IP|== Honcho container ==|New Honcho CT ID|Honcho IP/CIDR|Honcho gateway' ]] ||
    die "prompts out of order: $order"
[[ $prompts == *'Router CT ID [250]'* && $prompts == *'Router IP [192.0.2.80]'* && $prompts == *'Honcho gateway [192.0.2.1]'* ]] ||
    die "router, address and gateway were not offered: $prompts"
[[ $prompts == *'New Honcho CT ID (unused): '* ]] || die 'a new CT ID was suggested'
[[ $prompts == *'ROUTER_CT_ID=250 ROUTER_IP=192.0.2.80 CT_ID=286 IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1'* ]] ||
    die "Enter did not take the suggestions: $prompts"
# A wrong answer is explained and asked again; a preset is never asked.
CT_ID='' IP_CIDR=10.0.0.5/24 GATEWAY=''
out=$( { pve_ask_new_ct X; pve_ask_network X dhcp; printf 'CT_ID=%s GATEWAY=%s\n' "$CT_ID" "$GATEWAY"; } 2>&1 <<< $'12\n300\n10.0.0.1\n')
[[ $out == *'Use a free numeric ID of 100 or more.'* && $out == *'CT_ID=300 GATEWAY=10.0.0.1'* ]] || die "invalid answer handling: $out"
[[ $out != *'X IP/CIDR'* ]] || die 'a preset address was asked again'
IP_CIDR='' GATEWAY=''
out=$( { pve_ask_network X dhcp; printf 'IP=%s GW=%s\n' "$IP_CIDR" "$GATEWAY"; } 2>&1 <<< $'dhcp\n')
[[ $out == *'IP=dhcp GW='* && $out != *'X gateway'* ]] || die "dhcp still asked for a gateway: $out"
# pve_ask: Enter keeps the default (the recorded value on a reconfigure).
SETTING=''
out=$( { pve_ask SETTING 'Chat model' qwen3:8b; printf 'SETTING=%s\n' "$SETTING"; } 2>&1 <<< $'\n')
[[ $out == *'Chat model [qwen3:8b]: '* && $out == *'SETTING=qwen3:8b'* ]] || die "default was not kept: $out"
SETTING=''
out=$( { pve_ask SETTING 'Chat model' qwen3:8b; printf 'SETTING=%s\n' "$SETTING"; } 2>&1 <<< $'gemma4:12b\n')
[[ $out == *'SETTING=gemma4:12b'* ]] || die "an answer did not replace the default: $out"
FLAG=''
out=$( { pve_ask_yes_no FLAG 'Enable it?' true; printf 'FLAG=%s\n' "$FLAG"; } 2>&1 <<< $'maybe\nn\n')
[[ $out == *'Answer y or n.'* && $out == *'FLAG=false'* ]] || die "yes/no: $out"
# pve_confirm: no stops before any change; Enter goes ahead.
( pve_confirm 'Create it?' <<< $'\n' ) 2>/dev/null || die 'Enter did not confirm'
if ( pve_confirm 'Create it?' <<< $'n\n' ) 2>/dev/null; then die '"n" did not stop'; fi
( PVE_CONFIRM=false pve_confirm 'Create it?' < /dev/null ) || die 'PVE_CONFIRM=false still asked'
# pve_offer: Enter takes the suggestion, "none" refuses it.
OPT=''
out=$( { pve_offer OPT 'Honcho API URL' http://h:8000 pve_valid_optional_url; printf 'OPT=%s\n' "$OPT"; } 2>&1 <<< $'\n')
[[ $out == *'Honcho API URL (none to skip) [http://h:8000]: '* && $out == *'OPT=http://h:8000'* ]] || die "offer: $out"
OPT=''
out=$( { pve_offer OPT 'Honcho API URL' http://h:8000 pve_valid_optional_url; printf 'OPT=%s.\n' "$OPT"; } 2>&1 <<< $'none\n')
[[ $out == *'OPT=.'* ]] || die "none did not refuse the offer: $out"
# A section with nothing to ask prints nothing; under the OSR installer
# (PVE_ACCEPT_DEFAULTS=true) defaults are taken and only missing required
# values are asked.
SETTING=preset
out=$( { pve_section Quiet; pve_note 'never shown'; pve_ask SETTING 'Chat model' fast; } 2>&1 < /dev/null)
[[ -z $out ]] || die "an empty section printed: $out"
SETTING='' CT_ID='' OPT=''
out=$( { export PVE_ACCEPT_DEFAULTS=true; pve_section Installer; pve_ask SETTING 'Chat model' fast
         pve_offer OPT 'Honcho URL' http://h:8000 pve_valid_optional_url; pve_ask_new_ct X
         printf 'SETTING=%s OPT=%s. CT_ID=%s\n' "$SETTING" "$OPT" "$CT_ID"; } 2>&1 <<< $'333\n' )
[[ $out != *'Chat model'* && $out != *'Honcho URL'* && $out == *'SETTING=fast OPT=. CT_ID=333'* ]] ||
    die "the installer mode asked a default or skipped a required value: $out"
[[ $out == *'== X container =='* && $out != *'== Installer =='* ]] || die "installer mode headings: $out"
# pve_existing_ct offers the tagged CT.
CT_ID=''
out=$( { pve_ask_existing_ct honcho Honcho; printf 'CT_ID=%s\n' "$CT_ID"; } 2>&1 <<< $'\n')
[[ $out == *'== Honcho container to reconfigure =='* && $out == *'Honcho CT ID [285]'* && $out == *'CT_ID=285'* ]] ||
    die "reconfigure CT: $out"

# Unattended: a default (recorded value) is used silently; a CT ID, address or
# gateway is never taken from a suggestion.
export PVE_INTERACTIVE=false
SETTING=''
pve_ask SETTING 'Chat model' fast 2>/dev/null
[[ $SETTING == fast ]] || die 'an unattended run did not take the default'
OPT=''
pve_offer OPT 'Honcho API URL' http://h:8000 pve_valid_optional_url
[[ -z $OPT ]] || die 'an unattended run took an offer'
OPTIONAL=''
pve_ask OPTIONAL 'Optional URL' '' pve_valid_optional_ipv4
[[ -z $OPTIONAL ]] || die 'an optional setting was filled in'
ROUTER_CT_ID=''
if message=$( (pve_ask_router) 2>&1 ); then die 'an unattended run took the tagged router'; fi
[[ $message == *'Set ROUTER_CT_ID for unattended provisioning'* ]] || die "unattended router: $message"
GATEWAY='' IP_CIDR=192.0.2.86/24
if ( pve_ask_network X ) 2>/dev/null; then die 'an unattended run took the suggested gateway'; fi
( pve_confirm 'Create it?' < /dev/null ) || die 'an unattended run asked to confirm'
[[ $(pve_row Model fast 2>&1) == '  Model                      fast' ]] || die 'summary row format'

# CT descriptions as Proxmox keeps them: URL-encoded on one line, with the
# trailing newline the GUI's Notes field adds, or notes below the first line.
pct() { [[ $1 == config ]] && printf 'hostname: x\ndescription: %s\ntags: t\n' "$FAKE_DESCRIPTION"; }
want='DeepSeek Harness for Ollama Smart Router'
for d in "$want" "$want%0A" "$want%0A%0A" "$want %0A" "$want%0Akept for the team%3A do not delete%0A" 'DeepSeek%20Harness for Ollama Smart Router'; do
    FAKE_DESCRIPTION=$d pve_ct_described 159 "$want" || die "description not recognised: $d"
done
for d in "$want 2" "Not $want" 'DeepSeek Harness' "x%0A$want" ''; do
    if FAKE_DESCRIPTION=$d pve_ct_described 159 "$want"; then die "wrong description accepted: $d"; fi
done
unset -f pct

# pve_ensure_tags adds only the missing tags, keeps the others and their order,
# and changes nothing when every tag is there.
pct() {
    case $1 in
        config) [[ -z $FAKE_TAGS ]] || printf 'hostname: x\ntags: %s\n' "$FAKE_TAGS" ;;
        set) printf '%s\n' "$*" >> "$tag_log"; [[ ${FAKE_SET_FAILS:-0} == 0 ]] ;;
    esac
}
tag_log=$(mktemp); trap 'rm -f -- "$tag_log"' EXIT
FAKE_TAGS='community-script;ai' pve_ensure_tags 286 ai ai-model osr-target comfyui 2>/dev/null
[[ $(cat "$tag_log") == 'set 286 --tags community-script;ai;ai-model;osr-target;comfyui' ]] ||
    die "missing tags were not merged: $(cat "$tag_log")"
: > "$tag_log"
FAKE_TAGS='' pve_ensure_tags 286 osr-target comfyui 2>/dev/null
[[ $(cat "$tag_log") == 'set 286 --tags osr-target;comfyui' ]] || die "an untagged CT was not tagged: $(cat "$tag_log")"
: > "$tag_log"
FAKE_TAGS='mine, osr-target ;comfyui' pve_ensure_tags 286 osr-target comfyui 2>/dev/null
[[ ! -s $tag_log ]] || die "a fully tagged CT was changed: $(cat "$tag_log")"
FAKE_TAGS='osr-target-old' pve_ensure_tags 286 osr-target 2>/dev/null
[[ $(cat "$tag_log") == 'set 286 --tags osr-target-old;osr-target' ]] || die "a tag prefix counted as the tag: $(cat "$tag_log")"
: > "$tag_log"
out=$(FAKE_TAGS='' FAKE_SET_FAILS=1 pve_ensure_tags 286 osr-target comfyui 2>&1) || die 'a failed pct set was fatal'
[[ $out == *'pct set 286 --tags osr-target\;comfyui'* ]] || die "a failed pct set gave no fix: $out"
: > "$tag_log"
out=$(dry_run=1 FAKE_TAGS='' pve_ensure_tags 286 osr-target comfyui)
[[ $out == '+ tag CT 286 osr-target;comfyui (pct set --tags, keeping its other tags)' && ! -s $tag_log ]] ||
    die "a dry run changed or misreported tags: $out"
unset -f pct
printf 'Template, storage, required-input and guided-prompt, CT description and tag tests passed.\n'
