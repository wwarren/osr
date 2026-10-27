#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
common=(CT_ID=280 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1)
pin=$(sed -n 's/^PIN = "\([0-9a-f]\{40\}\)"$/\1/p' "$here/test-pinned-run-script.py")
[[ $pin =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL missing Strata test pin' >&2; exit 1; }
passed=0

has() { [[ $output == *"$1"* ]] || { printf 'FAIL missing %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
lacks() { [[ $output != *"$1"* ]] || { printf 'FAIL unexpected %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
plan() {
    output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL plan\n%s\n' "$output" >&2; exit 1;
    }
    passed=$((passed + 1))
}
reject() {
    local reason=$1; shift
    if output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1); then
        printf 'FAIL accepted invalid setting\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"
    lacks '+ pct create '
    passed=$((passed + 1))
}

plan
has '+ pct create 280 '
has '--unprivileged 1'
has '--memory 65536'
has '--rootfs local-lvm:160'
has 'lxc.prlimit.memlock: unlimited'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'path=/dev/nvidia-uvm\,gid=44\,mode=0660'
lacks 'gid=0\,'
has 'STRATA_READY_TIMEOUT=900'
has 'nvidia-guest-install.sh lxc'
has 'bash /root/strata-target-deploy/install-target.sh'
has 'STRATA_PORT=8080'
has "STRATA_COMMIT=$pin"
lacks 'https://github.com/Niko1221/Strata.git'  # cloning happens inside the CT

plan STRATA_REF=v0.1.40
has 'STRATA_REF=v0.1.40'
has 'STRATA_COMMIT='
plan STRATA_COMMIT=
has 'STRATA_REF=main'
has 'STRATA_COMMIT='

plan STRATA_PORT=11434 IP_CIDR=dhcp GATEWAY= STRATA_MODEL=IQ3_S
has 'STRATA_PORT=11434'
has 'STRATA_MODEL=IQ3_S'
has 'ip=dhcp\,firewall=1'
lacks 'gw='

plan STRATA_FAMILY=coder
has 'STRATA_MODEL=IQ1_M'

plan STRATA_FAMILY=unsloth
has 'STRATA_FAMILY=unsloth'
has 'STRATA_MODEL=UD-IQ4_XS'

reject 'CT_ID' CT_ID=99
reject 'Set CT_ID for an unattended run' CT_ID=
reject 'Set TEMPLATE for an unattended run' TEMPLATE=
reject 'Set STORAGE for an unattended run' STORAGE=
reject 'Set IP_CIDR for an unattended run' IP_CIDR=
reject 'Set GATEWAY for an unattended run' GATEWAY=
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'TEMPLATE' TEMPLATE=local:vztmpl/alpine-3.20-standard_amd64.tar.zst
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia0'
reject 'STRATA_PORT' STRATA_PORT=70000
reject 'MEMORY_MB' MEMORY_MB=8192
reject 'STRATA_COMMIT' STRATA_COMMIT=bad
reject 'GPU_GID' GPU_GID=0

plan GPU_GID=1000
has 'path=/dev/nvidia0\,gid=1000\,mode=0660'
plan GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
has '--dev3 path=/dev/nvidia-uvm-tools'

output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has "git fetch --depth 1 https://github.com/Niko1221/Strata.git $pin into /opt/strata (as strata)"
has 'setup.sh --help: keep only the options this checkout supports'
has '--setup --no-start --yes'
has '--host 0.0.0.0 --port 8080'
has '--api-key [redacted]'
has 'STRATA_RUN_SCRIPT'
has 'systemctl enable strata.service'
has 'systemctl restart strata.service'
has '/health to report loaded=true (up to 900s)'
lacks 'api-key [generated inside CT]'
lacks 'sudo'
passed=$((passed + 1))

installed=$(mktemp -d "${TMPDIR:-/tmp}/strata-rerun-test.XXXXXX")
trap 'rm -rf -- "$installed"' EXIT
mkdir -p "$installed/opt/strata/.git" "$installed/etc/systemd/system" "$installed/etc/strata-target"
: > "$installed/etc/systemd/system/strata.service"
# An installed target has a settings record; a rerun plans from it.
printf 'STRATA_FAMILY=qwen\nSTRATA_MODEL=IQ2_XS\nSTRATA_CONTEXT=32768\nSTRATA_VISION=no\nSTRATA_PORT=8123\nSTRATA_ALLOW_NO_KEY=false\n' > "$installed/etc/strata-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" STRATA_DIR="$installed/opt/strata" STRATA_ETC_DIR="$installed/etc/strata-target" \
        UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has "git fetch --depth 1 https://github.com/Niko1221/Strata.git $pin (before anything is stopped"
has 'nothing to do'
has 'record the current commit; systemctl stop strata.service'
has 'previous commit locally (no network)'
passed=$((passed + 1))

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/strata-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" STRATA_PORT=11434 STRATA_REF=v0.1.40 bash "$guest" --dry-run 2>&1)
has 'Strata.git v0.1.40 into'
has '--port 11434'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" STRATA_COMMIT= bash "$guest" --dry-run 2>&1)
has 'Strata.git main into'
passed=$((passed + 1))

commit=0123456789abcdef0123456789abcdef01234567
output=$(env -i "PATH=$PATH" STRATA_COMMIT=$commit bash "$guest" --dry-run 2>&1)
has "Strata.git $commit into"   # fetched by commit, not cloned at a branch tip
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" STRATA_FAMILY=coder bash "$guest" --dry-run 2>&1)
has '[--family coder] --model IQ1_M'
output=$(env -i "PATH=$PATH" STRATA_FAMILY=unsloth bash "$guest" --dry-run 2>&1)
has '[--family unsloth] --model UD-IQ4_XS'
if output=$(env -i "PATH=$PATH" STRATA_FAMILY='Qwen;x' bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted a malformed STRATA_FAMILY\n' >&2; exit 1
fi
has 'Invalid STRATA_FAMILY'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" bash "$guest" --dry-run --upgrade 2>&1)
has 'on failure: check out the previous commit'
passed=$((passed + 1))

if output=$(env -i "PATH=$PATH" STRATA_REF='a..b' bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted STRATA_REF with ..\n' >&2; exit 1
fi
has 'Invalid STRATA_REF'
passed=$((passed + 1))

unit=$here/strata.service
grep -Fqx 'ExecStart=/bin/sh ${STRATA_RUN_SCRIPT}' "$unit"
grep -q '^EnvironmentFile=/etc/strata-target/strata.env$' "$unit"
grep -q '^User=strata$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
grep -q '^ReadWritePaths=/opt/strata /var/lib/strata$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"   # the GPU nodes must stay visible
grep -q '^LimitMEMLOCK=infinity$' "$unit"
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
printf '%s Strata dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
