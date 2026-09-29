#!/usr/bin/env bash
# Exercise install-target.sh against a temporary tree that looks like a fresh
# community-script CT: helpers in isolation, adoption (and re-running it), and
# --upgrade with checksum verification and rollback. curl, zstd, systemctl and
# the account tools are stubs; nothing is downloaded, installed or started.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/ollama-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/ollama-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in valid_version valid_models release_archive listed_sha256 fetch_release unpack_release env_value \
    ensure_env_key api_base served_version wait_for_version adopt_models set_aside restore_aside; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done

valid_version v0.34.4 && ! valid_version 0.34.4 && ! valid_version latest || die 'valid_version'
valid_models '' && valid_models 'qwen3:8b  hf.co/org/repo:Q4_K_M' || die 'good model list rejected'
! valid_models 'qwen3;reboot' && ! valid_models '$(id)' || die 'bad model list accepted'
pass 'input validation'

sums=$tmp_root/sums
printf '%s  ./ollama-linux-amd64.tar.zst\n%s *ollama-linux-arm64.tar.zst\n' "$(printf 'a%.0s' {1..64})" "$(printf 'B%.0s' {1..64})" > "$sums"
[[ $(listed_sha256 "$sums" ollama-linux-amd64.tar.zst) == "$(printf 'a%.0s' {1..64})" ]] || die 'listed_sha256 ./ prefix'
[[ $(listed_sha256 "$sums" ollama-linux-arm64.tar.zst) == "$(printf 'b%.0s' {1..64})" ]] || die 'listed_sha256 * prefix / case'
[[ -z $(listed_sha256 "$sums" ollama-linux-amd64-rocm.tar.zst) ]] || die 'listed_sha256 matched a different archive'
pass 'sha256sum.txt parsing'

