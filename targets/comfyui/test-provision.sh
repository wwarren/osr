#!/usr/bin/env bash
# targets/comfyui/provision-lxc.sh without Proxmox: helpers, dry-run plans and
# validation, then whole runs against stubbed pct/pvesh/curl/id: the order of
# checks, the community-script presets, the CT firewall, the guest install and
# the Open WebUI registration. Nothing is fetched or created.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/provision-lxc.sh
bash_bin=$(command -v bash)
common=(CT_ID=286 IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1 STORAGE=local-lvm ROUTER=280 NVIDIA_DEVICE=/nonexistent)
passed=0
out=''
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n%s\n' "$1" "$out" >&2; exit 1; }
has() { [[ $out == *"$1"* ]] || fail "output lacks: $1"; }
lacks() { [[ $out != *"$1"* ]] || fail "output contains: $1"; }
split_args() {
    flags=(); vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
}
# plan [--flag ...] [VAR=value ...]: a dry run with those flags and settings.
plan() {
    split_args "$@"
    out=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" "$bash_bin" "$tool" --dry-run "${flags[@]}" 2>&1) ||
        fail "plan failed: $*"
}
refuse() {
    local expect=$1; shift
    split_args "$@"
    if out=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" "$bash_bin" "$tool" --dry-run "${flags[@]}" 2>&1); then
        fail "accepted: $*"
    fi
    has "$expect"
    lacks '+ env var_'
}

# --- helpers in isolation ------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Provision helpers/ { capture=1; next } /^# End provision helpers/ { capture=0 } capture' "$tool")
for helper in allow_list gpu_kind community_gpu_choice community_vars firewall_config net_with_firewall classify_router route_src \
        normalize_pci_address card_vendor_kind card_device_nodes config_devices other_card_devices; do
    declare -F "$helper" >/dev/null || fail "helper extraction failed: $helper"
done
[[ $(allow_list '192.0.2.0/24, 198.51.100.7 203.0.113.0/28' | paste -sd' ') == '192.0.2.0/24 198.51.100.7 203.0.113.0/28' ]] || fail 'allow_list'
[[ -z $(allow_list '') ]] || fail 'allow_list empty'
! allow_list '192.0.2.0/33' >/dev/null && ! allow_list 'example.org' >/dev/null || fail 'allow_list accepted a bad entry'
pass 'UI_ALLOW_CIDR parsing'

[[ $(NVIDIA_DEVICE=/dev/null gpu_kind auto) == nvidia && $(NVIDIA_DEVICE=/nonexistent gpu_kind auto) == none ]] || fail 'gpu_kind auto'
[[ $(gpu_kind amd) == amd ]] && ! gpu_kind radeon >/dev/null || fail 'gpu_kind explicit'
[[ $(community_gpu_choice none)$(community_gpu_choice nvidia)$(community_gpu_choice amd)$(community_gpu_choice intel) == 1234 ]] ||
    fail 'community_gpu_choice must match the install script menu: [1]-None [2]-NVIDIA [3]-AMD [4]-Intel'
pass 'GPU selection and the community GPU menu answer'

out=$(firewall_config 8188 192.0.2.80 198.51.100.0/24)
has $'[OPTIONS]\nenable: 1\npolicy_in: DROP'
has 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8188 -log nolog # comfyui-target'
has 'IN ACCEPT -source 198.51.100.0/24 -p tcp -dport 8188'
[[ $(grep -c '^IN ' <<< "$out") == 2 ]] || fail 'firewall rule count'
pass 'firewall: inbound dropped except the ComfyUI port from each source'

[[ $(net_with_firewall 'name=eth0,bridge=vmbr0,ip=dhcp') == 'name=eth0,bridge=vmbr0,ip=dhcp,firewall=1' ]] || fail 'net_with_firewall add'
[[ $(net_with_firewall 'name=eth0,firewall=0,bridge=vmbr0') == 'name=eth0,bridge=vmbr0,firewall=1' ]] || fail 'net_with_firewall replace'
[[ $(net_with_firewall 'name=eth0,firewall=1,bridge=vmbr0') == 'name=eth0,firewall=1,bridge=vmbr0' ]] || fail 'net_with_firewall keep'
pass 'net0 gets firewall=1, other options kept'

