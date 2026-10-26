#!/usr/bin/env bash
# Dry-run validation of provision-lxc.sh. No PVE, root, GPU or network required;
# every invocation carries --dry-run, so the community script is never fetched.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$script_dir/provision-lxc.sh
bash_bin=$(command -v bash)
common=(CT_ID=270 IP_CIDR=192.0.2.70/24 GATEWAY=192.0.2.1 STORAGE=local-lvm NVIDIA_DEVICE=/nonexistent
    KFD_DEVICE=/nonexistent DRM_SYSFS=/nonexistent)
passed=0
out=''

run_plan() { env -i "PATH=$PATH" "$@" "$bash_bin" "$provision" --dry-run ${FLAGS:-} 2>&1; }
ok() {
    local label=$1; shift
    out=$(run_plan "${common[@]}" "$@") || { printf 'FAIL %s\n%s\n' "$label" "$out" >&2; exit 1; }
    [[ $out == *'+ curl -fsSL -o '* ]] || \
        { printf 'FAIL %s: community script not fetched\n%s\n' "$label" "$out" >&2; exit 1; }
    [[ $out == *'+ pct push 270 '* ]] || { printf 'FAIL %s: files not copied\n%s\n' "$label" "$out" >&2; exit 1; }
    [[ $out != *'var_pw'* ]] || { printf 'FAIL %s: a root password was preset\n' "$label" >&2; exit 1; }
    passed=$((passed + 1)); printf 'PASS %s\n' "$label"
}
fails() {
    local label=$1 expect=$2; shift 2
    if out=$(run_plan "${common[@]}" "$@"); then printf 'FAIL %s: accepted\n%s\n' "$label" "$out" >&2; exit 1; fi
    [[ $out == *"$expect"* ]] || { printf 'FAIL %s: expected "%s"\n%s\n' "$label" "$expect" "$out" >&2; exit 1; }
    [[ $out != *'+ env var_'* ]] || { printf 'FAIL %s: ran the community script before refusing\n' "$label" >&2; exit 1; }
    passed=$((passed + 1)); printf 'PASS %s\n' "$label"
}
has() { [[ $out == *"$1"* ]] || { printf 'FAIL: plan lacks %s\n%s\n' "$1" "$out" >&2; exit 1; }; }
lacks() { [[ $out != *"$1"* ]] || { printf 'FAIL: plan contains %s\n%s\n' "$1" "$out" >&2; exit 1; }; }

ok 'the community script runs with this target'"'"'s presets'
has '+ env var_ctid=270 var_hostname=ollama var_cpu=4 var_ram=16384 var_disk=128 var_unprivileged=1 var_nesting=1 var_gpu=no var_brg=vmbr0 var_os=debian var_version=13 var_net=192.0.2.70/24 var_gateway=192.0.2.1 var_container_storage=local-lvm bash '
has 'https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/ollama.sh'
has 'install-target.sh'; has 'ollama-target.conf'
lacks 'install_nvidia'; lacks '+ pct exec 270 -- env'
has 'To adopt it into the target layout'

FLAGS=--install-target ok 'install plan adopts the install and pulls models' OLLAMA_PULL_MODELS='qwen3:8b qwen3:14b'
has "+ pct exec 270 -- env OLLAMA_GPU=none OLLAMA_PULL_MODELS=qwen3:8b\\ qwen3:14b bash /root/ollama-target-deploy/install-target.sh"

FLAGS=--install-target ok 'GPU passthrough adds the NVIDIA helper before adoption' GPU=yes
has 'var_gpu=yes'
[[ $out == *'install_nvidia_580_173_02.sh lxc'*'install-target.sh'* ]] || { echo 'FAIL: NVIDIA helper not before adoption' >&2; exit 1; }

has 'OLLAMA_GPU=nvidia'

ok 'GPU=auto follows the host devices' GPU=auto NVIDIA_DEVICE=/dev/null
has 'var_gpu=yes'

