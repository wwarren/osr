#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# Ollama Smart Router LXC installer for Proxmox
#
# Changes vs. the original:
#   * App/config files are staged on the host and pushed with `pct push`, so
#     secrets can never break out of shell quoting or be mangled by an inner
#     heredoc (fixes the GITEA/Mattermost token injection bug).
#   * Root password is set over stdin via `chpasswd`, never passed on argv
#     (no longer visible in the host process list).
#   * Container readiness is polled (DNS + systemd) instead of `sleep 8`, and
#     apt is retried, so a slow first boot no longer aborts the run.
#   * An ERR trap destroys a half-provisioned container on failure.
#   * The health monitor now probes each Ollama backend directly, instead of
#     reading a `services` key that LiteLLM's /health endpoint never returns
#     (the old monitor reported "healthy" forever and never alerted).
#   * The download storage is validated to support vztmpl content.
#   * Open WebUI is installed (own venv, own Python 3.12 — Debian 13's 3.13 is
#     outside its supported range) and pointed at the smart router, so the
#     container ships a chat UI in addition to the OpenAI-compatible API.
#   * A login MOTD lists every service, IP, port and config path.
#   * Container resources bumped to accommodate Open WebUI.
#   * Configuration is version controlled: the installer builds a per-service
#     config tree, seeds it into the Gitea repo (missing files only, so your
#     commits win), then the container clones it and injects the files via
#     install/apply-config.sh. Pull happens ONCE at provisioning time, so a
#     Gitea outage can never block a service start.
#   * Routing thresholds/keywords moved out of router.py into router.ini, and
#     monitor polling into monitor.ini, so behaviour is configurable per commit.
# ==============================================================================
CT_ID="${CT_ID:-}"
CT_NAME="${CT_NAME:-ollama-smart-router}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CIDR="${IP_CIDR:-192.168.11.80/24}"
GATEWAY="${GATEWAY:-192.168.11.1}"
NAMESERVER="${NAMESERVER:-}"          # optional; falls back to host DNS if empty
STORAGE="${STORAGE:-local-lvm}"
# Resources (bumped for Open WebUI: it loads a local embedding model for RAG).
# ROOTFS_GB note: with TORCH_CPU_ONLY=true (the default) the Open WebUI venv
# avoids ~4.5 GB of unusable CUDA wheels. 32 GB is kept as the default anyway,
# because if download.pytorch.org is unreachable the install falls back to the
# CUDA build (~7.5 GB venv, measured) and a smaller disk would then fail. Lower
# it to ~16 once you have confirmed a CPU-only install on your network.
CORES="${CORES:-2}"
MEMORY="${MEMORY:-4096}"
SWAP="${SWAP:-1024}"
ROOTFS_GB="${ROOTFS_GB:-32}"
# This container never has a GPU — inference happens on the remote Ollama hosts —
# so the CUDA build of torch is pure dead weight (~4.5 GB of nvidia-* wheels).
# Default true: CPU-only torch is installed from the PyTorch CPU index before
# Open WebUI, so pip sees the requirement already satisfied and skips the CUDA
# stack entirely. Needs outbound access to download.pytorch.org; if that host is
# unreachable the install falls back to the default (CUDA) build with a warning
# rather than failing the run.
TORCH_CPU_ONLY="${TORCH_CPU_ONLY:-true}"
# Service ports. Router (8000) and LiteLLM (4000) are fixed in their units;
# Open WebUI reads its port from its env file, so only this one is wired.
OPENWEBUI_PORT="${OPENWEBUI_PORT:-8080}"
# Open WebUI requires Python >=3.11,<3.13 (all releases). Debian 13 ships 3.13,
# so a dedicated interpreter is provisioned for it. See ensure_openwebui_python.
# Pinned deliberately; bump after testing. Every release so far requires
# Python >=3.11,<3.13, which is why a dedicated 3.12 interpreter is provisioned.
# Change it later on a running container with:
#   manage-model-servers set-webui-version <version|latest> --apply
OPENWEBUI_VERSION="${OPENWEBUI_VERSION:-0.11.0}"
OPENWEBUI_PY_VERSION="${OPENWEBUI_PY_VERSION:-3.12}"
OPENWEBUI_PY_DIR="${OPENWEBUI_PY_DIR:-/opt/python}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-ant-hp-nfs-backups}"
TEMPLATE_NAME="${TEMPLATE_NAME:-}"
# Minimum free space wanted on the storage that holds the container template.
TEMPLATE_MIN_GIB="${TEMPLATE_MIN_GIB:-2}"
FIREWALL="${FIREWALL:-1}"
API_ALLOW_CIDR="${API_ALLOW_CIDR:-}"  # if FIREWALL=1, allow 8000 from this CIDR
# --- Ollama model servers ---------------------------------------------------
# Everything here is only a DEFAULT offered at the prompts; set any of these in
# the environment to pre-fill (or, with NONINTERACTIVE=true, to skip) a prompt.
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
# How many Ollama hosts to configure. Asked at install; anything outside
# MODEL_SERVER_MIN..MODEL_SERVER_MAX is rejected with an error and re-prompted.
MODEL_SERVER_MIN="${MODEL_SERVER_MIN:-1}"
MODEL_SERVER_MAX="${MODEL_SERVER_MAX:-20}"
MODEL_SERVER_COUNT="${MODEL_SERVER_COUNT:-3}"
# Per-index defaults offered at the prompts. Any MODEL_SERVER_<n> up to
# MODEL_SERVER_MAX is honoured; unset indices simply have no default and must
# be typed in.
MODEL_SERVER_1="${MODEL_SERVER_1:-192.168.11.52}"
MODEL_SERVER_2="${MODEL_SERVER_2:-192.168.11.53}"
MODEL_SERVER_3="${MODEL_SERVER_3:-192.168.11.54}"
# How long Ollama should keep a model resident after a request. Blank means
# "send nothing", so each server's own OLLAMA_KEEP_ALIVE governs. A value here
# (e.g. 30m, 2h, -1 for indefinite) is sent explicitly on the LiteLLM path and
# used by the monitor's keep-alive maintainer. See the note in the README about
# why the OpenAI-compatible endpoint needs the maintainer.
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-}"
KEEP_ALIVE_REFRESH_SECONDS="${KEEP_ALIVE_REFRESH_SECONDS:-240}"
# Model tag served by each tier. NOTE: qwen3.8:27b is the value carried over
# from the original script and looks like a typo — the prompt lets you correct
# it to whatever you actually `ollama pull`ed (e.g. qwen3:32b).
MODEL_FAST="${MODEL_FAST:-qwen2.5-coder}"
MODEL_MEDIUM="${MODEL_MEDIUM:-qwen3:14b}"
MODEL_HEAVY="${MODEL_HEAVY:-qwen3.8:27b}"
# Tier -> server assignment, as 1-based server numbers. Empty means "derive a
# sensible default from the server count". A tier may list several servers;
# LiteLLM load-balances across them with the configured latency routing.
TIER_FAST_SERVERS="${TIER_FAST_SERVERS:-}"
TIER_MEDIUM_SERVERS="${TIER_MEDIUM_SERVERS:-}"
TIER_HEAVY_SERVERS="${TIER_HEAVY_SERVERS:-}"
# Skip every prompt and use the values above / from the environment.
NONINTERACTIVE="${NONINTERACTIVE:-false}"
# Populated by the prompts: normalised base URLs, and 0-based index lists.
MODEL_SERVERS=()
TIER_FAST_IDX=""
TIER_MEDIUM_IDX=""
TIER_HEAVY_IDX=""
# Gitea runs as a TurnKey appliance behind nginx on 443/80 — Gitea's own port
# 3000 is bound to localhost inside that container and is NOT reachable from
# outside, so the URL is the plain hostname with no port.
GITEA_SERVER_URL="${GITEA_SERVER_URL:-https://git.bancs.net}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea}"
# The configuration repository. Every Gitea call below is built from this name.
GITEA_REPO_NAME="${GITEA_REPO_NAME:-ollama-smart-router}"
# Owner of that repository. Leave empty to resolve automatically: the token
# owner first, then a search across everything the token can see. Set this
# explicitly when the repo belongs to an organisation, or when several accounts
# have a repo by the same name.
GITEA_REPO_OWNER="${GITEA_REPO_OWNER:-}"
GITEA_REPO_PRIVATE="${GITEA_REPO_PRIVATE:-true}"
# TurnKey appliances ship a self-signed certificate, so this defaults to false.
# NOTE: prompt_gitea_credentials sets this to false unconditionally — change it
# there (not here) if you have installed the appliance's CA or a real
# certificate and want verification enforced.
GITEA_VERIFY_TLS="${GITEA_VERIFY_TLS:-false}"
# Where the config repo is cloned inside the container. Config is pulled ONCE,
# at provisioning time — services never depend on Gitea being up to start.
CONFIG_REPO_DIR="${CONFIG_REPO_DIR:-/app/config-repo}"
# Auto-seed policy: push generated defaults only for files the repo does not
# already have, so committed edits always win. Set to "false" to require a
# pre-populated repo instead.
CONFIG_SEED_IF_MISSING="${CONFIG_SEED_IF_MISSING:-true}"
# Repo owner: discovered from the deploy token at runtime; this is the fallback.
GITEA_OWNER="${GITEA_ADMIN_USER}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
MATTERMOST_MONITOR_USER="${MATTERMOST_MONITOR_USER:-OllamaMonitor}"
MATTERMOST_CHANNEL="${MATTERMOST_CHANNEL:-ollama-monitor}"

# --- cleanup on failure -------------------------------------------------------
CT_CREATED=""
STAGE_DIR=""
cleanup_on_error() {
  local rc=$?
  [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]] && rm -rf "$STAGE_DIR"
  if [[ -n "$CT_CREATED" ]]; then
    echo "Provisioning failed (exit ${rc}); destroying container ${CT_ID}." >&2
    pct stop "$CT_ID" >/dev/null 2>&1 || true
    pct destroy "$CT_ID" --force >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_error ERR

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This installer must be run as root on a Proxmox host." >&2
    exit 1
  fi
}
require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 1
  fi
}
find_next_ct_id() {
  local candidate="" next_id=""
  if [[ -n "$CT_ID" ]]; then
    if [[ ! "$CT_ID" =~ ^[0-9]+$ ]]; then
      echo "CT_ID must be numeric when provided." >&2
      return 1
    fi
    if pct status "$CT_ID" >/dev/null 2>&1; then
      echo "Requested CT_ID ${CT_ID} already exists." >&2
      return 1
    fi
    printf '%s\n' "$CT_ID"
    return 0
  fi
  if command -v pvesh >/dev/null 2>&1; then
    next_id="$(pvesh get /cluster/nextid 2>/dev/null | awk 'NF {print $1; exit}')"
    if [[ "$next_id" =~ ^[0-9]+$ ]] && ! pct status "$next_id" >/dev/null 2>&1; then
      printf '%s\n' "$next_id"
      return 0
    fi
  fi
  candidate=100
  while pct status "$candidate" >/dev/null 2>&1; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}
# --- storage discovery -------------------------------------------------------
# Content types a storage declares, read straight from the cluster config. Used
# as a cross-check because `pvesm status -content <type>` returns nothing on
# some setups/versions, and relying on it alone leaves no way to tell "no such
# storage" apart from "the filter did not work".
STORAGE_CFG="${STORAGE_CFG:-/etc/pve/storage.cfg}"

storage_names_supporting() {
  local content="$1"
  [[ -r "$STORAGE_CFG" ]] || return 0
  awk -v want="$content" '
    /^[a-z]+:[[:space:]]*[^[:space:]]+/ {
      split($0, a, ":"); name = a[2]; gsub(/[[:space:]]/, "", name); next
    }
    /^[[:space:]]*content[[:space:]]/ {
      line = $0; sub(/^[[:space:]]*content[[:space:]]+/, "", line)
      n = split(line, types, ",")
      for (i = 1; i <= n; i++) {
        t = types[i]; gsub(/[[:space:]]/, "", t)
        if (t == want && name != "") { print name; break }
      }
    }' "$STORAGE_CFG"
}

# Parse a `pvesm status` table into "name<TAB>type<TAB>available_kib" for ACTIVE
# rows. Columns are located by HEADER NAME rather than position: pvesm has
# reordered used/available between releases, and indexing a fixed field would
# compare against the wrong number. Sizes are KiB (pvesm divides bytes by 1024).
parse_pvesm_table() {
  awk '
    NR == 1 && tolower($0) ~ /name/ && tolower($0) ~ /type/ {
      # The header carries unit annotations as SEPARATE whitespace-delimited
      # tokens ("Total (KiB)  Used (KiB)  Available (KiB)"), so a naive field
      # index puts Available at 8 while the data rows only have 7 fields.
      # Strip the parenthesised units first, then count real column positions.
      hdr = $0
      gsub(/\([^)]*\)/, "", hdr)
      ncols = split(hdr, cols, /[ \t]+/)
      idx = 0
      for (i = 1; i <= ncols; i++) {
        if (cols[i] == "") continue
        idx++
        h = tolower(cols[i])
        if (h == "name") ci_name = idx
        else if (h == "type") ci_type = idx
        else if (h == "status") ci_status = idx
        else if (h == "available" || h == "avail") ci_avail = idx
      }
      seen_header = 1
      next
    }
    {
      if (!seen_header) { ci_name = 1; ci_type = 2; ci_status = 3; ci_avail = NF - 1 }
      if (!ci_name)   ci_name = 1
      if (!ci_type)   ci_type = 2
      if (!ci_status) ci_status = 3
      if (!ci_avail)  ci_avail = NF - 1
      if (NF >= ci_avail && $(ci_status) == "active")
        printf "%s\t%s\t%s\n", $(ci_name), $(ci_type), $(ci_avail)
    }'
}

STORAGE_QUERY_ERROR=""

# Emits "name<TAB>type<TAB>available_kib" for active storages holding $1.
# Tries the server-side filter first, then falls back to the full table
# intersected with the content types declared in storage.cfg.
storage_candidates() {
  local content="$1" out rc=0 rows="" allowed
  out="$(pvesm status -content "$content" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    rows="$(printf '%s\n' "$out" | parse_pvesm_table)"
  else
    STORAGE_QUERY_ERROR="$out"
  fi
  if [[ -n "$rows" ]]; then
    printf '%s\n' "$rows"
    return 0
  fi

  # Fallback: unfiltered status, keeping only storages that storage.cfg says
  # accept this content type.
  out="$(pvesm status 2>&1)" || { STORAGE_QUERY_ERROR="$out"; return 0; }
  allowed="$(storage_names_supporting "$content")"
  if [[ -z "$allowed" ]]; then
    if [[ -r "$STORAGE_CFG" ]]; then
      # Readable config that lists nothing is a definitive answer, not an
      # unknown: offering storages that cannot hold a container would just
      # move the failure into `pct create`.
      STORAGE_QUERY_ERROR="no storage declares '${content}' in ${STORAGE_CFG}"
      return 0
    fi
    # Config unreadable: we genuinely cannot tell, so offer everything active
    # and say so rather than pretending there is nothing.
    echo "  NOTE: ${STORAGE_CFG} is unreadable; listing all active storages" >&2
    echo "        without verifying they accept '${content}'." >&2
    printf '%s\n' "$out" | parse_pvesm_table
    return 0
  fi
  printf '%s\n' "$out" | parse_pvesm_table |
    awk -F'\t' -v list="$allowed" '
      BEGIN { n = split(list, arr, "\n"); for (i = 1; i <= n; i++) ok[arr[i]] = 1 }
      $1 in ok'
}

# Everything known about storage, printed when selection fails.
diagnose_storage() {
  local content="$1"
  echo "  Diagnostics:" >&2
  if [[ -n "$STORAGE_QUERY_ERROR" ]]; then
    echo "    pvesm reported:" >&2
    printf '      %s\n' "$STORAGE_QUERY_ERROR" >&2
  fi
  echo "    pvesm status -content ${content}:" >&2
  pvesm status -content "$content" 2>&1 | sed 's/^/      /' >&2 || true
  echo "    all active storages:" >&2
  pvesm status 2>&1 | sed 's/^/      /' >&2 || true
  if [[ -r "$STORAGE_CFG" ]]; then
    echo "    storages declaring '${content}' in ${STORAGE_CFG}:" >&2
    local n
    n="$(storage_names_supporting "$content")"
    if [[ -n "$n" ]]; then
      printf '      %s\n' "$n" >&2
    else
      echo "      (none — no storage lists '${content}' in its content= line)" >&2
      echo "      Add it, e.g.:  pvesm set <storage> --content rootdir,images" >&2
    fi
  else
    echo "    ${STORAGE_CFG} is not readable from here." >&2
  fi
}

# KiB -> whole GiB (floor), so a "32 GiB free" report is never optimistic.
kib_to_gib() {
  local kib="${1:-0}"
  [[ "$kib" =~ ^[0-9]+$ ]] || { printf '0\n'; return 0; }
  printf '%s\n' "$(( kib / 1048576 ))"
}

# Free GiB on storage $1 for content type $2; prints -1 when it cannot be read.
storage_free_gib() {
  local name="$1" content="$2" line
  line="$(storage_candidates "$content" | awk -F'\t' -v n="$name" '$1 == n {print $3; exit}')"
  [[ -n "$line" ]] || { printf '%s\n' "-1"; return 0; }
  kib_to_gib "$line"
}

storage_supports_vztmpl() {
  # returns 0 if $1 is an active storage that accepts vztmpl content
  storage_candidates vztmpl | awk -F'\t' -v n="$1" '$1 == n {found=1} END {exit !found}'
}

# Interactive picker: choose a storage that can hold $1 content with at least
# $2 GiB free. Result goes into the variable named by $3.
select_storage_with_space() {
  local content="$1" need_gib="$2" var_name="$3" preferred="${4:-}"
  local -a names=() types=() frees=() ok=()
  local line name type avail_kib free_gib count=0 best="" best_free=-1 choice default_idx=0

  while IFS=$'\t' read -r name type avail_kib; do
    [[ -n "$name" ]] || continue
    free_gib="$(kib_to_gib "$avail_kib")"
    count=$(( count + 1 ))
    names+=("$name"); types+=("$type"); frees+=("$free_gib")
    if (( free_gib >= need_gib )); then
      ok+=("yes")
      if (( free_gib > best_free )); then best_free=$free_gib; best="$name"; fi
    else
      ok+=("no")
    fi
  done < <(storage_candidates "$content")

  if (( count == 0 )); then
    echo >&2
    echo "  No active storage was found that accepts '${content}' content." >&2
    diagnose_storage "$content"
    if [[ "$NONINTERACTIVE" == "true" ]]; then
      return 1
    fi
    echo >&2
    echo "  You can type a storage name to use anyway (it will not be" >&2
    echo "  space-checked), or press Enter to abort." >&2
    read -r -p "  Storage name: " choice
    if [[ -n "$choice" ]]; then
      printf -v "$var_name" '%s' "$choice"
      echo "  Using ${choice} (unverified)."
      return 0
    fi
    return 1
  fi

  echo
  echo "  Storage able to hold the container rootfs (need >= ${need_gib} GiB):"
  printf '    %-3s %-20s %-10s %-12s %s\n' "#" "STORAGE" "TYPE" "FREE" ""
  local i
  for (( i = 0; i < count; i++ )); do
    if [[ "${ok[i]}" == "yes" ]]; then
      printf '    %-3s %-20s %-10s %-12s\n' "$(( i + 1 ))" "${names[i]}" "${types[i]}" "${frees[i]} GiB"
      # Prefer the caller's existing choice when it is big enough.
      if [[ -n "$preferred" && "${names[i]}" == "$preferred" ]]; then
        default_idx=$(( i + 1 ))
      fi
    else
      # Still numbered, so selecting it gives the specific "needs N GiB"
      # refusal rather than a confusing gap in the list.
      printf '    %-3s %-20s %-10s %-12s %s\n' "$(( i + 1 ))" "${names[i]}" "${types[i]}" \
        "${frees[i]} GiB" "(too small)"
    fi
  done

  if [[ -z "$best" ]]; then
    echo >&2
    echo "  ERROR: no storage has ${need_gib} GiB free." >&2
    echo "         Free space, add storage, or choose a smaller rootfs." >&2
    echo "         (CPU-only torch is already the default, so the venv should" >&2
    echo "          be ~3 GB rather than ~7.5 GB.)" >&2
    if [[ "$NONINTERACTIVE" != "true" ]]; then
      echo >&2
      read -r -p "  Type a storage name to use anyway, or Enter to abort: " choice
      if [[ -n "$choice" ]]; then
        printf -v "$var_name" '%s' "$choice"
        echo "  Using ${choice} (space check overridden)."
        return 0
      fi
    fi
    return 1
  fi
  (( default_idx == 0 )) && { for (( i = 0; i < count; i++ )); do
      [[ "${names[i]}" == "$best" ]] && default_idx=$(( i + 1 ))
    done; }

  if [[ "$NONINTERACTIVE" == "true" ]]; then
    printf -v "$var_name" '%s' "${names[default_idx - 1]}"
    echo "  Using ${names[default_idx - 1]} (${frees[default_idx - 1]} GiB free)."
    return 0
  fi

  while true; do
    read -r -p "  Select storage [${default_idx}]: " choice
    [[ -z "$choice" ]] && choice="$default_idx"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      if [[ "${ok[choice - 1]}" == "yes" ]]; then
        printf -v "$var_name" '%s' "${names[choice - 1]}"
        echo "  Using ${names[choice - 1]} (${frees[choice - 1]} GiB free)."
        return 0
      fi
      echo "    ERROR: ${names[choice - 1]} has only ${frees[choice - 1]} GiB free;" >&2
      echo "           ${need_gib} GiB is required." >&2
    else
      echo "    ERROR: enter a number between 1 and ${count}." >&2
    fi
  done
}
template_storages() {
  {
    printf '%s\n' "$TEMPLATE_STORAGE"
    pvesm status -content vztmpl 2>/dev/null | awk 'NR > 1 {print $1}'
  } | awk 'NF && !seen[$1]++'
}
find_existing_debian_template() {
  local storage="" exact_ref="" template_list="" compatible_ref=""
  while IFS= read -r storage; do
    template_list="$(pveam list "$storage" 2>/dev/null | awk 'NR > 1 {print $1}')"
    if [[ -n "$TEMPLATE_NAME" ]]; then
      exact_ref="${storage}:vztmpl/${TEMPLATE_NAME}"
    else
      exact_ref=""
    fi
    if [[ -n "$exact_ref" ]] && printf '%s\n' "$template_list" | grep -Fxq "$exact_ref"; then
      TEMPLATE_STORAGE="$storage"
      printf '%s\n' "$exact_ref"
      return 0
    fi
    compatible_ref="$(
      printf '%s\n' "$template_list" |
        awk -v storage="$storage" '
          $1 ~ "^" storage ":vztmpl/debian-13-standard_" &&
          $1 ~ "_amd64\\.tar\\.(zst|gz|xz)$" {print $1}
        ' |
        sort -V |
        tail -n 1
    )"
    if [[ -n "$compatible_ref" ]]; then
      TEMPLATE_STORAGE="$storage"
      printf '%s\n' "$compatible_ref"
      return 0
    fi
  done < <(template_storages)
  return 1
}
select_available_debian_template() {
  local available_templates="" selected_template=""
  available_templates="$(pveam available --section system 2>/dev/null | awk 'NR > 1 {print $2}')"
  if [[ -n "$TEMPLATE_NAME" ]] && printf '%s\n' "$available_templates" | grep -Fxq "$TEMPLATE_NAME"; then
    printf '%s\n' "$TEMPLATE_NAME"
    return 0
  fi
  selected_template="$(
    printf '%s\n' "$available_templates" |
      awk '/^debian-13-standard_.*_amd64\.tar\.(zst|gz|xz)$/ {print $1}' |
      sort -V |
      tail -n 1
  )"
  if [[ -n "$selected_template" ]]; then
    printf '%s\n' "$selected_template"
    return 0
  fi
  echo "No downloadable Debian 13 standard container template was found in pveam available." >&2
  echo "Run 'pveam available --section system | grep debian-13-standard' to inspect available templates." >&2
  return 1
}
prompt_secret() {
  local prompt="$1" var_name="$2" first="" second=""
  while true; do
    read -r -s -p "$prompt: " first; echo
    read -r -s -p "Confirm $prompt: " second; echo
    if [[ -z "$first" ]]; then
      echo "Value cannot be empty." >&2
    elif [[ "$first" != "$second" ]]; then
      echo "Values did not match. Try again." >&2
    else
      printf -v "$var_name" '%s' "$first"
      break
    fi
  done
}
prompt_optional_secret() {
  local prompt="$1" var_name="$2" value=""
  read -r -s -p "$prompt (leave blank to skip): " value; echo
  printf -v "$var_name" '%s' "$value"
}
# Visible prompt with a default; pressing Enter accepts the default.
prompt_value() {
  local prompt="$1" var_name="$2" default="$3" value=""
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    printf -v "$var_name" '%s' "$default"; return 0
  fi
  read -r -p "$prompt [${default}]: " value
  [[ -z "$value" ]] && value="$default"
  printf -v "$var_name" '%s' "$value"
}

