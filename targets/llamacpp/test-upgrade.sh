#!/usr/bin/env bash
# Exercise install-target.sh --upgrade end to end against a temporary target
# tree. git, cmake, systemctl, curl, python3 and friends are stubs; nothing is
# built, installed system-wide, downloaded or restarted.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/llama-target-upgrade-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/llama-target-upgrade-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Build and upgrade helpers/ { capture=1; next }
    /^# End build and upgrade helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in valid_extra_args build_info fetch_llama_source build_llama_server install_bridge \
    write_build_info set_aside copy_aside restore_aside ensure_env_key target_healthy upgrade_unchanged \
    valid_cpu_target cpu_build cpu_cmake_args installed_cpu_build valid_cuda_architectures \
    detected_cuda_architectures resolve_cuda_architectures cuda_build_covers installed_cuda_architectures; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done

valid_extra_args '--flash-attn on --cache-type-k q8_0' || die 'flags rejected'
valid_extra_args '' || die 'empty flags rejected'
! valid_extra_args '--x;reboot' || die 'metacharacters accepted'
! valid_extra_args '$(id)' || die 'substitution accepted'
pass 'LLAMA_EXTRA_ARGS validation'

TARGET_ROOT=$tmp_root/h; mkdir -p "$TARGET_ROOT"
printf 'requested_ref=v1\nresolved_commit=abc\nbackend=cpu\n' > "$TARGET_ROOT/build-info.txt"
[[ $(build_info backend) == cpu && $(build_info resolved_commit) == abc && -z $(build_info nope) ]] || die 'build_info'
pass 'build_info reads keys'

# CPU_TARGET: auto is native only when the CPU has every CPU_ISA_FLAGS entry.
uname() { if [[ ${1:-} == -m ]]; then echo "${FAKE_MACHINE:-x86_64}"; else command uname "$@"; fi; }
ivy=$tmp_root/cpuinfo-ivy; haswell=$tmp_root/cpuinfo-haswell
printf 'processor\t: 0\nflags\t\t: fpu sse sse2 ssse3 sse4_1 sse4_2 popcnt avx f16c rdrand\n' > "$ivy"
printf 'flags\t\t: fpu sse4_2 avx f16c fma avx2 bmi1 bmi2\n' > "$haswell"
[[ $(CPUINFO_FILE=$ivy cpu_build auto) == portable:avx,f16c ]] || die "ivy auto: $(CPUINFO_FILE=$ivy cpu_build auto)"
[[ $(CPUINFO_FILE=$haswell cpu_build auto) == native ]] || die 'haswell auto'
[[ $(CPUINFO_FILE=$ivy cpu_build native) == native ]] || die 'explicit native'
[[ $(CPUINFO_FILE=$haswell cpu_build portable) == portable:avx,f16c,fma,avx2,bmi2 ]] || die 'haswell portable'
[[ $(FAKE_MACHINE=aarch64 cpu_build auto) == native ]] || die 'non-x86 auto'
! FAKE_MACHINE=aarch64 cpu_build portable 2>/dev/null || die 'portable accepted off x86'
! cpu_build fast 2>/dev/null || die 'an unknown CPU_TARGET was accepted'
! CPUINFO_FILE=$tmp_root/missing cpu_build auto 2>/dev/null || die 'an unreadable cpuinfo was accepted'
args=$(cpu_cmake_args portable:avx,f16c | tr '\n' ' ')
[[ $args == '-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_F16C=ON -DGGML_FMA=OFF -DGGML_AVX2=OFF -DGGML_BMI2=OFF -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF ' ]] ||
    die "portable cmake args: $args"
[[ $(cpu_cmake_args native) == -DGGML_NATIVE=ON ]] || die 'native must switch GGML_NATIVE back on'
[[ $(installed_cpu_build) == native ]] || die 'an install without cpu_build is not native'
unset -f uname
pass 'CPU_TARGET: auto picks portable on an AVX-only CPU, native otherwise'

