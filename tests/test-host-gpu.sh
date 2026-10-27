#!/usr/bin/env bash
# tools/setup-host-gpu.sh against a stubbed host: nvidia-smi (answers only once
# the fake driver helper has "installed" the driver), lspci, id and the NVIDIA
# helper. Nothing is installed; no root, GPU or network is needed.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/../tools/setup-host-gpu.sh
passed=0
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
has() { [[ $output == *"$1"* ]] || fail "missing: $1"$'\n'"$output"; }
lacks() { [[ $output != *"$1"* ]] || fail "unexpected: $1"$'\n'"$output"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/host-gpu-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
stubs=$tmp/bin; mkdir -p "$stubs"
log=$tmp/calls.log
cat > "$stubs/nvidia-smi" <<STUB
#!/usr/bin/env bash
[[ -e "$tmp/loaded" ]] || exit 9
case "\$*" in
    *pci.bus_id*) printf '%s\n' "\${FAKE_NV_GPUS:-0, 00000000:01:00.0, \${FAKE_CAP:-8.9}}" ;;
    *compute_cap*) echo "\${FAKE_CAP:-8.9}" ;;
    *) echo "GPU 0: NVIDIA GeForce RTX 4090 (UUID: GPU-0)" ;;
esac
STUB
printf '#!/usr/bin/env bash\n[[ -n ${FAKE_LSPCI:-} ]] && cat "$FAKE_LSPCI"\nexit 0\n' > "$stubs/lspci"
printf '#!/usr/bin/env bash\necho "${FAKE_UID:-0}"\n' > "$stubs/id"
chmod +x "$stubs/nvidia-smi" "$stubs/lspci" "$stubs/id"
helper=$tmp/install_nvidia_580_173_02.sh
cat > "$helper" <<STUB
#!/usr/bin/env bash
DRIVER_VERSION="580.173.02"
echo "helper \$* KERNEL_MODULE_TYPE=\${KERNEL_MODULE_TYPE:-}" >> "$log"
echo "helper output"
[[ \${FAKE_NO_LOAD:-0} == 1 ]] || touch "$tmp/loaded"
STUB
ada=$tmp/lspci-ada
cat > "$ada" <<'PCI'
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684] (rev a1)
	Subsystem: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:167c]
	Kernel driver in use: nouveau
	Kernel modules: nouveau
01:00.1 Audio device [0403]: NVIDIA Corporation AD102 High Definition Audio Controller [10de:22ba] (rev a1)
PCI
: > "$tmp/lspci-none"
sed 's/Kernel driver in use: nouveau/Kernel driver in use: vfio-pci/' "$ada" > "$tmp/lspci-vfio"
printf 'nouveau 2973696 0 - Live 0x0000000000000000\n' > "$tmp/nouveau"
: > "$tmp/modules"

