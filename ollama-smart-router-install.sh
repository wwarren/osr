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
CT_ID="${CT_ID:-}"                    # blank = offer the cluster's next free ID at the prompt
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
# Service ports. OSR (8000) and LiteLLM (4000) are fixed in their units;
# Open WebUI reads its port from its env file, so only this one is wired.
OPENWEBUI_PORT="${OPENWEBUI_PORT:-8080}"
# Open WebUI requires Python >=3.11,<3.13 (all releases). Debian 13 ships 3.13,
# so a dedicated interpreter is provisioned for it. See ensure_openwebui_python.
# Pinned deliberately; bump after testing. Every release so far requires
# Python >=3.11,<3.13, which is why a dedicated 3.12 interpreter is provisioned.
# Change it later on a running container with:
#   manage-model-servers set-webui-version <version|latest> --apply
OPENWEBUI_VERSION="${OPENWEBUI_VERSION:-0.12.4}"
OPENWEBUI_PY_VERSION="${OPENWEBUI_PY_VERSION:-3.12}"
OPENWEBUI_PY_DIR="${OPENWEBUI_PY_DIR:-/opt/python}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-ant-hp-nfs-backups}"
TEMPLATE_NAME="${TEMPLATE_NAME:-}"
# Minimum free space wanted on the storage that holds the container template.
TEMPLATE_MIN_GIB="${TEMPLATE_MIN_GIB:-2}"
FIREWALL="${FIREWALL:-1}"
# Bearer token required by the OSR API (8000). Blank = generate one. Stored
# only in /app/router/secrets.env; change it later with
#   manage-model-servers set-api-key [key|--generate|--off]
ROUTER_API_KEY="${ROUTER_API_KEY:-}"
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
MODEL_LARGE="${MODEL_LARGE:-qwen3.8:27b}"
MODEL_XLARGE="${MODEL_XLARGE:-llama3.3:70b}"
# Tier -> server assignment, as 1-based server numbers. Empty means "derive a
# sensible default from the server count". A tier may list several servers;
# LiteLLM load-balances across them with the configured latency routing.
TIER_FAST_SERVERS="${TIER_FAST_SERVERS:-}"
TIER_MEDIUM_SERVERS="${TIER_MEDIUM_SERVERS:-}"
TIER_LARGE_SERVERS="${TIER_LARGE_SERVERS:-}"
TIER_XLARGE_SERVERS="${TIER_XLARGE_SERVERS:-}"
# Skip every prompt and use the values above / from the environment.
NONINTERACTIVE="${NONINTERACTIVE:-false}"
# The Gitea and Mattermost services are targets too (targets/gitea,
# targets/mattermost); true pre-selects them in the targets menu below.
INSTALL_GITEA="${INSTALL_GITEA:-false}"
INSTALL_MATTERMOST="${INSTALL_MATTERMOST:-false}"
# Optional targets from targets/ (the Gitea and Mattermost services, model
# servers, and the Open Terminal / Hermes / ComfyUI companions), each in its own LXC.
# Interactive installs ask which to create;
# names or menu numbers, comma-separated, e.g. INSTALL_TARGETS=ollama,hermes
# to pre-fill the answer. Unattended installs refuse a non-empty list.
INSTALL_TARGETS="${INSTALL_TARGETS:-}"
TARGETS_DIR="${TARGETS_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/targets}"
TARGETS=""
# How long to wait for Open WebUI's first start before adding companions.
OPENWEBUI_WAIT_SECONDS="${OPENWEBUI_WAIT_SECONDS:-900}"
# An Open WebUI admin key for the companions may be preset; it is taken out of
# the environment at once, so no child process sees it.
TARGET_ADMIN_TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
unset OPENWEBUI_ADMIN_TOKEN
# Likewise a Hugging Face token for ComfyUI's gated klein-9b weights; only the
# ComfyUI provisioner gets it, as an environment variable.
TARGET_HF_TOKEN="${HF_TOKEN:-}"
unset HF_TOKEN
# Populated by the prompts: normalised base URLs, and 0-based index lists.
MODEL_SERVERS=()
TIER_FAST_IDX=""
TIER_MEDIUM_IDX=""
TIER_LARGE_IDX=""
TIER_XLARGE_IDX=""
# Gitea runs as a TurnKey appliance behind nginx on 443/80 — Gitea's own port
# 3000 is bound to localhost inside that container and is NOT reachable from
# outside, so the URL is the plain hostname with no port.
# No default host: an unattended run without it installs a local config, and the
# interactive prompt asks for it (blank = no Gitea). A placeholder default would
# send the deploy token to a host that is not yours.
GITEA_SERVER_URL="${GITEA_SERVER_URL:-}"
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
# Installer-OWNED code is different: it is not yours to tune, and a repo left
# holding an old copy silently runs old code forever (router.py, units and the
# management tool drifted exactly this way). With CONFIG_UPDATE_CODE=true these
# paths are updated in the repo whenever the installer's copy differs; git
# history keeps the previous version. Tunables (router.ini, monitor.ini), env
# files and litellm_config.yaml stay seed-if-missing. Keep this list in step
# with tools/sync-embedded.py (tests/test-repo.sh checks it).
CONFIG_UPDATE_CODE="${CONFIG_UPDATE_CODE:-true}"
INSTALLER_OWNED_CODE=(
  services/ollama-router/router.py
  services/ollama-router/requirements.txt
  services/ollama-router/ollama-router.service
  services/ollama-monitor/monitor.py
  services/ollama-monitor/requirements.txt
  services/ollama-monitor/ollama-monitor.service
  services/litellm-proxy/requirements.txt
  services/litellm-proxy/requirements.lock
  services/litellm-proxy/litellm-proxy.service
  services/open-webui/open-webui.service
  install/apply-config.sh
  install/manage-model-servers.sh
)
# Repo owner: discovered from the deploy token at runtime; this is the fallback.
GITEA_OWNER="${GITEA_ADMIN_USER}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
MATTERMOST_MONITOR_USER="${MATTERMOST_MONITOR_USER:-OllamaMonitor}"
MATTERMOST_CHANNEL="${MATTERMOST_CHANNEL:-ollama-monitor}"
# Verification is ON by default. An internal Mattermost behind a self-signed
# certificate needs this false, or every alert fails as a transport error.
MATTERMOST_VERIFY_TLS="${MATTERMOST_VERIFY_TLS:-true}"

# --- small helpers -------------------------------------------------------------
# router_settings for litellm_config.yaml. Input on stdin: one line per tier
# that has deployments, in size order: "<model_name> <signature>". Each tier
# falls back to the nearest other tiers (smaller first on a tie), skipping a
# tier with identical deployments -- the same model on the same host cannot
# succeed where the original just failed. Same rule as manage-model-servers.
litellm_router_settings() {
  python3 -c '
import json, sys
tiers = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        name, _, sig = line.partition(" ")
        tiers.append((name, sig))
print("router_settings:")
print("  routing_strategy: latency-based-routing")
print("  num_retries: 2")
print("  timeout: 600")
rows = []
for i, (name, sig) in enumerate(tiers):
    others = [(abs(i - j), j, o) for j, (o, osig) in enumerate(tiers) if o != name and osig != sig]
    if others:
        rows.append("    - %s: %s" % (name, json.dumps([o for _, _, o in sorted(others)])))
if rows:
    print("  fallbacks:")
    print("\n".join(rows))
'
}

generate_api_key() {
  printf 'sk-router-%s\n' "$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
}

# Append one rule line to a PVE firewall file unless it is already there, and
# make sure it lands in a [RULES] section. Re-running the installer therefore
# never duplicates rules.
ensure_fw_rule() {
  local file="$1" rule="$2"
  grep -qxF -- "$rule" "$file" 2>/dev/null && return 0
  grep -qx '\[RULES\]' "$file" 2>/dev/null || printf '\n[RULES]\n' >> "$file"
  printf '%s\n' "$rule" >> "$file"
}

# Write the CT firewall rules: SSH, the OSR API and Open WebUI from the
# trusted CIDR. SSH is included because enabling the CT firewall switches the
# default inbound policy to DROP -- without it the container locks you out.
write_firewall_rules() {
  local file="$1" cidr="$2" webui_port="$3" port
  [[ -f "$file" ]] || printf '[OPTIONS]\nenable: 1\n\n[RULES]\n' > "$file"
  for port in 22 8000 "$webui_port"; do
    ensure_fw_rule "$file" "IN ACCEPT -source ${cidr} -p tcp -dport ${port} -log nolog"
  done
}

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
  local next_id=""
  if [[ -n "$CT_ID" ]]; then
    if [[ ! "$CT_ID" =~ ^[0-9]+$ ]]; then
      echo "CT_ID must be numeric when provided." >&2
      return 1
    fi
    if ! ct_id_free "$CT_ID"; then
      echo "Requested CT_ID ${CT_ID} is in use or not available in this cluster." >&2
      return 1
    fi
    printf '%s\n' "$CT_ID"
    return 0
  fi
  next_id="$(cluster_next_ct_id)" || return 1
  if [[ -n "$next_id" ]] && ct_id_free "$next_id"; then
    printf '%s\n' "$next_id"
    return 0
  fi
  next_free_ct_id_excluding
}

# The cluster's own next free CT ID, or nothing when pvesh is not installed.
# A pvesh that cannot answer means the guest list is unreadable (pve-cluster
# down, /etc/pve not mounted): every later ID check would fail too, so stop
# here instead of scanning IDs that can never be confirmed free.
cluster_next_ct_id() {
  local next_id=""
  command -v pvesh >/dev/null 2>&1 || return 0
  if ! next_id="$(pvesh get /cluster/nextid 2>/dev/null)"; then
    next_id=""
  fi
  next_id="$(awk 'NF {print $1; exit}' <<< "$next_id")"
  if [[ ! "$next_id" =~ ^[0-9]+$ ]]; then
    echo "Cannot read the cluster's guest list (pvesh get /cluster/nextid failed)." >&2
    echo "Check that pve-cluster is running and /etc/pve is mounted." >&2
    return 1
  fi
  printf '%s\n' "$next_id"
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
select_router_template() {
  local n t a
  DOWNLOAD_TEMPLATE_NAME=""
  if TEMPLATE_REF="$(find_existing_debian_template)"; then
    # The lookup runs in a subshell; keep the storage it actually selected.
    TEMPLATE_STORAGE="${TEMPLATE_REF%%:*}"
    echo "Using existing Debian container template: ${TEMPLATE_REF}"
    return 0
  fi
  TEMPLATE_REF=""
  if ! storage_supports_vztmpl "$TEMPLATE_STORAGE"; then
    echo "Storage '${TEMPLATE_STORAGE}' does not support vztmpl content; cannot download a template there." >&2
    echo "Set TEMPLATE_STORAGE to a storage that lists 'vztmpl' in 'pvesm status -content vztmpl'." >&2
    echo "Candidates with free space:" >&2
    storage_candidates vztmpl | while IFS=$'\t' read -r n t a; do
      echo "  ${n} (${t}): $(kib_to_gib "$a") GiB free" >&2
    done
    return 1
  fi
  local free_gib
  free_gib="$(storage_free_gib "$TEMPLATE_STORAGE" vztmpl)"
  if [[ "$free_gib" =~ ^[0-9]+$ ]] && (( free_gib < TEMPLATE_MIN_GIB )); then
    echo "Storage '${TEMPLATE_STORAGE}' has only ${free_gib} GiB free;" >&2
    echo "at least ${TEMPLATE_MIN_GIB} GiB is wanted for the container template." >&2
    select_storage_with_space vztmpl "$TEMPLATE_MIN_GIB" TEMPLATE_STORAGE "$TEMPLATE_STORAGE" || return 1
  fi
  DOWNLOAD_TEMPLATE_NAME="$(select_available_debian_template)" || return 1
  TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${DOWNLOAD_TEMPLATE_NAME}"
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
# Only the two literals the generated env files and the Python services parse.
valid_bool() {
  [[ "$1" == "true" || "$1" == "false" ]]
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
  # Kind prefixes select the non-Ollama server APIs.
  raw="${raw#lmstudio+}"
  [[ "$raw" == lmstudio://* ]] && raw="${raw#lmstudio://}"
  raw="${raw#strata+}"
  [[ "$raw" == strata://* ]] && raw="${raw#strata://}"
  raw="${raw#basalt+}"
  [[ "$raw" == basalt://* ]] && raw="${raw#basalt://}"
  raw="${raw#maya+}"
  [[ "$raw" == maya://* ]] && raw="${raw#maya://}"
  raw="${raw#xolotl+}"
  [[ "$raw" == xolotl://* ]] && raw="${raw#xolotl://}"
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
# Stored form: http://host:port for Ollama or a kind-prefixed URL for
# LM Studio, Strata, Basalt, Maya and Xolotl, matching the manager, router and monitor.
normalize_ollama_url() {
  local raw="${1%/}" prefix="" port="$OLLAMA_PORT"
  if [[ "$raw" == lmstudio+* ]]; then
    prefix="lmstudio+"; raw="${raw#lmstudio+}"; port="${LMSTUDIO_PORT:-1234}"
  elif [[ "$raw" == lmstudio://* ]]; then
    prefix="lmstudio+"; raw="${raw#lmstudio://}"; port="${LMSTUDIO_PORT:-1234}"
  elif [[ "$raw" == strata+* ]]; then
    prefix="strata+"; raw="${raw#strata+}"; port="${STRATA_PORT:-8080}"
  elif [[ "$raw" == strata://* ]]; then
    prefix="strata+"; raw="${raw#strata://}"; port="${STRATA_PORT:-8080}"
  elif [[ "$raw" == basalt+* ]]; then
    prefix="basalt+"; raw="${raw#basalt+}"; port="${BASALT_PORT:-8080}"
  elif [[ "$raw" == basalt://* ]]; then
    prefix="basalt+"; raw="${raw#basalt://}"; port="${BASALT_PORT:-8080}"
  elif [[ "$raw" == maya+* ]]; then
    prefix="maya+"; raw="${raw#maya+}"; port="${MAYA_PORT:-8080}"
  elif [[ "$raw" == maya://* ]]; then
    prefix="maya+"; raw="${raw#maya://}"; port="${MAYA_PORT:-8080}"
  elif [[ "$raw" == xolotl+* ]]; then
    prefix="xolotl+"; raw="${raw#xolotl+}"; port="${XOLOTL_PORT:-8080}"
  elif [[ "$raw" == xolotl://* ]]; then
    prefix="xolotl+"; raw="${raw#xolotl://}"; port="${XOLOTL_PORT:-8080}"
  fi
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    printf '%s%s\n' "$prefix" "$raw"
  elif [[ "$raw" == *:* ]]; then
    printf '%shttp://%s\n' "$prefix" "$raw"
  else
    printf '%shttp://%s:%s\n' "$prefix" "$raw" "$port"
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
  local eof=false
  while true; do
    # `read` returns non-zero at EOF, but may still have set `value` from a
    # final line with no trailing newline -- so record EOF and evaluate the
    # value anyway rather than discarding it.
    if ! read -r -p "$prompt [${default}]: " value; then
      eof=true
    fi
    [[ -z "$value" ]] && value="$default"
    if "$validator" "$value"; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    echo "  Not a valid value: '${value}' — try again." >&2
    # Without this the loop spins forever on an exhausted stdin: there is
    # nothing left to read, so every iteration re-tests the same bad default.
    if $eof; then
      echo "  No more input; giving up on ${var_name}." >&2
      return 1
    fi
    value=""
  done
}

# True when no guest in the cluster uses the ID (pct only sees this node).
ct_id_free() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1
  else
    ! pct status "$1" >/dev/null 2>&1
  fi
}

# The lowest free CT ID that is not one of the arguments. The arguments are IDs
# this run will use later (the router's CT_ID), which the cluster cannot know.
# The scan is capped, so an ID check that never succeeds cannot loop forever.
next_free_ct_id_excluding() {
  local candidate="" id reserved tries=0
  candidate="$(cluster_next_ct_id)" || return 1
  [[ -n "$candidate" ]] || candidate=100
  while (( tries < 1000 )); do
    reserved=false
    for id in "$@"; do [[ "$id" == "$candidate" ]] && reserved=true; done
    if ! $reserved && ct_id_free "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1)); tries=$((tries + 1))
  done
  echo "No free CT ID found below ${candidate}." >&2
  return 1
}

# A service LXC created in this run exists to give the router that feature, so
# stop before building the router if its repository or webhook is not in use.
require_companion_credentials() {
  local status=0
  if [[ " ${TARGETS:-} " == *" gitea "* && "$CONFIG_SOURCE" != "repo" ]]; then
    echo "The new Gitea LXC (CT $(target_setting gitea CT_ID)) is ready, but OSR is not" >&2
    echo "using it (no Gitea URL, or its token or repository check failed). Rerun the" >&2
    echo "OSR installer without selecting gitea, with GITEA_SERVER_URL, GITEA_ADMIN_USER" >&2
    echo "and GITEA_DEPLOY_TOKEN from /etc/gitea-target/ in that CT." >&2
    status=1
  fi
  if [[ " ${TARGETS:-} " == *" mattermost "* && -z "$MATTERMOST_WEBHOOK_URL" ]]; then
    echo "The new Mattermost LXC (CT $(target_setting mattermost CT_ID)) is ready, but no alert" >&2
    echo "webhook was kept. Rerun the OSR installer without selecting mattermost, with" >&2
    echo "MATTERMOST_WEBHOOK_URL from /etc/mattermost-target/webhook-url in that CT." >&2
    status=1
  fi
  return "$status"
}

# --- optional targets ---------------------------------------------------------
# Services, inference targets and companions from targets/, each in its own
# LXC, chosen at the start of an interactive install. Services (Gitea,
# Mattermost) are created first, before the router is built, and give it their
# URL, token or webhook. Model targets are added to the router's server list up
# front and created after the router; companions need the router's Open WebUI,
# so they come last.
#
# One line per target: name|phase|label|router entry (@IP@ and @PORT@ filled
# in)|key kind (Strata-style servers generate an API key the router needs)|
# GPU as need:vendors[:generations]: need is required, optional (used when
# present) or empty; vendors are the GPU vendors the engine runs on, in order of
# preference; generations limit the cards (see target_gpu_spec).
target_table() {
  printf '%s\n' \
    'gitea|service|Gitea: the configuration repository (configured for OSR)|||' \
    'mattermost|service|Mattermost: health alerts (team, channel and webhook made for you)|||' \
    'ollama|model|Ollama from the PVE community script (NVIDIA, AMD or Intel Arc GPU when present)|http://@IP@:11434||optional:nvidia,amd,intel' \
    'llamacpp|model|llama.cpp llama-server behind an Ollama bridge (CUDA, or Vulkan on AMD/Intel Arc)|http://@IP@:11434||required:nvidia,amd,intel' \
    'airllm|model|AirLLM: one model larger than RAM/VRAM, streamed from disk (slow)|http://@IP@:11434||:nvidia' \
    'strata|model|Strata (Qwen3.8-Flash-Next) on an NVIDIA GPU|strata+http://@IP@:@PORT@|strata|required:nvidia' \
    'basalt|model|Basalt on a Blackwell GPU (CUDA 13)|basalt+http://@IP@:@PORT@|basalt|required:nvidia:rtx50' \
    'maya|model|Project Maya (GLM-5.3-Flash) on an NVIDIA GPU|maya+http://@IP@:@PORT@|maya|required:nvidia' \
    'xolotl|model|Xolotl (DeepSeek-V4.1-Flash, 552B) on a 24 GB NVIDIA GPU; ~372 GB download|xolotl+http://@IP@:@PORT@|xolotl|required:nvidia' \
    'open-terminal|companion|Open Terminal: a shell tool for Open WebUI|||' \
    'hermes|companion|Hermes Agent: offered in Open WebUI as the model hermes-agent|||' \
    'comfyui|companion|ComfyUI: image generation for Open WebUI (NVIDIA, AMD or Intel Arc GPU when present)|||optional:nvidia,amd,intel'
}
# target_field NAME FIELD: one column of the table (phase, label, entry, key, gpu).
target_field() {
  local column
  case "$2" in
    phase) column=2 ;; label) column=3 ;; entry) column=4 ;; key) column=5 ;; gpu) column=6 ;;
    *) return 1 ;;
  esac
  target_table | awk -F'|' -v n="$1" -v c="$column" '$1 == n {print $c; found=1} END {exit !found}'
}
# target_var_prefix NAME: the prefix of a target's presets (OPEN_TERMINAL_CT_ID).
target_var_prefix() { printf '%s\n' "$1" | tr 'a-z-' 'A-Z_'; }
# target_setting NAME FIELD: a target's chosen or preset <PREFIX>_<FIELD>.
target_setting() {
  local var
  var="$(target_var_prefix "$1")_$2"
  printf '%s\n' "${!var:-}"
}
# llama.cpp's guest install needs a model; without one only the CT is made.
llamacpp_model_given() {
  [[ -n "${MODEL_ALIAS:-}" && ( -n "${MODEL_DOWNLOAD_URL:-}" || -n "${MODEL_PATH:-}" ) ]]
}
# target_gpu_spec NAME: need|vendors|generations for the target as configured.
# llama.cpp needs a GPU for its default build: BACKEND=cuda (NVIDIA) or vulkan
# (AMD, Intel Arc), unset for whichever the host has; BACKEND=cpu does without.
# AirLLM uses an NVIDIA GPU only when GPU_DEVICES is given. Ollama and ComfyUI
# follow GPU (nvidia, amd or intel picks one; no or none runs on the CPU).
target_gpu_spec() {
  local need vendors gens
  IFS=: read -r need vendors gens <<< "$(target_field "$1" gpu)" || true
  target_field "$1" gpu >/dev/null || return 1
  case "$1" in
    llamacpp)
      case "${BACKEND:-}" in
        '') ;;
        cuda) vendors=nvidia ;;
        vulkan) vendors=amd,intel ;;
        *) need="" ;;
      esac ;;
    airllm) [[ -z "${GPU_DEVICES:-}" ]] || need=required ;;
    ollama|comfyui)
      case "${GPU:-auto}" in
        no|none) need="" ;;
        nvidia|amd|intel) vendors="$GPU" ;;
      esac ;;
  esac
  [[ -n "$need" ]] || vendors="" gens=""
  printf '%s|%s|%s\n' "$need" "$vendors" "$gens"
}
# target_gpu_need NAME: required, optional or nothing.
target_gpu_need() {
  local spec
  spec="$(target_gpu_spec "$1")" || return 1
  printf '%s\n' "${spec%%|*}"
}

# The GPUs on this host (load_host_gpu_cards), one address|vendor|generation|
# driver|name line per card, and GPU 0's compute capability once the GPU step
# has run for the NVIDIA-only targets.
HOST_GPU_CARDS="" HOST_GPU_CUDA_ARCH=""

# host_gpu_tool: tools/setup-host-gpu.sh of this checkout.
host_gpu_tool() {
  local tool="${TARGETS_DIR}/../tools/setup-host-gpu.sh"
  if [[ ! -r "$tool" ]]; then
    echo "Missing ${tool}. Run the OSR installer from the full repository checkout." >&2
    return 1
  fi
  printf '%s\n' "$tool"
}

# load_host_gpu_cards: HOST_GPU_CARDS from the host tool's --list (NVIDIA cards,
# and AMD Radeon and Intel Arc cards of a supported generation). Nothing is
# changed on the host.
load_host_gpu_cards() {
  local tool out
  tool="$(host_gpu_tool)" || return 1
  out="$(bash "$tool" --list --vendors nvidia,amd,intel)" || return 1
  HOST_GPU_CARDS="$(sed -n 's/^GPU_CARD=//p' <<< "$out")"
}

# host_gpu_card ADDRESS: the HOST_GPU_CARDS line of a card (03:00.0 and
# 0000:03:00.0 both match), or nothing.
host_gpu_card() {
  local address="${1,,}" line
  [[ -n "$address" ]] || return 1
  [[ "$address" == *:*:* ]] || address="0000:${address}"
  while IFS= read -r line; do
    [[ -n "$line" && "${line%%|*}" == "$address" ]] && { printf '%s\n' "$line"; return 0; }
  done <<< "${HOST_GPU_CARDS:-}"
  return 1
}

# gpu_card_label LINE: a card as the GPU menus show it.
gpu_card_label() {
  local address vendor gen driver name state
  IFS='|' read -r address vendor gen driver name <<< "$1"
  case "$driver" in
    "") state="no driver yet; set up next" ;;
    vfio-pci) state="bound to vfio-pci" ;;
    *) state="driver ${driver}" ;;
  esac
  printf '%s  %s (%s%s)\n' "$address" "$name" "${gen:+${gen}, }" "$state"
}

# target_gpu_prompted NAME: does the target run on AMD Radeon or Intel Arc as
# configured, so that each install asks which card it gets? NVIDIA-only
# targets use the NVIDIA driver's GPU 0 (or their GPU_DEVICES).
target_gpu_prompted() {
  local need vendors
  IFS='|' read -r need vendors _ <<< "$(target_gpu_spec "$1")" || return 1
  [[ -n "$need" && ( ",$vendors," == *",amd,"* || ",$vendors," == *",intel,"* ) ]]
}

# target_gpu_choices NAME: the cards the target can use, one HOST_GPU_CARDS
# line each, in the target's vendor order: not bound to vfio-pci, and of a
# generation the target accepts.
target_gpu_choices() {
  local need vendors gens v line vendor gen driver
  IFS='|' read -r need vendors gens <<< "$(target_gpu_spec "$1")" || return 1
  [[ -n "$need" ]] || return 0
  for v in ${vendors//,/ }; do
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS='|' read -r _ vendor gen driver _ <<< "$line"
      [[ "$vendor" == "$v" && "$driver" != vfio-pci ]] || continue
      [[ -z "$gens" || ",$gens," == *",$gen,"* ]] || continue
      printf '%s\n' "$line"
    done <<< "${HOST_GPU_CARDS:-}"
  done
}

# valid_gpu_choice VALUE: a menu number, a listed card's PCI address, or none
# when GPU_CHOICE_NONE is true. GPU_CHOICE_ADDRESSES holds the menu's cards.
valid_gpu_choice() {
  local value="${1,,}" count
  local -a addresses=()
  read -r -a addresses <<< "${GPU_CHOICE_ADDRESSES:-}"
  count=${#addresses[@]}
  [[ "${GPU_CHOICE_NONE:-false}" != true ]] || count=$((count + 1))
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    (( 10#$value >= 1 && 10#$value <= count ))
    return
  fi
  [[ "$value" != none ]] || { [[ "${GPU_CHOICE_NONE:-false}" == true ]]; return; }
  [[ "$value" == *:*:* ]] || value="0000:${value}"
  [[ " ${GPU_CHOICE_ADDRESSES:-} " == *" ${value} "* ]]
}

# prompt_target_gpus: for each selected target that runs on AMD Radeon or Intel
# Arc (Ollama, llama.cpp, ComfyUI), ask which of the host's GPUs it gets; the
# answer is <PREFIX>_GPU_CARD (a PCI address, or none: the CPU). Targets that
# use a GPU only when present can also take none. A preset is checked and
# offered as the default. With one card and a target that needs it, that card
# is taken without asking.
prompt_target_gpus() {
  local name var preset value line i default need choices
  local -a lines=() addresses=()
  [[ -n "${TARGETS:-}" ]] || return 0
  for name in $TARGETS; do target_gpu_prompted "$name" && break; name=""; done
  [[ -n "$name" ]] || return 0
  load_host_gpu_cards || return 1
  echo
  echo "--- GPU for each target ---"
  if [[ -z "$HOST_GPU_CARDS" ]]; then
    echo "  No NVIDIA, AMD Radeon (RX 7000/9000) or Intel Arc GPU is on this host's PCI bus."
  else
    echo "  GPUs on this host:"
    while IFS= read -r line; do echo "    $(gpu_card_label "$line")"; done <<< "$HOST_GPU_CARDS"
  fi
  for name in $TARGETS; do
    target_gpu_prompted "$name" || continue
    var="$(target_var_prefix "$name")_GPU_CARD"
    preset="${!var:-}"
    need="$(target_gpu_need "$name")"
    choices="$(target_gpu_choices "$name")"
    lines=(); addresses=()
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      lines+=("$line"); addresses+=("${line%%|*}")
    done <<< "$choices"
    GPU_CHOICE_ADDRESSES="${addresses[*]:-}"
    GPU_CHOICE_NONE=false
    [[ "$need" != optional ]] || GPU_CHOICE_NONE=true
    if [[ -n "$preset" ]] && ! valid_gpu_choice "$preset"; then
      if [[ "${preset,,}" == none ]]; then
        echo "${var}=none: ${name} needs a GPU (llama.cpp: set BACKEND=cpu to build without one)." >&2
      else
        echo "${var}=${preset} is not a GPU ${name} can use on this host." >&2
      fi
      return 1
    fi
    if (( ${#lines[@]} == 0 )); then
      # The GPU step reports the missing card (and stops a target that needs one).
      [[ -n "$preset" ]] || printf -v "$var" '%s' ""
      echo "  ${name}: no GPU it can use on this host."
      continue
    fi
    if [[ -z "$preset" && "$need" == required && ${#lines[@]} == 1 ]]; then
      printf -v "$var" '%s' "${addresses[0]}"
      echo "  ${name} uses the only GPU it can: $(gpu_card_label "${lines[0]}")"
      continue
    fi
    echo "  Which GPU should ${name} use?"
    for i in "${!lines[@]}"; do printf '    %d) %s\n' "$((i + 1))" "$(gpu_card_label "${lines[i]}")"; done
    if [[ "$GPU_CHOICE_NONE" == true ]]; then
      printf '    %d) none: run on the CPU\n' "$(( ${#lines[@]} + 1 ))"
    fi
    default="${preset:-1}"
    prompt_until_valid "  GPU for ${name} (number, PCI address$([[ $GPU_CHOICE_NONE != true ]] || printf ' or none'))" \
      "$var" "$default" valid_gpu_choice || return 1
    value="${!var,,}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      if (( 10#$value > ${#addresses[@]} )); then value=none; else value="${addresses[10#$value - 1]}"; fi
    elif [[ "$value" != none && "$value" != *:*:* ]]; then
      value="0000:${value}"
    fi
    printf -v "$var" '%s' "$value"
  done
  unset GPU_CHOICE_ADDRESSES GPU_CHOICE_NONE
}

# target_gpu_result NAME [FIELD]: what the GPU step found for a target, as
# state|vendor|render node|NVIDIA minor|PCI address, or one FIELD of it (state,
# vendor, render, minor, pci). Empty before the step ran for the target.
target_gpu_result() {
  local var value state vendor render minor pci
  var="GPU_RESULT_$(target_var_prefix "$1")"
  value="${!var:-}"
  [[ -n "${2:-}" ]] || { printf '%s\n' "$value"; return 0; }
  IFS='|' read -r state vendor render minor pci <<< "$value"
  case "$2" in
    state) printf '%s\n' "$state" ;;
    vendor) printf '%s\n' "$vendor" ;;
    render) printf '%s\n' "$render" ;;
    minor) printf '%s\n' "$minor" ;;
    pci) printf '%s\n' "$pci" ;;
    *) return 1 ;;
  esac
}

# run_host_gpu_tool NEED VENDORS CARD TARGETS [ARGS...]: one run of
# tools/setup-host-gpu.sh for the targets that share a card (CARD) or, without
# a card, the vendors; their results go to GPU_RESULT_<PREFIX>.
run_host_gpu_tool() {
  local need="$1" vendors="$2" card="$3" targets="$4" tool out rc=0 state vendor gen render name
  shift 4
  tool="$(host_gpu_tool)" || return 1
  echo
  echo "--- GPU${card:+ ${card}} for: ${targets} ---"
  out="$(bash "$tool" --need "$need" --vendors "$vendors" --for "$targets" ${card:+--card "$card"} "$@")" || rc=$?
  case "$rc" in
    0) ;;
    2)
      echo "Reboot this host, then run the OSR installer again. The GPU driver is set up;" >&2
      echo "nothing else was created." >&2
      return 1 ;;
    *)
      echo "The GPU is not ready for: ${targets}. Nothing was created;" >&2
      echo "deselect those targets, or fix the GPU and run the OSR installer again." >&2
      return 1 ;;
  esac
  state="$(sed -n 's/^GPU_STATE=//p' <<< "$out")"
  vendor="$(sed -n 's/^GPU_VENDOR=//p' <<< "$out")"
  gen="$(sed -n 's/^GPU_GENERATION=//p' <<< "$out")"
  render="$(sed -n 's/^GPU_RENDER_NODE=//p' <<< "$out")"
  for name in $targets; do
    printf -v "GPU_RESULT_$(target_var_prefix "$name")" '%s|%s|%s|%s|%s' "$state" "$vendor" "$render" \
      "$(sed -n 's/^GPU_NVIDIA_MINOR=//p' <<< "$out")" "$(sed -n 's/^GPU_PCI=//p' <<< "$out")"
  done
  if [[ "$state" != ready ]]; then
    echo "No GPU (${state}): ${targets} will run without one."
    return 0
  fi
  case "$vendor" in
    nvidia)
      HOST_GPU_CUDA_ARCH="$(sed -n 's/^GPU_CUDA_ARCH=//p' <<< "$out")"
      echo "NVIDIA GPU ready: ${gen:-} (compute capability ${HOST_GPU_CUDA_ARCH})." ;;
    amd) echo "AMD Radeon GPU ready: ${gen} ($(sed -n 's/^GPU_GFX=//p' <<< "$out"), ${render} and /dev/kfd)." ;;
    *) echo "Intel Arc GPU ready: ${gen} (${render})." ;;
  esac
}

# prepare_host_gpu: before anything is created, make sure each selected GPU
# target finds a working driver for its GPU on this host.
# tools/setup-host-gpu.sh reports a working one, or (with consent) sets up the
# driver: NVIDIA's from the repository, or the kernel's amdgpu, i915 or xe for
# AMD Radeon and Intel Arc. It runs once per card chosen in prompt_target_gpus
# (targets that chose the same card share the run), and once for the targets
# without a chosen card (the NVIDIA-only ones), which must share one vendor.
# Targets that need the GPU stop the install without one; those that only use
# it when present go on without. A target that chose none runs on the CPU.
prepare_host_gpu() {
  local name need vendors gens v kept card line vendor_list="nvidia,amd,intel" mode
  local -a required=() optional=() args=() wants=() cards=()
  local -A card_targets=() card_need=() card_args=()
  for name in ${TARGETS:-}; do
    IFS='|' read -r need vendors gens <<< "$(target_gpu_spec "$name")"
    [[ -n "$need" ]] || continue
    card="$(target_setting "$name" GPU_CARD)"
    if [[ "${card,,}" == none ]]; then
      printf -v "GPU_RESULT_$(target_var_prefix "$name")" '%s' "declined||||"
      echo "${name} runs on the CPU (no GPU chosen)."
      continue
    fi
    if [[ -n "$card" ]]; then
      line="$(host_gpu_card "$card")" || { echo "${name}: no GPU at ${card} on this host." >&2; return 1; }
      card="${line%%|*}"
      [[ -n "${card_targets[$card]:-}" ]] || cards+=("$card")
      card_targets[$card]+="${card_targets[$card]:+ }${name}"
      [[ "${card_need[$card]:-}" == required ]] || card_need[$card]="$need"
      [[ -z "$gens" ]] || card_args[$card]+="${card_args[$card]:+ }--allow ${gens}:${name}"
      continue
    fi
    case "$need" in
      required) required+=("$name") ;;
      *) optional+=("$name") ;;
    esac
    wants+=("${name} (${vendors//,/\/})")
    kept=""
    for v in ${vendor_list//,/ }; do
      [[ ",$vendors," != *",$v,"* ]] || kept+="${kept:+,}$v"
    done
    vendor_list="$kept"
    [[ -z "$gens" ]] || args+=(--allow "${gens}:${name}")
  done
  if (( ${#required[@]} + ${#optional[@]} )) && [[ -z "$vendor_list" ]]; then
    echo "The selected targets cannot share one GPU: ${wants[*]}." >&2
    echo "Deselect one, or set BACKEND (llama.cpp) or GPU (Ollama, ComfyUI) to match. Nothing was created." >&2
    return 1
  fi
  for card in "${cards[@]}"; do
    line="$(host_gpu_card "$card")"
    IFS='|' read -r _ v _ <<< "$line"
    # shellcheck disable=SC2086  # --allow <gens>:<name> pairs
    run_host_gpu_tool "${card_need[$card]}" "$v" "$card" "${card_targets[$card]}" ${card_args[$card]:-} || return 1
  done
  if (( ${#required[@]} + ${#optional[@]} )); then
    if (( ${#required[@]} )); then mode=required; else mode=optional; fi
    run_host_gpu_tool "$mode" "$vendor_list" "" "${required[*]}${required[*]:+${optional[*]:+ }}${optional[*]}" "${args[@]}" || return 1
  fi
}

# target_gpu_env NAME: the GPU settings a target gets from prepare_host_gpu
# (NAME=value lines), unless they were preset: GPU for Ollama and ComfyUI and,
# for a chosen card, GPU_CARD (its PCI address); for llama.cpp BACKEND (cuda
# or vulkan) and GPU_DEVICES: the card's render node for Vulkan, its
# /dev/nvidia<minor> with the control and UVM devices for CUDA.
target_gpu_env() {
  local state vendor render minor pci
  IFS='|' read -r state vendor render minor pci <<< "$(target_gpu_result "$1")"
  [[ -n "$state" ]] || return 0
  case "$1" in
    ollama|comfyui)
      if [[ -z "${GPU:-}" || "${GPU}" == auto ]]; then
        if [[ $state == ready ]]; then echo "GPU=${vendor}"; else echo "GPU=none"; fi
      fi
      if [[ $state == ready && -n "$pci" ]]; then echo "GPU_CARD=${pci}"; fi ;;
    llamacpp)
      local backend="${BACKEND:-}"
      if [[ -z "$backend" && $state == ready ]]; then
        case "$vendor" in nvidia) backend=cuda ;; amd|intel) backend=vulkan ;; esac
        echo "BACKEND=${backend}"
      fi
      [[ -z "${GPU_DEVICES:-}" && $state == ready ]] || return 0
      if [[ "$backend" == vulkan && -n "$render" ]]; then
        echo "GPU_DEVICES=${render}"
      elif [[ "$backend" == cuda && -n "$minor" ]]; then
        echo "GPU_DEVICES=/dev/nvidia${minor} /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools"
      fi ;;
  esac
}

# Strata, Basalt, Maya and Xolotl take a template; the others choose or prompt for theirs.
target_needs_template() { [[ "$1" == strata || "$1" == basalt || "$1" == maya || "$1" == xolotl ]]; }

# The newer NVIDIA repositories do not carry the targets' CUDA defaults.
# Keep an explicit user choice, including an unavailable one (the target's
# preflight explains that error before it creates a CT).
target_cuda_env() {
  local name=$1 template=$2 key release
  case "$name" in
    basalt) key=CUDA_VERSION ;;
    maya) key=MAYA_CUDA_VERSION ;;
    xolotl) key=XOLOTL_CUDA_VERSION ;;
    *) return 0 ;;
  esac
  [[ -z ${!key:-} ]] || return 0
  case "$template" in
    *:vztmpl/ubuntu-26.04-*) release=13.3 ;;
    *:vztmpl/debian-13-*) release=13.1 ;;
    *) return 0 ;;
  esac
  printf '%s=%s\n' "$key" "$release"
}

# A selection is blank, "none", or target names and/or menu numbers separated
# by commas or spaces.
valid_target_selection() {
  local sel="${1//,/ }" token count
  count="$(target_table | wc -l)"
  [[ -z "${sel// /}" || "${sel// /}" == none ]] && return 0
  for token in $sel; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      (( 10#$token >= 1 && 10#$token <= count )) || return 1
    else
      target_field "$token" phase >/dev/null || return 1
    fi
  done
}
# normalize_target_selection SEL: the selected names, in table order, once each.
normalize_target_selection() {
  local sel="${1//,/ }" token wanted=" " name i=0
  [[ "${sel// /}" == none ]] && sel=""
  for token in $sel; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      token="$(target_table | awk -F'|' -v n="$((10#$token))" 'NR == n {print $1}')"
    fi
    wanted+="${token} "
  done
  local picked=()
  while IFS='|' read -r name _; do
    i=$((i + 1))
    if [[ "$wanted" == *" ${name} "* ]]; then picked+=("$name"); fi
  done < <(target_table)
  printf '%s\n' "${picked[*]:-}"
}

prompt_target_selection() {
  local name phase label i=0 prev_phase=""
  TARGETS=""
  # INSTALL_GITEA / INSTALL_MATTERMOST (the earlier yes/no questions) pre-select.
  [[ "$INSTALL_GITEA" != "true" ]] || INSTALL_TARGETS="gitea ${INSTALL_TARGETS:-}"
  [[ "$INSTALL_MATTERMOST" != "true" ]] || INSTALL_TARGETS="mattermost ${INSTALL_TARGETS:-}"
  if [[ "$NONINTERACTIVE" == "true" ]]; then
    valid_target_selection "$INSTALL_TARGETS" || {
      echo "Invalid INSTALL_TARGETS: '${INSTALL_TARGETS}'" >&2; return 1; }
    if [[ -n "$(normalize_target_selection "$INSTALL_TARGETS")" ]]; then
      echo "INSTALL_TARGETS (or INSTALL_GITEA/INSTALL_MATTERMOST) needs an interactive run" >&2
      echo "(the community-script menus, GPU selection and the Open WebUI admin key)." >&2
      echo "Install OSR unattended without it, then run" >&2
      echo "targets/<name>/provision-lxc.sh for each target." >&2
      return 1
    fi
    return 0
  fi
  echo
  echo "--- Optional targets, each in its own LXC ---"
  while IFS='|' read -r name phase label _; do
    i=$((i + 1))
    if [[ "$phase" != "$prev_phase" ]]; then
      case "$phase" in
        service) echo "Services: created now, before OSR, and connected to it." ;;
        model) echo "Model servers: created after OSR and added to its server list." ;;
        companion) echo "Companions: added to OSR's Open WebUI once it is running." ;;
      esac
    fi
    printf '  %d) %-14s %s\n' "$i" "$name" "$label"
    prev_phase="$phase"
  done < <(target_table)
  echo "Target-specific settings (GPU_DEVICES, BACKEND, STRATA_MODEL, HERMES_MODEL, COMFYUI_MODEL_URL, ...) are read"
  echo "from the environment as each target's README describes."
  prompt_until_valid "Targets to create (numbers or names, comma-separated; none)" \
    INSTALL_TARGETS "${INSTALL_TARGETS:-none}" valid_target_selection || return 1
  TARGETS="$(normalize_target_selection "$INSTALL_TARGETS")"
  [[ -n "$TARGETS" ]] || return 0
  for name in $TARGETS; do
    if [[ ! -r "${TARGETS_DIR}/${name}/provision-lxc.sh" ]]; then
      echo "Cannot install ${name}: ${TARGETS_DIR}/${name}/provision-lxc.sh is missing." >&2
      echo "Run the OSR installer from the full repository checkout." >&2
      return 1
    fi
  done
  echo "Selected targets: ${TARGETS}"
}

# Validators for the per-target prompts. TARGET_RESERVED_IDS / _IPS hold the
# router's and the earlier targets' values.
valid_target_ct_id() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || return 1
  [[ " ${TARGET_RESERVED_IDS:-} " != *" $1 "* ]] || { echo "    CT $1 is already used by this install." >&2; return 1; }
  ct_id_free "$1" || { echo "    CT $1 already exists." >&2; return 1; }
}
valid_target_ip() {
  valid_cidr "$1" || return 1
  [[ " ${TARGET_RESERVED_IPS:-} " != *" ${1%/*} "* ]] || { echo "    ${1%/*} is already used by this install." >&2; return 1; }
}
valid_target_template() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-22\.04|ubuntu-24\.04|ubuntu-26\.04|debian-12|debian-13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]]
}
valid_strata_template() {
  valid_target_template "$1" && [[ "$1" != *:vztmpl/ubuntu-26.04-* ]]
}
show_strata_template_alternatives() {
  local selected="$1" storage ref shown=0
  while IFS= read -r storage; do
    while IFS= read -r ref; do
      [[ "$ref" != "$selected" ]] && valid_strata_template "$ref" || continue
      if (( shown == 0 )); then
        echo "    Other downloaded Strata templates (enter a reference to use one):"
        shown=1
      fi
      printf '      %s\n' "$ref"
    done < <(pveam list "$storage" 2>/dev/null | awk 'NR > 1 {print $1}' | sort -V -r)
  done < <(template_storages)
}
valid_comfyui_variant() { [[ $1 == klein-4b || $1 == klein-9b ]]; }
valid_hf_token() { [[ $1 =~ ^hf_[A-Za-z0-9]{30,}$ ]]; }