[[ $(classify_router 280) == 'ct 280' && $(classify_router 192.0.2.80) == 'ssh 192.0.2.80' && $(classify_router router.lan) == 'ssh router.lan' ]] ||
    fail classify_router
! classify_router 99 >/dev/null && ! classify_router 300.1.1.1 >/dev/null || fail 'classify_router accepted a bad value'
[[ $(printf '192.0.2.86 dev eth0 src 192.0.2.80 uid 0\n' | route_src) == 192.0.2.80 ]] || fail route_src
pass 'router location and source-address helpers'

# --- dry runs -------------------------------------------------------------------
plan
has 'https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/comfyui.sh'
has '+ env var_ctid=286 var_hostname=comfyui var_cpu=4 var_ram=16384 var_disk=64 var_unprivileged=1 var_nesting=1 var_os=debian var_version=13 var_gpu=no var_comfyui_gpu_type=1 var_brg=vmbr0 var_net=192.0.2.86/24 var_gateway=192.0.2.1 var_container_storage=local-lvm bash '
has '+ write /etc/pve/firewall/286.fw:'
has 'IN ACCEPT -source <router-source-ip>/32 -p tcp -dport 8188'
has 'COMFYUI_DEVICE=cpu'
has 'bash /root/comfyui-target-deploy/install-target.sh'
has '--comfyui-url http://192.0.2.86:8188'
has '--variant klein-4b'; has 'COMFYUI_IMAGE_VARIANT=klein-4b'
has '+ check that the klein-4b weights answer on Hugging Face (3 files)'
has 'klein-weights.txt /root/comfyui-target-deploy/klein-weights.txt'; lacks 'hf-token'
has 'Pin and verify the ComfyUI release'
lacks 'install_nvidia'
pass 'default plan: community script with presets, firewall for the router, adoption, Open WebUI'

plan GPU=nvidia UI_ALLOW_CIDR=198.51.100.0/24 COMFYUI_PORT=8190 COMFYUI_MODEL_URL='https://huggingface.co/o/r/resolve/main/sd_xl_base_1.0.safetensors?download=true' \
    COMFYUI_IMAGE_SIZE=1024x1024 COMFYUI_IMAGE_STEPS=30
has 'var_gpu=yes var_comfyui_gpu_type=2'
has 'IN ACCEPT -source 198.51.100.0/24 -p tcp -dport 8190'
has 'install_nvidia_580_173_02.sh lxc'
has 'COMFYUI_DEVICE=gpu'; has 'COMFYUI_PORT=8190'
lacks '--model sd_xl_base_1.0.safetensors'; has '--image-size 1024x1024'; has '--image-steps 30'
pass 'NVIDIA, extra UI sources, a port, and a download that does not replace Klein in Open WebUI'

plan COMFYUI_IMAGE_MODEL=another-klein.safetensors
has '--model another-klein.safetensors'
pass 'an explicit diffusion model override reaches Open WebUI'

plan COMFYUI_IMAGE_VARIANT=klein-4b
has 'flux2-klein-4b-api.json'; has '--variant klein-4b'
pass 'the selected 4B workflow reaches Open WebUI'

plan --no-webui UI_ALLOW_CIDR=198.51.100.0/24
lacks 'pct exec 280'; lacks 'pct push 280'; lacks 'Open WebUI on'; lacks 'integrate-webui'; lacks '<router-source-ip>'
has 'IN ACCEPT -source 198.51.100.0/24'
pass '--no-webui never touches the router; the firewall admits UI_ALLOW_CIDR'

plan --no-webui FIREWALL=0
lacks '.fw:'; has 'open to anyone'
pass 'FIREWALL=0 writes no firewall and says so'

plan --integrate-only
lacks '+ curl'; lacks '+ env var_'; lacks '.fw:'; lacks 'pct exec 286 -- env'
has 'integrate-webui.py'
pass '--integrate-only only registers the existing CT'

