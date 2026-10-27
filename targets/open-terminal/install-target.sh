#!/usr/bin/env bash
# Run inside the dedicated Open Terminal LXC after /etc/open-terminal/api-key
# has been pushed (provision-lxc.sh does both).
#
#   bash install-target.sh            install, or upgrade in place to
#                                     OPEN_TERMINAL_VERSION / OPEN_TERMINAL_COMMIT
#   bash install-target.sh --dry-run  print the plan; change nothing
#
# The upstream tag is checked against a pinned commit (tags can be moved), the
# Python dependencies come from the hash-locked requirements.lock, and the
# package itself is built offline from the verified checkout. Each commit and lock hash gets
# its own venv; /opt/open-terminal/venv points at the active one, so a failed
# upgrade switches straight back to the previous venv.
set -Eeuo pipefail

OPEN_TERMINAL_URL=https://github.com/open-webui/open-terminal.git
DEFAULT_VERSION=v0.14.0
DEFAULT_COMMIT=b58442aa8599755525878f917b621e0145b0e8f7
# Paths are overridable for tests only; open-terminal.service uses the defaults.
OT_ETC=${OT_ETC:-/etc/open-terminal}
OT_OPT=${OT_OPT:-/opt/open-terminal}
OT_SRV=${OT_SRV:-/srv/open-terminal}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-open-terminal}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-60}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]
Installs (or upgrades) Open Terminal from github.com/open-webui/open-terminal
as the unprivileged open-terminal account and starts open-terminal.service.

Environment:
  OPEN_TERMINAL_VERSION=v0.14.0   upstream tag
  OPEN_TERMINAL_COMMIT=<sha>      the commit that tag must resolve to (required
                                  for any tag other than the default)
  OPEN_TERMINAL_PORT=8000
The tag's Python dependencies must match requirements.in; a release that
changes them needs a regenerated requirements.lock (see README.md).
USAGE
}

# Install helpers (sourced by test-install.sh) -------------------------------

# deps_mismatch PYPROJECT REQUIREMENTS_IN: print the dependency lines that
# differ between the checkout's pyproject.toml and requirements.in (the lock's
# inputs). Platform-specific Windows dependencies and hatchling are ignored.
deps_mismatch() {
    python3 - "$1" "$2" <<'PY'
import re
import sys
import tomllib

def norm(spec):
    spec = spec.split(";")[0].strip()
    return re.sub(r"\s+", "", spec).lower()

with open(sys.argv[1], "rb") as f:
    project = tomllib.load(f)["project"]
wanted = {norm(d) for d in project.get("dependencies", [])
          if "win32" not in d}
locked = set()
with open(sys.argv[2], encoding="utf-8") as f:
    for line in f:
        line = line.split("#")[0].strip()
        if line and norm(line) != "hatchling":
            locked.add(norm(line))
for spec in sorted(wanted - locked):
    print(f"needed by the checkout, not in requirements.in: {spec}")
for spec in sorted(locked - wanted):
    print(f"in requirements.in, not needed by the checkout: {spec}")
PY
}

# service_env KEY PORT: the root-only EnvironmentFile the unit loads.
service_env() {
    printf '# Written by install-target.sh; root-only. Do not add OPEN_TERMINAL_API_KEY_FILE.\n'
    printf 'OPEN_TERMINAL_API_KEY=%s\n' "$1"
    printf 'OPEN_TERMINAL_PORT=%s\n' "$2"
}

# healthy PORT: /health answers {"status":"ok"}.
healthy() {
    curl --fail --silent --max-time 2 "http://127.0.0.1:$1/health" 2>/dev/null |
        grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
}
# End install helpers. ----------------------------------------------------------

wait_healthy() {
    local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
    while (( SECONDS < deadline )); do
        healthy "$PORT" && return 0
        sleep 2
    done
    return 1
}

dry_run=0
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