# --- input validation --------------------------------------------------------
valid_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  for octet in $ip; do
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
  return 0
}
valid_cidr() {
  local value="$1" prefix
  [[ "$value" == */* ]] || return 1
  prefix="${value#*/}"
  valid_ipv4 "${value%/*}" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 1 && prefix <= 32 ))
}
valid_hostname_or_ip() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}
valid_http_url() {
  [[ "$1" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/.*)?$ ]]
}
valid_optional_url() {   # blank is allowed (feature simply stays off)
  [[ -z "$1" ]] || valid_http_url "$1"
}
valid_optional_ipv4() {
  [[ -z "$1" ]] || valid_ipv4 "$1"
}
valid_nonempty() {
  [[ -n "$1" ]]
}
valid_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 ))
}
# Blank (use the server's own setting), -1 (never unload), 0 (unload at once),
# a bare number of seconds, or a Go duration such as 30m / 2h / 1h30m.
valid_keep_alive() {
  [[ -z "$1" ]] && return 0
  [[ "$1" == "-1" || "$1" == "0" ]] && return 0
  [[ "$1" =~ ^[0-9]+$ ]] && return 0
  [[ "$1" =~ ^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$ ]]
}
# Accepts "10.0.0.5", "10.0.0.5:11434", "ollama1.lan" or a full http(s) URL.
valid_ollama_addr() {
  local raw="$1" port
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    valid_http_url "$raw"; return $?
  fi
  if [[ "$raw" == *:* ]]; then
    port="${raw##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    valid_hostname_or_ip "${raw%:*}"; return $?
  fi
  valid_hostname_or_ip "$raw"
}
# Normalise any accepted form to a base URL with an explicit port.
normalize_ollama_url() {
  local raw="${1%/}"
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    printf '%s\n' "$raw"
  elif [[ "$raw" == *:* ]]; then
    printf 'http://%s\n' "$raw"
  else
    printf 'http://%s:%s\n' "$raw" "$OLLAMA_PORT"
  fi
}
# Comma-separated 1-based server numbers, each within range.
valid_tier_selection() {
  local sel="$1" token
  local -a tokens
  [[ -n "$sel" ]] || return 1
  IFS=',' read -r -a tokens <<< "$sel"
  (( ${#tokens[@]} > 0 )) || return 1
  for token in "${tokens[@]}"; do
    token="${token// /}"
    [[ "$token" =~ ^[0-9]+$ ]] || return 1
    (( 10#$token >= 1 && 10#$token <= MODEL_SERVER_COUNT )) || return 1
  done
  return 0
}
# Prompt until $4 (a validator function name) accepts the value.
prompt_until_valid() {
  local prompt="$1" var_name="$2" default="$3" validator="$4" value=""
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    if ! "$validator" "$default"; then
      echo "Invalid preset for ${var_name}: '${default}'" >&2
      return 1
    fi
    printf -v "$var_name" '%s' "$default"; return 0
  fi
  while true; do
    read -r -p "$prompt [${default}]: " value
    [[ -z "$value" ]] && value="$default"
    if "$validator" "$value"; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    echo "  Not a valid value: '${value}' — try again." >&2
  done
}

# --- interactive configuration ----------------------------------------------
prompt_network_config() {
  echo
  echo "--- Container network ---"
  prompt_until_valid "Proxmox bridge"            BRIDGE     "$BRIDGE"     valid_nonempty
  prompt_until_valid "Router IP address / CIDR"  IP_CIDR    "$IP_CIDR"    valid_cidr
  prompt_until_valid "Gateway IP"                GATEWAY    "$GATEWAY"    valid_ipv4
  prompt_until_valid "DNS nameserver (blank = inherit host)" \
                                                 NAMESERVER "$NAMESERVER" valid_optional_ipv4
  # A gateway outside the router's subnet is almost always a typo, and the
  # container would come up with no route off-link.
  if ! ip_in_same_subnet "$IP_CIDR" "$GATEWAY"; then
    echo "WARNING: gateway ${GATEWAY} is outside ${IP_CIDR}." >&2
    echo "         The container will have no working default route." >&2
  fi
}

# True when $2 (an IPv4) falls inside the network described by $1 (addr/prefix).
ip_in_same_subnet() {
  local cidr="$1" gw="$2"
  python3 - "$cidr" "$gw" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    net = ipaddress.ip_interface(sys.argv[1]).network
    sys.exit(0 if ipaddress.ip_address(sys.argv[2]) in net else 1)
except Exception:
    sys.exit(0)   # unparseable: don't second-guess, the field validators ran
PY
}

prompt_storage_config() {
  echo
  echo "--- Container storage ---"
  echo "  CPU-only torch is the default (no GPU here), so the Open WebUI venv"
  echo "  should be ~3 GiB and 16 GiB would do. 32 GiB is the safe default"
  echo "  because an unreachable PyTorch CPU index falls back to the CUDA"
  echo "  build, which needs ~7.5 GiB for that venv alone."
  prompt_until_valid "Root filesystem size (GiB)" ROOTFS_GB "$ROOTFS_GB" valid_positive_int
  # Size is chosen first because it decides which storages are even eligible.
  select_storage_with_space rootdir "$ROOTFS_GB" STORAGE "$STORAGE" \
    || die_storage
}

die_storage() {
  echo >&2
  echo "Cannot continue without a storage that fits the container." >&2
  exit 1
}

prompt_mattermost_config() {
  echo
  echo "--- Mattermost alerting (optional) ---"
  prompt_until_valid "Incoming webhook URL (blank to disable alerts)" \
    MATTERMOST_WEBHOOK_URL "$MATTERMOST_WEBHOOK_URL" valid_optional_url
  if [[ -n "$MATTERMOST_WEBHOOK_URL" ]]; then
    prompt_value "Channel name"    MATTERMOST_CHANNEL      "$MATTERMOST_CHANNEL"
    prompt_value "Post as username" MATTERMOST_MONITOR_USER "$MATTERMOST_MONITOR_USER"
  else
    echo "  No webhook — the monitor will log alerts instead of posting them."
  fi
}

# Default tier->server assignment for any server count from 1 upwards. Servers
# are split into three contiguous groups; the remainder goes to the heavy tier,
# which benefits most from extra parallel capacity. Counts below 3 can't give
# every tier its own host, so they share.
default_tier_selection() {
  local tier="$1" n="$MODEL_SERVER_COUNT" base
  local fast_start fast_end medium_start medium_end heavy_start heavy_end
  if (( n <= 1 )); then
    echo "1"; return 0
  fi
  if (( n == 2 )); then
    case "$tier" in
      fast)   echo "1" ;;
      medium) echo "2" ;;
      heavy)  echo "2" ;;
    esac
    return 0
  fi
  base=$(( n / 3 ))
  fast_start=1;                 fast_end=$(( base ))
  medium_start=$(( base + 1 )); medium_end=$(( base * 2 ))
  heavy_start=$(( base * 2 + 1 )); heavy_end=$n           # absorbs the remainder
  case "$tier" in
    fast)   seq_csv "$fast_start" "$fast_end" ;;
    medium) seq_csv "$medium_start" "$medium_end" ;;
    heavy)  seq_csv "$heavy_start" "$heavy_end" ;;
  esac
}

# "2" "5" -> "2,3,4,5"
seq_csv() {
  local start="$1" end="$2" i out=""
  for (( i = start; i <= end; i++ )); do
    out="${out}${out:+,}${i}"
  done
  printf '%s\n' "$out"
}

# Convert "1,3" into a space-separated 0-based index list ("0 2"), deduped.
tier_selection_to_indices() {
  local sel="$1" token out=""
  local -a tokens
  IFS=',' read -r -a tokens <<< "$sel"
  for token in "${tokens[@]}"; do
    token="${token// /}"
    [[ -n "$token" ]] || continue
    local idx=$(( 10#$token - 1 ))
    case " $out " in *" $idx "*) continue ;; esac
    out="${out}${out:+ }${idx}"
  done
  printf '%s\n' "$out"
}

# Space-separated 0-based indices -> comma-separated base URLs.
indices_to_urls() {
  local indices="$1" idx out=""
  for idx in $indices; do
    out="${out}${out:+,}${MODEL_SERVERS[$idx]}"
  done
  printf '%s\n' "$out"
}

prompt_model_servers() {
  local count raw default_addr i tier_sel
  echo
  echo "--- Ollama model servers ---"
  while true; do
    if [[ "$NONINTERACTIVE" == "true" ]]; then
      count="$MODEL_SERVER_COUNT"
    else
      read -r -p "How many Ollama model servers? (${MODEL_SERVER_MIN}-${MODEL_SERVER_MAX}) [${MODEL_SERVER_COUNT}]: " count
      [[ -z "$count" ]] && count="$MODEL_SERVER_COUNT"
    fi
    if [[ "$count" =~ ^[0-9]+$ ]] \
       && (( 10#$count >= MODEL_SERVER_MIN && 10#$count <= MODEL_SERVER_MAX )); then
      break
    fi
    # Say what was wrong with the value, not just what is allowed.
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
      echo "  ERROR: '${count}' is not a whole number." >&2
    elif (( 10#$count < MODEL_SERVER_MIN )); then
      echo "  ERROR: ${count} is too few — at least ${MODEL_SERVER_MIN} server is required." >&2
    else
      echo "  ERROR: ${count} is too many — at most ${MODEL_SERVER_MAX} servers are supported." >&2
    fi
    echo "         Enter a whole number between ${MODEL_SERVER_MIN} and ${MODEL_SERVER_MAX}." >&2
    if [[ "$NONINTERACTIVE" == "true" ]]; then
      return 1
    fi
  done
  MODEL_SERVER_COUNT=$(( 10#$count ))

  MODEL_SERVERS=()
  for (( i = 1; i <= MODEL_SERVER_COUNT; i++ )); do
    local var="MODEL_SERVER_${i}"
    default_addr="${!var:-}"
    # No default is offered for servers without a configured MODEL_SERVER_n:
    # suggesting the previous server's address would let a stray Enter create a
    # duplicate deployment, which silently double-weights that host.
    if [[ -n "$default_addr" ]]; then
      prompt_until_valid "  Server ${i} (IP, host:port or URL)" raw "$default_addr" valid_ollama_addr
    else
      while true; do
        read -r -p "  Server ${i} (IP, host:port or URL): " raw
        valid_ollama_addr "$raw" && break
        echo "    Not a valid address — try again." >&2
      done
    fi
    MODEL_SERVERS+=("$(normalize_ollama_url "$raw")")
  done

  echo
  echo "  Configured servers:"
  for i in "${!MODEL_SERVERS[@]}"; do
    printf '    %d) %s\n' "$(( i + 1 ))" "${MODEL_SERVERS[i]}"
  done
  # The same host entered twice becomes two LiteLLM deployments, which
  # double-weights it in latency routing — almost always a typo.
  local dupes
  dupes="$(printf '%s\n' "${MODEL_SERVERS[@]}" | sort | uniq -d)"
  if [[ -n "$dupes" ]]; then
    echo "  WARNING: the same address was entered more than once:" >&2
    while IFS= read -r raw; do
      [[ -n "$raw" ]] && echo "             ${raw}" >&2
    done <<< "$dupes"
    echo "           It will be weighted twice in latency routing." >&2
  fi
  echo
  echo "  Assign servers to tiers (comma-separated numbers; a tier may use"
  echo "  several servers, and LiteLLM will load-balance across them)."

  prompt_until_valid "    fast tier   (short prompts / code)" tier_sel \
    "${TIER_FAST_SERVERS:-$(default_tier_selection fast)}" valid_tier_selection
  TIER_FAST_IDX="$(tier_selection_to_indices "$tier_sel")"

  prompt_until_valid "    medium tier (mid-length prompts)" tier_sel \
    "${TIER_MEDIUM_SERVERS:-$(default_tier_selection medium)}" valid_tier_selection
  TIER_MEDIUM_IDX="$(tier_selection_to_indices "$tier_sel")"

  prompt_until_valid "    heavy tier  (long / analytical)" tier_sel \
    "${TIER_HEAVY_SERVERS:-$(default_tier_selection heavy)}" valid_tier_selection
  TIER_HEAVY_IDX="$(tier_selection_to_indices "$tier_sel")"

  echo
  echo "  Model tag served by each tier (must already be pulled on those hosts)."
  prompt_until_valid "    fast   model" MODEL_FAST   "$MODEL_FAST"   valid_nonempty
  prompt_until_valid "    medium model" MODEL_MEDIUM "$MODEL_MEDIUM" valid_nonempty
  prompt_until_valid "    heavy  model" MODEL_HEAVY  "$MODEL_HEAVY"  valid_nonempty

  echo
  echo "  Ollama unloads an idle model after 5 minutes by default. Set a"
  echo "  keep-alive here (e.g. 30m, 2h, or -1 to never unload), or leave it"
  echo "  blank to use whatever OLLAMA_KEEP_ALIVE each server is configured with."
  prompt_until_valid "    keep-alive" OLLAMA_KEEP_ALIVE "$OLLAMA_KEEP_ALIVE" valid_keep_alive

  echo
  echo "  Routing plan:"
  printf '    qwen-fast   -> %s (%s)\n' "$(indices_to_urls "$TIER_FAST_IDX")"   "$MODEL_FAST"
  printf '    qwen-medium -> %s (%s)\n' "$(indices_to_urls "$TIER_MEDIUM_IDX")" "$MODEL_MEDIUM"
  printf '    qwen-heavy  -> %s (%s)\n' "$(indices_to_urls "$TIER_HEAVY_IDX")"  "$MODEL_HEAVY"

  # Servers that ended up in no tier would sit idle — worth saying out loud.
  local unused="" idx
  for (( idx = 0; idx < MODEL_SERVER_COUNT; idx++ )); do
    case " ${TIER_FAST_IDX} ${TIER_MEDIUM_IDX} ${TIER_HEAVY_IDX} " in
      *" $idx "*) ;;
      *) unused="${unused}${unused:+, }$(( idx + 1 ))" ;;
    esac
  done
  [[ -n "$unused" ]] && echo "  NOTE: server(s) ${unused} are not assigned to any tier." >&2
  return 0
}

# Prompt for the Gitea username and auth token, validating the pair against the
# server before provisioning starts — a bad token discovered here costs seconds,
# whereas discovering it after the container is built costs the whole run.
# Leaving the token blank falls back to installing the generated config locally
# (CONFIG_SOURCE=local), which keeps provisioning working without Gitea.
CONFIG_SOURCE="repo"
prompt_gitea_credentials() {
  local attempt=0 max_attempts=3 login=""
  echo
  echo "--- Gitea (configuration repository) ---"
  prompt_until_valid "Gitea server URL" GITEA_SERVER_URL "$GITEA_SERVER_URL" valid_http_url
  prompt_value "Gitea username" GITEA_ADMIN_USER "$GITEA_ADMIN_USER"
  prompt_value "Configuration repository name" GITEA_REPO_NAME "$GITEA_REPO_NAME"
  GITEA_OWNER="$GITEA_ADMIN_USER"

  # The TurnKey Gitea appliance ships a self-signed certificate, so certificate
  # verification is turned off for every Gitea call. Set here — before
  # init_gitea_curl_opts — so the credential check, the repo resolution, the
  # seeding API calls and the container's `git clone` all use the same setting.
  # Trade-off: the deploy token is sent over a connection whose certificate is
  # not authenticated. Install the appliance's CA (or a real certificate) and
  # change this to "true" if that path isn't a network you trust.
  GITEA_VERIFY_TLS=false

  init_gitea_curl_opts

  while (( attempt < max_attempts )); do
    if [[ -z "$GITEA_DEPLOY_TOKEN" ]]; then
      prompt_optional_secret "Gitea auth token for '${GITEA_ADMIN_USER}'" GITEA_DEPLOY_TOKEN
    fi
    if [[ -z "$GITEA_DEPLOY_TOKEN" ]]; then
      echo "No token supplied — configuration will be installed directly and NOT" >&2
      echo "version controlled. Re-run with a token to use the Gitea repo." >&2
      CONFIG_SOURCE="local"
      return 0
    fi
    if login="$(gitea_probe_user "$GITEA_DEPLOY_TOKEN")" && [[ -n "$login" ]]; then
      GITEA_OWNER="$login"
      if [[ "$login" != "$GITEA_ADMIN_USER" ]]; then
        echo "NOTE: token belongs to '${login}', not '${GITEA_ADMIN_USER}'." >&2
        echo "      Using '${login}' as the repository owner." >&2
      fi
      echo "Gitea credentials verified (user: ${login})."
      return 0
    fi
    attempt=$((attempt + 1))
    GITEA_DEPLOY_TOKEN=""
    if (( attempt < max_attempts )); then
      echo "Token rejected — ${attempt}/${max_attempts}. Try again." >&2
    fi
  done

  echo "Could not verify Gitea credentials after ${max_attempts} attempts." >&2
  echo "Continuing with a local (non-version-controlled) configuration." >&2
  CONFIG_SOURCE="local"
  return 0
}

# Fallback when there is no usable Gitea token: ship the generated config tree
# into the container directly, then apply it through the same apply-config.sh
# path the repo flow uses, so the end state is identical minus version control.
push_local_config_tree() {
  local tree="$1" tarball
  tarball="$(mktemp)"
  tar -C "$tree" -czf "$tarball" .
  pct push "$CT_ID" "$tarball" /tmp/config-tree.tar.gz --perms 0600
  rm -f "$tarball"
  run_ct bash -c "
    set -e
    rm -rf '${CONFIG_REPO_DIR}'
    mkdir -p '${CONFIG_REPO_DIR}'
    tar -xzf /tmp/config-tree.tar.gz -C '${CONFIG_REPO_DIR}'
    rm -f /tmp/config-tree.tar.gz
    chown -R root:root '${CONFIG_REPO_DIR}'
    chmod -R go-rwx '${CONFIG_REPO_DIR}'
  "
}

# Run a command inside the container.
run_ct() { pct exec "$CT_ID" -- "$@"; }

# Wait until the container's userspace is actually ready (systemd + DNS).
wait_for_ct_ready() {
  local state
  echo "Waiting for container to become ready."
  for _ in $(seq 1 60); do
    state="$(run_ct systemctl is-system-running 2>/dev/null || true)"
    # 'running' or 'degraded' both mean userspace is up enough to proceed.
    if [[ "$state" == "running" || "$state" == "degraded" ]]; then
      # also make sure name resolution works before we hit apt mirrors
      if run_ct getent hosts deb.debian.org >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 2
  done
  echo "Container did not become ready in time." >&2
  return 1
}
apt_get() {
  local attempt
  for attempt in 1 2 3; do
    if run_ct apt-get "$@"; then
      return 0
    fi
    echo "apt-get $* failed (attempt ${attempt}); retrying." >&2
    sleep 5
  done
  echo "apt-get $* failed after 3 attempts." >&2
  return 1
}

# Open WebUI supports Python >=3.11,<3.13 only, while Debian 13 ships 3.13.
# Resolve an interpreter it can actually use and print its path. Tries, in
# order: an already-present pythonX.Y, the distro package, then a uv-managed
# standalone CPython build. Progress goes to stderr so stdout stays clean for
# command substitution.
ensure_openwebui_python() {
  local want="$OPENWEBUI_PY_VERSION" interp=""

  # A candidate is only usable if the *service* user can execute it. An
  # interpreter under /root (e.g. a previous uv install at
  # /root/.local/bin/python3.12) passes a root-run check but leaves the venv
  # unusable at runtime, since /root is mode 700.
  _usable_as_service_user() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    run_ct runuser -u ollama-router -- "$candidate" -c '' >/dev/null 2>&1
  }

  # 1) Already available in the container?
  interp="$(run_ct bash -lc "command -v python${want} || true" 2>/dev/null | tr -d '\r')"
  if [[ -n "$interp" ]]; then
    if _usable_as_service_user "$interp"; then
      echo "Found existing python${want} at ${interp}." >&2
      printf '%s\n' "$interp"
      return 0
    fi
    echo "Ignoring python${want} at ${interp}: not executable by the service user." >&2
  fi

  # 2) Distro package (present on some releases; absent on Debian 13).
  echo "Usable python${want} not present; trying the distro package." >&2
  if run_ct apt-get install -y "python${want}" "python${want}-venv" >/dev/null 2>&1; then
    interp="$(run_ct bash -lc "command -v python${want} || true" 2>/dev/null | tr -d '\r')"
    if _usable_as_service_user "$interp"; then
      echo "Installed python${want} from the distro repository." >&2
      printf '%s\n' "$interp"
      return 0
    fi
  fi

  # 3) uv-managed standalone CPython. uv itself comes from PyPI; the
  #    interpreter is a prebuilt standalone binary (needs outbound HTTPS to
  #    GitHub). Installed to a shared path so the service user can execute it.
  echo "Distro package unavailable; provisioning CPython ${want} via uv." >&2
  # The final `|| true` is deliberate: uv can exit non-zero on non-fatal
  # cosmetic problems (e.g. it declines to overwrite an unmanaged python3.12
  # shim in ~/.local/bin) even though the interpreter installed fine. Let the
  # `uv python find` below be the arbiter instead of aborting provisioning.
  run_ct bash -c "
    set -e
    python3 -m venv /opt/uv-bootstrap
    /opt/uv-bootstrap/bin/pip install --no-cache-dir --quiet --upgrade pip
    /opt/uv-bootstrap/bin/pip install --no-cache-dir --quiet uv
    UV_PYTHON_INSTALL_DIR='${OPENWEBUI_PY_DIR}' \
      /opt/uv-bootstrap/bin/uv python install '${want}' || true
  " >&2
  interp="$(run_ct bash -c "
    UV_PYTHON_INSTALL_DIR='${OPENWEBUI_PY_DIR}' \
      /opt/uv-bootstrap/bin/uv python find '${want}' 2>/dev/null
  " | tr -d '\r' | awk 'NF {print; exit}')"
  if [[ -z "$interp" ]]; then
    echo "Failed to provision a Python ${want} interpreter for Open WebUI." >&2
    echo "Set OPENWEBUI_PY_VERSION, or install a 3.11/3.12 interpreter manually." >&2
    return 1
  fi
  # The venv references this interpreter at runtime, and the service runs as
  # ollama-router, so it must be readable/executable by non-root.
  run_ct chmod -R a+rX "$OPENWEBUI_PY_DIR"
  if ! _usable_as_service_user "$interp"; then
    echo "Provisioned ${interp}, but it is not executable by the service user." >&2
    echo "Check permissions on ${OPENWEBUI_PY_DIR}." >&2
    return 1
  fi
  echo "Provisioned standalone CPython at ${interp}." >&2
  printf '%s\n' "$interp"
}

# Gitea REST helper. Uses $auth from the calling scope (bash dynamic scoping).
# Emits the response body followed by a final line containing the HTTP status,
# so callers can split it — the status is returned on stdout rather than via a
# global, because callers run this inside $(...) command substitution (a
# subshell) where a global assignment would not propagate back.
# Shared curl behaviour for every Gitea call. --location follows redirects; note
# curl deliberately DROPS the auth header when a redirect changes scheme, which
# is why an https:// URL matters (see the http:// warning below).
GITEA_CURL_OPTS=(--location)
init_gitea_curl_opts() {
  GITEA_CURL_OPTS=(--location)
  if [[ "$GITEA_VERIFY_TLS" != "true" ]]; then
    GITEA_CURL_OPTS+=(--insecure)
    echo "NOTE: TLS verification disabled for Gitea (GITEA_VERIFY_TLS=false)." >&2
  fi
}

# Map a curl exit code to an actionable message. $1=rc, $2=base URL.
gitea_diagnose_rc() {
  local rc="$1" base="$2"
  case "$rc" in
    6)  echo "WARNING: could not resolve the Gitea host in ${base}." >&2
        echo "         Check DNS for that name from this Proxmox host." >&2 ;;
    7)  echo "WARNING: could not connect to ${base}." >&2
        echo "         The TurnKey Gitea appliance serves on 80/443 via nginx;" >&2
        echo "         Gitea's own port 3000 is localhost-only inside that container." >&2 ;;
    22) echo "WARNING: Gitea returned an HTTP error (likely 401 Unauthorized)." >&2
        echo "         Check the token's scopes, and that the URL is https:// —" >&2
        echo "         an http:// URL loses the token on the redirect." >&2 ;;
    60) echo "WARNING: TLS certificate verification failed for ${base}." >&2
        if [[ "$GITEA_VERIFY_TLS" == "true" ]]; then
          echo "         TurnKey appliances ship a self-signed certificate. Either" >&2
          echo "         trust its CA on this host, install a real certificate, or" >&2
          echo "         set GITEA_VERIFY_TLS=false in prompt_gitea_credentials." >&2
        else
          echo "         Unexpected: verification is already disabled, so this is" >&2
          echo "         likely a TLS handshake or proxy problem rather than the" >&2
          echo "         certificate itself. Check for an intercepting proxy." >&2
        fi ;;
    *)  echo "WARNING: Gitea request failed (curl exit ${rc})." >&2
        echo "         Check GITEA_SERVER_URL and the token." >&2 ;;
  esac
}

