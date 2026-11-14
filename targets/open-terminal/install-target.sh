#!/usr/bin/env bash
# Run inside the dedicated Open Terminal LXC after /etc/open-terminal/api-key
# (Open WebUI's client key) has been pushed (provision-lxc.sh does both).
#
#   bash install-target.sh            install, or upgrade in place to
#                                     OPEN_TERMINAL_VERSION / OPEN_TERMINAL_COMMIT
#   bash install-target.sh --dry-run  print the plan; change nothing
#
# Every user gets an isolated workspace: open-terminal-gateway.service holds
# the public port, checks each client's key (Open WebUI, agent CTs) and
# forwards each (client, user) to its own open-terminal process
# (open-terminal-ws@<id>.service), started on demand by the root
# open-terminal-spawner.service under its own Linux account, port and key.
#
# The upstream tag is checked against a pinned commit (tags can be moved), the
# Python dependencies come from the hash-locked requirements.lock, and the
# package itself is built offline from the verified checkout. A tag other than
# the default whose dependencies differ from requirements.in has them resolved
# by pip instead (OPEN_TERMINAL_DEPS). Each commit and lock hash (or resolved
# dependency set) gets its own venv; /opt/open-terminal/venv points at the
# active one. Every file this run replaces is set aside first, so a failed upgrade
# (including the move from the earlier single shared workspace) is undone.
set -Eeuo pipefail
# Signal rollback helper
# A signal (Ctrl-C, a closed SSH session, kill) runs the same rollback as a
# failure: whatever the ERR trap holds at that moment, so a half-applied
# upgrade is undone; outside a rollback window it just stops the run. Further
# signals are ignored meanwhile, and after a hangup the output goes to
# OSR_INTERRUPT_LOG, so writes to the closed terminal cannot fail the rollback.
# Every copy matches targets/signal-rollback.sh (tests/test-signal-rollback.sh).
on_signal() {
    local status=$1 handler action
    local -a parts=()
    trap '' INT TERM HUP
    if [[ $status == 129 ]]; then
        exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
    fi
    printf '%s: stopped by a signal (status %s).\n' "${0##*/}" "$status" >&2
    handler=$(trap -p ERR)
    if [[ -n $handler ]]; then
        eval "parts=($handler)"
        action=${parts[2]}
        # The rollback handlers end in "exit 1": keep the signal's status.
        [[ $action != *'; exit 1' ]] || action="${action%exit 1}exit $status"
        trap - ERR
        eval "$action"
    fi
    exit "$status"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
# End signal rollback helper.

OPEN_TERMINAL_URL=https://github.com/open-webui/open-terminal.git
DEFAULT_VERSION=v0.14.0
DEFAULT_COMMIT=b58442aa8599755525878f917b621e0145b0e8f7
# Paths and accounts are overridable for tests only; the units use the defaults.
OT_ETC=${OT_ETC:-/etc/open-terminal}
OT_OPT=${OT_OPT:-/opt/open-terminal}
OT_SRV=${OT_SRV:-/srv/open-terminal}
OT_VAR=${OT_VAR:-/var/lib/open-terminal}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SBIN_DIR=${SBIN_DIR:-/usr/local/sbin}
GATEWAY_USER=${GATEWAY_USER:-ot-gateway}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-90}
GATEWAY_UNIT=open-terminal-gateway.service
SPAWNER_UNIT=open-terminal-spawner.service
WS_UNIT=open-terminal-ws@.service
LEGACY_UNIT=open-terminal.service

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
with an isolated workspace per user: open-terminal-gateway.service on the
public port, one open-terminal-ws@<id>.service per workspace.

