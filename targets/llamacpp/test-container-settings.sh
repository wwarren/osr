#!/usr/bin/env bash
# Fixture variables are consumed by dynamically extracted helpers.
# shellcheck disable=SC2034
# Exercise read-only provisioning prompts and validation without creating a CT.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1090
source <(awk '
    /^# Container configuration helpers / { capture=1; next }
    /^# End container configuration helpers\./ { capture=0 }
    capture { print }
' "$script_dir/provision-lxc.sh")
declare -F configure_container >/dev/null || die 'Provisioning helper extraction failed.'

pvesh() {
    [[ $* == 'get /cluster/nextid' ]] || die "Unexpected PVE request: $*"
    printf '251\n'
}

passed=0
check() {
    local label=$1 expected=$2 needle=$3 output status=0
    shift 3
    output=$(
        unset CT_ID TEMPLATE CT_HOSTNAME IP_CIDR BRIDGE GATEWAY CORES MEMORY_MB STORAGE ROOTFS_GB NONINTERACTIVE
        "$@" 2>&1
    ) || status=$?
    if [[ $expected == ok ]]; then
        (( status == 0 )) || die "$label: unexpected failure: $output"
    else
        (( status != 0 )) || die "$label: invalid settings accepted"
    fi
    [[ $output == *"$needle"* ]] || die "$label: expected '$needle' in: $output"
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
}
settings() {
    local entry
    # Suppress inventory only; exercise the real read/default/validation loop.
    list_container_templates() { :; }
    list_container_storage() { :; }
    for entry in "$@"; do export "${entry?}"; done
    configure_container
    printf 'SETTINGS|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$CT_ID" "$TEMPLATE" "$CT_HOSTNAME" "$IP_CIDR" "$BRIDGE" "$GATEWAY" \
        "$CORES" "$MEMORY_MB" "$STORAGE" "$ROOTFS_GB"
}
presets() {
    settings CT_ID=250 TEMPLATE=local:vztmpl/debian-12-standard_test_amd64.tar.zst \
        IP_CIDR=192.0.2.50/24 GATEWAY= STORAGE=local-lvm "$@"
}
interactive() {
    container_prompt_available() { return 0; }
    settings "$@"
}
interactive_presets() {
    container_prompt_available() { return 0; }
    presets "$@"
}
interactive_no_suggestion() {
    pvesh() { return 1; }
    interactive "$@"
}
inventory_templates() {
    local output
    pvesm() {
        [[ $* == 'status --content vztmpl' ]] || return 1
        printf '%s\n' 'Name Type Status Total Used Available %' 'local dir active 100 20 80 20%' 'offline dir inactive 100 20 80 20%'
    }
    pveam() {
        case "$*" in
            'list local') printf '%s\n' 'NAME SIZE' 'local:vztmpl/debian-12-standard_test_amd64.tar.zst 123' 'local:vztmpl/debian-13-standard_test_amd64.tar.zst 456' 'local:vztmpl/ubuntu-24.04-standard_test_amd64.tar.zst 789' ;;
            'list offline') printf '%s\n' 'offline:vztmpl/debian-12-standard_test_amd64.tar.zst 123' ;;
            *) return 1 ;;
        esac
    }
    output=$(list_container_templates)
    [[ $output == *'local:vztmpl/debian-12-standard_test_amd64.tar.zst'* ]] || die "Missing downloaded template: $output"
    [[ $output != *debian-13* && $output != *ubuntu* && $output != *offline:* ]] || die "Unsupported or inactive template listed: $output"
    printf 'INVENTORY verified\n'
}
inventory_templates_vulkan() {
    local output
    pvesm() { printf '%s\n' 'Name Type Status Total Used Available %' 'local dir active 100 20 80 20%'; }
    pveam() { printf '%s\n' 'NAME SIZE' 'local:vztmpl/debian-12-standard_test_amd64.tar.zst 123' 'local:vztmpl/debian-13-standard_test_amd64.tar.zst 456'; }
    BACKEND=vulkan
    output=$(list_container_templates)
    [[ $output == 'local:vztmpl/debian-13-standard_test_amd64.tar.zst' ]] || die "Vulkan must list Debian 13 only: $output"
    printf 'INVENTORY verified\n'
}
inventory_storage() {
    local output
    pvesm() {
        [[ $* == 'status --content rootdir' ]] || return 1
        printf '%s\n' 'Name Type Status Total Used Available %' 'vm_pool zfspool active 100 20 80 20%' 'offline dir inactive 100 20 80 20%'
    }
    output=$(list_container_storage)
    [[ $output == $'vm_pool\t'* ]] || die "Missing rootdir-filtered storage ID: $output"
    [[ $output == *zfspool* && $output != *offline* ]] || die "Storage label or active filtering failed: $output"
    printf 'INVENTORY verified\n'
}
inventory_unavailable() {
    pvesm() { return 1; }
    pveam() { return 1; }
    list_container_templates || die 'Unavailable template inventory prevented manual entry.'
    list_container_storage || die 'Unavailable storage inventory prevented manual entry.'
    printf 'INVENTORY verified\n'
}
selector_inventory() {
    printf '%s\n' "$@"
}
select_template() {
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_container_templates() {
        selector_inventory \
            'local:vztmpl/debian-12-standard_test_amd64.tar.zst' \
            'iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst'
    }
    select_container_setting TEMPLATE 'CT template volume' valid_container_template 'Enter a valid template.' list_container_templates
    printf 'SELECTED|%s\n' "$TEMPLATE"
}
select_storage() {
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_container_storage() {
        selector_inventory $'local-lvm\tlocal-lvm (lvmthin)' $'vm_pool\tvm_pool (zfspool)'
    }
    select_container_setting STORAGE 'Root disk storage ID' valid_container_storage 'Enter a valid storage ID.' list_container_storage
    printf 'SELECTED|%s\n' "$STORAGE"
}
selector_preset() {
    NONINTERACTIVE=false
    TEMPLATE=iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
    STORAGE=vm_pool
    container_prompt_available() { return 0; }
    list_container_templates() { die 'Inventory should not be queried for a preset.'; }
    list_container_storage() { die 'Inventory should not be queried for a preset.'; }
    select_container_setting TEMPLATE 'CT template volume' valid_container_template 'Enter a valid template.' list_container_templates
    select_container_setting STORAGE 'Root disk storage ID' valid_container_storage 'Enter a valid storage ID.' list_container_storage
    printf 'SELECTED|%s|%s\n' "$TEMPLATE" "$STORAGE"
}
selector_unattended() {
    NONINTERACTIVE=true
    container_prompt_available() { return 1; }
    list_container_templates() { die 'Inventory should not be queried without interactive input.'; }
    select_container_setting TEMPLATE 'CT template volume' valid_container_template 'Enter a valid template.' list_container_templates
}
selector_empty_inventory() {
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_container_storage() { :; }
    select_container_setting STORAGE 'Root disk storage ID' valid_container_storage 'Enter a valid storage ID.' list_container_storage
    printf 'SELECTED|%s\n' "$STORAGE"
}
interactive_selectors() {
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_container_templates() { printf '%s\n' 'iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst'; }
    list_container_storage() { printf '%s\n' $'vm_pool\tvm_pool (zfspool)'; }
    configure_container
    printf 'SETTINGS|%s|%s|%s|%s|%s|%s|%s|%s\n' "$CT_ID" "$TEMPLATE" "$CT_HOSTNAME" "$IP_CIDR" "$CORES" "$MEMORY_MB" "$STORAGE" "$ROOTFS_GB"
}

