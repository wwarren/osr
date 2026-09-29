#!/usr/bin/env bash
# Run on the PVE host to create a NEW AirLLM inference target. Never on the router CT/VM.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--install-target] [--dry-run]

Creates an unprivileged LXC for the AirLLM target, copies the deployment files
to /root/airllm-target-deploy, and with --install-target (or INSTALL_TARGET=1)
runs install-target.sh inside it.

Missing settings are prompted on a terminal: CT ID, template, IPv4/CIDR or
dhcp, gateway, root disk storage. NONINTERACTIVE=true disables prompts; then
CT_ID, TEMPLATE, STORAGE and IP_CIDR are required.
  CT_ID=<id>  TEMPLATE=<storage>:vztmpl/<debian-12|debian-13|ubuntu-24.04|ubuntu-26.04>-...tar.zst
  STORAGE=<rootdir storage>  IP_CIDR=<a.b.c.d/nn|dhcp>  GATEWAY=<a.b.c.d>
Optional: CT_HOSTNAME=airllm-target, BRIDGE=vmbr0, NAMESERVER, VLAN_TAG,
          CORES=4, MEMORY_MB=32768, SWAP_MB=4096, ROOTFS_GB=<sized for the model>,
          ONBOOT=0, SSH_PUBLIC_KEY=<file>,
          GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
          AIRLLM_MODEL_ID=Qwen/Qwen2.5-72B-Instruct, AIRLLM_MODEL_ALIAS=
ROOTFS_GB defaults to what the model needs (its weights twice, for the download
and AirLLM's shards, plus 20 GB) and at least 64. A smaller explicit value is
refused unless ALLOW_SMALL_DISK=true.
No root password is set: use `pct enter <id>` or SSH_PUBLIC_KEY.
With GPU_DEVICES the CT gets those devices, the NVIDIA 580.173.02 user-space
helper runs before the installer, and the model streams through cuda:0.
--dry-run validates inputs and prints the commands without creating anything.
USAGE
}