# CUDA_ARCHITECTURES=auto: the GPUs nvidia-smi sees, as a CMake list.
nvidia-smi() { printf '%s\n' ${FAKE_CAPS-8.9}; }
[[ $(FAKE_CAPS='8.9 8.6 8.9' detected_cuda_architectures) == '86;89' ]] || die 'detected architectures'
[[ $(resolve_cuda_architectures auto) == 89 && $(resolve_cuda_architectures '86;120') == '86;120' ]] || die 'resolve'
! FAKE_CAPS='' resolve_cuda_architectures auto 2>/dev/null || die 'auto without a GPU was accepted'
unset -f nvidia-smi
valid_cuda_architectures auto && valid_cuda_architectures native && valid_cuda_architectures '86;89-real' || die 'valid list rejected'
! valid_cuda_architectures '89;' && ! valid_cuda_architectures sm_89 || die 'invalid list accepted'
mkdir -p "$tmp_root/tk"
printf '#!/bin/sh\ncase $1 in --list-elf) for a in $FAKE_ELF; do echo "ELF file 1: x.1.$a.cubin"; done;; --list-ptx) for a in $FAKE_PTX; do echo "PTX file 1: x.1.$a.ptx"; done;; esac\n' > "$tmp_root/tk/cuobjdump"
chmod +x "$tmp_root/tk/cuobjdump"
covers() { FAKE_ELF=$1 FAKE_PTX=$2 CUDA_COMPILER=$tmp_root/tk/nvcc cuda_build_covers bin "$3"; }
covers sm_89 '' 89 >/dev/null || die 'sm_89 does not cover 8.9'
covers sm_86 '' 89 >/dev/null || die 'sm_86 code does not run on 8.9'
! covers sm_90 '' 89 >/dev/null || die 'sm_90 code accepted for 8.9'
! covers sm_75 '' 89 >/dev/null || die 'sm_75 code accepted for 8.9'
covers '' sm_80 89 >/dev/null || die 'PTX for 8.0 does not cover 8.9'
[[ $(covers sm_89 '' '89;120') == sm_120 ]] || die 'a second GPU without code was not reported'
CUDA_COMPILER=$tmp_root/none/nvcc cuda_build_covers bin 89 || die 'missing cuobjdump must not fail the build'
[[ $(installed_cuda_architectures) == native ]] || die 'an install without cuda_architectures is not native'
pass 'CUDA_ARCHITECTURES: auto reads nvidia-smi; a build is checked for code each GPU can run'

echo old > "$TARGET_ROOT/f"; echo older > "$TARGET_ROOT/f.prev"
set_aside "$TARGET_ROOT/f"; echo new > "$TARGET_ROOT/f"
[[ $(cat "$TARGET_ROOT/f.prev") == old ]] || die 'set_aside did not replace an older .prev'
restore_aside "$TARGET_ROOT/f"
[[ $(cat "$TARGET_ROOT/f") == old && ! -e $TARGET_ROOT/f.prev ]] || die 'restore_aside'
set_aside "$TARGET_ROOT/missing"; restore_aside "$TARGET_ROOT/missing"
pass 'set_aside / restore_aside round trip'

echo old > "$TARGET_ROOT/g"
copy_aside "$TARGET_ROOT/g"; echo edited >> "$TARGET_ROOT/g"
[[ $(cat "$TARGET_ROOT/g.prev") == old ]] || die 'copy_aside did not keep the original'
restore_aside "$TARGET_ROOT/g"
[[ $(cat "$TARGET_ROOT/g") == old && ! -e $TARGET_ROOT/g.prev ]] || die 'copy_aside / restore_aside'
pass 'copy_aside keeps the original for editing in place'

printf 'A=1\n' > "$TARGET_ROOT/env"
ensure_env_key "$TARGET_ROOT/env" A 2; ensure_env_key "$TARGET_ROOT/env" B ''
[[ $(cat "$TARGET_ROOT/env") == $'A=1\nB=' ]] || die 'ensure_env_key'
pass 'ensure_env_key adds, never rewrites'

# --- the full --upgrade run -------------------------------------------------
# install-target.sh insists on root and installs files owned by root.
if (( EUID != 0 )); then
    printf 'SKIP end-to-end upgrade cases (need root; helpers above were tested)\n'
    printf '%s upgrade cases passed. No system files, builds or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log; : > "$log"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub systemd-detect-virt 'echo lxc'
stub getent 'exit 0'
stub sleep 'exit 0'
stub ldd 'echo "	linux-vdso.so.1"'
stub apt-get 'exit 0'
stub runuser 'shift 3; "$@"'   # runuser -u USER -- CMD...
stub uname 'if [[ ${1:-} == -m ]]; then echo x86_64; else exec /usr/bin/uname "$@"; fi'
# FAKE_SMI=bad: NVML cannot talk to the driver (user-space/host mismatch).
stub nvidia-smi 'if [[ ${FAKE_SMI:-ok} != ok ]]; then echo "Failed to initialize NVML: Driver/library version mismatch"; exit 9; fi
case "$*" in *compute_cap*) printf "%s\n" ${FAKE_CAPS:-8.9};; -L) echo "GPU 0: NVIDIA RTX 2000E Ada Generation";;
*) echo "| NVIDIA-SMI 580.173.02   Driver Version: 580.173.02   CUDA Version: ${FAKE_DRIVER_CUDA:-13.0} |";; esac'
# vulkaninfo --summary: a discrete GPU, or only Mesa's CPU renderer (FAKE_VK=cpu).
stub vulkaninfo 'if [[ ${FAKE_VK:-discrete} == cpu ]]; then printf "GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName = llvmpipe (LLVM 19.1.7, 256 bits)\n"
else printf "GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n\tdeviceName = AMD Radeon RX 7900 XTX (RADV NAVI31)\n"; fi'
stub systemctl 'case "$1" in
    show) if [[ $* == *ActiveState* ]]; then
              if [[ -n ${FAKE_ACTIVE_STATE:-} ]]; then echo "$FAKE_ACTIVE_STATE"
              elif [[ ${FAKE_ACTIVE_RC:-0} == 0 ]]; then echo active; else echo inactive; fi
          else echo not-found; fi ;;
    is-active) [[ ${FAKE_ACTIVE_STATE:-} == failed ]] && exit 3; exit "${FAKE_ACTIVE_RC:-0}" ;;
