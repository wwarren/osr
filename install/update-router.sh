#!/usr/bin/env bash
# ==============================================================================
# update-router.sh — update the ollama-smart-router components of a running
# router container from a local directory of updated sources (a checkout or
# copy of this repository), without re-running the installer.
#
# Run it INSIDE the router container, as root:
#   bash /root/osr-src/install/update-router.sh              # source = that checkout
#   bash update-router.sh [options] /path/to/source
#
# What it does:
#   1. checks the source: layout, LF line endings, bash/Python syntax
#   2. commits the changed component files into the config repo (/app/config-repo)
#   3. refreshes the router venv when the router/monitor requirements changed
#   4. runs `manage-model-servers apply` (validate, snapshot, restart only the
#      affected services, health-check, roll back on failure)
#   5. pushes the commit to Gitea
# If the apply fails, the config-repo commit is undone and the router venv is
# put back, so the repo, the venv and the running files stay consistent.
#
# Updated: the installer-owned code (INSTALLER_OWNED_CODE in the source's
# ollama-smart-router-install.sh: service code, units, requirements, the
# management tools) plus this script. Never touched: env/*.env and
# litellm_config.yaml (your servers, tiers and settings) and secrets. The
# tunables router.ini / monitor.ini are updated only with --with-tunables.
# ==============================================================================

REPO_DIR="${CONFIG_REPO_DIR:-/app/config-repo}"
ROUTER_DIR="${ROUTER_DIR:-/app/router}"
ROUTER_VENV="${ROUTER_VENV:-${ROUTER_DIR}/venv}"
# The management tool that applies the result; the freshly updated copy by default.
# MANAGE_CMD is a single executable path, not a shell command string.
MANAGE_CMD="${MANAGE_CMD:-}"
MANAGE_SCRIPT="${MANAGE_SCRIPT:-${REPO_DIR}/install/manage-model-servers.sh}"
# Shared with manage-model-servers.sh; CONFIG_LOCK_WAIT seconds to wait for it.
CONFIG_LOCK_FILE="${CONFIG_LOCK_FILE:-/run/lock/ollama-smart-router-config.lock}"
CONFIG_LOCK_WAIT="${CONFIG_LOCK_WAIT:-0}"
TUNABLES=(services/ollama-router/router.ini services/ollama-monitor/monitor.ini)
SELF=install/update-router.sh

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: update-router.sh [options] [SOURCE_DIR]

SOURCE_DIR is a directory holding the updated repository (default: the
checkout this script lives in). Copy one into the container first, e.g. from
the PVE host:
  tar -C ~/gitea-ollama-smart-router --exclude=.git -czf - . |
    pct exec <CT> -- sh -c 'rm -rf /root/osr-src && mkdir /root/osr-src && tar -C /root/osr-src -xzf -'

Options:
  --dry-run         show what would change; change nothing
  --diff            print the full diff (implies --dry-run)
  --with-tunables   also update router.ini and monitor.ini (your edits there are replaced)
  --no-apply        commit but do not apply or restart (requirements changes also need --no-push)
  --no-push         do not push the commit to Gitea
  -h, --help        this help
USAGE
}