fresh() { rm -f "$tmp/loaded"; : > "$log"; }
# gpu [VAR=value...] -- [ARGS...]: run the tool; stdout in $stdout, both in $output, status in $rc.
gpu() {
    local -a vars=()
    while (( $# )) && [[ $1 != -- ]]; do vars+=("$1"); shift; done
    (( $# )) && shift
    rc=0
    stdout=$(env -i "PATH=$stubs:$PATH" FAKE_LSPCI="$ada" NVIDIA_HELPER="$helper" PROC_MODULES="$tmp/modules" \
        "${vars[@]}" bash "$tool" "$@" 2>"$tmp/stderr") || rc=$?
    output=$stdout$'\n'$(< "$tmp/stderr")
}
field() { sed -n "s/^$1=//p" <<< "$stdout"; }

fresh; gpu -- --dry-run
[[ $rc == 0 ]] || fail "dry run: $output"
has 'No NVIDIA driver is loaded on this host'
has 'AD102 [GeForce RTX 4090]'
lacks 'Audio device'
has 'ask for the GPU generation (rtx20, rtx30, rtx40 or rtx50; suggested: rtx40)'
[[ $(field GPU_STATE) == planned && $(field GPU_GENERATION) == rtx40 && $(field GPU_CUDA_ARCH) == 89 ]] || fail "plan: $stdout"
pass 'a dry run lists the NVIDIA cards and suggests the generation from the codename'

for answer in rtx20:75 2080:75 3:89 40:89 'RTX 4070 Ti:89' 4090:89 rtx30:86 3090:86 5090:120 rtx50:120; do
    fresh; gpu "GPU_GENERATION=${answer%:*}" -- --dry-run
    [[ $rc == 0 && $(field GPU_CUDA_ARCH) == "${answer##*:}" ]] || fail "$answer: $output"
done
has '+ env KERNEL_MODULE_TYPE=open bash'
has 'install_nvidia_580_173_02.sh host --no-reboot'
[[ ! -s $log ]] || fail 'a dry run ran the helper'
for bad in rtx60 1080 6 'gtx 1650'; do
    fresh; gpu "GPU_GENERATION=$bad" -- --dry-run
    [[ $rc == 1 ]] || fail "$bad accepted"; has 'GPU_GENERATION must be'
done
pass 'generations, menu numbers and model numbers map to the CUDA architecture; others are refused'

fresh; gpu GPU_GENERATION=rtx40 -- --dry-run --allow rtx50:Basalt
[[ $rc == 1 ]] || fail 'Basalt accepted an RTX 40'
has 'Basalt needs an rtx50 GPU (GeForce RTX 50 series, RTX PRO Blackwell (Blackwell)); this one is rtx40'
fresh; gpu GPU_GENERATION=rtx50 -- --dry-run --allow rtx50:Basalt
[[ $rc == 0 ]] || fail "Basalt refused an RTX 50: $output"
fresh; gpu -- --dry-run --allow rtx99:Basalt
[[ $rc == 1 ]] || fail 'a malformed --allow was accepted'
pass 'a target that accepts only some generations refuses the others before anything is installed'

touch "$tmp/loaded"; : > "$log"
gpu -- --allow rtx40:Xolotl
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_CUDA_ARCH) == 89 && $(field GPU_GENERATION) == rtx40 ]] || fail "loaded: $output"
[[ ! -s $log ]] || fail 'the helper ran with a driver already loaded'
gpu FAKE_CAP=8.9 -- --allow rtx50:Basalt
[[ $rc == 1 ]] || fail 'a loaded RTX 40 passed Basalt'
has 'Basalt needs an rtx50 GPU'
pass 'a loaded driver is only reported (and checked against the targets), never replaced'

gpu FAKE_CAP=6.1 -- --allow rtx40:Xolotl
[[ $rc == 1 ]] || fail 'a loaded unlisted NVIDIA card passed a generation restriction'
has "GPU 0's compute capability (61) is not a generation the targets accept (Xolotl: rtx40)."
gpu FAKE_CAP=N/A -- --need optional --for Basalt --allow rtx50:Basalt
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "optional restricted, unreadable capability: $output"
has "GPU 0's compute capability (unreadable) is not a generation the targets accept (Basalt: rtx50)."
pass 'an unlisted or unreadable NVIDIA compute capability never passes a generation restriction'

for cap in 7.0:70 8.0:80 9.0:90 6.1:61; do
    gpu FAKE_CAP="${cap%:*}" -- --need required --for 'llamacpp maya'
    [[ $rc == 0 && $(field GPU_STATE) == ready && -z $(field GPU_GENERATION) && $(field GPU_CUDA_ARCH) == "${cap#*:}" ]] ||
        fail "unrestricted ${cap%:*}: $output"
done
gpu FAKE_CAP=8.0 -- --need optional --vendors nvidia,amd,intel --for Ollama
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_VENDOR) == nvidia ]] || fail "optional A100: $output"
pass 'V100, A100, H100 or GTX 10 cards are ready for targets without a generation restriction'

fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_UID=1000 --
[[ $rc == 1 ]] || fail 'ran without root'; has 'Run as root'
[[ ! -s $log ]] || fail 'the helper ran without root'
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes --
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_CUDA_ARCH) == 89 ]] || fail "install: $output"
grep -qx 'helper host --no-reboot KERNEL_MODULE_TYPE=open' "$log" || fail "helper call: $(cat "$log")"
lacks 'helper output'$'\n''GPU_STATE'
[[ $stdout != *'helper output'* ]] || fail 'the helper wrote to stdout'
has 'NVIDIA 580.173.02 is loaded.'
pass 'with consent the helper installs the open kernel modules and the driver is loaded; stdout stays machine-readable'

fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_CAP=8.6 --
[[ $rc == 0 && $(field GPU_CUDA_ARCH) == 86 && $(field GPU_GENERATION) == rtx30 ]] || fail "real cap: $output"
has 'GPU 0 reports compute capability 86, not rtx40'"'"'s 89; using 86'
fresh; gpu GPU_GENERATION=rtx50 INSTALL_HOST_DRIVER=yes FAKE_CAP=8.9 -- --allow rtx50:Basalt
[[ $rc == 1 ]] || fail 'a wrong answer let Basalt through'
pass 'once loaded, the real compute capability wins over the answer'

fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_CAP=6.1 -- --allow rtx40:Xolotl
[[ $rc == 1 ]] || fail 'an installed driver with an unlisted compute capability passed a restriction'
has "GPU 0's compute capability (61) is not a generation the targets accept (Xolotl: rtx40)."
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_CAP=8.0 --
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_CUDA_ARCH) == 80 && -z $(field GPU_GENERATION) ]] ||
    fail "installed A100, unrestricted: $output"
has "GPU 0 reports compute capability 80, not rtx40's 89; using 80."
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_CAP=N/A --
[[ $rc == 0 && $(field GPU_STATE) == ready ]] || fail "installed, unreadable capability: $output"
has "GPU 0's compute capability is unreadable after installing"
lacks 'compute capability , not'
pass 'after installing, the detected capability is checked only against generation restrictions'

fresh; gpu GPU_GENERATION=rtx40 --
[[ $rc == 1 ]] || fail 'installed unattended without consent'; has 'Set INSTALL_HOST_DRIVER=yes'
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=no --
[[ $rc == 1 ]] || fail 'INSTALL_HOST_DRIVER=no installed'; has 'No NVIDIA driver was installed'
has 'An NVIDIA GPU is needed for these targets'
fresh; gpu INSTALL_HOST_DRIVER=yes -- --for 'Strata, Xolotl'
[[ $rc == 1 ]] || fail 'no generation accepted unattended'
has 'set GPU_GENERATION=rtx20|rtx30|rtx40|rtx50 and INSTALL_HOST_DRIVER=yes'
[[ ! -s $log ]] || fail 'the helper ran without an answer'
pass 'required targets: no consent or no answer is an error, and nothing is installed'

fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=no -- --need optional --for 'Ollama'
[[ $rc == 0 && $(field GPU_STATE) == declined ]] || fail "optional decline: $output"
has 'Ollama will run without a GPU'
fresh; gpu -- --need optional
[[ $rc == 0 && $(field GPU_STATE) == declined ]] || fail "optional, no terminal: $output"
fresh; gpu FAKE_LSPCI="$tmp/lspci-none" -- --need optional
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "optional, no card: $output"
[[ ! -s $log ]] || fail 'the helper ran for an optional target that declined'
pass 'optional targets: a no, no terminal or no card reports declined/absent and carries on'

fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_LSPCI="$tmp/lspci-none" -- --for Maya
[[ $rc == 1 ]] || fail 'a host without a card got a driver'
has "No NVIDIA GPU is on this host's PCI bus (lspci -d 10de:). An NVIDIA GPU is needed for Maya."
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_LSPCI="$tmp/lspci-vfio" --
[[ $rc == 1 ]] || fail 'a vfio-pci card got a driver'; has 'bound to vfio-pci'
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_LSPCI="$tmp/lspci-vfio" -- --need optional
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "optional vfio: $output"
[[ ! -s $log ]] || fail 'the helper ran for a card it cannot use'
pass 'no card on the PCI bus, or one reserved for VMs (vfio-pci), gets no driver'

fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_NO_LOAD=1 PROC_MODULES="$tmp/nouveau" --
[[ $rc == 2 ]] || fail "nouveau: rc=$rc $output"
has 'nouveau still holds the GPU. Reboot this host, then run this again (GPU_GENERATION=rtx40)'
fresh; gpu GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes FAKE_NO_LOAD=1 --
[[ $rc == 1 ]] || fail "not loaded: rc=$rc"; has 'is installed but did not load'
pass 'nouveau holding the card exits 2 (reboot, then run again); a driver that does not load is an error'