# Probe /user with a token. Prints the login name on success.
gitea_probe_user() {
  local token="$1" base api out rc=0
  base="${GITEA_SERVER_URL%/}"; api="${base}/api/v1"
  out="$(curl -fsS "${GITEA_CURL_OPTS[@]}" -H "Authorization: token ${token}" \
        "${api}/user" 2>/dev/null)" || rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    gitea_diagnose_rc "$rc" "$base"
    return 1
  fi
  printf '%s' "$out" |
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("login",""))' 2>/dev/null
}

# Uses $auth from the calling scope.
gitea_api() {
  local method="$1" url="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS "${GITEA_CURL_OPTS[@]}" -X "$method" -H "$auth" -H 'Content-Type: application/json' \
      --data "$data" -w $'\n%{http_code}' "$url" 2>/dev/null || true
  else
    curl -sS "${GITEA_CURL_OPTS[@]}" -X "$method" -H "$auth" -w $'\n%{http_code}' "$url" 2>/dev/null || true
  fi
}

# Push every file under $1 that the repo does not already have, via the Gitea
# contents API. Files that already exist are left alone, so anything you commit
# by hand wins over the installer's generated defaults. Prints the number of
# files created. $2 is the deploy token.
seed_gitea_repo() {
  local tree="$1" token="$2"
  local base api auth owner resp http rel content_b64 payload created=0 skipped=0
  if [[ -z "$token" ]]; then
    echo "No Gitea token; skipping repo seeding (using local config only)." >&2
    return 1
  fi
  if [[ "$CONFIG_SEED_IF_MISSING" != "true" ]]; then
    echo "CONFIG_SEED_IF_MISSING=false; not writing to the repository." >&2
    return 0
  fi
  base="${GITEA_SERVER_URL%/}"; api="${base}/api/v1"
  auth="Authorization: token ${token}"
  owner="$GITEA_OWNER"

  # Walk the generated tree deterministically.
  while IFS= read -r rel; do
    resp="$(gitea_api GET "${api}/repos/${owner}/${GITEA_REPO_NAME}/contents/${rel}")"
    http="${resp##*$'\n'}"
    if [[ "$http" == "200" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    content_b64="$(base64 -w0 < "${tree}/${rel}")"
    payload="$(python3 -c '
import json,sys
print(json.dumps({"message": "Seed %s from installer" % sys.argv[1],
                  "content": sys.argv[2]}))' "$rel" "$content_b64")"
    resp="$(gitea_api POST "${api}/repos/${owner}/${GITEA_REPO_NAME}/contents/${rel}" "$payload")"
    http="${resp##*$'\n'}"
    if [[ "$http" == "201" ]]; then
      created=$((created + 1))
      echo "  seeded: ${rel}" >&2
    else
      echo "  WARNING: failed to seed ${rel} (HTTP ${http})" >&2
    fi
  done < <(cd "$tree" && find . -type f -printf '%P\n' | sort)

  echo "Repo seeding complete: ${created} created, ${skipped} already present." >&2
  return 0
}

# Clone the config repo into the container. The token is written to a file and
# pushed in (never placed on a command line, where it would show up in `ps` on
# the Proxmox host), then removed once the clone finishes.
clone_config_repo() {
  local token="$1" host cred_tmp
  host="${GITEA_SERVER_URL%/}"
  host="${host#*://}"
  cred_tmp="$(mktemp)"
  # git credential store format: <scheme>://user:token@host
  # The scheme must match the remote exactly — git will not match an https://
  # credential against an http:// request, and the clone then fails as though
  # no credential were stored at all.
  local scheme="${GITEA_SERVER_URL%%://*}"
  printf '%s://%s:%s@%s\n' "$scheme" "$GITEA_OWNER" "$token" "$host" > "$cred_tmp"
  pct push "$CT_ID" "$cred_tmp" /root/.git-credentials --perms 0600
  rm -f "$cred_tmp"

  local sslverify="true"
  [[ "$GITEA_VERIFY_TLS" == "true" ]] || sslverify="false"

  run_ct bash -c "
    set -e
    rm -rf '${CONFIG_REPO_DIR}'
    git -c credential.helper='store --file=/root/.git-credentials' \
        -c http.sslVerify=${sslverify} \
        clone '${GITEA_SERVER_URL%/}/${GITEA_OWNER}/${GITEA_REPO_NAME}.git' \
        '${CONFIG_REPO_DIR}'
    # Keep pulls working later without re-supplying credentials interactively,
    # but drop the stored password file itself.
    git -C '${CONFIG_REPO_DIR}' config http.sslVerify ${sslverify}
    rm -f /root/.git-credentials
    # git clone writes 0644 files. The repo contains env/router.env with real
    # secrets, so the working tree must not be world-readable — otherwise the
    # clone would be laxer than the 0640 runtime copy it feeds.
    chown -R root:root '${CONFIG_REPO_DIR}'
    chmod -R go-rwx '${CONFIG_REPO_DIR}'
  "
}

# Work out which repository to use, and set GITEA_OWNER to its real owner.
# Without this, a repo that lives under an organisation (or another account)
# would 404 against the token owner and a duplicate would be created silently.
# Returns: 0 = found and GITEA_OWNER set, 2 = does not exist anywhere the token
# can see (caller should create it), 1 = ambiguous or an explicit owner missed.
resolve_gitea_repo() {
  local token="$1" base api auth resp http body matches count first
  base="${GITEA_SERVER_URL%/}"; api="${base}/api/v1"
  auth="Authorization: token ${token}"

  # 1) An explicit owner is authoritative — never guess past it.
  if [[ -n "$GITEA_REPO_OWNER" ]]; then
    resp="$(gitea_api GET "${api}/repos/${GITEA_REPO_OWNER}/${GITEA_REPO_NAME}")"
    http="${resp##*$'\n'}"
    if [[ "$http" == "200" ]]; then
      GITEA_OWNER="$GITEA_REPO_OWNER"
      echo "Using repository ${GITEA_OWNER}/${GITEA_REPO_NAME} (from GITEA_REPO_OWNER)."
      return 0
    fi
    if [[ "$http" == "404" ]]; then
      echo "Repository ${GITEA_REPO_OWNER}/${GITEA_REPO_NAME} does not exist yet." >&2
      return 2
    fi
    echo "WARNING: could not read ${GITEA_REPO_OWNER}/${GITEA_REPO_NAME} (HTTP ${http})." >&2
    return 1
  fi

  # 2) Under the token owner — the common case.
  resp="$(gitea_api GET "${api}/repos/${GITEA_OWNER}/${GITEA_REPO_NAME}")"
  http="${resp##*$'\n'}"
  if [[ "$http" == "200" ]]; then
    echo "Using existing repository ${GITEA_OWNER}/${GITEA_REPO_NAME}."
    return 0
  fi

  # 3) Search everything this token can see for an exact name match, so an
  #    existing repo under an org is reused rather than duplicated.
  resp="$(gitea_api GET "${api}/repos/search?q=${GITEA_REPO_NAME}&limit=50")"
  body="${resp%$'\n'*}"
  matches="$(printf '%s' "$body" | python3 -c '
import sys, json
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for repo in (data.get("data") or []):
    if repo.get("name") == name:
        full = repo.get("full_name") or ""
        if full:
            print(full)
' "$GITEA_REPO_NAME" 2>/dev/null | sort -u)"
  count="$(printf '%s' "$matches" | grep -c . || true)"

  if [[ "$count" == "1" ]]; then
    first="$matches"
    GITEA_OWNER="${first%%/*}"
    echo "Found repository ${first}; using it."
    return 0
  fi
  if [[ "${count:-0}" -gt 1 ]]; then
    echo "WARNING: several repositories are named '${GITEA_REPO_NAME}':" >&2
    while IFS= read -r first; do
      [[ -n "$first" ]] && echo "           ${first}" >&2
    done <<< "$matches"
    echo "         Set GITEA_REPO_OWNER to choose one." >&2
    return 1
  fi
  echo "No repository named '${GITEA_REPO_NAME}' is visible to this token."
  return 2
}

# Verify Gitea access by ensuring this service's repo exists and pushing a test
# commit through the API. Non-fatal: warns and returns non-zero on failure.
test_gitea_access() {
  local token="$1" base api auth owner resp http body branch ts filepath content_b64 payload commit_url
  local repo_name="$GITEA_REPO_NAME"
  if [[ -z "$token" ]]; then
    echo "No Gitea deploy token provided; skipping Gitea access/commit test." >&2
    return 0
  fi
  require_command curl
  require_command python3
  require_command base64
  base="${GITEA_SERVER_URL%/}"
  api="${base}/api/v1"
  auth="Authorization: token ${token}"

  if [[ "$base" == http://* ]]; then
    echo "WARNING: GITEA_SERVER_URL uses http://. The TurnKey appliance redirects" >&2
    echo "         to HTTPS, and curl drops the auth token across that redirect," >&2
    echo "         which shows up as a 401. Use https:// instead." >&2
  fi

  echo "Testing Gitea access at ${base} ..."
  # 1) Authenticate and discover the token owner.
  owner="$(gitea_probe_user "$token")" || return 1
  [[ -z "$owner" ]] && owner="$GITEA_ADMIN_USER"
  GITEA_OWNER="$owner"   # used later by seeding and by the container clone
  echo "Authenticated to Gitea as: ${owner}"

  # 2) Resolve the repository (reuse it wherever it lives), else create it.
  local rrc=0
  resolve_gitea_repo "$token" || rrc=$?
  case "$rrc" in
    0)
      owner="$GITEA_OWNER"
      ;;
    2)
      # Not found anywhere the token can see — create it under the token owner.
      owner="${GITEA_REPO_OWNER:-$GITEA_OWNER}"
      echo "Creating repository ${owner}/${repo_name}."
      payload="$(printf '{"name":"%s","private":%s,"auto_init":true,"default_branch":"main","description":"Provisioned by the ollama-smart-router installer"}' \
        "$repo_name" "$GITEA_REPO_PRIVATE")"
      resp="$(gitea_api POST "${api}/user/repos" "$payload")"
      http="${resp##*$'\n'}"; body="${resp%$'\n'*}"
      if [[ "$http" == "409" ]]; then
        # Exists but wasn't visible a moment ago (permissions, or a race).
        echo "Repository ${owner}/${repo_name} already exists; reusing it."
      elif [[ "$http" != "201" ]]; then
        echo "WARNING: repo creation returned HTTP ${http}: ${body}" >&2
        return 1
      fi
      GITEA_OWNER="$owner"
      ;;
    *)
      return 1
      ;;
  esac
  echo "Configuration repository: ${GITEA_OWNER}/${repo_name}"

  # 3) Determine the default branch, then push a unique test commit.
  resp="$(gitea_api GET "${api}/repos/${owner}/${repo_name}")"
  body="${resp%$'\n'*}"
  branch="$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("default_branch") or "main")' 2>/dev/null || true)"
  [[ -z "$branch" ]] && branch="main"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  filepath="provisioning-tests/${ts}.md"
  content_b64="$(printf 'Provisioning test commit\nCreated (UTC): %s\nProxmox host: %s\nService: ollama-smart-router\n' \
    "$ts" "$(hostname)" | base64 -w0)"
  payload="$(printf '{"message":"Provisioning test commit %s","content":"%s","branch":"%s"}' \
    "$ts" "$content_b64" "$branch")"
  resp="$(gitea_api POST "${api}/repos/${owner}/${repo_name}/contents/${filepath}" "$payload")"
  http="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [[ "$http" == "201" ]]; then
    commit_url="$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("commit",{}).get("html_url",""))' 2>/dev/null || true)"
    echo "Gitea test commit succeeded on branch '${branch}': ${commit_url:-${base}/${owner}/${repo_name}}"
    return 0
  fi
  echo "WARNING: Gitea test commit returned HTTP ${http}: ${body}" >&2
  return 1
}

# ------------------------------------------------------------------------------
require_root
require_command pveam
require_command pvesm
require_command pct

require_command curl
require_command python3

CT_ID="$(find_next_ct_id)"
ROOT_PASSWORD=""
GITEA_DEPLOY_TOKEN="${GITEA_DEPLOY_TOKEN:-}"
echo "Using container ID: ${CT_ID}"
prompt_secret "Root password for container ${CT_ID}" ROOT_PASSWORD

# Collect the rest of the configuration up front, before anything is built, so
# a typo costs a re-prompt rather than a failed provisioning run. Every prompt
# offers a default (Enter accepts); NONINTERACTIVE=true takes all defaults.
prompt_network_config
prompt_storage_config

# Ask for the Gitea URL, username + auth token and verify them against the
# server. GITEA_DEPLOY_TOKEN may be preset in the environment for unattended
# runs, in which case only the username prompt appears.
prompt_gitea_credentials

prompt_mattermost_config
prompt_model_servers

# Ensure the config repo exists and that the token can write to it. Non-fatal:
# on failure we fall back to installing the configuration locally.
if [[ "$CONFIG_SOURCE" == "repo" ]]; then
  if ! test_gitea_access "$GITEA_DEPLOY_TOKEN"; then
    echo "Gitea repo check failed — falling back to a local configuration." >&2
    CONFIG_SOURCE="local"
  fi
fi

echo "Updating Proxmox appliance template index."
pveam update
if TEMPLATE_REF="$(find_existing_debian_template)"; then
  echo "Using existing Debian container template: ${TEMPLATE_REF}"
else
  if ! storage_supports_vztmpl "$TEMPLATE_STORAGE"; then
    echo "Storage '${TEMPLATE_STORAGE}' does not support vztmpl content; cannot download a template there." >&2
    echo "Set TEMPLATE_STORAGE to a storage that lists 'vztmpl' in 'pvesm status -content vztmpl'." >&2
    echo "Candidates with free space:" >&2
    storage_candidates vztmpl | while IFS=$'\t' read -r n t a; do
      echo "  ${n} (${t}): $(kib_to_gib "$a") GiB free" >&2
    done
    exit 1
  fi
  # A Debian standard template is a few hundred MB; refuse a storage that
  # obviously cannot hold one rather than failing mid-download.
  TEMPLATE_FREE_GIB="$(storage_free_gib "$TEMPLATE_STORAGE" vztmpl)"
  if [[ "$TEMPLATE_FREE_GIB" =~ ^[0-9]+$ ]] && (( TEMPLATE_FREE_GIB < TEMPLATE_MIN_GIB )); then
    echo "Storage '${TEMPLATE_STORAGE}' has only ${TEMPLATE_FREE_GIB} GiB free;" >&2
    echo "at least ${TEMPLATE_MIN_GIB} GiB is wanted for the container template." >&2
    if ! select_storage_with_space vztmpl "$TEMPLATE_MIN_GIB" TEMPLATE_STORAGE "$TEMPLATE_STORAGE"; then
      exit 1
    fi
  fi
  DOWNLOAD_TEMPLATE_NAME="$(select_available_debian_template)"
  echo "Downloading template ${DOWNLOAD_TEMPLATE_NAME} to ${TEMPLATE_STORAGE}."
  pveam download "$TEMPLATE_STORAGE" "$DOWNLOAD_TEMPLATE_NAME"
  TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${DOWNLOAD_TEMPLATE_NAME}"
fi

echo "Creating Proxmox container ${CT_ID} (${CT_NAME})."
# Note: password is intentionally NOT passed here (would be visible in `ps`).
create_args=(
  "$CT_ID" "$TEMPLATE_REF"
  -cores "$CORES"
  -memory "$MEMORY"
  -swap "$SWAP"
  -hostname "$CT_NAME"
  -ostype debian
  -storage "$STORAGE"
  -rootfs "${STORAGE}:${ROOTFS_GB}"
  -net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY},firewall=${FIREWALL}"
  -unprivileged 1
  -onboot 1
  -start 1
)
[[ -n "$NAMESERVER" ]] && create_args+=(-nameserver "$NAMESERVER")
pct create "${create_args[@]}"
CT_CREATED=1

