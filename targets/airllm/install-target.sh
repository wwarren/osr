#!/usr/bin/env bash
# Run INSIDE a dedicated AirLLM inference-target LXC or VM, never on the router
# CT or the PVE host. Installs server.py as airllm-ollama-api.service: an
# Ollama-compatible API on TCP 11434 serving one AirLLM layer-streamed model.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh              # fresh install
       bash install-target.sh --upgrade    # refresh server.py, venv and unit in place
       MIGRATE_LEGACY=true bash install-target.sh
                                           # replace an /opt/airllm-ollama-api install

Fresh install settings (environment; all optional):
  AIRLLM_MODEL_ID=Qwen/Qwen2.5-72B-Instruct   Hugging Face repo to serve
  AIRLLM_MODEL_ALIAS=<name[:tag]>             name the router sees (default: the repo id)
  AIRLLM_DEVICE=auto|cpu|cuda:0               auto picks cuda:0 when nvidia-smi sees a GPU
  START_SERVICE=true                          start now (begins the model download)
  ALLOW_SMALL_DISK=false                      proceed although the disk looks too small
HF_TOKEN is never taken from the environment: put it in
/etc/airllm-target/airllm.env after installing, then restart the service.

--upgrade keeps the model, settings and data. It refuses to restart a target
that is still downloading or loading unless ALLOW_INTERRUPT=true, and it puts
the previous files back if the target does not come back healthy within
UPGRADE_HEALTH_TIMEOUT seconds (default 900).
USAGE
}

# Install helpers (paths are overridable so tests can use a temp tree).
TARGET_ROOT=${TARGET_ROOT:-/opt/airllm-target}
TARGET_ETC=${TARGET_ETC:-/etc/airllm-target}
TARGET_STATE=${TARGET_STATE:-/var/lib/airllm-target}
TARGET_UNITS=${TARGET_UNITS:-/etc/systemd/system}
TARGET_USER=${TARGET_USER:-airllm-target}
LEGACY_ROOT=${LEGACY_ROOT:-/opt/airllm-ollama-api}
SERVICE=airllm-ollama-api.service
TARGET_ENV=$TARGET_ETC/airllm.env
# Keys copied from a legacy .env; everything else takes the new defaults.
LEGACY_KEYS=(AIRLLM_MODEL_ID AIRLLM_MODEL_ALIAS AIRLLM_DEVICE AIRLLM_COMPRESSION AIRLLM_MAX_SEQ_LEN
    AIRLLM_MAX_NEW_TOKENS AIRLLM_TOKEN_TIMEOUT AIRLLM_LOAD_WAIT AIRLLM_PORT HF_TOKEN)

valid_model_id() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ || $1 =~ ^/[A-Za-z0-9._/-]+$ ]]
}
valid_alias() { [[ -z $1 || $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]]; }
valid_device() { [[ $1 == cpu || $1 =~ ^cuda(:[0-9]{1,2})?$ ]]; }
# Last value of KEY in an env file, without surrounding quotes (empty when absent).
env_value() {
    [[ -r $1 ]] || return 0
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n1 | sed -E "s/^([\"'])(.*)\\1\$/\\2/"
}
# Set KEY=value exactly once: replace every existing line for KEY, or append.
# The value goes through ENVIRON, so no character in it is interpreted.
set_env_value() {
    local file=$1 key=$2 tmp
    tmp=$(mktemp "$file.XXXXXX")
    KEY=$key VALUE=$3 awk '
        BEGIN { key = ENVIRON["KEY"]; line = key "=" ENVIRON["VALUE"] }
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (!done) print line; done = 1; next }
        { print }
        END { if (!done) print line }
    ' "$file" > "$tmp"
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    chown --reference="$file" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$file"
}
# Append KEY=value when the key is missing (never rewrites one).
ensure_env_key() {
    grep -Eq "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || printf '%s=%s\n' "$2" "$3" >> "$1"
}
gpu_present() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }
# Parameter count in billions parsed from a repo id ("Qwen2.5-72B" -> 72); empty when unknown.
model_billions() {
    local name=${1//[-_]/ }
    [[ $name =~ (^|[^0-9.])([0-9]+(\.[0-9]+)?)[[:space:]]*[bB]([^A-Za-z0-9]|$) ]] && printf '%s' "${BASH_REMATCH[2]}"
}
# GB needed for a model: bf16 weights twice (download + AirLLM shards) + 5% + 20 GB for
# the venv and OS. 0 when the size is unknown.
required_disk_gb() {
    local billions
    billions=$(model_billions "$1") || true
    [[ -n $billions ]] || { printf '0'; return; }
    awk -v b="$billions" 'BEGIN { printf "%d", b * 2 * 2 * 1.05 + 20 + 0.999 }'
}
free_disk_gb() {
    local path=$1
    while [[ ! -e $path ]]; do path=$(dirname -- "$path"); done
    df -BG --output=avail -- "$path" | tail -n1 | tr -dc '0-9'
}
python_ok() { "$1" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))' 2>/dev/null; }
# (Re)create the venv from the hash lock and install server.py from $1.
install_server() {
    local src=$1
    # The service account must be able to traverse and read the root-owned venv.
    ( umask 022
      "${PYTHON:-python3}" -m venv "$TARGET_ROOT/venv"
      "$TARGET_ROOT/venv/bin/python" -m pip install -q --disable-pip-version-check --require-hashes \
          -r "$src/requirements.lock"
      install -o root -g root -m 0644 "$src/server.py" "$src/requirements.txt" "$src/requirements.lock" \
          "$src/README.md" "$TARGET_ROOT/"
      "$TARGET_ROOT/venv/bin/python" -m py_compile "$TARGET_ROOT/server.py"
      "$TARGET_ROOT/venv/bin/python" -m pip freeze > "$TARGET_ROOT/python-packages.txt" )
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
target_url() { printf 'http://127.0.0.1:%s%s' "$(env_value "$TARGET_ENV" AIRLLM_PORT | grep . || echo 11434)" "$1"; }
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true; }
# Wait up to $2 seconds for $1 to answer 200.
wait_for() {
    local url=$1 limit=${2:-60} waited=0
    while (( waited < limit )); do
        [[ $(http_status "$url") == 200 ]] && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}