refuse 'With --no-webui nothing would be admitted' --no-webui
refuse 'Use only one of' --integrate-only --no-webui
refuse '--integrate-only needs the existing CT_ID' --integrate-only CT_ID=
refuse 'MEMORY_MB must be at least 8192' MEMORY_MB=4096
refuse 'ROOTFS_GB must be at least 32' ROOTFS_GB=25
refuse 'GPU must be' GPU=radeon
refuse 'UI_ALLOW_CIDR' UI_ALLOW_CIDR=everyone
refuse 'COMFYUI_MODEL_URL must be an https URL' COMFYUI_MODEL_URL=http://example.org/m.safetensors
refuse 'COMFYUI_MODEL_URL must be an https URL' "COMFYUI_MODEL_URL=https://example.org/\$(id).safetensors"
refuse 'COMFYUI_MODEL_SHA256' COMFYUI_MODEL_SHA256=abc
refuse 'COMFYUI_MODEL_NAME must be a plain file name' COMFYUI_MODEL_NAME=../../etc/passwd
refuse 'COMFYUI_IMAGE_VARIANT' COMFYUI_IMAGE_VARIANT=sdxl
refuse 'COMFYUI_IMAGE_SIZE' COMFYUI_IMAGE_SIZE=big
refuse 'COMFYUI_PORT' COMFYUI_PORT=70000
refuse 'CT IDs must differ' ROUTER=286
refuse 'neither a CT ID' ROUTER=12
refuse 'COMMUNITY_SCRIPT_SHA256' COMMUNITY_SCRIPT_SHA256=abc
refuse 'IP_CIDR' IP_CIDR=192.0.2.300/24
pass 'invalid settings are refused before the community script is fetched or run'

"$bash_bin" -n "$tool"
"$bash_bin" -n "$here/install-target.sh"

# --- whole runs against stubs ------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/comfyui-provision-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bin=$tmp/bin; mkdir -p "$bin" "$tmp/pve/nodes" "$tmp/net/vmbr0"
log=$tmp/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
# The "community script" the stubbed curl downloads records the presets it got.
community=$tmp/community.sh
printf '#!/usr/bin/env bash\necho "community var_ctid=$var_ctid var_gpu=$var_gpu var_comfyui_gpu_type=$var_comfyui_gpu_type var_os=$var_os" >> "%s"\n' "$log" > "$community"
good_sha=$(sha256sum "$community" | awk '{ print $1 }')
# curl: -I answers FAKE_HF_STATUS (302) for weights, 403 for the gated 9B file
# without the header file holding FAKE_HF_TOKEN; -o gets the community script.
stub curl 'out=""; head=0; header=""; prev=""; url="${@: -1}"
for a in "$@"; do [[ $prev == -o ]] && out=$a; [[ $prev == -H ]] && header=${a#@}; [[ $a == -I ]] && head=1; prev=$a; done
if (( head )); then
    if [[ $url == *FLUX.2-klein-9b* ]] && ! grep -qx "Authorization: Bearer ${FAKE_HF_TOKEN:-none}" "$header" 2>/dev/null; then printf 403; exit 0; fi
    printf "%s" "${FAKE_HF_STATUS:-302}"; exit 0
fi
[[ -z $out ]] || cp "'"$community"'" "$out"'
stub pveversion 'exit 0'
stub id '[[ $1 == -u ]] && echo 0'
stub pvesh '[[ $* == *--vmid* ]] || echo 286; exit 0'
stub pve-firewall 'echo "Status: ${FAKE_FW_STATUS:-enabled/running}"'
# pct: the router is CT 280 with a healthy Open WebUI; the new CT is 286.
stub pct 'case "$*" in
    "status 280") echo "status: running" ;;
    "status 286") [[ -n ${FAKE_NO_CT:-} ]] && exit 2; echo "status: running" ;;
    "exec 280 -- systemctl is-active --quiet open-webui.service") exit "${FAKE_WEBUI_DOWN:-0}" ;;
    "exec 280 -- sh -c sed"*) echo 8080 ;;
    "exec 280 -- python3 -c "*) echo 0.12.4 ;;
    "exec 280 -- ip -4 route get "*) echo "192.0.2.86 dev eth0 src 192.0.2.80 uid 0" ;;
    "exec 280 -- mktemp "*) echo /root/comfyui-integration.AbC123 ;;
    "exec 280 -- python3 /root/comfyui-integration.AbC123/integrate-webui.py "*) exit "${FAKE_INTEGRATE_RC:-0}" ;;
    "exec 286 -- nvidia-smi -L") exit "${FAKE_NO_NVIDIA_SMI:-0}" ;;
    "exec 286 -- hostname -I") echo "192.0.2.86 fd00::86" ;;
    "exec 286 -- sed -n "*) echo 8191 ;;
    "config 286") echo "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:86,ip=192.0.2.86/24,gw=192.0.2.1,type=veth"
                  [[ -z ${FAKE_CT_DEVICES:-} ]] || printf "%s\n" "$FAKE_CT_DEVICES" ;;
    push*) [[ $* != *admin-token* ]] || cp "$3" "'"$tmp"'/pushed-token"
           [[ $* != *hf-token* ]] || cp "$3" "'"$tmp"'/pushed-hf-token" ;;
    "exec 286 -- env "*) exit "${FAKE_GUEST_RC:-0}" ;;