# Container configuration helpers (read-only).
positive_int() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
ipv4() {
    local value=$1 octet
    local -a octets
    [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
}
valid_container_id() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( $1 >= 100 )); }
valid_container_template() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(debian-1[23]|ubuntu-2[46]\.04)-[A-Za-z0-9._-]+\.tar\.(zst|xz|gz)$ ]]
}
valid_container_storage() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_container_gateway() { [[ -z $1 ]] || ipv4 "$1"; }
valid_container_ip() {
    local address prefix
    [[ $1 != dhcp ]] || return 0
    [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    ipv4 "$address" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 ))
}
template_ostype() { [[ $1 == *:vztmpl/ubuntu-* ]] && printf 'ubuntu' || printf 'debian'; }
# Parameter count in billions parsed from a repo id ("Qwen2.5-72B" -> 72); empty when unknown.
model_billions() {
    local name=${1//[-_]/ }
    [[ $name =~ (^|[^0-9.])([0-9]+(\.[0-9]+)?)[[:space:]]*[bB]([^A-Za-z0-9]|$) ]] && printf '%s' "${BASH_REMATCH[2]}"
}
# Root disk the model needs: bf16 weights twice + 5% + 20 GB; at least 64.
model_disk_gb() {
    local billions
    billions=$(model_billions "$1") || true
    [[ -n $billions ]] || { printf '64'; return; }
    awk -v b="$billions" 'BEGIN { n = int(b * 2 * 2 * 1.05 + 20 + 0.999); print (n < 64 ? 64 : n) }'
}
container_prompt_available() { [[ $NONINTERACTIVE == false && -t 0 ]]; }
prompt_container_setting() {
    local name=$1 label=$2 default=$3 validator=$4 guidance=$5 value
    if [[ -n ${!name:-} ]]; then
        "$validator" "${!name}" || die "$name: $guidance"
        return
    fi
    if ! container_prompt_available; then
        [[ -n $default ]] || die "Set $name for unattended provisioning, or run interactively on the PVE host."
        "$validator" "$default" || die "$name: $guidance"
        printf -v "$name" '%s' "$default"
        return
    fi
    while true; do
        printf '%s' "$label" >&2
        [[ -z $default ]] || printf ' [%s]' "$default" >&2
        printf ': ' >&2
        IFS= read -r value || die "Input ended while reading $name."
        value=${value:-$default}
        if [[ -n $value ]] && "$validator" "$value"; then
            printf -v "$name" '%s' "$value"
            return
        fi
        printf '%s\n' "$guidance" >&2
    done
}
first_listed() { "$@" 2>/dev/null | head -n1 || true; }
list_container_templates() {
    local storage status rest volume
    command -v pvesm >/dev/null && command -v pveam >/dev/null || return 0
    while read -r storage _ status rest; do
        [[ $status == active ]] || continue
        while read -r volume rest; do
            if valid_container_template "$volume"; then printf '%s\n' "$volume"; fi
        done < <(pveam list "$storage" 2>/dev/null || true)
    done < <(pvesm status --content vztmpl 2>/dev/null || true)
    return 0
}
list_container_storage() {
    local storage status rest
    command -v pvesm >/dev/null || return 0
    while read -r storage _ status rest; do
        if [[ $status == active ]] && valid_container_storage "$storage"; then printf '%s\n' "$storage"; fi
    done < <(pvesm status --content rootdir 2>/dev/null || true)
    return 0
}
# End container configuration helpers.

dry_run=0
INSTALL_TARGET=${INSTALL_TARGET:-0}
while (( $# )); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --install-target) INSTALL_TARGET=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
[[ $INSTALL_TARGET == 0 || $INSTALL_TARGET == 1 ]] || die 'INSTALL_TARGET must be 0 or 1.'
NONINTERACTIVE=${NONINTERACTIVE:-false}
[[ $NONINTERACTIVE == true || $NONINTERACTIVE == false ]] || die 'NONINTERACTIVE must be true or false.'

CT_HOSTNAME=${CT_HOSTNAME:-airllm-target}
BRIDGE=${BRIDGE:-vmbr0}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-32768}
SWAP_MB=${SWAP_MB:-4096}
ONBOOT=${ONBOOT:-0}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
GPU_DEVICES=${GPU_DEVICES:-}
AIRLLM_MODEL_ID=${AIRLLM_MODEL_ID:-Qwen/Qwen2.5-72B-Instruct}
AIRLLM_MODEL_ALIAS=${AIRLLM_MODEL_ALIAS:-}
min_disk=$(model_disk_gb "$AIRLLM_MODEL_ID")
ROOTFS_GB=${ROOTFS_GB:-$min_disk}

next_id=''
(( dry_run )) || next_id=$(pvesh get /cluster/nextid 2>/dev/null || true)
prompt_container_setting CT_ID 'CT ID' "$next_id" valid_container_id 'Use a free numeric ID of 100 or more.'
prompt_container_setting TEMPLATE 'Template volume (Debian 12/13 or Ubuntu 24.04/26.04)' \
    "$(first_listed list_container_templates)" valid_container_template \
    'Use <storage>:vztmpl/<debian-12|debian-13|ubuntu-24.04|ubuntu-26.04>-...tar.zst (pveam download first).'
prompt_container_setting STORAGE 'Root disk storage' "$(first_listed list_container_storage)" valid_container_storage \
    'Use an active storage ID that supports rootdir content.'
prompt_container_setting IP_CIDR 'IPv4 address/CIDR or dhcp' '' valid_container_ip 'Use a.b.c.d/nn or dhcp.'
GATEWAY=${GATEWAY:-}
if [[ $IP_CIDR != dhcp ]]; then
    prompt_container_setting GATEWAY 'Gateway' '' valid_container_gateway 'Use an IPv4 address.'
fi

[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
for name in CORES MEMORY_MB ROOTFS_GB; do positive_int "$name" "${!name}"; done
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
(( MEMORY_MB >= 8192 )) || die 'MEMORY_MB must be at least 8192: AirLLM holds a full layer plus activations in RAM.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY || $dry_run == 1 ]] || die "SSH_PUBLIC_KEY is not readable: $SSH_PUBLIC_KEY"
[[ $AIRLLM_MODEL_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'AIRLLM_MODEL_ID must be a Hugging Face <org>/<repo>.'
[[ -z $AIRLLM_MODEL_ALIAS || $AIRLLM_MODEL_ALIAS =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || die 'Invalid AIRLLM_MODEL_ALIAS.'
if (( ROOTFS_GB < min_disk )) && [[ ${ALLOW_SMALL_DISK:-false} != true ]]; then
    die "$AIRLLM_MODEL_ID needs about ${min_disk} GB of root disk (download + AirLLM shards); ROOTFS_GB=$ROOTFS_GB. Raise it, or set ALLOW_SMALL_DISK=true if you will use AIRLLM_DELETE_ORIGINAL or separate storage."
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
files=(install-target.sh server.py requirements.txt requirements.lock airllm.env.example airllm-ollama-api.service README.md)
for file in "${files[@]}"; do [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"; done
nvidia_installer=''
for candidate in "$source_dir/../../tools/install_nvidia_580_173_02.sh" "$source_dir/../../install_nvidia_580_173_02.sh"; do
    if [[ -r $candidate ]]; then nvidia_installer=$candidate; break; fi
done

net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$(template_ostype "$TEMPLATE")"
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --description 'AirLLM inference target; Ollama-compatible API on TCP 11434')
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
devices=()
if [[ -n $GPU_DEVICES ]]; then read -r -a devices <<< "$GPU_DEVICES"; fi
(( ${#devices[@]} <= 32 )) || die 'At most 32 explicit GPU device paths are supported.'
declare -A seen_devices=()
for i in "${!devices[@]}"; do
    device=${devices[$i]}
    [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || die "Invalid device path: $device"
    [[ -z ${seen_devices[$device]:-} ]] || die "Duplicate device path: $device"
    seen_devices[$device]=1
    if (( ! dry_run )); then [[ -c $device ]] || die "Not an existing character device on this host: $device"; fi
    create+=("--dev$i" "path=$device,gid=993,mode=0660")
done
device=cpu
if (( ${#devices[@]} )); then
    device=cuda:0
    [[ -n $nvidia_installer ]] || die 'GPU_DEVICES needs install_nvidia_580_173_02.sh in the repository root or tools directory.'
fi
guest_env=(env "AIRLLM_MODEL_ID=$AIRLLM_MODEL_ID" "AIRLLM_MODEL_ALIAS=$AIRLLM_MODEL_ALIAS" "AIRLLM_DEVICE=$device")
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}

if (( ! dry_run )); then
    [[ ${EUID} -eq 0 ]] || die 'Run as root on the intended PVE host.'
    for command_name in pveversion pct pvesh pvesm; do command -v "$command_name" >/dev/null || die "Missing PVE command: $command_name"; done
    [[ -d /etc/pve/nodes ]] || die '/etc/pve is unavailable; do not create a CT until the cluster filesystem is ready.'
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "ID $CT_ID is unavailable in this cluster."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge interface is not present: $BRIDGE"
    template_path=$(pvesm path "$TEMPLATE")
    [[ -f $template_path && -r $template_path ]] || die "Template is not readable on this node: $TEMPLATE"
fi

trap 'printf "Provisioning stopped at line %s. Any newly created CT is kept for inspection.\n" "$LINENO" >&2' ERR
run "${create[@]}"
run pct start "$CT_ID"
if (( ! dry_run )); then
    ready=0
    for (( attempt=0; attempt<60; attempt++ )); do
        if pct exec "$CT_ID" -- test -d /run/systemd/system; then ready=1; break; fi
        sleep 1
    done
    (( ready )) || die "CT $CT_ID did not start systemd within 60 seconds."
    online=0
    for (( attempt=0; attempt<60; attempt++ )); do
        if pct exec "$CT_ID" -- sh -c 'ip route show default | grep -q . && getent hosts deb.debian.org >/dev/null'; then online=1; break; fi
        sleep 3
    done
    (( online )) || die "CT $CT_ID has no default route or DNS after 180 seconds; check IP_CIDR, GATEWAY, NAMESERVER and BRIDGE."
fi
run pct exec "$CT_ID" -- install -d -m 0700 /root/airllm-target-deploy
for file in "${files[@]}"; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/airllm-target-deploy/$file" --perms 0644
done
if (( ${#devices[@]} )); then
    run pct push "$CT_ID" "$nvidia_installer" /root/airllm-target-deploy/install_nvidia_580_173_02.sh --perms 0755
fi
if (( INSTALL_TARGET )); then
    if (( ${#devices[@]} )); then
        run pct exec "$CT_ID" -- bash /root/airllm-target-deploy/install_nvidia_580_173_02.sh lxc
    fi
    run pct exec "$CT_ID" -- "${guest_env[@]}" bash /root/airllm-target-deploy/install-target.sh
    printf '\nThe model is downloading in CT %s. Follow it with: pct exec %s -- journalctl -u airllm-ollama-api -f\n' "$CT_ID" "$CT_ID"
else
    printf '\nGuest installation skipped. Inside the CT (pct enter %s) run:\n' "$CT_ID"
    if (( ${#devices[@]} )); then printf '  bash /root/airllm-target-deploy/install_nvidia_580_173_02.sh lxc\n'; fi
    printf '  AIRLLM_MODEL_ID=%q bash /root/airllm-target-deploy/install-target.sh\n' "$AIRLLM_MODEL_ID"
fi
printf 'Gated models need HF_TOKEN in /etc/airllm-target/airllm.env inside the CT.\n'
printf 'Enable CT autostart when ready: pct set %s --onboot 1\n' "$CT_ID"