# Copy the settings of an /opt/airllm-ollama-api install into $TARGET_ENV and move
# its downloaded weights and shards into $TARGET_STATE, so nothing is fetched twice.
migrate_legacy() {
    local old_env=$LEGACY_ROOT/.env key value dir
    for key in "${LEGACY_KEYS[@]}"; do
        value=$(env_value "$old_env" "$key")
        [[ -z $value ]] || set_env_value "$TARGET_ENV" "$key" "$value"
    done
    for dir in "$(env_value "$old_env" HF_HOME)" "$LEGACY_ROOT/hf-cache"; do
        if [[ -n $dir && -d $dir && ! -e $TARGET_STATE/hf-cache/hub ]]; then
            rm -rf -- "$TARGET_STATE/hf-cache"
            mv -- "$dir" "$TARGET_STATE/hf-cache"
            break
        fi
    done
    for dir in "$(env_value "$old_env" AIRLLM_LAYER_SHARDS_PATH)" "$LEGACY_ROOT/shards"; do
        if [[ -n $dir && -d $dir && -z $(ls -A "$TARGET_STATE/shards" 2>/dev/null) ]]; then
            rm -rf -- "$TARGET_STATE/shards"
            mv -- "$dir" "$TARGET_STATE/shards"
            break
        fi
    done
}
# End install helpers.

MODE=install
case "${1:-}" in
    '') ;;
    --help|-h) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
    --upgrade) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; MODE=upgrade ;;
    *) usage >&2; exit 2 ;;
esac
[[ ${EUID} -eq 0 ]] || die 'Run as root inside the dedicated AirLLM target.'
[[ ! -d /etc/pve ]] || die 'This is a Proxmox host. Use provision-lxc.sh here instead.'
[[ -d ${SYSTEMD_RUN_DIR:-/run/systemd/system} ]] || die 'A running systemd environment is required.'
[[ ! -d /app/router ]] || die 'The smart-router installation is present. Install this target in a separate CT.'
# shellcheck disable=SC1090,SC1091
source "${OS_RELEASE_FILE:-/etc/os-release}"
[[ ${ID:-} == debian || ${ID:-} == ubuntu || ${ID_LIKE:-} == *debian* ]] || die 'Use a Debian or Ubuntu guest.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in server.py requirements.txt requirements.lock airllm.env.example "$SERVICE" README.md; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done