Environment (unset: the value recorded by the last run, else the default):
  OPEN_TERMINAL_VERSION=v0.14.0   upstream tag (unset, a newer tag the last run
                                  installed is kept: no downgrade unless asked)
  OPEN_TERMINAL_COMMIT=<sha>      the commit that tag must resolve to (required
                                  for any tag other than the default)
  OPEN_TERMINAL_PORT=8000         the gateway's port
  OPEN_TERMINAL_IDLE_MINUTES=120  stop a workspace unused this long (0: never)
  OPEN_TERMINAL_MAX_ACTIVE=8      workspaces running at once (the least
                                  recently used idle one makes room)
  OPEN_TERMINAL_WS_MEMORY=1G      per-workspace MemoryMax
  OPEN_TERMINAL_WS_TASKS=512      per-workspace TasksMax
  OPEN_TERMINAL_WS_CPU=100%       per-workspace CPUQuota
  OPEN_TERMINAL_DEPS=auto         Python dependencies: lock (the hash-checked
                                  requirements.lock; the tag's dependencies must
                                  match requirements.in), resolve (pip installs
                                  the tag with its own dependencies from PyPI,
                                  saved as requirements.resolved.txt in the venv),
                                  or auto: lock when they match, else resolve
                                  for a tag other than the default
The default tag's dependencies must match requirements.in; a new default that
changes them needs a regenerated requirements.lock (see README.md).
Client keys: open-terminal-clients (list, issue, revoke, workspaces).
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

# checkout_deps PYPROJECT: the checkout's runtime dependencies, one per line,
# normalized and sorted (Windows-only ones left out), for the resolved venv's name.
checkout_deps() {
    python3 - "$1" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    project = tomllib.load(f)["project"]
for spec in sorted({re.sub(r"\s+", "", d.split(";")[0]).lower()
                    for d in project.get("dependencies", []) if "win32" not in d}):
    print(spec)
PY
}

# What gateway.py and spawner.py import from the venv; a resolved install
# asks for them too and checks they import.
GATEWAY_DEPS=(starlette httpx websockets uvicorn)

# service_env: the gateway's EnvironmentFile. It also records the workspace
# limits for the next run. No key: clients.json holds hashes only.
service_env() {
    printf '# Written by install-target.sh. No secrets (clients.json holds key hashes).\n'
    printf 'OPEN_TERMINAL_PORT=%s\n' "$PORT"
    printf 'OPEN_TERMINAL_IDLE_MINUTES=%s\n' "$IDLE_MINUTES"
    printf 'OPEN_TERMINAL_MAX_ACTIVE=%s\n' "$MAX_ACTIVE"
    printf 'OPEN_TERMINAL_WS_MEMORY=%s\n' "$WS_MEMORY"
    printf 'OPEN_TERMINAL_WS_TASKS=%s\n' "$WS_TASKS"
    printf 'OPEN_TERMINAL_WS_CPU=%s\n' "$WS_CPU"
}

# workspace_env: settings every workspace shares. The system prompt names no
# account or path, so the one Open WebUI caches fits every workspace. The
# key-related variables are set explicitly so a workspace's own
# ~/.config/open-terminal/config.toml cannot change them.
workspace_env() {
    printf '# Written by install-target.sh; read by every open-terminal-ws@ instance.\n'
    printf 'OPEN_TERMINAL_MULTI_USER=false\n'
    # Empty would mean "*"; Open WebUI and the gateway call server-side.
    printf 'OPEN_TERMINAL_CORS_ALLOWED_ORIGINS=http://127.0.0.1\n'
    printf 'OPEN_TERMINAL_FILE_BROWSER_ROOT=home\n'
    printf 'OPEN_TERMINAL_SYSTEM_PROMPT="%s"\n' \
        'You have access to your own private workspace on a computer running {{os}} {{kernel}} ({{arch}}) with {{shell}}; Python {{python_version}} is available. The workspace is your home directory (~): it is separate from every other user, and files you keep there persist. There is no root access, so system packages cannot be installed, but pip install --user works. Use your tools to run commands, read and write files and search; verify the current state before changing it and check command output.'
}

# limits_conf: resource limits for each workspace (a drop-in for the template).
limits_conf() {
    printf '# Written by install-target.sh (OPEN_TERMINAL_WS_*).\n[Service]\n'
    printf 'MemoryMax=%s\nTasksMax=%s\nCPUQuota=%s\n' "$WS_MEMORY" "$WS_TASKS" "$WS_CPU"
}

# env_get FILE NAME: NAME's value in an env file (empty if absent).
env_get() {
    [[ -f $1 ]] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n 1
}