TARGET_ENV=$tmp_root/env
printf 'OLLAMA_HOST=0.0.0.0:12345\n' > "$TARGET_ENV"
[[ $(api_base) == http://127.0.0.1:12345 ]] || die "api_base: $(api_base)"
printf 'OLLAMA_HOST=0.0.0.0\n' > "$TARGET_ENV"
[[ $(api_base) == http://127.0.0.1:11434 ]] || die 'api_base default port'
ensure_env_key "$TARGET_ENV" OLLAMA_HOST x; ensure_env_key "$TARGET_ENV" OLLAMA_MODELS /m
[[ $(env_value "$TARGET_ENV" OLLAMA_HOST) == 0.0.0.0 && $(env_value "$TARGET_ENV" OLLAMA_MODELS) == /m ]] || die 'ensure_env_key'
pass 'env file helpers'

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
releases=$tmp_root/releases
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for command_name in getent groupadd useradd usermod sleep; do stub "$command_name" 'exit 0'; done
stub systemctl 'case "$1" in is-active) exit "${FAKE_ACTIVE_RC:-0}";; esac; exit 0'
stub zstd 'shift; cat -- "${@: -1}"'   # zstd -dc -- FILE: the test archives are plain tar
# Downloads come from $releases/<version>/<file>; /api/version reports FAKE_SERVED.
stub curl 'out=""; url="${@: -1}"; while (( $# )); do [[ $1 == -o ]] && out=$2; shift; done
if [[ -n $out ]]; then cp -- "'"$releases"'/${url#*/download/}" "$out"; exit; fi
[[ -n ${FAKE_SERVED:-} ]] && printf "{\"version\":\"%s\"}" "$FAKE_SERVED"'

# make_release VERSION [BROKEN]: an archive with bin/ollama plus its sha256sum.txt.
make_release() {
    local version=$1 dir=$releases/$1 stage=$tmp_root/stage
    rm -rf "$stage" "$dir"; mkdir -p "$stage/bin" "$stage/lib/ollama" "$dir"
    if [[ ${2:-} == broken ]]; then printf '#!/bin/sh\nexit 1\n' > "$stage/bin/ollama"
    else printf '#!/bin/sh\necho "ollama version is %s"\n' "${version#v}" > "$stage/bin/ollama"; fi
    chmod +x "$stage/bin/ollama"; echo "$version" > "$stage/lib/ollama/marker"
    tar -cf "$dir/ollama-linux-amd64.tar.zst" -C "$stage" bin lib
    (cd "$dir" && sha256sum ollama-linux-amd64.tar.zst | sed 's/  /  .\//' > sha256sum.txt)
}
# community_ct: what ct/ollama.sh leaves behind (service as root, models in /root/.ollama).
community_ct() {
    rm -rf "${tmp_root:?}/usr" "${tmp_root:?}/etc" "${tmp_root:?}/state" "${tmp_root:?}/units" "${tmp_root:?}/rootmodels"
    mkdir -p "$tmp_root/usr/lib/ollama/bin" "$tmp_root/usr/bin" "$tmp_root/units" "$tmp_root/run" "$tmp_root/rootmodels/blobs"
    printf '#!/bin/sh\necho "ollama version is 0.30.0"\n' > "$tmp_root/usr/lib/ollama/bin/ollama"
    chmod +x "$tmp_root/usr/lib/ollama/bin/ollama"
    ln -s "$tmp_root/usr/lib/ollama/bin/ollama" "$tmp_root/usr/bin/ollama"
    printf '[Service]\nExecStart=/usr/local/bin/ollama serve\nEnvironment=OLLAMA_HOST=0.0.0.0\n' > "$tmp_root/units/ollama.service"
    echo 'weights' > "$tmp_root/rootmodels/blobs/sha256-1"
    : > "$log"
}
target() {
    env -i "PATH=$bin:/usr/bin:/bin" TARGET_ETC="$tmp_root/etc" TARGET_STATE="$tmp_root/state" \
        TARGET_UNITS="$tmp_root/units" TARGET_USER=root OLLAMA_LIB="$tmp_root/usr/lib/ollama" \
        OLLAMA_LINK="$tmp_root/usr/bin/ollama" LEGACY_MODEL_DIRS="$tmp_root/rootmodels $tmp_root/none" \
        RELEASE_BASE=https://github.test/ollama/releases/download SYSTEMD_RUN_DIR="$tmp_root/run" \
        FAKE_SERVED="${FAKE_SERVED-0.30.0}" FAKE_ACTIVE_RC="${FAKE_ACTIVE_RC:-0}" UPGRADE_HEALTH_TIMEOUT=6 \
        "$@" bash "$script_dir/install-target.sh" ${ARGS:-}
}
dropin=$tmp_root/units/ollama.service.d/10-ollama-target.conf

community_ct
out=$(target OLLAMA_PULL_MODELS='qwen3:8b' 2>&1) || die "adoption failed: $out"
cmp -s "$script_dir/ollama-target.conf" "$dropin" || die 'drop-in not installed'
[[ $(cat "$tmp_root/units/ollama.service") == *'ExecStart=/usr/local/bin/ollama serve'* ]] || die 'community unit was edited'
cmp -s "$script_dir/ollama.env.example" "$tmp_root/etc/ollama.env" || die 'env file not installed'
[[ $(stat -c %a "$tmp_root/etc/ollama.env") == 640 ]] || die 'env file must be 0640'
[[ $(cat "$tmp_root/state/models/blobs/sha256-1") == weights && ! -e $tmp_root/rootmodels ]] || die 'models not moved'
grep -q 'systemctl restart ollama.service' "$log" || die 'service not restarted'
[[ $out == *'Pulling qwen3:8b'* ]] || die 'model not pulled'
pass 'adoption: drop-in, env file, models moved from /root, unit untouched, models pulled'

mkdir -p "$tmp_root/rootmodels/blobs"; echo 'other' > "$tmp_root/rootmodels/blobs/sha256-2"
echo 'OLLAMA_KEEP_ALIVE=2h' >> "$tmp_root/etc/ollama.env"
out=$(target 2>&1) || die "re-running adoption failed: $out"
[[ $(env_value "$tmp_root/etc/ollama.env" OLLAMA_KEEP_ALIVE) == 2h ]] || die 'settings rewritten on re-run'
[[ -e $tmp_root/rootmodels/blobs/sha256-2 && ! -e $tmp_root/state/models/blobs/sha256-2 ]] || die 're-run mixed model stores'
pass 'adoption is safe to re-run: settings kept, stores never mixed'

community_ct
out=$(FAKE_SERVED='' target 2>&1) && die 'adoption reported success with the server down'
[[ $out == *'did not answer'* ]] || die "unclear failure: $out"
pass 'adoption fails loudly when the server does not come back'

rm -rf "${tmp_root:?}/usr"
out=$(target 2>&1) && die 'adoption without a community install succeeded'
[[ $out == *'provision-lxc.sh'* ]] || die 'missing-install refusal unclear'
pass 'refuses a CT without the community-script install'

# --upgrade
adopted() { community_ct; target >/dev/null 2>&1 || die 'setup adoption failed'; : > "$log"; }
upgrade() { ARGS=--upgrade target OLLAMA_VERSION=v0.35.0 "$@"; }

adopted; make_release v0.35.0
out=$(FAKE_SERVED=0.35.0 upgrade 2>&1) || die "healthy upgrade failed: $out"
[[ $("$tmp_root/usr/bin/ollama") == 'ollama version is 0.35.0' ]] || die 'new release not linked'
[[ $("$tmp_root/usr/lib/ollama.prev/bin/ollama") == 'ollama version is 0.30.0' ]] || die 'old release not kept'
[[ -f $tmp_root/usr/lib/ollama/lib/ollama/marker ]] || die 'runner libraries not installed'
cmp -s "$script_dir/ollama-target.conf" "$dropin" || die 'drop-in lost'
pass 'healthy upgrade: verified release in place, old one kept, drop-in untouched'

adopted; make_release v0.35.0
out=$(FAKE_SERVED=0.30.0 upgrade 2>&1) && die 'upgrade reported success while the old version answered'
[[ $("$tmp_root/usr/bin/ollama") == 'ollama version is 0.30.0' && ! -e $tmp_root/usr/lib/ollama.prev ]] || die 'not rolled back'
grep -q 'systemctl start ollama.service' "$log" || die 'service not restarted after rollback'
pass 'unhealthy upgrade: the previous release is restored and restarted'

adopted; make_release v0.35.0
echo tampered >> "$releases/v0.35.0/ollama-linux-amd64.tar.zst"
out=$(upgrade 2>&1) && die 'a tampered archive was installed'
[[ $out == *'Checksum mismatch'* && $("$tmp_root/usr/bin/ollama") == *0.30.0 ]] || die "tampered archive: $out"
make_release v0.35.0
out=$(upgrade OLLAMA_SHA256="$(printf '0%.0s' {1..64})" 2>&1) && die 'an OLLAMA_SHA256 mismatch was installed'
[[ $out == *'OLLAMA_SHA256'* ]] || die 'pin mismatch unclear'
! grep -q 'systemctl stop' "$log" || die 'service stopped before the download was verified'
pass 'checksums: the release list and an optional pin are enforced before anything stops'

adopted; make_release v0.35.0 broken
out=$(upgrade 2>&1) && die 'a release that does not run was installed'
[[ $("$tmp_root/usr/bin/ollama") == *0.30.0 ]] || die 'broken release replaced the working one'
pass 'a release whose binary does not run is refused'

adopted; make_release v0.35.0
FAKE_ACTIVE_RC=3 upgrade >/dev/null 2>&1 || die 'upgrade of a stopped service failed'
! grep -q 'systemctl start' "$log" || die 'a stopped service was started'
pass 'a stopped service stays stopped'

community_ct
out=$(upgrade 2>&1) && die 'upgrade before adoption succeeded'
[[ $out == *'not been adopted'* ]] || die 'pre-adoption refusal unclear'
pass 'upgrade refuses a target that has not been adopted'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
