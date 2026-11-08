#!/usr/bin/env bash
# rocm-toolkit.sh without touching the system: the --check table of the
# distros AMD's repository has, version validation, an installed tree, and
# (as root, with stubbed apt/curl/gpg) the key fingerprint check and the apt
# source it writes.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
toolkit=$here/rocm-toolkit.sh
passed=0
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/avalon-rocm-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
check() { env -i "PATH=$PATH" "ROCM_DIST=$1" "ROCM_VERSION=$2" "ROCM_DIR=$tmp/none" bash "$toolkit" --check-repo 2>&1; }

for case in ubuntu2404:7.2.4 ubuntu2204:7.2.4 ubuntu2404:7.2; do
    out=$(check "${case%%:*}" "${case#*:}") || fail "$case refused: $out"
    [[ $out == *"can be installed on ${case%%:*}"* ]] || fail "$case: $out"
done
[[ $(check ubuntu2404 7.2.4) == *'(noble)'* && $(check ubuntu2204 7.2.4) == *'(jammy)'* ]] || fail 'suites'
pass 'ROCm 7.x is offered on Ubuntu 24.04 (noble) and 22.04 (jammy)'

for dist in debian13 debian12 ubuntu2604; do
    if out=$(check "$dist" 7.2.4); then fail "$dist accepted"; fi
    [[ $out == *"its repository has no $dist"* && $out == *'Ubuntu 24.04 or 22.04 template'* ]] || fail "$dist message: $out"
done
pass 'Debian and Ubuntu 26.04 are refused, with the templates to use instead'

for version in 6.4.1 8.0 7 'x'; do
    if out=$(check ubuntu2404 "$version"); then fail "ROCm $version accepted"; fi
    [[ $out == *'ROCM_VERSION must be a ROCm 7.x release'* ]] || fail "version message: $out"
done
if out=$(check 'ubuntu24;x' 7.2.4); then fail 'a malformed ROCM_DIST accepted'; fi
out=$(env -i "PATH=$PATH" ROCM_DIST=ubuntu2404 "ROCM_DIR=$tmp/none" bash "$toolkit" --check-repo 2>&1) ||
    fail "the default version was refused: $out"
[[ $out == *'ROCm 7.2.4 can be installed'* ]] || fail "default version: $out"
pass 'only ROCm 7.x releases and well-formed distros are accepted; the default is 7.2.4 (upstream'\''s tested release)'

# An installed tree of that release satisfies --check and an install on any
# distro; --check-repo ignores it.
rocm=$tmp/rocm-7.2.4
mkdir -p "$rocm/.info" "$rocm/bin"
echo '7.2.4-93' > "$rocm/.info/version"
for c in amdclang++ rocminfo; do printf '#!/bin/sh\n' > "$rocm/bin/$c"; chmod +x "$rocm/bin/$c"; done
installed() { env -i "PATH=$PATH" ROCM_DIST=debian13 "ROCM_VERSION=$2" "ROCM_DIR=$rocm" bash "$toolkit" "$1" 2>&1; }
out=$(installed --check 7.2.4) || fail "an installed 7.2.4 was refused: $out"
[[ $out == *'already present'* ]] || fail "installed message: $out"
out=$(installed '' 7.2.4) || fail "install with a present tree failed: $out"
if out=$(installed --check-repo 7.2.4); then fail '--check-repo accepted debian13 because of a local tree'; fi
if out=$(installed --check 7.2.3); then fail 'an installed 7.2.4 satisfied a 7.2.3 request'; fi
pass 'an installed ROCm of the requested release is accepted before the repository check; --check-repo ignores it'

if (( EUID != 0 )); then
    printf 'SKIP install-path cases (rocm-toolkit.sh needs root; --check cases above ran)\n'
    printf '%s ROCm toolkit cases passed. Nothing was installed.\n' "$passed"
    exit 0
fi
bin=$tmp/bin; mkdir -p "$bin"; log=$tmp/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for c in apt-get ldconfig; do stub "$c" 'exit 0'; done
stub curl 'while (( $# )); do [[ $1 == -o ]] && { echo KEY > "$2"; shift; }; shift; done'
# gpg: --show-keys prints FAKE_FPR as the primary key; --dearmor writes a keyring.
stub gpg 'if [[ " $* " == *" --show-keys "* ]]; then printf "pub:-:4096:1:9386B48A1A693C5C:::::::\nfpr:::::::::%s:\nsub:-:4096:1:X:::::::\nfpr:::::::::%s:\n" "${FAKE_FPR:-CA8BB4727A47B4D09B4EE8969386B48A1A693C5C}" "${FAKE_SUB:-0123456789ABCDEF0123456789ABCDEF01234567}"; elif [[ " $* " == *" --dearmor "* ]]; then while [[ $1 != -o ]]; do shift; done; echo RING > "$2"; fi'
target=$tmp/target
run_install() {
    env -i "PATH=$bin:$PATH" "ROCM_DIR=$target/rocm-7.2.4" ROCM_DIST=ubuntu2404 \
        "ROCM_KEYRING=$tmp/etc/keyrings/rocm.gpg" "ROCM_SOURCES=$tmp/etc/rocm.list" "ROCM_PIN_FILE=$tmp/etc/rocm-pin-600" \
        "$@" bash "$toolkit" 2>&1
}
mkdir -p "$tmp/etc"
if out=$(run_install FAKE_FPR=0000000000000000000000000000000000000000); then fail 'a key with the wrong fingerprint was trusted'; fi
[[ $out == *"not AMD's CA8BB4727A47B4D09B4EE8969386B48A1A693C5C. Nothing was installed."* ]] || fail "fingerprint message: $out"
[[ ! -e $tmp/etc/rocm.list && ! -e $tmp/etc/keyrings/rocm.gpg ]] || fail 'a source or keyring was written for an unknown key'
grep -q 'apt-get install -y hip-dev' "$log" && fail 'packages were installed with an unknown key'
if out=$(run_install FAKE_FPR=0123456789ABCDEF0123456789ABCDEF01234567 FAKE_SUB=CA8BB4727A47B4D09B4EE8969386B48A1A693C5C); then
    fail 'a key carrying AMD'\''s fingerprint only on a subkey was trusted'
fi
pass 'the repository key is trusted only when its primary fingerprint is AMD'\''s'

: > "$log"
if out=$(run_install); then fail 'an install whose packages left no ROCm tree reported success'; fi
[[ $out == *"did not install ROCm 7.2.4 at $target/rocm-7.2.4"* ]] || fail "missing tree message: $out"
grep -qx "deb \[arch=amd64 signed-by=$tmp/etc/keyrings/rocm.gpg\] https://repo.radeon.com/rocm/apt/7.2.4 noble main" "$tmp/etc/rocm.list" ||
    fail "apt source: $(cat "$tmp/etc/rocm.list")"
grep -q '^Pin: release o=repo.radeon.com$' "$tmp/etc/rocm-pin-600" || fail 'pin file'
grep -q 'curl -fsSL --proto =https -o .* https://repo.radeon.com/rocm/rocm.gpg.key' "$log" || fail "key download: $(grep curl "$log")"
grep -q 'apt-get install -y hip-dev hipblas-dev rocblas-dev rocm-device-libs rocminfo' "$log" || fail "packages: $(grep 'apt-get install' "$log")"
pass 'with AMD'\''s key the release'\''s noble repository is added, pinned, and the HIP build packages are installed and checked'

printf '%s ROCm toolkit cases passed. Nothing was installed.\n' "$passed"