# On a terminal: the menu, a re-prompt, the suggested default and the consent.
interactive() {   # interactive INPUT [ARGS...]
    local input=$1; shift
    printf '%s' "$input" | env PATH="$stubs:$PATH" FAKE_LSPCI="$ada" NVIDIA_HELPER="$helper" PROC_MODULES="$tmp/modules" \
        script -qec "bash $(printf '%q ' "$tool" "$@")" /dev/null 2>&1 | tr -d '\r'
}
fresh; output=$(interactive $'9\n\ny\n')
has '4) rtx50  GeForce RTX 50 series, RTX PRO Blackwell (Blackwell), compute capability 12.0'
has 'GPU generation (1-4, rtx20..rtx50 or a model number like 4090) [rtx40]:'
has 'Enter 1-4, rtx20, rtx30, rtx40, rtx50'
has 'Install NVIDIA 580.173.02 (open kernel modules, DKMS) on this Proxmox host now?'
has 'GPU_CUDA_ARCH=89'
grep -q 'helper host --no-reboot KERNEL_MODULE_TYPE=open' "$log" || fail 'the confirmed install did not run'
fresh; output=$(interactive $'5090\nn\n') || true
has 'No NVIDIA driver was installed'
[[ ! -s $log ]] || fail 'the helper ran after a no on the terminal'
fresh; output=$(interactive $'4090\nn\n' --need optional)
has 'GPU_STATE=declined'
pass 'on a terminal: the menu, a re-prompt, the suggested default, and a yes/no'
fresh; output=$(interactive $'b580\nn\n' --vendors nvidia,amd,intel --need optional)
has '8) arc-b  Arc B-series, Arc Pro B-series (Battlemage)'
has '5) rdna3  Radeon RX 7000 series, Radeon PRO W7000 (RDNA 3)'
has 'GPU generation (1-8, rtx20..arc-b or a model number like 4090) [rtx40]:'
has 'GPU_STATE='
pass 'on a terminal with every vendor allowed: eight generations to choose from'

# ── AMD Radeon and Intel Arc: in-kernel drivers, firmware and device nodes ──
sys=$tmp/sys; dev=$tmp/dev; fw=$tmp/firmware; mpd=$tmp/modprobe.d; mld=$tmp/modules-load.d
amd=$tmp/lspci-amd
cat > "$amd" <<'PCI'
0000:00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-S GT1 [UHD Graphics 770] [8086:a780] (rev 04)
	Kernel driver in use: i915
0000:03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M] [1002:744c] (rev c8)
	Subsystem: Sapphire Technology Limited Device [1da2:471e]
	Kernel modules: amdgpu
0000:03:00.1 Audio device [0403]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 HDMI/DP Audio [1002:ab30]
PCI
sed 's/^\tKernel modules: amdgpu$/\tKernel driver in use: amdgpu\n\tKernel modules: amdgpu/' "$amd" > "$tmp/lspci-amd-bound"
arcb=$tmp/lspci-arcb
cat > "$arcb" <<'PCI'
0000:04:00.0 VGA compatible controller [0300]: Intel Corporation Battlemage G21 [Arc B580] [8086:e20b]
	Kernel modules: xe
PCI
sed 's/^\tKernel modules: xe$/\tKernel driver in use: xe/' "$arcb" > "$tmp/lspci-arcb-bound"
mixed=$tmp/lspci-mixed
cat "$amd" "$arcb" > "$mixed"
cat >> "$mixed" <<'PCI'
0000:05:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 48 [Radeon RX 9070/9070 XT/9070 GRE] [1002:7550] (rev c0)
0000:06:00.0 VGA compatible controller [0300]: Intel Corporation DG2 [Arc A770] [8086:56a0] (rev 08)
PCI
# modprobe "binds" the card: the bound listing, its render node and /dev/kfd.
cat > "$stubs/modprobe" <<STUB
#!/usr/bin/env bash
echo "modprobe \$*" >> "$log"
[[ \${FAKE_BIND:-1} == 1 ]] || exit 0
cp "\$FAKE_BOUND" "\$FAKE_LSPCI"
mkdir -p "$sys/bus/pci/devices/\$FAKE_ADDR/drm/renderD128" "$dev/dri"; touch "$dev/dri/renderD128"
[[ \$1 != amdgpu ]] || touch "$dev/kfd"
STUB
cat > "$stubs/apt-get" <<STUB
#!/usr/bin/env bash
echo "apt-get \$*" >> "$log"
[[ \$* != *pve-firmware* || \${FAKE_FW_PKG:-1} != 1 ]] || { mkdir -p "$fw/amdgpu" "$fw/xe"; touch "$fw/amdgpu/gc_11_0_0_mec.bin.zst" "$fw/xe/bmg_guc_70.bin.zst"; }
STUB
printf '#!/bin/sh\nexit 0\n' > "$stubs/udevadm"
chmod +x "$stubs/modprobe" "$stubs/apt-get" "$stubs/udevadm"
# reset_kernel LISTING BOUND ADDR: a host with LISTING on the bus, firmware present, nothing loaded or bound.
reset_kernel() {
    rm -rf "$sys" "$dev" "$fw" "$mpd" "$mld"; mkdir -p "$fw/amdgpu" "$fw/xe" "$fw/i915" "$mpd" "$mld"
    touch "$fw/amdgpu/gc_11_0_0_mec.bin.zst" "$fw/amdgpu/gc_12_0_1_mec.bin.zst" "$fw/xe/bmg_guc_70.bin.zst" "$fw/i915/dg2_guc_70.bin"
    cp "$1" "$tmp/lspci-now"; bound=$2; addr=$3; : > "$tmp/modules"; fresh
}
kgpu() { gpu FAKE_LSPCI="$tmp/lspci-now" FAKE_BOUND="$bound" FAKE_ADDR="$addr" SYSFS_ROOT="$sys" DEV_ROOT="$dev" \
    FIRMWARE_DIR="$fw" MODPROBE_DIR="$mpd" MODULES_LOAD_DIR="$mld" KERNEL_RELEASE=6.14.11-4-pve "$@"; }