# version_newer A B: is tag A (v0.17.8) newer than tag B?
version_newer() {
    [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $1 != "$2" ]] || return 1
    [[ $(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | tail -n 1) == "${1#v}" ]]
}

# release_record: the tag and commit a successful run installed ($OT_ETC/release),
# so a later run without OPEN_TERMINAL_VERSION keeps a release newer than the pin.
release_record() {
    printf '# Written by install-target.sh after a healthy install.\n'
    printf 'OPEN_TERMINAL_VERSION=%s\nOPEN_TERMINAL_COMMIT=%s\n' "$VERSION" "$COMMIT"
}
write_release_record() {
    cmp -s <(release_record) "$OT_ETC/release" 2>/dev/null && return 0
    release_record > "$OT_ETC/release.new" && chmod 0644 "$OT_ETC/release.new" && mv -f -- "$OT_ETC/release.new" "$OT_ETC/release"
}

# key_hash KEYFILE: the SHA-256 the gateway compares (whitespace removed).
key_hash() {
    tr -d '\r\n\t ' < "$1" | sha256sum | cut -d' ' -f1
}

# clients_has CLIENTS NAME HASH: clients.json gives NAME exactly that hash.
clients_has() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        entry = json.load(f)["clients"][sys.argv[2]]
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
sys.exit(0 if entry.get("key_sha256") == sys.argv[3] else 1)
PY
}

# healthy PORT: /health answers {"status":"ok"} (the gateway says so only once
# its metadata workspace runs, so this proves the spawner works too).
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

for path_var in OT_ETC OT_OPT OT_SRV OT_VAR UNIT_DIR SBIN_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
# Unset settings keep the last run's values (tools/upgrade-all.sh passes only
# the port), then the defaults.
VERSION=${OPEN_TERMINAL_VERSION:-$DEFAULT_VERSION}
COMMIT=${OPEN_TERMINAL_COMMIT:-}
# Never a downgrade unless asked: a newer tag the last run installed (the latest
# upstream, chosen in tools/upgrade-all.sh) is kept when none is given.
if [[ -z ${OPEN_TERMINAL_VERSION:-} && -z $COMMIT ]]; then
    recorded_version=$(env_get "$OT_ETC/release" OPEN_TERMINAL_VERSION)
    recorded_commit=$(env_get "$OT_ETC/release" OPEN_TERMINAL_COMMIT)
    if [[ $recorded_commit =~ ^[0-9a-f]{40}$ ]] && version_newer "$recorded_version" "$DEFAULT_VERSION"; then
        VERSION=$recorded_version
        COMMIT=$recorded_commit
        printf 'Keeping Open Terminal %s, newer than the pinned %s (set OPEN_TERMINAL_VERSION to move to another release).\n' "$VERSION" "$DEFAULT_VERSION"
    fi