wait_for_ct_ready

echo "Setting container root password."
printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset ROOT_PASSWORD

echo "Installing base packages inside container."
apt_get update
apt_get install -y python3 python3-pip python3-venv curl ca-certificates

echo "Creating application user and directories."
run_ct groupadd --system ollama-router
run_ct useradd --system --gid ollama-router --home-dir /app/router --shell /usr/sbin/nologin ollama-router
run_ct mkdir -p /app/router /app/openwebui/data /app/openwebui/cache

# ------------------------------------------------------------------------------
# Build the version-controlled config tree on the HOST.
#
# Layout (one directory per service, so each is version controlled on its own):
#   services/<svc>/            unit file, code, .ini, requirements.txt
#   env/                       .env files
#   install/apply-config.sh    runs inside the container, copies files into place
#
# Building the files locally means secret values are inserted literally by the
# host shell and never re-parsed by an inner shell — no quoting escape hatch,
# no `$`-in-token mangling, no injection.
# ------------------------------------------------------------------------------
echo "Building configuration tree."
umask 077
STAGE_DIR="$(mktemp -d)"
REPO_DIR="${STAGE_DIR}/repo"
mkdir -p \
  "${REPO_DIR}/services/ollama-router" \
  "${REPO_DIR}/services/litellm-proxy" \
  "${REPO_DIR}/services/ollama-monitor" \
  "${REPO_DIR}/services/open-webui" \
  "${REPO_DIR}/env" \
  "${REPO_DIR}/install"

# --- env/router.env ---
# Shared by the router, litellm-proxy and monitor units (they run from one venv).
# Backend URLs are per-tier so the monitor can probe each Ollama box directly.
cat > "${REPO_DIR}/env/router.env" <<EOF
GITEA_SERVER_URL=${GITEA_SERVER_URL}
GITEA_ADMIN_USER=${GITEA_ADMIN_USER}
GITEA_DEPLOY_TOKEN=${GITEA_DEPLOY_TOKEN}
GITEA_VERIFY_TLS=${GITEA_VERIFY_TLS}
MATTERMOST_WEBHOOK_URL=${MATTERMOST_WEBHOOK_URL}
MATTERMOST_MONITOR_USER=${MATTERMOST_MONITOR_USER}
MATTERMOST_CHANNEL=${MATTERMOST_CHANNEL}
MATTERMOST_VERIFY_TLS=true
LITELLM_BASE_URL=http://127.0.0.1:4000
LITELLM_URL=http://127.0.0.1:4000/v1/chat/completions
LITELLM_HEALTH_URL=http://127.0.0.1:4000/health
BACKEND_QWEN_FAST=$(indices_to_urls "$TIER_FAST_IDX")
BACKEND_QWEN_MEDIUM=$(indices_to_urls "$TIER_MEDIUM_IDX")
BACKEND_QWEN_HEAVY=$(indices_to_urls "$TIER_HEAVY_IDX")
MODEL_SERVER_COUNT=${MODEL_SERVER_COUNT}
MODEL_SERVERS=$(IFS=,; printf '%s' "${MODEL_SERVERS[*]}")
MODEL_FAST=${MODEL_FAST}
MODEL_MEDIUM=${MODEL_MEDIUM}
MODEL_HEAVY=${MODEL_HEAVY}
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
KEEP_ALIVE_REFRESH_SECONDS=${KEEP_ALIVE_REFRESH_SECONDS}
TORCH_CPU_ONLY=${TORCH_CPU_ONLY}
MONITOR_INTERVAL_SECONDS=15
EOF
# The generated env file now holds the token; keep one copy in memory for the
# seeding + clone steps below, then clear the original.
GITEA_DEPLOY_TOKEN_KEEP="$GITEA_DEPLOY_TOKEN"
unset GITEA_DEPLOY_TOKEN

# --- router.py (quoted heredoc: no host expansion) ---
cat > "${REPO_DIR}/services/ollama-router/router.py" <<'PYEOF'
import asyncio
import configparser
import json
import os
import re
import time
import httpx
from fastapi import FastAPI, HTTPException, Request
from starlette.background import BackgroundTask
from fastapi.responses import StreamingResponse, JSONResponse

app = FastAPI(title="Intelligent Ollama Complexity Router")

# The router is a drop-in OpenAI endpoint in front of the LiteLLM proxy.
# /v1/chat/completions has its model chosen by complexity analysis; every other
# /v1/* path (notably /v1/models, which Open WebUI calls to populate its model
# list) is proxied through unchanged.
LITELLM_BASE = os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_URL = os.getenv("LITELLM_URL", f"{LITELLM_BASE}/v1/chat/completions")

# Routing behaviour lives in router.ini (version controlled) so thresholds,
# keyword lists and discovery heuristics can change without editing this file.
# Built-in defaults keep the service working if the ini is missing or partial.
_DEFAULTS = {
    "thresholds": {"heavy": "800", "medium": "250"},
    "keywords": {
        "code_first": "true",
        "code": json.dumps(["def ", "fn ", "function", "class ", "import ",
                            "sql", "script", "code", "bug", "error", "compile"]),
        "heavy": json.dumps(["analyze", "evaluate", "optimise", "optimize",
                             "architecture", "mathematics", "calculate",
                             "summarise this article"]),
    },
    "tiers": {"fast": "qwen-fast", "medium": "qwen-medium", "heavy": "qwen-heavy"},
    "discovery": {
        "enabled": "true",
        "refresh_seconds": "60",
        "timeout_seconds": "5",
        # Comma-separated Ollama base URLs. Blank -> derive from BACKEND_* env.
        "servers": "",
        # Parameter-count bands (in billions) each request class prefers.
        "fast_params": "0:9",
        "medium_params": "9:20",
        "heavy_params": "20:999",
        # How quickly score decays per billion parameters outside the band.
        "band_falloff": "12",
        # Substrings marking a model as code-specialised / vision / embedding.
        "code_models": json.dumps(["coder", "code", "starcoder", "codellama",
                                   "deepseek-coder", "codegemma", "codestral"]),
        "vision_models": json.dumps(["llava", "vision", "-vl", "minicpm-v",
                                     "moondream", "bakllava"]),
        "embedding_models": json.dumps(["embed", "embedding", "bge-", "gte-",
                                        "nomic-embed", "mxbai-embed"]),
        "vision_families": json.dumps(["clip", "mllama", "llava"]),
        "embedding_families": json.dumps(["bert", "nomic-bert"]),
    },
    "weights": {
        "band_fit": "1.0",
        "code_match": "0.6",
        "vision_match": "1.5",
        "prefer_larger_heavy": "0.15",
        "prefer_smaller_fast": "0.15",
        "unknown_params": "0.3",
        # Fraction of the specialist weight applied as a penalty when a
        # specialised model (code/vision) is used for an off-task request.
        "offtask_penalty": "0.25",
        # Candidates within this score of the best are treated as equivalent and
        # rotated through, so identical models on several hosts share load.
        "tie_epsilon": "0.05",
    },
}
ROUTER_INI = os.getenv(
    "ROUTER_INI",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "router.ini"),
)


def _load_config(path: str) -> configparser.ConfigParser:
    cp = configparser.ConfigParser()
    cp.read_dict(_DEFAULTS)
    if os.path.exists(path):
        cp.read(path)
    return cp


def _json_list(cp: configparser.ConfigParser, section: str, option: str) -> list:
    # JSON array keeps exact spacing ("def " must not match "default").
    raw = cp.get(section, option)
    try:
        return [str(k).lower() for k in json.loads(raw)]
    except (ValueError, TypeError):
        return [k.strip().lower() for k in raw.split(",") if k.strip()]


def _band(cp: configparser.ConfigParser, option: str) -> tuple:
    raw = cp.get("discovery", option)
    try:
        low, high = raw.split(":", 1)
        return (float(low), float(high))
    except (ValueError, AttributeError):
        return (0.0, 999.0)


_cfg = _load_config(ROUTER_INI)
TOKEN_THRESHOLD_HEAVY = _cfg.getint("thresholds", "heavy")
TOKEN_THRESHOLD_MEDIUM = _cfg.getint("thresholds", "medium")
CODE_FIRST = _cfg.getboolean("keywords", "code_first")
CODE_KEYWORDS = _json_list(_cfg, "keywords", "code")
HEAVY_KEYWORDS = _json_list(_cfg, "keywords", "heavy")
TIER_FAST = _cfg.get("tiers", "fast")
TIER_MEDIUM = _cfg.get("tiers", "medium")
TIER_HEAVY = _cfg.get("tiers", "heavy")
TIER_NAMES = {TIER_FAST: "fast", TIER_MEDIUM: "medium", TIER_HEAVY: "heavy"}

DISCOVERY_ENABLED = _cfg.getboolean("discovery", "enabled")
DISCOVERY_REFRESH = _cfg.getint("discovery", "refresh_seconds")
DISCOVERY_TIMEOUT = _cfg.getfloat("discovery", "timeout_seconds")
BANDS = {
    "fast": _band(_cfg, "fast_params"),
    "medium": _band(_cfg, "medium_params"),
    "heavy": _band(_cfg, "heavy_params"),
}
BAND_FALLOFF = _cfg.getfloat("discovery", "band_falloff")
CODE_MODELS = _json_list(_cfg, "discovery", "code_models")
VISION_MODELS = _json_list(_cfg, "discovery", "vision_models")
EMBEDDING_MODELS = _json_list(_cfg, "discovery", "embedding_models")
VISION_FAMILIES = _json_list(_cfg, "discovery", "vision_families")
EMBEDDING_FAMILIES = _json_list(_cfg, "discovery", "embedding_families")

W_BAND = _cfg.getfloat("weights", "band_fit")
W_CODE = _cfg.getfloat("weights", "code_match")
W_VISION = _cfg.getfloat("weights", "vision_match")
W_LARGER = _cfg.getfloat("weights", "prefer_larger_heavy")
W_SMALLER = _cfg.getfloat("weights", "prefer_smaller_fast")
W_UNKNOWN = _cfg.getfloat("weights", "unknown_params")
W_OFFTASK = _cfg.getfloat("weights", "offtask_penalty")
TIE_EPSILON = _cfg.getfloat("weights", "tie_epsilon")

HOP_BY_HOP = {"host", "content-length", "connection", "keep-alive",
              "transfer-encoding", "upgrade"}


def _discovery_servers() -> list:
    """Ollama base URLs to poll, in order of preference:
      1. an explicit list in router.ini
      2. MODEL_SERVERS - every configured host, including any not assigned to a
         tier (those are absent from BACKEND_*, so relying on those alone would
         leave such a host permanently undiscovered)
      3. the per-tier BACKEND_* vars, as a fallback for older env files."""
    def _split(value: str) -> list:
        seen, out = set(), []
        for url in (value or "").split(","):
            url = url.strip().rstrip("/")
            if url and url not in seen:
                seen.add(url)
                out.append(url)
        return out

    configured = _cfg.get("discovery", "servers").strip()
    if configured:
        return _split(configured)
    every_host = _split(os.getenv("MODEL_SERVERS", ""))
    if every_host:
        return every_host
    return _split(",".join(os.getenv(env, "") or "" for env in
                           ("BACKEND_QWEN_FAST", "BACKEND_QWEN_MEDIUM",
                            "BACKEND_QWEN_HEAVY")))


SERVERS = _discovery_servers()

# --- live inventory -----------------------------------------------------------
# Replaced wholesale on each refresh, so readers never see a half-built dict.
INVENTORY = {"models": [], "servers": {}, "updated_at": 0.0, "errors": {}}
_rotation = {}


def parse_params_billions(text) -> float:
    """'7.6B' -> 7.6, '134M' -> 0.134. Returns 0.0 when unparseable."""
    if not text:
        return 0.0
    match = re.match(r"^\s*([0-9.]+)\s*([bBmM])\s*$", str(text))
    if not match:
        return 0.0
    try:
        value = float(match.group(1))
    except ValueError:
        return 0.0
    return value if match.group(2).lower() == "b" else value / 1000.0


def params_from_name(name: str) -> float:
    """Fall back to the tag: 'qwen3:14b' -> 14.0, 'phi3:3.8b' -> 3.8."""
    match = re.search(r"[:\-]([0-9.]+)\s*b\b", (name or "").lower())
    if match:
        try:
            return float(match.group(1))
        except ValueError:
            return 0.0
    return 0.0


def _matches_any(haystack: str, needles: list) -> bool:
    return any(n in haystack for n in needles)


def build_entry(server: str, raw: dict) -> dict:
    name = raw.get("name") or raw.get("model") or ""
    details = raw.get("details") or {}
    families = [str(f).lower() for f in (details.get("families") or [])]
    family = str(details.get("family") or "").lower()
    if family and family not in families:
        families.append(family)
    params = parse_params_billions(details.get("parameter_size"))
    if params <= 0:
        params = params_from_name(name)
    lowered = name.lower()
    return {
        "server": server,
        "name": name,
        "params_b": params,
        "quantization": details.get("quantization_level") or "",
        "families": families,
        "size_bytes": raw.get("size") or 0,
        "is_code": _matches_any(lowered, CODE_MODELS),
        "is_vision": (_matches_any(lowered, VISION_MODELS)
                      or any(f in VISION_FAMILIES for f in families)),
        "is_embedding": (_matches_any(lowered, EMBEDDING_MODELS)
                         or any(f in EMBEDDING_FAMILIES for f in families)),
    }


async def fetch_server_models(client: httpx.AsyncClient, server: str) -> tuple:
    try:
        response = await client.get(f"{server}/api/tags", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
    except Exception as exc:  # noqa: BLE001 - any failure means "server is down"
        return server, None, f"{type(exc).__name__}: {exc}"
    entries = [build_entry(server, m) for m in (payload.get("models") or [])]
    return server, [e for e in entries if e["name"]], None


async def refresh_inventory() -> dict:
    """Poll every Ollama target for the models it is currently serving."""
    global INVENTORY
    if not SERVERS:
        INVENTORY = {"models": [], "servers": {}, "updated_at": time.time(),
                     "errors": {"config": "no servers configured"}}
        return INVENTORY
    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(
            *[fetch_server_models(client, s) for s in SERVERS],
            return_exceptions=True,
        )
    models, servers, errors = [], {}, {}
    for result in results:
        if isinstance(result, Exception):
            continue
        server, entries, error = result
        if error is not None:
            servers[server] = {"up": False, "model_count": 0}
            errors[server] = error
            continue
        servers[server] = {"up": True, "model_count": len(entries)}
        models.extend(entries)
    INVENTORY = {"models": models, "servers": servers,
                 "updated_at": time.time(), "errors": errors}
    return INVENTORY


async def _discovery_loop() -> None:
    while True:
        try:
            await refresh_inventory()
        except Exception:  # noqa: BLE001 - never let the loop die
            pass
        await asyncio.sleep(max(5, DISCOVERY_REFRESH))


@app.on_event("startup")
async def _startup() -> None:
    if DISCOVERY_ENABLED and SERVERS:
        await refresh_inventory()
        asyncio.create_task(_discovery_loop())


# --- request analysis ---------------------------------------------------------
def analyze_complexity(prompt: str) -> str:
    """Legacy tier name, kept so the LiteLLM fallback path behaves as before."""
    text_lower = prompt.lower()
    approx_tokens = len(text_lower.split()) * 1.3
    if CODE_FIRST and any(kw in text_lower for kw in CODE_KEYWORDS):
        return TIER_FAST
    if approx_tokens > TOKEN_THRESHOLD_HEAVY or any(kw in text_lower for kw in HEAVY_KEYWORDS):
        return TIER_HEAVY
    if approx_tokens > TOKEN_THRESHOLD_MEDIUM:
        return TIER_MEDIUM
    if not CODE_FIRST and any(kw in text_lower for kw in CODE_KEYWORDS):
        return TIER_FAST
    return TIER_FAST


def classify_request(messages: list) -> dict:
    """Turn the conversation into routing requirements."""
    text_parts, has_image = [], False
    for message in messages:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if isinstance(content, str):
            text_parts.append(content)
        elif isinstance(content, list):
            # OpenAI multimodal form: [{"type":"text"...},{"type":"image_url"...}]
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text" and isinstance(part.get("text"), str):
                    text_parts.append(part["text"])
                elif part.get("type") in ("image_url", "input_image", "image"):
                    has_image = True
    text = " ".join(text_parts)
    lowered = text.lower()
    approx_tokens = len(lowered.split()) * 1.3
    is_code = any(kw in lowered for kw in CODE_KEYWORDS)
    if CODE_FIRST and is_code:
        request_class = "fast"
    elif approx_tokens > TOKEN_THRESHOLD_HEAVY or any(kw in lowered for kw in HEAVY_KEYWORDS):
        request_class = "heavy"
    elif approx_tokens > TOKEN_THRESHOLD_MEDIUM:
        request_class = "medium"
    else:
        request_class = "fast"
    return {"class": request_class, "code": is_code, "vision": has_image,
            "approx_tokens": round(approx_tokens)}


def score_entry(entry: dict, need: dict) -> float:
    """Heuristic fit of one discovered (server, model) pair to one request."""
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    params = entry["params_b"]
    if params <= 0:
        fit = W_UNKNOWN
    elif low <= params <= high:
        fit = 1.0
    else:
        distance = (low - params) if params < low else (params - high)
        fit = max(0.0, 1.0 - (distance / BAND_FALLOFF))
    score = W_BAND * fit

    if need["code"]:
        score += W_CODE if entry["is_code"] else 0.0
    elif entry["is_code"]:
        # A code model on a general request is usable but not preferred.
        score -= W_CODE * W_OFFTASK

    if need["vision"]:
        score += W_VISION if entry["is_vision"] else -W_VISION
    elif entry["is_vision"]:
        # A vision model answers text fine, but it is tuned for something else
        # and is usually the wrong pick when an equal-sized text model exists.
        score -= W_VISION * W_OFFTASK

    # Within a band, bias toward the extreme the class actually wants.
    if params > 0:
        if need["class"] == "heavy":
            score += W_LARGER * min(params / 100.0, 1.0)
        elif need["class"] == "fast":
            score += W_SMALLER * (1.0 - min(params / 100.0, 1.0))
    return score


def rank_candidates(need: dict, inventory: dict = None) -> list:
    """All usable (server, model) pairs, best first."""
    inv = inventory if inventory is not None else INVENTORY
    scored = []
    for entry in inv.get("models", []):
        if entry["is_embedding"]:
            continue  # embedding models cannot serve chat completions
        if not inv.get("servers", {}).get(entry["server"], {}).get("up", True):
            continue
        scored.append((score_entry(entry, need), entry))
    if not scored:
        return []
    scored.sort(key=lambda pair: pair[0], reverse=True)

    # Rotate through candidates that score within tie_epsilon of the best, so
    # the same model on several hosts shares load instead of always hitting the
    # first one. (LiteLLM does this for the static path; direct dispatch needs
    # its own.)
    best_score = scored[0][0]
    tied = [e for s, e in scored if best_score - s <= TIE_EPSILON]
    rest = [e for s, e in scored if best_score - s > TIE_EPSILON]
    if len(tied) > 1:
        key = f"{need['class']}|{need['code']}|{need['vision']}"
        index = _rotation.get(key, 0) % len(tied)
        _rotation[key] = index + 1
        tied = tied[index:] + tied[:index]
    return tied + rest


def find_named_model(model_name: str) -> list:
    """Servers hosting an explicitly requested model, best first."""
    wanted = (model_name or "").strip().lower()
    if not wanted:
        return []
    matches = [e for e in INVENTORY.get("models", [])
               if e["name"].lower() == wanted
               and INVENTORY.get("servers", {}).get(e["server"], {}).get("up", True)]
    if not matches:
        # Allow the bare name without its tag, e.g. "qwen3" -> "qwen3:14b".
        matches = [e for e in INVENTORY.get("models", [])
                   if e["name"].lower().split(":", 1)[0] == wanted
                   and INVENTORY.get("servers", {}).get(e["server"], {}).get("up", True)]
    if len(matches) > 1:
        index = _rotation.get(wanted, 0) % len(matches)
        _rotation[wanted] = index + 1
        matches = matches[index:] + matches[:index]
    return matches


# --- proxying -----------------------------------------------------------------
def _forward_headers(request: Request) -> dict:
    return {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}


async def close_upstream(response: httpx.Response, client: httpx.AsyncClient) -> None:
    await response.aclose()
    await client.aclose()


async def _stream_upstream(method: str, url: str, headers: dict,
                           json_body=None, content=None,
                           extra_headers: dict = None) -> StreamingResponse:
    client = httpx.AsyncClient(timeout=300.0)
    try:
        upstream_request = client.build_request(
            method, url, headers=headers, json=json_body, content=content
        )
        upstream_response = await client.send(upstream_request, stream=True)
    except httpx.RequestError as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Router core disconnect: {exc}") from exc
    response_headers = dict(upstream_response.headers)
    if extra_headers:
        response_headers.update(extra_headers)
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=response_headers,
        background=BackgroundTask(close_upstream, upstream_response, client),
    )


