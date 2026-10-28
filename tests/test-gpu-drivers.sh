#!/usr/bin/env bash
# tools/update-gpu-drivers.sh against a stubbed Proxmox host: pct (four
# containers, their configs and in-container answers), lspci, nvidia-smi,
# modprobe, modinfo, dkms, make, apt, the GPU list of setup-host-gpu.sh, the
# NVIDIA driver helper and a fake download.nvidia.com. Nothing is installed;
# no root, GPU or network is needed.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/../tools/update-gpu-drivers.sh
passed=0
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
has() { [[ $output == *"$1"* ]] || fail "missing: $1"$'\n'"$output"; }
lacks() { [[ $output != *"$1"* ]] || fail "unexpected: $1"$'\n'"$output"; }
logged() { grep -qF -- "$1" "$log" || fail "not run: $1"$'\n'"$(cat "$log")"; }
unlogged() { ! grep -qF -- "$1" "$log" || fail "ran: $1"$'\n'"$(cat "$log")"; }
# before A B: the first log line with A comes before the last with B.
before() {
    local a b
    a=$(grep -nF -- "$1" "$log" | head -n1 | cut -d: -f1)
    b=$(grep -nF -- "$2" "$log" | tail -n1 | cut -d: -f1)
    [[ -n $a && -n $b ]] && (( a < b )) || fail "order: '$1' before '$2'"$'\n'"$(cat "$log")"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gpu-drivers-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
stubs=$tmp/bin web=$tmp/web state=$tmp/state log=$tmp/calls.log
mkdir -p "$stubs" "$web"

# --- stubs -------------------------------------------------------------------------
stub() { { printf '#!/usr/bin/env bash\n'; cat; } > "$stubs/$1"; chmod +x "$stubs/$1"; }
stub id <<'EOF'
echo "${FAKE_UID:-0}"
EOF
stub hostname <<'EOF'
echo pve-test
EOF
stub pveversion <<'EOF'
echo 'pve-manager/9.0.10/0123abcd (running kernel: 6.14.11-4-pve)'
EOF
stub curl <<EOF
out='' url=''
while (( \$# )); do
    case \$1 in -o) out=\$2; shift ;; --) url=\$2; shift ;; -*) ;; *) url=\$1 ;; esac
    shift
done
echo "curl \$url\${out:+ -o \$out}" >> "$log"
[[ \${FAKE_OFFLINE:-0} == 1 ]] && exit 6
path=\${url#http://nv.test/base}; path=\${path#/}
[[ -n \$path ]] || path=index.html
[[ -f $web/\$path ]] || exit 22
if [[ -n \$out ]]; then cp "$web/\$path" "\$out"; else cat "$web/\$path"; fi
EOF
stub pct <<EOF
cmd=\${1:-}; shift || true
case \$cmd in
    list)
        printf 'VMID       Status     Lock         Name\n'
        for f in "$state"/ct-*.status; do
            id=\${f##*/ct-}; id=\${id%.status}
            printf '%-10s %-10s %-12s %s\n' "\$id" "\$(cat "\$f")" '' "\$(cat "$state/ct-\$id.name")"
        done ;;
    status) echo "status: \$(cat "$state/ct-\$1.status")" ;;
    start) [[ \${FAKE_START_FAIL:-} == "\$1" ]] && exit 1; echo "pct start \$*" >> "$log"; echo running > "$state/ct-\$1.status" ;;
    shutdown|stop)
        echo "pct \$cmd \$*" >> "$log"
        [[ \${FAKE_STOP_FAIL:-} == "\$1" ]] && exit 1
        echo stopped > "$state/ct-\$1.status" ;;
    reboot|push) echo "pct \$cmd \$*" >> "$log" ;;
    exec)
        id=\$1; shift; [[ \${1:-} == -- ]] && shift
        if [[ \$1 == sh && \$2 == -c ]]; then
            if [[ \${4:-} == probe ]]; then
                echo "pct exec \$id probe refresh=\$5 apt=\$6" >> "$log"
                [[ \${FAKE_PROBE_FAIL:-} == "\$id" ]] && exit 1
                cat "$state/ct-\$id.probe" 2>/dev/null
                if [[ -n \${FAKE_GUEST_PROBE_VERSION:-} ]]; then
                    echo "NV_GUEST_KERNEL=\$FAKE_GUEST_PROBE_VERSION"
                else
                    echo "NV_GUEST_KERNEL=\$(sed -nE 's/.*Module( for x86_64)?[[:space:]]+([0-9.]+).*/\\2/p' "$state/nvversion" 2>/dev/null)"
                fi
            elif [[ \${4:-} == sh ]]; then
                echo "pct exec \$id verify NVIDIA \$5" >> "$log"
                [[ \$(cat "$state/ct-\$id.nvsmi" 2>/dev/null) == "\$5" &&
                   \$(cat "$state/ct-\$id.cuda-lib" 2>/dev/null) == "\$5" ]] || exit 1
            else
                echo "pct exec \$id cleanup NVIDIA packages" >> "$log"
                [[ \${FAKE_CLEANUP_FAIL:-} == "\$id" ]] && exit 1
            fi
            exit 0
        fi
        echo "pct exec \$id -- \$*" >> "$log"
        case \$1 in
            cat)
                if [[ \${2:-} == /proc/driver/nvidia/version ]]; then
                    if [[ -n \${FAKE_GUEST_NV_VERSION:-} ]]; then
                        printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  %s  Release Build\n' "\$FAKE_GUEST_NV_VERSION"
                    else
                        cat "$state/nvversion"
                    fi
                fi ;;
            nvidia-smi) cat "$state/ct-\$id.nvsmi" 2>/dev/null ;;
            env)
                if [[ " \$* " == *' lxc '* ]]; then
                    [[ \${FAKE_LXC_FAIL:-} == "\$id" ]] && exit 1
                    printf '%s\n' "\$@" | sed -n 's/^DRIVER_VERSION=//p' > "$state/ct-\$id.nvsmi"
                    [[ \${FAKE_CUDA_INSTALL_FAIL:-} == "\$id" ]] || cp "$state/ct-\$id.nvsmi" "$state/ct-\$id.cuda-lib"
                fi
                [[ " \$* " == *' apt-get '* && \${FAKE_CT_APT_FAIL:-0} == 1 ]] && exit 100 ;;
        esac ;;
esac
exit 0
EOF
stub lspci <<'EOF'
case "$*" in
    *01:00.0*) echo '0000:01:00.0 0300: 10de:2684 (rev a1)' ;;
    *03:00.0*) echo '0000:03:00.0 0300: 1002:744c (rev c8)' ;;
