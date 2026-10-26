#!/usr/bin/env bash
# cuda-toolkit.sh without touching the system: the --check table of what each
# NVIDIA repository carries, and (as root, with stubbed apt/curl/dpkg) the
# keyring URL and the "package not in this repository" message.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
toolkit=$here/cuda-toolkit.sh
passed=0
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
check() { env -i "PATH=$PATH" "CUDA_DIST=$1" "CUDA_VERSION=$2" "CUDA_HOME_DIR=/nonexistent" bash "$toolkit" --check-repo 2>&1; }

for case in ubuntu2404:12.8 ubuntu2404:12.9 ubuntu2204:12.8 debian12:12.8 debian12:13.0 \
            debian13:13.1 debian13:13.4 ubuntu2404:13.0 ubuntu2604:13.3 ubuntu2604:13.4; do
    out=$(check "${case%%:*}" "${case#*:}") || fail "$case refused: $out"
    [[ $out == *"is available for ${case%%:*}"* ]] || fail "$case: $out"
done
pass 'CUDA 12.8+ is accepted where NVIDIA publishes it (Ubuntu 22.04/24.04, Debian 12; Debian 13 from 13.1)'

for case in debian13:12.8 debian13:12.9 debian13:13.0; do
    if out=$(check "${case%%:*}" "${case#*:}"); then fail "$case accepted"; fi
    [[ $out == *"debian13 repository starts at CUDA 13.1"* ]] || fail "$case message: $out"
    [[ $out == *'XOLOTL_CUDA_VERSION=13.1 or later'* && $out == *'Ubuntu 24.04'* ]] || fail "$case advice: $out"
done
pass 'Debian 13 with CUDA 12.x or 13.0 is refused, with the setting to change and the alternatives'

out=$(check ubuntu2604 13.0) && fail 'ubuntu2604 with CUDA 13.0 accepted'
[[ $out == *'ubuntu2604 repository starts at CUDA 13.3'* && $out == *'XOLOTL_CUDA_VERSION=13.3'* ]] || fail "ubuntu2604 message: $out"
pass 'Ubuntu 26.04 requires CUDA 13.3 or later'

out=$(check debian14 12.8) || fail "an unknown distro was refused by the table: $out"
[[ $out == *'not a distro this script has checked'* ]] || fail "unknown distro note: $out"
if out=$(check ubuntu2404 12.4); then fail 'CUDA below 12.8 accepted'; fi
[[ $out == *'Xolotl needs CUDA 12.8 or newer'* ]] || fail "minimum message: $out"
if out=$(check 'ubuntu24;x' 12.8); then fail 'a malformed CUDA_DIST accepted'; fi
out=$(env -i "PATH=$PATH" CUDA_DIST=ubuntu2404 CUDA_HOME_DIR=/nonexistent bash "$toolkit" --check-repo 2>&1) ||
    fail "the default version was refused: $out"
[[ $out == *'CUDA 13.0 is available for ubuntu2404'* ]] || fail "default version: $out"
pass 'unknown distros defer to apt; versions below 12.8 and malformed distros are refused; the default is 13.0'

# A toolkit that is already installed (a runfile, say) satisfies --check and an
# install even where the repository could not provide it; --check-repo ignores it.
fake=$(mktemp -d "${TMPDIR:-/tmp}/xolotl-nvcc.XXXXXX")
trap 'rm -rf -- "$fake" ${tmp:+"$tmp"}' EXIT
mkdir -p "$fake/bin"
printf '#!/bin/sh\necho "Cuda compilation tools, release 12.8, V12.8.93"\n' > "$fake/bin/nvcc"; chmod +x "$fake/bin/nvcc"
installed() { env -i "PATH=$PATH" CUDA_DIST=debian13 "CUDA_VERSION=$2" "CUDA_NVCC=$fake/bin/nvcc" bash "$toolkit" "$1" 2>&1; }
out=$(installed --check 12.8) || fail "an installed 12.8 on debian13 was refused: $out"
[[ $out == *'already present'* ]] || fail "installed toolkit message: $out"
if out=$(installed --check-repo 12.8); then fail '--check-repo accepted debian13 12.8 because of a local toolkit'; fi
if out=$(installed --check 12.9); then fail 'an installed 12.8 satisfied a 12.9 request'; fi
[[ $out == *'debian13 repository starts at CUDA 13.1'* ]] || fail "wrong-release message: $out"
pass 'an installed toolkit of the requested release is accepted before the repository check; --check-repo ignores it'

if (( EUID != 0 )); then
    printf 'SKIP install-path cases (cuda-toolkit.sh needs root; --check cases above ran)\n'
    printf '%s CUDA toolkit cases passed. Nothing was installed.\n' "$passed"
    exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xolotl-cuda-test.XXXXXX")
trap 'rm -rf -- "$tmp" "$fake"' EXIT
bin=$tmp/bin; mkdir -p "$bin"; log=$tmp/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for c in apt-get dpkg ldconfig curl; do stub "$c" 'exit 0'; done
# The repository offers 13.1 and 13.4 only: cuda-toolkit-12-8 is absent.
stub apt-cache 'case $1 in show) exit 100;; pkgnames) printf "cuda-toolkit-13-4\ncuda-toolkit-13-1\ncuda-toolkit-config-common\n";; esac'
if out=$(env -i "PATH=$bin:$PATH" "CUDA_HOME_DIR=$tmp/missing-toolkit" CUDA_DIST=debian99 CUDA_VERSION=12.8 bash "$toolkit" 2>&1); then
    fail 'a package missing from the repository was reported as installed'
fi
grep -q 'curl -fsSL -o /usr/local/src/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/debian99/x86_64/cuda-keyring_1.1-1_all.deb' "$log" ||
    fail "keyring URL: $(grep curl "$log")"
[[ $out == *'has no cuda-toolkit-12-8. It offers CUDA: 13.1 13.4.'* ]] || fail "missing-package message: $out"
grep -q '^apt-get install' "$log" && fail 'apt-get install ran for a missing package'
pass 'the keyring comes from the x86_64 path, and a package the repository lacks is named with what it offers'

# Install mode with that toolkit present: nothing is fetched or installed.
: > "$log"
out=$(env -i "PATH=$bin:$PATH" CUDA_DIST=debian13 CUDA_VERSION=12.8 "CUDA_NVCC=$fake/bin/nvcc" \
      "CUDA_HOME_DIR=$tmp/cuda-12.8" bash "$toolkit" 2>&1) || fail "install with a present toolkit failed: $out"
grep -qE '^(apt-get|curl|dpkg)' "$log" && fail "a present toolkit was reinstalled: $(cat "$log")"
pass 'install mode keeps a present toolkit on a distro whose repository lacks it'

printf '%s CUDA toolkit cases passed. Nothing was installed.\n' "$passed"