async def _dispatch_direct(candidates: list, body: dict, headers: dict,
                           need: dict) -> StreamingResponse:
    """Send to the best candidate, falling forward through the ranked list on
    connection errors or upstream 5xx. Retrying is only safe before any body has
    been streamed, which is why the status is checked before returning."""
    last_error = None
    for position, entry in enumerate(candidates):
        attempt_body = dict(body)
        attempt_body["model"] = entry["name"]
        client = httpx.AsyncClient(timeout=300.0)
        url = f"{entry['server']}/v1/chat/completions"
        try:
            upstream_request = client.build_request(
                "POST", url, headers=headers, json=attempt_body
            )
            upstream_response = await client.send(upstream_request, stream=True)
        except httpx.RequestError as exc:
            await client.aclose()
            last_error = f"{entry['server']}: {exc}"
            continue
        if upstream_response.status_code >= 500 and position < len(candidates) - 1:
            await upstream_response.aclose()
            await client.aclose()
            last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
            continue
        response_headers = dict(upstream_response.headers)
        response_headers.update({
            "X-Router-Model": entry["name"],
            "X-Router-Server": entry["server"],
            "X-Router-Class": need["class"],
            "X-Router-Mode": "discovery",
            "X-Router-Candidates": str(len(candidates)),
        })
        return StreamingResponse(
            upstream_response.aiter_raw(),
            status_code=upstream_response.status_code,
            headers=response_headers,
            background=BackgroundTask(close_upstream, upstream_response, client),
        )
    raise HTTPException(status_code=502,
                        detail=f"No usable Ollama target. Last error: {last_error}")


@app.get("/healthz")
async def healthz():
    return JSONResponse({"status": "ok"})


@app.get("/routing/inventory")
async def routing_inventory():
    """What each Ollama target is currently serving, as the router sees it."""
    return JSONResponse({
        "enabled": DISCOVERY_ENABLED,
        "servers": SERVERS,
        "updated_at": INVENTORY.get("updated_at"),
        "age_seconds": round(time.time() - (INVENTORY.get("updated_at") or 0), 1),
        "server_status": INVENTORY.get("servers", {}),
        "errors": INVENTORY.get("errors", {}),
        "models": INVENTORY.get("models", []),
    })


@app.post("/routing/refresh")
async def routing_refresh():
    await refresh_inventory()
    return await routing_inventory()


@app.post("/routing/explain")
async def routing_explain(request: Request):
    """Show the routing decision for a prompt without executing it."""
    try:
        body = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    messages = body.get("messages")
    if not messages and isinstance(body.get("prompt"), str):
        messages = [{"role": "user", "content": body["prompt"]}]
    need = classify_request(messages or [])
    candidates = rank_candidates(need)
    return JSONResponse({
        "request": need,
        "legacy_tier": analyze_complexity(
            " ".join(m.get("content", "") for m in (messages or [])
                     if isinstance(m, dict) and isinstance(m.get("content"), str))
        ),
        "chosen": ({"model": candidates[0]["name"], "server": candidates[0]["server"]}
                   if candidates else None),
        "candidates": [
            {"model": e["name"], "server": e["server"], "params_b": e["params_b"],
             "score": round(score_entry(e, need), 4)}
            for e in candidates[:10]
        ],
    })


@app.post("/v1/chat/completions")
async def route_chat_completion(request: Request):
    try:
        body = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    messages = body.get("messages", [])
    headers = _forward_headers(request)
    requested = str(body.get("model") or "").strip()

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        need = classify_request(messages)
        # An explicitly requested real model is honoured; tier aliases and
        # "auto" mean "decide for me".
        candidates = []
        if requested and requested.lower() not in ("auto", "") \
                and requested not in TIER_NAMES:
            candidates = find_named_model(requested)
        if not candidates:
            if requested in TIER_NAMES:
                need = dict(need, **{"class": TIER_NAMES[requested]})
            candidates = rank_candidates(need)
        if candidates:
            return await _dispatch_direct(candidates, body, headers, need)

    # Fallback: the original static path through LiteLLM, which keeps its own
    # latency routing and cross-tier fallbacks.
    full_prompt_context = " ".join(
        msg.get("content", "") for msg in messages
        if isinstance(msg, dict) and isinstance(msg.get("content"), str)
    )
    body["model"] = analyze_complexity(full_prompt_context)
    return await _stream_upstream(
        "POST", LITELLM_URL, headers, json_body=body,
        extra_headers={"X-Router-Mode": "litellm", "X-Router-Model": body["model"]},
    )


@app.get("/v1/models")
async def list_models(request: Request):
    """Advertise the discovered models plus the virtual auto-routing entries, so
    Open WebUI's picker is meaningful. Falls back to LiteLLM's list."""
    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        seen, data = set(), []
        for alias in ("auto", TIER_FAST, TIER_MEDIUM, TIER_HEAVY):
            if alias not in seen:
                seen.add(alias)
                data.append({"id": alias, "object": "model", "owned_by": "router"})
        for entry in INVENTORY["models"]:
            if entry["is_embedding"] or entry["name"] in seen:
                continue
            seen.add(entry["name"])
            data.append({"id": entry["name"], "object": "model", "owned_by": "ollama"})
        return JSONResponse({"object": "list", "data": data})
    return await _stream_upstream("GET", f"{LITELLM_BASE}/v1/models",
                                  _forward_headers(request))


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def proxy_openai(path: str, request: Request):
    # Transparent passthrough for all other OpenAI routes (embeddings, etc.).
    url = f"{LITELLM_BASE}/v1/{path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"
    raw = await request.body()
    return await _stream_upstream(
        request.method, url, _forward_headers(request), content=raw or None
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
PYEOF

# --- monitor.py (probes each Ollama backend directly) ---
cat > "${REPO_DIR}/services/ollama-monitor/monitor.py" <<'PYEOF'
import configparser
import logging
import os
import socket
import time
import httpx

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

MATTERMOST_WEBHOOK_URL = os.getenv("MATTERMOST_WEBHOOK_URL")
MATTERMOST_USER = os.getenv("MATTERMOST_MONITOR_USER", "OllamaMonitor")
MATTERMOST_CHANNEL = os.getenv("MATTERMOST_CHANNEL", "ollama-monitor")
MATTERMOST_VERIFY_TLS = os.getenv("MATTERMOST_VERIFY_TLS", "true").lower() == "true"

# Polling behaviour comes from monitor.ini (version controlled); environment
# variables still win, so an operator can override without a commit.
_DEFAULTS = {"polling": {"interval_seconds": "15", "timeout_seconds": "5",
                         "health_path": "/api/tags"}}
MONITOR_INI = os.getenv(
    "MONITOR_INI",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "monitor.ini"),
)
_cfg = configparser.ConfigParser()
_cfg.read_dict(_DEFAULTS)
if os.path.exists(MONITOR_INI):
    _cfg.read(MONITOR_INI)

CHECK_INTERVAL = int(os.getenv("MONITOR_INTERVAL_SECONDS",
                               _cfg.get("polling", "interval_seconds")))
CHECK_TIMEOUT = float(os.getenv("MONITOR_TIMEOUT_SECONDS",
                                _cfg.get("polling", "timeout_seconds")))
HEALTH_PATH = os.getenv("MONITOR_HEALTH_PATH", _cfg.get("polling", "health_path"))

# --- keep-alive maintenance ---------------------------------------------------
# Ollama's OpenAI-compatible endpoint does not support a keep_alive field, so a
# model driven through it uses the server default and unloads after ~5 minutes
# idle. Pinning is therefore done against the NATIVE /api/chat endpoint, which
# does honour keep_alive: an empty-message request loads the model and (re)sets
# its unload timer without generating anything.
KEEP_ALIVE = (os.getenv("OLLAMA_KEEP_ALIVE", "") or "").strip()
KEEP_ALIVE_MODE = _cfg.get("keep_alive", "enabled", fallback="auto").strip().lower()
KEEP_ALIVE_INTERVAL = int(os.getenv("KEEP_ALIVE_REFRESH_SECONDS",
                                    _cfg.get("keep_alive", "refresh_seconds",
                                             fallback="240")))
KEEP_ALIVE_TIMEOUT = float(_cfg.get("keep_alive", "timeout_seconds", fallback="120"))
if KEEP_ALIVE_MODE == "auto":
    KEEP_ALIVE_ENABLED = bool(KEEP_ALIVE)
else:
    KEEP_ALIVE_ENABLED = KEEP_ALIVE_MODE in ("true", "yes", "1", "on")

# tier -> model tag, so we pin only the models this system actually fronts
# rather than everything a host happens to have pulled (which would thrash VRAM).
TIER_MODELS = {
    "qwen-fast": (os.getenv("MODEL_FAST", "") or "").strip(),
    "qwen-medium": (os.getenv("MODEL_MEDIUM", "") or "").strip(),
    "qwen-heavy": (os.getenv("MODEL_HEAVY", "") or "").strip(),
}


def _keep_alive_value():
    """Ollama accepts -1/0 or a number as an integer, durations as a string."""
    try:
        return int(KEEP_ALIVE)
    except (TypeError, ValueError):
        return KEEP_ALIVE


def pin_model(url: str, model: str) -> bool:
    """Load `model` on `url` and set its unload timer, generating nothing."""
    payload = {"model": model, "messages": [], "keep_alive": _keep_alive_value()}
    try:
        with httpx.Client() as client:
            resp = client.post(f"{url.rstrip('/')}/api/chat", json=payload,
                               timeout=KEEP_ALIVE_TIMEOUT)
            resp.raise_for_status()
        return True
    except Exception as exc:
        logging.warning("keep-alive: %s on %s failed: %s", model, url, exc)
        return False


def refresh_keep_alive(health: dict) -> None:
    """Pin each tier's model on every healthy host serving that tier."""
    pinned = 0
    for tier, urls in BACKENDS.items():
        model = TIER_MODELS.get(tier, "")
        if not model:
            continue
        for url in urls:
            if not health.get(url, False):
                continue          # don't wait on a host we already know is down
            if pin_model(url, model):
                pinned += 1
    if pinned:
        logging.info("keep-alive: refreshed %d model(s) with keep_alive=%s",
                     pinned, KEEP_ALIVE)

# tier -> [Ollama backend base URLs]. A tier may have several servers (LiteLLM
# load-balances across them), so each env var is a comma-separated list and every
# individual server is tracked and alerted on separately.
def _url_list(value: str) -> list:
    return [u.strip().rstrip("/") for u in (value or "").split(",") if u.strip()]


BACKENDS = {
    "qwen-fast": _url_list(os.getenv("BACKEND_QWEN_FAST", "")),
    "qwen-medium": _url_list(os.getenv("BACKEND_QWEN_MEDIUM", "")),
    "qwen-heavy": _url_list(os.getenv("BACKEND_QWEN_HEAVY", "")),
}
BACKENDS = {tier: urls for tier, urls in BACKENDS.items() if urls}
# One state per (tier, url) pair: the same host can back more than one tier.
server_states = {(tier, url): True for tier, urls in BACKENDS.items() for url in urls}


def post_mattermost(message: str, emoji: str = ":warning:") -> bool:
    """Post to the configured channel. Returns True on a 2xx delivery."""
    if not MATTERMOST_WEBHOOK_URL:
        logging.info("(message suppressed, no webhook configured) %s", message)
        return False
    payload = {
        "username": MATTERMOST_USER,
        "icon_emoji": emoji,
        "text": message,
    }
    # An incoming webhook is bound to a channel, but posting the channel handle
    # explicitly makes the target unambiguous (and overrides the default when
    # the webhook allows it).
    if MATTERMOST_CHANNEL:
        payload["channel"] = MATTERMOST_CHANNEL
    try:
        with httpx.Client(verify=MATTERMOST_VERIFY_TLS) as client:
            resp = client.post(MATTERMOST_WEBHOOK_URL, json=payload, timeout=5.0)
        if resp.status_code >= 400:
            logging.error("Mattermost rejected message (HTTP %s): %s",
                          resp.status_code, resp.text.strip())
            return False
        return True
    except Exception as exc:
        logging.error("Failed message delivery: %s", exc)
        return False


def send_startup_notice() -> None:
    host = socket.gethostname()
    tiers = ", ".join(
        f"{tier} -> {', '.join(urls)}" for tier, urls in BACKENDS.items()
    ) or "none configured"
    message = (
        f"Ollama monitor online on `{host}` — health alerting is active. "
        f"Watching tiers: {tiers}. "
        f"(This is a startup test message confirming webhook access to "
        f"#{MATTERMOST_CHANNEL}.)"
    )
    if not MATTERMOST_WEBHOOK_URL:
        logging.warning("No MATTERMOST_WEBHOOK_URL set; skipping startup notice.")
        return
    if post_mattermost(message, emoji=":white_check_mark:"):
        logging.info("Startup notice delivered to #%s.", MATTERMOST_CHANNEL)
    else:
        logging.error(
            "Startup notice to #%s FAILED — check MATTERMOST_WEBHOOK_URL, the "
            "webhook's channel permissions, and MATTERMOST_VERIFY_TLS.",
            MATTERMOST_CHANNEL,
        )


def backend_healthy(url: str) -> bool:
    try:
        with httpx.Client() as client:
            resp = client.get(f"{url.rstrip('/')}{HEALTH_PATH}", timeout=CHECK_TIMEOUT)
            resp.raise_for_status()
        return True
    except Exception as exc:
        logging.debug("Backend %s unhealthy: %s", url, exc)
        return False


def run_health_checks() -> None:
    if not BACKENDS:
        logging.error("No BACKEND_* URLs configured; nothing to monitor.")
        return
    summary = ", ".join(f"{t}({len(u)})" for t, u in BACKENDS.items())
    logging.info("Monitoring daemon initialized for tiers: %s", summary)
    if KEEP_ALIVE_ENABLED:
        logging.info("keep-alive maintainer active: keep_alive=%s every %ds",
                     KEEP_ALIVE, KEEP_ALIVE_INTERVAL)
    elif KEEP_ALIVE:
        logging.info("keep-alive configured (%s) but the maintainer is disabled.",
                     KEEP_ALIVE)
    else:
        logging.info("No OLLAMA_KEEP_ALIVE set; each server's own setting applies.")
    # Confirm on startup that the webhook works and has channel permission.
    send_startup_notice()
    last_pin = 0.0
    while True:
        # Probe each distinct host once per cycle, even when several tiers
        # share it, then apply the result to every tier that uses it.
        health = {}
        for url in {u for urls in BACKENDS.values() for u in urls}:
            health[url] = backend_healthy(url)
        for tier, urls in BACKENDS.items():
            for url in urls:
                key = (tier, url)
                was_healthy = server_states[key]
                now_healthy = health[url]
                if was_healthy and not now_healthy:
                    post_mattermost(
                        f"Infrastructure Alert: `{url}` serving tier `{tier}` is unavailable."
                    )
                    server_states[key] = False
                elif not was_healthy and now_healthy:
                    post_mattermost(
                        f"Recovery Notice: `{url}` serving tier `{tier}` is operational again.",
                        emoji=":white_check_mark:",
                    )
                    server_states[key] = True
        if KEEP_ALIVE_ENABLED and (time.monotonic() - last_pin) >= KEEP_ALIVE_INTERVAL:
            refresh_keep_alive(health)
            last_pin = time.monotonic()
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    run_health_checks()
PYEOF

# --- litellm_config.yaml ---
# One model_list entry per (tier, server) pair. A tier with several servers gets
# several deployments under the same model_name, which is what lets the
# latency-based router load-balance across them.
{
  echo "model_list:"
  emit_tier_deployments() {           # $1=model_name  $2=model tag  $3=indices
    local name="$1" tag="$2" indices="$3" idx
    for idx in $indices; do
      printf '  - model_name: %s\n' "$name"
      printf '    litellm_params:\n'
      printf '      model: ollama/%s\n' "$tag"
      printf '      api_base: %s\n' "${MODEL_SERVERS[$idx]}"
      # LiteLLM talks to Ollama's NATIVE api, which does honour keep_alive
      # (merged upstream in litellm PR #7079).
      [[ -n "$OLLAMA_KEEP_ALIVE" ]] && printf '      keep_alive: %s\n' "$OLLAMA_KEEP_ALIVE"
    done
  }
  emit_tier_deployments qwen-fast   "$MODEL_FAST"   "$TIER_FAST_IDX"
  emit_tier_deployments qwen-medium "$MODEL_MEDIUM" "$TIER_MEDIUM_IDX"
  emit_tier_deployments qwen-heavy  "$MODEL_HEAVY"  "$TIER_HEAVY_IDX"
  cat <<'YAMLEOF'
router_settings:
  routing_strategy: latency-based-routing
  fallbacks:
    - qwen-heavy: ["qwen-medium", "qwen-fast"]
    - qwen-medium: ["qwen-heavy", "qwen-fast"]
    - qwen-fast: ["qwen-medium", "qwen-heavy"]
YAMLEOF
} > "${REPO_DIR}/services/litellm-proxy/litellm_config.yaml"

# --- Open WebUI environment ---
# Open WebUI talks to the *complexity router* (port 8000) as an OpenAI-
# compatible backend, so chats are smart-routed by prompt complexity. The
# router proxies /v1/models through to LiteLLM so the model list still
# populates. NOTE: because the router chooses the tier per request, the model
# picked in the UI is overridden — the dropdown reflects what LiteLLM exposes,
# not what actually served the reply. To let the UI pick the model manually
# instead, point OPENAI_API_BASE_URLS at http://127.0.0.1:4000/v1 (LiteLLM
# direct). Router/LiteLLM have no master key, so the API key is a placeholder.
cat > "${REPO_DIR}/env/openwebui.env" <<EOF
HOST=0.0.0.0
PORT=${OPENWEBUI_PORT}
DATA_DIR=/app/openwebui/data
OPENAI_API_BASE_URLS=http://127.0.0.1:8000/v1
OPENAI_API_KEYS=sk-router-local
ENABLE_OPENAI_API=true
ENABLE_OLLAMA_API=false
WEBUI_AUTH=true
ANONYMIZED_TELEMETRY=false
DO_NOT_TRACK=true
SCARF_NO_ANALYTICS=true
HF_HOME=/app/openwebui/cache
SENTENCE_TRANSFORMERS_HOME=/app/openwebui/cache
EOF


# --- per-service requirements (each venv is built from these, so dependency
#     pins are version controlled per service) ---
cat > "${REPO_DIR}/services/ollama-router/requirements.txt" <<'REQEOF'
fastapi==0.116.1
uvicorn==0.35.0
httpx==0.28.1
python-dotenv==1.1.1
REQEOF

cat > "${REPO_DIR}/services/litellm-proxy/requirements.txt" <<'REQEOF'
litellm==1.75.5.post1
REQEOF

cat > "${REPO_DIR}/services/ollama-monitor/requirements.txt" <<'REQEOF'
httpx==0.28.1
REQEOF

cat > "${REPO_DIR}/services/open-webui/requirements.txt" <<EOF
open-webui==${OPENWEBUI_VERSION}
EOF

# --- routing tunables moved out of code into version-controlled ini ---
cat > "${REPO_DIR}/services/ollama-router/router.ini" <<'INIEOF'
# Complexity-routing tunables. Edit + commit to change routing behaviour
# without touching router.py. Applied at provisioning time.
[thresholds]
# Approximate token counts (words * 1.3) above which a tier is chosen.
heavy = 800
medium = 250

[keywords]
# JSON arrays, so exact spacing is preserved — a trailing space is significant
# ("def " must not match "default"). Matched as case-insensitive substrings.
# code_first=true means a code match wins regardless of prompt length.
code_first = true
code = ["def ", "fn ", "function", "class ", "import ", "sql", "script", "code", "bug", "error", "compile"]
heavy = ["analyze", "evaluate", "optimise", "optimize", "architecture", "mathematics", "calculate", "summarise this article"]

[tiers]
fast = qwen-fast
medium = qwen-medium
heavy = qwen-heavy

[discovery]
# Poll each Ollama target's /api/tags for the models it is actually serving,
# and route from that live inventory instead of the static tier mapping.
# Set enabled = false to use only the LiteLLM tier path.
enabled = true
refresh_seconds = 60
timeout_seconds = 5
# Targets to poll. Blank derives them from the BACKEND_* entries in the env
# file, which already list every configured server.
servers =
# Parameter-count bands (billions) each request class prefers: low:high
fast_params = 0:9
medium_params = 9:20
heavy_params = 20:999
# Score decay per billion parameters outside the preferred band.
band_falloff = 12
# Name substrings / model families used to classify what a model is for.
code_models = ["coder", "code", "starcoder", "codellama", "deepseek-coder", "codegemma", "codestral"]
vision_models = ["llava", "vision", "-vl", "minicpm-v", "moondream", "bakllava"]
embedding_models = ["embed", "embedding", "bge-", "gte-", "nomic-embed", "mxbai-embed"]
vision_families = ["clip", "mllama", "llava"]
embedding_families = ["bert", "nomic-bert"]

[weights]
# Relative importance of each heuristic when scoring a (server, model) pair.
band_fit = 1.0
code_match = 0.6
vision_match = 1.5
prefer_larger_heavy = 0.15
prefer_smaller_fast = 0.15
unknown_params = 0.3
# Penalty fraction when a specialised model serves an off-task request
# (a vision model answering plain text, a code model answering prose).
offtask_penalty = 0.25
# Candidates within this score of the best are rotated through, so the same
# model on several hosts shares load.
tie_epsilon = 0.05
INIEOF

cat > "${REPO_DIR}/services/ollama-monitor/monitor.ini" <<'INIEOF'
# Health-monitor tunables. Backend URLs and the webhook stay in env/router.env;
# only polling behaviour lives here.
[polling]
interval_seconds = 15
timeout_seconds = 5
# Path appended to each backend URL for the health probe.
health_path = /api/tags

[keep_alive]
# Ollama's OpenAI-compatible endpoint (/v1/chat/completions) does not accept a
# keep_alive field at all — it is absent from the supported-parameter list — so
# a model served through it falls back to the server default and unloads after
# ~5 minutes idle. The router dispatches through that endpoint, so keeping a
# model resident has to be done out of band: this maintainer periodically calls
# the NATIVE /api/chat with an empty message list, which loads the model (or
# refreshes its timer) with the requested keep_alive.
#
# enabled=auto -> run only when OLLAMA_KEEP_ALIVE is set to a non-empty value.
enabled = auto
# Seconds between refreshes. Must be shorter than the keep-alive itself; the
# default sits just inside Ollama's 5-minute default.
refresh_seconds = 240
# Seconds to wait for the load call (a cold model can take a while).
timeout_seconds = 120
INIEOF