FLAGS=--install-target ok 'an AMD GPU is passed through without the NVIDIA helper' GPU=amd
has 'var_gpu=yes'; has 'OLLAMA_GPU=amd'; has 'answer AMD'
lacks 'install_nvidia'
fake_drm=$(mktemp -d); trap 'rm -rf -- "$fake_drm" "${keyfile:-}"' EXIT
mkdir -p "$fake_drm/renderD128/device" "$fake_drm/renderD129/device"
printf '0x8086\n' > "$fake_drm/renderD128/device/vendor"; printf '0xa780\n' > "$fake_drm/renderD128/device/device"
FLAGS=--install-target ok 'GPU=auto ignores an Intel iGPU' GPU=auto DRM_SYSFS="$fake_drm"
has 'var_gpu=no'; has 'OLLAMA_GPU=none'
printf '0x8086\n' > "$fake_drm/renderD129/device/vendor"; printf '0xe20b\n' > "$fake_drm/renderD129/device/device"
FLAGS=--install-target ok 'GPU=auto finds an Arc B580' GPU=auto DRM_SYSFS="$fake_drm"
has 'var_gpu=yes'; has 'OLLAMA_GPU=intel'; has 'answer INTEL'
FLAGS=--install-target ok 'GPU=auto finds an AMD GPU by /dev/kfd' GPU=auto KFD_DEVICE=/dev/null DRM_SYSFS="$fake_drm"
has 'OLLAMA_GPU=amd'
ok 'GPU=none (or no) runs on the CPU' GPU=no
has 'var_gpu=no'; lacks 'answer'

ok 'another supported distribution is passed to the community script' OLLAMA_CT_OS=ubuntu OLLAMA_CT_VERSION=26.04
has 'var_os=ubuntu var_version=26.04'

ok 'DHCP drops the gateway' IP_CIDR=dhcp
has 'var_net=dhcp'; lacks 'var_gateway'

ok 'optional network settings are passed through' NAMESERVER=192.0.2.53 VLAN_TAG=30 BRIDGE=vmbr1
has 'var_ns=192.0.2.53'; has 'var_vlan=30'; has 'var_brg=vmbr1'

keyfile=$(mktemp)
echo 'ssh-ed25519 AAAAC3Nz test@host' > "$keyfile"
ok 'an SSH key is passed as its content' SSH_PUBLIC_KEY="$keyfile"
has 'var_ssh=yes'; has 'var_ssh_authorized_key=ssh-ed25519\ AAAAC3Nz\ test@host'

ok 'a reviewed copy of the community script can be used' COMMUNITY_SCRIPT_URL=https://git.example/mirror/ollama.sh
has 'https://git.example/mirror/ollama.sh'

fails 'too little RAM is refused' 'MEMORY_MB must be at least' MEMORY_MB=2048
fails 'too small a disk is refused' 'ROOTFS_GB must be at least' ROOTFS_GB=16
fails 'a bad address is refused' 'IP_CIDR' IP_CIDR=192.0.2.300/24
fails 'a bad CT ID is refused' 'CT_ID' CT_ID=12
fails 'an unknown GPU mode is refused' 'GPU must be' GPU=maybe
fails 'an unsupported distribution is refused' 'OLLAMA_CT_OS/OLLAMA_CT_VERSION' OLLAMA_CT_OS=ubuntu OLLAMA_CT_VERSION=25.10
fails 'Debian 11 is refused' 'OLLAMA_CT_OS/OLLAMA_CT_VERSION' OLLAMA_CT_VERSION=11
fails 'a bad model list is refused' 'OLLAMA_PULL_MODELS' OLLAMA_PULL_MODELS='qwen3;reboot'
fails 'a non-https script URL is refused' 'COMMUNITY_SCRIPT_URL' COMMUNITY_SCRIPT_URL=http://example/ollama.sh
fails 'a malformed script checksum is refused' 'COMMUNITY_SCRIPT_SHA256' COMMUNITY_SCRIPT_SHA256=abc

"$bash_bin" -n "$provision"
"$bash_bin" -n "$script_dir/install-target.sh"
printf '%s dry-run cases and both shell syntax checks passed. No CT or service was changed.\n' "$passed"