all=(--vendors "nvidia,amd,intel")

reset_kernel "$tmp/lspci-amd-bound" "$tmp/lspci-amd-bound" 0000:03:00.0
mkdir -p "$sys/bus/pci/devices/0000:03:00.0/drm/renderD128" "$dev/dri"; touch "$dev/kfd" "$dev/dri/renderD128"
kgpu -- "${all[@]}"
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_VENDOR) == amd && $(field GPU_GENERATION) == rdna3 &&
   $(field GPU_GFX) == gfx1100 && $(field GPU_RENDER_NODE) == /dev/dri/renderD128 && -z $(field GPU_CUDA_ARCH) ]] || fail "amd ready: $output"
[[ ! -s $log ]] || fail "a ready AMD card was touched: $(cat "$log")"
has 'AMD Radeon GPU ready'
touch "$tmp/loaded"
kgpu -- --vendors amd,nvidia
[[ $(field GPU_VENDOR) == amd ]] || fail "vendor preference: $output"
kgpu -- --vendors nvidia,amd
[[ $(field GPU_VENDOR) == nvidia ]] || fail "vendor preference (nvidia first): $output"
rm -f "$tmp/loaded"
kgpu -- --vendors nvidia --for Strata
[[ $rc == 1 ]] || fail 'an AMD card passed an NVIDIA-only target'
has 'An NVIDIA GPU is needed for Strata'
pass 'a working AMD card (amdgpu, render node, /dev/kfd) is reported with its LLVM target; vendors go in the order given; NVIDIA-only targets refuse it'

reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
kgpu -- "${all[@]}" --dry-run
[[ $rc == 0 && $(field GPU_STATE) == planned && $(field GPU_GENERATION) == rdna3 && $(field GPU_VENDOR) == amd ]] || fail "amd plan: $output"
has 'suggested: rdna3'
has 'rtx20, rtx30, rtx40, rtx50, rdna3, rdna4, arc-a or arc-b'
lacks 'UHD Graphics 770'
reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
kgpu GPU_GENERATION='RX 7900 XTX' -- "${all[@]}" --dry-run
[[ $rc == 0 && $(field GPU_STATE) == planned && $(field GPU_GFX) == gfx1100 ]] || fail "amd dry run: $output"
has '+ modprobe amdgpu'
has "+ add amdgpu to $mld/gpu-lxc.conf"
lacks 'apt-get'
[[ ! -s $log && ! -s $mld/gpu-lxc.conf ]] || fail 'a dry run changed the host'
pass 'AMD: the card is suggested from its PCI ID (an Intel iGPU is ignored), and a dry run only shows the steps'

reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes -- "${all[@]}" --for Ollama
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_RENDER_NODE) == /dev/dri/renderD128 ]] || fail "amd setup: $output"
grep -qx 'modprobe amdgpu' "$log" || fail "modprobe: $(cat "$log")"
grep -q apt-get "$log" && fail 'pve-firmware installed although the firmware is there'
grep -qx amdgpu "$mld/gpu-lxc.conf" || fail 'amdgpu is not loaded at boot'
[[ $stdout != *modprobe* ]] || fail 'stdout is not machine-readable'
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes -- "${all[@]}"
[[ $(grep -c . "$mld/gpu-lxc.conf") == 1 ]] || fail 'a rerun added amdgpu twice'
pass 'AMD with consent: amdgpu is loaded now and at boot, and the card with its nodes is reported'

reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
rm -f "$fw/amdgpu/"*
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes -- "${all[@]}"
[[ $rc == 0 && $(field GPU_STATE) == ready ]] || fail "firmware: $output"
grep -q 'apt-get update' "$log" && grep -q 'apt-get install -y pve-firmware' "$log" || fail "apt: $(cat "$log")"
has 'is missing; installing pve-firmware'
reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
rm -f "$fw/amdgpu/"*
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes FAKE_FW_PKG=0 -- "${all[@]}"
[[ $rc == 1 ]] || fail 'went on without firmware'; has 'pve-firmware has no firmware for rdna3'
grep -q modprobe "$log" && fail 'loaded amdgpu without firmware'
reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
printf 'amdgpu 15000000 0 - Live 0x0\n' > "$tmp/modules"
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes FAKE_BIND=0 -- "${all[@]}"
[[ $rc == 2 ]] || fail "loaded but unbound: rc=$rc $output"
has 'Reboot this host, then run this again (GPU_GENERATION=rdna3)'
grep -q 'modprobe' "$log" && fail 'modprobe ran for a loaded module'
reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes FAKE_BIND=0 -- "${all[@]}"
[[ $rc == 1 ]] || fail "no render node: rc=$rc"; has 'amdgpu is loaded but the card has no render node'
pass 'missing firmware comes from pve-firmware; a card the loaded driver did not take needs a reboot (exit 2)'

reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
printf '# for the Windows VM\nblacklist amdgpu\n' > "$mpd/vfio.conf"
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes -- "${all[@]}" --for Ollama
[[ $rc == 1 ]] || fail 'a blacklisted driver was loaded'
has "amdgpu is blacklisted in $mpd/vfio.conf"
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes -- "${all[@]}" --need optional --for ComfyUI
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "optional blacklist: $output"
[[ ! -s $log ]] || fail 'the host was changed despite the blacklist'
reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
sed -i 's/Kernel modules: amdgpu/Kernel driver in use: vfio-pci/' "$tmp/lspci-now"
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=yes -- "${all[@]}" --need optional
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "amd vfio: $output"; has 'bound to vfio-pci'
reset_kernel "$amd" "$tmp/lspci-amd-bound" 0000:03:00.0
kgpu GPU_GENERATION=rdna3 INSTALL_HOST_DRIVER=no -- "${all[@]}" --for Ollama
[[ $rc == 1 ]] || fail 'declined setup passed'; has 'The amdgpu driver was not set up'
has 'An NVIDIA, AMD Radeon or Intel Arc GPU is needed for Ollama'
[[ ! -s $log ]] || fail 'changed the host after a no'
pass 'a blacklisted driver, a vfio-pci card or a no changes nothing'

reset_kernel "$arcb" "$tmp/lspci-arcb-bound" 0000:04:00.0
kgpu GPU_GENERATION=b580 INSTALL_HOST_DRIVER=yes KERNEL_RELEASE=6.8.12-9-pve -- --vendors intel
[[ $rc == 1 ]] || fail 'Arc B on 6.8'; has 'Arc B-series cards need Linux 6.12 or newer'
reset_kernel "$arcb" "$tmp/lspci-arcb-bound" 0000:04:00.0
kgpu GPU_GENERATION=b580 INSTALL_HOST_DRIVER=yes -- --vendors amd,intel
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_VENDOR) == intel && $(field GPU_GENERATION) == arc-b &&
   -z $(field GPU_GFX) && $(field GPU_RENDER_NODE) == /dev/dri/renderD128 ]] || fail "arc b: $output"
grep -qx 'modprobe xe' "$log" || fail "xe: $(cat "$log")"
[[ ! -e $dev/kfd ]] || fail 'kfd for Intel'
reset_kernel "$tmp/lspci-arcb-bound" "$tmp/lspci-arcb-bound" 0000:04:00.0
mkdir -p "$sys/bus/pci/devices/0000:04:00.0/drm/renderD129" "$dev/dri"; touch "$dev/dri/renderD129"
kgpu -- --vendors intel
[[ $(field GPU_STATE) == ready && $(field GPU_RENDER_NODE) == /dev/dri/renderD129 ]] || fail "arc ready: $output"
pass 'Intel Arc: xe for Battlemage (Linux 6.12+), no /dev/kfd, the render node of that card'

reset_kernel "$mixed" "$mixed" 0000:03:00.0
kgpu -- "${all[@]}" --dry-run
lacks 'suggested:'
has 'DG2 [Arc A770]'
for answer in 'RX 7900 XTX:rdna3:gfx1100' W7800:rdna3:gfx1100 '9070 XT:rdna4:gfx1201' 'Radeon AI PRO R9700:rdna4:gfx1201' \
        rdna4:rdna4:gfx1201 'Arc A770:arc-a:' A380:arc-a: arc-b:arc-b: 'Arc Pro B50:arc-b:' 6:rdna4:gfx1201 8:arc-b:; do
    IFS=: read -r given want gfx <<< "$answer"
    kgpu "GPU_GENERATION=$given" -- "${all[@]}" --dry-run
    [[ $rc == 0 && $(field GPU_GENERATION) == "$want" && $(field GPU_GFX) == "$gfx" ]] || fail "$given: $output"