# --- install/apply-config.sh: runs INSIDE the container, copies the cloned
#     config into place. Version controlled, so the layout is auditable. ---
cat > "${REPO_DIR}/install/apply-config.sh" <<'APPLYEOF'
#!/usr/bin/env bash
# Copy configuration from the cloned repo into its runtime locations.
# Invoked by the installer during provisioning; safe to re-run by hand after a
# `git pull` in the repo directory, followed by: systemctl daemon-reload &&
# systemctl restart litellm-proxy ollama-router ollama-monitor open-webui
set -euo pipefail
REPO_DIR="${1:-/app/config-repo}"
ROUTER_DIR="${2:-/app/router}"
OPENWEBUI_DIR="${3:-/app/openwebui}"
UNIT_DIR="${4:-/etc/systemd/system}"

install -d -m 0755 "$ROUTER_DIR" "$OPENWEBUI_DIR"

# Application code + per-service config
install -m 0644 "${REPO_DIR}/services/ollama-router/router.py"   "${ROUTER_DIR}/router.py"
install -m 0644 "${REPO_DIR}/services/ollama-router/router.ini"  "${ROUTER_DIR}/router.ini"
install -m 0644 "${REPO_DIR}/services/ollama-monitor/monitor.py"  "${ROUTER_DIR}/monitor.py"
install -m 0644 "${REPO_DIR}/services/ollama-monitor/monitor.ini" "${ROUTER_DIR}/monitor.ini"
install -m 0644 "${REPO_DIR}/services/litellm-proxy/litellm_config.yaml" \
                "${ROUTER_DIR}/litellm_config.yaml"

# Environment files (contain secrets -> root:ollama-router 0640)
install -m 0640 -o root -g ollama-router "${REPO_DIR}/env/router.env"    "${ROUTER_DIR}/.env"
install -m 0640 -o root -g ollama-router "${REPO_DIR}/env/openwebui.env" "${OPENWEBUI_DIR}/.env"

# systemd units
for unit in "${REPO_DIR}"/services/*/*.service; do
  install -m 0644 "$unit" "${UNIT_DIR}/$(basename "$unit")"
done

# Seeding through the Gitea contents API does not preserve the executable bit,
# so restore it on the repo's own scripts.
chmod 0755 "${REPO_DIR}"/install/*.sh 2>/dev/null || true

# Expose the server-management tool on PATH. A symlink (not a copy) means a
# `git pull` in the repo updates the command too.
if [ -f "${REPO_DIR}/install/manage-model-servers.sh" ]; then
  ln -sfn "${REPO_DIR}/install/manage-model-servers.sh" /usr/local/bin/manage-model-servers
fi

echo "Configuration applied from ${REPO_DIR}."
APPLYEOF
chmod 0755 "${REPO_DIR}/install/apply-config.sh"

# --- install/manage-model-servers.sh: day-2 tool for changing the server list
#     without re-running this installer. Lives in the repo so it is versioned
#     alongside the config it edits. ---
cat > "${REPO_DIR}/install/manage-model-servers.sh" <<'MANAGEEOF'
#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# manage-model-servers.sh — add / remove / re-tier the Ollama model servers of
# a running ollama-smart-router container, without re-running the installer.
#
# Run it from either place, as root:
#   * inside the container:   ./manage-model-servers.sh list
#   * on the Proxmox host:    ./manage-model-servers.sh list
# When run on the host, it locates the container that actually holds the config
# (by testing for the file, not by guessing a name) and re-execs itself there.
# Set CT_ID to skip the search.
#
# It edits the version-controlled config in $CONFIG_REPO_DIR, regenerates
# litellm_config.yaml from the tier assignments, then (optionally) applies the
# result and restarts the affected services. Servers are tracked by URL, never
# by index, so removing one never silently re-points another.
# ==============================================================================

REPO_DIR="${CONFIG_REPO_DIR:-/app/config-repo}"
ROUTER_DIR="${ROUTER_DIR:-/app/router}"
ENV_FILE="${REPO_DIR}/env/router.env"
LITELLM_YAML="${REPO_DIR}/services/litellm-proxy/litellm_config.yaml"
ROUTER_INI="${REPO_DIR}/services/ollama-router/router.ini"
OPENWEBUI_REQ="${REPO_DIR}/services/open-webui/requirements.txt"
OPENWEBUI_DIR="${OPENWEBUI_DIR:-/app/openwebui}"
APPLY_SCRIPT="${REPO_DIR}/install/apply-config.sh"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
MODEL_SERVER_MAX="${MODEL_SERVER_MAX:-20}"
MODEL_SERVER_MIN="${MODEL_SERVER_MIN:-1}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:8000}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
SERVICES=(litellm-proxy ollama-router ollama-monitor open-webui)

declare -A TIER_MODEL_OVERRIDE=()   # tier            -> model tag
declare -A PAIR_MODEL_OVERRIDE=()   # "tier|server"   -> model tag

CHANGED=false      # set by a command that actually wrote something
DRY_RUN=false
NO_PROBE=false
AUTO_APPLY=false
AUTO_COMMIT=false
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Usage: manage-model-servers.sh <command> [options]

Commands:
  list                       Show configured servers and their tier assignments
  status                     As list, plus a live reachability probe of each host
  discover                   Ask the router to re-poll and print the live model inventory
  add <addr> [addr...]       Add server(s). Address may be IP, host:port or a URL
  remove <addr> [addr...]    Remove server(s) by address (or by list number)
  set-tier <tier> <addr...>  Replace a tier's servers (tier: fast|medium|heavy)
  set-model <tier> <model>   Set the model for EVERY server in a tier
  set-server-model <tier> <server> <model>
                             Set the model for ONE server within a tier
  set-keepalive <value>      Set how long Ollama keeps models resident
                             (e.g. 30m, 2h, -1 = never unload, blank = use the
                             server's own OLLAMA_KEEP_ALIVE)
  models                     List every model available across the configured hosts
  apply                      Apply the current config and restart services
  commit [message]           Commit and push the config repo to Gitea
  set-token [token]          Store/replace the Gitea deploy token used for
                             pushing (prompts if not given, then verifies it)
  set-webui-version [v]      Show, or pin, the Open WebUI version (use 'latest').
                             Checks the version exists and that the venv's
                             Python satisfies its Requires-Python

Options:
  --tier <t[,t...]>          With 'add': also assign the new server(s) to these tiers
  --apply                    Apply + restart services after the change
  --commit[=msg]             Commit and push the change after applying
  --no-probe                 Skip the reachability check when adding, and the
                             model-availability check when setting a model
  --dry-run                  Show what would change; write nothing
  --yes, -y                  Do not prompt for confirmation
  -h, --help                 This help

Examples:
  manage-model-servers.sh add 10.0.0.55 --tier heavy --apply
  manage-model-servers.sh add ollama7.lan:11434 --tier fast,medium --apply --commit
  manage-model-servers.sh remove 10.0.0.52 --apply
  manage-model-servers.sh set-tier heavy 10.0.0.54 10.0.0.55 --apply
  manage-model-servers.sh models
  manage-model-servers.sh set-model heavy qwen3:32b --apply --commit
  manage-model-servers.sh set-server-model heavy 10.0.0.54 llama3.3:70b --apply
  manage-model-servers.sh set-keepalive 2h --apply
  manage-model-servers.sh set-webui-version latest --apply
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

# --- address handling ---------------------------------------------------------
valid_hostname_or_ip() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

valid_addr() {
  local raw="$1" port
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    [[ "$raw" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/.*)?$ ]]
    return $?
  fi
  if [[ "$raw" == *:* ]]; then
    port="${raw##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    valid_hostname_or_ip "${raw%:*}"
    return $?
  fi
  valid_hostname_or_ip "$raw"
}

# Same normalisation the installer uses, so entries stay comparable.
normalize_addr() {
  local raw="${1%/}"
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    printf '%s\n' "$raw"
  elif [[ "$raw" == *:* ]]; then
    printf 'http://%s\n' "$raw"
  else
    printf 'http://%s:%s\n' "$raw" "$OLLAMA_PORT"
  fi
}

# --- env file access ----------------------------------------------------------
env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || die "env file not found: ${ENV_FILE}"
  awk -v k="$key" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE"
}

env_set() {
  local key="$1" value="$2" tmp
  $DRY_RUN && { echo "  [dry-run] ${key}=${value}"; return 0; }
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" -F= '{ if ($1==k) print k "=" v; else print }' "$ENV_FILE" > "$tmp"
  else
    cp "$ENV_FILE" "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  # Copy content rather than mv, so the file keeps its 0640 root:ollama-router
  # ownership and mode instead of inheriting the temp file's.
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

# NOTE for callers: this dies on an unknown tier, but a `die` inside $(...)
# only kills the subshell. Assignment sites must therefore append `|| exit 1`,
# or an invalid tier silently yields an empty key and corrupts router.env.
tier_env_key() {
  case "$1" in
    fast)   echo "BACKEND_QWEN_FAST" ;;
    medium) echo "BACKEND_QWEN_MEDIUM" ;;
    heavy)  echo "BACKEND_QWEN_HEAVY" ;;
    *) die "unknown tier '$1' (expected fast, medium or heavy)" ;;
  esac
}

# Tier model_name comes from router.ini so custom names are honoured.
tier_model_name() {
  local key="$1" val=""
  if [[ -f "$ROUTER_INI" ]]; then
    val="$(awk -v k="$key" '/^\[tiers\]/{f=1;next} /^\[/{f=0} f && $1==k {print $3; exit}' "$ROUTER_INI")"
  fi
  printf '%s' "${val:-qwen-${key}}"
}

# NOTE the trailing newline: without it the final element has no line
# terminator, and `while read` silently drops it.
csv_to_lines() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d'; }
lines_to_csv() { paste -sd, - ; }

get_servers()  { csv_to_lines "$(env_get MODEL_SERVERS)"; }
# Returns 1 rather than dying on an unknown tier: this runs inside command
# substitutions, where `exit` would kill only the subshell and the caller would
# see an empty (successful-looking) list. Callers that must abort validate the
# tier separately with `tier_env_key "$tier" >/dev/null`.
get_tier() {
  local __k
  __k="$(tier_env_key "$1")" || return 1
  csv_to_lines "$(env_get "$__k")"
}

contains_line() {  # $1 = needle, stdin = haystack
  local needle="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$needle" ]] && return 0
  done
  return 1
}

# --- reachability -------------------------------------------------------------
probe_server() {  # prints model count, or "-" when unreachable
  local url="$1" body
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${url}/api/tags" 2>/dev/null)"; then
    printf '%s' "$body" | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin).get("models") or []))
except Exception: print("?")' 2>/dev/null || printf '?'
  else
    printf '%s' "-"
  fi
}

# Names of the models a host currently serves, one per line.
server_models() {
  curl -fsS --max-time "$PROBE_TIMEOUT" "${1}/api/tags" 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for entry in (data.get("models") or []):
    name = entry.get("name") or ""
    if name:
        print(name)
'
}

# 0 = present, 1 = absent, 2 = host unreachable.
model_present_on() {
  local url="$1" tag="$2" names
  names="$(server_models "$url")" || return 2
  [[ -n "$names" ]] || return 2
  printf '%s\n' "$names" | grep -Fxq "$tag" && return 0
  # Ollama treats a bare name as ":latest", so accept that spelling too.
  if [[ "$tag" != *:* ]]; then
    printf '%s\n' "$names" | grep -Fxq "${tag}:latest" && return 0
  fi
  return 1
}

# The ollama tag configured for one specific (model_name, api_base) deployment.
# Deployments are per (tier, server), so each pair can carry its own model.
current_pair_tag() {
  local want_name="$1" want_base="$2"
  [[ -f "$LITELLM_YAML" ]] || return 0
  awk -v want="$want_name" -v base="$want_base" '
    /^[[:space:]]*-[[:space:]]*model_name:/ {
      n = $0; sub(/.*model_name:[[:space:]]*/, "", n); sub(/[[:space:]]*$/, "", n)
      tag = ""; next
    }
    /^[[:space:]]*model:[[:space:]]*ollama\// {
      tag = $0; sub(/.*model:[[:space:]]*ollama\//, "", tag); sub(/[[:space:]]*(#.*)?$/, "", tag); next
    }
    /^[[:space:]]*api_base:[[:space:]]*/ {
      b = $0; sub(/.*api_base:[[:space:]]*/, "", b); sub(/[[:space:]]*$/, "", b)
      if (n == want && b == base && tag != "") { print tag; exit }
    }' "$LITELLM_YAML"
}

# The ollama tag currently configured for a LiteLLM model_name (first match).
current_tier_tag() {
  local want="$1"
  [[ -f "$LITELLM_YAML" ]] || return 0
  awk -v want="$want" '
    /^[[:space:]]*-[[:space:]]*model_name:/ {
      n=$0; sub(/.*model_name:[[:space:]]*/,"",n); sub(/[[:space:]]*$/,"",n); next
    }
    /^[[:space:]]*model:[[:space:]]*ollama\// && n==want {
      t=$0; sub(/.*model:[[:space:]]*ollama\//,"",t); sub(/[[:space:]]*(#.*)?$/,"",t); print t; exit
    }' "$LITELLM_YAML"
}

# --- rendering ----------------------------------------------------------------
tiers_of() {  # which tiers reference this URL
  local url="$1" tier out=""
  for tier in fast medium heavy; do
    if get_tier "$tier" | contains_line "$url"; then
      out="${out}${out:+,}${tier}"
    fi
  done
  printf '%s' "${out:-—}"
}

cmd_list() {
  local probe="${1:-false}" i=0 url count
  echo "Configured model servers (${ENV_FILE}):"
  printf '  %-3s %-34s %-18s' "#" "ADDRESS" "TIERS"
  $probe && printf ' %-8s' "MODELS"
  echo
  while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -n "$url" ]] || continue
    i=$((i + 1))
    printf '  %-3s %-34s %-18s' "$i" "$url" "$(tiers_of "$url")"
    if $probe; then
      count="$(probe_server "$url")"
      if [[ "$count" == "-" ]]; then printf ' %-8s' "DOWN"; else printf ' %-8s' "$count"; fi
    fi
    echo
  done < <(get_servers)
  (( i == 0 )) && echo "  (none configured)"
  echo
  local ka; ka="$(env_get OLLAMA_KEEP_ALIVE)"
  # No apostrophe inside the ${...:-default}: bash re-parses that word and a
  # lone quote there opens a quote context, breaking everything after it.
  echo "Keep-alive: ${ka:-<server default (OLLAMA_KEEP_ALIVE on each host)>}"
  echo
  # One row per (tier, server) deployment, because each pair can carry its own
  # model — a single MODEL column per tier would hide that.
  echo "Tier assignments (one row per server):"
  printf '  %-7s %-14s %-34s %s\n' "TIER" "ALIAS" "SERVER" "MODEL"
  local tier alias tag url any
  for tier in fast medium heavy; do
    alias="$(tier_model_name "$tier")"
    any=false
    while IFS= read -r url || [[ -n "$url" ]]; do
      [[ -n "$url" ]] || continue
      any=true
      tag="$(current_pair_tag "$alias" "$url")"
      [[ -n "$tag" ]] || tag="$(current_tier_tag "$alias")"
      printf '  %-7s %-14s %-34s %s\n' "$tier" "$alias" "$url" "ollama/${tag:-?}"
    done < <(get_tier "$tier")
    $any || printf '  %-7s %-14s %-34s %s\n' "$tier" "$alias" "<no servers>" "-"
  done
}

cmd_discover() {
  local body rc=0
  echo "Asking the router to re-poll every configured host..."
  body="$(curl -fsS -X POST "${ROUTER_URL}/routing/refresh" 2>/dev/null)" || rc=$?
  if (( rc != 0 )) || [[ -z "$body" ]]; then
    note "Could not reach the router at ${ROUTER_URL} (curl exit ${rc})."
    note "  Check it is running:  systemctl status ollama-router"
    note "  Or point elsewhere:   ROUTER_URL=http://host:8000 $0 discover"
    return 1
  fi
  # NOTE: %-formatting, not f-strings. This code is embedded in a shell-quoted
  # string, and a quote inside an f-string expression cannot be escaped without
  # producing invalid Python.
  printf '%s' "$body" | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print("  the router replied, but the response did not parse: %s" % exc)
    raise SystemExit(1)

status = data.get("server_status") or {}
print("  polled %d host(s), inventory age %ss" % (len(status), data.get("age_seconds")))
for host in sorted(status):
    info = status[host] or {}
    state = "up" if info.get("up") else "DOWN"
    print("    %-34s %-5s models=%s" % (host, state, info.get("model_count", 0)))

errors = data.get("errors") or {}
for host in sorted(errors):
    print("    ! %s: %s" % (host, str(errors[host])[:70]))

models = data.get("models") or []
if models:
    print("  live inventory:")
    for entry in sorted(models, key=lambda m: (m.get("server", ""), m.get("name", ""))):
        flags = ",".join(
            label for label, on in (
                ("code", entry.get("is_code")),
                ("vision", entry.get("is_vision")),
                ("embed", entry.get("is_embedding")),
            ) if on
        )
        print("    %-34s %-24s %6sB %s" % (
            entry.get("server", ""), entry.get("name", ""),
            entry.get("params_b", 0), flags))
else:
    print("  (no models discovered — are the hosts reachable from the container?)")
'
}

# --- mutations ----------------------------------------------------------------
regenerate_litellm() {
  local tmp tier name tag tier_tag url tail_block keep_alive
  keep_alive="$(env_get OLLAMA_KEEP_ALIVE)"
  $DRY_RUN && { echo "  [dry-run] would regenerate ${LITELLM_YAML}"; return 0; }
  [[ -f "$LITELLM_YAML" ]] || die "missing ${LITELLM_YAML}"
  tmp="$(mktemp)"
  {
    echo "model_list:"
    for tier in fast medium heavy; do
      name="$(tier_model_name "$tier")"
      tier_tag="${TIER_MODEL_OVERRIDE[$tier]:-}"
      [[ -n "$tier_tag" ]] || tier_tag="$(current_tier_tag "$name")"
      [[ -n "$tier_tag" ]] || tier_tag="$name"
      while IFS= read -r url || [[ -n "$url" ]]; do
        [[ -n "$url" ]] || continue
        # Resolve the model for THIS (tier, server) pair, most specific first:
        #   1. an explicit set-server-model for this pair
        #   2. an explicit set-model for the whole tier
        #   3. whatever this exact pair already had  <- without this, a server
        #      with its own model would be silently overwritten by the tier's
        #      first tag on the next add/remove
        #   4. the tier tag
        tag="${PAIR_MODEL_OVERRIDE[${tier}|${url}]:-}"
        if [[ -z "$tag" && -z "${TIER_MODEL_OVERRIDE[$tier]:-}" ]]; then
          tag="$(current_pair_tag "$name" "$url")"
        fi
        [[ -n "$tag" ]] || tag="$tier_tag"
        printf '  - model_name: %s\n' "$name"
        printf '    litellm_params:\n'
        printf '      model: ollama/%s\n' "$tag"
        printf '      api_base: %s\n' "$url"
        [[ -n "$keep_alive" ]] && printf '      keep_alive: %s\n' "$keep_alive"
      done < <(get_tier "$tier")
    done
    # Carry the existing router_settings block through verbatim so hand edits
    # to the strategy or fallbacks survive a regeneration.
    tail_block="$(awk '/^router_settings:/{f=1} f' "$LITELLM_YAML")"
    if [[ -n "$tail_block" ]]; then
      printf '%s\n' "$tail_block"
    else
      cat <<'YAMLEOF'
router_settings:
  routing_strategy: latency-based-routing
  fallbacks:
    - qwen-heavy: ["qwen-medium", "qwen-fast"]
    - qwen-medium: ["qwen-heavy", "qwen-fast"]
    - qwen-fast: ["qwen-medium", "qwen-heavy"]
YAMLEOF
    fi
  } > "$tmp"
  cat "$tmp" > "$LITELLM_YAML"
  rm -f "$tmp"
  echo "  regenerated $(basename "$LITELLM_YAML")"
  CHANGED=true
}

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN && return 0
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