esac; exit 0'
# FAKE_HEALTH: ok, down, or old-only (only the previous build answers).
stub curl 'case ${FAKE_HEALTH:-ok} in ok) exit 0;; old-only) "$TARGET_ROOT/bin/llama-server" | grep -q "version old";; *) exit 1;; esac'
stub git 'case "$*" in *"init -q "*) mkdir -p "${@: -1}";; *rev-parse*) echo "$FAKE_COMMIT";; esac; exit 0'
stub cmake 'if [[ $1 == --build ]]; then mkdir -p "$2/bin"; printf "#!/bin/sh\necho version $FAKE_COMMIT\n" > "$2/bin/llama-server"; chmod +x "$2/bin/llama-server"; fi; [[ ${FAKE_BUILD:-ok} == ok ]]'
# python3 -m venv DIR creates a venv whose python accepts pip / py_compile.
stub python3 'if [[ $1 == -m && $2 == venv ]]; then mkdir -p "$3/bin"; printf "#!/bin/sh\necho \"venv-python \$*\" >> %s\n[ \"\${FAKE_PIP:-ok}\" = ok ]\n" "'"$log"'" > "$3/bin/python"; chmod +x "$3/bin/python"; fi'

make_install() {
    rm -rf "${tmp_root:?}/opt" "${tmp_root:?}/etc" "${tmp_root:?}/units"
    mkdir -p "$tmp_root/opt/bin" "$tmp_root/opt/src" "$tmp_root/opt/venv/bin" "$tmp_root/etc" "$tmp_root/units" "$tmp_root/run"
    printf '#!/bin/sh\necho version old\n' > "$tmp_root/opt/bin/llama-server"; chmod +x "$tmp_root/opt/bin/llama-server"
    echo 'old bridge' > "$tmp_root/opt/bridge.py"; echo 'old venv' > "$tmp_root/opt/venv/marker"
    printf 'requested_ref=v0.4.0\nresolved_commit=%s\nbackend=cpu\n' "${1:-oldcommit}" > "$tmp_root/opt/build-info.txt"
    printf 'MODEL_PATH=/m.gguf\nMODEL_ALIAS=m:latest\nCONTEXT_SIZE=8192\nPARALLEL_SLOTS=2\n' > "$tmp_root/etc/llama-server.env"
    printf 'MODEL_ALIAS=m:latest\n' > "$tmp_root/etc/bridge.env"
    echo 'old unit' > "$tmp_root/units/llama-server.service"
    printf 'ID=debian\nVERSION_ID=12\n' > "$tmp_root/os-release"
    printf 'flags\t\t: fpu sse4_2 avx f16c fma avx2 bmi1 bmi2\n' > "$tmp_root/cpuinfo"
    echo 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.173.02  Release Build' > "$tmp_root/nvidia-version"
    : > "$log"
}
upgrade() {
    env -i "PATH=$bin:/usr/bin:/bin" TARGET_ROOT="$tmp_root/opt" TARGET_ETC="$tmp_root/etc" \
        TARGET_UNITS="$tmp_root/units" SYSTEMD_RUN_DIR="$tmp_root/run" OS_RELEASE_FILE="$tmp_root/os-release" \
        LLAMA_CPP_REF=v0.5.0 FAKE_COMMIT="${FAKE_COMMIT:-newcommit}" FAKE_HEALTH="${FAKE_HEALTH:-ok}" \
        FAKE_BUILD="${FAKE_BUILD:-ok}" FAKE_PIP="${FAKE_PIP:-ok}" FAKE_ACTIVE_RC="${FAKE_ACTIVE_RC:-0}" \
        BACKEND="${BACKEND:-}" FAKE_ACTIVE_STATE="${FAKE_ACTIVE_STATE:-}" \
        FORCE_REBUILD="${FORCE_REBUILD:-false}" UPGRADE_HEALTH_TIMEOUT=10 \
        GPU_LAYERS="${GPU_LAYERS:-}" CUDA_COMPILER="${CUDA_COMPILER:-}" \
        DRI_DIR="$tmp_root/dri" FAKE_VK="${FAKE_VK:-discrete}" \
        CPUINFO_FILE="$tmp_root/cpuinfo" CPU_TARGET="${CPU_TARGET:-}" \
        CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-}" FAKE_CAPS="${FAKE_CAPS:-8.9}" FAKE_SMI="${FAKE_SMI:-ok}" \
        FAKE_DRIVER_CUDA="${FAKE_DRIVER_CUDA:-13.0}" FAKE_ELF="${FAKE_ELF:-sm_89}" FAKE_PTX='' \
        NVIDIA_VERSION_FILE="${NVIDIA_VERSION_FILE:-$tmp_root/nvidia-version}" \
        bash "$script_dir/install-target.sh" "${MODE_FLAG:---upgrade}"
}