VERSION=${OPEN_TERMINAL_VERSION:-$DEFAULT_VERSION}
COMMIT=${OPEN_TERMINAL_COMMIT:-}
PORT=${OPEN_TERMINAL_PORT:-8000}
[[ $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid OPEN_TERMINAL_VERSION.'
if [[ -z $COMMIT ]]; then
    [[ $VERSION == "$DEFAULT_VERSION" ]] ||
        die "Set OPEN_TERMINAL_COMMIT to the reviewed commit of ${VERSION} (tags can be moved upstream)."
    COMMIT=$DEFAULT_COMMIT
fi
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die 'OPEN_TERMINAL_COMMIT must be a full 40-digit lowercase SHA-1.'
[[ $PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT <= 65535 )) || die 'Invalid OPEN_TERMINAL_PORT.'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'
for path_var in OT_ETC OT_OPT OT_SRV UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in open-terminal.service requirements.in requirements.lock; do
    [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file (push it with install-target.sh)."
done
src=$OT_OPT/source
lock_sha256=$(sha256sum "$source_dir/requirements.lock" | cut -d' ' -f1)
venv=$OT_OPT/venv-$COMMIT-$lock_sha256

if (( dry_run )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl git python3 python3-venv
    printf '+ create the %s account; workspace %s/workspace\n' "$SERVICE_USER" "$OT_SRV"
    printf '+ %s/api-key -> root-only %s/service.env (OPEN_TERMINAL_API_KEY, OPEN_TERMINAL_PORT=%s)\n' "$OT_ETC" "$OT_ETC" "$PORT"
    printf '+ git fetch --depth 1 %s refs/tags/%s; require commit %s\n' "$OPEN_TERMINAL_URL" "$VERSION" "$COMMIT"
    printf '+ check the checkout'\''s dependencies against requirements.in\n'
    printf '+ python3 -m venv %s; pip install --require-hashes -r requirements.lock; pip install --no-deps --no-build-isolation %s\n' "$venv" "$src"
    printf '+ point %s/venv at %s; install %s/open-terminal.service\n' "$OT_OPT" "$venv" "$UNIT_DIR"
    run systemctl daemon-reload
    run systemctl enable open-terminal.service
    run systemctl restart open-terminal.service
    printf '+ wait for http://127.0.0.1:%s/health to report "ok" (up to %ss); on failure switch back to the previous venv\n' "$PORT" "$HEALTH_TIMEOUT"
    exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the terminal CT.'
[[ -s $OT_ETC/api-key ]] || die "Missing $OT_ETC/api-key."
key=$(< "$OT_ETC/api-key")
key=${key//[$'\r\n\t ']/}
[[ $key =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] || die "$OT_ETC/api-key does not hold a usable key."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git python3 python3-venv
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Open Terminal needs Python 3.11+"'

id "$SERVICE_USER" >/dev/null 2>&1 ||
    useradd --system --home-dir "$OT_SRV" --create-home --shell /bin/bash "$SERVICE_USER"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$OT_SRV" "$OT_SRV/workspace"
install -d -m 0755 "$OT_OPT"
# The service reads the key through systemd (EnvironmentFile, read as root), so
# neither file needs to be readable by the account the shell runs as. Open
# Terminal also probes /etc/open-terminal/config.toml on startup, even when
# that optional file is absent. Its account must be able to traverse OT_ETC.
chown root:root "$OT_ETC" "$OT_ETC/api-key"
chmod 0711 "$OT_ETC"
chmod 0600 "$OT_ETC/api-key"

# Source: the tag, refetched (+ forces a moved tag to show up), then checked
# against the pinned commit.
if [[ ! -d $src/.git ]]; then
    git init -q "$src"
    git -C "$src" remote add origin "$OPEN_TERMINAL_URL"
fi
git -C "$src" fetch -q --depth 1 origin "+refs/tags/${VERSION}:refs/tags/${VERSION}"
git -C "$src" checkout -q --detach "refs/tags/${VERSION}"
actual=$(git -C "$src" rev-parse HEAD)
[[ $actual == "$COMMIT" ]] ||
    die "Tag ${VERSION} is commit ${actual}, not the reviewed ${COMMIT}. Review the change and set OPEN_TERMINAL_COMMIT if it is intended."
mismatch=$(deps_mismatch "$src/pyproject.toml" "$source_dir/requirements.in")
[[ -z $mismatch ]] ||
    die "Open Terminal ${VERSION} needs different Python dependencies than requirements.lock was built for:"$'\n'"$mismatch"$'\n'"Update requirements.in and regenerate requirements.lock (README.md, \"Updating the pin\")."

# Nothing to change: the commit and lock's venv is active, service.env and the
# unit would be written exactly as they are, and the terminal is healthy.
if [[ -f $venv/.install-complete && -x $venv/bin/open-terminal && $(readlink "$OT_OPT/venv" 2>/dev/null) == "$venv" ]] &&
        cmp -s <(service_env "$key" "$PORT") "$OT_ETC/service.env" &&
        cmp -s "$source_dir/open-terminal.service" "$UNIT_DIR/open-terminal.service" &&
        systemctl is-active --quiet open-terminal.service && healthy "$PORT"; then
    printf 'Open Terminal %s (%s) is already installed with these settings and is healthy; nothing to do.\n' "$VERSION" "$COMMIT"
    exit 0
fi

# A fresh venv per commit and lock hash; scripts carry its absolute path, so the
# venv is never moved, only the venv symlink is switched.
if [[ ! -f $venv/.install-complete || ! -x $venv/bin/open-terminal ]]; then
    [[ $(readlink "$OT_OPT/venv" 2>/dev/null) != "$venv" ]] ||
        die "The active venv is incomplete: $venv; inspect it before retrying."
    rm -rf -- "$venv"
    (umask 022
     python3 -m venv "$venv"
     "$venv/bin/python" -m pip install --no-cache-dir --require-hashes -r "$source_dir/requirements.lock"
     "$venv/bin/python" -m pip install --no-cache-dir --no-deps --no-build-isolation "$src"
     touch "$venv/.install-complete")
fi
previous=''
if [[ -L $OT_OPT/venv ]]; then
    previous=$(readlink "$OT_OPT/venv")
elif [[ -d $OT_OPT/venv ]]; then
    # An install made before per-commit venvs: keep it as the rollback target.
    mv "$OT_OPT/venv" "$OT_OPT/venv-legacy"
    previous=$OT_OPT/venv-legacy
fi
# Only now, with the new venv ready, is the configuration changed. The unit
# and service.env in use are kept as *.prev (this run's copies only), so a
# rollback restores the configuration as well as the venv.
unit_file=$UNIT_DIR/open-terminal.service
rm -f -- "$OT_ETC/service.env.prev" "$OT_ETC/open-terminal.service.prev"
[[ -f $OT_ETC/service.env ]] && (umask 077 && cp -p -- "$OT_ETC/service.env" "$OT_ETC/service.env.prev")
[[ -f $unit_file ]] && cp -p -- "$unit_file" "$OT_ETC/open-terminal.service.prev"
rollback() {
    # Handle restart errors as well as timeouts, including settings-only updates.
    trap - ERR
    set +e
    systemctl stop open-terminal.service 2>/dev/null
    if [[ -n $previous && -x $previous/bin/open-terminal ]]; then
        ln -sfn "$previous" "$OT_OPT/venv" || return 1
    elif [[ -z $previous ]]; then
        # A first install never became active. Keep the built venv for a retry,
        # but do not leave its symlink advertising a working installation.
        rm -f -- "$OT_OPT/venv" || return 1
    fi
    if [[ -f $OT_ETC/service.env.prev ]]; then
        mv -f -- "$OT_ETC/service.env.prev" "$OT_ETC/service.env" || return 1
        prev_port=$(sed -n 's/^OPEN_TERMINAL_PORT=\([0-9]\{1,5\}\)$/\1/p' "$OT_ETC/service.env" | tail -n1)
        [[ -n $prev_port ]] && PORT=$prev_port
    else
        rm -f -- "$OT_ETC/service.env"
    fi
    if [[ -f $OT_ETC/open-terminal.service.prev ]]; then
        install -m 0644 "$OT_ETC/open-terminal.service.prev" "$unit_file" || return 1
        rm -f -- "$OT_ETC/open-terminal.service.prev"
    else
        rm -f -- "$unit_file"
    fi
    systemctl daemon-reload || return 1
    if [[ -n $previous && -x $previous/bin/open-terminal ]]; then
        if systemctl restart open-terminal.service && wait_healthy; then
            note 'Upgrade failed; the previous Open Terminal is running again.'
        else
            note 'Upgrade failed and the previous Open Terminal did not come back either; see journalctl -u open-terminal.'
            return 1
        fi
    else
        note 'Open Terminal installation failed; no previous installation was available. The service was stopped and its new configuration removed.'
    fi
    return 0
}
# With set -E a failure inside a ( ... ) subshell fires this trap in the
# subshell and again in the parent; only the main shell rolls back (a second
# pass would find no *.prev and delete the configuration it just restored).
trap '[[ $BASHPID == "$$" ]] || exit 1; rollback || note "Rollback failed; inspect the saved configuration and journalctl -u open-terminal."; exit 1' ERR
(umask 077 && service_env "$key" "$PORT" > "$OT_ETC/service.env.new")
mv -f "$OT_ETC/service.env.new" "$OT_ETC/service.env"
ln -sfn "$venv" "$OT_OPT/venv"
install -m 0644 "$source_dir/open-terminal.service" "$unit_file"
systemctl daemon-reload
systemctl enable open-terminal.service
systemctl restart open-terminal.service
wait_healthy || false
trap - ERR
# The run succeeded, so the configuration it replaced is no longer needed
# (service.env.prev holds the API key).
rm -f -- "$OT_ETC/service.env.prev" "$OT_ETC/open-terminal.service.prev"
# Keep the active venv and the one before it; remove older ones. A settings-only
# change on the same commit removes nothing: "previous" is then the active venv
# itself, and the previous environment remains the rollback target.
if [[ $previous != "$venv" ]]; then
    for old in "$OT_OPT"/venv-*; do
        [[ -d $old && $old != "$venv" && $old != "$previous" ]] && rm -rf -- "$old"
    done
fi
printf 'Open Terminal %s (%s) is healthy on port %s.\n' "$VERSION" "$COMMIT" "$PORT"