cmd_add() {
  local -a wanted=("$@")
  local addr url current count tier
  (( ${#wanted[@]} > 0 )) || die "add: no address given"
  current="$(get_servers | lines_to_csv)"
  count="$(get_servers | grep -c . || true)"

  local -a to_add=()
  for addr in "${wanted[@]}"; do
    valid_addr "$addr" || die "not a valid address: '${addr}'"
    url="$(normalize_addr "$addr")"
    if get_servers | contains_line "$url"; then
      note "  already configured, skipping: ${url}"
      continue
    fi
    if printf '%s\n' "${to_add[@]:-}" | contains_line "$url"; then
      note "  duplicate in arguments, skipping: ${url}"
      continue
    fi
    if ! $NO_PROBE; then
      if [[ "$(probe_server "$url")" == "-" ]]; then
        die "${url} is not reachable (no /api/tags). Use --no-probe to add anyway."
      fi
    fi
    to_add+=("$url")
  done
  (( ${#to_add[@]} > 0 )) || { note "Nothing to add."; return 0; }

  if (( count + ${#to_add[@]} > MODEL_SERVER_MAX )); then
    die "that would make $(( count + ${#to_add[@]} )) servers; the maximum is ${MODEL_SERVER_MAX}."
  fi

  echo "Adding:"
  printf '  + %s\n' "${to_add[@]}"
  confirm "Apply this change?" || { note "Aborted."; return 1; }

  local new_list="$current"
  for url in "${to_add[@]}"; do
    new_list="${new_list}${new_list:+,}${url}"
  done
  env_set MODEL_SERVERS "$new_list"

  if [[ -n "${TIER_ARG:-}" ]]; then
    for tier in $(csv_to_lines "$TIER_ARG"); do
      local key existing
      key="$(tier_env_key "$tier")" || exit 1
      existing="$(get_tier "$tier" | lines_to_csv)"
      for url in "${to_add[@]}"; do
        existing="${existing}${existing:+,}${url}"
      done
      env_set "$key" "$existing"
      echo "  assigned to tier '${tier}'"
    done
  else
    note "  NOTE: not assigned to any tier. Discovery will still poll and can"
    note "        select it, but LiteLLM's static path will not use it."
  fi
  regenerate_litellm
}

cmd_remove() {
  local -a wanted=("$@")
  local addr url target remaining tier key kept
  (( ${#wanted[@]} > 0 )) || die "remove: no address given"

  local -a to_remove=()
  for addr in "${wanted[@]}"; do
    # Accept a list number as shown by 'list'.
    if [[ "$addr" =~ ^[0-9]+$ ]]; then
      target="$(get_servers | sed -n "${addr}p")"
      [[ -n "$target" ]] || die "no server number ${addr} in the list"
    else
      valid_addr "$addr" || die "not a valid address: '${addr}'"
      target="$(normalize_addr "$addr")"
    fi
    if ! get_servers | contains_line "$target"; then
      note "  not configured, skipping: ${target}"
      continue
    fi
    to_remove+=("$target")
  done
  (( ${#to_remove[@]} > 0 )) || { note "Nothing to remove."; return 0; }

  local count remaining_count
  count="$(get_servers | grep -c . || true)"
  remaining_count=$(( count - ${#to_remove[@]} ))
  if (( remaining_count < MODEL_SERVER_MIN )); then
    die "that would leave ${remaining_count} servers; at least ${MODEL_SERVER_MIN} is required."
  fi

  echo "Removing:"
  printf '  - %s\n' "${to_remove[@]}"
  confirm "Apply this change?" || { note "Aborted."; return 1; }

  remaining="$(get_servers | grep -vxF -f <(printf '%s\n' "${to_remove[@]}") | lines_to_csv)"
  env_set MODEL_SERVERS "$remaining"

  for tier in fast medium heavy; do
    key="$(tier_env_key "$tier")" || exit 1
    kept="$(get_tier "$tier" | grep -vxF -f <(printf '%s\n' "${to_remove[@]}") | lines_to_csv || true)"
    if [[ "$kept" != "$(get_tier "$tier" | lines_to_csv)" ]]; then
      env_set "$key" "$kept"
      [[ -z "$kept" ]] && note "  WARNING: tier '${tier}' now has no servers on the LiteLLM path."
    fi
  done
  regenerate_litellm
}

cmd_set_tier() {
  local tier="${1:-}"; shift || true
  local -a wanted=("$@")
  local addr url key list
  [[ -n "$tier" ]] || die "set-tier: no tier given"
  key="$(tier_env_key "$tier")" || exit 1
  (( ${#wanted[@]} > 0 )) || die "set-tier: no servers given"

  list=""
  for addr in "${wanted[@]}"; do
    if [[ "$addr" =~ ^[0-9]+$ ]]; then
      url="$(get_servers | sed -n "${addr}p")"
      [[ -n "$url" ]] || die "no server number ${addr} in the list"
    else
      valid_addr "$addr" || die "not a valid address: '${addr}'"
      url="$(normalize_addr "$addr")"
    fi
    get_servers | contains_line "$url" || die "${url} is not a configured server; add it first."
    list="${list}${list:+,}${url}"
  done

  echo "Setting tier '${tier}' to:"
  printf '  %s\n' "$list"
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  env_set "$key" "$list"
  regenerate_litellm
}

valid_keep_alive() {
  [[ -z "$1" ]] && return 0
  [[ "$1" == "-1" || "$1" == "0" ]] && return 0
  [[ "$1" =~ ^[0-9]+$ ]] && return 0
  [[ "$1" =~ ^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$ ]]
}

# Resolve an address (or list number) to a configured server URL.
resolve_server_arg() {
  local arg="$1" url
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    url="$(get_servers | sed -n "${arg}p")"
    [[ -n "$url" ]] || die "no server number ${arg} in the list"
  else
    valid_addr "$arg" || die "not a valid address: '${arg}'"
    url="$(normalize_addr "$arg")"
  fi
  get_servers | contains_line "$url" || die "${url} is not a configured server; add it first."
  printf '%s\n' "$url"
}

cmd_set_server_model() {
  local tier="${1:-}" server="${2:-}" tag="${3:-}"
  local url alias current rc=0
  [[ -n "$tier" ]]   || die "set-server-model: no tier given"
  tier_env_key "$tier" >/dev/null
  [[ -n "$server" ]] || die "set-server-model: no server given"
  [[ -n "$tag" ]]    || die "set-server-model: no model given (e.g. qwen3:32b)"
  [[ "$tag" != */* ]] || die "give the Ollama tag only, without the 'ollama/' prefix"

  url="$(resolve_server_arg "$server")"
  get_tier "$tier" | contains_line "$url" \
    || die "${url} is not in tier '${tier}'. Add it with: $0 set-tier ${tier} ... "

  alias="$(tier_model_name "$tier")"
  current="$(current_pair_tag "$alias" "$url")"
  [[ -n "$current" ]] || current="$(current_tier_tag "$alias")"
  if [[ "$current" == "$tag" ]]; then
    note "${url} already serves '${tag}' for tier '${tier}'. Nothing to do."
    return 0
  fi

  if ! $NO_PROBE; then
    rc=0; model_present_on "$url" "$tag" || rc=$?
    case "$rc" in
      1) note "  '${tag}' is not present on ${url}."
         note "  Pull it there (ollama pull ${tag}), see '$0 models', or use --no-probe."
         die "model '${tag}' is not available on ${url}" ;;
      2) note "  WARNING: ${url} is unreachable; cannot verify '${tag}' is present." ;;
    esac
  fi

  echo "Tier '${tier}' on ${url}:"
  echo "  ollama/${current:-<unset>}  ->  ollama/${tag}"
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  PAIR_MODEL_OVERRIDE["${tier}|${url}"]="$tag"
  regenerate_litellm
}

# --- Open WebUI version -------------------------------------------------------
openwebui_current_version() {
  [[ -f "$OPENWEBUI_REQ" ]] || return 0
  awk -F'==' '/^[[:space:]]*open-webui[[:space:]]*==/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' \
    "$OPENWEBUI_REQ"
}

openwebui_installed_version() {
  local py="${OPENWEBUI_DIR}/venv/bin/python"
  [[ -x "$py" ]] || return 0
  "$py" -c 'import importlib.metadata as m
try: print(m.version("open-webui"))
except Exception: pass' 2>/dev/null
}

# Ask PyPI for the newest release and the Requires-Python of a given version.
# Prints "<latest>\t<requires_python_for_requested>" (blank field when unknown).
pypi_openwebui_info() {
  local want="${1:-}"
  python3 - "$want" <<'PYEOF' 2>/dev/null
import json, re, sys, urllib.request

want = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with urllib.request.urlopen("https://pypi.org/pypi/open-webui/json", timeout=20) as r:
        data = json.load(r)
except Exception:
    sys.exit(1)

def sort_key(v):
    return [int(x) for x in re.findall(r"\d+", v)[:3]] or [0]

stable = [v for v in data.get("releases", {}) if not re.search(r"(dev|rc|a\d|b\d)", v)]
stable.sort(key=sort_key)
latest = data.get("info", {}).get("version", stable[-1] if stable else "")

target = want if want and want != "latest" else latest
files = data.get("releases", {}).get(target) or []
requires = files[0].get("requires_python") if files else None
if not files:
    requires = ""          # version does not exist
    target = ""
print("%s\t%s\t%s" % (latest, target, requires or ""))
PYEOF
}

# Does the Open WebUI venv's interpreter satisfy a Requires-Python spec?
openwebui_python_ok() {
  local spec="$1" py="${OPENWEBUI_DIR}/venv/bin/python"
  [[ -n "$spec" ]] || return 0          # nothing declared: nothing to check
  [[ -x "$py" ]] || return 0            # no venv yet (fresh install): skip
  "$py" - "$spec" <<'PYEOF' 2>/dev/null
import sys
spec = sys.argv[1]
version = ".".join(str(p) for p in sys.version_info[:3])
try:
    from pip._vendor.packaging.specifiers import SpecifierSet
    sys.exit(0 if SpecifierSet(spec).contains(version, prereleases=True) else 1)
except Exception:
    pass
# Fallback: compare only the >= lower bound and < upper bound on major.minor.
import re
cur = sys.version_info[:2]
for clause in spec.split(","):
    clause = clause.strip()
    m = re.match(r"^(>=|<=|<|>|==)\s*(\d+)\.(\d+)", clause)
    if not m:
        continue
    op, major, minor = m.group(1), int(m.group(2)), int(m.group(3))
    other = (major, minor)
    if op == ">=" and not cur >= other: sys.exit(1)
    if op == ">"  and not cur >  other: sys.exit(1)
    if op == "<=" and not cur <= other: sys.exit(1)
    if op == "<"  and not cur <  other: sys.exit(1)
sys.exit(0)
PYEOF
}

cmd_set_webui_version() {
  local want="${1:-}" info latest target requires current installed pyver

  current="$(openwebui_current_version)"
  installed="$(openwebui_installed_version)"
  pyver="$("${OPENWEBUI_DIR}/venv/bin/python" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo "?")"

  info="$(pypi_openwebui_info "$want")" || {
    note "Could not reach PyPI to check versions."
    [[ -n "$want" ]] || return 1
    info=$'\t'"${want}"$'\t'
  }
  latest="$(printf '%s' "$info" | cut -f1)"
  target="$(printf '%s' "$info" | cut -f2)"
  requires="$(printf '%s' "$info" | cut -f3)"

  if [[ -z "$want" ]]; then
    echo "Open WebUI version:"
    printf '  pinned in repo : %s\n' "${current:-<none>}"
    printf '  installed now  : %s\n' "${installed:-<unknown>}"
    printf '  latest on PyPI : %s\n' "${latest:-<unknown>}"
    printf '  venv python    : %s\n' "$pyver"
    echo
    echo "Change it with:  $0 set-webui-version <version|latest> --apply"
    return 0
  fi

  [[ -n "$target" ]] || die "open-webui ${want} does not exist on PyPI"
  if [[ "$target" == "$current" ]]; then
    note "Already pinned to ${target}. Nothing to do."
    return 0
  fi

  # The whole dual-interpreter design exists because of this constraint, so
  # check it before writing anything rather than failing during pip install.
  if ! openwebui_python_ok "$requires"; then
    note "  open-webui ${target} requires Python '${requires}',"
    note "  but the Open WebUI venv is Python ${pyver}."
    note "  Rebuild that venv with a compatible interpreter first, or pick"
    note "  another version:  $0 set-webui-version <version>"
    die "incompatible Python for open-webui ${target}"
  fi

  echo "Open WebUI: ${current:-<none>}  ->  ${target}"
  [[ -n "$requires" ]] && echo "  requires Python ${requires} (venv is ${pyver})"
  [[ "$target" != "$latest" ]] && note "  note: ${latest} is the latest release."
  confirm "Apply this change?" || { note "Aborted."; return 1; }

  if $DRY_RUN; then
    echo "  [dry-run] would pin open-webui==${target} in ${OPENWEBUI_REQ}"
  else
    printf 'open-webui==%s\n' "$target" > "$OPENWEBUI_REQ"
    echo "  pinned open-webui==${target}"
  fi
  CHANGED=true
  note "  The new version is installed when you apply:  $0 apply"
  note "  (that step downloads a large dependency tree and takes a while)"
}

cmd_set_keepalive() {
  local value="${1-}" current
  valid_keep_alive "$value" || die "not a valid keep-alive: '${value}' (try 30m, 2h, -1, or blank)"
  current="$(env_get OLLAMA_KEEP_ALIVE)"
  if [[ "$current" == "$value" ]]; then
    note "Keep-alive is already '${value:-<server default>}'. Nothing to do."
    return 0
  fi
  echo "Keep-alive: ${current:-<server default>}  ->  ${value:-<server default>}"
  if [[ -z "$value" ]]; then
    note "  Blank: nothing will be sent, so each server's own OLLAMA_KEEP_ALIVE applies"
    note "  and the monitor's keep-alive maintainer switches off."
  fi
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  env_set OLLAMA_KEEP_ALIVE "$value"
  regenerate_litellm
  note "  NOTE: Ollama's OpenAI-compatible endpoint ignores keep_alive, so models"
  note "        served through the router are kept resident by the monitor, which"
  note "        re-pins them through the native API. Restart it to pick this up."
}

cmd_models() {
  local url count=0 tmp
  tmp="$(mktemp)"
  while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -n "$url" ]] || continue
    count=$((count + 1))
    if ! server_models "$url" | sed "s|\$|\t${url}|" >> "$tmp"; then
      note "  (unreachable: ${url})"
    fi
  done < <(get_servers)
  echo "Models available across ${count} configured host(s):"
  if [[ ! -s "$tmp" ]]; then
    echo "  (none — no host answered /api/tags)"
    rm -f "$tmp"; return 0
  fi
  printf '  %-30s %s\n' "MODEL" "HOSTS"
  sort "$tmp" | awk -F'\t' '
    { if ($1 != prev) { if (prev != "") printf "  %-30s %s\n", prev, hosts
                        prev=$1; hosts=$2 }
      else hosts = hosts ", " $2 }
    END { if (prev != "") printf "  %-30s %s\n", prev, hosts }'
  rm -f "$tmp"
  echo
  echo "Set one for a tier with:  $0 set-model <fast|medium|heavy> <model>"
}

cmd_set_model() {
  local tier="${1:-}" tag="${2:-}"
  local url current alias missing="" unreachable="" rc
  [[ -n "$tier" ]] || die "set-model: no tier given"
  tier_env_key "$tier" >/dev/null          # validates the tier name
  [[ -n "$tag" ]] || die "set-model: no model given (e.g. qwen3:32b)"
  [[ "$tag" != */* ]] || die "give the Ollama tag only, without the 'ollama/' prefix"

  alias="$(tier_model_name "$tier")"
  current="$(current_tier_tag "$alias")"
  if [[ "$current" == "$tag" ]]; then
    note "Tier '${tier}' already serves '${tag}'. Nothing to do."
    return 0
  fi

  local -a servers=()
  while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -n "$url" ]] && servers+=("$url")
  done < <(get_tier "$tier")
  if (( ${#servers[@]} == 0 )); then
    note "  WARNING: tier '${tier}' has no servers assigned; setting the tag anyway."
  fi

  # Verify the tag actually exists on the hosts that will be asked to serve it.
  if ! $NO_PROBE && (( ${#servers[@]} > 0 )); then
    for url in "${servers[@]}"; do
      rc=0; model_present_on "$url" "$tag" || rc=$?
      case "$rc" in
        1) missing="${missing}${missing:+, }${url}" ;;
        2) unreachable="${unreachable}${unreachable:+, }${url}" ;;
      esac
    done
    [[ -n "$unreachable" ]] && note "  WARNING: could not check ${unreachable} (unreachable)."
    if [[ -n "$missing" ]]; then
      note "  '${tag}' is not present on: ${missing}"
      note "  Pull it there first (ollama pull ${tag}), pick another with '$0 models',"
      note "  or re-run with --no-probe to set it anyway."
      die "model '${tag}' is not available on every server in tier '${tier}'"
    fi
  fi

  echo "Tier '${tier}' (${alias}) — ALL servers in this tier:"
  echo "  ollama/${current:-<unset>}  ->  ollama/${tag}"
  local n_servers
  n_servers="$(get_tier "$tier" | grep -c . || true)"
  if (( n_servers > 1 )); then
    note "  This overwrites the model on all ${n_servers} servers in the tier."
    note "  Use set-server-model to change just one."
  fi
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  TIER_MODEL_OVERRIDE["$tier"]="$tag"
  regenerate_litellm
  note "  NOTE: the tier's model tag governs the LiteLLM fallback path. In"
  note "        discovery mode the router picks a model from the live inventory,"
  note "        so this does not by itself change discovery-mode routing."
}

# Install the pinned Open WebUI into its venv, CPU-only by default.
#
# This container never has a GPU, so the CUDA build of torch is ~4.5 GB of
# wheels that can never be used. Installing CPU-only torch FIRST leaves pip with
# its torch requirement already satisfied, so the CUDA stack is never pulled.
openwebui_install() {
  local pip="${OPENWEBUI_DIR}/venv/bin/pip"
  local cpu_only orphans
  [[ -x "$pip" ]] || { note "  no Open WebUI venv at ${OPENWEBUI_DIR}/venv"; return 1; }

  cpu_only="$(env_get TORCH_CPU_ONLY)"
  [[ -n "$cpu_only" ]] || cpu_only="true"

  if [[ "$cpu_only" == "true" ]]; then
    echo "  installing CPU-only torch first (no GPU in this container)..."
    # Deliberately the FIRST step: if the CPU index is unreachable this fails
    # while the venv is still intact, rather than after uninstalling anything.
    if "$pip" install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch; then
      # Any nvidia-*/triton wheels left from an earlier CUDA install are now
      # orphans. Removing them is what actually reclaims the disk.
      orphans="$("$pip" list --format=freeze 2>/dev/null |
                 sed 's/==.*//' | grep -E '^(nvidia-|triton$)' || true)"
      if [[ -n "$orphans" ]]; then
        echo "  removing orphaned CUDA packages:"
        printf '    %s\n' $orphans
        # shellcheck disable=SC2086
        "$pip" uninstall -y $orphans >/dev/null 2>&1 || \
          note "    (some could not be removed; harmless, just disk)"
      fi
    else
      note "  WARNING: CPU-only torch install failed — is download.pytorch.org"
      note "           reachable from this container? Continuing with the"
      note "           default build, which pulls ~4.5 GB of unusable CUDA wheels."
    fi
  fi

  "$pip" install --no-cache-dir -r "$OPENWEBUI_REQ"
}

cmd_apply() {
  local svc
  if $DRY_RUN; then echo "  [dry-run] would apply config and restart services"; return 0; fi
  # Checked with -f, not -x: seeding through the Gitea contents API does not
  # preserve the executable bit, and we invoke it via `bash` anyway.
  [[ -f "$APPLY_SCRIPT" ]] || die "apply script not found: ${APPLY_SCRIPT}"
  echo "Applying configuration..."
  bash "$APPLY_SCRIPT" "$REPO_DIR"

  # If the pinned Open WebUI version no longer matches what is installed,
  # bring the venv in line before restarting the unit.
  local want_v have_v
  want_v="$(openwebui_current_version)"
  have_v="$(openwebui_installed_version)"
  if [[ -n "$want_v" && "$want_v" != "$have_v" ]]; then
    echo "Open WebUI ${have_v:-<none>} -> ${want_v}; installing (this takes a while)..."
    if openwebui_install; then
      echo "  installed open-webui ${want_v}"
    else
      note "  WARNING: install failed; the service keeps running ${have_v:-its current version}."
    fi
  fi
  # Files are already in place at this point. If systemd isn't running (a
  # chroot, a container without PID 1, a rescue shell), say so plainly rather
  # than dying with "Failed to connect to bus" after a partial job.
  if ! systemctl daemon-reload 2>/dev/null; then
    note "WARNING: systemd is not available here — configuration was copied into"
    note "         place, but no service was restarted. Restart them manually:"
    note "           systemctl restart ${SERVICES[*]}"
    return 0
  fi
  echo "Restarting services..."
  for svc in "${SERVICES[@]}"; do
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
      if systemctl restart "${svc}.service" 2>/dev/null; then
        echo "  restarted ${svc}"
      else
        note "  WARNING: failed to restart ${svc} (check: systemctl status ${svc})"
      fi
    fi
  done
}

# Push using the Gitea deploy token from router.env.
#
# Gitea does not accept an account password for git-over-HTTP (it wants a token
# or an app password), and provisioning deliberately deletes the stored git
# credentials once the clone is done. Without this, git falls back to prompting
# for a username/password, which then fails against Gitea.
git_push_authenticated() {
  local remote branch token user host cred sslverify out rc=0 hostpart scheme
  remote="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" || remote=""
  if [[ -z "$remote" ]]; then
    note "  No 'origin' remote is configured; the commit stays local."
    return 1
  fi
  branch="$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo main)"

  # A non-HTTP remote (ssh) carries its own auth; just let git do its thing.
  if [[ "$remote" != http://* && "$remote" != https://* ]]; then
    if out="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" push origin "HEAD:${branch}" 2>&1)"; then
      return 0
    fi
    note "  push failed: ${out}"
    return 1
  fi

  token="$(env_get GITEA_DEPLOY_TOKEN)"
  if [[ -z "$token" ]]; then
    note "  No GITEA_DEPLOY_TOKEN in ${ENV_FILE}."
    note "  Gitea needs a token for git over HTTP — an account password will be"
    note "  rejected. Store one with:  $0 set-token"
    return 1
  fi

  # Username: take it from the remote if it carries one, else the configured
  # Gitea user. Gitea accepts the token as the password for any valid user.
  hostpart="${remote#*://}"
  user="$(env_get GITEA_ADMIN_USER)"
  if [[ "$hostpart" == *@* ]]; then
    user="${hostpart%%@*}"
    hostpart="${hostpart#*@}"
  fi
  [[ -n "$user" ]] || user="git"
  host="${hostpart%%/*}"
  # The credential entry must carry the SAME scheme as the remote: git will not
  # match an https:// credential against an http:// request, and the push then
  # fails as if no credential existed at all.
  scheme="${remote%%://*}"

  sslverify="true"
  [[ "$(env_get GITEA_VERIFY_TLS)" == "true" ]] || sslverify="false"

  # Credentials go in a 0600 file, never on the command line where they would
  # show up in `ps`.
  cred="$(mktemp)"
  chmod 600 "$cred"
  printf '%s://%s:%s@%s\n' "$scheme" "$user" "$token" "$host" > "$cred"

  # GIT_TERMINAL_PROMPT/GIT_ASKPASS guarantee a hard failure instead of a
  # hanging password prompt if the token is wrong.
  out="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
        git -C "$REPO_DIR" \
            -c credential.helper="store --file=${cred}" \
            -c http.sslVerify="$sslverify" \
            push origin "HEAD:${branch}" 2>&1)" || rc=$?
  rm -f "$cred"

  if (( rc == 0 )); then
    return 0
  fi
  # Show the real error rather than swallowing it, with the token redacted.
  note "  push failed (git exit ${rc}):"
  printf '%s\n' "$out" | sed "s|${token}|<token>|g; s/^/    /" >&2
  case "$out" in
    *"401"*|*"Authentication failed"*|*"invalid credentials"*)
      note "  The token was rejected. Check it has write access to this repo:"
      note "    $0 set-token" ;;
    *"403"*)
      note "  Authenticated, but not authorised to push to this repository." ;;
    *"certificate"*|*"SSL"*|*"TLS"*)
      note "  TLS problem. GITEA_VERIFY_TLS in router.env is '${sslverify}'." ;;
  esac
  return 1
}

cmd_set_token() {
  local token="${1:-}" confirm_token=""
  if [[ -z "$token" ]]; then
    if [[ "$ASSUME_YES" == "true" ]]; then
      die "set-token: no token given"
    fi
    read -r -s -p "Gitea deploy token: " token; echo
    read -r -s -p "Confirm token: " confirm_token; echo
    [[ "$token" == "$confirm_token" ]] || die "tokens did not match"
  fi
  [[ -n "$token" ]] || die "set-token: empty token"
  env_set GITEA_DEPLOY_TOKEN "$token"
  echo "Stored the deploy token in ${ENV_FILE}."
  note "  Verifying against $(env_get GITEA_SERVER_URL) ..."
  local base api code
  base="$(env_get GITEA_SERVER_URL)"; base="${base%/}"
  api="${base}/api/v1/user"
  local -a copts=(--location)
  [[ "$(env_get GITEA_VERIFY_TLS)" == "true" ]] || copts+=(--insecure)
  code="$(curl -o /dev/null -sS -w '%{http_code}' "${copts[@]}" \
          -H "Authorization: token ${token}" "$api" 2>/dev/null || echo "000")"
  case "$code" in
    200) note "  Token accepted by Gitea." ;;
    401) note "  WARNING: Gitea rejected the token (401)." ;;
    000) note "  WARNING: could not reach ${base} to verify." ;;
    *)   note "  WARNING: unexpected response from Gitea (HTTP ${code})." ;;
  esac
  CHANGED=true
}

cmd_commit() {
  local message="${1:-Update model server list}"
  if $DRY_RUN; then echo "  [dry-run] would commit: ${message}"; return 0; fi
  command -v git >/dev/null 2>&1 || die "git is not installed"
  [[ -d "${REPO_DIR}/.git" ]] || {
    note "${REPO_DIR} is not a git repository (config was installed locally)."
    note "Nothing to commit or push."
    return 0
  }
  git -C "$REPO_DIR" add -A
  if git -C "$REPO_DIR" diff --cached --quiet; then
    note "Nothing to commit."
  else
    git -C "$REPO_DIR" -c user.name="${GIT_AUTHOR_NAME:-ollama-smart-router}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-router@localhost}" \
        commit -q -m "$message"
    echo "Committed: ${message}"
  fi
  if git_push_authenticated; then
    echo "Pushed to Gitea."
  else
    note "  The commit is saved locally in ${REPO_DIR}; push it when resolved."
  fi
}

# --- running from the Proxmox host -------------------------------------------
# The config this script edits lives inside the container. When invoked on the
# PVE host instead, find the container that actually holds it and re-exec there,
# rather than failing with a path the host was never going to have.

# Container IDs that are running, parsed by header position (pct list column
# order is not guaranteed).
running_ct_ids() {
  pct list 2>/dev/null | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        h = tolower($i)
        if (h == "vmid") ci_id = i
        else if (h == "status") ci_status = i
      }
      if (!ci_id) ci_id = 1
      if (!ci_status) ci_status = 2
      next
    }
    NF >= ci_status && tolower($(ci_status)) == "running" { print $(ci_id) }'
}

ct_name_of() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2; exit}'
}

# The container holding the config is identified by actually having the file,
# not by guessing from its name.
find_router_ct() {
  local id
  if [[ -n "${CT_ID:-}" ]]; then
    printf '%s\n' "$CT_ID"
    return 0
  fi
  for id in $(running_ct_ids); do
    if pct exec "$id" -- test -f "$ENV_FILE" >/dev/null 2>&1; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

# Path to use for the in-container invocation, preferring the installed copies.
in_container_command() {
  local id="$1"
  if pct exec "$id" -- test -x /usr/local/bin/manage-model-servers >/dev/null 2>&1; then
    printf '%s\n' "/usr/local/bin/manage-model-servers"
  elif pct exec "$id" -- test -f "${REPO_DIR}/install/manage-model-servers.sh" >/dev/null 2>&1; then
    printf '%s\n' "${REPO_DIR}/install/manage-model-servers.sh"
  else
    printf '%s\n' ""
  fi
}

ensure_config_or_forward() {
  [[ -f "$ENV_FILE" ]] && return 0

  if ! command -v pct >/dev/null 2>&1; then
    die "config not found at ${ENV_FILE}. Run this inside the router container, or set CONFIG_REPO_DIR."
  fi

  # On a Proxmox host: locate the container and hand off to it.
  local id cmd
  if id="$(find_router_ct)"; then
    cmd="$(in_container_command "$id")"
    if [[ -n "$cmd" ]]; then
      note "Config lives inside container ${id} ($(ct_name_of "$id")); running there."
      exec pct exec "$id" -- "$cmd" "${ORIG_ARGS[@]}"
    fi
    # The container has the config but not the script: push this copy in.
    note "Container ${id} has the config but no installed tool; using this copy."
    pct push "$id" "$0" /tmp/manage-model-servers.sh --perms 0755 >/dev/null 2>&1 \
      || die "could not copy this script into container ${id}"
    exec pct exec "$id" -- bash /tmp/manage-model-servers.sh "${ORIG_ARGS[@]}"
  fi

  # Could not find it — say what was actually checked.
  echo "ERROR: ${ENV_FILE} does not exist here." >&2
  echo >&2
  echo "This tool edits configuration that lives INSIDE the router container," >&2
  echo "and you appear to be on the Proxmox host." >&2
  echo >&2
  local ids id2
  ids="$(running_ct_ids)"
  if [[ -n "$ids" ]]; then
    echo "Running containers checked (none had ${ENV_FILE}):" >&2
    for id2 in $ids; do
      printf '  %-6s %s\n' "$id2" "$(ct_name_of "$id2")" >&2
    done
    echo >&2
    echo "If the router container is one of these, run:" >&2
    echo "  CT_ID=<id> $0 ${ORIG_ARGS[*]}" >&2
  else
    echo "No running containers were found (pct list)." >&2
  fi
  echo >&2
  echo "Or run it inside the container directly:" >&2
  echo "  pct exec <CTID> -- manage-model-servers ${ORIG_ARGS[*]}" >&2
  echo >&2
  echo "If your config lives elsewhere, set CONFIG_REPO_DIR." >&2
  exit 1
}

# --- argument parsing ---------------------------------------------------------
ORIG_ARGS=("$@")     # kept verbatim so the hand-off re-runs the same request
COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || { usage; exit 1; }
shift || true
case "$COMMAND" in -h|--help|help) usage; exit 0 ;; esac

TIER_ARG=""
COMMIT_MSG=""
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --tier)      TIER_ARG="${2:-}"; shift 2 ;;
    --tier=*)    TIER_ARG="${1#*=}"; shift ;;
    --apply)     AUTO_APPLY=true; shift ;;
    --commit)    AUTO_COMMIT=true; shift ;;
    --commit=*)  AUTO_COMMIT=true; COMMIT_MSG="${1#*=}"; shift ;;
    --no-probe)  NO_PROBE=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -y|--yes)    ASSUME_YES=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    --*)         die "unknown option: $1" ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done

for tier in $(csv_to_lines "${TIER_ARG:-}"); do
  tier_env_key "$tier" >/dev/null
done

ensure_config_or_forward
$DRY_RUN && note "(dry run — no files will be written)"

case "$COMMAND" in
  list)     cmd_list false ;;
  status)   cmd_list true ;;
  discover) cmd_discover ;;
  add)      cmd_add "${ARGS[@]:-}" ;;
  remove)   cmd_remove "${ARGS[@]:-}" ;;
  set-tier) cmd_set_tier "${ARGS[@]:-}" ;;
  set-model) cmd_set_model "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
  set-server-model) cmd_set_server_model "${ARGS[0]:-}" "${ARGS[1]:-}" "${ARGS[2]:-}" ;;
  models)   cmd_models ;;
  set-keepalive) cmd_set_keepalive "${ARGS[0]-}" ;;
  apply)    cmd_apply ;;
  commit)   cmd_commit "${ARGS[0]:-Update model server list}" ;;
  set-token) cmd_set_token "${ARGS[0]:-}" ;;
  set-webui-version) cmd_set_webui_version "${ARGS[0]:-}" ;;
  *)        die "unknown command '${COMMAND}' (try --help)" ;;