# --- helpers (sourced by tests/test-update.sh) --------------------------------
# The INSTALLER_OWNED_CODE entries of installer $1, one per line. Parsed as
# text, never evaluated: the source directory is not trusted to run code here.
owned_code_list() {
  sed -n '/^INSTALLER_OWNED_CODE=(/,/^)/p' "$1" | sed -e '1d' -e '$d' |
    sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -E '^[A-Za-z0-9._/-]+$' || true
}
# A relative repo path that cannot escape the repo.
safe_rel_path() { [[ $1 =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && $1 != *..* ]]; }
# Require every path component to be a real directory/file, not a symlink.
source_file_is_regular() {
  local root=$1 rel=$2 part path=$1
  local -a parts=()
  IFS=/ read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    path="$path/$part"
    [[ ! -L $path ]] || return 1
  done
  [[ -f $path ]]
}
# Files (relative to $1) that contain a carriage return.
crlf_files() {
  local root=$1 rel
  shift
  for rel in "$@"; do
    [[ -f $root/$rel ]] && grep -q $'\r' "$root/$rel" && printf '%s\n' "$rel"
  done
  return 0
}
# Syntax-check the files (relative to $1): bash -n for .sh, py_compile for .py.
# Prints the failures; returns 1 when there is any.
syntax_errors() {
  local root=$1 rel bad=0 py=${PYTHON:-python3}
  shift
  for rel in "$@"; do
    case "$rel" in
      *.sh) bash -n "$root/$rel" 2>/dev/null || { printf '%s\n' "$rel"; bad=1; } ;;
      *.py) "$py" -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' \
              "$root/$rel" 2>/dev/null || { printf '%s\n' "$rel"; bad=1; } ;;
    esac
  done
  return "$bad"
}
# Files (relative) whose source copy in $1 differs from the repo copy in $2.
changed_files() {
  local src=$1 dst=$2 rel
  shift 2
  for rel in "$@"; do
    [[ -f $src/$rel ]] || continue
    cmp -s "$src/$rel" "$dst/$rel" || printf '%s\n' "$rel"
  done
  return 0
}
# "+added -removed" line counts between two files (a missing file counts as empty).
diff_stat() {
  diff -u "${1}" "${2}" 2>/dev/null | awk '
    /^\+\+\+|^---/ { next } /^\+/ { a++ } /^-/ { d++ }
    END { printf "+%d -%d", a, d }' || true
}
# A short description of the source: its git commit when it is a checkout.
source_label() {
  local rev
  if rev=$(git -C "$1" describe --always --dirty 2>/dev/null); then printf '%s@%s' "$1" "$rev"
  else printf '%s' "$1"; fi
}
# --- end helpers ----------------------------------------------------------------