done
kgpu GPU_GENERATION=7900 -- --vendors nvidia --dry-run
[[ $rc == 1 ]] || fail 'an AMD answer passed NVIDIA-only targets'; has 'rdna3 (Radeon RX 7000 series, Radeon PRO W7000 (RDNA 3)) is not an option here'
kgpu GPU_GENERATION=rdna3 -- "${all[@]}" --dry-run --allow rtx50:Basalt
[[ $rc == 1 ]] || fail 'Basalt accepted an AMD card'
kgpu GPU_GENERATION=a6000 -- "${all[@]}" --dry-run
[[ $rc == 1 ]] || fail 'a6000 (an NVIDIA workstation card) became an Arc'
pass 'AMD and Intel model numbers, names and menu numbers; several generations on the bus give no suggestion'

# ── one card out of several: --list and --card ──
kgpu -- --list "${all[@]}"
[[ $rc == 0 ]] || fail "list: $output"
has 'GPU_CARD=0000:03:00.0|amd|rdna3||AMD Radeon Navi 31 [Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M]'
has 'GPU_CARD=0000:04:00.0|intel|arc-b||Intel Arc Battlemage G21 [Arc B580]'
has 'GPU_CARD=0000:05:00.0|amd|rdna4||'
has 'GPU_CARD=0000:06:00.0|intel|arc-a||Intel Arc DG2 [Arc A770]'
lacks 'UHD Graphics 770'
[[ $(grep -c '^GPU_CARD=' <<< "$stdout") == 4 && $stdout != *GPU_STATE* ]] || fail "list lines: $stdout"
gpu -- --list --vendors nvidia
has 'GPU_CARD=0000:01:00.0|nvidia|rtx40|nouveau|NVIDIA AD102 [GeForce RTX 4090]'
printf '41:00.0 3D controller [0302]: NVIDIA Corporation GA100 [A100 PCIe 40GB] [10de:20f1] (rev a1)\n\tKernel driver in use: nvidia\n' > "$tmp/lspci-a100"
gpu FAKE_LSPCI="$tmp/lspci-a100" -- --list --vendors nvidia,amd
has 'GPU_CARD=0000:41:00.0|nvidia||nvidia|NVIDIA GA100 [A100 PCIe 40GB]'
gpu FAKE_LSPCI="$tmp/lspci-none" -- --list
[[ $rc == 0 && -z $stdout ]] || fail "empty list: $output"
pass '--list prints every card of the vendors with its address, generation and driver, and changes nothing'

two=$tmp/lspci-two-bound
cat "$tmp/lspci-amd-bound" "$tmp/lspci-arcb-bound" > "$two"
reset_kernel "$two" "$two" 0000:03:00.0
mkdir -p "$sys/bus/pci/devices/0000:03:00.0/drm/renderD128" "$sys/bus/pci/devices/0000:04:00.0/drm/renderD129" "$dev/dri"
touch "$dev/kfd" "$dev/dri/renderD128" "$dev/dri/renderD129"
kgpu -- --vendors intel --card 0000:04:00.0
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_VENDOR) == intel && $(field GPU_RENDER_NODE) == /dev/dri/renderD129 &&
   $(field GPU_PCI) == 0000:04:00.0 ]] || fail "card arc: $output"
kgpu -- --vendors amd --card 03:00.0
[[ $rc == 0 && $(field GPU_VENDOR) == amd && $(field GPU_RENDER_NODE) == /dev/dri/renderD128 && $(field GPU_PCI) == 0000:03:00.0 ]] ||
    fail "card amd: $output"
kgpu -- "${all[@]}"
[[ $(field GPU_PCI) == 0000:03:00.0 ]] || fail "the first ready card reports its address: $output"
kgpu -- --vendors amd --card 0000:04:00.0 --for Ollama
[[ $rc == 1 ]] || fail 'an Intel card passed as AMD'; has 'The GPU at 0000:04:00.0 is Intel Arc, not AMD Radeon (for Ollama).'
kgpu -- --vendors amd --card 0000:09:00.0 --need optional
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "missing card, optional: $output"
has 'No supported AMD Radeon GPU is at 0000:09:00.0'
kgpu -- --vendors amd --card 0000:09:00.0
[[ $rc == 1 ]] || fail 'a missing card passed a required target'
kgpu -- --card 3:0.0
[[ $rc == 1 ]] || fail 'a malformed --card was accepted'; has '--card takes a PCI address'
pass '--card checks and reports that card only (render node, address), and refuses one of another vendor or not on the bus'

