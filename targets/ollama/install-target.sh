#!/usr/bin/env bash
# Run INSIDE an Ollama target CT created by the Proxmox community script
# (ct/ollama.sh, via provision-lxc.sh), never on the router CT or the PVE host.
# Adopts that install into this repository's target conventions:
#   * settings in /etc/ollama-target/ollama.env, models in /var/lib/ollama-target
#   * ollama.service runs as the unprivileged `ollama` user under a hardening
#     drop-in (ollama.service.d/10-ollama-target.conf) instead of as root
#   * --upgrade installs a pinned, checksum-verified release with rollback
set -Eeuo pipefail

# Release reviewed for this repository for --upgrade. Keep it fixed until a newer
# release has been reviewed; never resolve "latest".
readonly OLLAMA_DEFAULT_VERSION=v0.34.4

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<USAGE
Usage: bash install-target.sh              # adopt the community-script install (safe to re-run)
       bash install-target.sh --upgrade    # replace the Ollama release in place

Settings (environment; all optional):
  OLLAMA_PULL_MODELS='qwen3:8b qwen3:14b'   models to pull once the server is up
  OLLAMA_VERSION=$OLLAMA_DEFAULT_VERSION             release for --upgrade
  OLLAMA_SHA256=<hex>                       also require this archive checksum (--upgrade)
Server settings live in /etc/ollama-target/ollama.env (see ollama.env.example).

--upgrade verifies the archive against the release's sha256sum.txt, keeps models
and settings, and puts the previous release back if the server does not answer
with the new version within UPGRADE_HEALTH_TIMEOUT seconds (default 120). The
community script's own \`update\` command also works; it installs the latest
release without a pin or rollback, and the drop-in survives it.
USAGE
}

