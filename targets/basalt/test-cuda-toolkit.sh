#!/usr/bin/env bash
# cuda-toolkit.sh without touching the system: the --check-repo table of what
# each NVIDIA repository carries, and (as root, with stubbed apt/curl/dpkg) the
# keyring URL and the "package not in this repository" message.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
toolkit=$here/cuda-toolkit.sh
passed=0
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
check() { env -i "PATH=$PATH" "CUDA_DIST=$1" "CUDA_VERSION=$2" bash "$toolkit" --check-repo 2>&1; }

for case in ubuntu2404:13.0 ubuntu2204:13.0 ubuntu2604:13.3 ubuntu2604:13.4 debian12:13.0 debian12:13.1 debian13:13.1 debian13:13.4; do
    out=$(check "${case%%:*}" "${case#*:}") || fail "$case refused: $out"
    [[ $out == *"is available for ${case%%:*}"* ]] || fail "$case: $out"
done
pass 'CUDA 13.x is accepted where NVIDIA publishes it (Debian 13 from 13.1)'

out=$(check debian13 13.0) && fail 'debian13 with CUDA 13.0 accepted'
[[ $out == *'debian13 repository starts at CUDA 13.1'* && $out == *'CUDA_VERSION=13.1'* ]] || fail "debian13 message: $out"
pass 'Debian 13 with the default CUDA 13.0 is refused, naming the release to use'

out=$(check ubuntu2604 13.0) && fail 'ubuntu2604 with CUDA 13.0 accepted'
[[ $out == *'ubuntu2604 repository starts at CUDA 13.3'* && $out == *'CUDA_VERSION=13.3'* ]] || fail "ubuntu2604 message: $out"
pass 'Ubuntu 26.04 requires CUDA 13.3 or later'

out=$(check debian14 13.0) || fail "an unknown distro was refused by the table: $out"
[[ $out == *'not a distro this script has checked'* ]] || fail "unknown distro note: $out"
out=$(check ubuntu2404 12.9) && fail 'CUDA below 13.0 accepted'
[[ $out == *'basalt needs CUDA 13.0 or newer'* ]] || fail "minimum message: $out"
out=$(check 'ubuntu24;x' 13.0) && fail 'a malformed CUDA_DIST accepted'
out=$(env -i "PATH=$PATH" bash "$toolkit" --bogus 2>&1) && fail 'an unknown option was accepted'
pass 'unknown distros defer to apt; versions below 13.0, malformed distros and options are refused'

if (( EUID != 0 )); then
    printf 'SKIP install-path cases (cuda-toolkit.sh needs root; --check-repo cases above ran)\n'
    printf '%s CUDA toolkit cases passed. Nothing was installed.\n' "$passed"
    exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/basalt-cuda-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
bin=$tmp/bin; mkdir -p "$bin"; log=$tmp/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for c in apt-get dpkg ldconfig curl; do stub "$c" 'exit 0'; done
# The repository offers 13.1 and 13.4 only: cuda-toolkit-13-0 is absent.
stub apt-cache 'case $1 in show) exit 100;; pkgnames) printf "cuda-toolkit-13-4\ncuda-toolkit-13-1\ncuda-toolkit-config-common\n";; esac'
# A CUDA_DIST the table does not know, so the install path reaches apt.
if out=$(env -i "PATH=$bin:/usr/bin:/bin" CUDA_DIST=debian99 CUDA_VERSION=13.0 bash "$toolkit" 2>&1); then
    fail 'a package missing from the repository was reported as installed'
fi
grep -q 'curl -fsSL -o /usr/local/src/cuda-keyring_1.1-1_all.deb https://developer.download.nvidia.com/compute/cuda/repos/debian99/x86_64/cuda-keyring_1.1-1_all.deb' "$log" ||
    fail "keyring URL: $(grep curl "$log")"
[[ $out == *'has no cuda-toolkit-13-0. It offers CUDA: 13.1 13.4.'* ]] || fail "missing-package message: $out"
grep -q '^apt-get install' "$log" && fail 'apt-get install ran for a missing package'
pass 'the keyring comes from the x86_64 path, and a package the repository lacks is named with what it offers'

printf '%s CUDA toolkit cases passed. Nothing was installed.\n' "$passed"