# host_gpu_cuda_arch: GPU 0's compute capability (86), from the GPU step or,
# before it has run (the template prompts come first), from nvidia-smi.
host_gpu_cuda_arch() {
  local cap
  if [[ -n ${HOST_GPU_CUDA_ARCH:-} ]]; then printf '%s\n' "$HOST_GPU_CUDA_ARCH"; return 0; fi
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader -i 0 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ $cap =~ ^([0-9]+)\.([0-9])$ ]] && printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  return 0
}
# gpu_target_template_order NAME: the template distributions to prefer for a
# GPU target. Debian 13 first: its NVIDIA repository starts at CUDA 13.1, the
# release nearest the host's 580 driver (Ubuntu 26.04's starts at 13.3, which
# NVIDIA pairs with the 610 driver and which runs on 580 only under minor-version
# compatibility). Ubuntu 26.04 is next for Basalt, Maya and Xolotl; Strata's
# upstream setup does not support it. Maya on a card CUDA 13 cannot build for
# (compute capability below 7.5, e.g. a V100) needs CUDA 12.x, which only the
# Ubuntu 24.04/22.04 and Debian 12 repositories carry.
gpu_target_template_order() {
  case "$1" in
    strata) echo debian-13 ubuntu-24.04 ubuntu-22.04 debian-12 ;;
    maya)
      local arch
      arch="$(host_gpu_cuda_arch)"
      if [[ $arch =~ ^[0-9]+$ ]] && (( arch < 75 )); then
        echo ubuntu-24.04 ubuntu-22.04 debian-12
      else
        echo debian-13 ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 debian-12
      fi ;;
    *) echo debian-13 ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 debian-12 ;;
  esac
}
# default_gpu_target_template NAME: the newest downloaded template of the first
# distribution in NAME's order that has one, else the newest template of the
# first distribution pveam can download into TEMPLATE_STORAGE.
default_gpu_target_template() {
  local storage distro ref name order first
  order="$(gpu_target_template_order "${1:-}")"
  first="${order%% *}"
  for distro in $order; do
    while IFS= read -r storage; do
      ref="$(pveam list "$storage" 2>/dev/null |
        awk -v p="^${storage}:vztmpl/${distro}-standard_" '$1 ~ p && $1 ~ /_amd64\.tar\.(zst|gz|xz)$/ {print $1}' |
        sort -V | tail -n 1)"
      if [[ -n "$ref" ]]; then printf '%s\n' "$ref"; return 0; fi
    done < <(template_storages)
  done
  name="$(pveam available --section system 2>/dev/null |
    awk -v p="^${first}-standard_" '$2 ~ p && $2 ~ /_amd64\.tar\.(zst|gz|xz)$/ {print $2}' | sort -V | tail -n 1)"
  [[ -n "$name" ]] || return 1
  printf '%s:vztmpl/%s\n' "$TEMPLATE_STORAGE" "$name"
}
# ensure_target_template REF: download REF with pveam unless it is there.
ensure_target_template() {
  local storage="${1%%:*}" name="${1#*:vztmpl/}"
  pveam list "$storage" 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq -- "$1" && return 0
  echo "Downloading template ${name} to ${storage}."
  pveam download "$storage" "$name"
}

# For each selected target: CT ID, static address and storage (and a template
# for Strata, Basalt, Maya and Xolotl), asked now so a typo costs a re-prompt. Presets:
# <NAME>_CT_ID, <NAME>_IP_CIDR, <NAME>_STORAGE, <NAME>_TEMPLATE.
prompt_target_settings() {
  local name prefix id_var ip_var storage_var template_var default ip
  [[ -n "${TARGETS:-}" ]] || return 0
  echo
  echo "--- Target containers ---"
  echo "  Each target gets a static address on ${BRIDGE} with gateway ${GATEWAY},"
  echo "  so OSR can reach it."
  TARGET_RESERVED_IDS="$CT_ID"
  TARGET_RESERVED_IPS="${IP_CIDR%/*}"
  for name in $TARGETS; do
    prefix="$(target_var_prefix "$name")"
    id_var="${prefix}_CT_ID"; ip_var="${prefix}_IP_CIDR"
    storage_var="${prefix}_STORAGE"; template_var="${prefix}_TEMPLATE"
    echo "  ${name}: $(target_field "$name" label)"
    default="${!id_var:-}"
    if [[ -z "$default" ]]; then
      # shellcheck disable=SC2086  # a list of IDs
      default="$(next_free_ct_id_excluding $TARGET_RESERVED_IDS)" || return 1
    fi
    prompt_until_valid "    CT ID" "$id_var" "$default" valid_target_ct_id || return 1
    TARGET_RESERVED_IDS+=" ${!id_var}"
    prompt_until_valid "    IP address / CIDR" "$ip_var" "${!ip_var:-}" valid_target_ip || return 1
    ip="${!ip_var}"
    TARGET_RESERVED_IPS+=" ${ip%/*}"
    if ! ip_in_same_subnet "$ip" "$GATEWAY"; then
      echo "    WARNING: gateway ${GATEWAY} is outside ${ip}." >&2
    fi
    prompt_until_valid "    Storage" "$storage_var" "${!storage_var:-$STORAGE}" valid_nonempty || return 1
    if [[ $name == comfyui ]]; then
      echo "    Image model; the CT install downloads its diffusion model, text encoder and VAE:"
      echo "      klein-4b  FLUX.2 Klein 4B distilled: Apache 2.0, a 12.5 GB download"
      echo "      klein-9b  FLUX.2 Klein 9B distilled: FLUX Non-Commercial License, an 18.4 GB"
      echo "                download; gated, so it needs a Hugging Face token"
      prompt_until_valid "    Image model" COMFYUI_IMAGE_VARIANT "${COMFYUI_IMAGE_VARIANT:-klein-4b}" \
        valid_comfyui_variant || return 1
      if [[ $COMFYUI_IMAGE_VARIANT == klein-9b && -z ${TARGET_HF_TOKEN:-} ]]; then
        echo "    Accept the license at https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8"
        echo "    with your Hugging Face account, then create a read token (Settings > Access Tokens)."
        while true; do
          if ! read -r -s -p "    Hugging Face token (hf_...): " TARGET_HF_TOKEN; then
            echo; echo "    No Hugging Face token was entered." >&2; TARGET_HF_TOKEN=""; return 1
          fi
          echo
          valid_hf_token "$TARGET_HF_TOKEN" && break
          echo "    That is not a Hugging Face access token (hf_...)." >&2
        done
      fi
    fi
    if target_needs_template "$name"; then
      default="${!template_var:-}"
      if [[ $name == strata ]]; then
        [[ -n "$default" ]] || default="${TEMPLATE_REF:-}"
        [[ -n "$default" ]] || default="$(default_gpu_target_template "$name")" || default=""
        [[ "$NONINTERACTIVE" == true ]] || show_strata_template_alternatives "$default"
        prompt_until_valid "    Template (Ubuntu 22.04/24.04 or Debian 12/13; downloaded if missing)" \
          "$template_var" "$default" valid_strata_template || return 1
      else
        [[ -n "$default" ]] || default="$(default_gpu_target_template "$name")" || default=""
        prompt_until_valid "    Template (Ubuntu 22.04/24.04/26.04 or Debian 12/13; downloaded if missing; Ubuntu 26.04 needs CUDA 13.3+)" \
          "$template_var" "$default" valid_target_template || return 1
      fi
    fi
  done
}

# target_server_entry NAME: the router's server entry for a model target.
target_server_entry() {
  local name="$1" prefix ip_var entry port_var
  prefix="$(target_var_prefix "$name")"
  ip_var="${prefix}_IP_CIDR"; port_var="${prefix}_PORT"
  entry="$(target_field "$name" entry)" || return 1
  [[ -n "$entry" ]] || return 1
  entry="${entry//@IP@/${!ip_var%/*}}"
  printf '%s\n' "${entry//@PORT@/${!port_var:-8080}}"
}

# The model targets go first in the server prompt, so they get tiers and are in
# the router's configuration from the start. Configured defaults move behind
# them; raise the count to keep existing servers too.
preset_target_model_servers() {
  local name i from to n entries=()
  for name in ${TARGETS:-}; do
    [[ "$(target_field "$name" phase)" == model ]] || continue
    entries+=("$(target_server_entry "$name")")
  done
  n=${#entries[@]}
  (( n > 0 )) || return 0
  for (( i = MODEL_SERVER_MAX; i > n; i-- )); do
    from="MODEL_SERVER_$(( i - n ))"; to="MODEL_SERVER_${i}"
    printf -v "$to" '%s' "${!from:-}"
  done
  for (( i = 1; i <= n; i++ )); do
    printf -v "MODEL_SERVER_${i}" '%s' "${entries[i - 1]}"
  done
  MODEL_SERVER_COUNT=$n
  echo
  echo "  The new model targets are servers 1-${n} below. They answer once they are"
  echo "  created after OSR; until then OSR skips them. Raise the"
  echo "  count to keep other servers as well."
}

# run_target_provisioner NAME: the target's provision-lxc.sh with its own CT
# settings. Runs in a subshell: the router's CT_ID, IP_CIDR, CORES, ROOTFS_GB
# and the like must not reach a target, and the admin token only reaches the
# companions (as an environment variable, never an argument).
run_target_provisioner() {
  local name="$1" phase script id ip storage template image_variant hf_token="" gpu_env cuda_env
  local -a flags=()
  phase="$(target_field "$name" phase)" || return 1
  script="${TARGETS_DIR}/${name}/provision-lxc.sh"
  [[ -r "$script" ]] || { echo "Missing ${script}." >&2; return 1; }
  id="$(target_setting "$name" CT_ID)"
  ip="$(target_setting "$name" IP_CIDR)"
  storage="$(target_setting "$name" STORAGE)"
  template="$(target_setting "$name" TEMPLATE)"
  image_variant="$(target_setting "$name" IMAGE_VARIANT)"
  # Only ComfyUI's gated klein-9b weights need the Hugging Face token.
  if [[ $name == comfyui && $image_variant == klein-9b ]]; then hf_token="${TARGET_HF_TOKEN:-}"; fi
  [[ -n "$id" && -n "$ip" ]] || { echo "${name}: no CT ID or address was chosen." >&2; return 1; }
  case "$name" in
    ollama|airllm) flags=(--install-target) ;;
    llamacpp) if llamacpp_model_given; then flags=(--install-target); fi ;;
    open-terminal|hermes) template="${template:-${TEMPLATE_REF:-}}" ;;
  esac
  local script_url script_sha channel="${MATTERMOST_CHANNEL:-ollama-monitor}"
  script_url="$(target_setting "$name" COMMUNITY_SCRIPT_URL)"
  script_sha="$(target_setting "$name" COMMUNITY_SCRIPT_SHA256)"
  gpu_env="$(target_gpu_env "$name")"
  cuda_env="$(target_cuda_env "$name" "$template")"
  (
    local router_ct="$CT_ID" gateway="$GATEWAY" bridge="$BRIDGE" nameserver="$NAMESERVER"
    local webui_port="$OPENWEBUI_PORT" admin_token="${TARGET_ADMIN_TOKEN:-}"
    unset CT_ID CT_NAME CT_HOSTNAME IP_CIDR GATEWAY STORAGE BRIDGE NAMESERVER VLAN_TAG \
      CORES MEMORY MEMORY_MB SWAP SWAP_MB ROOTFS_GB ONBOOT TEMPLATE FIREWALL NONINTERACTIVE \
      ROUTER ROUTER_CT_ID ROUTER_SSH_HOST ROUTER_IP ROUTER_URL ROUTER_API_KEY \
      OPENWEBUI_PORT OPENWEBUI_ADMIN_TOKEN TARGET_ADMIN_TOKEN COMFYUI_IMAGE_VARIANT \
      HF_TOKEN TARGET_HF_TOKEN
    export CT_ID="$id" IP_CIDR="$ip" GATEWAY="$gateway" STORAGE="$storage" BRIDGE="$bridge"
    [[ -z "$nameserver" ]] || export NAMESERVER="$nameserver"
    [[ -z "$template" ]] || export TEMPLATE="$template"
    # GITEA_COMMUNITY_SCRIPT_URL / _SHA256 (and MATTERMOST_*) select and pin a
    # service's community script; the provisioner calls them COMMUNITY_SCRIPT_*.
    unset COMMUNITY_SCRIPT_URL COMMUNITY_SCRIPT_SHA256
    [[ -z "$script_url" ]] || export COMMUNITY_SCRIPT_URL="$script_url"
    [[ -z "$script_sha" ]] || export COMMUNITY_SCRIPT_SHA256="$script_sha"
    [[ "$name" != mattermost ]] || export MATTERMOST_CHANNEL="$channel"
    [[ "$name" != comfyui ]] || export COMFYUI_IMAGE_VARIANT="$image_variant"
    [[ -z "$hf_token" ]] || export HF_TOKEN="$hf_token"
    local setting
    while IFS= read -r setting; do
      [[ -z "$setting" ]] || export "${setting?}"
    done <<< "$gpu_env"
    [[ -z "$cuda_env" ]] || export "${cuda_env?}"
    if [[ "$phase" == companion ]]; then
      export ROUTER_CT_ID="$router_ct" OPENWEBUI_PORT="$webui_port"
      OPENWEBUI_ADMIN_TOKEN="$admin_token" exec bash "$script" "${flags[@]}"
    fi
    exec bash "$script" "${flags[@]}"
  )
}

# service_result NAME FILE: one of a service CT's /etc/<name>-target/ results.
service_result() {
  pct exec "$(target_setting "$1" CT_ID)" -- cat "/etc/${1}-target/$2" 2>/dev/null | tr -d '\r\n'
}

# provision_service_targets: create the selected services now, before the
# router is built, and take what the router needs from them: Gitea's URL,
# router account and token, Mattermost's webhook. They become the defaults of
# the Gitea and Mattermost prompts (which still check them). A failure stops
# the install before anything for the router exists; the CT stays.
provision_service_targets() {
  local name id value
  SERVICES_DONE=""
  for name in ${TARGETS:-}; do
    [[ "$(target_field "$name" phase)" == service ]] || continue
    id="$(target_setting "$name" CT_ID)"
    echo
    echo "=== Target ${name} (CT ${id}), before OSR ==="
    if ! run_target_provisioner "$name"; then
      echo "Creating ${name} failed. CT ${id}, if it was made, is kept: repair it with" >&2
      echo "  CT_ID=${id} bash ${TARGETS_DIR}/${name}/provision-lxc.sh --reconfigure" >&2
      echo "then rerun the OSR installer without selecting ${name}." >&2
      return 1
    fi
    case "$name" in
      gitea)
        GITEA_SERVER_URL="$(service_result gitea url)"
        GITEA_ADMIN_USER="$(service_result gitea router-user)"
        GITEA_DEPLOY_TOKEN="$(service_result gitea router-token)"
        if [[ -z "$GITEA_SERVER_URL" || -z "$GITEA_ADMIN_USER" || -z "$GITEA_DEPLOY_TOKEN" ]]; then
          echo "Gitea in CT ${id} gave no URL, OSR account or token (/etc/gitea-target/)." >&2
          return 1
        fi
        echo "Gitea at ${GITEA_SERVER_URL}: OSR uses its account ${GITEA_ADMIN_USER}." ;;
      mattermost)
        value="$(service_result mattermost webhook-url)"
        if [[ -z "$value" ]]; then
          echo "Mattermost in CT ${id} gave no webhook URL (/etc/mattermost-target/webhook-url)." >&2
          return 1
        fi
        MATTERMOST_WEBHOOK_URL="$value"
        echo "Mattermost alerts go to its channel ${MATTERMOST_CHANNEL:-ollama-monitor}." ;;
    esac
    SERVICES_DONE+="${name} "
  done
}

# register_target_key NAME: give the router a Strata-style target's generated
# key (set-<kind>-token reads it from stdin, twice, so it never is an argument).
# Targets without a key need nothing.
register_target_key() {
  local name="$1" kind id key
  kind="$(target_field "$name" key)" || return 1
  [[ -n "$kind" ]] || return 0
  id="$(target_setting "$name" CT_ID)"
  key="$(pct exec "$id" -- cat "/etc/${kind}-target/api-key" 2>/dev/null | tr -d '\r\n')" || key=""
  if [[ -z "$key" ]]; then
    echo "WARNING: could not read /etc/${kind}-target/api-key in CT ${id}; set it on OSR" >&2
    echo "         with: manage-model-servers set-${kind}-token --apply" >&2
    return 1
  fi
  printf '%s\n%s\n' "$key" "$key" | run_ct /usr/local/bin/manage-model-servers "set-${kind}-token"
}

# wait_for_openwebui: Open WebUI's first start downloads an embedding model.
wait_for_openwebui() {
  local deadline=$(( SECONDS + ${OPENWEBUI_WAIT_SECONDS:-900} ))
  echo "Waiting for Open WebUI to finish its first start..."
  while (( SECONDS < deadline )); do
    if run_ct curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:${OPENWEBUI_PORT}/health" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  echo "Open WebUI did not answer within ${OPENWEBUI_WAIT_SECONDS:-900}s." >&2
  return 1
}

# prompt_openwebui_admin_token: the companions register through Open WebUI's
# admin API, and its first account (the admin) is created in the browser.
prompt_openwebui_admin_token() {
  [[ -z "${TARGET_ADMIN_TOKEN:-}" ]] || return 0
  echo
  echo "--- Open WebUI admin key for the companions ---"
  echo "  1. Open http://${IP_CIDR%/*}:${OPENWEBUI_PORT} and create the admin account."
  echo "  2. Admin Settings > Authentication: enable API keys."
  echo "  3. Settings > Account > API keys: create a key, and paste it here."
  read -r -s -p "Open WebUI admin API key or JWT (blank skips the companions): " TARGET_ADMIN_TOKEN || true
  echo
  [[ -n "$TARGET_ADMIN_TOKEN" ]]
}