make_install
out=$(upgrade 2>&1) || die "healthy upgrade failed: $out"
[[ $("$tmp_root/opt/bin/llama-server") == 'version newcommit' ]] || die 'new binary not installed'
[[ $(cat "$tmp_root/opt/bin/llama-server.prev") == *'version old'* ]] || die 'old binary not kept as .prev'
grep -q '^resolved_commit=newcommit$' "$tmp_root/opt/build-info.txt" || die 'build-info not updated'
grep -q '^backend=cpu$' "$tmp_root/opt/build-info.txt" || die 'backend not carried over'
grep -q '^cpu_build=native$' "$tmp_root/opt/build-info.txt" || die 'native CPU build not recorded'
grep -q 'cmake .*-DGGML_NATIVE=OFF' "$log" && die 'an AVX2 CPU got a portable build'
grep -q '^LLAMA_EXTRA_ARGS=$' "$tmp_root/etc/llama-server.env" || die 'LLAMA_EXTRA_ARGS not added'
grep -q '^CONTEXT_SIZE=8192$' "$tmp_root/etc/bridge.env" || die 'bridge context fallback not added'
grep -q '^PARALLEL_SLOTS=2$' "$tmp_root/etc/bridge.env" || die 'bridge slot count not added'
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" || die 'existing settings touched'
cmp -s "$script_dir/bridge.py" "$tmp_root/opt/bridge.py" || die 'bridge.py not refreshed'
cmp -s "$script_dir/llama-server.service" "$tmp_root/units/llama-server.service" || die 'unit not refreshed'
grep -q 'systemctl restart llama-server.service llama-ollama-bridge.service' "$log" || die 'services not restarted'
pass 'healthy upgrade: rebuilds, refreshes bridge and units, keeps settings, restarts'

# A second upgrade to the same ref, bridge, units and settings changes nothing.
: > "$log"
cp "$tmp_root/opt/bin/llama-server.prev" "$tmp_root/prev-before"
out=$(upgrade 2>&1) || die "unchanged upgrade failed: $out"
[[ $out == *'unchanged and the target is healthy; nothing to do'* ]] || die "unchanged upgrade did work: $out"
! grep -qE 'systemctl (stop|restart|start)|cmake|venv-python' "$log" || die "an unchanged upgrade touched the target: $(cat "$log")"
cmp -s "$tmp_root/opt/bin/llama-server.prev" "$tmp_root/prev-before" || die 'an unchanged upgrade replaced the kept .prev'
[[ ! -e $tmp_root/opt/src/llama.cpp.new ]] || die 'the fetched source was left behind'
out=$(FAKE_ACTIVE_RC=3 upgrade 2>&1) || die "unchanged upgrade of stopped services failed: $out"
[[ $out == *'nothing to do (the services stay stopped)'* ]] || die "stopped no-op: $out"
pass 'an unchanged upgrade does nothing, running or stopped, and keeps the previous .prev'

: > "$log"
out=$(FAKE_ACTIVE_STATE=failed upgrade 2>&1) || die "failed service recovery: $out"
grep -q 'systemctl restart' "$log" || die 'a failed service was mistaken for stopped'
pass 'an unchanged failed service is restarted'

: > "$log"
sed -i "s/^backend=cpu$/backend=cuda/" "$tmp_root/opt/build-info.txt"
out=$(BACKEND=cpu upgrade 2>&1) || die "backend change failed: $out"
grep -q 'cmake ' "$log" || die 'a backend change did not rebuild'
grep -q '^backend=cpu$' "$tmp_root/opt/build-info.txt" || die 'backend not recorded'
pass 'a backend change on the same commit rebuilds the executable'