main() {
  local dry_run=false show_diff=false with_tunables=false do_apply=true do_push=true source=''
  local -a manage=()
  if [[ -n $MANAGE_CMD ]]; then
    manage=("$MANAGE_CMD")
  else
    manage=(bash "$MANAGE_SCRIPT")
  fi
  while (( $# )); do
    case "$1" in
      --dry-run) dry_run=true ;;
      --diff) show_diff=true; dry_run=true ;;
      --with-tunables) with_tunables=true ;;
      --no-apply) do_apply=false ;;
      --no-push) do_push=false ;;
      -h|--help) usage; return 0 ;;
      -*) usage >&2; return 2 ;;
      *) [[ -z $source ]] || { usage >&2; return 2; }; source=$1 ;;
    esac
    shift
  done
  [[ -n $source ]] || source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  [[ -d $source ]] || die "source directory not found: $source"
  source="$(cd -- "$source" && pwd -P)"

  [[ ${EUID} -eq 0 ]] || die 'run as root inside the router container.'
  [[ -d $REPO_DIR/.git ]] || die "no config repo at ${REPO_DIR} — run this inside the router container (or set CONFIG_REPO_DIR)."
  [[ -d $ROUTER_DIR ]] || die "no router installation at ${ROUTER_DIR}."
  [[ $source != "$(cd -- "$REPO_DIR" && pwd -P)" ]] || die 'the source must be a separate copy, not the config repo itself.'
  source_file_is_regular "$source" ollama-smart-router-install.sh && \
    source_file_is_regular "$source" install/manage-model-servers.sh || \
    die "${source} does not look like the ollama-smart-router repository."

  # --- what to update --------------------------------------------------------
  local -a files=() changed=() bad=()
  local rel
  mapfile -t files < <(owned_code_list "$source/ollama-smart-router-install.sh")
  (( ${#files[@]} )) || die 'the source installer has no INSTALLER_OWNED_CODE list.'
  files+=("$SELF")
  $with_tunables && files+=("${TUNABLES[@]}")
  for rel in "${files[@]}"; do safe_rel_path "$rel" || die "refusing unsafe path in the source: ${rel}"; done
  for rel in "${files[@]}"; do
    source_file_is_regular "$source" "$rel" || die "the source is missing or symlinked: ${rel}."
  done

  # --- check the source before touching anything ------------------------------
  mapfile -t bad < <(crlf_files "$source" "${files[@]}")
  if (( ${#bad[@]} )); then
    note "These files have Windows (CRLF) line endings, which bash and systemd cannot use:"
    printf '  %s\n' "${bad[@]}" >&2
    die 'convert them to LF first (git add --renormalize . on Windows, or dos2unix).'
  fi
  local py=python3
  [[ -x ${ROUTER_VENV}/bin/python ]] && py=${ROUTER_VENV}/bin/python
  mapfile -t bad < <(PYTHON=$py syntax_errors "$source" "${files[@]}" || true)
  if (( ${#bad[@]} )); then
    note "These files do not parse:"
    printf '  %s\n' "${bad[@]}" >&2
    die 'fix them in the source; nothing was changed.'
  fi

  local lock_fd=''
  if ! $dry_run; then
    command -v flock >/dev/null 2>&1 || die 'flock is required to serialize config updates.'
    [[ $CONFIG_LOCK_WAIT =~ ^[0-9]+$ ]] || die 'CONFIG_LOCK_WAIT must be a number of seconds.'
    local -a wait=(-n)
    (( CONFIG_LOCK_WAIT > 0 )) && wait=(-w "$CONFIG_LOCK_WAIT")
    exec {lock_fd}>>"$CONFIG_LOCK_FILE" || die "cannot open config lock: ${CONFIG_LOCK_FILE}"
    flock "${wait[@]}" "$lock_fd" || \
      die "another config update is already running (lock: ${CONFIG_LOCK_FILE}). If it is hung: manage-model-servers clear-lock"
  fi

  mapfile -t changed < <(changed_files "$source" "$REPO_DIR" "${files[@]}")
  local venv_changed=false
  for rel in "${changed[@]}"; do
    case "$rel" in
      services/ollama-router/requirements.txt|services/ollama-monitor/requirements.txt)
        venv_changed=true ;;
    esac
  done
  if $venv_changed && ! $do_apply && $do_push; then
    die 'router requirements changed with --no-apply; use --no-push, update the venv, then push separately.'
  fi
  if (( ${#changed[@]} == 0 )); then
    echo "Already up to date with $(source_label "$source"); nothing to do."
    return 0
  fi
  echo "Updating from $(source_label "$source"):"
  for rel in "${changed[@]}"; do
    if [[ -f $REPO_DIR/$rel ]]; then
      printf '  %-50s %s\n' "$rel" "$(diff_stat "$REPO_DIR/$rel" "$source/$rel")"
    else
      printf '  %-50s new\n' "$rel"
    fi
  done
  if $dry_run; then
    if $show_diff; then
      local before
      for rel in "${changed[@]}"; do
        before="$REPO_DIR/$rel"
        [[ -f $before ]] || before=/dev/null
        diff -u --label "a/$rel" --label "b/$rel" "$before" "$source/$rel" 2>/dev/null || true
      done
    fi
    echo "[dry-run] nothing was changed."
    return 0
  fi

  if [[ -n $(git -C "$REPO_DIR" status --porcelain) ]]; then
    git -C "$REPO_DIR" status --short >&2
    die "the config repo has uncommitted changes. Commit them first (manage-model-servers commit \"...\") so this update can be undone on its own."
  fi

  # --- commit into the config repo --------------------------------------------
  local prev_head freeze='' venv_packages='' mode
  prev_head=$(git -C "$REPO_DIR" rev-parse HEAD)

  undo() {
    trap - ERR
    note "Undoing the update: config repo back to ${prev_head:0:12}."
    git -C "$REPO_DIR" reset -q --hard "$prev_head"
    if [[ -n $freeze && -f $freeze ]]; then
      note "Restoring the previous router venv packages..."
      local current_packages='' extra=()
      if [[ -n $venv_packages && -f $venv_packages ]]; then
        current_packages="${venv_packages}.current"
        if "${ROUTER_VENV}/bin/pip" list --format=json > "$current_packages" 2>/dev/null; then
          mapfile -t extra < <(python3 - "$venv_packages" "$current_packages" <<'PY'
import json
import re
import sys

def key(name):
    return re.sub(r"[-_.]+", "-", name).lower()

with open(sys.argv[1], encoding="utf-8") as old_file:
    old = {key(item["name"]) for item in json.load(old_file)}
with open(sys.argv[2], encoding="utf-8") as current_file:
    current = {item["name"] for item in json.load(current_file)}
for name in sorted(current):
    if key(name) not in old:
        print(name)
PY
          )
          if (( ${#extra[@]} )); then
            "${ROUTER_VENV}/bin/pip" uninstall -y "${extra[@]}" >/dev/null 2>&1 || \
              note "  WARNING: removing newly installed packages failed; see ${venv_packages}."
          fi
        else
          note "  WARNING: could not enumerate the updated venv packages."
        fi
        rm -f -- "$current_packages"
      fi
      "${ROUTER_VENV}/bin/pip" install -q --no-cache-dir -r "$freeze" >/dev/null 2>&1 || \
        note "  WARNING: restoring the router venv failed; see ${freeze}."
      systemctl restart ollama-router.service ollama-monitor.service 2>/dev/null || true
    fi
  }

  # Any failure from the first filesystem mutation onward undoes the update.
  trap 'undo; exit 1' ERR
  for rel in "${changed[@]}"; do
    mode=0644
    [[ $rel == *.sh ]] && mode=0755
    install -D -m "$mode" "$source/$rel" "$REPO_DIR/$rel"
  done
  git -C "$REPO_DIR" add -- "${changed[@]}"
  git -C "$REPO_DIR" -c user.name="${GIT_AUTHOR_NAME:-ollama-smart-router}" \
      -c user.email="${GIT_AUTHOR_EMAIL:-router@localhost}" \
      commit -q -m "Update router components from $(source_label "$source")" \
      -m "$(printf '%s\n' "${changed[@]}")"
  echo "Committed to ${REPO_DIR} (previous: ${prev_head:0:12})."

  # --- router venv -------------------------------------------------------------
  if $venv_changed && $do_apply; then
    freeze="${ROUTER_DIR}/.venv-before-update.txt"
    venv_packages="${ROUTER_DIR}/.venv-before-update-packages.json"
    "${ROUTER_VENV}/bin/pip" freeze > "$freeze"
    "${ROUTER_VENV}/bin/pip" list --format=json > "$venv_packages"
    echo "Router/monitor requirements changed; updating ${ROUTER_VENV}..."
    if ! "${ROUTER_VENV}/bin/pip" install -q --no-cache-dir \
         -r "$REPO_DIR/services/ollama-router/requirements.txt" \
         -r "$REPO_DIR/services/ollama-monitor/requirements.txt"; then
      undo
      die 'installing the new router requirements failed; nothing was applied.'
    fi
  fi

  # --- apply -------------------------------------------------------------------
  if ! $do_apply; then
    echo "Not applied (--no-apply). Apply later with: manage-model-servers apply"
    if $venv_changed; then
      echo "  Update the router venv before applying:"
      echo "    ${ROUTER_VENV}/bin/pip install -r ${REPO_DIR}/services/ollama-router/requirements.txt -r ${REPO_DIR}/services/ollama-monitor/requirements.txt"
      echo "  Then restart with: manage-model-servers apply --all"
    fi
  else
    local -a apply_args=(apply)
    # A changed venv is invisible to apply's file comparison: restart everything.
    $venv_changed && apply_args+=(--all)
    echo "Applying with: manage-model-servers ${apply_args[*]}"
    if ! CONFIG_LOCK_INHERITED_FD=$lock_fd "${manage[@]}" "${apply_args[@]}"; then
      undo
      die 'the apply failed and was rolled back; the previous version is running. Nothing was pushed.'
    fi
  fi

  # --- push --------------------------------------------------------------------
  if $do_push; then
    # `commit` finds nothing new to commit and pushes with the Gitea deploy token.
    if ! CONFIG_LOCK_INHERITED_FD=$lock_fd REQUIRE_PUSH=true "${manage[@]}" commit "Update router components"; then
      trap - ERR
      [[ -z $freeze ]] || rm -f -- "$freeze"
      [[ -z $venv_packages ]] || rm -f -- "$venv_packages"
      die "push failed; the applied update and local commit are kept in ${REPO_DIR}."
    fi
  fi
  trap - ERR
  [[ -z $freeze ]] || rm -f -- "$freeze"
  [[ -z $venv_packages ]] || rm -f -- "$venv_packages"
  echo "Update complete."
}

# Sourcing (tests) only defines the helpers.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -Eeuo pipefail
  main "$@"
fi