esac
EOF
stub nvidia-smi <<'EOF'
[[ -e $PROC_DRIVER_VERSION ]] || exit 9
echo "00000000:01:00.0, ${FAKE_CAP:-8.9}, NVIDIA GeForce RTX 4090"
EOF
stub modprobe <<EOF
echo "modprobe \$*" >> "$log"
if [[ \$1 == -r ]]; then
    [[ \${FAKE_UNLOAD_FAIL:-0} == 1 ]] && exit 1
    sed -i "/^\$2 /d" "\$PROC_MODULES"
    [[ \$2 != nvidia ]] || rm -f "\$PROC_DRIVER_VERSION"
fi
exit 0
EOF
stub modinfo <<EOF
cat "$state/modinfo" 2>/dev/null
EOF
stub dkms <<EOF
sub=\$1; shift
v='' k=''
while (( \$# )); do case \$1 in -v) v=\$2; shift ;; -k) k=\$2; shift ;; esac; shift; done
case \$sub in
    status) [[ -e "$state/dkms-\$v-\$k" ]] && echo "nvidia/\$v, \$k, x86_64: installed" ;;
    install)
        echo "dkms install \$v \$k" >> "$log"
        [[ \${FAKE_DKMS_FAIL:-0} == 1 ]] && exit 1
        touch "$state/dkms-\$v-\$k" ;;
esac
exit 0
EOF
stub make <<EOF
echo "make \$*" >> "$log"
exit \${FAKE_MAKE_RC:-0}
EOF
stub systemctl <<EOF
[[ \$1 == is-active ]] && exit 3
echo "systemctl \$*" >> "$log"
EOF
stub apt-get <<EOF
echo "apt-get \$*" >> "$log"
exit \${FAKE_APT_RC:-0}
EOF
stub apt-cache <<EOF
case \$1 in
    policy)
        f="$state/apt/\$2"
        [[ -f \$f ]] || exit 0
        IFS='|' read -r i c < "\$f"
        printf '%s:\n  Installed: %s\n  Candidate: %s\n' "\$2" "\${i:-(none)}" "\${c:-(none)}" ;;
    show) exit 0 ;;
    pkgnames) [[ -z \${FAKE_PKGNAMES:-} ]] || printf '%s\n' \$FAKE_PKGNAMES ;;
esac
EOF
stub dpkg-query <<'EOF'
[[ -z ${FAKE_HOST_APT_NV:-} ]] || echo "$FAKE_HOST_APT_NV install ok installed"
exit 1
EOF
# The GPU list of tools/setup-host-gpu.sh --list.
stub setup-host-gpu <<'EOF'
printf '%s\n' "${FAKE_CARDS:-GPU_CARD=0000:01:00.0|nvidia|rtx40|nvidia|NVIDIA AD102 [GeForce RTX 4090]}"
EOF
stub nvidia-helper <<EOF
echo "helper \$* DRIVER_VERSION=\${DRIVER_VERSION:-} KERNEL_MODULE_TYPE=\${KERNEL_MODULE_TYPE:-} FORCE=\${FORCE:-} SHA=\${DRIVER_SHA256:+set}" >> "$log"
if [[ \$1 == host ]]; then
    [[ \${FAKE_HELPER_FAIL:-} == "\$DRIVER_VERSION" ]] && exit 1
    echo "\$DRIVER_VERSION" > "$state/modinfo"
    [[ \${FAKE_NO_LOAD:-0} == 1 ]] ||
        printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  %s  Release Build\n' "\$DRIVER_VERSION" > "\$PROC_DRIVER_VERSION"
    printf 'nvidia 1 0 - Live 0x0\nnvidia_uvm 1 0 - Live 0x0\n' >> "\$PROC_MODULES"
fi
exit 0
EOF

# --- fake download.nvidia.com ----------------------------------------------------------
ada_json='{"chips": [{"devid": "0x2684", "name": "NVIDIA GeForce RTX 4090", "features": ["kernelopen"]}]}'
make_release() {
    local version=$1 json=${2:-$ada_json} file
    file=NVIDIA-Linux-x86_64-$version.run
    mkdir -p "$web/$version"
    cat > "$web/$version/$file" <<RUN
#!/bin/sh
case "\$1" in
    --extract-only)
        d=NVIDIA-Linux-x86_64-$version
        mkdir -p "\$d/supported-gpus" "\$d/kernel-open" "\$d/kernel"
        cat > "\$d/supported-gpus/supported-gpus.json" <<'JSON'
$json
JSON
        ;;
esac
exit 0
RUN
    printf '%s  %s\n' "$(sha256sum "$web/$version/$file" | cut -d' ' -f1)" "$file" > "$web/$version/$file.sha256sum"
}
releases=(570.211.01 580.173.02 580.196.07 590.48.01 595.104.02 595.112.07 610.57.04 615.78.08)
: > "$web/index.html"
for v in "${releases[@]}"; do
    make_release "$v"
    printf "<a href='%s/'>%s/</a> 2026-10-21 13:51\n" "$v" "$v" >> "$web/index.html"
done
echo '595.112.07 595.112.07/NVIDIA-Linux-x86_64-595.112.07.run' > "$web/latest.txt"