: > "$log"
out=$(FAKE_HEALTH=old-only upgrade 2>&1) && die 'an unhealthy re-apply reported success'
[[ $out == *'not healthy; re-applying'* ]] || die "unhealthy unchanged target was not re-applied: $out"
grep -q 'systemctl restart' "$log" || die 'the re-apply did not restart'
: > "$log"
out=$(FORCE_REBUILD=true upgrade 2>&1) || die "forced rebuild failed: $out"
grep -q 'cmake' "$log" || die 'FORCE_REBUILD=true did not rebuild an unchanged target'
pass 'an unchanged but unhealthy target is re-applied; FORCE_REBUILD=true always rebuilds'

# An install from before CPU_TARGET (native) on an AVX-only CPU: --upgrade
# rebuilds it portable on the same commit, records it, and then stays put.
make_install newcommit
printf 'flags\t\t: fpu sse4_2 avx f16c\n' > "$tmp_root/cpuinfo"
out=$(upgrade 2>&1) || die "AVX-only upgrade failed: $out"
grep -q 'cmake .*-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_F16C=ON -DGGML_FMA=OFF -DGGML_AVX2=OFF -DGGML_BMI2=OFF' "$log" ||
    die "AVX-only build flags: $(grep cmake "$log")"
grep -q '^cpu_build=portable:avx,f16c$' "$tmp_root/opt/build-info.txt" || die 'portable CPU build not recorded'
grep -q '^cpu_target=auto$' "$tmp_root/opt/build-info.txt" || die 'CPU_TARGET not recorded'
: > "$log"
out=$(upgrade 2>&1) || die "AVX-only re-run failed: $out"
grep -q 'cmake' "$log" && die 'an unchanged portable build was rebuilt'
: > "$log"
out=$(CPU_TARGET=native upgrade 2>&1) || die "switch to native failed: $out"
grep -q 'cmake' "$log" || die 'CPU_TARGET=native did not rebuild'
grep -q 'cmake .*-DGGML_NATIVE=OFF' "$log" && die 'CPU_TARGET=native still built portable'
grep -q '^cpu_target=native$' "$tmp_root/opt/build-info.txt" || die 'CPU_TARGET=native not recorded'
: > "$log"
out=$(upgrade 2>&1) || die "kept native re-run failed: $out"
grep -q 'cmake' "$log" && die 'the recorded CPU_TARGET=native was not kept'
out=$(CPU_TARGET=fast upgrade 2>&1) && die 'an invalid CPU_TARGET was accepted'
pass 'CPU_TARGET: an AVX-only CPU is rebuilt portable once; the chosen target is recorded and kept'

# A backend switch sets GPU_LAYERS for the new backend (the upgrade otherwise
# never rewrites a setting); GPU_LAYERS overrides; a rollback restores it.
printf '#!/bin/sh\necho "Cuda compilation tools, release 13.0"\n' > "$tmp_root/nvcc"; chmod +x "$tmp_root/nvcc"
layers() { sed -n 's/^GPU_LAYERS=//p' "$tmp_root/etc/llama-server.env"; }
make_install
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "cpu->cuda upgrade failed: $out"
[[ $(layers) == auto ]] || die "cpu->cuda left GPU_LAYERS=$(layers): $out"
[[ $out == *'setting GPU_LAYERS=auto (was 0)'* ]] || die "GPU_LAYERS change not reported: $out"
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" || die 'other settings touched'
make_install
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cuda GPU_LAYERS=40 CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "cpu->cuda with GPU_LAYERS failed: $out"
[[ $(layers) == 40 ]] || die "GPU_LAYERS=40 not applied: $(layers)"
make_install
sed -i 's/^backend=cpu$/backend=cuda/' "$tmp_root/opt/build-info.txt"
echo 'GPU_LAYERS=auto' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cpu upgrade 2>&1) || die "cuda->cpu upgrade failed: $out"
[[ $(layers) == 0 && $(grep -c '^GPU_LAYERS=' "$tmp_root/etc/llama-server.env") == 1 ]] || die "cuda->cpu left GPU_LAYERS=$(layers)"
make_install
sed -i 's/^backend=cpu$/backend=cuda/' "$tmp_root/opt/build-info.txt"
: > "$log"
out=$(BACKEND=cpu GPU_LAYERS=20 upgrade 2>&1) && die 'a CPU build with GPU layers was accepted'
[[ $out == *'A CPU build requires GPU_LAYERS=0'* ]] || die "cpu GPU_LAYERS message: $out"
grep -qE 'cmake|systemctl (stop|restart)' "$log" && die 'a refused GPU_LAYERS touched the target'
make_install
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
cp "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc FAKE_HEALTH=old-only upgrade 2>&1) && die 'an unhealthy backend switch reported success'
cmp -s "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before" || die "rollback kept GPU_LAYERS=$(layers)"
pass 'a backend switch sets GPU_LAYERS for the new backend (GPU_LAYERS overrides), and rollback restores it'
make_install
printf 'GPU_LAYERS=0\n  GPU_LAYERS = 0\n\tGPU_LAYERS = "12"\n' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "spaced GPU_LAYERS upgrade failed: $out"
[[ $out == *'setting GPU_LAYERS=auto (was 12)'* ]] || die "the message did not show the effective (last) value: $out"
[[ $(layers) == auto ]] || die "spaced GPU_LAYERS was not rewritten: $(layers)"
[[ $(grep -cE '^[[:space:]]*GPU_LAYERS[[:space:]]*=' "$tmp_root/etc/llama-server.env") == 1 ]] ||
    die 'a whitespace-prefixed GPU_LAYERS duplicate survived'
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" || die 'unrelated settings changed'
pass 'a backend switch rewrites whitespace-prefixed settings and drops all duplicates'