# provision_selected_targets: after the router is up, create the model
# targets, give the router their keys, then add the companions. A failed target
# leaves the router as it is; the summary says how to retry.
provision_selected_targets() {
  local name id companions=false status=0
  local -a key_targets=()
  declare -A result=()
  [[ -n "${TARGETS:-}" ]] || return 0
  for name in $TARGETS; do
    case "$(target_field "$name" phase)" in
      service)
        if [[ " ${SERVICES_DONE:-} " == *" ${name} "* ]]; then result[$name]="ok (created before OSR)"; fi
        continue ;;
      companion) companions=true; continue ;;
    esac
    id="$(target_setting "$name" CT_ID)"
    echo
    echo "=== Target ${name} (CT ${id}) ==="
    if target_needs_template "$name" &&
       ! ensure_target_template "$(target_setting "$name" TEMPLATE)"; then
      result[$name]="failed (template download)"; continue
    fi
    if ! run_target_provisioner "$name"; then
      result[$name]=failed; continue
    fi
    result[$name]=ok
    if [[ "$name" == llamacpp ]] && ! llamacpp_model_given; then
      result[$name]="ok (CT only: run install-target.sh in it with a model)"
    fi
    if [[ -n "$(target_field "$name" key)" ]]; then
      if register_target_key "$name"; then
        key_targets+=("$name")
      else
        result[$name]="ok (OSR key not set)"
      fi
    fi
  done
  if (( ${#key_targets[@]} > 0 )); then
    echo "Applying the target keys on OSR."
    if ! run_ct /usr/local/bin/manage-model-servers apply; then
      echo "ERROR: manage-model-servers apply failed in OSR CT ${CT_ID}." >&2
      for name in "${key_targets[@]}"; do
        result[$name]="failed (OSR key apply)"
      done
    fi
  fi
  if $companions; then
    if wait_for_openwebui && prompt_openwebui_admin_token; then
      for name in $TARGETS; do
        [[ "$(target_field "$name" phase)" == companion ]] || continue
        echo
        echo "=== Target ${name} (CT $(target_setting "$name" CT_ID)) ==="
        if run_target_provisioner "$name"; then result[$name]=ok; else result[$name]=failed; fi
      done
    else
      for name in $TARGETS; do
        [[ "$(target_field "$name" phase)" == companion ]] && result[$name]="skipped (no Open WebUI admin key)"
      done
    fi
    TARGET_ADMIN_TOKEN=""
    TARGET_HF_TOKEN=""
  fi
  echo
  echo "=============================================================================="
  echo "Targets:"
  for name in $TARGETS; do
    id="$(target_setting "$name" CT_ID)"
    printf '  %-14s CT %-6s %s\n' "$name" "$id" "${result[$name]:-not run}"
    if [[ "${result[$name]:-}" != ok* || "${result[$name]}" == *"not set"* ]]; then
      status=1
      if [[ "${result[$name]}" == "failed (OSR key apply)" ]]; then
        echo "                 run pct exec ${CT_ID} -- /usr/local/bin/manage-model-servers apply"
      else
        echo "                 see targets/${name}/README.md; rerun targets/${name}/provision-lxc.sh"
      fi
    fi
  done
  echo "=============================================================================="
  return "$status"
}

# --- interactive configuration ----------------------------------------------
# The router's CT ID. The default offered is the CT_ID preset, else the
# cluster's next free ID; any other free ID can be typed in. An ID that is
# malformed or already in use anywhere in the cluster is refused and re-asked
# (with NONINTERACTIVE=true it stops the install instead).
prompt_router_ct_id() {
  local default="$CT_ID"
  if [[ -z "$default" ]]; then
    default="$(find_next_ct_id)" || return 1
  fi
  echo
  echo "--- Ollama Smart Router container ---"
  prompt_until_valid "OSR CT ID" CT_ID "$default" valid_router_ct_id
}
# Proxmox accepts guest IDs 100-999999999.
valid_router_ct_id() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || { echo "  A CT ID is a whole number from 100 to 999999999." >&2; return 1; }
  ct_id_free "$1" || { echo "  CT $1 is already in use in this cluster." >&2; return 1; }
}

prompt_network_config() {
  echo
  echo "--- Container network ---"
  prompt_until_valid "Proxmox bridge"            BRIDGE     "$BRIDGE"     valid_nonempty
  prompt_until_valid "OSR IP address / CIDR"     IP_CIDR    "$IP_CIDR"    valid_cidr
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
    echo "  The channel name is the URL handle (ollama-monitor), not the display"
    echo "  name. Leave it blank to post wherever the webhook itself is bound —"
    echo "  some servers reject an explicit channel override."
    prompt_value "Channel name"    MATTERMOST_CHANNEL      "$MATTERMOST_CHANNEL"
    prompt_value "Post as username" MATTERMOST_MONITOR_USER "$MATTERMOST_MONITOR_USER"
    prompt_until_valid "Verify the Mattermost TLS certificate (true/false)" \
      MATTERMOST_VERIFY_TLS "$MATTERMOST_VERIFY_TLS" valid_bool
  else
    echo "  No webhook — the monitor will log alerts instead of posting them."
  fi
}

# Default tier->server assignment for any server count from 1 upwards. Servers
# are split into four contiguous groups; the remainder goes to the xlarge tier,
# which benefits most from extra parallel capacity. Counts below 4 can't give
# every tier its own host, so the upper tiers share the last one — an xlarge
# model is the least likely to fit on an early, smaller host.
default_tier_selection() {
  local tier="$1" n="$MODEL_SERVER_COUNT" base
  local fast_start fast_end medium_start medium_end
  local large_start large_end xlarge_start xlarge_end
  if (( n <= 1 )); then
    echo "1"; return 0
  fi
  if (( n == 2 )); then
    case "$tier" in
      fast)   echo "1" ;;
      *)      echo "2" ;;      # medium, large and xlarge share the second host
    esac
    return 0
  fi
  if (( n == 3 )); then
    case "$tier" in
      fast)   echo "1" ;;
      medium) echo "2" ;;
      *)      echo "3" ;;      # large and xlarge share the third host
    esac
    return 0
  fi
  base=$(( n / 4 ))
  fast_start=1;                    fast_end=$(( base ))
  medium_start=$(( base + 1 ));    medium_end=$(( base * 2 ))
  large_start=$(( base * 2 + 1 )); large_end=$(( base * 3 ))
  xlarge_start=$(( base * 3 + 1 )); xlarge_end=$n         # absorbs the remainder
  case "$tier" in
    fast)   seq_csv "$fast_start" "$fast_end" ;;
    medium) seq_csv "$medium_start" "$medium_end" ;;
    large)  seq_csv "$large_start" "$large_end" ;;
    xlarge) seq_csv "$xlarge_start" "$xlarge_end" ;;
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
      prompt_until_valid "  Server ${i} (IP, host:port, URL, lmstudio://host, strata://host, basalt://host, maya://host or xolotl://host)" raw "$default_addr" valid_ollama_addr
    else
      while true; do
        read -r -p "  Server ${i} (IP, host:port, URL, lmstudio://host, strata://host, basalt://host, maya://host or xolotl://host): " raw
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

  prompt_until_valid "    large tier  (long / analytical)" tier_sel \
    "${TIER_LARGE_SERVERS:-$(default_tier_selection large)}" valid_tier_selection
  TIER_LARGE_IDX="$(tier_selection_to_indices "$tier_sel")"

  prompt_until_valid "    xlarge tier (deepest / 70B+)" tier_sel \
    "${TIER_XLARGE_SERVERS:-$(default_tier_selection xlarge)}" valid_tier_selection
  TIER_XLARGE_IDX="$(tier_selection_to_indices "$tier_sel")"

  echo
  echo "  Model tag served by each tier (must already be pulled on those hosts)."
  prompt_until_valid "    fast   model" MODEL_FAST   "$MODEL_FAST"   valid_nonempty
  prompt_until_valid "    medium model" MODEL_MEDIUM "$MODEL_MEDIUM" valid_nonempty
  prompt_until_valid "    large  model" MODEL_LARGE  "$MODEL_LARGE"  valid_nonempty
  prompt_until_valid "    xlarge model" MODEL_XLARGE "$MODEL_XLARGE" valid_nonempty

  echo
  echo "  Ollama unloads an idle model after 5 minutes by default. Set a"
  echo "  keep-alive here (e.g. 30m, 2h, or -1 to never unload), or leave it"
  echo "  blank to use whatever OLLAMA_KEEP_ALIVE each server is configured with."
  prompt_until_valid "    keep-alive" OLLAMA_KEEP_ALIVE "$OLLAMA_KEEP_ALIVE" valid_keep_alive

  echo
  echo "  Routing plan:"
  printf '    fast   -> %s (%s)\n' "$(indices_to_urls "$TIER_FAST_IDX")"   "$MODEL_FAST"
  printf '    medium -> %s (%s)\n' "$(indices_to_urls "$TIER_MEDIUM_IDX")" "$MODEL_MEDIUM"
  printf '    large  -> %s (%s)\n' "$(indices_to_urls "$TIER_LARGE_IDX")"  "$MODEL_LARGE"
  printf '    xlarge -> %s (%s)\n' "$(indices_to_urls "$TIER_XLARGE_IDX")" "$MODEL_XLARGE"

  # Servers that ended up in no tier would sit idle — worth saying out loud.
  local unused="" idx
  for (( idx = 0; idx < MODEL_SERVER_COUNT; idx++ )); do
    case " ${TIER_FAST_IDX} ${TIER_MEDIUM_IDX} ${TIER_LARGE_IDX} ${TIER_XLARGE_IDX} " in
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
  prompt_until_valid "Gitea server URL (https://..., blank = no Gitea)" GITEA_SERVER_URL \
    "$GITEA_SERVER_URL" valid_optional_url
  if [[ -z "$GITEA_SERVER_URL" ]]; then
    if [[ -n "$GITEA_DEPLOY_TOKEN" ]]; then
      echo "ERROR: GITEA_DEPLOY_TOKEN is set but GITEA_SERVER_URL is not. Set the" >&2
      echo "       Gitea URL (e.g. GITEA_SERVER_URL=https://git.example.net)." >&2
      exit 1
    fi
    echo "No Gitea server URL — configuration will be installed directly and NOT" >&2
    echo "version controlled. Set GITEA_SERVER_URL to use a Gitea repo." >&2
    CONFIG_SOURCE="local"
    return 0
  fi
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
        echo "         Check the scheme and port: a Gitea from tools/install-gitea.sh serves" >&2
        echo "         http on port 3000, while the TurnKey appliance serves 80/443 via" >&2
        echo "         nginx (its Gitea port 3000 is localhost-only inside that container)." >&2 ;;
    22) echo "WARNING: Gitea returned an HTTP error (likely 401 Unauthorized or 403 Forbidden)." >&2
        echo "         Existing repositories need read:user and write:repository." >&2
        echo "         Automatic repository creation also needs write:user (includes read:user)." >&2
        echo "         The same scopes cover an organisation-owned repository, but for any" >&2
        echo "         repository it does not own, the account needs Write access to it." >&2
        echo "         If the server redirects http:// to https://, use the https:// URL:" >&2
        echo "         the token is dropped on that redirect." >&2 ;;
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

is_installer_owned() {
  local want="$1" path
  for path in "${INSTALLER_OWNED_CODE[@]}"; do [[ "$path" == "$want" ]] && return 0; done
  return 1
}

# Given a Gitea contents-API JSON body on stdin and a local file, print the
# blob sha when the remote content DIFFERS from the file; print nothing when
# they are identical (or the body is unparseable).
gitea_sha_if_changed() {
  python3 -c '
import base64, json, sys
try:
    meta = json.load(sys.stdin)
    remote = base64.b64decode(meta.get("content") or "")
except Exception:
    sys.exit(0)
with open(sys.argv[1], "rb") as fh:
    local = fh.read()
if remote != local and meta.get("sha"):
    print(meta["sha"])
' "$1"
}