sed 's/^\(0000:05:00.0 .*\)$/\1\n\tKernel driver in use: amdgpu/' "$mixed" > "$tmp/lspci-mixed-9070"
reset_kernel "$mixed" "$tmp/lspci-mixed-9070" 0000:05:00.0
kgpu INSTALL_HOST_DRIVER=yes -- "${all[@]}" --card 0000:05:00.0 --for Ollama
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_GENERATION) == rdna4 && $(field GPU_GFX) == gfx1201 &&
   $(field GPU_PCI) == 0000:05:00.0 ]] || fail "card setup: $output"
grep -qx 'modprobe amdgpu' "$log" || fail "modprobe: $(cat "$log")"
lacks 'Which generation is the GPU?'
pass "--card takes the card's generation from its PCI ID: no question, even without a terminal"

nvtwo=$tmp/lspci-nv-two
cat > "$nvtwo" <<'PCI'
0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684] (rev a1)
	Kernel driver in use: nvidia
0000:02:00.0 VGA compatible controller [0300]: NVIDIA Corporation GB202 [GeForce RTX 5090] [10de:2b85] (rev a1)
	Kernel driver in use: nvidia
PCI
nvp=$tmp/proc-nvidia
mkdir -p "$nvp/gpus/0000:01:00.0" "$nvp/gpus/0000:02:00.0"
printf 'Model: \t\t NVIDIA GeForce RTX 4090\nDevice Minor: \t 0\n' > "$nvp/gpus/0000:01:00.0/information"
printf 'Model: \t\t NVIDIA GeForce RTX 5090\nDevice Minor: \t 1\n' > "$nvp/gpus/0000:02:00.0/information"
nvgpus=$'0, 00000000:01:00.0, 8.9\n1, 00000000:02:00.0, 12.0'
touch "$tmp/loaded"; : > "$log"
gpu FAKE_LSPCI="$nvtwo" NVIDIA_PROC="$nvp" FAKE_NV_GPUS="$nvgpus" -- --card 0000:02:00.0 --allow rtx50:Basalt
[[ $rc == 0 && $(field GPU_STATE) == ready && $(field GPU_GENERATION) == rtx50 && $(field GPU_CUDA_ARCH) == 120 &&
   $(field GPU_NVIDIA_MINOR) == 1 && $(field GPU_PCI) == 0000:02:00.0 ]] || fail "nvidia card 2: $output"
has 'An NVIDIA driver is loaded (The GPU at 0000:02:00.0: compute capability 120).'
gpu FAKE_LSPCI="$nvtwo" NVIDIA_PROC="$nvp" FAKE_NV_GPUS="$nvgpus" -- --card 0000:01:00.0 --allow rtx50:Basalt
[[ $rc == 1 ]] || fail 'the RTX 4090 passed Basalt'; has 'this one is rtx40'
gpu FAKE_LSPCI="$nvtwo" NVIDIA_PROC="$nvp" FAKE_NV_GPUS="$nvgpus" -- --card 0000:01:00.0
[[ $rc == 0 && $(field GPU_NVIDIA_MINOR) == 0 && $(field GPU_CUDA_ARCH) == 89 ]] || fail "nvidia card 1: $output"
gpu FAKE_LSPCI="$nvtwo" NVIDIA_PROC="$nvp" -- --card 0000:02:00.0
[[ $rc == 2 ]] || fail "a card the driver does not list: rc=$rc $output"
has 'it does not list the GPU at 0000:02:00.0'
sed -i '4s/nvidia/vfio-pci/' "$nvtwo"
gpu FAKE_LSPCI="$nvtwo" NVIDIA_PROC="$nvp" -- --card 0000:02:00.0 --need optional
[[ $rc == 0 && $(field GPU_STATE) == absent ]] || fail "nvidia vfio card: $output"
has 'The GPU at 0000:02:00.0 is bound to vfio-pci'
[[ ! -s $log ]] || fail 'the helper ran with a driver already loaded'
rm -f "$tmp/loaded"
pass "NVIDIA --card: that card's compute capability and /dev/nvidia minor; one the driver does not list needs a reboot, a vfio-pci one is absent"

output=$(bash "$tool" --help)
has 'Usage: bash tools/setup-host-gpu.sh'
bash -n "$tool"
pass 'usage and syntax'
printf '%s host GPU setup cases passed. Nothing was installed.\n' "$passed"