make_install newcommit
out=$(upgrade 2>&1) || die "same-commit upgrade failed: $out"
[[ $out == *'not rebuilding'* ]] || die 'same commit was rebuilt'
! grep -q 'cmake' "$log" || die 'cmake ran for an unchanged commit'
cmp -s "$script_dir/bridge.py" "$tmp_root/opt/bridge.py" || die 'bridge.py not refreshed on a bridge-only upgrade'
pass 'unchanged llama.cpp commit: bridge-only upgrade, no rebuild'

make_install
cp "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before"
out=$(FAKE_HEALTH=old-only upgrade 2>&1) && die 'an unhealthy upgrade reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'binary not rolled back'
[[ $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'bridge.py not rolled back'
[[ -f $tmp_root/opt/venv/marker ]] || die 'venv not rolled back'
grep -q '^resolved_commit=oldcommit$' "$tmp_root/opt/build-info.txt" || die 'build-info not rolled back'
[[ $(cat "$tmp_root/units/llama-server.service") == 'old unit' ]] || die 'unit not rolled back'
cmp -s "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before" || die 'settings file not rolled back'
[[ ! -e $tmp_root/opt/bin/llama-server.prev && ! -e $tmp_root/etc/llama-server.env.prev ]] || die 'rollback left a .prev behind'
[[ $out == *'the previous installation is running again'* ]] || die "rollback outcome not reported: $out"
pass 'unhealthy upgrade: code, units and settings are rolled back, and the old build is checked healthy'

make_install
out=$(FAKE_HEALTH=down upgrade 2>&1) && die 'an unhealthy upgrade reported success'
[[ $out == *'did not become healthy either'* ]] || die "failed rollback not reported: $out"
pass 'a rollback that does not become healthy is reported as such'

make_install
FAKE_BUILD=fail upgrade >/dev/null 2>&1 && die 'a failed build reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' && $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'failed build changed the install'
pass 'failed build: installation untouched'

make_install
echo 'stale from an earlier upgrade' > "$tmp_root/opt/bin/llama-server.prev"
FAKE_COMMIT=oldcommit FAKE_PIP=fail upgrade >/dev/null 2>&1 && die 'a failed pip install reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'a stale .prev was restored over the untouched binary'
pass 'rollback restores only what this run replaced'

# A failure inside a subshell (pip in install_bridge) must not fire the ERR
# trap twice: the second pass would stop the restored services and wait again.
make_install
: > "$log"
out=$(FAKE_PIP=fail upgrade 2>&1) && die 'a failed pip install reported success'
[[ $(grep -c 'restoring the previous installation' <<< "$out") == 1 ]] || die "pip failure rolled back more than once: $out"
[[ $(grep -c '^systemctl start' "$log") == 1 ]] || die "the restored services were restarted more than once: $(grep systemctl "$log")"
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' && $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'pip failure: install not restored'
[[ $out == *'the previous installation is running again'* ]] || die "rollback outcome not reported: $out"
pass 'a failure inside a subshell rolls back exactly once'

make_install
FAKE_ACTIVE_RC=3 upgrade >/dev/null 2>&1 || die 'upgrade of stopped services failed'
! grep -q 'systemctl restart' "$log" || die 'stopped services were started'
make_install
out=$(FAKE_ACTIVE_RC=3 FAKE_PIP=fail upgrade 2>&1) && die 'a failed upgrade of stopped services reported success'
[[ $out == *'services stay stopped as they were'* ]] || die "stopped rollback not reported: $out"
! grep -q 'systemctl start' "$log" || die 'a rollback started services that were stopped'
pass 'stopped services stay stopped, on success and on rollback'

rm -rf "$tmp_root/opt/bin/llama-server"
upgrade >/dev/null 2>&1 && die 'upgrade without an installation succeeded'
pass 'upgrade refuses a target that is not installed'

# Vulkan (AMD Radeon, Intel Arc) needs Debian 13; CUDA stays on Debian 12.
mkdir -p "$tmp_root/dri"; : > "$tmp_root/dri/renderD128"
make_install
printf 'ID=debian\nVERSION_ID=13\n' > "$tmp_root/os-release"
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=vulkan upgrade 2>&1) || die "cpu->vulkan upgrade failed: $out"
grep -q 'apt-get install --no-install-recommends -y mesa-vulkan-drivers libvulkan1 libvulkan-dev glslc spirv-headers vulkan-tools' "$log" ||
    die "Vulkan packages: $(cat "$log")"
grep -q 'cmake .*-DGGML_CUDA=OFF -DGGML_VULKAN=ON' "$log" || die "Vulkan build flags: $(grep cmake "$log")"
grep -q '^backend=vulkan$' "$tmp_root/opt/build-info.txt" || die 'vulkan backend not recorded'
[[ $(layers) == auto && $out == *'RX 7900 XTX'* ]] || die "cpu->vulkan: GPU_LAYERS=$(layers) $out"
: > "$log"
out=$(upgrade 2>&1) || die "vulkan re-run failed: $out"
grep -q 'apt-get install' "$log" && die 'an unchanged Vulkan target reinstalled packages'
pass 'cpu -> vulkan on Debian 13: Mesa, Vulkan headers and glslc, a Vulkan build, GPU layers on'

make_install
printf 'ID=debian\nVERSION_ID=13\n' > "$tmp_root/os-release"
out=$(FAKE_VK=cpu BACKEND=vulkan upgrade 2>&1) && die 'Vulkan without a GPU was accepted'
[[ $out == *'Vulkan sees no discrete GPU (only: deviceName = llvmpipe'* ]] || die "no GPU: $out"
grep -q 'cmake' "$log" && die 'built without a GPU'
rm -f "$tmp_root/dri/renderD128"
out=$(BACKEND=vulkan upgrade 2>&1) && die 'Vulkan without a render node was accepted'
[[ $out == *'cannot open a GPU render node'* ]] || die "no render node: $out"
: > "$tmp_root/dri/renderD128"
make_install
out=$(BACKEND=vulkan upgrade 2>&1) && die 'Vulkan on Debian 12 was accepted'
[[ $out == *'The Vulkan build targets a Debian 13 guest'* ]] || die "debian 12 vulkan: $out"
make_install
printf 'ID=debian\nVERSION_ID=13\n' > "$tmp_root/os-release"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "cpu->cuda on Debian 13 failed: $out"
grep -q 'cmake .*-DGGML_CUDA=ON' "$log" || die "Debian 13 CUDA build flags: $(grep cmake "$log")"
grep -q '^backend=cuda$' "$tmp_root/opt/build-info.txt" || die 'cuda backend not recorded on Debian 13'
make_install
printf 'ID=debian\nVERSION_ID=11\n' > "$tmp_root/os-release"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) && die 'Debian 11 was accepted'
grep -qE 'cmake|systemctl (stop|restart)' "$log" && die 'a refused guest touched the target'
pass 'Vulkan needs a discrete GPU through a render node, and Debian 13; CUDA runs on Debian 12 or 13'