# Push the generated tree to the repo via the Gitea contents API.
#   * a file the repo lacks is created (anything you committed by hand wins);
#   * an INSTALLER-OWNED code file that differs is updated in place, when
#     CONFIG_UPDATE_CODE=true, so a re-install never leaves stale code behind.
# $2 is the deploy token.
seed_gitea_repo() {
  local tree="$1" token="$2"
  local base api auth owner resp http body sha rel content_b64 payload
  local created=0 skipped=0 updated=0
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
    content_b64="$(base64 -w0 < "${tree}/${rel}")"
    if [[ "$http" == "200" ]]; then
      sha=""
      if [[ "$CONFIG_UPDATE_CODE" == "true" ]] && is_installer_owned "$rel"; then
        body="${resp%$'\n'*}"
        sha="$(printf '%s' "$body" | gitea_sha_if_changed "${tree}/${rel}")"
      fi
      if [[ -z "$sha" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
      payload="$(python3 -c '
import json,sys
print(json.dumps({"message": "Update %s from installer" % sys.argv[1],
                  "content": sys.argv[2], "sha": sys.argv[3]}))' "$rel" "$content_b64" "$sha")"
      resp="$(gitea_api PUT "${api}/repos/${owner}/${GITEA_REPO_NAME}/contents/${rel}" "$payload")"
      http="${resp##*$'\n'}"
      if [[ "$http" == "200" ]]; then
        updated=$((updated + 1))
        echo "  updated: ${rel}" >&2
      else
        echo "  WARNING: failed to update ${rel} (HTTP ${http})" >&2
      fi
      continue
    fi
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

  echo "Repo seeding complete: ${created} created, ${updated} updated, ${skipped} already present." >&2
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

# Delete the provisioning test file just created. $6 is the create response,
# which carries the blob sha the contents API needs. Best effort: a failure
# only leaves the marker behind, so it is reported but never fatal.
remove_marker_file() {
  local api="$1" owner="$2" repo="$3" branch="$4" path="$5" created="$6" sha payload resp http
  sha="$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("content",{}).get("sha",""))' 2>/dev/null || true)"
  if [[ -z "$sha" ]]; then
    echo "NOTE: could not read the test file's sha; ${path} stays in the repo." >&2
    return 0
  fi
  payload="$(printf '{"message":"Remove provisioning test marker","sha":"%s","branch":"%s"}' "$sha" "$branch")"
  resp="$(gitea_api DELETE "${api}/repos/${owner}/${repo}/contents/${path}" "$payload")"
  http="${resp##*$'\n'}"
  if [[ "$http" == "200" ]]; then
    echo "Removed the test marker ${path}." >&2
  else
    echo "NOTE: could not remove ${path} (HTTP ${http}); delete it by hand if unwanted." >&2
  fi
  return 0
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
    echo "NOTE: GITEA_SERVER_URL uses http://, so the token is sent unencrypted." >&2
    echo "      That suits a Gitea on a trusted network (tools/install-gitea.sh serves" >&2
    echo "      http on port 3000). If the server redirects to HTTPS, as the TurnKey" >&2
    echo "      appliance does, use its https:// URL: curl drops the token on that" >&2
    echo "      redirect, which shows up as a 401." >&2
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
      # POST /user/repos can only create there, so a different explicit owner
      # (an organisation or another account) must hold the repository already.
      if [[ -n "$GITEA_REPO_OWNER" && "${GITEA_REPO_OWNER,,}" != "${owner,,}" ]]; then
        echo "WARNING: ${GITEA_REPO_OWNER}/${repo_name} does not exist, and the installer" >&2
        echo "         creates repositories only under the token owner (${owner})." >&2
        echo "         Create it in Gitea first and give ${owner} Write access to it," >&2
        echo "         or unset GITEA_REPO_OWNER to create ${owner}/${repo_name}." >&2
        return 1
      fi
      owner="$GITEA_OWNER"
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
    # The write access is proven; remove the marker again so every
    # provisioning run does not leave a provisioning-tests/<ts>.md behind.
    remove_marker_file "$api" "$owner" "$repo_name" "$branch" "$filepath" "$body"
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

# Which targets to create alongside the router (their settings follow below).
prompt_target_selection || exit 1

# Asked before the password prompt, which names the container by its ID.
prompt_router_ct_id || exit 1
ROOT_PASSWORD=""
GITEA_DEPLOY_TOKEN="${GITEA_DEPLOY_TOKEN:-}"
echo "Using container ID: ${CT_ID}"
prompt_secret "Root password for container ${CT_ID}" ROOT_PASSWORD

# Collect the rest of the configuration up front, before anything is built, so
# a typo costs a re-prompt rather than a failed provisioning run. Every prompt
# offers a default (Enter accepts); NONINTERACTIVE=true takes all defaults.
prompt_network_config
prompt_storage_config
echo "Updating Proxmox appliance template index."
pveam update
select_router_template || exit 1
prompt_target_settings || exit 1
# Which GPU each AMD/Intel-capable target gets, then the host driver for every
# chosen card: set up now, when missing, before anything is created (a reboot
# then costs nothing but a rerun).
prompt_target_gpus || exit 1
prepare_host_gpu || exit 1
# Gitea and Mattermost, if selected, are created now: the prompts below take
# their URL, token and webhook.
provision_service_targets || exit 1

# Ask for the Gitea URL, username + auth token and verify them against the
# server. GITEA_DEPLOY_TOKEN may be preset in the environment for unattended
# runs, in which case only the username prompt appears.
prompt_gitea_credentials

prompt_mattermost_config
preset_target_model_servers
prompt_model_servers

# Ensure the config repo exists and that the token can write to it. Non-fatal:
# on failure we fall back to installing the configuration locally.
if [[ "$CONFIG_SOURCE" == "repo" ]]; then
  if ! test_gitea_access "$GITEA_DEPLOY_TOKEN"; then
    echo "Gitea repo check failed — falling back to a local configuration." >&2
    CONFIG_SOURCE="local"
  fi
fi
require_companion_credentials || exit 1

if [[ -n "$DOWNLOAD_TEMPLATE_NAME" ]]; then
  echo "Downloading template ${DOWNLOAD_TEMPLATE_NAME} to ${TEMPLATE_STORAGE}."
  pveam download "$TEMPLATE_STORAGE" "$DOWNLOAD_TEMPLATE_NAME"
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
apt_get install -y python3 python3-pip python3-venv curl ca-certificates qemu-guest-agent

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
GITEA_VERIFY_TLS=${GITEA_VERIFY_TLS}
MATTERMOST_MONITOR_USER=${MATTERMOST_MONITOR_USER}
MATTERMOST_CHANNEL=${MATTERMOST_CHANNEL}
MATTERMOST_VERIFY_TLS=${MATTERMOST_VERIFY_TLS}
LITELLM_BASE_URL=http://127.0.0.1:4000
LITELLM_URL=http://127.0.0.1:4000/v1/chat/completions
LITELLM_HEALTH_URL=http://127.0.0.1:4000/health
BACKEND_FAST=$(indices_to_urls "$TIER_FAST_IDX")
BACKEND_MEDIUM=$(indices_to_urls "$TIER_MEDIUM_IDX")
BACKEND_LARGE=$(indices_to_urls "$TIER_LARGE_IDX")
BACKEND_XLARGE=$(indices_to_urls "$TIER_XLARGE_IDX")
MODEL_SERVER_COUNT=${MODEL_SERVER_COUNT}
MODEL_SERVERS=$(IFS=,; printf '%s' "${MODEL_SERVERS[*]}")
MODEL_FAST=${MODEL_FAST}
MODEL_MEDIUM=${MODEL_MEDIUM}
MODEL_LARGE=${MODEL_LARGE}
MODEL_XLARGE=${MODEL_XLARGE}
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
KEEP_ALIVE_REFRESH_SECONDS=${KEEP_ALIVE_REFRESH_SECONDS}
TORCH_CPU_ONLY=${TORCH_CPU_ONLY}
MONITOR_INTERVAL_SECONDS=15
OPENWEBUI_HEALTH_URL=http://127.0.0.1:${OPENWEBUI_PORT}/health
EOF
# --- secrets.env (NOT part of the repo tree) ---
# The deploy token and the webhook URL (whose path is itself a credential) never
# enter the config repo. They are pushed straight into the container as
# /app/router/secrets.env (0640 root:ollama-router) after apply-config.sh runs,
# and loaded by the units that need them via a second EnvironmentFile=.
SECRETS_STAGE="${STAGE_DIR}/secrets.env"
# The router API is authenticated from the first boot. Open WebUI is handed the
# same key as its OpenAI connection key (it persists it on first start).
[[ -n "$ROUTER_API_KEY" ]] || ROUTER_API_KEY="$(generate_api_key)"
( umask 077
  printf 'GITEA_DEPLOY_TOKEN=%s\nMATTERMOST_WEBHOOK_URL=%s\nROUTER_API_KEY=%s\nOPENAI_API_KEYS=%s\n' \
    "$GITEA_DEPLOY_TOKEN" "$MATTERMOST_WEBHOOK_URL" "$ROUTER_API_KEY" "$ROUTER_API_KEY" \
    > "$SECRETS_STAGE" )
# Keep one copy of the token in memory for the seeding + clone steps below,
# then clear the original.
GITEA_DEPLOY_TOKEN_KEEP="$GITEA_DEPLOY_TOKEN"
unset GITEA_DEPLOY_TOKEN

# --- router.py (quoted heredoc: no host expansion) ---
cat > "${REPO_DIR}/services/ollama-router/router.py" <<'PYEOF'
import asyncio
import configparser
import hmac
import ipaddress
import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from starlette.background import BackgroundTask
from fastapi.responses import JSONResponse, Response, StreamingResponse

logging.basicConfig(level=os.getenv("ROUTER_LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("router")
# httpx logs every request at INFO; the router logs its own decisions instead.
logging.getLogger("httpx").setLevel(logging.WARNING)

# The router is a drop-in OpenAI endpoint in front of the LiteLLM proxy.
# /v1/chat/completions has its model chosen by complexity analysis; every other
# /v1/* path (notably /v1/models, which Open WebUI calls to populate its model
# list) is proxied through unchanged.
LITELLM_BASE = os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_URL = os.getenv("LITELLM_URL", f"{LITELLM_BASE}/v1/chat/completions")

# Routing behaviour lives in router.ini (version controlled) so thresholds,
# keyword lists and discovery heuristics can change without editing this file.
# Built-in defaults keep the service working if the ini is missing or partial.
# Code signals. Bare "class " / "import " / "def " matched prose ("first class
# ticket", "import my contacts"), so those are regexes for their code shapes.
CODE_KEYWORD_DEFAULTS = [
    r"re:\bdef\s+\w+\s*\(", r"re:\bfn\s+\w+\s*\(", r"re:\bclass\s+\w+\s*[:({]",
    r"re:^\s*(?:from\s+\S+\s+)?import\s+[\w.]+", r"re:```", "function", "sql",
    "script", "code", "bug", "error", "compile", "stack trace", "regex",
]
_DEFAULTS = {
    "thresholds": {"xlarge": "2000", "large": "800", "medium": "250"},
    "keywords": {
        "code_first": "true",
        "code": json.dumps(CODE_KEYWORD_DEFAULTS),
        "large": json.dumps(["analyze", "evaluate", "optimise", "optimize",
                             "architecture", "mathematics", "calculate",
                             "summarise this article"]),
        "xlarge": json.dumps(["prove", "derive", "rigorous", "comprehensive",
                              "exhaustive", "step by step proof",
                              "entire codebase", "whole repository",
                              "research report", "literature review"]),
    },
    "tiers": {"fast": "fast", "medium": "medium", "large": "large",
              "xlarge": "xlarge"},
    "classification": {
        # What the keyword and length heuristics look at:
        #   last_user    -- the newest user message only (default). A system
        #                   prompt or an old turn can no longer pin every
        #                   request of a conversation to one tier.
        #   conversation -- every message, the pre-2026-09 behaviour.
        "scope": "last_user",
        # true: a request carrying an image fails with HTTP 400 when no
        # discovered model looks vision-capable. false: route it anyway and
        # flag it with an X-Router-Warning header.
        "vision_strict": "false",
        # Requests that carry tools (agents, function calling) are raised to at
        # least this class: small models are poor at tool use. Blank: no floor.
        # A tier alias named by the client still pins the class.
        "tools_min_class": "large",
        # true: a tool request fails with HTTP 400 when every discovered model
        # is known to lack tool support. false: route it anyway, flagged with
        # an X-Router-Warning header.
        "tools_strict": "false",
    },
    "http": {
        # Seconds to establish a TCP connection to a backend. Short on purpose:
        # this is how long a dead host delays failover to the next candidate.
        "connect_timeout_seconds": "3",
        # Seconds allowed between bytes of a response (generation can be slow).
        "read_timeout_seconds": "300",
    },
    "discovery": {
        "enabled": "true",
        "refresh_seconds": "60",
        "timeout_seconds": "5",
        # Comma-separated Ollama base URLs. Blank -> derive from BACKEND_* env.
        "servers": "",
        # Ask each server's /api/show for a model's real capabilities (vision,
        # embedding). Name matching below is the fallback.
        "capability_probe": "true",
        # LM Studio servers (MODEL_SERVERS entries written lmstudio+http://...)
        # load models on demand. true: only route to models already loaded
        # there (no multi-second JIT load on the request path).
        "lmstudio_loaded_only": "false",
        # Parameter-count bands (in billions) each request class prefers.
        "fast_params": "0:9",
        "medium_params": "9:20",
        "large_params": "20:70",
        "xlarge_params": "70:999",
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
        "prefer_larger": "0.15",
        "prefer_smaller": "0.15",
        "unknown_params": "0.3",
        # Fraction of the specialist weight applied as a penalty when a
        # specialised model (code/vision) is used for an off-task request.
        "offtask_penalty": "0.25",
        # Candidates within this score of the best are treated as equivalent and
        # rotated through, so identical models on several hosts share load.
        "tie_epsilon": "0.05",
        # Bonus for a model that is already resident in memory (LM Studio
        # reports this per model; Ollama entries are neutral).
        "loaded_bonus": "0.1",
        # Bonus, on a tool request, for a model the server reports as
        # tool-capable over one whose tool support is unknown.
        "tool_match": "0.3",
    },
    # Sizes for exact model ids that an OpenAI-compatible server (Strata,
    # Basalt, Maya, Xolotl) lists without a parameter count. Matching is by the whole
    # id, case-insensitive, so variants and aliases stay unknown-size unless
    # given a line of their own. A blank value removes a built-in entry.
    "model_sizes": {
        "strata": "125B",               # Strata's default id: Qwen3.8-Flash-Next
        "qwen3.8-flash-next": "125B",   # Basalt's default alias
        "glm-5.3-flash": "321B",        # Project Maya (GLM-5.3-Flash, 321B total)
        "deepseek-v4.1-flash": "552B",  # Xolotl's default id (DeepSeek-V4.1-Flash, 552B total)
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

    def norm(k):
        k = str(k)
        # Regex entries keep their case: lowering "\S" would turn it into "\s".
        return k if k.startswith("re:") else k.lower()
    try:
        return [norm(k) for k in json.loads(raw)]
    except (ValueError, TypeError):
        return [norm(k.strip()) for k in raw.split(",") if k.strip()]


def keyword_pattern(keywords: list):
    """Compile keywords into one case-insensitive, word-bounded regex.

    Plain substring matching misrouted ordinary prose: "script" matched
    "description"/"subscription", "code" matched "encode", "prove" matched
    "improve". Each keyword now has to start at a word boundary and end at one,
    allowing only a simple plural/past suffix ("bugs", "compiled"). A keyword
    written with a trailing space ("def ") must be followed by whitespace,
    preserving the old meaning of that convention. Spaces inside a phrase match
    any run of whitespace. An entry starting with "re:" is a regular expression
    (matched case-insensitively), for code shapes such as "class Foo:".
    """
    parts = []
    for raw in keywords:
        word = str(raw)
        if word.startswith("re:"):
            # A regular expression, for shapes a word list cannot express
            # (e.g. "class Foo:" as code but not "first class ticket").
            try:
                re.compile(word[3:])
            except re.error as exc:
                log.warning("ignoring invalid keyword regex %r: %s", raw, exc)
                continue
            parts.append("(?:%s)" % word[3:])
            continue
        word = word.lower()
        core = word.strip()
        if not core:
            continue
        body = r"\s+".join(re.escape(piece) for piece in core.split())
        tail = r"\s" if word.endswith(" ") else r"(?:s|es|d|ed)?(?![\w])"
        parts.append(r"(?<![\w])" + body + tail)
    if not parts:
        return None
    return re.compile("|".join(parts), re.IGNORECASE | re.MULTILINE)


def matches_keywords(pattern, text: str) -> bool:
    return bool(pattern and pattern.search(text))


def _band(cp: configparser.ConfigParser, option: str) -> tuple:
    raw = cp.get("discovery", option)
    try:
        low, high = raw.split(":", 1)
        return (float(low), float(high))
    except (ValueError, AttributeError):
        return (0.0, 999.0)


_cfg = _load_config(ROUTER_INI)
TOKEN_THRESHOLD_XLARGE = _cfg.getint("thresholds", "xlarge")
TOKEN_THRESHOLD_LARGE = _cfg.getint("thresholds", "large")
TOKEN_THRESHOLD_MEDIUM = _cfg.getint("thresholds", "medium")
CODE_FIRST = _cfg.getboolean("keywords", "code_first")
CODE_KEYWORDS = _json_list(_cfg, "keywords", "code")
LARGE_KEYWORDS = _json_list(_cfg, "keywords", "large")
XLARGE_KEYWORDS = _json_list(_cfg, "keywords", "xlarge")
CODE_RE = keyword_pattern(CODE_KEYWORDS)
LARGE_RE = keyword_pattern(LARGE_KEYWORDS)
XLARGE_RE = keyword_pattern(XLARGE_KEYWORDS)
TIER_FAST = _cfg.get("tiers", "fast")
TIER_MEDIUM = _cfg.get("tiers", "medium")
TIER_LARGE = _cfg.get("tiers", "large")
TIER_XLARGE = _cfg.get("tiers", "xlarge")
TIER_NAMES = {TIER_FAST: "fast", TIER_MEDIUM: "medium", TIER_LARGE: "large",
              TIER_XLARGE: "xlarge"}

DISCOVERY_ENABLED = _cfg.getboolean("discovery", "enabled")
DISCOVERY_REFRESH = _cfg.getint("discovery", "refresh_seconds")
DISCOVERY_TIMEOUT = _cfg.getfloat("discovery", "timeout_seconds")
CAPABILITY_PROBE = _cfg.getboolean("discovery", "capability_probe")
LMSTUDIO_LOADED_ONLY = _cfg.getboolean("discovery", "lmstudio_loaded_only")


def _model_sizes(cp: configparser.ConfigParser) -> dict:
    """[model_sizes] as {lowercase id: size}, blank entries dropped. The
    per-kind keys of earlier router.ini files ([discovery]
    strata_default_params, basalt_/maya_default_id + _params) still apply when
    a committed router.ini sets them."""
    sizes = {k.strip().lower(): v.strip() for k, v in cp.items("model_sizes")}
    if cp.has_option("discovery", "strata_default_params"):
        sizes["strata"] = cp.get("discovery", "strata_default_params").strip()
    for kind in ("basalt", "maya"):
        id_key, size_key = f"{kind}_default_id", f"{kind}_default_params"
        if cp.has_option("discovery", id_key) and cp.has_option("discovery", size_key):
            sizes[cp.get("discovery", id_key).strip().lower()] = \
                cp.get("discovery", size_key).strip()
    return {k: v for k, v in sizes.items() if k and v}


MODEL_SIZES = _model_sizes(_cfg)
BANDS = {
    "fast": _band(_cfg, "fast_params"),
    "medium": _band(_cfg, "medium_params"),
    "large": _band(_cfg, "large_params"),
    "xlarge": _band(_cfg, "xlarge_params"),
}
# Highest ceiling across all bands — the one band whose upper bound stays
# inclusive, so a model above every other band still scores a perfect fit.
TOP_BAND_HIGH = max(high for _, high in BANDS.values())
BAND_FALLOFF = _cfg.getfloat("discovery", "band_falloff")
CODE_MODELS = _json_list(_cfg, "discovery", "code_models")
VISION_MODELS = _json_list(_cfg, "discovery", "vision_models")
EMBEDDING_MODELS = _json_list(_cfg, "discovery", "embedding_models")
VISION_FAMILIES = _json_list(_cfg, "discovery", "vision_families")
EMBEDDING_FAMILIES = _json_list(_cfg, "discovery", "embedding_families")

W_BAND = _cfg.getfloat("weights", "band_fit")
W_CODE = _cfg.getfloat("weights", "code_match")
W_VISION = _cfg.getfloat("weights", "vision_match")
W_LARGER = _cfg.getfloat("weights", "prefer_larger")
W_SMALLER = _cfg.getfloat("weights", "prefer_smaller")
W_UNKNOWN = _cfg.getfloat("weights", "unknown_params")
W_OFFTASK = _cfg.getfloat("weights", "offtask_penalty")
TIE_EPSILON = _cfg.getfloat("weights", "tie_epsilon")
W_LOADED = _cfg.getfloat("weights", "loaded_bonus")
W_TOOLS = _cfg.getfloat("weights", "tool_match")

# --- server kinds -----------------------------------------------------------------
# A server entry is a base URL. Entries for servers that are not Ollama carry a
# kind prefix (lmstudio+http://host:1234, maya+http://host:8080, ...), so
# MODEL_SERVERS / BACKEND_* can mix APIs. This table is the one place a kind is
# described; monitor.py and manage-model-servers.sh keep matching tables, and
# tests/test_router.py checks that all three agree.
#   prefix   -- the entry prefix
#   key_env  -- the secrets.env variable holding the router's bearer token
#   label    -- the name used in logs and alerts
#   openai   -- models are listed at <base>/v1/models (Strata-style servers)
SERVER_KINDS = {
    "lmstudio": {"prefix": "lmstudio+", "key_env": "LMSTUDIO_API_TOKEN",
                 "label": "LM Studio", "openai": False},
    "strata": {"prefix": "strata+", "key_env": "STRATA_API_KEY",
               "label": "Strata", "openai": True},
    "basalt": {"prefix": "basalt+", "key_env": "BASALT_API_KEY",
               "label": "Basalt", "openai": True},
    "maya": {"prefix": "maya+", "key_env": "MAYA_API_KEY",
             "label": "Maya", "openai": True},
    "xolotl": {"prefix": "xolotl+", "key_env": "XOLOTL_API_KEY",
               "label": "Xolotl", "openai": True},
}
OPENAI_KINDS = frozenset(k for k, v in SERVER_KINDS.items() if v["openai"])
# Bearer tokens the router adds per kind (secrets.env). LM Studio's is for
# servers with "Require authentication" (0.4+).
KIND_KEYS = {kind: (os.getenv(spec["key_env"]) or "").strip()
             for kind, spec in SERVER_KINDS.items()}


def server_kind(server: str) -> str:
    for kind, spec in SERVER_KINDS.items():
        if server.startswith(spec["prefix"]):
            return kind
    return "ollama"


def server_base(server: str) -> str:
    """The plain http(s) base URL of a server entry."""
    kind = server_kind(server)
    return server.removeprefix(SERVER_KINDS[kind]["prefix"]) if kind != "ollama" else server


def backend_headers(server: str) -> dict:
    """Credentials the ROUTER adds for a backend (never the client's own)."""
    token = KIND_KEYS.get(server_kind(server), "")
    if token:
        return {"Authorization": f"Bearer {token}"}
    return {}


CLASSIFY_SCOPE = _cfg.get("classification", "scope").strip().lower()
VISION_STRICT = _cfg.getboolean("classification", "vision_strict")
CLASS_ORDER = ("fast", "medium", "large", "xlarge")
TOOLS_MIN_CLASS = _cfg.get("classification", "tools_min_class").strip().lower()
if TOOLS_MIN_CLASS and TOOLS_MIN_CLASS not in CLASS_ORDER:
    log.warning("ignoring [classification] tools_min_class = %r (use one of %s, "
                "or blank)", TOOLS_MIN_CLASS, ", ".join(CLASS_ORDER))
    TOOLS_MIN_CLASS = ""
TOOLS_STRICT = _cfg.getboolean("classification", "tools_strict")
CONNECT_TIMEOUT = _cfg.getfloat("http", "connect_timeout_seconds")
READ_TIMEOUT = _cfg.getfloat("http", "read_timeout_seconds")

# Request headers never forwarded upstream.
HOP_BY_HOP = {"host", "content-length", "connection", "keep-alive",
              "transfer-encoding", "upgrade", "proxy-connection", "te",
              "trailer", "proxy-authorization", "proxy-authenticate"}
# Response headers never copied onto our own (re-framed) streaming response.
# The body is re-chunked by the ASGI server, so the upstream framing headers
# would contradict what is actually sent. content-encoding is kept because the
# raw (still-encoded) bytes are passed through unchanged.
RESPONSE_HOP_BY_HOP = HOP_BY_HOP | {"date", "server"}

# Optional bearer token. When set, every endpoint except /healthz requires
# "Authorization: Bearer <key>". Lives in /app/router/secrets.env.
ROUTER_API_KEY = (os.getenv("ROUTER_API_KEY") or "").strip()
ROUTER_HOST = os.getenv("ROUTER_HOST", "0.0.0.0")
ROUTER_PORT = int(os.getenv("ROUTER_PORT", "8000"))


# Historical names for each tier's backend env key, newest first. The keys
# dropped their QWEN_ infix when the router stopped being Qwen-specific, and
# "heavy" was then renamed "large" when the xlarge tier was added. A service
# can start against a router.env that manage-model-servers.sh has not migrated
# yet -- without these fallbacks such a start looks healthy while resolving no
# backends at all.
_TIER_ENV_ALIASES = {
    "fast": ("BACKEND_FAST", "BACKEND_QWEN_FAST"),
    "medium": ("BACKEND_MEDIUM", "BACKEND_QWEN_MEDIUM"),
    "large": ("BACKEND_LARGE", "BACKEND_HEAVY", "BACKEND_QWEN_HEAVY"),
    "xlarge": ("BACKEND_XLARGE",),
}


def _tier_env(tier: str) -> str:
    for name in _TIER_ENV_ALIASES.get(tier, ("BACKEND_%s" % tier.upper(),)):
        value = os.getenv(name)
        if value:
            return value
    return ""


def _discovery_servers() -> list:
    """Model server entries to poll, in order of preference:
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
    return _split(",".join(
        _tier_env(t) for t in ("fast", "medium", "large", "xlarge")))


SERVERS = _discovery_servers()

# --- live inventory -----------------------------------------------------------
# Replaced wholesale on each refresh, so readers never see a half-built dict.
INVENTORY = {"models": [], "servers": {}, "updated_at": 0.0, "errors": {}}
_rotation = {}


def parse_params_billions(text) -> float:
    """'7.6B' -> 7.6, '134M' -> 0.134. A mixture-of-experts label such as
    LM Studio's '26B-A4B' counts its total size (26). 0.0 when unparseable."""
    if not text:
        return 0.0
    match = re.match(r"^\s*([0-9.]+)\s*([bBmM])(?:\s*$|[-_ ])", str(text))
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


def build_entry(server: str, raw: dict, capabilities=None) -> dict:
    """One discovered (server, model). `capabilities` is Ollama's own list from
    /api/show ("completion", "vision", "embedding", "tools", ...). When known it
    decides vision/embedding outright; the name heuristics are the fallback
    for servers that do not report it, and still drive is_code (Ollama has no
    "code" capability)."""
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
    is_vision = (_matches_any(lowered, VISION_MODELS)
                 or any(f in VISION_FAMILIES for f in families))
    is_embedding = (_matches_any(lowered, EMBEDDING_MODELS)
                    or any(f in EMBEDDING_FAMILIES for f in families))
    caps = [str(c).lower() for c in capabilities] if capabilities else []
    if caps:
        is_vision = "vision" in caps
        is_embedding = "embedding" in caps and "completion" not in caps
    # Tool support: True, False, or None (unknown). Ollama's /api/show list is
    # authoritative (the llama.cpp bridge and AirLLM answer it too). Other
    # kinds say so explicitly in raw["tools"] or not at all.
    if "tools" in raw:
        tools = raw["tools"]
    elif caps and server_kind(server) == "ollama":
        tools = "tools" in caps
    else:
        tools = None
    return {
        "server": server,
        "name": name,
        "params_b": params,
        "quantization": details.get("quantization_level") or "",
        "families": families,
        "size_bytes": raw.get("size") or 0,
        "capabilities": caps,
        "is_code": _matches_any(lowered, CODE_MODELS),
        "is_vision": is_vision,
        "is_embedding": is_embedding,
        "tools": tools,
        # The largest context the server reports for this model (tokens), or
        # None when it reports none. A ceiling, not a guarantee: Ollama, for
        # one, may serve less than the model's own limit unless num_ctx says.
        "context_length": positive_int(raw.get("context_length")),
        # True/False when the server reports residency; None otherwise.
        "loaded": raw.get("loaded"),
        "kind": server_kind(server),
    }


# (server, model name, digest) -> capability list, or None when the server
# does not report one. Keyed by digest so a re-pulled model is re-probed.
_CAPABILITIES = {}
# The same key -> context length from the same /api/show answer, or None.
_CONTEXTS = {}
# Runtime settings can change without changing a model digest (for example a
# llama.cpp context size). Cached probes expire after one minute.
SHOW_CACHE_SECONDS = 60
_SHOW_TIMES = {}


def positive_int(value):
    """value if it is a positive int (not a bool), else None."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def show_context_length(show: dict):
    """The context Ollama's /api/show says a model is served with, or None.
    model_info's "<arch>.context_length" is the model's own limit; a num_ctx
    parameter (a Modelfile's, or AirLLM's window) is what the server uses.
    The smaller known value wins."""
    values = []
    info = show.get("model_info")
    if isinstance(info, dict):
        values += [positive_int(v) for k, v in info.items()
                   if isinstance(k, str) and k.endswith(".context_length")]
    parameters = show.get("parameters")
    if isinstance(parameters, str):
        for line in parameters.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "num_ctx" and parts[1].isdigit():
                values.append(positive_int(int(parts[1])))
    values = [v for v in values if v]
    return min(values) if values else None


def _show_key(server: str, raw: dict) -> tuple:
    name = raw.get("name") or raw.get("model") or ""
    return (server, name, raw.get("digest") or raw.get("modified_at") or "")


async def model_capabilities(client: httpx.AsyncClient, server: str, raw: dict,
                             limit: asyncio.Semaphore = None, force: bool = False):
    """Ollama's capability list for one model via POST /api/show, cached.
    The context length from the same answer is cached in _CONTEXTS."""
    name = raw.get("name") or raw.get("model") or ""
    key = _show_key(server, raw)
    if (not force and key in _CAPABILITIES and key in _SHOW_TIMES
            and time.monotonic() - _SHOW_TIMES[key] < SHOW_CACHE_SECONDS):
        return _CAPABILITIES[key]
    caps = context = None
    try:
        async with (limit or asyncio.Semaphore(1)):
            response = await client.post(f"{server}/api/show", json={"model": name},
                                         timeout=DISCOVERY_TIMEOUT)
        if response.status_code == 200:
            payload = response.json()
            if isinstance(payload, dict):
                found = payload.get("capabilities")
                if isinstance(found, list):
                    caps = [str(c) for c in found]
                context = show_context_length(payload)
        # Only a definite answer is cached; a transient failure is retried
        # on the next poll.
        if response.status_code in (200, 400, 404, 405, 501):
            _CONTEXTS[key] = context
            _CAPABILITIES[key] = caps
            _SHOW_TIMES[key] = time.monotonic()
    except (httpx.HTTPError, ValueError, AttributeError):
        pass
    return _CAPABILITIES.get(key, caps)


def lmstudio_context(model: dict):
    """LM Studio's context for a model: the smallest loaded instance's
    configured context_length, else max_context_length; None if neither."""
    loaded = []
    for instance in model.get("loaded_instances") or []:
        config = instance.get("config") if isinstance(instance, dict) else None
        if isinstance(config, dict) and positive_int(config.get("context_length")):
            loaded.append(config["context_length"])
    return min(loaded) if loaded else positive_int(model.get("max_context_length"))


def _lmstudio_v1_models(payload: dict) -> list:
    """LM Studio 0.4+ GET /api/v1/models -> raw entries build_entry accepts."""
    out = []
    for m in payload.get("models") or []:
        if not isinstance(m, dict) or not m.get("key"):
            continue
        caps = ["embedding"] if m.get("type") == "embedding" else ["completion"]
        features = m.get("capabilities") or {}
        if features.get("vision"):
            caps.append("vision")
        # LM Studio gives untrained models its default tool format, so
        # "not trained for tool use" is not "no tools": leave that unknown.
        trained = bool(features.get("trained_for_tool_use"))
        if trained:
            caps.append("tools")
        quant = m.get("quantization") or {}
        out.append({
            "name": m["key"],
            "size": m.get("size_bytes") or 0,
            "details": {"parameter_size": m.get("params_string") or "",
                        "family": m.get("architecture") or "",
                        "quantization_level": quant.get("name") if isinstance(quant, dict) else quant},
            "capabilities": caps,
            "tools": True if trained else None,
            "loaded": bool(m.get("loaded_instances")),
            "context_length": lmstudio_context(m),
        })
    return out


def _lmstudio_v0_models(payload: dict) -> list:
    """LM Studio 0.3.x GET /api/v0/models -> raw entries (type llm|vlm|embeddings)."""
    out = []
    for m in payload.get("data") or []:
        if not isinstance(m, dict) or not m.get("id"):
            continue
        kind = m.get("type")
        caps = (["embedding"] if kind in ("embeddings", "embedding")
                else ["completion", "vision"] if kind == "vlm" else ["completion"])
        out.append({
            "name": m["id"],
            "details": {"family": m.get("arch") or "",
                        "quantization_level": m.get("quantization") or ""},
            "capabilities": caps,
            "loaded": m.get("state") == "loaded",
            "context_length": positive_int(m.get("max_context_length")),
        })
    return out


async def fetch_lmstudio_models(client: httpx.AsyncClient, server: str) -> tuple:
    """Newest native API first; the OpenAI-compatible /v1/models (names only)
    is the last resort, e.g. for an older LM Studio."""
    base, headers = server_base(server), backend_headers(server)
    last_error = None
    for path, convert in (("/api/v1/models", _lmstudio_v1_models),
                          ("/api/v0/models", _lmstudio_v0_models),
                          ("/v1/models", None)):
        try:
            response = await client.get(f"{base}{path}", headers=headers,
                                        timeout=DISCOVERY_TIMEOUT)
            if response.status_code in (404, 405):
                continue
            response.raise_for_status()
            payload = response.json()
        except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
            return server, None, f"{type(exc).__name__}: {exc}"
        except Exception as exc:  # noqa: BLE001 - try the next API flavour
            last_error = f"{path}: {type(exc).__name__}: {exc}"
            continue
        if convert is None:
            raws = [{"name": m.get("id")} for m in (payload.get("data") or [])
                    if isinstance(m, dict) and m.get("id")]
        else:
            raws = convert(payload)
        entries = [build_entry(server, raw, raw.get("capabilities")) for raw in raws]
        return server, [e for e in entries if e["name"]], None
    return server, None, last_error or "no LM Studio model API answered"


async def fetch_openai_models(client: httpx.AsyncClient, server: str) -> tuple:
    """Read Strata, Basalt, Maya or Xolotl model IDs and capabilities at /v1/models."""
    try:
        response = await client.get(f"{server_base(server)}/v1/models",
                                    headers=backend_headers(server),
                                    timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
        models = payload["data"]
        if not isinstance(models, list):
            raise ValueError("data is not a list")
        entries = []
        for model in models:
            if not isinstance(model, dict) or not model.get("id"):
                continue
            architecture = model.get("architecture") or {}
            modalities = model.get("input_modalities") or []
            if not modalities and isinstance(architecture, dict):
                modalities = architecture.get("input_modalities") or []
            caps = ["completion"] + (["vision"] if "image" in modalities else [])
            state = model.get("status", model.get("state"))
            if isinstance(state, dict):
                state = state.get("value")
            size = model.get("parameter_size") or model.get("params_string")
            # Only ids listed in [model_sizes] inherit a size. Other aliases
            # and variants stay unknown unless the API or the id gives one.
            if not size:
                size = MODEL_SIZES.get(str(model["id"]).lower())
            raw = {"name": model["id"], "capabilities": caps,
                   "details": {"parameter_size": size},
                   "loaded": state == "loaded" if state is not None else None,
                   # Field names used by OpenAI-style servers (vLLM-style
                   # max_model_len included); none of them is required.
                   "context_length": next(filter(None, (
                       positive_int(model.get(k)) for k in
                       ("context_length", "max_model_len", "context_window"))), None)}
            entries.append(build_entry(server, raw, caps))
        return server, entries, None
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        return server, None, f"{type(exc).__name__}: {exc}"


fetch_strata_models = fetch_openai_models  # preserve the existing callable


async def fetch_server_models(client: httpx.AsyncClient, server: str,
                              force_probe: bool = False) -> tuple:
    if server_kind(server) == "lmstudio":
        return await fetch_lmstudio_models(client, server)
    if server_kind(server) in OPENAI_KINDS:
        return await fetch_openai_models(client, server)
    try:
        response = await client.get(f"{server}/api/tags", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
    except Exception as exc:  # noqa: BLE001 - any failure means "server is down"
        return server, None, f"{type(exc).__name__}: {exc}"
    raws = [m for m in (payload.get("models") or []) if isinstance(m, dict)]
    # Ollama's /api/tags lists installed models; /api/ps reports the ones
    # resident in memory right now. Older bridges may lack /api/ps, in which
    # case residency remains unknown rather than marking everything cold.
    try:
        running = await client.get(f"{server}/api/ps", timeout=DISCOVERY_TIMEOUT)
        running.raise_for_status()
        running_models = [m for m in running.json().get("models", []) if isinstance(m, dict)]
        loaded = {name for m in running_models for name in (m.get("name"), m.get("model"))
                  if isinstance(name, str)}
        loaded.update(f"{name}:latest" for name in tuple(loaded) if ":" not in name)
        loaded_digests = {m["digest"] for m in running_models if m.get("digest")}
        for raw in raws:
            raw["loaded"] = ((raw.get("name") or raw.get("model")) in loaded
                             or bool(raw.get("digest") and raw["digest"] in loaded_digests))
    except (httpx.HTTPError, ValueError, TypeError, AttributeError):
        pass
    if CAPABILITY_PROBE:
        limit = asyncio.Semaphore(8)   # per poll, so no cross-event-loop state
        caps = await asyncio.gather(*[model_capabilities(client, server, m, limit, force_probe)
                                      for m in raws])
        for raw in raws:
            raw["context_length"] = _CONTEXTS.get(_show_key(server, raw))
    else:
        caps = [None] * len(raws)
    entries = [build_entry(server, m, c) for m, c in zip(raws, caps, strict=True)]
    return server, [e for e in entries if e["name"]], None


async def refresh_inventory(force_probe: bool = False) -> dict:
    """Poll every target for the models it is currently serving."""
    global INVENTORY
    if not SERVERS:
        INVENTORY = {"models": [], "servers": {}, "updated_at": time.time(),
                     "errors": {"config": "no servers configured"}}
        return INVENTORY
    results = await asyncio.gather(
        *[fetch_server_models(http_client(), s, force_probe) for s in SERVERS],
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
            if INVENTORY.get("servers", {}).get(server, {}).get("up", True):
                log.warning("discovery: %s is down (%s)", server, error)
            continue
        if not INVENTORY.get("servers", {}).get(server, {}).get("up", True):
            log.info("discovery: %s is back (%d models)", server, len(entries))
        servers[server] = {"up": True, "model_count": len(entries)}
        models.extend(entries)
    INVENTORY = {"models": models, "servers": servers,
                 "updated_at": time.time(), "errors": errors}
    return INVENTORY


def mark_server_down(server: str, reason: str) -> None:
    """Take a host out of rotation right now, instead of waiting up to
    refresh_seconds for the next poll. The next successful poll restores it."""
    global INVENTORY
    servers = dict(INVENTORY.get("servers", {}))
    previous = servers.get(server, {})
    if not previous.get("up", True):
        return
    servers[server] = dict(previous, up=False)
    errors = dict(INVENTORY.get("errors", {}), **{server: reason})
    INVENTORY = dict(INVENTORY, servers=servers, errors=errors)
    log.warning("dispatch: %s marked down until the next discovery poll (%s)",
                server, reason)


async def _discovery_loop() -> None:
    while True:
        await asyncio.sleep(max(5, DISCOVERY_REFRESH))
        try:
            await refresh_inventory()
        except Exception:  # noqa: BLE001 - never let the loop die
            log.exception("discovery: refresh failed")


# --- shared HTTP client + lifespan ---------------------------------------------
# One pooled client for every upstream call. Tests swap the transport.
_HTTP = {"client": None, "transport": None, "task": None}


def http_client() -> httpx.AsyncClient:
    if _HTTP["client"] is None:
        _HTTP["client"] = httpx.AsyncClient(
            timeout=httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT),
            limits=httpx.Limits(max_connections=200, max_keepalive_connections=40),
            transport=_HTTP["transport"],
        )
    return _HTTP["client"]


def _is_loopback(host: str) -> bool:
    if host in ("localhost", ""):
        return host == "localhost"
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


@asynccontextmanager
async def lifespan(_app):
    http_client()
    if not ROUTER_API_KEY and not _is_loopback(ROUTER_HOST):
        log.warning("ROUTER_API_KEY is not set and the router listens on %s: "
                    "anyone who can reach port %d can use every backend. Set "
                    "it with `manage-model-servers set-api-key`.",
                    ROUTER_HOST, ROUTER_PORT)
    if DISCOVERY_ENABLED and SERVERS:
        await refresh_inventory()
        # Keep the reference: a bare create_task() can be garbage-collected.
        _HTTP["task"] = asyncio.create_task(_discovery_loop())
    log.info("router ready: discovery=%s servers=%d scope=%s auth=%s",
             DISCOVERY_ENABLED, len(SERVERS), CLASSIFY_SCOPE,
             "on" if ROUTER_API_KEY else "off")
    try:
        yield
    finally:
        task = _HTTP.get("task")
        if task:
            task.cancel()
        if _HTTP["client"] is not None:
            await _HTTP["client"].aclose()
            _HTTP["client"] = None


app = FastAPI(title="Ollama Smart Router", lifespan=lifespan)


@app.middleware("http")
async def require_api_key(request: Request, call_next):
    if ROUTER_API_KEY and request.url.path != "/healthz":
        supplied = request.headers.get("authorization", "")
        token = supplied[7:].strip() if supplied.lower().startswith("bearer ") else ""
        if not hmac.compare_digest(token.encode(), ROUTER_API_KEY.encode()):
            return JSONResponse(
                {"error": {"message": "Missing or invalid router API key.",
                           "type": "invalid_request_error",
                           "code": "invalid_api_key"}},
                status_code=401)
    return await call_next(request)


# --- request analysis ---------------------------------------------------------
_CLASS_TO_TIER = {"fast": "TIER_FAST", "medium": "TIER_MEDIUM",
                  "large": "TIER_LARGE", "xlarge": "TIER_XLARGE"}


def classify_text(text: str) -> dict:
    """Request class for one block of text. The single source of the keyword
    and length heuristics, shared by discovery routing and the LiteLLM path."""
    approx_tokens = len(text.split()) * 1.3
    is_code = matches_keywords(CODE_RE, text)
    if CODE_FIRST and is_code:
        request_class = "fast"
    elif approx_tokens > TOKEN_THRESHOLD_XLARGE or matches_keywords(XLARGE_RE, text):
        request_class = "xlarge"
    elif approx_tokens > TOKEN_THRESHOLD_LARGE or matches_keywords(LARGE_RE, text):
        request_class = "large"
    elif approx_tokens > TOKEN_THRESHOLD_MEDIUM:
        request_class = "medium"
    else:
        request_class = "fast"
    return {"class": request_class, "code": is_code,
            "approx_tokens": round(approx_tokens)}


def analyze_complexity(prompt: str) -> str:
    """Tier alias (a LiteLLM model_name) for a prompt -- the LiteLLM path."""
    return globals()[_CLASS_TO_TIER[classify_text(prompt)["class"]]]


def _message_parts(message) -> tuple:
    """(text, has_image) for one OpenAI chat message."""
    if not isinstance(message, dict):
        return "", False
    content = message.get("content")
    if isinstance(content, str):
        return content, False
    texts, has_image = [], False
    if isinstance(content, list):
        # OpenAI multimodal form: [{"type":"text"...},{"type":"image_url"...}]
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                texts.append(part["text"])
            elif part.get("type") in ("image_url", "input_image", "image"):
                has_image = True
    return " ".join(texts), has_image


def routing_text(messages: list) -> str:
    """The text the heuristics judge, per [classification] scope."""
    messages = [m for m in (messages or []) if isinstance(m, dict)]
    if CLASSIFY_SCOPE != "conversation":
        for message in reversed(messages):
            if message.get("role") == "user":
                return _message_parts(message)[0]
    # Scope "conversation", or no user turn at all (then judge everything).
    return " ".join(_message_parts(m)[0] for m in messages)


def classify_request(messages: list) -> dict:
    """Turn the conversation into routing requirements.

    Images are looked for in EVERY message: a follow-up question about an
    image sent earlier still needs a vision model to see it."""
    need = classify_text(routing_text(messages))
    need["vision"] = any(_message_parts(m)[1] for m in (messages or []))
    need["tools"] = False
    return need


def wants_tools(body: dict) -> bool:
    """Does the request offer the model tools it may call? An empty list, or
    tool_choice "none", asks for none."""
    if not isinstance(body, dict):
        return False
    tools = body.get("tools") or body.get("functions")
    if not isinstance(tools, list) or not tools:
        return False
    return body.get("tool_choice") != "none" and body.get("function_call") != "none"


def apply_tool_needs(need: dict, body: dict) -> dict:
    """Mark a tool request, and raise its class to tools_min_class."""
    need = dict(need, tools=wants_tools(body))
    if need["tools"] and TOOLS_MIN_CLASS and \
            CLASS_ORDER.index(need["class"]) < CLASS_ORDER.index(TOOLS_MIN_CLASS):
        need["class"] = TOOLS_MIN_CLASS
    return need


def _in_band(params: float, low: float, high: float) -> bool:
    """Is a parameter count inside a band?

    The upper bound is EXCLUSIVE so adjacent bands are disjoint. With the
    defaults (large 20:70, xlarge 70:999) an inclusive bound would place a 70B
    model in both, and the size bias in score_entry would then let large take
    the very model that defines xlarge. The topmost band keeps an inclusive
    ceiling so the biggest model in the pool still lands somewhere.
    """
    return low <= params < high or params == high == TOP_BAND_HIGH


def band_distance(entry: dict, need: dict) -> float:
    """How far outside the requested band a model sits, in billions (0 = in).

    Used to order candidates when nothing is in band at all -- see
    rank_candidates. A model of unknown size sorts after known out-of-band
    models, but remains eligible when no known-size model exists.
    """
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    params = entry["params_b"]
    if params <= 0:
        return float("inf")
    if _in_band(params, low, high):
        return 0.0
    return (low - params) if params < low else (params - high)


def in_requested_band(entry: dict, need: dict) -> bool:
    """Does this model's size genuinely fall inside the requested band?

    Distinct from `band_distance(...) == 0.0`, which means a known model is
    inside the requested band. Keeping them separate matters: one unknown-size
    model in the pool must not switch off distance ranking for every other
    candidate.
    """
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    return entry["params_b"] > 0 and _in_band(entry["params_b"], low, high)


def score_entry(entry: dict, need: dict) -> float:
    """Heuristic fit of one discovered (server, model) pair to one request."""
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    params = entry["params_b"]
    in_band = _in_band(params, low, high)
    if params <= 0:
        fit = W_UNKNOWN
    elif in_band:
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

    # Within a band, bias toward the extreme the class actually wants. The bias
    # is a position WITHIN the band (0 at the floor, 1 at the ceiling) and is
    # applied only to in-band models. Rewarding absolute size instead would let
    # an out-of-band giant outscore a perfect in-band fit: a 70B model sits at
    # large's exclusive ceiling, so the gentle falloff still scores it ~1.0, and
    # an unbounded size bonus would push it past the 32B that actually belongs
    # to the tier.
    if params > 0 and in_band:
        span = high - low
        position = (params - low) / span if span > 0 else 1.0
        position = max(0.0, min(position, 1.0))
        if need["class"] in ("large", "xlarge"):
            score += W_LARGER * position
        elif need["class"] == "fast":
            score += W_SMALLER * (1.0 - position)
    if entry.get("loaded"):
        score += W_LOADED
    if need.get("tools") and entry.get("tools"):
        score += W_TOOLS
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
        if LMSTUDIO_LOADED_ONLY and entry["kind"] == "lmstudio" and entry.get("loaded") is False:
            continue  # would trigger a just-in-time load on LM Studio
        scored.append((score_entry(entry, need), entry))
    if need.get("tools"):
        # A model known to lack tools answers a tool request with an error.
        # Keep the full list only when nothing else is left (the caller warns).
        capable = [pair for pair in scored if pair[1].get("tools") is not False]
        scored = capable or scored
    if not scored:
        return []

    # Ordinarily score alone orders the list. But when NOTHING is in band it
    # cannot: the falloff floors at zero once a model is band_falloff billions
    # outside, so for an xlarge request (70:999) against a 14B/27B pool every
    # candidate flattens to exactly 0.0. They then look tied, and the rotation
    # below hands the prompt to the smallest model half the time while the
    # largest sits idle. In that case rank by how far each model is from the
    # band, so the closest wins, and let score break ties only among models
    # that are equally far out.
    use_distance = not any(in_requested_band(e, need) for _, e in scored)

    def _distance(entry):
        return band_distance(entry, need) if use_distance else 0.0

    # Sorting on (distance asc, score desc) is identical to the previous
    # score-only sort whenever use_distance is False.
    scored.sort(key=lambda pair: (_distance(pair[1]), -pair[0]))

    # Rotate through candidates that score within tie_epsilon of the best, so
    # the same model on several hosts shares load instead of always hitting the
    # first one. (LiteLLM does this for the static path; direct dispatch needs
    # its own.) Equal distance is part of "tied": without it the rotation would
    # spread load across models of visibly different size.
    best_score = scored[0][0]
    best_distance = _distance(scored[0][1])
    tied, rest = [], []
    for s_val, e in scored:
        if _distance(e) == best_distance and best_score - s_val <= TIE_EPSILON:
            tied.append(e)
        else:
            rest.append(e)
    if need.get("tools") and len(tied) > 1:
        # An agent loop sends many requests for one task. Rotating between
        # DIFFERENT models would change the model mid-task and discard the
        # backend's prompt cache, so only the same model on several hosts
        # shares the load.
        best_name = tied[0]["name"]
        rest = [e for e in tied if e["name"] != best_name] + rest
        tied = [e for e in tied if e["name"] == best_name]
    if len(tied) > 1:
        key = f"{need['class']}|{need['code']}|{need['vision']}|{need.get('tools', False)}"
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
               and not e["is_embedding"]
               and INVENTORY.get("servers", {}).get(e["server"], {}).get("up", True)]
    if not matches:
        # Allow the bare name without its tag, e.g. "qwen3" -> "qwen3:14b".
        matches = [e for e in INVENTORY.get("models", [])
                   if e["name"].lower().split(":", 1)[0] == wanted
                   and not e["is_embedding"]
                   and INVENTORY.get("servers", {}).get(e["server"], {}).get("up", True)]
    if len(matches) > 1:
        index = _rotation.get(wanted, 0) % len(matches)
        _rotation[wanted] = index + 1
        matches = matches[index:] + matches[:index]
    return matches


def embedding_only_match(model_name: str):
    """The inventory name when an explicitly requested model exists ONLY as an
    embedding model (exact name first, then the bare name without its tag);
    None when it is unknown or any host serves it for chat.

    Such a request cannot be answered by the chat endpoint. Rerouting it to
    some other chat model would silently answer with a model the client did
    not ask for, so the caller rejects it instead.

    Host state is deliberately ignored: when the chat copy of a name is only on
    a host that is down, the model is not embedding-only, and the request takes
    the same path as any explicitly named model that is currently unavailable
    (routed by its content, flagged with X-Router-Warning: model-unavailable).
    """
    wanted = (model_name or "").strip().lower()
    if not wanted:
        return None
    models = INVENTORY.get("models", [])
    matches = [e for e in models if e["name"].lower() == wanted]
    if not matches:
        matches = [e for e in models if e["name"].lower().split(":", 1)[0] == wanted]
    if matches and all(e["is_embedding"] for e in matches):
        return matches[0]["name"]
    return None


def known_chat_model(model_name: str) -> bool:
    """Is this name (exact, or without its tag) a chat model on ANY host, up or
    down? Distinguishes "named model temporarily unavailable" from a name the
    router has never seen."""
    wanted = (model_name or "").strip().lower()
    if not wanted:
        return False
    return any(not e["is_embedding"]
               and wanted in (e["name"].lower(), e["name"].lower().split(":", 1)[0])
               for e in INVENTORY.get("models", []))


# --- proxying -----------------------------------------------------------------
def _forward_headers(request: Request, drop_auth: bool = False) -> dict:
    """Request headers to send upstream. drop_auth strips Authorization, so the
    router's own API key is never handed to an Ollama host."""
    return {k: v for k, v in request.headers.items()
            if k.lower() not in HOP_BY_HOP
            and not (drop_auth and k.lower() == "authorization")}


def _response_headers(upstream: httpx.Response, extra: dict = None) -> dict:
    headers = {k: v for k, v in upstream.headers.items()
               if k.lower() not in RESPONSE_HOP_BY_HOP}
    if extra:
        headers.update(extra)
    return headers


async def close_upstream(response: httpx.Response) -> None:
    await response.aclose()


async def _stream_upstream(method: str, url: str, headers: dict,
                           json_body=None, content=None,
                           extra_headers: dict = None) -> StreamingResponse:
    client = http_client()
    try:
        upstream_request = client.build_request(
            method, url, headers=headers, json=json_body, content=content
        )
        upstream_response = await client.send(upstream_request, stream=True)
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response, extra_headers),
        background=BackgroundTask(close_upstream, upstream_response),
    )


# Upstream statuses that mean "try the next candidate": the host is failing
# (5xx) or no longer has the model (404, e.g. removed since the last poll).
RETRYABLE_STATUS = {404} | set(range(500, 600))
# Only a capability rejection warrants trying another model and temporarily
# excluding this one from tool requests. A malformed tools payload can also
# mention "tools" in a 400, but every candidate would receive that same error.
TOOL_REJECTION_RE = re.compile(
    rb"\b(?:does not|doesn't|do not|don't)\s+support\s+"
    rb"(?:tools?|tool\s+(?:calls?|calling|use)|function\s+(?:calls?|calling))\b"
    rb"|\b(?:tools?|tool\s+(?:calls?|calling|use)|function\s+(?:calls?|calling))"
    rb"\s+(?:is|are)\s+not\s+supported\b",
    re.IGNORECASE,
)
# Error bodies are small; never buffer more than this to inspect one.
ERROR_PEEK_BYTES = 65536


async def _read_raw(response: httpx.Response, limit: int = ERROR_PEEK_BYTES) -> bytes:
    """The raw (still encoded) body of an error response, up to limit bytes."""
    chunks, size = [], 0
    async for chunk in response.aiter_raw():
        chunks.append(chunk)
        size += len(chunk)
        if size >= limit:
            break
    return b"".join(chunks)


async def _dispatch_direct(candidates: list, body: dict, headers: dict,
                           need: dict, extra_headers: dict = None) -> StreamingResponse:
    """Send to the best candidate, falling forward through the ranked list on
    connection errors, 404 or 5xx. Retrying is only safe before any body has
    been streamed, which is why the status is checked before returning. A host
    that refuses or times out the CONNECTION is marked down immediately so the
    next request skips it too."""
    client = http_client()
    last_error = None
    for position, entry in enumerate(candidates):
        if not INVENTORY.get("servers", {}).get(entry["server"], {}).get("up", True):
            last_error = f"{entry['server']}: marked down"
            continue
        attempt_body = dict(body)
        attempt_body["model"] = entry["name"]
        url = f"{server_base(entry['server'])}/v1/chat/completions"
        try:
            upstream_request = client.build_request(
                "POST", url, headers=dict(headers, **backend_headers(entry["server"])),
                json=attempt_body
            )
            upstream_response = await client.send(upstream_request, stream=True)
        except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
            last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
            mark_server_down(entry["server"], last_error)
            continue
        except httpx.RequestError as exc:
            last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
            log.warning("dispatch: %s", last_error)
            continue
        is_last = position == len(candidates) - 1
        if upstream_response.status_code in RETRYABLE_STATUS and not is_last:
            await upstream_response.aclose()
            last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
            log.warning("dispatch: %s for %s; trying the next candidate",
                        last_error, entry["name"])
            continue
        buffered = None
        if upstream_response.status_code == 400 and need.get("tools"):
            # The raw body is inspected as sent. A compressed error body will
            # not match, so it is passed through and nothing is demoted.
            buffered = await _read_raw(upstream_response)
            await upstream_response.aclose()
            if TOOL_REJECTION_RE.search(buffered):
                # Skip this model for tool requests until the next poll
                # (which rebuilds the entry) instead of failing every turn.
                # The last candidate is remembered too; its 400 is returned.
                entry["tools"] = False
                last_error = f"{entry['server']}: {entry['name']} rejected the tools (HTTP 400)"
                if not is_last:
                    log.warning("dispatch: %s; trying the next candidate", last_error)
                    continue
                log.warning("dispatch: %s; no candidates left", last_error)
        log.info("route class=%s code=%s vision=%s tools=%s tokens~%s -> %s @ %s (%d/%d)",
                 need["class"], need["code"], need["vision"], need.get("tools", False),
                 need.get("approx_tokens"), entry["name"], entry["server"],
                 position + 1, len(candidates))
        router_headers = {
            "X-Router-Model": entry["name"],
            "X-Router-Server": entry["server"],
            "X-Router-Class": need["class"],
            "X-Router-Mode": "discovery",
            "X-Router-Candidates": str(len(candidates)),
        }
        router_headers.update(extra_headers or {})
        if buffered is not None:
            return Response(content=buffered, status_code=upstream_response.status_code,
                            headers=_response_headers(upstream_response, router_headers))
        return StreamingResponse(
            upstream_response.aiter_raw(),
            status_code=upstream_response.status_code,
            headers=_response_headers(upstream_response, router_headers),
            background=BackgroundTask(close_upstream, upstream_response),
        )
    raise HTTPException(status_code=502,
                        detail=f"No usable model target. Last error: {last_error}")


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
    await refresh_inventory(force_probe=True)
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
    need = apply_tool_needs(classify_request(messages or []), body)
    requested = str(body.get("model") or "").strip()
    if requested in TIER_NAMES:
        need = dict(need, **{"class": TIER_NAMES[requested]})
    candidates = rank_candidates(need)
    return JSONResponse({
        "request": need,
        "legacy_tier": analyze_complexity(routing_text(messages or [])),
        "chosen": ({"model": candidates[0]["name"], "server": candidates[0]["server"]}
                   if candidates else None),
        "candidates": [
            {"model": e["name"], "server": e["server"], "params_b": e["params_b"],
             "tools": e.get("tools"), "score": round(score_entry(e, need), 4)}
            for e in candidates[:10]
        ],
    })


def _error(status: int, message: str, code: str) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "invalid_request_error",
                                   "code": code}}, status_code=status)


@app.post("/v1/chat/completions")
async def route_chat_completion(request: Request):
    try:
        body = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    if not isinstance(body, dict):
        return _error(400, "Request body must be a JSON object.", "invalid_body")
    messages = body.get("messages") or []
    requested = str(body.get("model") or "").strip()
    need = apply_tool_needs(classify_request(messages), body)

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        # An explicitly requested real model is honoured; tier aliases and
        # "auto" mean "decide for me".
        candidates, explicit = [], False
        if requested and requested.lower() not in ("auto", "") \
                and requested not in TIER_NAMES:
            candidates = find_named_model(requested)
            explicit = bool(candidates)
            embedding = None if candidates else embedding_only_match(requested)
            if embedding:
                log.warning("route: %s is embedding-only; rejecting the chat request", embedding)
                return _error(
                    400,
                    f"Model '{embedding}' is an embedding-only model and cannot answer chat "
                    "completions. Send embedding requests to /v1/embeddings, or choose a chat "
                    "model (see /v1/models) or 'auto'.",
                    "embedding_model_not_chat")
        warnings = []
        if requested and not candidates and requested.lower() != "auto" \
                and requested not in TIER_NAMES and known_chat_model(requested):
            # Named, known, but every host serving it is down: answer by
            # content, and say so rather than silently using another model.
            log.warning("route: %s is on no reachable host; routing by content", requested)
            warnings.append("model-unavailable")
        if not candidates:
            if requested in TIER_NAMES:
                need = dict(need, **{"class": TIER_NAMES[requested]})
            candidates = rank_candidates(need)
        extra = {}
        if need["vision"] and not explicit and candidates \
                and not any(e["is_vision"] for e in candidates):
            message = ("The request contains an image, but no discovered model "
                       "looks vision-capable (see [discovery] vision_models).")
            if VISION_STRICT:
                return _error(400, message, "no_vision_model")
            log.warning("route: %s Routing to %s anyway.", message, candidates[0]["name"])
            warnings.append("no-vision-model")
        if need["tools"] and not explicit and candidates \
                and all(e.get("tools") is False for e in candidates):
            message = ("The request offers tools, but every discovered model is "
                       "known to lack tool support.")
            if TOOLS_STRICT:
                return _error(400, message, "no_tool_model")
            log.warning("route: %s Routing to %s anyway.", message, candidates[0]["name"])
            warnings.append("no-tool-model")
        if warnings:
            extra["X-Router-Warning"] = ", ".join(warnings)
        if candidates:
            return await _dispatch_direct(
                candidates, body, _forward_headers(request, drop_auth=True),
                need, extra)

    # Fallback: the original static path through LiteLLM, which keeps its own
    # latency routing and cross-tier fallbacks.
    body["model"] = globals()[_CLASS_TO_TIER[need["class"]]]
    log.info("route class=%s -> LiteLLM %s", need["class"], body["model"])
    return await _stream_upstream(
        "POST", LITELLM_URL, _forward_headers(request, drop_auth=True), json_body=body,
        extra_headers={"X-Router-Mode": "litellm", "X-Router-Model": body["model"]},
    )


@app.get("/v1/models")
async def list_models(request: Request):
    """Advertise auto + the tier aliases, then whatever is actually available.

    The aliases are emitted FIRST and UNCONDITIONALLY. They are resolved by the
    router itself, so they must stay selectable in states where nothing
    downstream knows about them:

      * discovery empty -- every Ollama host down, discovery disabled, or the
        first poll still in flight;
      * a tier with no LiteLLM deployment -- which is exactly xlarge until
        servers are assigned to it.

    This path used to return LiteLLM's list verbatim whenever discovery was
    empty. That made the picker mirror litellm_config.yaml, so a tier with no
    deployment never appeared, and a stale alias still in that file was
    advertised as though it were live.
    """
    seen, data = set(), []
    for alias in ("auto", TIER_FAST, TIER_MEDIUM, TIER_LARGE, TIER_XLARGE):
        if alias and alias not in seen:
            seen.add(alias)
            data.append({"id": alias, "object": "model", "owned_by": "router"})

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        for entry in INVENTORY["models"]:
            if entry["is_embedding"] or entry["name"] in seen:
                continue
            seen.add(entry["name"])
            data.append({"id": entry["name"], "object": "model",
                         "owned_by": entry["kind"]})
        return JSONResponse({"object": "list", "data": data})

    # Discovery unavailable: supplement the aliases with LiteLLM's own list so
    # real model names are still offered. An alias already emitted is never
    # displaced by a stale entry of the same name.
    try:
        response = await http_client().get(
            f"{LITELLM_BASE}/v1/models",
            headers=_forward_headers(request, drop_auth=True),
            timeout=DISCOVERY_TIMEOUT)
        for entry in (response.json().get("data") or []):
            name = str(entry.get("id") or "").strip()
            if name and name not in seen:
                seen.add(name)
                data.append({"id": name, "object": "model", "owned_by": "litellm"})
    except Exception as exc:  # noqa: BLE001 - the alias list must still be served
        log.warning("model list: LiteLLM unreachable (%s); serving aliases only", exc)
    return JSONResponse({"object": "list", "data": data})


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def proxy_openai(path: str, request: Request):
    # Transparent passthrough for all other OpenAI routes (embeddings, etc.).
    url = f"{LITELLM_BASE}/v1/{path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"
    raw = await request.body()
    return await _stream_upstream(
        request.method, url, _forward_headers(request, drop_auth=True),
        content=raw or None
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=ROUTER_HOST, port=ROUTER_PORT)
PYEOF

# --- monitor.py (probes each Ollama backend directly) ---
cat > "${REPO_DIR}/services/ollama-monitor/monitor.py" <<'PYEOF'
"""Health monitor for the smart-router stack.

Watches every model host the router can route to (MODEL_SERVERS plus the
per-tier BACKEND_* lists) and the three local services (LiteLLM, the router,
Open WebUI), and posts state changes to Mattermost.

  * Probes run in parallel, so one dead host cannot stretch the cycle.
  * A state change is only reported after N consecutive failed (or passed)
    checks, so a single dropped probe does not page anyone.
  * One alert per HOST, naming every tier it serves -- not one per tier.
  * An alert that fails to deliver is retried every cycle until it lands.
  * Keep-alive pinning runs in its own thread: loading a cold model can take
    minutes and must never delay health checks.
"""
import configparser
import logging
import os
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import httpx

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

MATTERMOST_WEBHOOK_URL = os.getenv("MATTERMOST_WEBHOOK_URL")
MATTERMOST_USER = os.getenv("MATTERMOST_MONITOR_USER", "OllamaMonitor")
MATTERMOST_CHANNEL = os.getenv("MATTERMOST_CHANNEL", "ollama-monitor")
MATTERMOST_VERIFY_TLS = os.getenv("MATTERMOST_VERIFY_TLS", "true").lower() == "true"

# Polling behaviour comes from monitor.ini (version controlled); environment
# variables still win, so an operator can override without a commit.
_DEFAULTS = {
    "polling": {"interval_seconds": "15", "timeout_seconds": "5",
                "health_path": "/api/tags"},
    "alerting": {"fail_threshold": "3", "recover_threshold": "2"},
    "startup": {"notice_interval_seconds": "3600"},
    "local_services": {
        "enabled": "true",
        "litellm-proxy": "http://127.0.0.1:4000/health/liveliness",
        "ollama-router": "http://127.0.0.1:8000/healthz",
        "open-webui": "http://127.0.0.1:8080/health",
    },
}
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
FAIL_THRESHOLD = max(1, int(os.getenv("MONITOR_FAIL_THRESHOLD",
                                      _cfg.get("alerting", "fail_threshold"))))
RECOVER_THRESHOLD = max(1, int(os.getenv("MONITOR_RECOVER_THRESHOLD",
                                         _cfg.get("alerting", "recover_threshold"))))
# The startup notice is posted at most once per this many seconds, so a crash
# loop (Restart=always) does not flood the channel. The timestamp lives in the
# unit's StateDirectory; without one, every start posts as before.
NOTICE_INTERVAL = int(_cfg.get("startup", "notice_interval_seconds"))
STATE_DIR = os.getenv("MONITOR_STATE_DIR", "")

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
    "fast": (os.getenv("MODEL_FAST", "") or "").strip(),
    "medium": (os.getenv("MODEL_MEDIUM", "") or "").strip(),
    "large": (os.getenv("MODEL_LARGE") or os.getenv("MODEL_HEAVY", "") or "").strip(),
    "xlarge": (os.getenv("MODEL_XLARGE", "") or "").strip(),
}


def _keep_alive_value():
    """Ollama accepts -1/0 or a number as an integer, durations as a string."""
    try:
        return int(KEEP_ALIVE)
    except (TypeError, ValueError):
        return KEEP_ALIVE


def _url_list(value: str) -> list:
    return [u.strip().rstrip("/") for u in (value or "").split(",") if u.strip()]


# Historical names for each tier's backend env key, newest first. The keys
# dropped their QWEN_ infix when the router stopped being Qwen-specific, and
# "heavy" was then renamed "large" when the xlarge tier was added.
# manage-model-servers.sh rewrites router.env on its next write, but a service
# can start against a file that has not been migrated yet -- without these
# fallbacks such a start looks healthy while routing to nothing at all.
_TIER_ENV_ALIASES = {
    "fast": ("BACKEND_FAST", "BACKEND_QWEN_FAST"),
    "medium": ("BACKEND_MEDIUM", "BACKEND_QWEN_MEDIUM"),
    "large": ("BACKEND_LARGE", "BACKEND_HEAVY", "BACKEND_QWEN_HEAVY"),
    "xlarge": ("BACKEND_XLARGE",),
}


def _tier_env(tier: str) -> str:
    for name in _TIER_ENV_ALIASES.get(tier, ("BACKEND_%s" % tier.upper(),)):
        value = os.getenv(name)
        if value:
            return value
    return ""


BACKENDS = {tier: _url_list(_tier_env(tier)) for tier in ("fast", "medium", "large", "xlarge")}
BACKENDS = {tier: urls for tier, urls in BACKENDS.items() if urls}


# Entries for servers that are not Ollama carry a kind prefix in the shared
# server lists. Same table as router.py's SERVER_KINDS (tests/test_router.py
# checks that they agree):
#   prefix / key_env / label -- entry prefix, secrets.env token, alert name
#   openai -- a Strata-style server: probed on /v1/models, and up only while
#             that list names a model (its engine answers 200 with an empty
#             list when it is not running, and the router cannot use it then)
SERVER_KINDS = {
    "lmstudio": {"prefix": "lmstudio+", "key_env": "LMSTUDIO_API_TOKEN",
                 "label": "LM Studio", "openai": False},
    "strata": {"prefix": "strata+", "key_env": "STRATA_API_KEY",
               "label": "Strata", "openai": True},
    "basalt": {"prefix": "basalt+", "key_env": "BASALT_API_KEY",
               "label": "Basalt", "openai": True},
    "maya": {"prefix": "maya+", "key_env": "MAYA_API_KEY",
             "label": "Maya", "openai": True},
    "xolotl": {"prefix": "xolotl+", "key_env": "XOLOTL_API_KEY",
               "label": "Xolotl", "openai": True},
}
KIND_KEYS = {kind: (os.getenv(spec["key_env"]) or "").strip()
             for kind, spec in SERVER_KINDS.items()}
LMSTUDIO_HEALTH_PATH = os.getenv("MONITOR_LMSTUDIO_HEALTH_PATH", "/v1/models")
OPENAI_HEALTH_PATH = "/v1/models"


def server_kind(server: str) -> str:
    for kind, spec in SERVER_KINDS.items():
        if server.startswith(spec["prefix"]):
            return kind
    return "ollama"


def server_base(server: str) -> str:
    kind = server_kind(server)
    return server.removeprefix(SERVER_KINDS[kind]["prefix"]) if kind != "ollama" else server


def ollama_hosts() -> dict:
    """host URL -> tiers it serves. Includes every MODEL_SERVERS host, even one
    assigned to no tier: the router's discovery routes to it all the same."""
    hosts = {}
    for url in _url_list(os.getenv("MODEL_SERVERS", "")):
        hosts.setdefault(url, [])
    for tier, urls in BACKENDS.items():
        for url in urls:
            hosts.setdefault(url, []).append(tier)
    return hosts


def local_services() -> dict:
    """name -> health URL for the services running next to the monitor.
    OPENWEBUI_HEALTH_URL (written by the installer) overrides the ini default,
    because the Open WebUI port is chosen at install time."""
    if not _cfg.getboolean("local_services", "enabled"):
        return {}
    services = {name: url.strip() for name, url in _cfg.items("local_services")
                if name != "enabled" and url.strip()}
    override = (os.getenv("OPENWEBUI_HEALTH_URL") or "").strip()
    if override and "open-webui" in services:
        services["open-webui"] = override
    return services


class Check:
    """One monitored endpoint with debounced state.

    status   -- the confirmed state after the thresholds ('up' / 'down')
    notified -- the last state successfully delivered to Mattermost
    The two differ exactly when an alert still has to go out."""

    def __init__(self, key: str, url: str, label: str, headers: dict = None,
                 require_models: bool = False):
        self.key, self.url, self.label = key, url, label
        self.headers = headers or {}
        self.require_models = require_models
        self.status = self.notified = "up"
        self.fails = self.passes = 0
        self.last_error = ""

    def record(self, ok: bool, error: str = "") -> None:
        if ok:
            self.passes, self.fails = self.passes + 1, 0
            if self.status == "down" and self.passes >= RECOVER_THRESHOLD:
                self.status = "up"
        else:
            self.fails, self.passes = self.fails + 1, 0
            self.last_error = error
            if self.status == "up" and self.fails >= FAIL_THRESHOLD:
                self.status = "down"

    @property
    def pending(self) -> bool:
        return self.status != self.notified

    def message(self) -> tuple:
        if self.status == "down":
            detail = f" ({self.last_error})" if self.last_error else ""
            return (f"Infrastructure Alert: {self.label} is unavailable after "
                    f"{FAIL_THRESHOLD} failed checks{detail}.", ":warning:")
        return (f"Recovery Notice: {self.label} is operational again.",
                ":white_check_mark:")


def build_checks() -> list:
    checks = []
    for url, tiers in ollama_hosts().items():
        served = ", ".join(tiers) if tiers else "no tier (discovery only)"
        kind = server_kind(url)
        if kind != "ollama":
            spec, base = SERVER_KINDS[kind], server_base(url)
            token = KIND_KEYS[kind]
            headers = {"Authorization": f"Bearer {token}"} if token else {}
            path = OPENAI_HEALTH_PATH if spec["openai"] else LMSTUDIO_HEALTH_PATH
            checks.append(Check(url, f"{base}{path}",
                                f"{spec['label']} host `{base}` (serving: {served})",
                                headers, require_models=spec["openai"]))
        else:
            checks.append(Check(url, f"{url}{HEALTH_PATH}",
                                f"Ollama host `{url}` (serving: {served})"))
    for name, url in local_services().items():
        checks.append(Check(name, url, f"local service `{name}` ({url})"))
    return checks


def _post_once(payload: dict) -> tuple:
    """POST one payload. Returns (ok, status, body) -- status None on transport
    failure, with the exception text as the body."""
    try:
        with httpx.Client(verify=MATTERMOST_VERIFY_TLS) as client:
            resp = client.post(MATTERMOST_WEBHOOK_URL, json=payload, timeout=5.0)
        return (resp.status_code < 400, resp.status_code, resp.text.strip())
    except Exception as exc:  # noqa: BLE001 - transport errors are reported, not raised
        return (False, None, str(exc))


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
    # An incoming webhook is already bound to a channel. Naming the channel
    # explicitly makes the target unambiguous, but Mattermost REJECTS the
    # override unless the webhook is allowed to post elsewhere -- and a server
    # with channel overrides disabled fails every message with a 4xx that reads
    # like a permissions problem. So: try with the override, and on any 4xx
    # fall back to the webhook's own default channel rather than losing the
    # alert entirely.
    if MATTERMOST_CHANNEL:
        payload["channel"] = MATTERMOST_CHANNEL

    ok, status, body = _post_once(payload)
    if ok:
        return True

    if status is not None and 400 <= status < 500 and "channel" in payload:
        retry = {k: v for k, v in payload.items() if k != "channel"}
        ok_retry, status_retry, body_retry = _post_once(retry)
        if ok_retry:
            logging.warning(
                "Mattermost refused the channel override to '%s' (HTTP %s: %s); "
                "delivered to the webhook's own default channel instead. Either "
                "clear MATTERMOST_CHANNEL, or allow channel overrides for this "
                "webhook in the System Console.",
                MATTERMOST_CHANNEL, status, body)
            return True
        logging.error("Mattermost rejected message (HTTP %s): %s -- and again "
                      "without the channel override (HTTP %s): %s",
                      status, body, status_retry, body_retry)
        return False

    if status is None:
        logging.error("Failed message delivery: %s%s", body,
                      "" if MATTERMOST_VERIFY_TLS is False
                      else "  (if this is a certificate error, set "
                           "MATTERMOST_VERIFY_TLS=false in router.env)")
    else:
        logging.error("Mattermost rejected message (HTTP %s): %s", status, body)
    return False


def _notice_stamp() -> str:
    return os.path.join(STATE_DIR, "last-startup-notice") if STATE_DIR else ""


def startup_notice_due(now: float = None) -> bool:
    """False when a startup notice was delivered less than NOTICE_INTERVAL ago."""
    stamp = _notice_stamp()
    if not stamp or NOTICE_INTERVAL <= 0:
        return True
    try:
        with open(stamp) as fh:
            last = float(fh.read().strip() or 0)
    except (OSError, ValueError):
        return True
    return ((now or time.time()) - last) >= NOTICE_INTERVAL


def record_startup_notice(now: float = None) -> None:
    stamp = _notice_stamp()
    if not stamp:
        return
    try:
        with open(stamp, "w") as fh:
            fh.write("%f\n" % (now or time.time()))
    except OSError as exc:
        logging.warning("could not record the startup notice time: %s", exc)


def send_startup_notice(checks: list) -> None:
    host = socket.gethostname()
    watched = ", ".join(c.key for c in checks) or "nothing configured"
    message = (
        f"Ollama monitor online on `{host}` — health alerting is active. "
        f"Watching: {watched}. "
        f"(This is a startup test message confirming webhook access to "
        f"#{MATTERMOST_CHANNEL}.)"
    )
    if not MATTERMOST_WEBHOOK_URL:
        logging.warning("No MATTERMOST_WEBHOOK_URL set; skipping startup notice.")
        return
    if not startup_notice_due():
        logging.info("Startup notice skipped: one was sent within the last %ds "
                     "([startup] notice_interval_seconds).", NOTICE_INTERVAL)
        return
    if post_mattermost(message, emoji=":white_check_mark:"):
        record_startup_notice()
        logging.info("Startup notice delivered to #%s.", MATTERMOST_CHANNEL)
    else:
        logging.error(
            "Startup notice to #%s FAILED — check MATTERMOST_WEBHOOK_URL, the "
            "webhook's channel permissions, and MATTERMOST_VERIFY_TLS.",
            MATTERMOST_CHANNEL,
        )


def probe(url: str, client: httpx.Client, headers: dict = None,
          require_models: bool = False) -> tuple:
    """(ok, error) for one health URL. A 401/403 counts as down: a server
    that rejects the token cannot serve the router either. With
    require_models, the OpenAI model list must also name at least one model."""
    try:
        resp = client.get(url, timeout=CHECK_TIMEOUT, headers=headers or {})
        resp.raise_for_status()
        if require_models:
            models = resp.json().get("data")
            if not isinstance(models, list) or not models:
                return False, "no model loaded (the model list is empty)"
        return True, ""
    except Exception as exc:  # noqa: BLE001 - any failure is "unhealthy"
        return False, f"{type(exc).__name__}: {exc}"[:200]


def run_cycle(checks: list, client: httpx.Client, pool: ThreadPoolExecutor,
              notify=None) -> None:
    """Probe every check in parallel, update state, deliver pending alerts.
    An undelivered alert stays pending and is retried on the next cycle."""
    notify = notify or post_mattermost
    results = list(pool.map(lambda c: probe(c.url, client, c.headers, c.require_models),
                            checks))
    for check, (ok, error) in zip(checks, results, strict=True):
        before = check.status
        check.record(ok, error)
        if check.status != before:
            logging.warning("%s is now %s", check.label, check.status.upper())
        if check.pending:
            text, emoji = check.message()
            if notify(text, emoji):
                check.notified = check.status
            else:
                logging.warning("alert for %s not delivered; will retry", check.key)


# --- keep-alive thread --------------------------------------------------------
def pin_model(url: str, model: str) -> bool:
    """Load `model` on `url` and set its unload timer, generating nothing."""
    payload = {"model": model, "messages": [], "keep_alive": _keep_alive_value()}
    try:
        with httpx.Client() as client:
            resp = client.post(f"{url.rstrip('/')}/api/chat", json=payload,
                               timeout=KEEP_ALIVE_TIMEOUT)
            resp.raise_for_status()
        return True
    except Exception as exc:  # noqa: BLE001 - reported, the loop carries on
        logging.warning("keep-alive: %s on %s failed: %s", model, url, exc)
        return False


def refresh_keep_alive(is_up) -> int:
    """Pin each tier's model on every host serving that tier that is up.
    is_up(url) -> bool comes from the health checks."""
    pinned = 0
    for tier, urls in BACKENDS.items():
        model = TIER_MODELS.get(tier, "")
        if not model:
            continue
        for url in urls:
            if server_kind(url) != "ollama":
                # LM Studio has no keep_alive: it loads on demand and unloads
                # on its own idle TTL (configure that in LM Studio itself).
                continue
            if not is_up(url):
                continue          # don't wait on a host we already know is down
            if pin_model(url, model):
                pinned += 1
    if pinned:
        logging.info("keep-alive: refreshed %d model(s) with keep_alive=%s",
                     pinned, KEEP_ALIVE)
    return pinned


def keep_alive_loop(checks: list, stop: threading.Event) -> None:
    by_url = {c.key: c for c in checks}

    def is_up(url):
        check = by_url.get(url)
        return check is None or check.status == "up"

    while not stop.is_set():
        try:
            refresh_keep_alive(is_up)
        except Exception:  # noqa: BLE001 - never let the thread die
            logging.exception("keep-alive: refresh failed")
        stop.wait(KEEP_ALIVE_INTERVAL)


def run_health_checks() -> None:
    checks = build_checks()
    if not checks:
        logging.error("No Ollama hosts or local services configured; nothing to monitor.")
        return
    logging.info("Monitoring %d endpoint(s): %s (alert after %d failures, "
                 "recover after %d passes)", len(checks),
                 ", ".join(c.key for c in checks), FAIL_THRESHOLD, RECOVER_THRESHOLD)
    stop = threading.Event()
    if KEEP_ALIVE_ENABLED:
        logging.info("keep-alive maintainer active: keep_alive=%s every %ds",
                     KEEP_ALIVE, KEEP_ALIVE_INTERVAL)
        threading.Thread(target=keep_alive_loop, args=(checks, stop),
                         name="keep-alive", daemon=True).start()
    elif KEEP_ALIVE:
        logging.info("keep-alive configured (%s) but the maintainer is disabled.",
                     KEEP_ALIVE)
    else:
        logging.info("No OLLAMA_KEEP_ALIVE set; each server's own setting applies.")
    # Confirm on startup that the webhook works and has channel permission.
    send_startup_notice(checks)
    with httpx.Client() as client, ThreadPoolExecutor(max_workers=min(16, len(checks))) as pool:
        while True:
            started = time.monotonic()
            run_cycle(checks, client, pool)
            time.sleep(max(1.0, CHECK_INTERVAL - (time.monotonic() - started)))


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
      local url="${MODEL_SERVERS[$idx]}"
      printf '  - model_name: %s\n' "$name"
      printf '    litellm_params:\n'
      if [[ "$url" == lmstudio+* ]]; then
        # LM Studio: LiteLLM's lm_studio provider on its OpenAI-compatible /v1.
        printf '      model: lm_studio/%s\n' "$tag"
        printf '      api_base: %s/v1\n' "${url#lmstudio+}"
      elif [[ "$url" == strata+* ]]; then
        printf '      model: openai/%s\n' "$tag"
        printf '      api_base: %s/v1\n' "${url#strata+}"
        printf '      api_key: none\n'
      elif [[ "$url" == basalt+* ]]; then
        printf '      model: openai/%s\n' "$tag"
        printf '      api_base: %s/v1\n' "${url#basalt+}"
        printf '      api_key: none\n'
      elif [[ "$url" == maya+* ]]; then
        printf '      model: openai/%s\n' "$tag"
        printf '      api_base: %s/v1\n' "${url#maya+}"
        printf '      api_key: none\n'
      else
        printf '      model: ollama/%s\n' "$tag"
        printf '      api_base: %s\n' "$url"
        # LiteLLM talks to Ollama's NATIVE api, which does honour keep_alive
        # (merged upstream in litellm PR #7079).
        [[ -n "$OLLAMA_KEEP_ALIVE" ]] && printf '      keep_alive: %s\n' "$OLLAMA_KEEP_ALIVE"
      fi
    done
  }
  emit_tier_deployments fast   "$MODEL_FAST"   "$TIER_FAST_IDX"
  emit_tier_deployments medium "$MODEL_MEDIUM" "$TIER_MEDIUM_IDX"
  emit_tier_deployments large  "$MODEL_LARGE"  "$TIER_LARGE_IDX"
  emit_tier_deployments xlarge "$MODEL_XLARGE" "$TIER_XLARGE_IDX"
  # Fallbacks only between tiers that actually have deployments (a fallback
  # to an empty tier fails LiteLLM's config and `manage apply` validation).
  for _t in fast:"$MODEL_FAST":"$TIER_FAST_IDX" medium:"$MODEL_MEDIUM":"$TIER_MEDIUM_IDX" \
            large:"$MODEL_LARGE":"$TIER_LARGE_IDX" xlarge:"$MODEL_XLARGE":"$TIER_XLARGE_IDX"; do
    IFS=: read -r _name _tag _idx <<< "$_t"
    [[ -n "${_idx// /}" ]] || continue
    printf '%s %s@%s\n' "$_name" "$_tag" "$(indices_to_urls "$_idx")"
  done | litellm_router_settings
} > "${REPO_DIR}/services/litellm-proxy/litellm_config.yaml"