check 'unattended optional defaults' ok '|llama-target|192.0.2.50/24|vmbr0||4|16384|local-lvm|64' presets NONINTERACTIVE=true
check 'redirected input uses defaults without prompting' ok '|llama-target|192.0.2.50/24|vmbr0||4|16384|local-lvm|64' presets </dev/null
check 'invalid noninteractive setting rejected' fail 'NONINTERACTIVE' presets NONINTERACTIVE=invalid
check 'all environment settings honored without prompts' ok '|gpu-target|192.0.2.50/24|vmbr2|192.0.2.1|8|32768|fast-zfs|128' interactive_presets CT_HOSTNAME=gpu-target BRIDGE=vmbr2 GATEWAY=192.0.2.1 CORES=8 MEMORY_MB=32768 STORAGE=fast-zfs ROOTFS_GB=128 </dev/null
check 'explicit empty gateway does not prompt' ok '|vmbr0||4|16384|local-lvm|64' interactive_presets CT_HOSTNAME=llama-target BRIDGE=vmbr0 CORES=4 MEMORY_MB=16384 ROOTFS_GB=64 </dev/null
for name in CT_ID TEMPLATE IP_CIDR STORAGE; do
    check "missing unattended $name fails" fail "$name" presets NONINTERACTIVE=true "$name="
