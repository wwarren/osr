#!/usr/bin/env bash
# Exercise CUDA compiler discovery without installing CUDA or touching system paths.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
source <(awk '
    /^# CUDA compiler discovery helpers / { capture=1; next }
    /^# End CUDA compiler discovery helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")

for helper in cuda_compiler_candidates cuda_compiler_missing resolve_cuda_compiler \
    install_cuda_toolkit_13_0 ensure_cuda_compiler; do
    declare -F "$helper" >/dev/null || die "Installer helper extraction failed: $helper"
done

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/llama-target-cuda-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/llama-target-cuda-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT

fake_bin=$tmp_root/bin
fake_nvcc=$fake_bin/nvcc
mkdir -p -- "$fake_bin"
printf '#!/usr/bin/env bash\nprintf "mock nvcc 13.0\\n"\n' > "$fake_nvcc"
chmod 0755 "$fake_nvcc"
original_path=$PATH
passed=0

check() {
    local label=$1 expected=$2 needle=$3 output status=0
    shift 3
    output=$("$@" 2>&1) || status=$?
    if [[ $expected == ok ]]; then
        (( status == 0 )) || die "$label: unexpected failure: $output"
    else
        (( status != 0 )) || die "$label: expected failure but command succeeded"
    fi
    [[ $output == *"$needle"* ]] || die "$label: expected '$needle' in: $output"
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
}

explicit_compiler() {
    CUDA_COMPILER=$fake_nvcc
    PATH=$original_path
    resolve_cuda_compiler
    printf 'COMPILER|%s\n' "$CUDA_COMPILER"
}

path_compiler() {
    CUDA_COMPILER=''
    PATH="$fake_bin:$original_path"
    resolve_cuda_compiler
    printf 'COMPILER|%s\n' "$CUDA_COMPILER"
}

invalid_explicit_falls_back() {
    CUDA_COMPILER=/usr/local/cuda-13.0/bin/missing-nvcc
    PATH="$fake_bin:$original_path"
    resolve_cuda_compiler
    printf 'COMPILER|%s\n' "$CUDA_COMPILER"
}

missing_compiler() {
    CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc
    cuda_compiler_missing "$CUDA_COMPILER"
}

automatic_install_then_detect() {
    local attempts=0
    CUDA_COMPILER=''
    resolve_cuda_compiler() {
        attempts=$((attempts + 1))
        if (( attempts == 1 )); then return 1; fi
        CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc
    }
    install_cuda_toolkit_13_0() { printf 'INSTALL|cuda-toolkit-13-0\n'; }
    ensure_cuda_compiler
    printf 'COMPILER|%s\n' "$CUDA_COMPILER"
}

toolkit_segment_present() {
    local body
    body=$(declare -f install_cuda_toolkit_13_0)
    for fragment in \
        'apt-get update' \
        'apt-get install -y ca-certificates wget' \
        'cuda-keyring_1.1-1_all.deb' \
        'dpkg -i /tmp/cuda-keyring.deb' \
        'apt-get install --no-install-recommends -y cuda-toolkit-13-0' \
        '/usr/local/cuda-13.0/bin/nvcc --version'; do
        [[ $body == *"$fragment"* ]] || die "CUDA toolkit installer is missing: $fragment"
    done
    printf 'SEGMENT|complete\n'
}

check 'valid explicit CUDA compiler is retained' ok "COMPILER|$(realpath -e -- "$fake_nvcc")" explicit_compiler
check 'unset CUDA compiler is discovered on PATH' ok "COMPILER|$(realpath -e -- "$fake_nvcc")" path_compiler
check 'invalid configured path falls back to discovered nvcc' ok 'using detected compiler' invalid_explicit_falls_back
check 'missing CUDA toolkit reports the install package' fail 'cuda-toolkit-13-0' missing_compiler
check 'missing compiler triggers toolkit installation then detection' ok 'COMPILER|/usr/local/cuda-13.0/bin/nvcc' automatic_install_then_detect
check 'CUDA toolkit installation segment is complete' ok 'SEGMENT|complete' toolkit_segment_present

printf '%s CUDA compiler discovery cases passed. No toolkit or system files were changed.\n' "$passed"