# --- --rebuild: the CT moved to a host with another CPU and GPU ------------
printf '#!/bin/sh\necho "Cuda compilation tools, release 13.0"\n' > "$tmp_root/nvcc"; chmod +x "$tmp_root/nvcc"
printf '#!/bin/sh\ncase $1 in --list-elf) for a in $FAKE_ELF; do echo "ELF file 1: x.1.$a.cubin"; done;; esac\n' > "$tmp_root/cuobjdump"
chmod +x "$tmp_root/cuobjdump"
rebuild() { MODE_FLAG=--rebuild CUDA_COMPILER=$tmp_root/nvcc upgrade; }
moved_install() {   # a CUDA build from an AVX2 host with an Ampere (8.6) GPU
    make_install oldcommit
    printf 'requested_ref=v0.5.0\nresolved_commit=oldcommit\nbackend=cuda\ncpu_target=auto\ncpu_build=native\ncuda_target=auto\ncuda_architectures=86\n' \
        > "$tmp_root/opt/build-info.txt"
    mkdir -p "$tmp_root/opt/src/llama.cpp"; : > "$tmp_root/opt/src/llama.cpp/CMakeLists.txt"
    printf 'flags\t\t: fpu sse4_2 avx f16c\n' > "$tmp_root/cpuinfo"
}

moved_install
out=$(FAKE_ACTIVE_STATE=failed rebuild 2>&1) || die "rebuild after a move failed: $out"
grep -q 'cmake .*-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_F16C=ON -DGGML_FMA=OFF -DGGML_AVX2=OFF' "$log" || die "rebuild CPU flags: $(grep cmake "$log")"
grep -q 'cmake .*-DCMAKE_CUDA_ARCHITECTURES=89' "$log" || die "rebuild CUDA flags: $(grep cmake "$log")"
grep -q 'git ' "$log" && die 'a rebuild with the source present used the network'
[[ $("$tmp_root/opt/bin/llama-server") == 'version newcommit' && $(cat "$tmp_root/opt/bin/llama-server.prev") == *'version old'* ]] ||
    die 'rebuilt binary not installed with the previous kept'