esac; exit 0'
fw=$tmp/pve/firewall/286.fw
real() {
    rm -f "$fw"; : > "$log"
    split_args "$@"
    out=$(env -i "PATH=$bin:$PATH" "${common[@]}" PVE_ETC="$tmp/pve" SYS_NET_DIR="$tmp/net" "${vars[@]}" \
        "$bash_bin" "$tool" "${flags[@]}" 2>&1)
}
calls() { cat "$log"; }

real OPENWEBUI_ADMIN_TOKEN=owui-secret GPU=nvidia NVIDIA_DEVICE=/dev/null FAKE_NO_NVIDIA_SMI=1 UI_ALLOW_CIDR=198.51.100.0/24 \
    COMMUNITY_SCRIPT_SHA256="$good_sha" COMFYUI_MODEL_URL=https://huggingface.co/o/r/resolve/main/v1-5.safetensors || fail "full run failed"
has "sha256 $good_sha"
grep -q 'community var_ctid=286 var_gpu=yes var_comfyui_gpu_type=2 var_os=debian' "$log" || fail "presets: $(calls)"
[[ $(cat "$fw") == "$(firewall_config 8188 192.0.2.80 198.51.100.0/24)" ]] || fail "firewall file: $(cat "$fw")"
grep -q 'pct set 286 --net0 name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:86,ip=192.0.2.86/24,gw=192.0.2.1,type=veth,firewall=1' "$log" ||
    fail "net0 not put behind the firewall: $(calls)"
grep -q 'pct exec 286 -- bash /root/comfyui-target-deploy/install_nvidia_580_173_02.sh lxc' "$log" || fail 'NVIDIA helper not run'
grep -q 'COMFYUI_DEVICE=gpu .*COMFYUI_MODEL_URL=https://huggingface.co/o/r/resolve/main/v1-5.safetensors' "$log" || fail 'guest install settings'
grep -q -- '--comfyui-url http://192.0.2.86:8188 --admin-token-file /root/comfyui-integration.AbC123/admin-token' "$log" ||
    fail "integration call: $(calls)"