# --- the host and its containers -----------------------------------------------------
# fresh: a host with NVIDIA 580.173.02 (open modules, .run + DKMS), CT 201
# (NVIDIA, running, Basalt), 202 (AMD render node + /dev/kfd, running,
# llama.cpp Vulkan, a Mesa update pending), 203 (NVIDIA, stopped) and 204 (no GPU).
fresh() {
    rm -rf "$state"; mkdir -p "$state/apt" "$state/proc" "$state/lxc" "$state/dl" "$state/usrbin"
    : > "$log"
    printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  580.173.02  Release Build\n' > "$state/nvversion"
    echo 580.173.02 > "$state/modinfo"
    printf 'nvidia_uvm 1 0 - Live 0x0\nnvidia_drm 1 1 - Live 0x0\nnvidia_modeset 1 1 nvidia_drm, Live 0x0\nnvidia 1 2 nvidia_uvm,nvidia_modeset, Live 0x0\n' > "$state/modules"
    mkdir -p "$state/lib-modules/6.14.11-4-pve/kernel" "$state/lib-modules/6.14.11-4-pve/build"
    touch "$state/usrbin/nvidia-uninstall"
    mkdir -p "$state/sys/class/drm/renderD128/device" "$state/sys/class/drm/renderD129/device"
    echo 0x1002 > "$state/sys/class/drm/renderD128/device/vendor"
    echo 0x10de > "$state/sys/class/drm/renderD129/device/vendor"
    echo '3.16-3|3.16-3' > "$state/apt/pve-firmware"
    echo '2.0.0|2.0.0' > "$state/apt/proxmox-default-kernel"
    echo '6.14.11-4|6.14.11-4' > "$state/apt/proxmox-kernel-6.14"
    echo '2.0.0|2.0.0' > "$state/apt/proxmox-default-headers"
    ct 201 running basalt-gpu
    printf 'arch: amd64\ndev0: /dev/nvidia0,gid=44\ndev1: /dev/nvidiactl\ndev2: /dev/nvidia-uvm\n\n[before-upgrade]\ndev3: /dev/kfd\n' > "$state/lxc/201.conf"
    printf 'OS=Debian GNU/Linux 12 (bookworm)\nNV_USER=580.173.02\nNV_CUDA_LIB=580.173.02\nNV_RUN=1\nNV_APT=\nCUDA=13.0\nTARGET=basalt\n' > "$state/ct-201.probe"
    echo 580.173.02 > "$state/ct-201.nvsmi"
    echo 580.173.02 > "$state/ct-201.cuda-lib"
    ct 202 running llama-vulkan
    printf 'dev0: /dev/dri/renderD128,gid=993\ndev1: /dev/kfd\n' > "$state/lxc/202.conf"
    printf 'OS=Debian GNU/Linux 13 (trixie)\nNV_USER=\nNV_CUDA_LIB=\nNV_APT=\nTARGET=llama\nPKG=mesa-vulkan-drivers|25.0.7-2|25.0.7-3\nPKG=libvulkan1|1.4.309.0-1|1.4.309.0-1\n' > "$state/ct-202.probe"
    ct 203 stopped ollama-gpu
    printf 'lxc.cgroup2.devices.allow: c 195:* rwm\nlxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file\n' > "$state/lxc/203.conf"
    printf 'OS=Ubuntu 24.04 LTS\nNV_USER=580.173.02\nNV_CUDA_LIB=580.173.02\nNV_RUN=1\nNV_APT=\nTARGET=ollama\n' > "$state/ct-203.probe"
    echo 580.173.02 > "$state/ct-203.cuda-lib"
    ct 204 running router
    printf 'arch: amd64\nnet0: name=eth0,bridge=vmbr0\n' > "$state/lxc/204.conf"
}
ct() { echo "$2" > "$state/ct-$1.status"; echo "$3" > "$state/ct-$1.name"; }
cards_both='GPU_CARD=0000:01:00.0|nvidia|rtx40|nvidia|NVIDIA AD102 [GeForce RTX 4090]
GPU_CARD=0000:03:00.0|amd|rdna3|amdgpu|AMD Radeon Navi 31 [Radeon RX 7900 XT/7900 XTX]'