for line in resolved_commit=oldcommit requested_ref=v0.5.0 cpu_build=portable:avx,f16c cuda_target=auto cuda_architectures=89; do
    grep -qx "$line" "$tmp_root/opt/build-info.txt" || die "build-info lacks $line: $(cat "$tmp_root/opt/build-info.txt")"
done
grep -q 'systemctl start llama-server.service llama-ollama-bridge.service' "$log" || die 'a failed service was not started after the rebuild'
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" && cmp -s "$tmp_root/opt/bridge.py" <(echo 'old bridge') ||
    die 'a rebuild touched the settings or the bridge'
pass 'rebuild after a move: new CPU and GPU detected, offline, recorded, services started'

: > "$log"
out=$(rebuild 2>&1) || die "unchanged rebuild failed: $out"
[[ $out == *'already suits this host and the target is healthy; nothing to do'* ]] || die "unchanged rebuild: $out"
grep -qE 'cmake|systemctl (stop|start|restart)' "$log" && die 'an unchanged rebuild touched the target'
out=$(FAKE_ACTIVE_RC=3 rebuild 2>&1) || die "unchanged stopped rebuild failed: $out"
[[ $out == *'nothing to do (the services stay stopped)'* ]] || die "stopped unchanged rebuild: $out"
: > "$log"
out=$(FAKE_ACTIVE_STATE=failed rebuild 2>&1) || die "unchanged failed-service rebuild failed: $out"
grep -q 'cmake' "$log" && die 'a suitable build was rebuilt'
grep -q 'systemctl restart' "$log" || die 'a failed service with a suitable build was not restarted'
: > "$log"
out=$(FORCE_REBUILD=true rebuild 2>&1) || die "forced rebuild failed: $out"
grep -q 'cmake' "$log" || die 'FORCE_REBUILD=true did not rebuild'
pass 'rebuild on the same host: nothing to do, stopped stays stopped, failed is restarted, FORCE_REBUILD rebuilds'

moved_install
out=$(FAKE_BUILD=fail rebuild 2>&1) && die 'a failed rebuild reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' && ! -e $tmp_root/opt/bin/llama-server.prev ]] || die 'a failed build changed the binary'
grep -q '^cuda_architectures=86$' "$tmp_root/opt/build-info.txt" || die 'a failed build changed build-info'
grep -qE 'systemctl (stop|start)' "$log" && die 'a failed build touched the services'
[[ $out == *'the installed llama-server was not changed'* ]] || die "failed build message: $out"
moved_install
out=$(FAKE_ELF=sm_75 rebuild 2>&1) && die 'a build without code for the GPU was installed'
[[ $out == *'no GPU code'*'sm_89'* && $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die "uncovered GPU: $out"
moved_install
out=$(FAKE_HEALTH=down rebuild 2>&1) && die 'an unhealthy rebuild reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'an unhealthy rebuild was not rolled back'
grep -q '^cuda_architectures=86$' "$tmp_root/opt/build-info.txt" || die 'build-info not rolled back'
pass 'rebuild failures: a failed build or one without code for the GPU changes nothing; an unhealthy one is rolled back'

moved_install
out=$(FAKE_SMI=bad rebuild 2>&1) && die 'a CT whose NVIDIA user-space does not match the host was rebuilt'
[[ $out == *'does not match the host driver 580.173.02'*'update-gpu-drivers.sh'*'DRIVER_VERSION=580.173.02'* ]] || die "mismatch message: $out"
grep -q 'cmake' "$log" && die 'built with a broken GPU'
moved_install
out=$(FAKE_DRIVER_CUDA=12.8 rebuild 2>&1) && die 'a toolkit newer than the driver was accepted'
[[ $out == *'CUDA 13 toolkit'*'supports CUDA 12'* ]] || die "old driver: $out"
moved_install
rm -f "$tmp_root/nvidia-version"
out=$(rebuild 2>&1) && die 'a CUDA rebuild on a host without NVIDIA was accepted'
[[ $out == *'sees no NVIDIA driver'*'BACKEND=vulkan|cpu'* ]] || die "no NVIDIA: $out"
grep -q 'cmake' "$log" && die 'built without an NVIDIA driver'
pass 'rebuild checks the GPU first: user-space mismatch, an old host driver, no NVIDIA at all'

printf '%s upgrade cases passed. No system files, builds or services were touched.\n' "$passed"