esac

case "$COMMAND" in
  add|remove|set-tier|set-model|set-server-model|set-keepalive|set-webui-version)
    if ! $CHANGED && ! $DRY_RUN; then
      exit 0        # nothing was written; no need to nag about applying
    fi
    $AUTO_APPLY && cmd_apply
    $AUTO_COMMIT && cmd_commit "${COMMIT_MSG:-${COMMAND}: update model configuration}"
    echo
    cmd_list false
    if ! $AUTO_APPLY && ! $DRY_RUN; then
      echo
      note "Config changed but NOT applied. Run: $0 apply"
    fi
    ;;
esac
MANAGEEOF
chmod 0755 "${REPO_DIR}/install/manage-model-servers.sh"

# --- repo README so the tree is self-documenting in Gitea ---
cat > "${REPO_DIR}/README.md" <<'RDEOF'
# ollama-smart-router — service configuration

Version-controlled configuration for the Ollama Smart Router LXC. The installer
clones this repo into the container during provisioning and runs
`install/apply-config.sh` to copy each file into place.

    services/<service>/     unit file, code, .ini tunables, requirements.txt
    env/                    environment files consumed via systemd EnvironmentFile
    install/apply-config.sh copies everything into its runtime location

Config is pulled **once, at provisioning time** — services do not contact Gitea
to start, so a Gitea outage can never block a boot.

## Changing configuration on a running container

    cd /app/config-repo && git pull
    ./install/apply-config.sh
    systemctl daemon-reload
    systemctl restart litellm-proxy ollama-router ollama-monitor open-webui

## Layout notes

* `services/ollama-router`, `litellm-proxy` and `ollama-monitor` share one venv
  (`/app/router/venv`); it is built from all three `requirements.txt` files.
* `services/open-webui` has its own venv on Python 3.12 — every open-webui
  release requires `>=3.11,<3.13`, and Debian 13 ships 3.13.
* `router.ini` holds the complexity-routing thresholds and keyword lists, so
  routing behaviour can change without editing `router.py`.
RDEOF

# --- systemd units (one per service directory) ---
cat > "${REPO_DIR}/services/ollama-router/ollama-router.service" <<'UNITEOF'
[Unit]
Description=Intelligent Ollama Prompt Complexity Router Middleware
After=network-online.target litellm-proxy.service
Wants=network-online.target
Requires=litellm-proxy.service
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/router
EnvironmentFile=/app/router/.env
ExecStart=/app/router/venv/bin/python router.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNITEOF

cat > "${REPO_DIR}/services/litellm-proxy/litellm-proxy.service" <<'UNITEOF'
[Unit]
Description=LiteLLM Load Balancing Proxy
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/router
EnvironmentFile=/app/router/.env
ExecStart=/app/router/venv/bin/litellm --config litellm_config.yaml --port 4000 --host 127.0.0.1
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNITEOF

cat > "${REPO_DIR}/services/ollama-monitor/ollama-monitor.service" <<'UNITEOF'
[Unit]
Description=Ollama Cluster Resilience Health Monitor
After=network-online.target litellm-proxy.service
Wants=network-online.target
Requires=litellm-proxy.service
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/router
EnvironmentFile=/app/router/.env
ExecStart=/app/router/venv/bin/python monitor.py
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNITEOF

cat > "${REPO_DIR}/services/open-webui/open-webui.service" <<'UNITEOF'
[Unit]
Description=Open WebUI (chat frontend for the smart router)
After=network-online.target ollama-router.service
Wants=network-online.target
Requires=ollama-router.service
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/openwebui
EnvironmentFile=/app/openwebui/.env
ExecStart=/app/openwebui/venv/bin/open-webui serve
Restart=always
RestartSec=5
# First start downloads a local embedding model; give it room before timeout.
TimeoutStartSec=600
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
UNITEOF

if [[ "$CONFIG_SOURCE" == "repo" ]]; then
  echo "Seeding the Gitea config repository (missing files only)."
  seed_gitea_repo "$REPO_DIR" "$GITEA_DEPLOY_TOKEN_KEEP" || \
    echo "Seeding reported problems; the clone below may be incomplete." >&2

  echo "Installing git in the container."
  apt_get install -y git

  echo "Cloning the config repository into the container."
  clone_config_repo "$GITEA_DEPLOY_TOKEN_KEEP"
else
  echo "Installing the generated configuration directly (no Gitea repo)."
  push_local_config_tree "$REPO_DIR"
fi

echo "Applying configuration."
run_ct bash "${CONFIG_REPO_DIR}/install/apply-config.sh" "$CONFIG_REPO_DIR"

rm -rf "$STAGE_DIR"; STAGE_DIR=""
unset GITEA_DEPLOY_TOKEN_KEEP

echo "Installing Python dependencies (from the repo's requirements files)."
# router, litellm-proxy and monitor share one venv; it is built from all three
# per-service requirements files so each service's pins stay independently
# version controlled.
run_ct python3 -m venv /app/router/venv
run_ct /app/router/venv/bin/pip install --no-cache-dir \
  -r "${CONFIG_REPO_DIR}/services/ollama-router/requirements.txt" \
  -r "${CONFIG_REPO_DIR}/services/litellm-proxy/requirements.txt" \
  -r "${CONFIG_REPO_DIR}/services/ollama-monitor/requirements.txt"

echo "Installing Open WebUI (separate venv to avoid dependency conflicts)."
# open-webui pins its own fastapi/uvicorn/etc., so it must not share the
# router's venv. This install pulls a large dependency tree and takes a while.
#
# IMPORTANT: every open-webui release requires Python >=3.11,<3.13, but Debian
# 13 ships Python 3.13. Installing with the system interpreter fails with
# "No matching distribution found" / "from versions: none" — pip filters out
# every candidate on the Requires-Python gate. So the Open WebUI venv is built
# with a dedicated 3.12 interpreter; the router venv keeps using system python.
OPENWEBUI_PYTHON_BIN="$(ensure_openwebui_python)"
echo "Building Open WebUI venv with: ${OPENWEBUI_PYTHON_BIN}"
run_ct "$OPENWEBUI_PYTHON_BIN" -m venv /app/openwebui/venv
run_ct /app/openwebui/venv/bin/pip install --no-cache-dir --upgrade pip
if [[ "$TORCH_CPU_ONLY" == "true" ]]; then
  # Pre-seed CPU-only torch so the open-webui resolve below already has its
  # torch requirement satisfied and skips the CUDA wheels (~4.5 GB saved).
  echo "Installing CPU-only torch (TORCH_CPU_ONLY=true)."
  if run_ct /app/openwebui/venv/bin/pip install --no-cache-dir \
       --index-url https://download.pytorch.org/whl/cpu torch; then
    echo "  CPU-only torch installed."
  else
    echo "WARNING: could not install CPU-only torch (is download.pytorch.org" >&2
    echo "         reachable from the container?). Falling back to the default" >&2
    echo "         build, which pulls ~4.5 GB of CUDA wheels this container" >&2
    echo "         cannot use. Re-run with TORCH_CPU_ONLY=false to skip this." >&2
  fi
fi
# Pin a known-good release; bump deliberately after testing. This step pulls a
# large dependency tree (torch, transformers, chromadb…) and takes a while.
run_ct /app/openwebui/venv/bin/pip install --no-cache-dir \
  -r "${CONFIG_REPO_DIR}/services/open-webui/requirements.txt"

echo "Setting ownership and permissions."
run_ct chown -R ollama-router:ollama-router /app/router /app/openwebui
run_ct chown root:ollama-router /app/router/.env
run_ct chmod 0640 /app/router/.env
run_ct chown root:ollama-router /app/openwebui/.env
run_ct chmod 0640 /app/openwebui/.env




# ------------------------------------------------------------------------------
# Optional: if the CT firewall is on, the default input policy can drop inbound
# traffic. Allow the Router API (8000) and Open WebUI (OPENWEBUI_PORT) from the
# trusted subnet. LiteLLM (4000) stays localhost-only and needs no rule.
if [[ "$FIREWALL" == "1" && -n "$API_ALLOW_CIDR" ]]; then
  echo "Adding firewall rules to allow tcp/8000 and tcp/${OPENWEBUI_PORT} from ${API_ALLOW_CIDR}."
  mkdir -p "/etc/pve/firewall"
  fw_conf="/etc/pve/firewall/${CT_ID}.fw"
  if [[ ! -f "$fw_conf" ]]; then
    printf '[OPTIONS]\nenable: 1\n\n[RULES]\n' > "$fw_conf"
  fi
  echo "IN ACCEPT -source ${API_ALLOW_CIDR} -p tcp -dport 8000 -log nolog" >> "$fw_conf"
  echo "IN ACCEPT -source ${API_ALLOW_CIDR} -p tcp -dport ${OPENWEBUI_PORT} -log nolog" >> "$fw_conf"
elif [[ "$FIREWALL" == "1" ]]; then
  echo "WARNING: FIREWALL=1 but API_ALLOW_CIDR is unset. If the datacenter" >&2
  echo "         firewall is active, inbound tcp/8000 and tcp/${OPENWEBUI_PORT}" >&2
  echo "         may be dropped. Set API_ALLOW_CIDR (e.g. 192.168.11.0/24) or" >&2
  echo "         disable FIREWALL." >&2
fi

# ------------------------------------------------------------------------------
echo "Writing login MOTD."
ROUTER_IP="${IP_CIDR%/*}"
motd_tmp="$(mktemp)"
cat > "$motd_tmp" <<EOF

==============================================================================
  Ollama Smart Router        ${CT_NAME}  (CT ${CT_ID})
==============================================================================
  Container IP : ${ROUTER_IP}

  SERVICES
  ---------------------------------------------------------------------------
   Open WebUI (chat UI)       http://${ROUTER_IP}:${OPENWEBUI_PORT}        [open-webui.service]
   Smart Router (OpenAI API)  http://${ROUTER_IP}:8000/v1     [ollama-router.service]
   LiteLLM proxy              http://127.0.0.1:4000  (local)  [litellm-proxy.service]
   Health monitor             Mattermost alerts               [ollama-monitor.service]

  MODEL TIERS  ->  OLLAMA BACKEND(S)
  ---------------------------------------------------------------------------
   qwen-fast     ->  $(indices_to_urls "$TIER_FAST_IDX")   (ollama/${MODEL_FAST})
   qwen-medium   ->  $(indices_to_urls "$TIER_MEDIUM_IDX")   (ollama/${MODEL_MEDIUM})
   qwen-heavy    ->  $(indices_to_urls "$TIER_HEAVY_IDX")   (ollama/${MODEL_HEAVY})
   ${MODEL_SERVER_COUNT} server(s) total

  PATHS & COMMANDS
  ---------------------------------------------------------------------------
   Router config : /app/router/.env  /app/router/litellm_config.yaml
   Tunables      : /app/router/router.ini  /app/router/monitor.ini
   WebUI config  : /app/openwebui/.env
   Config repo   : ${CONFIG_REPO_DIR}  (git pull && ./install/apply-config.sh)
   Model servers : manage-model-servers list | status | models
                   manage-model-servers add <ip> --tier heavy --apply
                   manage-model-servers set-model heavy <tag> --apply
                   manage-model-servers set-server-model <tier> <ip> <tag>
                   manage-model-servers set-webui-version latest --apply
                   manage-model-servers set-keepalive 2h --apply
   Status        : systemctl status open-webui ollama-router litellm-proxy ollama-monitor
   Logs          : journalctl -u ollama-router -f
==============================================================================
EOF
pct push "$CT_ID" "$motd_tmp" /etc/motd --perms 0644
rm -f "$motd_tmp"

echo "Starting services."
run_ct systemctl daemon-reload
run_ct systemctl enable --now \
  litellm-proxy.service ollama-router.service ollama-monitor.service open-webui.service

# Provisioning succeeded — disarm the failure trap so we keep the container.
CT_CREATED=""
trap - ERR

echo "=============================================================================="
echo "Provisioning complete."
echo "Container ID: ${CT_ID}"
echo "Service IP: ${ROUTER_IP}"
echo "OpenAI-compatible API base URL: http://${ROUTER_IP}:8000/v1"
echo "Open WebUI (chat UI):          http://${ROUTER_IP}:${OPENWEBUI_PORT}"
echo "  -> create the admin account on first visit; it is pre-connected to the router."
echo "Config directory (in container): ${CONFIG_REPO_DIR}"
if [[ "$CONFIG_SOURCE" == "repo" ]]; then
  echo "Config source: git clone of ${GITEA_SERVER_URL%/}/${GITEA_OWNER}/${GITEA_REPO_NAME}"
else
  echo "Config source: LOCAL (not version controlled — no usable Gitea token)"
fi
echo "=============================================================================="