# --- Open WebUI environment ---
# Open WebUI talks to the *complexity router* (port 8000) as an OpenAI-
# compatible backend, so chats are smart-routed by prompt complexity. The
# router proxies /v1/models through to LiteLLM so the model list still
# populates. NOTE: because the router chooses the tier per request, the model
# picked in the UI is overridden — the dropdown reflects what LiteLLM exposes,
# not what actually served the reply. To let the UI pick the model manually
# instead, point OPENAI_API_BASE_URLS at http://127.0.0.1:4000/v1 (LiteLLM
# direct). The real router API key is NOT written here: it lives in
# /app/router/secrets.env (OPENAI_API_KEYS), which the unit loads after this
# file. The value below is only a placeholder for a router without a key.
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
# LiteLLM runs in its OWN venv (/app/litellm/venv). The [proxy] extra is what
# `litellm --config` needs (backoff, orjson, apscheduler, ...); without it the
# proxy dies at import with "Missing dependency ... pip install 'litellm[proxy]'".
# It also pins fastapi/uvicorn versions that conflict with the router's, which is
# why it cannot share /app/router/venv.
#
# requirements.lock (next to this file) is the hash-locked resolution of this
# pin and is preferred at install time (pip --require-hashes). Regenerate it
# after changing the pin:
#   uv pip compile requirements.txt --generate-hashes --python-version 3.13 \
#     --python-platform x86_64-unknown-linux-gnu -o requirements.lock
# Never move to 1.82.7 or 1.82.8: both were malicious uploads (March 2026).
litellm[proxy]==1.75.5.post1
REQEOF