# Install helpers (paths are overridable so tests can use a temp tree).
TARGET_ETC=${TARGET_ETC:-/etc/ollama-target}
TARGET_STATE=${TARGET_STATE:-/var/lib/ollama-target}
TARGET_UNITS=${TARGET_UNITS:-/etc/systemd/system}
TARGET_USER=${TARGET_USER:-ollama}
OLLAMA_LIB=${OLLAMA_LIB:-/usr/local/lib/ollama}
OLLAMA_LINK=${OLLAMA_LINK:-/usr/local/bin/ollama}
# Where the community install keeps models: as root (HOME=/root), or as the ollama user.
LEGACY_MODEL_DIRS=${LEGACY_MODEL_DIRS:-/root/.ollama/models /usr/share/ollama/.ollama/models}
RELEASE_BASE=${RELEASE_BASE:-https://github.com/ollama/ollama/releases/download}
SERVICE=ollama.service
DROPIN=$TARGET_UNITS/$SERVICE.d/10-ollama-target.conf
TARGET_ENV=$TARGET_ETC/ollama.env

valid_version() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_models() { [[ -z $1 || $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*([[:space:]]+[A-Za-z0-9][A-Za-z0-9._:/-]*)*$ ]]; }
release_archive() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'ollama-linux-amd64.tar.zst' ;;
        aarch64|arm64) printf 'ollama-linux-arm64.tar.zst' ;;
        *) return 1 ;;
    esac
}
# The checksum listed for archive $2 in sha256sum file $1 ("<hex>  [./]<name>").
listed_sha256() {
    awk -v name="$2" '{ file = $2; sub(/^\*?(\.\/)?/, "", file) } file == name { print tolower($1); exit }' "$1"
}
# Download the release archive for $1 into directory $2 and verify it; prints the path.
fetch_release() {
    local version=$1 dir=$2 archive expected actual
    archive=$(release_archive) || die "Unsupported architecture: $(uname -m)"
    curl -fsSL --retry 3 -o "$dir/sha256sum.txt" "$RELEASE_BASE/$version/sha256sum.txt"
    curl -fsSL --retry 3 -o "$dir/$archive" "$RELEASE_BASE/$version/$archive"
    expected=$(listed_sha256 "$dir/sha256sum.txt" "$archive")
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || die "sha256sum.txt of $version does not list $archive."
    actual=$(sha256sum "$dir/$archive" | awk '{ print $1 }')
    [[ $actual == "$expected" ]] || die "Checksum mismatch for $archive: got $actual, the release lists $expected."
    if [[ -n ${OLLAMA_SHA256:-} ]]; then
        [[ $actual == "${OLLAMA_SHA256,,}" ]] || die "Checksum mismatch for $archive: got $actual, OLLAMA_SHA256 is $OLLAMA_SHA256."
    fi
    printf '%s' "$dir/$archive"
}
# Unpack archive $1 into a fresh $2 (bin/ollama + lib/ollama) and check the binary runs.
unpack_release() {
    local archive=$1 dest=$2
    rm -rf -- "$dest"
    install -d -m 0755 "$dest"
    zstd -dc -- "$archive" | tar -xf - -C "$dest" --no-same-owner
    [[ -x $dest/bin/ollama ]] || die 'The release archive has no bin/ollama.'
    chmod -R u=rwX,go=rX -- "$dest"
    "$dest/bin/ollama" --version >/dev/null 2>&1 || die 'The downloaded ollama binary does not run on this system.'
}
# Last value of KEY in an env file, without surrounding quotes (empty when absent).
env_value() {
    [[ -r $1 ]] || return 0
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n1 | sed -E "s/^([\"'])(.*)\\1\$/\\2/"
}
# Append KEY=value when the key is missing (never rewrites one).
ensure_env_key() {
    grep -Eq "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || printf '%s=%s\n' "$2" "$3" >> "$1"
}
# The local API base for this target's OLLAMA_HOST (port only; always loopback).
api_base() {
    local host port
    host=$(env_value "$TARGET_ENV" OLLAMA_HOST)
    port=${host##*:}
    [[ $port =~ ^[0-9]+$ ]] || port=11434
    printf 'http://127.0.0.1:%s' "$port"
}
# Server version reported by /api/version (empty when it does not answer).
served_version() {
    curl -fsS --max-time 5 "$(api_base)/api/version" 2>/dev/null | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}
# Wait up to $2 seconds for the server to report version $1 (any version when empty).
wait_for_version() {
    local want=${1#v} limit=${2:-60} waited=0 got
    while (( waited < limit )); do
        got=$(served_version || true)
        if [[ -n $got && ( -z $want || $got == "$want" ) ]]; then return 0; fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}
# Move the first non-empty legacy model store into $TARGET_STATE/models (only
# while that is still empty, so a re-run never mixes stores).
adopt_models() {
    local dir
    [[ -z $(ls -A "$TARGET_STATE/models" 2>/dev/null) ]] || return 0
    for dir in $LEGACY_MODEL_DIRS; do
        if [[ -d $dir && -n $(ls -A "$dir" 2>/dev/null) ]]; then
            rm -rf -- "$TARGET_STATE/models"
            mv -- "$dir" "$TARGET_STATE/models"
            printf 'Moved models from %s.\n' "$dir"
            return 0
        fi
    done
}
# Move $1 aside as $1.prev (replacing an older .prev); a no-op when absent.
set_aside() {
    [[ -e $1 || -L $1 ]] || return 0
    rm -rf -- "$1.prev"
    mv -- "$1" "$1.prev"
}
# Undo set_aside: put $1.prev back in place of whatever is at $1.
restore_aside() {
    [[ -e $1.prev || -L $1.prev ]] || return 0
    rm -rf -- "$1"
    mv -- "$1.prev" "$1"
}
# End install helpers.

MODE=adopt
case "${1:-}" in
    '') ;;
    --help|-h) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
    --upgrade) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; MODE=upgrade ;;
    *) usage >&2; exit 2 ;;
esac
[[ ${EUID} -eq 0 ]] || die 'Run as root inside the Ollama target CT.'
[[ ! -d /etc/pve ]] || die 'This is a Proxmox host. Use provision-lxc.sh here instead.'
[[ -d ${SYSTEMD_RUN_DIR:-/run/systemd/system} ]] || die 'A running systemd environment is required.'
[[ ! -d /app/router ]] || die 'The smart-router installation is present. Use a separate CT for the Ollama target.'
[[ -x $OLLAMA_LIB/bin/ollama && -f $TARGET_UNITS/$SERVICE ]] || \
    die "No community-script Ollama install found ($OLLAMA_LIB/bin/ollama, $SERVICE). Create the CT with provision-lxc.sh first."

OLLAMA_VERSION=${OLLAMA_VERSION:-$OLLAMA_DEFAULT_VERSION}
valid_version "$OLLAMA_VERSION" || die 'OLLAMA_VERSION must be a release tag such as v0.34.4.'
[[ -z ${OLLAMA_SHA256:-} || ${OLLAMA_SHA256} =~ ^[0-9A-Fa-f]{64}$ ]] || die 'OLLAMA_SHA256 must be 64 hex digits.'
OLLAMA_PULL_MODELS=${OLLAMA_PULL_MODELS:-}
valid_models "$OLLAMA_PULL_MODELS" || die 'OLLAMA_PULL_MODELS is a space-separated list of name[:tag] entries.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in ollama.env.example ollama-target.conf README.md; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done