done
check 'minimum scalar settings' ok '|1|1024|local-lvm|1' presets NONINTERACTIVE=true CT_ID=100 CORES=1 MEMORY_MB=1024 ROOTFS_GB=1
check 'maximum CT ID and CPU settings' ok 'SETTINGS|999999999|' presets NONINTERACTIVE=true CT_ID=999999999 CORES=8192
check 'CT ID below range rejected' fail 'CT_ID' presets NONINTERACTIVE=true CT_ID=99
check 'CT ID above range rejected' fail 'CT_ID' presets NONINTERACTIVE=true CT_ID=1000000000
check 'CPU zero rejected' fail 'CORES' presets NONINTERACTIVE=true CORES=0
check 'CPU above range rejected' fail 'CORES' presets NONINTERACTIVE=true CORES=8193
check 'fractional CPU rejected' fail 'CORES' presets NONINTERACTIVE=true CORES=1.5
check 'RAM below minimum rejected' fail 'MEMORY_MB' presets NONINTERACTIVE=true MEMORY_MB=1023
check 'zero disk size rejected' fail 'ROOTFS_GB' presets NONINTERACTIVE=true ROOTFS_GB=0
check 'invalid preset fails without prompt' fail 'CORES' interactive_presets CT_HOSTNAME=llama-target BRIDGE=vmbr0 CORES=invalid MEMORY_MB=16384 ROOTFS_GB=64 </dev/null
check 'unsupported template rejected' fail 'TEMPLATE' presets NONINTERACTIVE=true TEMPLATE=local:vztmpl/debian-13-standard_test_amd64.tar.zst
check 'storage path rejected' fail 'STORAGE' presets NONINTERACTIVE=true STORAGE=/var/lib/vz
check 'hostname with whitespace rejected' fail 'CT_HOSTNAME' presets NONINTERACTIVE=true 'CT_HOSTNAME=gpu target'
check 'bridge with whitespace rejected' fail 'BRIDGE' presets NONINTERACTIVE=true 'BRIDGE=vm br0'
check 'IPv4 invalid octet rejected' fail 'IP_CIDR' presets NONINTERACTIVE=true IP_CIDR=192.0.2.999/24
check 'IPv4 invalid prefix rejected' fail 'IP_CIDR' presets NONINTERACTIVE=true IP_CIDR=192.0.2.50/33
check 'IPv4 prefix with leading zero rejected' fail 'IP_CIDR' presets NONINTERACTIVE=true IP_CIDR=192.0.2.50/024
check 'static gateway rejected if invalid' fail 'GATEWAY' presets NONINTERACTIVE=true GATEWAY=192.0.2.999
check 'DHCP with empty gateway accepted' ok '|dhcp|vmbr0||4|' presets NONINTERACTIVE=true IP_CIDR=dhcp
check 'DHCP with static gateway rejected' fail 'GATEWAY' presets NONINTERACTIVE=true IP_CIDR=dhcp GATEWAY=192.0.2.1

check 'interactive input accepts suggested CT ID and defaults' ok 'SETTINGS|251|local:vztmpl/debian-12-standard_test_amd64.tar.zst|llama-target|192.0.2.50/24|vmbr0||4|16384|local-lvm|64' interactive <<'INPUT'