# gpu [VAR=value...] -- [ARGS...]: run the tool; output in $output, status in $rc.
gpu() {
    local -a vars=()
    while (( $# )) && [[ $1 != -- ]]; do vars+=("$1"); shift; done
    (( $# )) && shift
    rc=0
    output=$(env PATH="$stubs:$PATH" KERNEL_RELEASE=6.14.11-4-pve \
        NVIDIA_HELPER="$stubs/nvidia-helper" SETUP_HOST_GPU="$stubs/setup-host-gpu" \
        NVIDIA_BASE_URL=http://nv.test/base DOWNLOAD_DIR="$state/dl" PVE_LXC_DIR="$state/lxc" \
        SYSFS_ROOT="$state/sys" PROC_ROOT="$state/proc" PROC_MODULES="$state/modules" \
        PROC_DRIVER_VERSION="$state/nvversion" MODULES_ROOT="$state/lib-modules" USR_BIN="$state/usrbin" \
        LOCK_FILE="$state/lock" FAKE_CARDS="$cards_both" "${vars[@]}" bash "$tool" "$@" 2>&1) || rc=$?
}
# in_tool CODE: run CODE with the tool's functions loaded (nothing of main runs).
in_tool() {
    env PATH="$stubs:$PATH" PVE_LXC_DIR="$state/lxc" SYSFS_ROOT="$state/sys" \
        bash -c 'source "$1"; set +e; eval "$2"' _ "$tool" "$1"
}

# --- functions ------------------------------------------------------------------------
fresh
[[ $(in_tool 'version_gt 595.112.07 580.196.07 && echo y; version_gt 580.65.06 580.173.02 || echo n; version_gt 580 580 || echo same') == $'y\nn\nsame' ]] ||
    fail 'version_gt'
out=$(in_tool 'NV_RELEASES=$(printf "%s\n" 570.211.01 580.173.02 580.196.07 595.112.07 610.57.04 615.78.08)
    NV_PRODUCTION=595.112.07
    nvidia_pick_candidates 580.173.02 ""; echo "$NV_RECOMMENDED|$NV_CAND_PRODUCTION|$NV_CAND_BRANCH|$NV_CAND_NEWEST"
    nvidia_pick_candidates 580.173.02 580; echo "$NV_RECOMMENDED|$NV_CAND_PRODUCTION|$NV_CAND_BRANCH|$NV_CAND_NEWEST"
    nvidia_pick_candidates 595.104.02 ""; echo "$NV_RECOMMENDED|$NV_CAND_PRODUCTION|$NV_CAND_BRANCH|$NV_CAND_NEWEST"
    nvidia_pick_candidates 610.43.02 ""; echo "$NV_RECOMMENDED|$NV_CAND_PRODUCTION|$NV_CAND_BRANCH|$NV_CAND_NEWEST"
    nvidia_pick_candidates 615.78.08 ""; echo "[$NV_RECOMMENDED]"
    release_label 615.78.08; release_label 595.112.07; release_label 580.196.07; release_label 570.211.01')
[[ $out == $'595.112.07|595.112.07|580.196.07|615.78.08\n580.196.07||580.196.07|\n595.112.07|595.112.07||615.78.08\n610.57.04||610.57.04|615.78.08\n[]\nnew feature branch\nproduction branch\n580 branch, the last for Maxwell, Pascal and Volta\n570 branch' ]] ||
    fail "candidates: $out"
pass 'candidates: production recommended, the installed branch and the newest offered, a Pascal-era card capped at 580, nothing newer -> nothing'

out=$(in_tool 'ct_gpu_nodes 201 | paste -sd" " -; ct_gpu_vendors 201; ct_gpu_vendors 202; ct_gpu_vendors 203; ct_gpu_vendors 204; echo end')
[[ $out == $'/dev/nvidia0 /dev/nvidiactl\nnvidia\namd\nnvidia\n\nend' ]] || fail "vendors: $out"
printf 'lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir\n' > "$state/lxc/205.conf"
printf 'dev0: /dev/dri/renderD129\n' > "$state/lxc/206.conf"
[[ $(in_tool 'ct_gpu_vendors 205; ct_gpu_vendors 206') == $'nvidia amd\nnvidia' ]] || fail "dri: $(in_tool 'ct_gpu_vendors 205; ct_gpu_vendors 206')"
pass 'GPU containers: devN and mount entries, render nodes by their sysfs vendor, the whole /dev/dri, snapshots ignored'

# The container probe's apt classification, against fake dpkg and apt-get:
# which NVIDIA packages the guest cleanup's purge removes (apt's simulation),
# which stay behind, and what else it would take with it.
ctbin=$tmp/ctbin; mkdir -p "$ctbin"
cat > "$ctbin/dpkg-query" <<'EOF'
#!/bin/sh
for p in $FAKE_DPKG; do echo "$p install ok installed"; done
EOF
cat > "$ctbin/dpkg" <<'EOF'
#!/bin/sh
case " $FAKE_DPKG " in *" $2 "*) echo 'Status: install ok installed' ;; *) exit 1 ;; esac
EOF
cat > "$ctbin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$FAKE_CT_LOG"
for p in $FAKE_PURGE; do echo "Purg $p [1.0]"; done
exit "${FAKE_SIM_RC:-0}"
EOF
printf '#!/bin/sh\nexit 0\n' > "$ctbin/ldconfig"
chmod +x "$ctbin"/*
in_tool 'script=$(ct_probe_script); script=${script//@PACKAGES@/none}
    printf "%s\n" "${script//@CLEANUP@/$(nvidia_lxc_guest_cleanup_packages)}"' > "$tmp/probe.sh"
probe() { env PATH="$ctbin:$PATH" FAKE_CT_LOG="$tmp/ct.log" "$@" sh "$tmp/probe.sh" 1 0 | grep -E '^NV_APT'; }
debian='libcuda1 libnvidia-ml1 nvidia-alternative nvidia-smi nvidia-cuda-toolkit libnvidia-container1 nvidia-container-toolkit'
: > "$tmp/ct.log"
out=$(probe FAKE_DPKG="$debian" FAKE_PURGE='libcuda1 libnvidia-ml1:amd64 nvidia-alternative nvidia-smi')
[[ $out == $'NV_APT=libcuda1 libnvidia-ml1 nvidia-alternative nvidia-smi\nNV_APT_LEFT=\nNV_APT_COLLATERAL=' ]] || fail "Debian probe: $out"
[[ $(cat "$tmp/ct.log") == 'apt-get -s purge nvidia-smi libnvidia-ml1 libcuda1 nvidia-alternative' ]] || fail "simulation: $(cat "$tmp/ct.log")"
out=$(probe FAKE_DPKG="$debian" FAKE_PURGE='libcuda1 libnvidia-ml1 nvidia-alternative nvidia-smi nvidia-cuda-toolkit')
[[ $out == *$'NV_APT_LEFT=\nNV_APT_COLLATERAL=nvidia-cuda-toolkit' ]] || fail "collateral probe: $out"
out=$(probe FAKE_DPKG='libnvidia-compute-580 nvidia-utils-580 cuda-drivers-580')
[[ $out == $'NV_APT=cuda-drivers-580 libnvidia-compute-580 nvidia-utils-580\nNV_APT_LEFT=cuda-drivers-580 libnvidia-compute-580 nvidia-utils-580\nNV_APT_COLLATERAL=' ]] ||
    fail "Ubuntu probe: $out"
out=$(probe FAKE_DPKG='libcuda1 nvidia-smi' FAKE_PURGE='libcuda1 nvidia-smi' FAKE_SIM_RC=100)
[[ $out == $'NV_APT=libcuda1 nvidia-smi\nNV_APT_SIM=failed\nNV_APT_LEFT=libcuda1 nvidia-smi\nNV_APT_COLLATERAL=' ]] || fail "failed simulation: $out"
out=$(probe FAKE_DPKG='nvidia-container-toolkit libnvidia-container1')
[[ $out == 'NV_APT=' ]] || fail "toolkit only: $out"
pass "the probe: Debian packages the cleanup removes are convertible, what it leaves or would take along blocks, a failed simulation blocks, CUDA and container toolkits are not driver packages"

mkdir -p "$tmp/x"
cat > "$tmp/x/supported-gpus.json" <<'JSON'
{"chips": [
  {"devid": "0x2684", "name": "NVIDIA GeForce RTX 4090", "features": ["kernelopen"]},
  {"devid": "0x1b80", "name": "NVIDIA GeForce GTX 1080", "features": []},
  {"devid": "0x1292", "name": "GeForce GT 740M", "legacybranch": "470.xx", "features": []}
]}
JSON
out=$(in_tool "NV_DEVIDS=(2684); nvidia_supports_cards '$tmp/x' open && echo ok
    NV_DEVIDS=(1b80); nvidia_supports_cards '$tmp/x' proprietary && echo ok; nvidia_supports_cards '$tmp/x' open || echo no
    NV_DEVIDS=(1292 2b85); nvidia_supports_cards '$tmp/x' proprietary || echo no" 2>&1)
[[ $out == *ok*ok*'10de:1b80 (NVIDIA GeForce GTX 1080): not supported by the open kernel modules'*no*'10de:1292 (GeForce GT 740M): only supported by the 470.xx legacy branch'*'10de:2b85: not in its list of supported GPUs'*no* ]] ||
    fail "supported GPUs: $out"
pass "supported-gpus.json: a card must be listed outside a legacy branch, with kernelopen for open modules"

choose='NV_STATE=outdated NV_LOADED=580.173.02 NV_PRODUCTION=595.112.07 NV_RECOMMENDED=595.112.07
    NV_CAND_PRODUCTION=595.112.07 NV_CAND_BRANCH=580.196.07 NV_CAND_NEWEST=615.78.08
    choose_nvidia 2>/dev/null; echo "[$NV_TARGET]"'
[[ $(printf '\n' | in_tool "$choose") == '[595.112.07]' ]] || fail 'Enter does not take the recommended release'
[[ $(printf '3\n' | in_tool "$choose") == '[615.78.08]' ]] || fail 'menu 3'
[[ $(printf '9\nx\n2\n' | in_tool "$choose") == '[580.196.07]' ]] || fail 'menu retry'
[[ $(printf 's\n' | in_tool "$choose") == '[]' ]] || fail 'menu skip'
[[ $(printf 'n\n' | in_tool 'ask_yes "Go?" y 2>/dev/null && echo yes || echo no') == no ]] || fail 'ask_yes n'
[[ $(printf '\n' | in_tool 'ask_yes "Go?" n 2>/dev/null && echo yes || echo no') == no ]] || fail 'ask_yes default n'
[[ $(printf 'YES\n' | in_tool 'ask_yes "Go?" n 2>/dev/null && echo yes || echo no') == yes ]] || fail 'ask_yes YES'
pass 'the NVIDIA menu: Enter takes the recommended release, a number another, s skips, anything else asks again; yes/no defaults'

# --- --check -------------------------------------------------------------------------
fresh; gpu -- --check
[[ $rc == 3 ]] || fail "check rc $rc: $output"
has 'Host pve-test (Proxmox VE 9.0.10, kernel 6.14.11-4-pve)'
has '0000:01:00.0  NVIDIA AD102 [GeForce RTX 4090] (rtx40, compute 8.9)  driver: nvidia'
has 'NVIDIA driver 580.173.02 loaded (open kernel modules; NVIDIA installer, DKMS)'
has 'NVIDIA user space 580.173.02'
has 'CUDA toolkit 13.0'
has 'target: basalt'
has 'mesa-vulkan-drivers 25.0.7-2 (25.0.7-3 available)'
has 'not checked: stopped (--include-stopped checks it)'
has '595.112.07  production branch  [recommended]'
has '580.196.07  580 branch, the last for Maxwell, Pascal and Volta; the installed branch'
has '615.78.08  new feature branch'
has 'CT 202 (llama-vulkan): upgrade mesa-vulkan-drivers'
has 'Updates are available'
lacks '204'
logged 'pct exec 201 probe refresh=1 apt=0'
logged 'pct exec 202 probe refresh=1 apt=1'
unlogged 'pct exec 203'
for change in 'pct stop' 'pct shutdown' 'pct push' 'pct start' 'helper' 'modprobe' 'apt-get install' 'make '; do unlogged "$change"; done
pass '--check reports the host, each GPU container and the newest compatible releases, changes nothing, exits 3'

fresh; gpu -- --check --no-refresh --ct 202
[[ $rc == 3 ]] || fail "ct filter: $output"
has 'not selected (--ct)'
logged 'pct exec 202 probe refresh=0 apt=1'
logged 'pct exec 201 probe refresh=0 apt=0'
unlogged 'pct exec 203'
unlogged 'apt-get update'
pass '--ct reports only the named containers (running NVIDIA ones are still checked for a host update); --no-refresh runs no apt-get update'

fresh; gpu FAKE_CAP=6.1 -- --check
has '580.196.07  580 branch, the last for Maxwell, Pascal and Volta; the installed branch  [recommended]'
lacks '595.112.07  production'
has 'A card older than Turing keeps NVIDIA on the 580 branch'
pass 'a card below compute capability 7.5 keeps NVIDIA on the 580 branch'

fresh
printf 'OS=Debian GNU/Linux 13 (trixie)\nTARGET=llama\nPKG=mesa-vulkan-drivers|25.0.7-3|25.0.7-3\n' > "$state/ct-202.probe"
gpu -- --check --nvidia keep
[[ $rc == 3 ]] || fail "still outdated NVIDIA counts: $output"
printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  615.78.08  Release Build\n' > "$state/nvversion"
echo 615.78.08 > "$state/modinfo"
sed -i 's/580.173.02/615.78.08/' "$state/ct-201.probe"
gpu -- --check
[[ $rc == 0 ]] || fail "current: rc $rc $output"
has 'NVIDIA 615.78.08 is the newest compatible release (new feature branch).'
has 'Everything is up to date.'
pass 'nothing newer and matching containers: up to date, exit 0'

fresh; gpu FAKE_OFFLINE=1 -- --check
has "NVIDIA's archive (http://nv.test/base/) could not be read"
fresh; echo 595.112.07 > "$state/modinfo"; gpu -- --check
has 'NVIDIA 595.112.07 is installed but 580.173.02 is still loaded: reboot the host'
lacks '[recommended]'
fresh; gpu FAKE_HOST_APT_NV=nvidia-driver -- --check
has "The host's NVIDIA driver comes from apt (nvidia-driver)"
lacks '[recommended]'
fresh; rm -f "$state/nvversion"; gpu -- --check
has 'NVIDIA 580.173.02 is installed but not loaded: reboot the host'
rm -f "$state/modinfo"; gpu -- --check
has 'No NVIDIA driver is loaded: set the GPU up with tools/setup-host-gpu.sh first.'
pass 'offline archive, a pending reboot, an apt-managed or missing host driver: reported, nothing offered'

# --- option checks ------------------------------------------------------------------
fresh; gpu -- --nvidia 'latest; rm -rf /'
[[ $rc == 1 ]] || fail 'a bad --nvidia was accepted'; has '--nvidia takes a version'
gpu -- --ct 201,abc
[[ $rc == 1 ]] || fail 'a bad --ct was accepted'; has '--ct takes container IDs'
gpu FAKE_UID=1000 -- --check
[[ $rc == 1 ]] || fail 'ran as non-root'; has 'Run as root'
gpu
[[ $rc == 1 ]] || fail 'asked without a terminal'; has 'No terminal to ask on'
gpu -- --help
[[ $rc == 0 ]] || fail 'help'; has 'Usage: bash tools/update-gpu-drivers.sh'
pass 'bad options, no root and no terminal are refused; --help works'

# --- updates --------------------------------------------------------------------------
fresh; gpu -- --yes --include-stopped
[[ $rc == 0 ]] || fail "update rc $rc: $output"
logged 'pct start 203'
logged 'pct exec 203 probe'
logged 'curl http://nv.test/base/595.112.07/NVIDIA-Linux-x86_64-595.112.07.run.sha256sum'
logged 'make -C '
logged 'kernel-open'
logged 'KERNEL_UNAME=6.14.11-4-pve'
logged 'pct shutdown 201'
logged 'modprobe -r nvidia_drm'
logged 'modprobe -r nvidia'
logged 'helper host --no-reboot DRIVER_VERSION=595.112.07 KERNEL_MODULE_TYPE=open FORCE= SHA=set'
logged 'modprobe nvidia_drm'
logged 'pct push 201'
logged 'NVIDIA-Linux-x86_64-595.112.07.run'
logged 'DRIVER_VERSION=595.112.07'
logged 'pct exec 201 cleanup NVIDIA packages'
before 'pct exec 201 cleanup NVIDIA packages' 'pct exec 201 -- env DRIVER_VERSION=595.112.07'
logged 'FORCE=false bash /root/osr-gpu-driver-update/install_nvidia.sh lxc'
logged 'pct reboot 201'
logged 'pct exec 202 -- env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade mesa-vulkan-drivers'
logged 'pct reboot 202'
before 'make -C' 'pct shutdown 201'
before 'pct shutdown 201' 'helper host'
before 'modprobe -r nvidia' 'helper host'
before 'helper host' 'pct exec 201 -- env DRIVER_VERSION=595.112.07'
before 'pct exec 203 -- env DRIVER_VERSION=595.112.07' 'pct shutdown 203'
[[ $(cat "$state/ct-203.status") == stopped ]] || fail 'CT 203 was left running'
unlogged 'pct reboot 203'
unlogged 'apt-get install -y -q --only-upgrade libvulkan1'
[[ -f $state/dl/NVIDIA-Linux-x86_64-595.112.07.run ]] || fail 'installer not kept'
has 'Host: NVIDIA 595.112.07 loaded'
has 'CT 201 (basalt-gpu): NVIDIA 595.112.07, NVML and CUDA work'
logged 'pct exec 201 verify NVIDIA 595.112.07'
has 'CT 203 (ollama-gpu): NVIDIA 595.112.07 user space installed (left stopped)'
logged 'pct exec 203 verify NVIDIA 595.112.07'
has 'CT 202 (llama-vulkan): upgraded mesa-vulkan-drivers and restarted'
pass '--yes: the checked release replaces the host driver with the containers stopped, then their libraries; Mesa is upgraded'

fresh; gpu -- --yes --nvidia keep --ct 202
[[ $rc == 0 ]] || fail "keep: $output"
unlogged 'helper'
unlogged 'pct shutdown 201'
logged 'apt-get install -y -q --only-upgrade mesa-vulkan-drivers'
pass '--nvidia keep leaves NVIDIA alone'

fresh; gpu -- --yes --nvidia 580.196.07 --ct 201
logged 'helper host --no-reboot DRIVER_VERSION=580.196.07'
logged 'pct exec 203 -- env DRIVER_VERSION=580.196.07'
unlogged 'apt-get install -y -q --only-upgrade mesa'
fresh; sed -i '/^CUDA=/d' "$state/ct-201.probe"; gpu -- --yes --nvidia 570.211.01 --ct 201
logged 'helper host --no-reboot DRIVER_VERSION=570.211.01'
has 'older than the installed 580.173.02 (a rollback)'
fresh; gpu -- --yes --nvidia 570.211.01 --ct 201
[[ $rc == 1 ]] || fail 'a release below the CUDA 13 floor was accepted'
has 'NVIDIA 570.211.01 is too old for: CT 201 (basalt-gpu) (CUDA 13.0 needs the 580 branch or newer)'
unlogged 'helper'
fresh; gpu -- --yes --nvidia 599.1.2
[[ $rc == 1 ]] || fail 'an unknown release was accepted'; has "NVIDIA 599.1.2 is not in NVIDIA's archive"
fresh; gpu FAKE_CAP=6.1 -- --yes --nvidia 595.112.07
[[ $rc == 1 ]] || fail 'a too new release for Pascal was accepted'; has 'the 580 branch is the last that does'
fresh; gpu -- --yes --nvidia branch --ct 201
logged 'DRIVER_VERSION=580.196.07'
fresh; gpu -- --yes --nvidia newest --ct 201
logged 'DRIVER_VERSION=615.78.08'
pass '--nvidia: a version (also a rollback, a stopped NVIDIA container still follows), branch and newest; unknown releases, ones too new for the card or too old for a CUDA toolkit refused'

fresh; make_release 595.112.07 '{"chips": [{"devid": "0x2684", "name": "NVIDIA GeForce RTX 4090", "legacybranch": "580.xx", "features": []}]}'
gpu -- --yes --ct 201
[[ $rc == 1 ]] || fail "unsupported card: $output"
has '10de:2684 (NVIDIA GeForce RTX 4090): only supported by the 580.xx legacy branch'
has 'NVIDIA 595.112.07: not installed (it failed the checks above)'
unlogged 'pct shutdown 201'
unlogged 'helper'
make_release 595.112.07
fresh; gpu FAKE_MAKE_RC=2 -- --yes --ct 201
[[ $rc == 1 ]] || fail "failed build: $output"
has 'The build for 6.14.11-4-pve failed'
unlogged 'pct shutdown 201'
unlogged 'helper'
fresh; gpu FAKE_MAKE_RC=2 -- --yes --ct 201 --no-probe
[[ $rc == 0 ]] || fail "--no-probe: $output"
unlogged 'make '
logged 'helper host'
pass 'a release that does not support the card or does not build is refused before anything stops; --no-probe skips the build'

fresh
mkdir -p "$state/lib-modules/6.17.2-1-pve/kernel" "$state/lib-modules/6.17.2-1-pve/build"
gpu -- --yes --ct 201
[[ $rc == 0 ]] || fail "newer kernel: $output"
logged 'KERNEL_UNAME=6.17.2-1-pve'
logged 'dkms install 595.112.07 6.17.2-1-pve'
rm -rf "$state/lib-modules/6.17.2-1-pve/build"
fresh; mkdir -p "$state/lib-modules/6.17.2-1-pve/kernel"
gpu FAKE_DKMS_FAIL=1 -- --yes --ct 201 --no-probe
has 'No headers for kernel 6.17.2-1-pve'
[[ $rc == 1 ]] || fail "missing headers for the next kernel: rc $rc"
has 'DKMS has not built NVIDIA 595.112.07 for kernel 6.17.2-1-pve, the one the host boots next'
pass 'a newer installed kernel: the release is test-built and DKMS-built for it too; without headers the next boot is flagged'

fresh; mkdir -p "$state/proc/4242/fd"; ln -s /dev/nvidia0 "$state/proc/4242/fd/7"; echo python3 > "$state/proc/4242/comm"
gpu -- --yes --ct 201
[[ $rc == 1 ]] || fail "holder: $output"
has '4242 python3'
has 'not installed; stop what uses the GPU on the host'
unlogged 'helper host'
logged 'pct start 201'
fresh; gpu FAKE_UNLOAD_FAIL=1 -- --yes --ct 201
[[ $rc == 1 ]] || fail "unload failure: $output"
has 'nvidia_drm (used by 1)'
unlogged 'helper host'
logged 'pct start 201'
fresh; gpu FAKE_STOP_FAIL=201 -- --yes --ct 201
[[ $rc == 1 ]] || fail "stop failure: $output"
has 'CT 201 (basalt-gpu) did not stop'
unlogged 'helper host'
pass 'a host process on the GPU, modules that will not unload or a container that will not stop: nothing installed, containers restarted'

fresh; gpu FAKE_HELPER_FAIL=595.112.07 -- --yes --ct 201
[[ $rc == 1 ]] || fail "failed install: $output"
has 'NVIDIA 595.112.07: the host install FAILED'
logged 'helper host --no-reboot DRIVER_VERSION=580.173.02'
has 'NVIDIA 580.173.02: put back on the host'
logged 'pct start 201'
unlogged 'pct push 201'
pass 'a failed host install puts the previous release back and restarts the containers'

fresh; gpu FAKE_NO_LOAD=1 -- --yes --ct 201
[[ $rc == 2 ]] || fail "no load: rc $rc $output"
has 'Host: NVIDIA 595.112.07 installed; reboot the host to load it'
logged 'FORCE=true bash /root/osr-gpu-driver-update/install_nvidia.sh lxc'
has 'its GPU works after the host reboot'
has 'Reboot the host to finish'
pass 'a driver that only loads after a reboot: the containers get its libraries anyway, exit 2'

fresh; gpu FAKE_LXC_FAIL=201 -- --yes --ct 201
[[ $rc == 1 ]] || fail "lxc failure: $output"
has 'CT 201 (basalt-gpu): FAILED to install NVIDIA 595.112.07'
pass "a container's failed library install is reported"

fresh; gpu FAKE_CUDA_INSTALL_FAIL=201 -- --yes --ct 201
[[ $rc == 1 ]] || fail "post-install CUDA check: $output"
has 'NVIDIA 595.112.07 installed, but NVML or CUDA does not match'
pass 'a guest install is not reported healthy when libcuda remains mismatched'

# A container that does not match the host is offered the host's release.
fresh
sed -i 's/NV_USER=580.173.02/NV_USER=575.64.05/' "$state/ct-201.probe"
gpu -- --check --nvidia keep
has 'NVIDIA user space 575.64.05: does not match the host (580.173.02)'
has 'NVIDIA user space to match the host (580.173.02): 201'
gpu -- --yes --nvidia keep --ct 201
[[ $rc == 0 ]] || fail "sync: $output"
unlogged 'helper host'
logged 'pct push 201'
logged 'NVIDIA-Linux-x86_64-580.173.02.run'
logged 'pct exec 201 -- env DRIVER_VERSION=580.173.02'
logged 'pct reboot 201'
unlogged 'pct shutdown 201'
fresh
sed -i '/^NV_CUDA_LIB=/d' "$state/ct-201.probe"
gpu -- --check --nvidia keep
[[ $rc == 3 ]] || fail "missing CUDA library was reported current: $output"
has 'CUDA driver library missing: does not match the host (580.173.02)'
has 'NVIDIA user space to match the host (580.173.02): 201'
gpu -- --yes --nvidia keep --ct 201
[[ $rc == 0 ]] || fail "missing CUDA library was not repaired: $output"
logged 'pct exec 201 cleanup NVIDIA packages'
logged 'pct exec 201 -- env DRIVER_VERSION=580.173.02'
pass 'matching NVML without libcuda is reported as a mismatch and repaired'

# Ubuntu's or the CUDA repository's NVIDIA packages: not ones the guest
# cleanup removes, so the container is left to apt.
fresh
printf 'OS=Ubuntu 24.04\nNV_USER=570.195.03\nNV_CUDA_LIB=570.195.03\nNV_APT=libnvidia-compute-570 nvidia-utils-570\nNV_APT_LEFT=libnvidia-compute-570 nvidia-utils-570\nNV_APT_COLLATERAL=\n' > "$state/ct-201.probe"
gpu -- --check --nvidia keep
has 'It cannot be converted to the .run libraries: its apt NVIDIA packages libnvidia-compute-570 nvidia-utils-570 are not ones the .run conversion removes'
gpu -- --yes --nvidia keep --ct 201
has "CT 201 (basalt-gpu): not given NVIDIA 580.173.02's user space; its apt NVIDIA packages libnvidia-compute-570 nvidia-utils-570"
unlogged 'pct push 201'
unlogged 'cleanup NVIDIA packages'
pass "a container with Ubuntu or CUDA-repository NVIDIA packages is not given the host's release"

# Debian's NVIDIA packages are converted to the .run libraries (the
# provisioners' cleanup), for a host update and to match the host.
debian_probe='OS=Debian GNU/Linux 12 (bookworm)\nNV_USER=550.163.01\nNV_CUDA_LIB=550.163.01\nNV_APT=libcuda1 libnvidia-ml1 nvidia-alternative nvidia-smi\nNV_APT_LEFT=\nNV_APT_COLLATERAL=\nCUDA=13.0\n'
fresh; printf "$debian_probe" > "$state/ct-201.probe"
gpu -- --check
has "An NVIDIA update replaces those packages with NVIDIA's .run libraries."
lacks 'is blocked'
gpu -- --yes --ct 201
[[ $rc == 0 ]] || fail "Debian conversion during a host update: $output"
logged 'helper host --no-reboot DRIVER_VERSION=595.112.07'
before 'pct exec 201 cleanup NVIDIA packages' 'pct exec 201 -- env DRIVER_VERSION=595.112.07'
has 'CT 201 (basalt-gpu): NVIDIA 595.112.07, NVML and CUDA work'
fresh; printf "$debian_probe" > "$state/ct-201.probe"
gpu -- --yes --nvidia keep --ct 201
[[ $rc == 0 ]] || fail "Debian conversion to match the host: $output"
has "Replace the apt NVIDIA packages in CT 201 (basalt-gpu) (libcuda1 libnvidia-ml1 nvidia-alternative nvidia-smi) with NVIDIA 580.173.02's .run user space"
before 'pct exec 201 cleanup NVIDIA packages' 'pct exec 201 -- env DRIVER_VERSION=580.173.02'
pass "Debian's apt NVIDIA packages are replaced with the .run libraries, for a host update or to match the host"

# A running container that cannot follow blocks the host update before any
# download or test build, even one --ct leaves out; other updates still run.
fresh
printf 'OS=Ubuntu 24.04\nNV_USER=580.173.02\nNV_CUDA_LIB=580.173.02\nNV_APT=libnvidia-compute-580\nNV_APT_LEFT=libnvidia-compute-580\nNV_APT_COLLATERAL=\n' > "$state/ct-201.probe"
gpu -- --check
[[ $rc == 3 ]] || fail "blocked check: $output"
has 'The NVIDIA host update is blocked until these containers can follow it:'
has 'CT 201 (basalt-gpu): its apt NVIDIA packages libnvidia-compute-580 are not ones the .run conversion removes'
gpu -- --yes --ct 202
[[ $rc == 1 ]] || fail "blocked update: $output"
has 'Host NVIDIA: not updated; blocked by CT 201 (basalt-gpu)'
for change in '.run -o' 'make ' 'helper host' 'pct shutdown 201'; do unlogged "$change"; done
logged 'pct exec 202 -- env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade mesa-vulkan-drivers'
fresh
printf 'OS=Debian GNU/Linux 12 (bookworm)\nNV_USER=580.173.02\nNV_CUDA_LIB=580.173.02\nNV_APT=libcuda1\nNV_APT_LEFT=\nNV_APT_COLLATERAL=nvidia-cuda-toolkit\n' > "$state/ct-201.probe"
gpu -- --yes --ct 201
[[ $rc == 1 ]] || fail "collateral removal accepted: $output"
has 'removing its apt NVIDIA packages would also remove nvidia-cuda-toolkit'
for change in '.run -o' 'make ' 'helper host' 'cleanup NVIDIA packages'; do unlogged "$change"; done
fresh; gpu FAKE_PROBE_FAIL=201 -- --yes --ct 201
[[ $rc == 1 ]] || fail "unprobeable container did not block host upgrade: $output"
has 'blocked by CT 201 (basalt-gpu): it could not be checked'
for change in '.run -o' 'make ' 'helper host' 'pct shutdown 201'; do unlogged "$change"; done
fresh; gpu FAKE_GUEST_PROBE_VERSION=575.64.05 -- --yes --ct 201
[[ $rc == 1 ]] || fail "guest view mismatch did not block: $output"
has "it sees NVIDIA driver 575.64.05, not the host's 580.173.02"
for change in '.run -o' 'make ' 'helper host'; do unlogged "$change"; done
pass 'a running container that cannot follow (apt packages the cleanup leaves or would overreach with, not checkable, the wrong host view) blocks the host update before any download'

# A stopped one is checked once started, still before the download.
fresh
printf 'OS=Ubuntu 24.04\nNV_USER=580.173.02\nNV_CUDA_LIB=580.173.02\nNV_APT=libnvidia-compute-580\nNV_APT_LEFT=libnvidia-compute-580\nNV_APT_COLLATERAL=\n' > "$state/ct-203.probe"
gpu -- --yes --ct 201
[[ $rc == 1 ]] || fail "stopped apt container did not block host upgrade: $output"
logged 'pct exec 203 probe'
has 'NVIDIA 595.112.07: not installed; CT 203 (ollama-gpu): its apt NVIDIA packages libnvidia-compute-580'
for change in '.run -o' 'make ' 'helper host' 'pct shutdown 201' 'pct push 203'; do unlogged "$change"; done
[[ $(cat "$state/ct-203.status") == stopped ]] || fail 'CT 203 was left running'
fresh; gpu FAKE_START_FAIL=203 -- --yes --ct 201
[[ $rc == 1 ]] || fail "unstartable container did not block: $output"
has 'CT 203 (ollama-gpu) could not be started for checking'
for change in '.run -o' 'helper host'; do unlogged "$change"; done
fresh; gpu FAKE_START_FAIL=203 -- --check --include-stopped
[[ $rc == 3 ]] || fail "--include-stopped with a container that will not start: rc $rc $output"
has 'not checked: could not be started (--include-stopped)'
pass 'a stopped NVIDIA container is checked once started, before any download; one that cannot follow or start blocks the update; --include-stopped reports one that will not start'

fresh
sed -i 's/NV_APT=/NV_APT=nvidia-installer-cleanup libnvidia-ml1/' "$state/ct-201.probe"
gpu -- --yes --ct 201
[[ $rc == 0 ]] || fail "mixed package cleanup: $output"
logged 'pct exec 201 cleanup NVIDIA packages'
before 'pct exec 201 cleanup NVIDIA packages' 'pct exec 201 -- env DRIVER_VERSION=595.112.07'
pass 'a runfile container with leftover Debian NVIDIA packages is cleaned before reinstalling'

fresh
gpu FAKE_GUEST_NV_VERSION=575.64.05 -- --yes --ct 201
[[ $rc == 1 ]] || fail "guest kernel mismatch was accepted: $output"
has 'does not see the loaded host NVIDIA driver 595.112.07'
unlogged 'pct exec 201 cleanup NVIDIA packages'
unlogged 'pct exec 201 -- env DRIVER_VERSION=595.112.07'
pass 'a container that loses sight of the host driver after the host change keeps its packages'

fresh
gpu FAKE_CLEANUP_FAIL=201 -- --yes --ct 201
[[ $rc == 1 ]] || fail "failed cleanup: $output"
unlogged 'pct exec 201 -- env DRIVER_VERSION=595.112.07'
has 'FAILED to install NVIDIA 595.112.07'
pass 'failed guest package cleanup prevents its runfile install'

# AMD/Intel host: the kernel series and pve-firmware from the Proxmox repositories.
fresh
echo '3.16-3|3.17-1' > "$state/apt/pve-firmware"
echo '6.14.11-4|6.14.11-5' > "$state/apt/proxmox-kernel-6.14"
rm -f "$state/apt/proxmox-default-headers"; echo '|2.0.0' > "$state/apt/proxmox-default-headers"
gpu FAKE_PKGNAMES='proxmox-kernel-6.8 proxmox-kernel-6.14 proxmox-kernel-6.17' -- --check --nvidia keep
has 'pve-firmware 3.16-3 (3.17-1 available)'
has 'AMD/Intel host driver and firmware: pve-firmware proxmox-kernel-6.14'
has 'proxmox-default-headers is not installed'
has 'A newer opt-in kernel series is available (6.17)'
gpu -- --yes --nvidia keep --ct 201
[[ $rc == 2 ]] || fail "host apt: rc $rc $output"
logged 'apt-get install -y -q proxmox-default-headers'
logged 'apt-get install -y -q --only-upgrade pve-firmware proxmox-kernel-6.14'
before 'proxmox-default-headers' 'only-upgrade pve-firmware'
has 'reboot to load the new kernel driver and firmware'
fresh; echo '3.16-3|3.17-1' > "$state/apt/pve-firmware"
gpu FAKE_CARDS='GPU_CARD=0000:01:00.0|nvidia|rtx40|nvidia|NVIDIA AD102 [GeForce RTX 4090]' -- --check --nvidia keep --ct 201
lacks 'AMD/Intel host driver'
pass 'AMD/Intel host: pve-firmware and the running kernel series upgraded (headers first), reboot asked for; an NVIDIA-only host is not offered them'

fresh; gpu FAKE_CT_APT_FAIL=1 -- --yes --nvidia keep --ct 202
[[ $rc == 1 ]] || fail "ct apt failure: $output"
has 'CT 202 (llama-vulkan): the upgrade of mesa-vulkan-drivers FAILED'
unlogged 'pct reboot 202'
pass "a container's failed apt upgrade is reported and the container is not restarted"

fresh; gpu -- --yes --dry-run --include-stopped
[[ $rc == 0 ]] || fail "dry run: $output"
has '+ pct start 203'
has '+ pct shutdown 201'
has '+ modprobe -r nvidia'
has '+ env DRIVER_VERSION=595.112.07'
for change in 'pct start' 'pct shutdown' 'pct push' 'helper' 'modprobe' 'apt-get install' 'make ' 'pct reboot'; do unlogged "$change"; done
[[ ! -e $state/dl/NVIDIA-Linux-x86_64-595.112.07.run ]] || fail 'a dry run downloaded the installer'
pass '--dry-run shows the commands and runs none'

fresh; gpu FAKE_PROBE_FAIL=201 -- --check
has 'not checked: could not be checked (pct exec failed)'
pass 'a container that cannot be checked is reported, not fatal'

printf '%d passed\n' "$passed"