if [[ $MODE == upgrade ]]; then
    [[ -f $DROPIN && -f $TARGET_ENV ]] || die 'This target has not been adopted yet; run install-target.sh without --upgrade first.'
    work=$(mktemp -d "${TMPDIR:-/tmp}/ollama-target.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    printf 'Installed Ollama: %s\nRequested: %s\n' "$("$OLLAMA_LIB/bin/ollama" --version 2>/dev/null | awk '{print $NF}' | tail -n1)" "$OLLAMA_VERSION"
    archive=$(fetch_release "$OLLAMA_VERSION" "$work")
    unpack_release "$archive" "$work/new"

    was_active=false
    systemctl is-active --quiet "$SERVICE" && was_active=true
    rollback() {
        printf 'Upgrade failed; restoring the previous release...\n' >&2
        systemctl stop "$SERVICE" 2>/dev/null || true
        restore_aside "$OLLAMA_LIB"
        ln -sfn -- "$OLLAMA_LIB/bin/ollama" "$OLLAMA_LINK"
        if $was_active; then systemctl start "$SERVICE" || true; fi
        rm -rf -- "$work"
    }
    trap 'rollback; exit 1' ERR
    if $was_active; then systemctl stop "$SERVICE"; fi
    set_aside "$OLLAMA_LIB"
    mv -- "$work/new" "$OLLAMA_LIB"
    ln -sfn -- "$OLLAMA_LIB/bin/ollama" "$OLLAMA_LINK"
    if $was_active; then
        systemctl start "$SERVICE"
        printf 'Waiting for Ollama %s to answer...\n' "$OLLAMA_VERSION"
        wait_for_version "$OLLAMA_VERSION" "${UPGRADE_HEALTH_TIMEOUT:-120}" || false
        printf 'Ollama %s is serving; models are unchanged.\n' "$OLLAMA_VERSION"
    else
        printf 'The service was stopped before the upgrade and is left stopped.\n'
    fi
    trap - ERR
    trap 'rm -rf -- "$work"' EXIT
    printf 'Upgrade complete. The previous release is kept as %s.prev.\n' "$OLLAMA_LIB"
    exit 0
fi

# --- adopt (idempotent) ---------------------------------------------------------
getent group "$TARGET_USER" >/dev/null || groupadd --system "$TARGET_USER"
getent passwd "$TARGET_USER" >/dev/null || \
    useradd --system --gid "$TARGET_USER" --home-dir "$TARGET_STATE" --no-create-home --shell /usr/sbin/nologin "$TARGET_USER"
# GPU device nodes are usually group video/render inside the CT.
for group in video render; do
    if getent group "$group" >/dev/null; then usermod -a -G "$group" "$TARGET_USER"; fi
done
install -d -o root -g "$TARGET_USER" -m 0750 "$TARGET_ETC"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0750 "$TARGET_STATE"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0750 "$TARGET_STATE/models"
install -o root -g root -m 0644 "$source_dir/README.md" "$TARGET_ETC/README.md"
if [[ -f $TARGET_ENV ]]; then
    printf 'Keeping existing %s\n' "$TARGET_ENV"
    ensure_env_key "$TARGET_ENV" OLLAMA_MODELS "$TARGET_STATE/models"
else
    install -o root -g "$TARGET_USER" -m 0640 "$source_dir/ollama.env.example" "$TARGET_ENV"
fi

was_active=false
systemctl is-active --quiet "$SERVICE" && was_active=true
if $was_active; then systemctl stop "$SERVICE"; fi
adopt_models
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_STATE"
install -d -o root -g root -m 0755 "$(dirname -- "$DROPIN")"
install -o root -g root -m 0644 "$source_dir/ollama-target.conf" "$DROPIN"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
wait_for_version '' 60 || {
    systemctl status "$SERVICE" --no-pager --lines=40 || true
    die "$SERVICE did not answer on $(api_base)/api/version within 60 seconds after adoption."
}
printf '\nOllama %s is serving as %s on %s.\n' "$(served_version)" "$TARGET_USER" "$(env_value "$TARGET_ENV" OLLAMA_HOST)"
for model in $OLLAMA_PULL_MODELS; do
    printf 'Pulling %s...\n' "$model"
    OLLAMA_HOST=$(api_base) "$OLLAMA_LINK" pull "$model"
done
cat <<DONE
  Settings:  $TARGET_ENV, then: systemctl restart $SERVICE
  Models:    ollama pull <name:tag>   (models live in $TARGET_STATE/models)
  GPU check: journalctl -u $SERVICE | grep -i -E 'inference compute|cuda'
  Upgrade:   bash install-target.sh --upgrade   (pinned, with rollback)
  Router:    manage-model-servers add http://<this CT's address>:11434
DONE
