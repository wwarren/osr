#!/usr/bin/env bash
# cuda-toolkit.sh without touching the system: the --check-repo table, an
# installed toolkit, and (as root, with stubbed apt-get, curl and ldconfig) a
# fake runfile: its published checksum, the toolkit-only flags, the cleanup
# and the library path.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
toolkit=$here/cuda-toolkit.sh
passed=0
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
check() { env -i "PATH=$PATH" "CUDA_DIST=$1" "CUDA_HOME_DIR=/nonexistent" bash "$toolkit" --check-repo 2>&1; }

for dist in debian12 debian13 ubuntu2204 ubuntu2404; do
    out=$(check "$dist") || fail "$dist refused: $out"
    [[ $out == *"can be installed on $dist"* ]] || fail "$dist: $out"
done
pass 'the CUDA 10.2 runfile is accepted on Debian 12/13 and Ubuntu 22.04/24.04'
for dist in ubuntu2604 ubuntu1804 debian11; do
    if out=$(check "$dist"); then fail "$dist accepted"; fi
    [[ $out == *"not checked on $dist"* && $out == *'KINDI_BACKEND=cpu'* ]] || fail "$dist message: $out"
done
if out=$(check 'ubuntu24;x'); then fail 'a malformed CUDA_DIST accepted'; fi
for bad in 'CUDA_RUNFILE_MD5=xyz' 'CUDA_RUNFILE_SHA256=abc' 'CUDA_RUNFILE=cuda_11.0.2_450.51.05_linux.run' \
           'CUDA_RUNFILE_URL=http://developer.download.nvidia.com/x' 'CUDA_HOME_DIR=relative'; do
    if out=$(env -i "PATH=$PATH" CUDA_DIST=debian12 "$bad" bash "$toolkit" --check-repo 2>&1); then fail "accepted $bad"; fi
done
grep -qx 'CUDA_RUNFILE_MD5=${CUDA_RUNFILE_MD5:-3d816c583759efa8567a92c1a2af90db}' "$toolkit" ||
    fail 'the runfile is not pinned to NVIDIA'\''s published MD5'
pass 'other distros, malformed distros and malformed pins are refused; the runfile is pinned to NVIDIA'\''s MD5'

# A toolkit that is already installed satisfies --check and an install;
# --check-repo ignores it.
fake=$(mktemp -d "${TMPDIR:-/tmp}/kindi-cuda.XXXXXX")
tmp=''
trap 'rm -rf -- "$fake" ${tmp:+"$tmp"}' EXIT
make_toolkit() {
    mkdir -p "$1/bin" "$1/lib64"
    printf '#!/bin/sh\necho "Cuda compilation tools, release %s, V%s.89"\n' "$2" "$2" > "$1/bin/nvcc"; chmod +x "$1/bin/nvcc"
    : > "$1/lib64/libcudart.so.10.2"; : > "$1/lib64/libnvrtc.so.10.2"; : > "$1/lib64/libcublas.so.10"
}
make_toolkit "$fake/cuda-10.2" 10.2
installed() { env -i "PATH=$PATH" CUDA_DIST=ubuntu2604 "CUDA_HOME_DIR=$2" bash "$toolkit" "$1" 2>&1; }
out=$(installed --check "$fake/cuda-10.2") || fail "an installed 10.2 was refused: $out"
[[ $out == *'already present'* ]] || fail "installed toolkit message: $out"
if out=$(installed --check-repo "$fake/cuda-10.2"); then fail '--check-repo accepted ubuntu2604 because of a local toolkit'; fi
make_toolkit "$fake/cuda-11" 11.8
if out=$(installed --check "$fake/cuda-11"); then fail 'a CUDA 11.8 toolkit satisfied a 10.2 request'; fi
rm "$fake/cuda-10.2/lib64/libnvrtc.so.10.2"
if out=$(installed --check "$fake/cuda-10.2"); then fail 'a toolkit without NVRTC was accepted'; fi
pass 'an installed 10.2 toolkit with its libraries is accepted before the distro check; --check-repo ignores it'