fi
PORT=${OPEN_TERMINAL_PORT:-$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_PORT)}
PORT=${PORT:-8000}
IDLE_MINUTES=${OPEN_TERMINAL_IDLE_MINUTES:-$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_IDLE_MINUTES)}
IDLE_MINUTES=${IDLE_MINUTES:-120}
MAX_ACTIVE=${OPEN_TERMINAL_MAX_ACTIVE:-$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_MAX_ACTIVE)}
MAX_ACTIVE=${MAX_ACTIVE:-8}
WS_MEMORY=${OPEN_TERMINAL_WS_MEMORY:-$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_WS_MEMORY)}
WS_MEMORY=${WS_MEMORY:-1G}
WS_TASKS=${OPEN_TERMINAL_WS_TASKS:-$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_WS_TASKS)}
WS_TASKS=${WS_TASKS:-512}
WS_CPU=${OPEN_TERMINAL_WS_CPU:-$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_WS_CPU)}
WS_CPU=${WS_CPU:-100%}
[[ $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid OPEN_TERMINAL_VERSION.'
if [[ -z $COMMIT ]]; then
    [[ $VERSION == "$DEFAULT_VERSION" ]] ||
        die "Set OPEN_TERMINAL_COMMIT to the reviewed commit of ${VERSION} (tags can be moved upstream)."
    COMMIT=$DEFAULT_COMMIT
fi
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || die 'OPEN_TERMINAL_COMMIT must be a full 40-digit lowercase SHA-1.'
DEPS=${OPEN_TERMINAL_DEPS:-auto}
[[ $DEPS =~ ^(auto|lock|resolve)$ ]] || die 'OPEN_TERMINAL_DEPS must be auto, lock or resolve.'
[[ $PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT <= 65535 )) || die 'Invalid OPEN_TERMINAL_PORT.'
(( PORT < 20000 || PORT > 29999 )) || die 'OPEN_TERMINAL_PORT must be outside 20000-29999 (the workspaces use those).'
[[ $IDLE_MINUTES =~ ^[0-9]{1,5}$ ]] || die 'OPEN_TERMINAL_IDLE_MINUTES must be minutes (0 = never stop).'
[[ $MAX_ACTIVE =~ ^[1-9][0-9]{0,2}$ ]] || die 'OPEN_TERMINAL_MAX_ACTIVE must be 1-999.'
[[ $WS_MEMORY =~ ^([1-9][0-9]{0,5}[KMGT]?|infinity)$ ]] || die 'OPEN_TERMINAL_WS_MEMORY must be like 1G, 512M or infinity.'
[[ $WS_TASKS =~ ^([1-9][0-9]{0,5}|infinity)$ ]] || die 'OPEN_TERMINAL_WS_TASKS must be a number or infinity.'
[[ $WS_CPU =~ ^[1-9][0-9]{0,4}%$ ]] || die 'OPEN_TERMINAL_WS_CPU must be a percentage such as 100% (one core).'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'
[[ $GATEWAY_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid GATEWAY_USER.'
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in "$GATEWAY_UNIT" "$SPAWNER_UNIT" "$WS_UNIT" gateway.py spawner.py open-terminal-clients \
            requirements.in requirements.lock; do
    [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file (push it with install-target.sh)."
done
src=$OT_OPT/source
lock_sha256=$(sha256sum "$source_dir/requirements.lock" | cut -d' ' -f1)
venv=$OT_OPT/venv-$COMMIT-$lock_sha256
dropin_dir=$UNIT_DIR/$WS_UNIT.d

if (( dry_run )); then
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl git python3 python3-venv passwd
    printf '+ create the %s account; workspaces under %s/ws (one ot-<id> account each)\n' "$GATEWAY_USER" "$OT_SRV"
    printf '+ git fetch --depth 1 %s refs/tags/%s; require commit %s\n' "$OPEN_TERMINAL_URL" "$VERSION" "$COMMIT"
    printf '+ check the checkout'\''s dependencies against requirements.in (OPEN_TERMINAL_DEPS=%s)\n' "$DEPS"
    if [[ $DEPS == resolve ]]; then
        printf '+ python3 -m venv %s/venv-%s-resolved-<deps>; pip install %s %s (resolved from PyPI); save pip freeze\n' "$OT_OPT" "$COMMIT" "$src" "${GATEWAY_DEPS[*]}"
    else
        printf '+ python3 -m venv %s; pip install --require-hashes -r requirements.lock; pip install --no-deps --no-build-isolation %s\n' "$venv" "$src"
        [[ $DEPS == lock || $VERSION == "$DEFAULT_VERSION" ]] ||
            printf '+ if %s needs other dependencies than requirements.in: resolve them with pip instead (not hash-checked)\n' "$VERSION"
    fi
    printf '+ set aside the files this run replaces (%s/rollback)\n' "$OT_ETC"
    printf '+ point %s/venv at %s; install %s/lib/{gateway,spawner}.py and %s/open-terminal-clients\n' "$OT_OPT" "$venv" "$OT_OPT" "$SBIN_DIR"
    printf '+ write %s/service.env (port %s, idle %s min, at most %s active), workspace.env and the %s limits (%s, %s tasks, %s CPU)\n' \
        "$OT_ETC" "$PORT" "$IDLE_MINUTES" "$MAX_ACTIVE" "$WS_UNIT" "$WS_MEMORY" "$WS_TASKS" "$WS_CPU"
    printf '+ register %s/api-key as client openwebui in %s/clients.json (hash only)\n' "$OT_ETC" "$OT_ETC"
    printf '+ install %s, %s and %s; stop and remove %s (the earlier shared workspace) if present\n' \
        "$SPAWNER_UNIT" "$GATEWAY_UNIT" "$WS_UNIT" "$LEGACY_UNIT"
    run systemctl daemon-reload
    run systemctl enable "$SPAWNER_UNIT" "$GATEWAY_UNIT"
    printf '+ stop running workspaces (they start again on their next request)\n'
    run systemctl restart "$SPAWNER_UNIT" "$GATEWAY_UNIT"
    printf '+ wait for http://127.0.0.1:%s/health to report "ok" (up to %ss); on failure restore the previous files, venv and services\n' "$PORT" "$HEALTH_TIMEOUT"
    exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the terminal CT.'
[[ -s $OT_ETC/api-key ]] || die "Missing $OT_ETC/api-key."
key=$(< "$OT_ETC/api-key")
key=${key//[$'\r\n\t ']/}
[[ $key =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] || die "$OT_ETC/api-key does not hold a usable key."
owui_hash=$(key_hash "$OT_ETC/api-key")
unset key

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git python3 python3-venv passwd
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Open Terminal needs Python 3.11+"'

id "$GATEWAY_USER" >/dev/null 2>&1 ||
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$GATEWAY_USER"
install -d -m 0755 "$OT_OPT"
# The workspaces must traverse OT_ETC, and open-terminal probes
# /etc/open-terminal/config.toml on startup.
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
deps_mode=lock
if [[ $DEPS == resolve ]]; then
    deps_mode=resolve
elif [[ -n $mismatch ]]; then
    if [[ $DEPS == lock || $VERSION == "$DEFAULT_VERSION" ]]; then
        die "Open Terminal ${VERSION} needs different Python dependencies than requirements.lock was built for:"$'\n'"$mismatch"$'\n'"Update requirements.in and regenerate requirements.lock (README.md, \"Updating the pin\"), or set OPEN_TERMINAL_DEPS=resolve to have pip resolve them."
    fi
    deps_mode=resolve
    printf 'Open Terminal %s needs different Python dependencies than requirements.lock was built for:\n%s\n' "$VERSION" "$mismatch"
    printf 'Resolving them with pip from PyPI for this release (not hash-checked); the resolved set is saved in the venv.\n'
fi
if [[ $deps_mode == resolve ]]; then
    # Named by the commit, the dependency list and the Python it is built for,
    # so an unchanged rerun finds it complete and changes nothing.
    deps_sha256=$( { python3 -c 'import sys; print(sys.version_info[:2])'; checkout_deps "$src/pyproject.toml"; printf '%s\n' "${GATEWAY_DEPS[@]}"; } |
        sha256sum | cut -d' ' -f1)
    venv=$OT_OPT/venv-$COMMIT-resolved-${deps_sha256:0:16}
fi

# The files this target owns: destination|content source|mode. A content
# source is a repo file or a rendering helper. clients.json is handled
# separately: it also holds the agents' entries, which open-terminal-clients
# manages.
managed=(
    "$OT_ETC/service.env|render:service_env|0600"
    "$OT_ETC/workspace.env|render:workspace_env|0644"
    "$dropin_dir/50-osr-limits.conf|render:limits_conf|0644"
    "$UNIT_DIR/$SPAWNER_UNIT|file:$SPAWNER_UNIT|0644"
    "$UNIT_DIR/$GATEWAY_UNIT|file:$GATEWAY_UNIT|0644"
    "$UNIT_DIR/$WS_UNIT|file:$WS_UNIT|0644"
    "$OT_OPT/lib/gateway.py|file:gateway.py|0644"
    "$OT_OPT/lib/spawner.py|file:spawner.py|0644"
    "$SBIN_DIR/open-terminal-clients|file:open-terminal-clients|0755"
)
content_of() {
    case $1 in
        render:*) "${1#render:}" ;;
        file:*) cat -- "$source_dir/${1#file:}" ;;
    esac
}
files_current() {
    local entry dest from
    for entry in "${managed[@]}"; do
        IFS='|' read -r dest from _ <<< "$entry"
        cmp -s <(content_of "$from") "$dest" || return 1
    done
}

# Nothing to change: the commit and lock's venv is active, every file would be
# written exactly as it is, the earlier shared-workspace unit is gone, and the
# gateway is running and healthy.
if [[ -f $venv/.install-complete && -x $venv/bin/open-terminal && $(readlink "$OT_OPT/venv" 2>/dev/null) == "$venv" ]] &&
        files_current && clients_has "$OT_ETC/clients.json" openwebui "$owui_hash" &&
        [[ ! -e $UNIT_DIR/$LEGACY_UNIT ]] &&
        systemctl is-active --quiet "$SPAWNER_UNIT" && systemctl is-active --quiet "$GATEWAY_UNIT" &&
        healthy "$PORT"; then
    write_release_record
    printf 'Open Terminal %s (%s) is already installed with these settings and is healthy; nothing to do.\n' "$VERSION" "$COMMIT"
    exit 0
fi

# A fresh venv per commit and lock hash; scripts carry its absolute path, so the
# venv is never moved, only the venv symlink is switched.
if [[ ! -f $venv/.install-complete || ! -x $venv/bin/open-terminal ]]; then
    [[ $(readlink "$OT_OPT/venv" 2>/dev/null) != "$venv" ]] ||
        die "The active venv is incomplete: $venv; inspect it before retrying."
    rm -rf -- "${venv:?}"
    (umask 022
     python3 -m venv "$venv"
     if [[ $deps_mode == lock ]]; then
         "$venv/bin/python" -m pip install --no-cache-dir --require-hashes -r "$source_dir/requirements.lock"
         "$venv/bin/python" -m pip install --no-cache-dir --no-deps --no-build-isolation "$src"
     else
         # The checkout and the gateway's own imports, resolved together.
         "$venv/bin/python" -m pip install --no-cache-dir "$src" "${GATEWAY_DEPS[@]}"
         "$venv/bin/python" -c 'import starlette, httpx, websockets, uvicorn'
         "$venv/bin/python" -m pip freeze --all > "$venv/requirements.resolved.txt"
     fi
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

# Only now, with the new venv ready, is the configuration changed. Every file
# this run may replace or remove is copied into rollback/ first (an "absent"
# marker for one that does not exist), with the services that were running.
saved=$OT_ETC/rollback
rm -rf -- "${saved:?}"
install -d -m 0700 "$saved"
snapshot=()
for entry in "${managed[@]}"; do snapshot+=("${entry%%|*}"); done
snapshot+=("$OT_ETC/clients.json" "$UNIT_DIR/$LEGACY_UNIT")
for i in "${!snapshot[@]}"; do
    if [[ -e ${snapshot[i]} ]]; then cp -p -- "${snapshot[i]}" "$saved/file.$i"; else : > "$saved/absent.$i"; fi
done
was_active=()
for unit in "$LEGACY_UNIT" "$SPAWNER_UNIT" "$GATEWAY_UNIT"; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then was_active+=("$unit"); fi
done
prev_port=$(env_get "$OT_ETC/service.env" OPEN_TERMINAL_PORT)
prev_port=${prev_port:-$PORT}

rollback() {
    # Handle restart errors as well as timeouts, including settings-only updates.
    trap - ERR
    set +e
    local i unit
    systemctl stop "$GATEWAY_UNIT" "$SPAWNER_UNIT" 2>/dev/null
    systemctl stop 'open-terminal-ws@*.service' 2>/dev/null
    # Before their files may go: what was running is enabled again below.
    systemctl disable "$GATEWAY_UNIT" "$SPAWNER_UNIT" >/dev/null 2>&1
    if [[ -n $previous && -x $previous/bin/open-terminal ]]; then
        ln -sfn "$previous" "$OT_OPT/venv" || return 1
    elif [[ -z $previous ]]; then
        # A first install never became active. Keep the built venv for a retry,
        # but do not leave its symlink advertising a working installation.
        rm -f -- "${OT_OPT:?}/venv" || return 1
    fi
    for i in "${!snapshot[@]}"; do
        if [[ -e $saved/file.$i ]]; then
            install -d -m 0755 "$(dirname -- "${snapshot[i]}")" || return 1
            cp -p -- "$saved/file.$i" "${snapshot[i]}" || return 1
        else
            rm -f -- "${snapshot[i]:?}"
        fi
    done
    rmdir -- "$dropin_dir" 2>/dev/null
    systemctl daemon-reload || return 1
    PORT=$prev_port
    if (( ${#was_active[@]} )); then
        for unit in "${was_active[@]}"; do systemctl enable "$unit" >/dev/null 2>&1; done
        if systemctl restart "${was_active[@]}" && wait_healthy; then
            note 'Upgrade failed; the previous Open Terminal is running again.'
        else
            note "Upgrade failed and the previous Open Terminal did not come back either; see journalctl -u ${was_active[*]}."
            return 1
        fi
    else
        note 'Open Terminal installation failed; no previous installation was running. The services were stopped and their new configuration removed.'
    fi
    rm -rf -- "${saved:?}"
    return 0
}
# With set -E a failure inside a ( ... ) subshell fires this trap in the
# subshell and again in the parent; only the main shell rolls back (a second
# pass would find rollback/ gone and remove the restored files).
trap '[[ $BASHPID == "$$" ]] || exit 1; rollback || note "Rollback failed; the previous files are in $saved; see journalctl -u $GATEWAY_UNIT."; exit 1' ERR

# Directories. The workspaces must traverse OT_SRV and OT_SRV/ws; the
# earlier shared workspace (OT_SRV/workspace) keeps its owner and stays out
# of every workspace's reach.
install -d -m 0711 -o root -g root "$OT_SRV" "$OT_SRV/ws"
install -d -m 0700 -o root -g root "$OT_ETC/ws" "$OT_VAR" "$OT_VAR/workspaces"
install -d -m 0755 "$OT_OPT/lib" "$SBIN_DIR" "$dropin_dir"
for entry in "${managed[@]}"; do
    IFS='|' read -r dest from mode <<< "$entry"
    (umask 077 && content_of "$from" > "$dest.new")
    install -m "$mode" -o root -g root "$dest.new" "$dest"
    rm -f -- "${dest:?}.new"
done
env "OT_ETC=$OT_ETC" "OT_GATEWAY_GROUP=$GATEWAY_USER" \
    python3 "$SBIN_DIR/open-terminal-clients" import-key openwebui "$OT_ETC/api-key"
ln -sfn "$venv" "$OT_OPT/venv"
if [[ -e $UNIT_DIR/$LEGACY_UNIT ]]; then
    note "Moving from the single shared workspace: $LEGACY_UNIT is replaced; its files stay in $OT_SRV/workspace."
    systemctl disable --now "$LEGACY_UNIT" >/dev/null 2>&1 || true
    rm -f -- "${UNIT_DIR:?}/${LEGACY_UNIT:?}"
fi
systemctl daemon-reload
systemctl enable "$SPAWNER_UNIT" "$GATEWAY_UNIT"
# Running workspaces still use the old release, unit or limits; they start
# again on their next request.
systemctl stop 'open-terminal-ws@*.service'
systemctl restart "$SPAWNER_UNIT" "$GATEWAY_UNIT"
wait_healthy || false
trap - ERR
# The run succeeded, so the files it replaced are no longer needed.
rm -rf -- "${saved:?}"
# Keep the active venv and the one before it; remove older ones. A settings-only
# change on the same commit removes nothing: "previous" is then the active venv
# itself, and the previous environment remains the rollback target.
if [[ $previous != "$venv" ]]; then
    for old in "$OT_OPT"/venv-*; do
        [[ -d $old && $old != "$venv" && $old != "$previous" ]] && rm -rf -- "${old:?}"
    done
fi
write_release_record
printf 'Open Terminal %s (%s) is healthy on port %s, with a separate workspace per user.\n' "$VERSION" "$COMMIT" "$PORT"
[[ $deps_mode == lock ]] ||
    printf 'Its Python dependencies were resolved by pip, not hash-checked: %s/requirements.resolved.txt. To make them the pin, update requirements.in and regenerate requirements.lock (README.md, "Updating the pin").\n' "$venv"