grep -q 'flux2-klein-9b-api.json' "$log" || fail 'the API workflow was not staged on the router'
grep -q 'flux2-klein-4b-api.json' "$log" || fail 'the 4B API workflow was not staged on the router'
[[ $(cat "$tmp/pushed-token") == owui-secret ]] || fail 'the admin token was not staged on the router'
! grep -q owui-secret "$log" || fail 'the admin token appeared in a command line'
# Order: router checks and the token before the CT; firewall before the guest install.
order=$(grep -nE 'python3 -c |^community |pct set 286|install-target.sh$|integrate-webui.py --webui' "$log" | cut -d: -f1 | paste -sd' ')
[[ $order =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] || fail "unexpected steps ($order): $(grep -nE 'python3 -c |^community |pct set 286|install-target.sh$|integrate-webui.py --webui' "$log")"
read -r a b c d e <<< "$order"
(( a < b && b < c && c < d && d < e )) || fail "steps out of order ($order): $(calls)"
grep -q 'pct exec 280 -- rm -rf -- /root/comfyui-integration.AbC123' "$log" || fail 'router staging not removed'
pass 'a full run: Open WebUI checked, presets, firewall before adoption, NVIDIA helper, registration; token never in argv'

mkdir -p "$tmp/pve/firewall"
real_keep() { : > "$log"; split_args "$@"; out=$(env -i "PATH=$bin:$PATH" "${common[@]}" PVE_ETC="$tmp/pve" SYS_NET_DIR="$tmp/net" "${vars[@]}" "$bash_bin" "$tool" "${flags[@]}" 2>&1); }
echo '[OPTIONS]' > "$fw"
real_keep OPENWEBUI_ADMIN_TOKEN=t && fail 'an existing firewall file was replaced'
has 'Refusing to replace existing firewall file'; [[ $(cat "$fw") == '[OPTIONS]' ]] || fail 'firewall file changed'
! grep -q '^community' "$log" || fail 'the community script ran before the firewall check'
pass 'an existing firewall file stops the run before anything is created'

real OPENWEBUI_ADMIN_TOKEN=t FAKE_WEBUI_DOWN=3 && fail 'a stopped Open WebUI was accepted'
has 'open-webui.service) is not active'; ! grep -q '^community' "$log" || fail 'CT created although Open WebUI is down'
real && fail 'ran without an admin token'
has 'Set OPENWEBUI_ADMIN_TOKEN'; ! grep -q '^community' "$log" || fail 'CT created without a token'
real OPENWEBUI_ADMIN_TOKEN=t COMMUNITY_SCRIPT_SHA256="$(printf '0%.0s' {1..64})" && fail 'a changed community script ran'
has 'The community script changed'; ! grep -q '^community' "$log" || fail 'the unpinned script ran'
pass 'Open WebUI, the admin token and the script checksum are checked before the CT is created'

real OPENWEBUI_ADMIN_TOKEN=t FAKE_INTEGRATE_RC=1 && fail 'a failed registration was reported as success'
has 'CT 286 is kept'; has '--integrate-only'; lacks 'rerun the guest step'
pass 'a failed registration keeps the CT and says how to retry'

real --integrate-only OPENWEBUI_ADMIN_TOKEN=t || fail "--integrate-only failed: $out"
! grep -qE '^community|pct set|install-target.sh' "$log" || fail "--integrate-only changed the CT: $(calls)"
grep -q -- '--comfyui-url http://192.0.2.86:8191' "$log" || fail 'the CT'"'"'s configured port was not used'
[[ ! -e $fw ]] || fail '--integrate-only wrote a firewall'
pass "--integrate-only reads the CT's port and only registers it"

real --no-webui UI_ALLOW_CIDR=198.51.100.0/24 FAKE_FW_STATUS=disabled/running || fail "--no-webui failed: $out"
! grep -q 'pct exec 280' "$log" || fail '--no-webui touched the router'
[[ $(cat "$fw") == "$(firewall_config 8188 198.51.100.0/24)" ]] || fail '--no-webui firewall'
has 'the Proxmox firewall is not enabled for the datacenter'
pass '--no-webui: no router, the firewall admits UI_ALLOW_CIDR; a disabled datacenter firewall is reported'

# --- one card out of several (GPU_CARD) ---------------------------------------------
pci=$tmp/pci; nvp=$tmp/nvidia
mkdir -p "$pci/0000:03:00.0/drm/renderD128" "$pci/0000:03:00.0/drm/card0" "$pci/0000:04:00.0/drm/renderD129" \
    "$pci/0000:04:00.0/drm/card1" "$pci/0000:02:00.0" "$nvp/gpus/0000:02:00.0"
printf '0x1002\n' > "$pci/0000:03:00.0/vendor"; printf '0x1002\n' > "$pci/0000:04:00.0/vendor"; printf '0x10de\n' > "$pci/0000:02:00.0/vendor"
printf 'Device Minor: \t 1\n' > "$nvp/gpus/0000:02:00.0/information"
amd_devs=$'dev0: /dev/dri/renderD128,gid=104\ndev1: /dev/dri/card0,gid=44\ndev2: /dev/dri/renderD129,gid=104\ndev3: /dev/dri/card1,gid=44\ndev4: /dev/kfd,gid=104'
real OPENWEBUI_ADMIN_TOKEN=t GPU_CARD=0000:04:00.0 PCI_SYSFS="$pci" FAKE_CT_DEVICES="$amd_devs" || fail "GPU_CARD run failed"
grep -q 'community var_ctid=286 var_gpu=yes var_comfyui_gpu_type=3' "$log" || fail "GPU_CARD did not pick AMD: $(calls)"
grep -qx 'pct set 286 --delete dev0,dev1' "$log" || fail "other cards not removed: $(calls)"
has 'CT 286: passing only the GPU at 0000:04:00.0 (/dev/dri/renderD129 /dev/dri/card1).'
order=$(grep -nE '^community |pct stop 286|pct set 286 --delete|pct start 286|pct set 286 --net0|install-target.sh$' "$log" | cut -d: -f1 | paste -sd' ')
read -r a b c d e f <<< "$order"
[[ -n $f ]] && (( a < b && b < c && c < d && d < e && e < f )) || fail "narrowing out of order ($order): $(calls)"
grep -q 'COMFYUI_DEVICE=gpu' "$log" || fail 'the guest install runs without the GPU'
real OPENWEBUI_ADMIN_TOKEN=t GPU_CARD=0000:03:00.0 PCI_SYSFS="$pci" FAKE_CT_DEVICES=$'dev0: /dev/dri/renderD128,gid=104\ndev1: /dev/kfd,gid=104' ||
    fail "GPU_CARD, nothing to remove"
! grep -q 'pct stop 286' "$log" || fail 'restarted a CT that passes only the chosen card'
real OPENWEBUI_ADMIN_TOKEN=t GPU_CARD=0000:04:00.0 PCI_SYSFS="$pci" FAKE_CT_DEVICES=$'dev0: /dev/dri/renderD128,gid=104' || fail 'GPU_CARD, card not passed'
has 'Warning: CT 286 does not pass /dev/dri/renderD129, the GPU at 0000:04:00.0.'
nv_devs=$'dev0: /dev/nvidia0,gid=44\ndev1: /dev/nvidia1,gid=44\ndev2: /dev/nvidiactl,gid=44\ndev3: /dev/nvidia-uvm,gid=44\ndev4: /dev/nvidia-caps/nvidia-cap1,gid=44'
real OPENWEBUI_ADMIN_TOKEN=t GPU_CARD=02:00.0 PCI_SYSFS="$pci" NVIDIA_PROC="$nvp" FAKE_CT_DEVICES="$nv_devs" || fail "NVIDIA GPU_CARD run failed"
grep -q 'community var_ctid=286 var_gpu=yes var_comfyui_gpu_type=2' "$log" || fail "GPU_CARD did not pick NVIDIA: $(calls)"
grep -qx 'pct set 286 --delete dev0' "$log" || fail "the other NVIDIA card was kept: $(calls)"
real OPENWEBUI_ADMIN_TOKEN=t GPU=amd GPU_CARD=0000:02:00.0 PCI_SYSFS="$pci" && fail 'an NVIDIA GPU_CARD passed GPU=amd'
has 'GPU_CARD 0000:02:00.0 is an NVIDIA card, not AMD'; ! grep -q '^community' "$log" || fail 'the CT was created'
real OPENWEBUI_ADMIN_TOKEN=t GPU_CARD=0000:09:00.0 PCI_SYSFS="$pci" && fail 'a missing GPU_CARD passed'
has 'GPU_CARD: no NVIDIA, AMD or Intel GPU at 0000:09:00.0'
plan GPU_CARD=0000:04:00.0
has '+ keep only the GPU at 0000:04:00.0 in CT 286'
pass "GPU_CARD: only the chosen card's nodes stay in the CT (restarted before the firewall and guest install); a wrong vendor or missing card is refused first"

# --- the image model's weights -------------------------------------------------------
plan COMFYUI_IMAGE_VARIANT=klein-9b
has '+ stage the Hugging Face token for klein-9b (gated: https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8)'
has '/hf-token /root/comfyui-target-deploy/hf-token --perms 0600'
has 'COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE=/root/comfyui-target-deploy/hf-token bash'
has '+ pct exec 286 -- rm -f -- /root/comfyui-target-deploy/hf-token'; has '--variant klein-9b'
pass 'klein-9b: the token goes into the CT as a file for the guest step, and is removed after it'

plan COMFYUI_DOWNLOAD_WEIGHTS=0
has 'COMFYUI_IMAGE_VARIANT=none'; lacks 'answer on Hugging Face'; has 'No weights were downloaded'; has '--variant klein-4b'
plan --integrate-only
has '--variant auto'; lacks 'answer on Hugging Face'
refuse 'COMFYUI_DOWNLOAD_WEIGHTS' COMFYUI_DOWNLOAD_WEIGHTS=yes
pass 'COMFYUI_DOWNLOAD_WEIGHTS=0 skips the download; --integrate-only downloads nothing and lets Open WebUI pick'

hf_token='hf_Q1w2E3r4T5Q1w2E3r4T5Q1w2E3r4T5Q1w2E3r4T5'
real OPENWEBUI_ADMIN_TOKEN=t COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN="$hf_token" FAKE_HF_TOKEN="$hf_token" || fail "9B run failed: $out"
[[ $(cat "$tmp/pushed-hf-token") == "$hf_token" ]] || fail 'the token was not pushed into the CT'
! grep -q "$hf_token" "$log" || fail 'the Hugging Face token appeared in a command line'
grep -q 'curl .* -I -H @.*hf-headers -- https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8/' "$log" ||
    fail "the gated file was not checked with the token: $(calls)"
grep -q 'pct exec 286 -- rm -f -- /root/comfyui-target-deploy/hf-token' "$log" || fail 'the token was left in the CT'
[[ $(grep -n 'curl .* -I ' "$log" | head -n1 | cut -d: -f1) -lt $(grep -n '^community' "$log" | cut -d: -f1) ]] ||
    fail 'the weights were checked after the CT was created'
pass 'klein-9b: the token is checked against the gated file before the CT exists, pushed as a file, never in argv, then removed'

real OPENWEBUI_ADMIN_TOKEN=t COMFYUI_IMAGE_VARIANT=klein-9b && fail '9B ran without a token'
has 'set HF_TOKEN'; ! grep -q '^community' "$log" || fail 'CT created without the token'
real OPENWEBUI_ADMIN_TOKEN=t COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN="$hf_token" FAKE_HF_TOKEN=other && fail 'a refused token was accepted'
has 'Hugging Face refused flux-2-klein-9b-fp8.safetensors (HTTP 403)'; has 'Nothing was created'
! grep -q '^community' "$log" || fail 'CT created with a refused token'
real OPENWEBUI_ADMIN_TOKEN=t COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN=nope && fail 'a malformed token was accepted'
has 'must be an access token'
real OPENWEBUI_ADMIN_TOKEN=t FAKE_HF_STATUS=000 && fail 'unreachable weights were accepted'
has 'did not answer from this host'; has 'COMFYUI_DOWNLOAD_WEIGHTS=0'; ! grep -q '^community' "$log" || fail 'CT created anyway'
pass 'no token, a refused or malformed token, or unreachable weights stop the run before the CT is created'

real OPENWEBUI_ADMIN_TOKEN=t COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN="$hf_token" FAKE_HF_TOKEN="$hf_token" FAKE_GUEST_RC=1 &&
    fail 'a failed guest step was reported as success'
grep -q 'pct exec 286 -- rm -f -- /root/comfyui-target-deploy/hf-token' "$log" || fail 'a failed run left the token in the CT'
has 'COMFYUI_IMAGE_VARIANT=klein-9b bash /root/comfyui-target-deploy/install-target.sh'; has 'HF_TOKEN_FILE='
pass 'a failed guest step still removes the token, and says how to resume the download'

printf '%s provision cases passed. Nothing was fetched or created.\n' "$passed"