if (( EUID != 0 )); then
    printf 'SKIP install-path cases (cuda-toolkit.sh needs root; --check cases above ran)\n'
    printf '%s CUDA toolkit cases passed. Nothing was installed.\n' "$passed"
    exit 0
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kindi-cuda-test.XXXXXX")
bin=$tmp/bin; mkdir -p "$bin"; log=$tmp/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for c in apt-get ldconfig; do stub "$c" 'exit 0'; done
# The fake runfile "installs" a toolkit (and docs) where --toolkitpath says.
cat > "$tmp/runfile" <<STUB
#!/bin/sh
echo "runfile \$*" >> "$log"
for a in "\$@"; do case \$a in --toolkitpath=*) dest=\${a#--toolkitpath=} ;; esac; done
mkdir -p "\$dest/bin" "\$dest/lib64" "\$dest/doc" "\$dest/samples"
printf '#!/bin/sh\necho "Cuda compilation tools, release 10.2, V10.2.89"\n' > "\$dest/bin/nvcc"; chmod +x "\$dest/bin/nvcc"
: > "\$dest/lib64/libcudart.so.10.2"; : > "\$dest/lib64/libnvrtc.so.10.2"; : > "\$dest/lib64/libcublas.so.10"
STUB
md5=$(md5sum "$tmp/runfile" | cut -d' ' -f1)
# curl: "downloads" the fake runfile (FAKE_RUNFILE: another file instead).
stub curl 'out=""; while (( $# )); do case $1 in -o) out=$2; shift 2;; *) shift;; esac; done; cp "${FAKE_RUNFILE:-'"$tmp/runfile"'}" "$out"'
install_toolkit() {
    env -i "PATH=$bin:$PATH" CUDA_DIST=debian13 "CUDA_HOME_DIR=$tmp/cuda-10.2" "CUDA_DOWNLOAD_DIR=$tmp/cache" \
        "LDCONF=$tmp/cuda-10-2.conf" "CUDA_RUNFILE_MD5=$md5" "$@" bash "$toolkit" 2>&1
}
out=$(install_toolkit) || fail "install: $out"
grep -q "runfile --silent --toolkit --toolkitpath=$tmp/cuda-10.2 --no-opengl-libs --no-man-page --override --tmpdir=$tmp/cache/unpack." "$log" ||
    fail "runfile flags: $(grep runfile "$log")"
grep -q -- '--driver' "$log" && fail 'the driver was installed'
[[ -x $tmp/cuda-10.2/bin/nvcc && ! -e $tmp/cuda-10.2/doc && ! -e $tmp/cuda-10.2/samples ]] || fail 'the toolkit was not cleaned up'
[[ $(< "$tmp/cuda-10-2.conf") == "$tmp/cuda-10.2/lib64" ]] || fail 'the library path'
grep -q '^ldconfig' "$log" || fail 'ldconfig did not run'
grep -q '^apt-get install -y ca-certificates curl libxml2' "$log" || fail 'libxml2 was not installed'
[[ -z $(find "$tmp/cache" -mindepth 1) ]] || fail "the runfile or its scratch space was kept: $(ls "$tmp/cache")"
[[ $out == *'CUDA toolkit ready: release 10.2'* ]] || fail "ready message: $out"
pass 'the runfile installs the toolkit only, is cleaned up, and its libraries are on the loader path'

: > "$log"
out=$(install_toolkit) || fail "rerun: $out"
grep -qE '^(curl|runfile|apt-get)' "$log" && fail "an installed toolkit was installed again: $(cat "$log")"
pass 'a rerun with the toolkit installed downloads nothing'

rm -rf "$tmp/cuda-10.2"; : > "$log"
printf 'not the runfile\n' > "$tmp/other"
if out=$(install_toolkit FAKE_RUNFILE="$tmp/other"); then fail 'a runfile with the wrong MD5 was run'; fi
[[ $out == *"not NVIDIA's $md5"* && $out == *'it was removed'* ]] || fail "MD5 message: $out"
grep -q '^runfile' "$log" && fail 'the wrong runfile was run'
[[ ! -e $tmp/cache/cuda_10.2.89_440.33.01_linux.run ]] || fail 'the wrong runfile was kept'
if out=$(install_toolkit CUDA_RUNFILE_SHA256="$(printf 'a%.0s' {1..64})"); then fail 'a runfile with the wrong SHA-256 was run'; fi
[[ $out == *'not aaaa'* ]] || fail "SHA-256 message: $out"
pass 'a download that does not match the published MD5 (or a pinned SHA-256) is removed, never run'

printf '%s CUDA toolkit cases passed. Nothing was installed.\n' "$passed"