local:vztmpl/debian-12-standard_test_amd64.tar.zst

192.0.2.50/24




local-lvm

INPUT
check 'interactive DHCP skips gateway prompt' ok '|gpu-target|dhcp|vmbr1||8|32768|fast-zfs|128' interactive <<'INPUT'
250
local:vztmpl/debian-12-standard_test_amd64.tar.zst
gpu-target
dhcp
vmbr1
8
32768
fast-zfs
128
INPUT
check 'interactive input works when CT ID suggestion unavailable' ok 'SETTINGS|250|' interactive_no_suggestion <<'INPUT'
250
local:vztmpl/debian-12-standard_test_amd64.tar.zst

dhcp



local-lvm

INPUT
check 'interactive invalid values re-prompt' ok 'SETTINGS|250|local:vztmpl/debian-12-standard_test_amd64.tar.zst|gpu-target|192.0.2.50/24|vmbr0|192.0.2.1|8|32768|local-lvm|128' interactive <<'INPUT'
99
250
local:vztmpl/debian-13-standard_test_amd64.tar.zst
local:vztmpl/debian-12-standard_test_amd64.tar.zst
bad name
gpu-target
192.0.2.999/24
192.0.2.50/24
vm br0
vmbr0
192.0.2.999
192.0.2.1
0
8
1023
32768
/var/lib/vz
local-lvm
0
128
INPUT
check 'interactive EOF aborts' fail 'Input ended' interactive </dev/null
check 'inventory lists only downloaded Debian 12 templates on active storage' ok 'INVENTORY verified' inventory_templates
check 'BACKEND=vulkan lists only Debian 13 templates' ok 'INVENTORY verified' inventory_templates_vulkan
check 'storage inventory requests rootdir capability' ok 'INVENTORY verified' inventory_storage
check 'inventory failure permits manual entry' ok 'INVENTORY verified' inventory_unavailable
check 'numbered template selector accepts underscore storage ID' ok 'SELECTED|iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst' select_template <<'INPUT'
2
INPUT
check 'numbered root disk selector assigns storage ID without display label' ok 'SELECTED|vm_pool' select_storage <<'INPUT'
2
INPUT
check 'selector accepts exact listed template volume' ok 'SELECTED|iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst' select_template <<'INPUT'
iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
INPUT
check 'selector accepts exact listed storage ID' ok 'SELECTED|vm_pool' select_storage <<'INPUT'
vm_pool
INPUT
check 'invalid selector values retry safely' ok 'SELECTED|vm_pool' select_storage <<'INPUT'

0
3
-1
99999999999999999999999999999999999999999999999999999999
missing-pool
2
INPUT
check 'template selector supports manual entry' ok 'SELECTED|archive_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst' select_template <<'INPUT'
m
archive_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
INPUT
check 'storage selector supports manual entry and validation' ok 'SELECTED|alternate_pool' select_storage <<'INPUT'
M
/var/lib/vz
alternate_pool
INPUT
check 'selector presets skip inventory and input' ok 'SELECTED|iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst|vm_pool' selector_preset </dev/null
check 'unattended selector requires a preset' fail 'TEMPLATE' selector_unattended </dev/null
check 'empty inventory falls back to manual entry' ok 'SELECTED|vm_pool' selector_empty_inventory <<'INPUT'
vm_pool
INPUT
check 'selector EOF aborts' fail 'Input ended' select_template </dev/null
check 'manual selector EOF aborts' fail 'Input ended' select_storage <<'INPUT'
m
INPUT
check 'full interactive configuration selects user template and root storage' ok 'SETTINGS|134|iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst|ant-rtxpro2k-llama1|192.168.10.10/23|12|32768|vm_pool|1024' interactive_selectors <<'INPUT'
134
1
ant-rtxpro2k-llama1
192.168.10.10/23


12
32768
1
1024
INPUT
printf '%s container configuration cases passed. No PVE or CT changes were made.\n' "$passed"