if [[ $MODE == upgrade ]]; then
    [[ -x $TARGET_ROOT/venv/bin/python && -f $TARGET_ENV && -f $TARGET_UNITS/$SERVICE ]] || \
        die "No installation under $TARGET_ROOT and $TARGET_ETC; run without --upgrade to install."
    getent passwd "$TARGET_USER" >/dev/null || die "The $TARGET_USER user is missing; this is not an installed target."
    was_active=false
    systemctl is-active --quiet "$SERVICE" && was_active=true
    if $was_active && [[ $(http_status "$(target_url /healthz)") != 200 && ${ALLOW_INTERRUPT:-false} != true ]]; then
        die 'The target is still downloading or loading its model. Wait for /healthz to answer 200, or rerun with ALLOW_INTERRUPT=true (downloads resume, but splitting restarts).'
    fi
    # Only what THIS run set aside is restored.
    aside=()
    stash() { set_aside "$1"; aside+=("$1"); }
    rollback() {
        local path
        printf 'Upgrade failed; restoring the previous installation...\n' >&2
        systemctl stop "$SERVICE" 2>/dev/null || true
        for path in "${aside[@]}"; do restore_aside "$path"; done
        systemctl daemon-reload
        if $was_active; then systemctl start "$SERVICE" || true; fi
    }
    trap 'rollback; exit 1' ERR
    for path in server.py requirements.txt requirements.lock README.md venv; do stash "$TARGET_ROOT/$path"; done
    install_server "$source_dir"
    stash "$TARGET_UNITS/$SERVICE"
    install -o root -g root -m 0644 "$source_dir/$SERVICE" "$TARGET_UNITS/$SERVICE"
    # New settings get their defaults; existing values are never rewritten.
    ensure_env_key "$TARGET_ENV" AIRLLM_EXIT_ON_LOAD_FAILURE true
    ensure_env_key "$TARGET_ENV" AIRLLM_DELETE_ORIGINAL false
    ensure_env_key "$TARGET_ENV" AIRLLM_MODEL_FAMILY ''
    ensure_env_key "$TARGET_ENV" AIRLLM_MODEL_PARAMETER_SIZE ''
    systemctl daemon-reload
    if $was_active; then
        systemctl restart "$SERVICE"
        printf 'Waiting for the target to report ready...\n'
        wait_for "$(target_url /healthz)" "${UPGRADE_HEALTH_TIMEOUT:-900}" || false
        printf 'Target is healthy on the upgraded files.\n'
    else
        printf 'The service was stopped before the upgrade and is left stopped.\n'
    fi
    trap - ERR
    printf 'Upgrade complete. Previous files are kept as *.prev.\n'
    exit 0
fi

# --- fresh install ------------------------------------------------------------
migrate=false
if [[ -d $LEGACY_ROOT ]]; then
    [[ ${MIGRATE_LEGACY:-false} == true ]] || die "An earlier install exists at $LEGACY_ROOT. Rerun with MIGRATE_LEGACY=true to move its settings, downloaded weights and shards into this layout."
    migrate=true
fi
[[ ! -e $TARGET_ROOT/venv ]] || die "Already installed under $TARGET_ROOT; use --upgrade."
if [[ -f $TARGET_UNITS/$SERVICE ]] && ! $migrate; then
    die "$SERVICE already exists; use --upgrade (or MIGRATE_LEGACY=true for an $LEGACY_ROOT install)."
fi

AIRLLM_MODEL_ID=${AIRLLM_MODEL_ID:-Qwen/Qwen2.5-72B-Instruct}
AIRLLM_MODEL_ALIAS=${AIRLLM_MODEL_ALIAS:-}
AIRLLM_DEVICE=${AIRLLM_DEVICE:-auto}
if [[ $AIRLLM_DEVICE == auto ]]; then
    if gpu_present; then AIRLLM_DEVICE=cuda:0; else AIRLLM_DEVICE=cpu; fi
fi
valid_model_id "$AIRLLM_MODEL_ID" || die 'AIRLLM_MODEL_ID must be a Hugging Face <org>/<repo> or an absolute local path.'
valid_alias "$AIRLLM_MODEL_ALIAS" || die 'AIRLLM_MODEL_ALIAS may contain letters, digits and ._:/- only.'
valid_device "$AIRLLM_DEVICE" || die 'AIRLLM_DEVICE must be auto, cpu, cuda or cuda:<n>.'
if $migrate; then
    legacy_model=$(env_value "$LEGACY_ROOT/.env" AIRLLM_MODEL_ID)
    [[ -z $legacy_model ]] || AIRLLM_MODEL_ID=$legacy_model
fi