cat > "${REPO_DIR}/services/ollama-monitor/requirements.txt" <<'REQEOF'
httpx==0.28.1
REQEOF

cat > "${REPO_DIR}/services/open-webui/requirements.txt" <<EOF
open-webui==${OPENWEBUI_VERSION}
EOF

# The hash lock for LiteLLM is too large to embed here. When the installer is
# run from a checkout of this repo, carry it along so it is seeded and used.
_installer_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_installer_dir}/services/litellm-proxy/requirements.lock" ]]; then
  cp "${_installer_dir}/services/litellm-proxy/requirements.lock" \
     "${REPO_DIR}/services/litellm-proxy/requirements.lock"
fi

# --- routing tunables moved out of code into version-controlled ini ---
cat > "${REPO_DIR}/services/ollama-router/router.ini" <<'INIEOF'
# Complexity-routing tunables. Edit + commit to change routing behaviour
# without touching router.py. Applied at provisioning time.
[thresholds]
# Approximate token counts (words * 1.3) above which a tier is chosen.
# Evaluated highest-first: xlarge, then large, then medium.
xlarge = 2000
large = 800
medium = 250

[keywords]
# JSON arrays, so exact spacing is preserved. Matched case-insensitively as
# WHOLE WORDS (a plural/past suffix is allowed: "bug" matches "bugs"), so
# "script" no longer matches "description" and "prove" no longer matches
# "improve". A trailing space is significant: "def " must be followed by
# whitespace. An entry starting with "re:" is a regular expression (JSON-escape
# backslashes: "re:\\bclass\\s+\\w+"), used for code SHAPES so that "first
# class ticket" or "import my contacts" are not mistaken for code.
# code_first=true means a code match wins regardless of length.
code_first = true
code = ["re:\\bdef\\s+\\w+\\s*\\(", "re:\\bfn\\s+\\w+\\s*\\(", "re:\\bclass\\s+\\w+\\s*[:({]", "re:^\\s*(?:from\\s+\\S+\\s+)?import\\s+[\\w.]+", "re:```", "function", "sql", "script", "code", "bug", "error", "compile", "stack trace", "regex"]
large = ["analyze", "evaluate", "optimise", "optimize", "architecture", "mathematics", "calculate", "summarise this article"]
# Checked before the large list: work that wants the deepest model available.
xlarge = ["prove", "derive", "rigorous", "comprehensive", "exhaustive", "step by step proof", "entire codebase", "whole repository", "research report", "literature review"]

[tiers]
fast = fast
medium = medium
large = large
xlarge = xlarge

[classification]
# What the keyword and length heuristics judge:
#   last_user    -- the newest user message only. A system prompt or an old
#                   turn can no longer pin a whole conversation to one tier.
#   conversation -- every message (the old behaviour).
# Images are always looked for in every message.
scope = last_user
# true: an image request fails with HTTP 400 when no discovered model looks
# vision-capable. false: route it anyway, flagged with X-Router-Warning.
vision_strict = false
# Requests that offer tools (agents such as Hermes, Open WebUI native function
# calling) skip models whose server reports no tool support, are raised to at
# least this class (small models are poor at tool use; blank: no floor), and
# stay on one model across an agent loop. A tier alias still pins the class.
tools_min_class = large
# true: a tool request fails with HTTP 400 when every discovered model is
# known to lack tools. false: route it anyway, flagged with X-Router-Warning.
tools_strict = false

[http]
# Seconds to open a connection to a backend. This is how long a dead host can
# delay failover to the next candidate, so keep it short.
connect_timeout_seconds = 3
# Seconds allowed between bytes of a response (slow generation is fine).
read_timeout_seconds = 300

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
# Ask each server's /api/show for the capabilities Ollama reports per model
# ("vision", "embedding", ...), cached per model digest. This catches vision
# models whose names give nothing away (gemma3, mistral-small3.1, qwen2.5vl).
# The *_models / *_families name lists below are the fallback for servers that
# do not report capabilities.
capability_probe = true
# LM Studio servers (entries written lmstudio+http://host:1234) are polled via
# LM Studio's own model API, which reports vision/embedding and whether each
# model is loaded. true: never route to a model that is not loaded there, so a
# request never waits for LM Studio's just-in-time load (and never evicts
# another model to make room).
lmstudio_loaded_only = false
# Parameter-count bands (billions) each request class prefers: low:high
fast_params = 0:9
medium_params = 9:20
large_params = 20:70
xlarge_params = 70:999
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
prefer_larger = 0.15
prefer_smaller = 0.15
unknown_params = 0.3
# Penalty fraction when a specialised model serves an off-task request
# (a vision model answering plain text, a code model answering prose).
offtask_penalty = 0.25
# Candidates within this score of the best are rotated through, so the same
# model on several hosts shares load.
tie_epsilon = 0.05
# Bonus for a model that is already resident (LM Studio reports this; Ollama
# entries are neutral). Small: it breaks near-ties, it does not override fit.
loaded_bonus = 0.1
# On a tool request, bonus for a model reported tool-capable over one whose
# tool support is unknown (Strata/Basalt/Maya/Xolotl, LM Studio's untrained models).
tool_match = 0.3

[model_sizes]
# Sizes for exact model ids that an OpenAI-compatible server (Strata, Basalt,
# Maya, Xolotl) lists without a parameter count, so the router can size-band them.
# Matching is by the whole id, case-insensitive: variants and aliases (Strata's
# Coder, a renamed Basalt alias) stay unknown-size unless listed here.
# Add a line for a custom alias (e.g. the BASALT_ALIAS a target serves);
# a blank value removes one of these built-in entries.
strata = 125B
qwen3.8-flash-next = 125B
glm-5.3-flash = 321B
deepseek-v4.1-flash = 552B
INIEOF

cat > "${REPO_DIR}/services/ollama-monitor/monitor.ini" <<'INIEOF'
# Health-monitor tunables. Backend URLs stay in env/router.env and the webhook
# in /app/router/secrets.env; only polling/alerting behaviour lives here.
# Every model host in MODEL_SERVERS and the BACKEND_* lists is watched.
[polling]
interval_seconds = 15
timeout_seconds = 5
# Path appended to each Ollama backend URL for the health probe. LM Studio,
# Strata, Basalt, Maya and Xolotl are probed on /v1/models with their own keys
# when set, and are skipped by the keep-alive pinner. They count as down while
# that list is empty (their engine is not running).
health_path = /api/tags

[alerting]
# Consecutive failed checks before a host/service is reported DOWN, and
# consecutive passing checks before it is reported back UP. With the default
# 15 s interval, 3 failures = an alert after ~45 s of real outage, and a single
# dropped probe never pages anyone. An alert that fails to deliver is retried
# every cycle until Mattermost accepts it.
fail_threshold = 3
recover_threshold = 2

[startup]
# The "monitor online" confirmation is posted at most once per this many
# seconds, so a restart loop cannot flood the channel. 0 = on every start.
notice_interval_seconds = 3600

[local_services]
# Services on this container, probed with the same thresholds. The Open WebUI
# URL is overridden by OPENWEBUI_HEALTH_URL (router.env) when the installer
# used a non-default port. Set enabled = false to watch the Ollama hosts only.
enabled = true
litellm-proxy = http://127.0.0.1:4000/health/liveliness
ollama-router = http://127.0.0.1:8000/healthz
open-webui = http://127.0.0.1:8080/health

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
# Secrets never live in the config repo: they are kept beside the runtime copy
# of the env file, readable by the service group only, and loaded by the units
# that need them through a second EnvironmentFile=.
SECRETS_FILE="${SECRETS_FILE:-${ROUTER_DIR}/secrets.env}"
# LiteLLM runs from its own venv (see services/litellm-proxy/requirements.txt).
LITELLM_DIR="${LITELLM_DIR:-/app/litellm}"
LITELLM_REQ="${REPO_DIR}/services/litellm-proxy/requirements.txt"
LITELLM_LOCK="${REPO_DIR}/services/litellm-proxy/requirements.lock"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
# Default ports of the other server kinds are in kind_field (LM Studio 1234,
# Strata/Basalt/Maya/Xolotl 8080); LMSTUDIO_PORT, STRATA_PORT, BASALT_PORT,
# MAYA_PORT and XOLOTL_PORT in the environment override them.
LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
SERVER_TYPE="auto"   # --type ollama|<kind>|auto for add / set-tier (see server_kinds)
MODEL_SERVER_MAX="${MODEL_SERVER_MAX:-20}"
MODEL_SERVER_MIN="${MODEL_SERVER_MIN:-1}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:8000}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
SERVICES=(litellm-proxy ollama-router ollama-monitor open-webui)
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
# Snapshots of the runtime files taken before each apply (root-only).
APPLY_BACKUP_DIR="${APPLY_BACKUP_DIR:-/var/backups/ollama-smart-router}"
APPLY_BACKUP_KEEP="${APPLY_BACKUP_KEEP:-5}"
# One config change at a time (this tool and install/update-router.sh share it).
# The lock is an flock on this file: it lasts only as long as the process that
# holds it, so a crash or reboot never leaves it in force. CONFIG_LOCK_WAIT
# seconds to wait for it (0 = fail at once); `clear-lock` deals with a hung holder.
CONFIG_LOCK_FILE="${CONFIG_LOCK_FILE:-/run/lock/ollama-smart-router-config.lock}"
CONFIG_LOCK_WAIT="${CONFIG_LOCK_WAIT:-0}"
# Seconds clear-lock --force gives a holder to exit after SIGTERM before SIGKILL.
LOCK_KILL_WAIT="${LOCK_KILL_WAIT:-10}"
# Seconds a restarted service gets to pass its health check. Open WebUI's
# first start downloads an embedding model, hence its longer allowance.
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
OPENWEBUI_HEALTH_TIMEOUT="${OPENWEBUI_HEALTH_TIMEOUT:-300}"
LITELLM_HEALTH_URL="${LITELLM_HEALTH_URL:-http://127.0.0.1:4000/health/liveliness}"
APPLY_ALL=false
CONFIG_LOCK_FD=""

declare -A TIER_MODEL_OVERRIDE=()   # tier            -> model tag
declare -A PAIR_MODEL_OVERRIDE=()   # "tier|server"   -> model tag

CHANGED=false      # set by a command that actually wrote something
DRY_RUN=false
NO_PROBE=false
AUTO_APPLY=false
AUTO_COMMIT=false
ASSUME_YES=false
FORCE=false

usage() {
  cat <<'USAGE'
Usage: manage-model-servers.sh <command> [options]

Commands:
  list                       Show configured servers and their tier assignments
  status                     As list, plus a live reachability probe of each host
  discover                   Ask OSR to re-poll and print the live model inventory
  add <addr> [addr...]       Add server(s). Address may be IP, host:port or a URL.
                             LM Studio, Strata, Basalt, Maya and Xolotl are detected
                             automatically, or use lmstudio://host / strata://host /
                             basalt://host / maya://host / xolotl://host or --type.
                             Detection sends no API key.
  remove <addr> [addr...]    Remove server(s) by address (or by list number)
  set-tier <tier> <addr...>  Replace a tier's servers (tier: fast|medium|large|xlarge)
  set-model <tier> <model>   Set the model for EVERY server in a tier
  set-server-model <tier> <server> <model>
                             Set the model for ONE server within a tier
  set-keepalive <value>      Set how long Ollama keeps models resident
                             (e.g. 30m, 2h, -1 = never unload, blank = use the
                             server's own OLLAMA_KEEP_ALIVE)
  models                     List every model available across the configured hosts
  apply [--all]              Validate the config, apply it, restart only the
                             services whose files changed, health-check them,
                             and roll back automatically if one fails.
                             --all restarts every service regardless
  commit [message]           Commit and push the config repo to Gitea
  set-token [token]          Store/replace the Gitea deploy token used for
                             pushing (prompts if not given, then verifies it)
  test-alert [message]       Post a test message through the Mattermost webhook
                             and report exactly why it failed if it did
  set-webhook [url] [--channel <c>] [--username <u>] [--verify-tls true|false]
                             Configure Mattermost alerting. An empty url
                             disables posting; an empty --channel posts to
                             whichever channel the webhook is bound to
  set-lmstudio-token [token|--off]
                             Bearer token for LM Studio servers that require
                             authentication (stored in secrets.env)
  set-strata-token [token|--off]
                             Bearer token for Strata servers with an API key
                             (stored in secrets.env)
  set-basalt-token [token|--off]
                             Bearer token for Basalt servers with an API key
                             (stored in secrets.env)
  set-maya-token [token|--off]
                             Bearer token for Maya servers with an API key
                             (stored in secrets.env)
  set-xolotl-token [token|--off]
                             Bearer token for Xolotl servers with an API key
                             (stored in secrets.env)
  set-api-key [key|--generate|--off]
                             Require "Authorization: Bearer <key>" on OSR
                             API (Open WebUI is given the same key)
  set-webui-version [v]      Show, or pin, the Open WebUI version (use 'latest').
                             Checks the version exists and that the venv's
                             Python satisfies its Requires-Python
  clear-lock [--force]       Show who holds the config lock. A crash or reboot
                             never leaves it in force (it dies with its
                             process); a live but hung holder is only stopped
                             with --force (SIGTERM, then SIGKILL)

Options:
  --tier <t[,t...]>          With 'add': also assign the new server(s) to these tiers
  --type <ollama|lmstudio|strata|basalt|maya|xolotl> With 'add' / 'set-tier': the server's API (default:
                             auto-detect by probing; ollama when --no-probe)
  --apply                    Apply + restart services after the change
  --commit[=msg]             Commit and push the change after applying
  --no-probe                 Skip the reachability check when adding, and the
                             model-availability check when setting a model
  --dry-run                  Show what would change; write nothing
  --yes, -y                  Do not prompt for confirmation
  --force                    With 'clear-lock': stop the process holding the lock
  -h, --help                 This help

Examples:
  manage-model-servers.sh add 10.0.0.55 --tier large --apply
  manage-model-servers.sh add ollama7.lan:11434 --tier fast,medium --apply --commit
  manage-model-servers.sh remove 10.0.0.52 --apply
  manage-model-servers.sh set-tier large 10.0.0.54 10.0.0.55 --apply
  manage-model-servers.sh models
  manage-model-servers.sh set-model large qwen3:32b --apply --commit
  manage-model-servers.sh set-server-model large 10.0.0.54 llama3.3:70b --apply
  manage-model-servers.sh set-server-model medium 192.168.11.14 smtek/Qwen3.8-27B:Q3_K_XL-16gb --apply
  manage-model-servers.sh set-keepalive 2h --apply
  manage-model-servers.sh set-webui-version latest --apply
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

# --- address handling ---------------------------------------------------------
valid_hostname_or_ip() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

# --- server kinds -------------------------------------------------------------
# One table for every server kind that is not Ollama. Their entries are stored
# as <kind>+http://host:port, so each consumer knows which API to speak.
# router.py and monitor.py keep matching SERVER_KINDS tables, and
# tests/test_monitor.py checks that all three agree. Adding a kind here (and
# there) is all the manager needs: detection fingerprints aside, nothing below
# names a kind.
#   key    -- secrets.env variable with the bearer token for that kind
#   label  -- human name in messages
#   port   -- default port (overridable through the <KIND>_PORT variable)
#   openai -- 1 for Strata-style servers (models at /v1/models, LiteLLM's
#             openai provider), 0 for LM Studio (its own API and provider)
server_kinds() { printf '%s\n' lmstudio strata basalt maya xolotl; }
kind_field() {
  local spec key label port_var port_default openai value
  case "$1" in
    lmstudio) spec='LMSTUDIO_API_TOKEN|LM Studio|LMSTUDIO_PORT|1234|0' ;;
    strata)   spec='STRATA_API_KEY|Strata|STRATA_PORT|8080|1' ;;
    basalt)   spec='BASALT_API_KEY|Basalt|BASALT_PORT|8080|1' ;;
    maya)     spec='MAYA_API_KEY|Maya|MAYA_PORT|8080|1' ;;
    xolotl)   spec='XOLOTL_API_KEY|Xolotl|XOLOTL_PORT|8080|1' ;;
    *) return 1 ;;
  esac
  IFS='|' read -r key label port_var port_default openai <<< "$spec"
  case "$2" in
    key) printf '%s\n' "$key" ;;
    label) printf '%s\n' "$label" ;;
    port) value="${!port_var:-}"; printf '%s\n' "${value:-$port_default}" ;;
    openai) printf '%s\n' "$openai" ;;
    *) return 1 ;;
  esac
}
is_server_kind() { [[ -n "$1" ]] && server_kinds | grep -qx -- "$1"; }
is_openai_kind() { is_server_kind "$1" && [[ "$(kind_field "$1" openai)" == 1 ]]; }
openai_kinds() { local k; for k in $(server_kinds); do is_openai_kind "$k" && echo "$k"; done; return 0; }
# "Ollama, LM Studio, Strata, Basalt, Maya or Xolotl"
kind_labels() {
  local out=Ollama k label last=""
  for k in $(server_kinds); do
    label="$(kind_field "$k" label)"
    [[ -n "$last" ]] && out+=", ${last}"
    last="$label"
  done
  printf '%s or %s\n' "$out" "$last"
}
# The secret's name in messages: "LM Studio token", "Maya API key".
kind_secret_name() {
  if [[ "$1" == lmstudio ]]; then echo "LM Studio token"
  else printf '%s API key\n' "$(kind_field "$1" label)"; fi
}

server_kind() {
  local k
  for k in $(server_kinds); do
    [[ "$1" == "$k"+* ]] && { echo "$k"; return 0; }
  done
  echo ollama
}
server_base() {
  local kind; kind="$(server_kind "$1")"
  if [[ "$kind" == ollama ]]; then printf '%s\n' "$1"; else printf '%s\n' "${1#"$kind"+}"; fi
}
# LiteLLM provider prefix and api_base for a server entry. OpenAI-compatible
# servers use /v1; LM Studio uses LiteLLM's lm_studio/ provider.
litellm_provider() {
  local kind; kind="$(server_kind "$1")"
  if [[ "$kind" == lmstudio ]]; then echo lm_studio
  elif is_openai_kind "$kind"; then echo openai
  else echo ollama; fi
}
litellm_api_base() {
  if [[ "$(server_kind "$1")" != ollama ]]; then
    printf '%s/v1\n' "$(server_base "$1")"
  else
    printf '%s\n' "$1"
  fi
}

# curl against a server entry, with its API token when there is one.
# The header goes through a file descriptor so the token never shows in `ps`.
server_curl() {
  local url="$1" path="$2" token="" kind
  kind="$(server_kind "$url")"
  if [[ "$kind" != ollama ]]; then
    token="$(env_get "$(kind_field "$kind" key)" 2>/dev/null)"
  fi
  if [[ -n "$token" ]]; then
    curl -fsS --max-time "$PROBE_TIMEOUT" -H @<(printf 'Authorization: Bearer %s\n' "$token") \
      "$(server_base "$url")${path}"
  else
    curl -fsS --max-time "$PROBE_TIMEOUT" "$(server_base "$url")${path}"
  fi
}

valid_addr() {
  local raw="$1" port
  [[ -n "$raw" ]] || return 1
  # Kind prefixes (maya+http://..., maya://host) select the non-Ollama APIs.
  local k
  for k in $(server_kinds); do
    raw="${raw#"$k"+}"
    [[ "$raw" == "$k"://* ]] && raw="${raw#"$k"://}"
  done
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

# Canonical form of an address: http://host:port for Ollama, or a kind prefix
# plus http://host:port for the OpenAI-compatible servers. $2 (or SERVER_TYPE)
# may force the kind; the default port follows it. A full http(s):// URL
# without a port gets its scheme's default (80 or 443), written out so the
# router, the monitor and the Hermes firewall all see the same endpoint.
normalize_addr() {
  local raw="${1%/}" kind="${2:-$SERVER_TYPE}" port base k rest hostport
  for k in $(server_kinds); do
    if [[ "$raw" == "$k"+* ]]; then kind="$k"; raw="${raw#"$k"+}"; break; fi
    if [[ "$raw" == "$k"://* ]]; then kind="$k"; raw="${raw#"$k"://}"; break; fi
  done
  if is_server_kind "$kind"; then port="$(kind_field "$kind" port)"; else port="$OLLAMA_PORT"; fi
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    base="$raw"
    rest="${raw#*://}"
    hostport="${rest%%/*}"
    if [[ "$hostport" != *:* || "$hostport" == *\] ]]; then
      if [[ "$raw" == https://* ]]; then k=443; else k=80; fi
      base="${raw%%://*}://${hostport}:${k}${rest:${#hostport}}"
    fi
  elif [[ "$raw" == *:* ]]; then
    base="http://${raw}"
  else
    base="http://${raw}:${port}"
  fi
  if is_server_kind "$kind"; then
    printf '%s+%s\n' "$kind" "$base"
  else printf '%s\n' "$base"; fi
}

# Which API answers at a plain http base URL.
detect_server_kind() {
  local base="$1" body
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/api/tags" 2>/dev/null)" &&
     [[ "$body" == *'"models"'* ]]; then
    echo ollama; return 0
  fi
  # Both services identify themselves at public /health without credentials.
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/health" 2>/dev/null)"; then
    if [[ "$body" =~ \"service\"[[:space:]]*:[[:space:]]*\"strata\" ]]; then
      # Xolotl serves through Strata's server; its DeepSeek-V4 engine (a model
      # upstream Strata does not run) tells it apart.
      if [[ "$body" =~ \"model\"[[:space:]]*:[[:space:]]*\"deepseek-v4 ]]; then
        echo xolotl; return 0
      fi
      echo strata; return 0
    fi
    if [[ "$body" =~ \"service\"[[:space:]]*:[[:space:]]*\"basalt\" ]]; then
      echo basalt; return 0
    fi
    if [[ "$body" =~ \"model\"[[:space:]]*:[[:space:]]*\"glm-5\.3-flash\" ]] &&
       [[ "$body" == *'"version"'* ]]; then
      echo maya; return 0
    fi
  fi
  local code path status_code=''
  body="$(curl -sS --max-time "$PROBE_TIMEOUT" -w '\n%{http_code}' "${base}/v1/status" 2>/dev/null || true)"
  status_code="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [[ "$status_code" == 200 && "$body" == *'"auto_load"'* && "$body" == *'"loaded"'* ]]; then
    echo strata; return 0
  fi
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/v1/models" 2>/dev/null)" &&
     [[ "$body" =~ \"(id|owned_by)\"[[:space:]]*:[[:space:]]*\"strata\" ]]; then
    echo strata; return 0
  fi
  # LM Studio: its native model API (0.4+ /api/v1, 0.3 /api/v0). A 401 still
  # identifies it: authentication is on and needs set-lmstudio-token. An
  # older keyed server without a service marker on /health can also answer
  # 401 here; then only LM Studio's own port settles it.
  for path in /api/v1/models /api/v0/models; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$PROBE_TIMEOUT" "${base}${path}" 2>/dev/null || true)"
    [[ "$code" == 200 ]] && { echo lmstudio; return 0; }
    if [[ "$code" == 401 ]]; then
      if [[ "$status_code" != 401 || "${base##*:}" == "$LMSTUDIO_PORT" ]]; then
        echo lmstudio; return 0
      fi
      note "  ${base} requires authentication, so its API cannot be identified without sending a key."
      local k forms=()
      for k in $(openai_kinds) lmstudio; do forms+=("${k}://${base#*://}"); done
      note "  Add it as one of: ${forms[*]} (or use --type)."
      return 1
    fi
  done
  return 1
}

# The configured entry an address refers to, so "10.0.0.9:1234" finds a stored
# lmstudio+http://10.0.0.9:1234 without the prefix having to be typed. Prints
# the normalized form when nothing matches.
configured_entry() {
  local url alt k
  # Stored exactly as typed: an http(s) URL without a port, saved before
  # normalize_addr wrote the default port out, is still found.
  get_servers | contains_line "${1%/}" && { printf '%s\n' "${1%/}"; return 0; }
  url="$(normalize_addr "$1")"
  get_servers | contains_line "$url" && { printf '%s\n' "$url"; return 0; }
  for k in lmstudio ollama $(openai_kinds); do
    alt="$(normalize_addr "$1" "$k")"
    get_servers | contains_line "$alt" && { printf '%s\n' "$alt"; return 0; }
  done
  printf '%s\n' "$url"
}

# Resolve a user-supplied address to a stored server entry, probing to find
# out what it is unless --type says so (or --no-probe is given, which assumes
# Ollama unless the address has a kind prefix). Prints the entry; returns 1 if
# nothing usable answers.
resolve_server() {
  local addr="$1" url base kind alt
  url="$(normalize_addr "$addr")"
  [[ "$SERVER_TYPE" != auto || "$(server_kind "$url")" != ollama ]] && { printf '%s\n' "$url"; return 0; }
  $NO_PROBE && { printf '%s\n' "$url"; return 0; }
  base="$(server_base "$url")"
  if kind="$(detect_server_kind "$base")"; then
    normalize_addr "$base" "$kind"; return 0
  fi
  # A bare host got Ollama's port; another API may be on its own port instead.
  # Each distinct default port is probed once, and whichever OpenAI-style
  # server answers there is accepted (they share 8080 unless overridden).
  if [[ "$addr" != *:* ]]; then
    alt="$(server_base "$(normalize_addr "$addr" lmstudio)")"
    if kind="$(detect_server_kind "$alt")" && [[ "$kind" == lmstudio ]]; then
      normalize_addr "$alt" lmstudio; return 0
    fi
    local k tried=" "
    for k in $(openai_kinds); do
      alt="$(server_base "$(normalize_addr "$addr" "$k")")"
      [[ "$tried" == *" $alt "* ]] && continue
      tried+="$alt "
      if kind="$(detect_server_kind "$alt")" && is_openai_kind "$kind"; then
        normalize_addr "$alt" "$kind"; return 0
      fi
    done
  fi
  return 1
}

# --- env file access ----------------------------------------------------------
# Keys that must never be written to the version-controlled env file.
secret_keys() {
  local k
  printf '%s\n' GITEA_DEPLOY_TOKEN MATTERMOST_WEBHOOK_URL ROUTER_API_KEY OPENAI_API_KEYS
  for k in $(server_kinds); do kind_field "$k" key; done
}
is_secret_key() { secret_keys | grep -qx -- "$1"; }

# Raw KEY=value access to one file. kv_get prints nothing for a missing key;
# kv_has distinguishes "absent" from "present but empty".
kv_has() { [[ -f "$1" ]] && grep -q "^${2}=" "$1"; }
kv_get() {
  [[ -f "$1" ]] || return 0
  awk -v k="$2" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$1"
}
kv_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if kv_has "$file" "$key"; then
    # ENVIRON, not -v: awk -v would interpret backslashes in the value.
    KV_VALUE="$value" awk -v k="$key" -F= \
      '{ if ($1==k) print k "=" ENVIRON["KV_VALUE"]; else print }' "$file" > "$tmp"
  else
    [[ -f "$file" ]] && cp "$file" "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  # Copy content rather than mv, so an existing file keeps its 0640
  # root:ollama-router ownership and mode instead of inheriting the temp file's.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}
kv_del() {
  local file="$1" key="$2" tmp
  kv_has "$file" "$key" || return 0
  tmp="$(mktemp)"
  awk -v k="$key" -F= '$1!=k' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Create the secrets file with service-group-only permissions if needed.
ensure_secrets_file() {
  [[ -f "$SECRETS_FILE" ]] && return 0
  mkdir -p "$(dirname "$SECRETS_FILE")"
  ( umask 027; : > "$SECRETS_FILE" )
  chown root:ollama-router "$SECRETS_FILE" 2>/dev/null || true
  chmod 0640 "$SECRETS_FILE"
}

# --- env file access ----------------------------------------------------------
# Secret keys resolve from SECRETS_FILE first and fall back to the repo env file,
# so a deployment that has not been migrated yet keeps working.
env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || die "env file not found: ${ENV_FILE}"
  if is_secret_key "$key" && kv_has "$SECRETS_FILE" "$key"; then
    kv_get "$SECRETS_FILE" "$key"
    return 0
  fi
  kv_get "$ENV_FILE" "$key"
}

env_set() {
  local key="$1" value="$2"
  if is_secret_key "$key"; then
    $DRY_RUN && { echo "  [dry-run] ${key}=<secret> -> ${SECRETS_FILE}"; return 0; }
    ensure_secrets_file
    kv_set "$SECRETS_FILE" "$key" "$value"
    kv_del "$ENV_FILE" "$key"
    return 0
  fi
  $DRY_RUN && { echo "  [dry-run] ${key}=${value}"; return 0; }
  kv_set "$ENV_FILE" "$key" "$value"
}

# Move any secret still sitting in the version-controlled env file into
# SECRETS_FILE. Runs before every commit and apply, so a token can never be
# committed again once this script has touched the deployment.
migrate_secrets() {
  local key value moved=0
  $DRY_RUN && return 0
  [[ -f "$ENV_FILE" ]] || return 0
  for key in $(secret_keys); do
    kv_has "$ENV_FILE" "$key" || continue
    value="$(kv_get "$ENV_FILE" "$key")"
    if [[ -n "$value" ]] && ! kv_has "$SECRETS_FILE" "$key"; then
      ensure_secrets_file
      kv_set "$SECRETS_FILE" "$key" "$value"
    fi
    kv_del "$ENV_FILE" "$key"
    [[ -n "$value" ]] && moved=$((moved + 1))
  done
  if (( moved )); then
    note "Moved ${moved} secret(s) out of $(basename "$ENV_FILE") into ${SECRETS_FILE}."
    note "  They are still in the repo's git history: rotate the Gitea token and"
    note "  the Mattermost webhook if the repo was ever pushed."
  fi
}

# NOTE for callers: this dies on an unknown tier, but a `die` inside $(...)
# only kills the subshell. Assignment sites must therefore append `|| exit 1`,
# or an invalid tier silently yields an empty key and corrupts router.env.
tier_env_key() {
  case "$1" in
    fast)   echo "BACKEND_FAST" ;;
    medium) echo "BACKEND_MEDIUM" ;;
    large)  echo "BACKEND_LARGE" ;;
    xlarge) echo "BACKEND_XLARGE" ;;
    *) die "unknown tier '$1' (expected fast, medium, large or xlarge)" ;;
  esac
}

# Tier model_name comes from router.ini so custom names are honoured.
tier_model_name() {
  local key="$1" val=""
  if [[ -f "$ROUTER_INI" ]]; then
    val="$(awk -v k="$key" '/^\[tiers\]/{f=1;next} /^\[/{f=0} f && $1==k {print $3; exit}' "$ROUTER_INI")"
  fi
  printf '%s' "${val:-${key}}"
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
probe_server() {  # prints model count, "-" when unreachable, "?" when unreadable
  local url="$1" names rc=0
  names="$(server_models "$url")" || rc=$?
  case "$rc" in
    0) printf '%s' "$(printf '%s' "$names" | grep -c . || true)" ;;
    3) printf '%s' "?" ;;
    *) printf '%s' "-" ;;
  esac
}

# Chat-capable model names a server offers, one per line. Ollama: /api/tags.
# LM Studio: its native /api/v1 (or /api/v0) model list without embedding
# models, falling back to the OpenAI-compatible /v1/models.
# Exit status: 1 unreachable, 3 answered but not parseable.
server_models() {
  local url="$1" body path
  if [[ "$(server_kind "$url")" == ollama ]]; then
    body="$(server_curl "$url" /api/tags 2>/dev/null)" || return 1
  elif is_openai_kind "$(server_kind "$url")"; then
    body="$(server_curl "$url" /v1/models 2>/dev/null)" || return 1
  else
    for path in /api/v1/models /api/v0/models /v1/models; do
      body="$(server_curl "$url" "$path" 2>/dev/null)" && break
    done
    [[ -n "$body" ]] || return 1
  fi
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    entries = data.get("models") or data.get("data") or []
except Exception:
    sys.exit(3)
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if entry.get("type") in ("embedding", "embeddings"):
        continue
    name = entry.get("name") or entry.get("key") or entry.get("id") or ""
    if name:
        print(name)
'
}

model_present_on() {
  local url="$1" tag="$2" names
  names="$(server_models "$url")" || return 2
  [[ -n "$names" ]] || return 2
  printf '%s\n' "$names" | grep -Fxq "$tag" && return 0
  # Ollama treats a bare name as ":latest", so accept that spelling too.
  if [[ "$(server_kind "$url")" == ollama && "$tag" != *:* ]]; then
    printf '%s\n' "$names" | grep -Fxq "${tag}:latest" && return 0
  fi
  return 1
}

# The ollama tag configured for one specific (model_name, api_base) deployment.
# Deployments are per (tier, server), so each pair can carry its own model.
current_pair_tag() {
  local want_name="$1" want_base="$2"
  [[ -f "$LITELLM_YAML" ]] || return 0
  awk -v want="$want_name" -v base="$(litellm_api_base "$want_base")" '
    /^[[:space:]]*-[[:space:]]*model_name:/ {
      n = $0; sub(/.*model_name:[[:space:]]*/, "", n); sub(/[[:space:]]*$/, "", n)
      tag = ""; next
    }
    /^[[:space:]]*model:[[:space:]]*(ollama|lm_studio|openai)\// {
      tag = $0; sub(/.*model:[[:space:]]*(ollama|lm_studio|openai)\//, "", tag); sub(/[[:space:]]*(#.*)?$/, "", tag); next
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
    /^[[:space:]]*model:[[:space:]]*(ollama|lm_studio|openai)\// && n==want {
      t=$0; sub(/.*model:[[:space:]]*(ollama|lm_studio|openai)\//,"",t); sub(/[[:space:]]*(#.*)?$/,"",t); print t; exit
    }' "$LITELLM_YAML"
}

# --- rendering ----------------------------------------------------------------
tiers_of() {  # which tiers reference this URL
  local url="$1" tier out=""
  for tier in fast medium large xlarge; do
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
  for tier in fast medium large xlarge; do
    alias="$(tier_model_name "$tier")"
    any=false
    while IFS= read -r url || [[ -n "$url" ]]; do
      [[ -n "$url" ]] || continue
      any=true
      tag="$(current_pair_tag "$alias" "$url")"
      [[ -n "$tag" ]] || tag="$(current_tier_tag "$alias")"
      printf '  %-7s %-14s %-34s %s\n' "$tier" "$alias" "$url" "$(litellm_provider "$url")/${tag:-?}"
    done < <(get_tier "$tier")
    $any || printf '  %-7s %-14s %-34s %s\n' "$tier" "$alias" "<no servers>" "-"
  done
}

cmd_discover() {
  local body rc=0
  echo "Asking OSR to re-poll every configured host..."
  local key; key="$(env_get ROUTER_API_KEY)"
  if [[ -n "$key" ]]; then
    # Header read from a file descriptor, so the key never shows up in `ps`.
    body="$(curl -fsS -X POST -H @<(printf 'Authorization: Bearer %s\n' "$key") \
            "${ROUTER_URL}/routing/refresh" 2>/dev/null)" || rc=$?
  else
    body="$(curl -fsS -X POST "${ROUTER_URL}/routing/refresh" 2>/dev/null)" || rc=$?
  fi
  if (( rc != 0 )) || [[ -z "$body" ]]; then
    note "Could not reach OSR at ${ROUTER_URL} (curl exit ${rc})."
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
    print("  OSR replied, but the response did not parse: %s" % exc)
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
# Print a `  fallbacks:` block for router_settings. Input on stdin, one tier
# per line in size order: "<model_name> <signature>", where the signature is
# the sorted list of its deployments (tag@url). Each tier falls back to the
# nearest other tiers, smaller first on a tie. A tier whose deployments are
# IDENTICAL to this one's is skipped: falling back to the same model on the
# same host cannot succeed where the original failed.
litellm_fallbacks() {
  python3 -c '
import json, sys
tiers = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        name, _, sig = line.partition(" ")
        tiers.append((name, sig))
rows = []
for i, (name, sig) in enumerate(tiers):
    others = [(abs(i - j), j, other) for j, (other, osig) in enumerate(tiers)
              if other != name and osig != sig]
    if others:
        rows.append("    - %s: %s" % (name, json.dumps([o for _, _, o in sorted(others)])))
if rows:
    print("  fallbacks:")
    print("\n".join(rows))
'
}

regenerate_litellm() {
  local tmp tier name tag tier_tag url tail_block keep_alive fallbacks sig
  local -a sig_lines=()
  local kind key_env k
  local -A kind_has_token=()
  keep_alive="$(env_get OLLAMA_KEEP_ALIVE)"
  for k in $(server_kinds); do
    [[ -n "$(env_get "$(kind_field "$k" key)")" ]] && kind_has_token[$k]=1
  done
  $DRY_RUN && { echo "  [dry-run] would regenerate ${LITELLM_YAML}"; return 0; }
  [[ -f "$LITELLM_YAML" ]] || die "missing ${LITELLM_YAML}"
  tmp="$(mktemp)"
  {
    echo "model_list:"
    for tier in fast medium large xlarge; do
      name="$(tier_model_name "$tier")"
      tier_tag="${TIER_MODEL_OVERRIDE[$tier]:-}"
      [[ -n "$tier_tag" ]] || tier_tag="$(current_tier_tag "$name")"
      [[ -n "$tier_tag" ]] || tier_tag="$name"
      sig=""
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
        printf '      model: %s/%s\n' "$(litellm_provider "$url")" "$tag"
        printf '      api_base: %s\n' "$(litellm_api_base "$url")"
        kind="$(server_kind "$url")"
        if [[ "$kind" == ollama ]]; then
          [[ -n "$keep_alive" ]] && printf '      keep_alive: %s\n' "$keep_alive"
        else
          # Tokens come from secrets.env, which the LiteLLM unit loads.
          # keep_alive is an Ollama setting and is never sent elsewhere.
          key_env="$(kind_field "$kind" key)"
          if [[ -n "${kind_has_token[$kind]:-}" ]]; then
            printf '      api_key: os.environ/%s\n' "$key_env"
          elif is_openai_kind "$kind"; then
            # LiteLLM's openai provider needs some key even for a keyless server.
            printf '      api_key: none\n'
          fi
        fi
        sig+="${tag}@${url} "
      done < <(get_tier "$tier")
      if [[ -n "$sig" ]]; then
        sig_lines+=("${name} $(tr ' ' '\n' <<< "$sig" | sed '/^$/d' | sort | paste -sd, -)")
      fi
    done
    # router_settings: every hand-edited key (strategy, retries, ...) is kept,
    # but `fallbacks` is REGENERATED from the tiers that exist now. Carrying it
    # verbatim left fallbacks pointing at renamed or removed tiers.
    fallbacks="$( ((${#sig_lines[@]})) && printf '%s\n' "${sig_lines[@]}" | litellm_fallbacks)"
    tail_block="$(awk '/^router_settings:/{f=1} f' "$LITELLM_YAML")"
    [[ -n "$tail_block" ]] || tail_block=$'router_settings:\n  routing_strategy: latency-based-routing\n  num_retries: 2\n  timeout: 600'
    printf '%s\n' "$tail_block" | FALLBACKS="$fallbacks" awk '
      /^router_settings:/ { print; if (ENVIRON["FALLBACKS"] != "") print ENVIRON["FALLBACKS"]; next }
      skip && ($0 ~ /^   / || $0 ~ /^  -/) { next }
      { skip = 0 }
      /^  fallbacks:/ { skip = 1; next }
      { print }'
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
  local addr url current count tier kind
  (( ${#wanted[@]} > 0 )) || die "add: no address given"
  current="$(get_servers | lines_to_csv)"
  count="$(get_servers | grep -c . || true)"

  local -a to_add=()
  for addr in "${wanted[@]}"; do
    valid_addr "$addr" || die "not a valid address: '${addr}'"
    if ! url="$(resolve_server "$addr")"; then
      die "${addr} is not reachable as $(kind_labels). Use --type and/or --no-probe to add anyway."
    fi
    kind="$(server_kind "$url")"
    [[ "$kind" == ollama ]] || note "  ${addr}: $(kind_field "$kind" label) server -> ${url}"
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
        if [[ "$kind" != ollama ]]; then
          die "${url} did not list its models. Is the $(kind_field "$kind" label) server running? If it requires authentication, run set-${kind}-token first. Use --no-probe to add anyway."
        fi
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
    # Model names differ between Ollama and LM Studio (qwen3:14b vs
    # qwen/qwen3-14b), so the tier's tag is often wrong for a new LM Studio
    # server. Say so now rather than at the first failed request.
    local tag
    for url in "${to_add[@]}"; do
      [[ "$(server_kind "$url")" != ollama ]] || continue
      for tier in $(csv_to_lines "$TIER_ARG"); do
        tag="$(current_tier_tag "$(tier_model_name "$tier")")"
        [[ -n "$tag" ]] || continue
        if ! $NO_PROBE && ! model_present_on "$url" "$tag"; then
          note "  NOTE: ${url} has no model '${tag}' (tier ${tier}). Pick one it serves:"
          note "        $0 models"
          note "        $0 set-server-model ${tier} ${url} <model>"
        fi
      done
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
      target="$(configured_entry "$addr")"
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

  for tier in fast medium large xlarge; do
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
      url="$(configured_entry "$addr")"
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
    url="$(configured_entry "$arg")"
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
  # Namespace slashes belong to the model name; only the provider prefix is forbidden.
  [[ "$tag" != ollama/* ]] || die "give the Ollama tag only, without the 'ollama/' prefix"

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
  note "        served through OSR are kept resident by the monitor, which"
  note "        re-pins them through the native API. Restart it to pick this up."
  note "        LM Studio servers are not affected: LM Studio loads models on demand"
  note "        and unloads them on its own idle TTL (set that in LM Studio)."
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
    echo "  (none — no host listed its models)"
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
  echo "Set one for a tier with:  $0 set-model <fast|medium|large|xlarge> <model>"
}

cmd_set_model() {
  local tier="${1:-}" tag="${2:-}"
  local url current alias missing="" unreachable="" rc
  [[ -n "$tier" ]] || die "set-model: no tier given"
  tier_env_key "$tier" >/dev/null          # validates the tier name
  [[ -n "$tag" ]] || die "set-model: no model given (e.g. qwen3:32b)"
  # Namespace slashes belong to the model name; only the provider prefix is forbidden.
  [[ "$tag" != ollama/* ]] || die "give the Ollama tag only, without the 'ollama/' prefix"

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
  note "        discovery mode OSR picks a model from the live inventory,"
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

# --- LiteLLM venv ---------------------------------------------------------------
litellm_pinned_version() {
  [[ -f "$LITELLM_REQ" ]] || return 0
  sed -nE 's/^[[:space:]]*litellm(\[[^]]*\])?[[:space:]]*==[[:space:]]*([^[:space:];#]+).*/\2/p' \
    "$LITELLM_REQ" | head -n1
}

litellm_installed_version() {
  local py="${LITELLM_DIR}/venv/bin/python"
  [[ -x "$py" ]] || return 0
  "$py" -c 'import importlib.metadata as m
try: print(m.version("litellm"))
except Exception: pass' 2>/dev/null
}

# True when the venv has the pinned litellm AND the proxy extra's imports work.
# The import is the real test: a plain `litellm` install passes a version check
# but `litellm --config` then dies with "Missing dependency ... backoff".
litellm_venv_ok() {
  local want have
  want="$(litellm_pinned_version)"
  have="$(litellm_installed_version)"
  [[ -n "$have" ]] || return 1
  [[ -z "$want" || "$want" == "$have" ]] || return 1
  "${LITELLM_DIR}/venv/bin/python" -c 'import litellm.proxy.proxy_server' >/dev/null 2>&1
}

# Build (or bring up to date) LiteLLM's own venv, hash-checked when the repo
# carries requirements.lock.
litellm_install() {
  local pip="${LITELLM_DIR}/venv/bin/pip" rc=0
  # The service runs as ollama-router from this root-owned tree: build it world-
  # readable whatever the calling shell's umask (a 077/027 umask here produced
  # "Failed to execute .../litellm: Permission denied", status=203/EXEC).
  (
    umask 022
    if [[ ! -x "$pip" ]]; then
      mkdir -p "$LITELLM_DIR"
      python3 -m venv "${LITELLM_DIR}/venv" || { note "  could not create ${LITELLM_DIR}/venv"; exit 1; }
    fi
    if [[ -f "$LITELLM_LOCK" ]]; then
      "$pip" install --no-cache-dir --require-hashes -r "$LITELLM_LOCK"
    else
      note "  WARNING: no $(basename "$LITELLM_LOCK"); installing without hash checking."
      "$pip" install --no-cache-dir -r "$LITELLM_REQ"
    fi
  ) || rc=$?
  venv_make_readable "${LITELLM_DIR}/venv"
  return "$rc"
}

# Give everyone read (and traverse/execute where set) access to a venv, and let
# them traverse its parent. Venvs hold no secrets; the service accounts need this.
venv_make_readable() {
  local venv="$1"
  [[ -d "$venv" ]] || return 0
  chmod -R u+rwX,go+rX,go-w -- "$venv"
  chmod go+x -- "$(dirname -- "$venv")"
}

# The service account every unit runs as.
SERVICE_USER="${SERVICE_USER:-ollama-router}"

# Before restarting anything, make sure the service account can actually run
# each venv's interpreter; repair the permissions when a restrictive umask
# (on an earlier install, pip run or update) left them unreadable. Prints the
# venvs it fixed; returns 1 when one is still unusable.
repair_venv_access() {
  local venv bad=0
  getent passwd "$SERVICE_USER" >/dev/null 2>&1 || return 0
  command -v runuser >/dev/null 2>&1 || return 0
  for venv in "${LITELLM_DIR}/venv" "${ROUTER_DIR}/venv" "${OPENWEBUI_DIR}/venv"; do
    [[ -x "${venv}/bin/python" ]] || continue
    runuser -u "$SERVICE_USER" -- "${venv}/bin/python" -c 'import sys' >/dev/null 2>&1 && continue
    echo "  ${venv} is not usable by ${SERVICE_USER}; making it readable"
    venv_make_readable "$venv"
    if ! runuser -u "$SERVICE_USER" -- "${venv}/bin/python" -c 'import sys' >/dev/null 2>&1; then
      note "  WARNING: ${SERVICE_USER} still cannot run ${venv}/bin/python; check the permissions of its parent directories."
      bad=1
    fi
  done
  return "$bad"
}

# --- safe apply ---------------------------------------------------------------
# Validate every file apply-config.sh is about to install. Prints one line per
# problem; returns 1 if there was any. Nothing on the running system changes.
validate_config() {
  local py=python3
  # The YAML check needs PyYAML. Debian's python3 may lack it; LiteLLM's venv
  # always has it. (Without either, only a basic structural check runs.)
  if ! python3 -c 'import yaml' 2>/dev/null && [[ -x "${LITELLM_DIR}/venv/bin/python" ]]; then
    py="${LITELLM_DIR}/venv/bin/python"
  fi
  "$py" - "$REPO_DIR" <<'PYEOF'
import configparser, json, re, sys
from pathlib import Path

repo = Path(sys.argv[1])
errors = []
deployments = {}   # model_name -> {(model, api_base)}

def err(path, message):
    errors.append("%s: %s" % (path, message))

# env files: KEY=value lines only (systemd EnvironmentFile syntax).
for rel in ("env/router.env", "env/openwebui.env"):
    path = repo / rel
    if not path.is_file():
        err(rel, "missing")
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.strip() and not line.lstrip().startswith("#") \
                and not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", line):
            err(rel, "line %d is not KEY=value: %r" % (number, line[:60]))

# Python services must at least compile.
for rel in ("services/ollama-router/router.py", "services/ollama-monitor/monitor.py"):
    try:
        compile((repo / rel).read_text(), rel, "exec")
    except (OSError, SyntaxError) as exc:
        err(rel, "does not compile: %s" % exc)

# router.ini
rel = "services/ollama-router/router.ini"
cp = configparser.ConfigParser()
try:
    cp.read(repo / rel)
    for option in ("code", "large", "xlarge"):
        if cp.has_option("keywords", option):
            value = json.loads(cp.get("keywords", option))
            if not isinstance(value, list):
                err(rel, "[keywords] %s must be a JSON array" % option)
                continue
            for entry in value:
                if str(entry).startswith("re:"):
                    try:
                        re.compile(str(entry)[3:])
                    except re.error as exc:
                        err(rel, "[keywords] %s: bad regex %r (%s)" % (option, entry, exc))
    for option in ("xlarge", "large", "medium"):
        if cp.has_option("thresholds", option):
            int(cp.get("thresholds", option))
    for option in ("fast_params", "medium_params", "large_params", "xlarge_params"):
        if cp.has_option("discovery", option):
            low, high = cp.get("discovery", option).split(":", 1)
            if float(low) > float(high):
                err(rel, "[discovery] %s has low > high" % option)
except (configparser.Error, ValueError) as exc:
    err(rel, str(exc))

# monitor.ini
rel = "services/ollama-monitor/monitor.ini"
cp = configparser.ConfigParser()
try:
    cp.read(repo / rel)
    for section, option in (("polling", "interval_seconds"), ("alerting", "fail_threshold"),
                            ("alerting", "recover_threshold")):
        if cp.has_option(section, option):
            int(cp.get(section, option))
except (configparser.Error, ValueError) as exc:
    err(rel, str(exc))

# litellm_config.yaml
rel = "services/litellm-proxy/litellm_config.yaml"
try:
    import yaml
except ImportError:
    yaml = None
text = (repo / rel).read_text() if (repo / rel).is_file() else None
if text is None:
    err(rel, "missing")
elif yaml is None:
    if not re.search(r"^model_list:", text, re.M):
        err(rel, "no model_list (PyYAML unavailable; only a basic check was possible)")
else:
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        err(rel, "is not valid YAML: %s" % str(exc).splitlines()[0])
        doc = None
    if doc is not None:
        names = set()
        models = doc.get("model_list") if isinstance(doc, dict) else None
        if not isinstance(models, list) or not models:
            err(rel, "model_list must be a non-empty list")
            models = []
        for index, item in enumerate(models):
            params = (item or {}).get("litellm_params") or {}
            if not (item or {}).get("model_name") or not params.get("model") \
                    or not params.get("api_base"):
                err(rel, "model_list[%d] needs model_name, litellm_params.model and api_base" % index)
            else:
                names.add(item["model_name"])
                deployments.setdefault(item["model_name"], set()).add(
                    (params["model"], params["api_base"]))
        settings = (doc.get("router_settings") or {}) if isinstance(doc, dict) else {}
        for entry in settings.get("fallbacks") or []:
            if not isinstance(entry, dict) or len(entry) != 1:
                err(rel, "each fallbacks entry must be {tier: [tiers]}")
                continue
            (source, targets), = entry.items()
            for name in [source] + list(targets or []):
                if name not in names:
                    err(rel, "fallback names %r, which has no deployment" % name)

if not errors:
    seen = {}
    for name, deps in sorted(deployments.items()):
        key = frozenset(deps)
        if key in seen:
            print("  note: tiers %r and %r serve the same model on the same host(s); "
                  "one of them adds nothing (not an error)" % (seen[key], name))
        else:
            seen[key] = name

for line in errors:
    print("  " + line)
sys.exit(1 if errors else 0)
PYEOF
}

# runtime path -> repo source, and the services that read it.
apply_map() {
  cat <<EOF
services/ollama-router/router.py|${ROUTER_DIR}/router.py|ollama-router
services/ollama-router/router.ini|${ROUTER_DIR}/router.ini|ollama-router
services/ollama-monitor/monitor.py|${ROUTER_DIR}/monitor.py|ollama-monitor
services/ollama-monitor/monitor.ini|${ROUTER_DIR}/monitor.ini|ollama-monitor
services/litellm-proxy/litellm_config.yaml|${ROUTER_DIR}/litellm_config.yaml|litellm-proxy
env/router.env|${ROUTER_DIR}/.env|litellm-proxy ollama-router ollama-monitor
env/openwebui.env|${OPENWEBUI_DIR}/.env|open-webui
services/litellm-proxy/litellm-proxy.service|${UNIT_DIR}/litellm-proxy.service|litellm-proxy
services/ollama-router/ollama-router.service|${UNIT_DIR}/ollama-router.service|ollama-router
services/ollama-monitor/ollama-monitor.service|${UNIT_DIR}/ollama-monitor.service|ollama-monitor
services/open-webui/open-webui.service|${UNIT_DIR}/open-webui.service|open-webui
EOF
}

# Fingerprint of the secrets file, recorded after each successful apply, so a
# set-token / set-webhook / set-api-key since then restarts the services that
# load it.
secrets_fingerprint() {
  if [[ -f "$SECRETS_FILE" ]]; then sha256sum < "$SECRETS_FILE" | cut -d' ' -f1; else echo none; fi
}

# Services that must restart for the pending apply, in SERVICES order: any
# whose files differ from what is installed, any that is not running, and the
# secret-loading ones when secrets.env changed. Run BEFORE apply-config.sh.
affected_services() {
  local src dest svcs svc
  local -A want=()
  if $APPLY_ALL; then printf '%s\n' "${SERVICES[@]}"; return 0; fi
  while IFS='|' read -r src dest svcs; do
    [[ -f "${REPO_DIR}/${src}" ]] || continue
    if ! cmp -s "${REPO_DIR}/${src}" "$dest"; then
      for svc in $svcs; do want[$svc]=1; done
    fi
  done < <(apply_map)
  if [[ "$(secrets_fingerprint)" != "$(cat "${ROUTER_DIR}/.secrets.applied" 2>/dev/null)" ]]; then
    want[ollama-router]=1; want[ollama-monitor]=1; want[open-webui]=1
  fi
  for svc in "${SERVICES[@]}"; do
    systemctl is-active --quiet "${svc}.service" 2>/dev/null || want[$svc]=1
  done
  for svc in "${SERVICES[@]}"; do
    [[ -n "${want[$svc]:-}" ]] && printf '%s\n' "$svc"
  done
  return 0
}

# Copy every runtime file apply-config.sh may overwrite into a new timestamped
# snapshot directory; print its path. Old snapshots beyond APPLY_BACKUP_KEEP
# are pruned.
snapshot_runtime() {
  local dir src dest svcs
  dir="${APPLY_BACKUP_DIR}/$(date +%Y%m%dT%H%M%S)-$$"
  mkdir -p "$dir" && chmod 0700 "$APPLY_BACKUP_DIR" "$dir"
  : > "${dir}/MANIFEST"
  while IFS='|' read -r src dest svcs; do
    [[ -f "$dest" ]] || continue
    mkdir -p "${dir}/files$(dirname "$dest")"
    cp -p "$dest" "${dir}/files${dest}"
    printf '%s\n' "$dest" >> "${dir}/MANIFEST"
  done < <(apply_map)
  # shellcheck disable=SC2012  # names are our own timestamps
  ls -1d "${APPLY_BACKUP_DIR}"/*/ 2>/dev/null | sort | head -n "-${APPLY_BACKUP_KEEP}" |
    while IFS= read -r old; do rm -rf -- "$old"; done
  printf '%s\n' "$dir"
}

# Put back every file recorded in a snapshot.
restore_runtime() {
  local dir="$1" dest
  [[ -f "${dir}/MANIFEST" ]] || { note "  snapshot ${dir} has no MANIFEST"; return 1; }
  while IFS= read -r dest; do
    [[ -n "$dest" ]] && cp -p "${dir}/files${dest}" "$dest"
  done < "${dir}/MANIFEST"
}

# The URL a service answers health checks on (empty: use systemd state only).
health_url() {
  local port
  case "$1" in
    litellm-proxy) printf '%s\n' "$LITELLM_HEALTH_URL" ;;
    ollama-router) printf '%s/healthz\n' "$ROUTER_URL" ;;
    open-webui)
      port="$(kv_get "${REPO_DIR}/env/openwebui.env" PORT)"
      printf 'http://127.0.0.1:%s/health\n' "${port:-8080}" ;;
    *) printf '\n' ;;
  esac
}

# Wait until a restarted service is active AND answers its health URL. A unit
# that systemd reports as failed is given up on at once. Returns 1 on timeout.
wait_healthy() {
  local svc="$1" limit="${2:-$HEALTH_TIMEOUT}" url waited=0 state
  url="$(health_url "$svc")"
  while (( waited < limit )); do
    state="$(systemctl is-active "${svc}.service" 2>/dev/null || true)"
    if [[ "$state" == failed ]]; then
      return 1
    fi
    if [[ "$state" == active ]]; then
      if [[ -z "$url" ]]; then
        # No HTTP health endpoint: require it to stay up for a few seconds.
        sleep 3
        systemctl is-active --quiet "${svc}.service" 2>/dev/null && return 0
        return 1
      fi
      curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null && return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# Restart the given services in order and health-check each. Prints the name
# of the first that fails and returns 1.
restart_and_check() {
  local svc limit
  for svc in "$@"; do
    systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || continue
    if ! systemctl restart "${svc}.service" >/dev/null 2>&1; then
      printf '%s\n' "$svc"; return 1
    fi
    limit="$HEALTH_TIMEOUT"
    [[ "$svc" == open-webui ]] && limit="$OPENWEBUI_HEALTH_TIMEOUT"
    if wait_healthy "$svc" "$limit"; then
      echo "  restarted ${svc}: healthy" >&2
    else
      printf '%s\n' "$svc"; return 1
    fi
  done
}

# Open WebUI's data directory (its SQLite database lives there).
openwebui_data_dir() {
  local dir
  dir="$(kv_get "${REPO_DIR}/env/openwebui.env" DATA_DIR)"
  printf '%s\n' "${dir:-${OPENWEBUI_DIR}/data}"
}

# An Open WebUI upgrade migrates webui.db in place and cannot be undone by
# reinstalling the old version alone, so the database is copied into the apply
# snapshot first. (Uploads and the vector store are not copied: they are large
# and not rewritten by schema migrations.)
openwebui_backup_db() {
  local snap="$1" data f
  data="$(openwebui_data_dir)"
  mkdir -p "${snap}/openwebui-data"
  for f in "${data}"/webui.db "${data}"/webui.db-wal "${data}"/webui.db-shm; do
    [[ -f "$f" ]] && cp -p "$f" "${snap}/openwebui-data/"
  done
  return 0
}

openwebui_restore_db() {
  local snap="$1" data f
  data="$(openwebui_data_dir)"
  [[ -d "${snap}/openwebui-data" ]] || return 0
  rm -f "${data}/webui.db-wal" "${data}/webui.db-shm"
  for f in "${snap}"/openwebui-data/*; do
    [[ -f "$f" ]] && cp -p "$f" "${data}/"
  done
  return 0
}

cmd_apply() {
  local svc snapshot failed webui_from=""
  local -a affected=()
  if $DRY_RUN; then echo "  [dry-run] would apply config and restart services"; return 0; fi
  # Checked with -f, not -x: seeding through the Gitea contents API does not
  # preserve the executable bit, and we invoke it via `bash` anyway.
  [[ -f "$APPLY_SCRIPT" ]] || die "apply script not found: ${APPLY_SCRIPT}"
  migrate_secrets

  echo "Validating configuration..."
  if ! validate_config; then
    note "Configuration is invalid; nothing was applied or restarted."
    return 1
  fi

  mapfile -t affected < <(affected_services)
  snapshot="$(snapshot_runtime)"
  echo "Applying configuration (previous files saved in ${snapshot})..."
  bash "$APPLY_SCRIPT" "$REPO_DIR"

  # Older deployments ran LiteLLM from the router's venv without the [proxy]
  # extra, which crash-loops. Build its own venv before the unit is restarted.
  if ! litellm_venv_ok; then
    echo "LiteLLM venv missing or out of date; installing into ${LITELLM_DIR}/venv..."
    if litellm_install && litellm_venv_ok; then
      echo "  installed litellm $(litellm_installed_version)"
      affected+=(litellm-proxy)
    else
      note "  WARNING: LiteLLM install failed; litellm-proxy will not start."
    fi
  fi

  # If the pinned Open WebUI version no longer matches what is installed,
  # bring the venv in line before restarting the unit.
  local want_v have_v
  want_v="$(openwebui_current_version)"
  have_v="$(openwebui_installed_version)"
  if [[ -n "$want_v" && "$want_v" != "$have_v" ]]; then
    echo "Open WebUI ${have_v:-<none>} -> ${want_v}; installing (this takes a while)..."
    openwebui_backup_db "$snapshot"
    # umask 022: the UI runs as the service account from this root-owned venv.
    if ( umask 022; openwebui_install ); then
      echo "  installed open-webui ${want_v} (database backed up in ${snapshot})"
      webui_from="$have_v"
      affected+=(open-webui)
    else
      note "  WARNING: install failed; the service keeps running ${have_v:-its current version}."
    fi
  fi
  # A venv the service account cannot read fails at exec (status=203/EXEC).
  repair_venv_access || true
  # De-duplicate, keeping SERVICES order.
  mapfile -t affected < <(for svc in "${SERVICES[@]}"; do
    printf '%s\n' "${affected[@]}" | grep -qx -- "$svc" && echo "$svc"; done)

  # Files are already in place at this point. If systemd isn't running (a
  # chroot, a container without PID 1, a rescue shell), say so plainly rather
  # than dying with "Failed to connect to bus" after a partial job.
  if ! systemctl daemon-reload 2>/dev/null; then
    note "WARNING: systemd is not available here — configuration was copied into"
    note "         place, but no service was restarted. Restart them manually:"
    note "           systemctl restart ${SERVICES[*]}"
    return 0
  fi
  if (( ${#affected[@]} == 0 )); then
    echo "No service is affected by this change; nothing restarted."
    secrets_fingerprint > "${ROUTER_DIR}/.secrets.applied"
    return 0
  fi
  echo "Restarting: ${affected[*]}"
  if failed="$(restart_and_check "${affected[@]}")"; then
    secrets_fingerprint > "${ROUTER_DIR}/.secrets.applied"
    echo "Applied; all restarted services are healthy."
    return 0
  fi

  note "ERROR: ${failed} did not become healthy. Rolling back to the previous files..."
  note "  (see: journalctl -u ${failed} -n 50)"
  restore_runtime "$snapshot"
  if [[ -n "$webui_from" ]]; then
    note "  Reinstalling open-webui ${webui_from} and restoring its database..."
    systemctl stop open-webui.service 2>/dev/null || true
    ( umask 022; "${OPENWEBUI_DIR}/venv/bin/pip" install --no-cache-dir "open-webui==${webui_from}" ) >/dev/null 2>&1 || \
      note "  WARNING: reinstalling open-webui ${webui_from} failed."
    openwebui_restore_db "$snapshot"
  fi
  systemctl daemon-reload 2>/dev/null || true
  if restart_and_check "${affected[@]}" >/dev/null; then
    note "Rolled back; the previous configuration is running again."
  else
    note "Rolled back the files, but a service is still unhealthy — check it by hand."
  fi
  note "  The LiteLLM venv is not rolled back. The repo still holds the new config;"
  note "  fix it (or git revert) and run apply again."
  return 1
}

# Push using the Gitea deploy token from the secrets file.
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
    note "  No GITEA_DEPLOY_TOKEN in ${SECRETS_FILE}."
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

# Post a message through the configured webhook, exactly as monitor.py does,
# and report precisely why it failed. Without this there is no way to tell a
# missing URL from a TLS failure from a rejected channel override -- all three
# just look like "alerts do not arrive".
cmd_test_alert() {
  local message="${1:-}" url channel user verify host
  url="$(env_get MATTERMOST_WEBHOOK_URL)"
  channel="$(env_get MATTERMOST_CHANNEL)"
  user="$(env_get MATTERMOST_MONITOR_USER)"; [[ -n "$user" ]] || user="OllamaMonitor"
  verify="$(env_get MATTERMOST_VERIFY_TLS)"
  [[ -n "$message" ]] || message="Test alert from $(hostname) via ${0##*/} — if you can read this, monitor alerting works."

  if [[ -z "$url" ]]; then
    echo "MATTERMOST_WEBHOOK_URL is not set in ${SECRETS_FILE}."
    echo "The monitor logs alerts instead of posting them. Set one with:"
    echo "  $0 set-webhook <url>"
    return 1
  fi

  host="${url#*://}"; host="${host%%/*}"
  echo "Webhook host : ${host}"
  echo "Channel      : ${channel:-<webhook default>}"
  echo "Post as      : ${user}"
  echo "Verify TLS   : ${verify:-true}"
  echo

  local -a copts=(-sS -o /dev/null)
  [[ "$verify" == "false" ]] && copts+=(--insecure)

  _mm_post() {  # $1 = json payload -> prints "<http_code> <curl_rc>"
    local body="$1" code rc=0
    code="$(curl "${copts[@]}" -w '%{http_code}' -X POST \
            -H 'Content-Type: application/json' --data "$body" "$url" 2>/dev/null)" || rc=$?
    printf '%s %s' "${code:-000}" "$rc"
  }
  _mm_payload() {  # $1 = include the channel override? true/false
    python3 -c '
import json, sys
payload = {"username": sys.argv[1], "icon_emoji": ":white_check_mark:", "text": sys.argv[2]}
if sys.argv[3] == "true" and sys.argv[4]:
    payload["channel"] = sys.argv[4]
print(json.dumps(payload))' "$user" "$message" "$1" "$channel"
  }

  local result code rc
  result="$(_mm_post "$(_mm_payload true)")"
  code="${result%% *}"; rc="${result##* }"

  if [[ "$code" =~ ^2 ]]; then
    # NOTE: no apostrophe inside a ${var:-default}. Bash re-parses the default,
    # so a lone quote there opens a quote context and breaks the rest of the file.
    local where="the channel the webhook is bound to"
    [[ -n "$channel" ]] && where="#${channel}"
    echo "Delivered (HTTP ${code}). Check ${where} in Mattermost."
    return 0
  fi

  # Transport-level failure: curl never got an HTTP response.
  if [[ "$code" == "000" ]]; then
    echo "Could not reach the webhook (curl exit ${rc})."
    case "$rc" in
      6)  echo "  DNS: '${host}' does not resolve from inside this container." ;;
      7)  echo "  Connection refused — check the host, port and any firewall." ;;
      28) echo "  Timed out." ;;
      35|60)
          echo "  TLS failure. If Mattermost uses a self-signed or internal CA"
          echo "  certificate, turn verification off:"
          echo "    $0 set-webhook --verify-tls false" ;;
      *)  echo "  curl exit ${rc}." ;;
    esac
    return 1
  fi

  echo "Mattermost rejected the message (HTTP ${code})."

  # A 4xx WITH a channel override is very often the override itself: a webhook
  # is bound to one channel and many servers refuse to redirect it. Re-test
  # without the override so the report says which of the two is at fault.
  if [[ -n "$channel" && "$code" =~ ^4 ]]; then
    echo "Retrying without the channel override ..."
    result="$(_mm_post "$(_mm_payload false)")"
    if [[ "${result%% *}" =~ ^2 ]]; then
      echo
      echo "That worked. The webhook is fine; Mattermost is refusing to redirect"
      echo "it to '${channel}'. Either clear the override:"
      echo "    $0 set-webhook --channel ''"
      echo "  or allow channel overrides for this webhook in the System Console"
      echo "  (Integrations -> Incoming Webhooks), and confirm '${channel}' is the"
      echo "  channel's URL handle rather than its display name."
      return 1
    fi
    echo "  Still rejected (HTTP ${result%% *}) — the webhook URL itself is the problem."
  fi

  case "$code" in
    400) echo "  400 usually means a malformed payload or an unknown channel." ;;
    401|403) echo "  The webhook is not authorised to post there. Re-check it in"
             echo "  Integrations -> Incoming Webhooks." ;;
    404) echo "  404 means the webhook URL is wrong or has been deleted." ;;
  esac
  return 1
}

# Set the Mattermost webhook and its options without hand-editing router.env.
cmd_set_webhook() {
  local url="" set_url=false
  while (( $# )); do
    case "$1" in
      --channel)    env_set MATTERMOST_CHANNEL "${2-}"; CHANGED=true; shift 2 ;;
      --username)   env_set MATTERMOST_MONITOR_USER "${2:?--username needs a value}"; CHANGED=true; shift 2 ;;
      --verify-tls)
        [[ "${2-}" == "true" || "${2-}" == "false" ]] \
          || die "set-webhook: --verify-tls takes 'true' or 'false'"
        env_set MATTERMOST_VERIFY_TLS "$2"; CHANGED=true; shift 2 ;;
      -*) die "set-webhook: unknown option '$1'" ;;
      *)  url="$1"; set_url=true; shift ;;
    esac
  done

  if $set_url; then
    # An empty URL is meaningful: it disables posting and the monitor logs
    # alerts instead, which is the documented way to turn alerting off.
    if [[ -n "$url" ]]; then
      [[ "$url" =~ ^https?://[^[:space:]]+$ ]] \
        || die "set-webhook: '${url}' is not an http(s) URL"
    fi
    env_set MATTERMOST_WEBHOOK_URL "$url"
    CHANGED=true
    if [[ -n "$url" ]]; then
      echo "Webhook stored in ${SECRETS_FILE}."
    else
      echo "Webhook cleared — the monitor will log alerts instead of posting."
    fi
  fi

  $CHANGED || { echo "Nothing to change. See: $0 --help"; return 0; }
  echo
  echo "  webhook   : $(env_get MATTERMOST_WEBHOOK_URL | sed -E 's#(://[^/]+/).*#\1<redacted>#')"
  echo "  channel   : $(env_get MATTERMOST_CHANNEL)"
  echo "  username  : $(env_get MATTERMOST_MONITOR_USER)"
  echo "  verify tls: $(env_get MATTERMOST_VERIFY_TLS)"
  note "Run '$0 apply' to restart the monitor, then '$0 test-alert'."
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
  echo "Stored the deploy token in ${SECRETS_FILE}."
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

# OSR API key. Stored twice in the secrets file: ROUTER_API_KEY for OSR,
# OPENAI_API_KEYS for Open WebUI, which authenticates to OSR as
# an OpenAI connection. Both units load secrets.env.
cmd_set_api_key() {
  local key="${1:-}"
  case "$key" in
    --off)
      env_set ROUTER_API_KEY ""
      env_set OPENAI_API_KEYS ""
      echo "OSR API key cleared: the API is open to anyone who can reach it."
      CHANGED=true
      return 0 ;;
    --generate|"")
      key="sk-router-$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')" ;;
  esac
  [[ "$key" =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] || \
    die "set-api-key: use at least 16 characters from A-Z a-z 0-9 . _ ~ + / = -"
  env_set ROUTER_API_KEY "$key"
  env_set OPENAI_API_KEYS "$key"
  echo "Stored the OSR API key in ${SECRETS_FILE}."
  $DRY_RUN || echo "  key: ${key}"
  note "  Clients must send:  Authorization: Bearer <key>"
  note "  Open WebUI reads OPENAI_API_KEYS only on its FIRST start; on an existing"
  note "  install also paste the key into Admin Settings > Connections > OpenAI."
  note "  Run '$0 apply' to restart the services with the key."
  CHANGED=true
}

# Bearer token for one server kind (set-lmstudio-token, set-maya-token, ...):
# LM Studio servers with "Require authentication" on, or Strata, Basalt, Maya
# and Xolotl servers started with an API key. One token per kind, stored in
# secrets.env (outside the repo) like the other secrets.
cmd_set_kind_token() {
  local kind="$1" token="${2:-}" confirm_token="" key_env name noun cmd
  is_server_kind "$kind" || die "unknown server kind '${kind}'"
  key_env="$(kind_field "$kind" key)"
  name="$(kind_secret_name "$kind")"
  noun="${name##* }"                     # token / key
  cmd="set-${kind}-token"
  if [[ "$token" == --off ]]; then
    env_set "$key_env" ""
    echo "${name} cleared."
    regenerate_litellm
    CHANGED=true
    return 0
  fi
  if [[ -z "$token" ]]; then
    [[ "$ASSUME_YES" == "true" ]] && die "${cmd}: no ${noun} given"
    read -r -s -p "$(kind_field "$kind" label) API ${noun}: " token; echo
    read -r -s -p "Confirm ${noun}: " confirm_token; echo
    [[ "$token" == "$confirm_token" ]] || die "${noun}s did not match"
  fi
  [[ -n "$token" ]] || die "${cmd}: empty ${noun}"
  [[ "$token" =~ ^[A-Za-z0-9._~+/=:-]+$ ]] || die "${cmd}: unexpected characters in ${noun}"
  env_set "$key_env" "$token"
  echo "Stored the ${name} in ${SECRETS_FILE}."
  regenerate_litellm
  CHANGED=true
}

# The kind a set-<kind>-token command names, or nothing.
token_command_kind() {
  local kind="${1#set-}"; kind="${kind%-token}"
  [[ "$1" == "set-${kind}-token" ]] && is_server_kind "$kind" && printf '%s\n' "$kind"
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
  migrate_secrets
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
    # Only a caller that asked for it (update-router.sh) treats this as failure.
    if [[ "${REQUIRE_PUSH:-false}" == true ]]; then return 1; fi
  fi
  return 0
}

# Commands that write config, secrets or runtime files take the config lock;
# read-only ones (list, status, models, discover, test-alert) never wait on it.
command_writes() {
  case "$1" in
    add|remove|set-tier|set-model|set-server-model|set-keepalive|apply|commit|\
    set-token|set-api-key|set-webhook|set-webui-version) return 0 ;;
    *) [[ -n "$(token_command_kind "$1")" ]] ;;
  esac
}

lock_path() { readlink -f -- "$CONFIG_LOCK_FILE" 2>/dev/null || printf '%s\n' "$CONFIG_LOCK_FILE"; }

# True when nobody holds the lock (probed through a separate open of the file,
# so it also sees a lock held by this process's parent).
lock_is_free() {
  [[ -e "$CONFIG_LOCK_FILE" ]] || return 0
  ( flock -n 9 ) 9>>"$CONFIG_LOCK_FILE" 2>/dev/null
}

# True when a parent (install/update-router.sh) holds the lock and handed this
# process the descriptor: CONFIG_LOCK_INHERITED_FD must be an open descriptor on
# the lock file AND the lock must really be taken.
lock_inherited() {
  local fd="${CONFIG_LOCK_INHERITED_FD:-}"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  [[ "$(readlink -f "/proc/self/fd/${fd}" 2>/dev/null)" == "$(lock_path)" ]] || return 1
  ! lock_is_free
}

# PIDs of processes with the lock file open (holders and children that
# inherited the descriptor), excluding this shell.
lock_holders() {
  local target link pid
  target="$(lock_path)"
  for link in /proc/[0-9]*/fd/*; do
    [[ "$(readlink "$link" 2>/dev/null)" == "$target" ]] || continue
    pid="${link#/proc/}"; pid="${pid%%/*}"
    [[ "$pid" == "$$" || "$pid" == "${BASHPID:-}" ]] && continue
    printf '%s\n' "$pid"
  done | sort -un
}

acquire_config_lock() {
  local -a wait=(-n)
  command -v flock >/dev/null 2>&1 || die "flock is required to serialize config changes"
  [[ "$CONFIG_LOCK_WAIT" =~ ^[0-9]+$ ]] || die "CONFIG_LOCK_WAIT must be a number of seconds"
  (( CONFIG_LOCK_WAIT > 0 )) && wait=(-w "$CONFIG_LOCK_WAIT")
  exec {CONFIG_LOCK_FD}>>"$CONFIG_LOCK_FILE" || die "cannot open config lock: ${CONFIG_LOCK_FILE}"
  if ! flock "${wait[@]}" "$CONFIG_LOCK_FD"; then
    # Close ours first, or this process and its subshells list themselves.
    exec {CONFIG_LOCK_FD}>&-
    note "Another config change is running (lock: ${CONFIG_LOCK_FILE}), held by PID(s): $(lock_holders | tr '\n' ' ')"
    note "Wait for it (or set CONFIG_LOCK_WAIT=<seconds>). If it is hung: $0 clear-lock"
    exit 1
  fi
}

cmd_clear_lock() {
  local pid waited
  local -a pids=()
  if [[ ! -e "$CONFIG_LOCK_FILE" ]]; then
    echo "No lock file at ${CONFIG_LOCK_FILE}; nothing to clear."
    return 0
  fi
  if lock_is_free; then
    # The file is kept on purpose: deleting it while another process has it
    # open would let two changes lock two different files at once.
    echo "The config lock is not held; nothing to clear. ${CONFIG_LOCK_FILE} is only"
    echo "a placeholder: the lock dies with the process that holds it, so a crash"
    echo "or reboot never leaves it in force."
    return 0
  fi
  mapfile -t pids < <(lock_holders)
  note "The config lock (${CONFIG_LOCK_FILE}) is held by:"
  for pid in "${pids[@]}"; do
    note "  $(ps -o pid=,etime=,args= -p "$pid" 2>/dev/null || echo "$pid (exited)")"
  done
  (( ${#pids[@]} > 0 )) || die "no holding process is visible here (another container sharing the file?); not touching it."
  if ! $FORCE; then
    note "A change is in progress. If it is hung, stop it with: $0 clear-lock --force"
    return 1
  fi
  note "Stopping a change midway can leave the config repo or services half-updated."
  confirm "Stop these process(es)?" || die "cancelled; the lock is still held."
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for (( waited = 0; waited < LOCK_KILL_WAIT * 5; waited++ )); do
    lock_is_free && break
    sleep 0.2
  done
  if ! lock_is_free; then
    note "Still held after ${LOCK_KILL_WAIT}s; sending SIGKILL."
    mapfile -t pids < <(lock_holders)
    (( ${#pids[@]} == 0 )) || kill -KILL "${pids[@]}" 2>/dev/null || true
    for (( waited = 0; waited < 25; waited++ )); do
      lock_is_free && break
      sleep 0.2
    done
  fi
  lock_is_free || die "the lock is still held; check: ps -p $(lock_holders | tr '\n' ' ')"
  echo "Lock cleared. Check the config repo (git -C ${REPO_DIR} status) and run"
  echo "'$0 apply' so the running services match it."
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
    die "config not found at ${ENV_FILE}. Run this inside the OSR container, or set CONFIG_REPO_DIR."
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
  echo "This tool edits configuration that lives INSIDE the OSR container," >&2
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
    echo "If the OSR container is one of these, run:" >&2
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
    --force)
      [[ "$COMMAND" == "clear-lock" ]] || die "unknown option: $1"
      FORCE=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    # set-webhook's own flags. They are passed through rather than handled
    # here, because they take a value that may legitimately be EMPTY
    # (--channel '' clears the override) and only that command understands them.
    --channel|--username|--verify-tls)
      [[ "$COMMAND" == "set-webhook" ]] || die "unknown option: $1"
      (( $# >= 2 )) || die "$1 needs a value"
      ARGS+=("$1" "$2"); shift 2 ;;
    --generate|--off)
      [[ "$COMMAND" == "set-api-key" || -n "$(token_command_kind "$COMMAND")" ]] || die "unknown option: $1"
      ARGS+=("$1"); shift ;;
    --all)       APPLY_ALL=true; shift ;;
    --type)      SERVER_TYPE="${2:-}"; shift 2 ;;
    --type=*)    SERVER_TYPE="${1#*=}"; shift ;;
    --*)         die "unknown option: $1" ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done

for tier in $(csv_to_lines "${TIER_ARG:-}"); do
  tier_env_key "$tier" >/dev/null
done
if [[ "$SERVER_TYPE" != auto && "$SERVER_TYPE" != ollama ]] && ! is_server_kind "$SERVER_TYPE"; then
  die "--type must be ollama, $(server_kinds | paste -sd, - | sed 's/,/, /g') or auto (got '${SERVER_TYPE}')"
fi

ensure_config_or_forward
if command_writes "$COMMAND" && ! $DRY_RUN && ! lock_inherited; then
  acquire_config_lock
fi
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
  set-api-key) cmd_set_api_key "${ARGS[0]:-}" ;;
  set-*-token)
    token_kind="$(token_command_kind "$COMMAND")"
    [[ -n "$token_kind" ]] || die "unknown command '${COMMAND}' (try --help)"
    cmd_set_kind_token "$token_kind" "${ARGS[0]:-}" ;;
  test-alert) cmd_test_alert "${ARGS[0]:-}" ;;
  set-webhook) cmd_set_webhook ${ARGS[@]+"${ARGS[@]}"} ;;
  set-webui-version) cmd_set_webui_version "${ARGS[0]:-}" ;;
  clear-lock) cmd_clear_lock ;;
  *)        die "unknown command '${COMMAND}' (try --help)" ;;
esac

case "$COMMAND" in
  add|remove|set-tier|set-model|set-server-model|set-keepalive|set-webui-version|set-webhook)
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
  set-api-key|set-*-token)
    if $CHANGED && $AUTO_APPLY && ! $DRY_RUN; then cmd_apply; fi
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

* `services/ollama-router` and `ollama-monitor` share one venv
  (`/app/router/venv`). `litellm-proxy` has its own (`/app/litellm/venv`),
  installed from `requirements.lock` with hash checking when present.
* `services/open-webui` has its own venv on Python 3.12 — every open-webui
  release requires `>=3.11,<3.13`, and Debian 13 ships 3.13.
* `router.ini` holds the complexity-routing thresholds and keyword lists, so
  routing behaviour can change without editing `router.py`.
RDEOF

# --- systemd units (one per service directory) ---
cat > "${REPO_DIR}/services/ollama-router/ollama-router.service" <<'UNITEOF'
[Unit]
Description=Ollama Smart Router Middleware
# LiteLLM is the *fallback* dispatch path, not a hard requirement: the router
# serves traffic from its own live discovery inventory and only forwards to
# LiteLLM when discovery is off or the inventory is empty. Wants= keeps the
# start ordering (After= still holds LiteLLM first) without the binding, so a
# crash-looping litellm-proxy degrades routing to discovery-only. With
# Requires=, every LiteLLM restart propagated a stop up through this unit to
# open-webui, and the UI never stayed up long enough to bind :8080.
After=network-online.target litellm-proxy.service
Wants=network-online.target litellm-proxy.service
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/router
EnvironmentFile=/app/router/.env
# ROUTER_API_KEY (optional bearer token for the API) lives outside the repo.
EnvironmentFile=-/app/router/secrets.env
ExecStart=/app/router/venv/bin/python router.py
Restart=always
RestartSec=3
# --- sandboxing (same model as the llama.cpp target units) ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
# Writes nothing; bytecode caching is turned off instead of granting a path.
Environment=PYTHONDONTWRITEBYTECODE=1
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0027
[Install]
WantedBy=multi-user.target
UNITEOF

cat > "${REPO_DIR}/services/litellm-proxy/litellm-proxy.service" <<'UNITEOF'
[Unit]
Description=LiteLLM Load Balancing Proxy
After=network-online.target
Wants=network-online.target
[Service]
# LiteLLM has its own venv: litellm[proxy] pins fastapi/uvicorn versions that
# conflict with the router's, so the two cannot share /app/router/venv.
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/router
EnvironmentFile=/app/router/.env
# Model server API keys live outside the repo; litellm_config.yaml refers to
# their environment variables when authentication is configured.
EnvironmentFile=-/app/router/secrets.env
ExecStart=/app/litellm/venv/bin/litellm --config litellm_config.yaml --port 4000 --host 127.0.0.1
Restart=always
RestartSec=5
# --- sandboxing (same model as the llama.cpp target units) ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
# Needs no writable path: verified serving with a read-only install tree and
# an unwritable HOME (litellm[proxy] 1.75.5.post1, no database configured).
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0027
[Install]
WantedBy=multi-user.target
UNITEOF

cat > "${REPO_DIR}/services/ollama-monitor/ollama-monitor.service" <<'UNITEOF'
[Unit]
Description=Ollama Cluster Resilience Health Monitor
# The monitor polls the Ollama hosts directly and posts to Mattermost; it never
# talks to LiteLLM, so a hard dependency only made it collateral damage of a
# LiteLLM failure. Start ordering is kept, the binding is not.
After=network-online.target litellm-proxy.service
Wants=network-online.target litellm-proxy.service
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/router
EnvironmentFile=/app/router/.env
# Secrets (MATTERMOST_WEBHOOK_URL) live outside the config repo. The leading
# '-' keeps the unit starting when the file does not exist yet.
EnvironmentFile=-/app/router/secrets.env
ExecStart=/app/router/venv/bin/python monitor.py
Restart=always
RestartSec=10
# --- sandboxing (same model as the llama.cpp target units) ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
# /var/lib/ollama-monitor holds the startup-notice timestamp.
StateDirectory=ollama-monitor
Environment=MONITOR_STATE_DIR=/var/lib/ollama-monitor
Environment=PYTHONDONTWRITEBYTECODE=1
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0027
[Install]
WantedBy=multi-user.target
UNITEOF

cat > "${REPO_DIR}/services/open-webui/open-webui.service" <<'UNITEOF'
[Unit]
Description=Open WebUI (chat frontend for the smart router)
# This Requires= is deliberate and stays: the router is the UI's only backend,
# so Open WebUI has nothing to serve without it. Contrast the router and monitor
# units, which only Want= litellm-proxy.
After=network-online.target ollama-router.service
Wants=network-online.target
Requires=ollama-router.service
[Service]
Type=simple
User=ollama-router
Group=ollama-router
WorkingDirectory=/app/openwebui
EnvironmentFile=/app/openwebui/.env
# OPENAI_API_KEYS (the router API key) lives outside the repo and overrides
# the placeholder in .env. Open WebUI reads it on first start only; see
# `manage-model-servers set-api-key`.
EnvironmentFile=-/app/router/secrets.env
ExecStart=/app/openwebui/venv/bin/open-webui serve
Restart=always
RestartSec=5
# First start downloads a local embedding model; give it room before timeout.
TimeoutStartSec=600
# --- sandboxing (same model as the llama.cpp target units) ---
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
# DATA_DIR (the SQLite database, uploads) and the model cache.
ReadWritePaths=/app/openwebui
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
UMask=0027
[Install]
WantedBy=multi-user.target
UNITEOF

if [[ "$CONFIG_SOURCE" == "repo" ]]; then
  echo "Seeding the Gitea config repository (missing files; installer-owned code is updated)."
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

echo "Installing secrets outside the config repo."
pct push "$CT_ID" "$SECRETS_STAGE" /app/router/secrets.env --perms 0640
run_ct chown root:ollama-router /app/router/secrets.env

rm -rf "$STAGE_DIR"; STAGE_DIR=""
unset GITEA_DEPLOY_TOKEN_KEEP

echo "Installing Python dependencies (from the repo's requirements files)."
# The config tree above was built under `umask 077` (it holds secrets), and
# `pct exec` hands the caller's umask to the container. Venvs built under it
# are unreadable by the ollama-router service account: LiteLLM, which is not
# chowned below, then fails with status=203/EXEC "Permission denied".
umask 022
# The router and monitor share /app/router/venv. LiteLLM gets its own venv:
# `litellm --config` needs the litellm[proxy] extra, and that extra pins
# fastapi/uvicorn versions that conflict with the router's pins.
run_ct python3 -m venv /app/router/venv
run_ct /app/router/venv/bin/pip install --no-cache-dir \
  -r "${CONFIG_REPO_DIR}/services/ollama-router/requirements.txt" \
  -r "${CONFIG_REPO_DIR}/services/ollama-monitor/requirements.txt"

echo "Installing LiteLLM proxy (own venv)."
run_ct install -d -m 0755 /app/litellm
run_ct python3 -m venv /app/litellm/venv
# Prefer the hash-locked resolution when the repo carries one; a supply-chain
# swap of any dependency then fails the install instead of shipping.
run_ct bash -c "
  set -e
  lock='${CONFIG_REPO_DIR}/services/litellm-proxy/requirements.lock'
  req='${CONFIG_REPO_DIR}/services/litellm-proxy/requirements.txt'
  if [ -f \"\$lock\" ]; then
    /app/litellm/venv/bin/pip install --no-cache-dir --require-hashes -r \"\$lock\"
  else
    echo 'WARNING: no requirements.lock; installing LiteLLM without hash checking.' >&2
    /app/litellm/venv/bin/pip install --no-cache-dir -r \"\$req\"
  fi
  /app/litellm/venv/bin/python -c 'import litellm.proxy.proxy_server' >/dev/null
  # Root-owned, read-only for the service: make sure it can read and run it.
  chmod -R u+rwX,go+rX,go-w /app/litellm
"

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
# traffic. Allow SSH (22), the OSR API (8000) and Open WebUI (OPENWEBUI_PORT)
# from the trusted subnet. LiteLLM (4000) stays localhost-only and needs no rule.
if [[ "$FIREWALL" == "1" && -n "$API_ALLOW_CIDR" ]]; then
  echo "Adding firewall rules to allow tcp/22, tcp/8000 and tcp/${OPENWEBUI_PORT} from ${API_ALLOW_CIDR}."
  mkdir -p "/etc/pve/firewall"
  write_firewall_rules "/etc/pve/firewall/${CT_ID}.fw" "$API_ALLOW_CIDR" "$OPENWEBUI_PORT"
elif [[ "$FIREWALL" == "1" ]]; then
  echo "WARNING: FIREWALL=1 but API_ALLOW_CIDR is unset. If the datacenter" >&2
  echo "         firewall is active, inbound tcp/22, tcp/8000 and tcp/${OPENWEBUI_PORT}" >&2
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
   OSR (OpenAI API)           http://${ROUTER_IP}:8000/v1     [ollama-router.service]
     (Bearer key: ROUTER_API_KEY in /app/router/secrets.env)
   LiteLLM proxy              http://127.0.0.1:4000  (local)  [litellm-proxy.service]
   Health monitor             Mattermost alerts               [ollama-monitor.service]

  MODEL TIERS  ->  OLLAMA BACKEND(S)
  ---------------------------------------------------------------------------
   fast     ->  $(indices_to_urls "$TIER_FAST_IDX")   (ollama/${MODEL_FAST})
   medium   ->  $(indices_to_urls "$TIER_MEDIUM_IDX")   (ollama/${MODEL_MEDIUM})
   large    ->  $(indices_to_urls "$TIER_LARGE_IDX")   (ollama/${MODEL_LARGE})
   xlarge   ->  $(indices_to_urls "$TIER_XLARGE_IDX")   (ollama/${MODEL_XLARGE})
   ${MODEL_SERVER_COUNT} server(s) total

  PATHS & COMMANDS
  ---------------------------------------------------------------------------
   OSR config    : /app/router/.env  /app/router/litellm_config.yaml
   Tunables      : /app/router/router.ini  /app/router/monitor.ini
   WebUI config  : /app/openwebui/.env
   Config repo   : ${CONFIG_REPO_DIR}  (git pull && ./install/apply-config.sh)
   Model servers : manage-model-servers list | status | models
                   manage-model-servers add <ip> --tier large --apply
                   manage-model-servers set-model large <tag> --apply
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
echo "  -> create the admin account on first visit; it is pre-connected to OSR."
echo "Config directory (in container): ${CONFIG_REPO_DIR}"
if [[ "$CONFIG_SOURCE" == "repo" ]]; then
  echo "Config source: git clone of ${GITEA_SERVER_URL%/}/${GITEA_OWNER}/${GITEA_REPO_NAME}"
else
  echo "Config source: LOCAL (not version controlled — no usable Gitea token)"
fi
echo "=============================================================================="

# The selected targets, now that the router they belong to is running. A failed
# target never touches the router; the summary says how to retry it.
if [[ -n "$TARGETS" ]]; then
  provision_selected_targets || exit 1
fi