need=$(required_disk_gb "$AIRLLM_MODEL_ID")
have=$(free_disk_gb "$TARGET_STATE")
if (( need > 0 && have < need )) && ! $migrate; then
    [[ ${ALLOW_SMALL_DISK:-false} == true ]] || die "$AIRLLM_MODEL_ID needs about ${need} GB (download + AirLLM shards) but only ${have} GB is free under $TARGET_STATE. Grow the disk, set AIRLLM_DELETE_ORIGINAL=true after installing and rerun with ALLOW_SMALL_DISK=true, or choose a smaller model."
    printf 'Warning: about %s GB is needed and %s GB is free; continuing (ALLOW_SMALL_DISK=true).\n' "$need" "$have"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv
python_ok "${PYTHON:-python3}" || die 'Python 3.11 or newer is required (Debian 12+, Ubuntu 24.04+).'

getent group "$TARGET_USER" >/dev/null || groupadd --system "$TARGET_USER"
getent passwd "$TARGET_USER" >/dev/null || \
    useradd --system --gid "$TARGET_USER" --home-dir "$TARGET_STATE" --no-create-home --shell /usr/sbin/nologin "$TARGET_USER"
install -d -o root -g root -m 0755 "$TARGET_ROOT"
install -d -o root -g "$TARGET_USER" -m 0750 "$TARGET_ETC"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0750 "$TARGET_STATE" "$TARGET_STATE/hf-cache" "$TARGET_STATE/shards"

printf 'Installing the Python environment (torch is large; this takes a while)...\n'
install_server "$source_dir"
if [[ $AIRLLM_DEVICE == cuda* ]]; then
    "$TARGET_ROOT/venv/bin/python" -c 'import torch; raise SystemExit(not torch.cuda.is_available())' || \
        die 'AIRLLM_DEVICE is CUDA but torch cannot see a GPU. Install the host-matched NVIDIA user-space libraries in this CT (install_nvidia_580_173_02.sh lxc), or use AIRLLM_DEVICE=cpu.'
fi

if [[ -f $TARGET_ENV ]]; then
    printf 'Keeping existing %s\n' "$TARGET_ENV"
else
    install -o root -g "$TARGET_USER" -m 0640 "$source_dir/airllm.env.example" "$TARGET_ENV"
    set_env_value "$TARGET_ENV" AIRLLM_MODEL_ID "$AIRLLM_MODEL_ID"
    set_env_value "$TARGET_ENV" AIRLLM_MODEL_ALIAS "$AIRLLM_MODEL_ALIAS"
    set_env_value "$TARGET_ENV" AIRLLM_DEVICE "$AIRLLM_DEVICE"
    set_env_value "$TARGET_ENV" HF_HOME "$TARGET_STATE/hf-cache"
    set_env_value "$TARGET_ENV" AIRLLM_LAYER_SHARDS_PATH "$TARGET_STATE/shards"
fi

if $migrate; then
    printf 'Migrating %s...\n' "$LEGACY_ROOT"
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    migrate_legacy
    chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_STATE"
    mv -- "$LEGACY_ROOT" "$LEGACY_ROOT.legacy"
    printf 'The old tree is kept as %s.legacy; delete it once the new target works.\n' "$LEGACY_ROOT"
fi

install -o root -g root -m 0644 "$source_dir/$SERVICE" "$TARGET_UNITS/$SERVICE"
systemctl daemon-reload
systemctl enable "$SERVICE"

name=$(env_value "$TARGET_ENV" AIRLLM_MODEL_ALIAS)
name=${name:-$(env_value "$TARGET_ENV" AIRLLM_MODEL_ID)}
if [[ ${START_SERVICE:-true} == true ]]; then
    systemctl restart "$SERVICE"
    wait_for "$(target_url /api/version)" 60 || {
        systemctl status "$SERVICE" --no-pager --lines=40 || true
        die "$SERVICE did not answer on $(target_url /api/version) within 60 seconds."
    }
    printf '\n%s is up and is downloading/loading %s in the background.\n' "$SERVICE" "$name"
    printf '/api/tags and /healthz answer 503 until the model is ready, so the router ignores it until then.\n'
else
    printf '\nInstalled but not started (START_SERVICE=%s). Start with: systemctl start %s\n' "${START_SERVICE}" "$SERVICE"
fi
cat <<DONE
  Settings (HF_TOKEN for gated repos): $TARGET_ENV, then: systemctl restart $SERVICE
  Progress:   journalctl -u $SERVICE -f
  Readiness:  curl -s $(target_url /healthz)
  Smoke test: curl -s $(target_url /api/chat) -d '{"model":"$name","stream":false,"messages":[{"role":"user","content":"hi"}]}'
DONE
