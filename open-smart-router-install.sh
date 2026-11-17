#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# Open Smart Router LXC installer for Proxmox
#
# Run as root on a Proxmox host, from a full repository checkout. It creates
# the router CT (smart router, LiteLLM, health monitor, Open WebUI) and the
# selected targets/ CTs. README.md covers installation and operation,
# ARCHITECTURE.md the design.
#
#   * Config files are staged on the host and pushed with `pct push`, so a
#     secret can never break out of shell quoting; the root password is set
#     over stdin, never on argv.
#   * Configuration is version controlled: the installer builds a per-service
#     config tree and seeds it into the Gitea repository (missing files only,
#     so your commits win); the container clones it and applies it with
#     install/apply-config.sh. The pull happens once, at provisioning, so a
#     Gitea outage can never block a service start.
#   * An ERR trap destroys a half-provisioned router container.
#
# The project was called Ollama Smart Router before November 2026. New installs
# use only the new names (osr-router and osr-monitor units, services/ paths and
# service account); an update migrates an existing install. See "Upgrading
# from Ollama Smart Router" in README.md.
# ==============================================================================
CT_ID="${CT_ID:-}"                    # default: the cluster's next free ID
CT_NAME="${CT_NAME:-open-smart-router}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CIDR="${IP_CIDR:-}"
GATEWAY="${GATEWAY:-}"
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
# This container never has a GPU — inference happens on the remote model hosts —
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
TEMPLATE_STORAGE_EXPLICIT="${TEMPLATE_STORAGE+x}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE_NAME="${TEMPLATE_NAME:-}"
TEMPLATE_REF="${TEMPLATE_REF:-}"
# Minimum free space wanted on the storage that holds the container template.
TEMPLATE_MIN_GIB="${TEMPLATE_MIN_GIB:-2}"
FIREWALL="${FIREWALL:-1}"
# Bearer token required by the OSR API (8000). Blank = generate one. Stored
# only in /app/router/secrets.env; change it later with
#   manage-model-servers set-api-key [key|--generate|--off]
ROUTER_API_KEY="${ROUTER_API_KEY:-}"
API_ALLOW_CIDR="${API_ALLOW_CIDR:-}"  # if FIREWALL=1, allow 8000 from this CIDR
# --- Model servers -----------------------------------------------------------
# Everything here is only a DEFAULT offered at the prompts; set any of these in
# the environment to pre-fill (or, with NONINTERACTIVE=true, to skip) a prompt.
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
# How many model servers to configure. Asked at install; anything outside
# MODEL_SERVER_MIN..MODEL_SERVER_MAX is rejected with an error and re-prompted.
MODEL_SERVER_MIN="${MODEL_SERVER_MIN:-1}"
MODEL_SERVER_MAX="${MODEL_SERVER_MAX:-20}"
MODEL_SERVER_COUNT="${MODEL_SERVER_COUNT:-3}"
# Per-index values may be preset through the environment. Unset server
# addresses have no default and must be entered at the prompt.
MODEL_SERVER_1="${MODEL_SERVER_1:-}"
MODEL_SERVER_2="${MODEL_SERVER_2:-}"
MODEL_SERVER_3="${MODEL_SERVER_3:-}"
# How long Ollama should keep a model resident after a request. Blank means
# "send nothing", so each server's own OLLAMA_KEEP_ALIVE governs. A value here
# (e.g. 30m, 2h, -1 for indefinite) is sent explicitly on the LiteLLM path and
# used by the monitor's keep-alive maintainer. See the note in the README about
# why the OpenAI-compatible endpoint needs the maintainer.
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-}"
KEEP_ALIVE_REFRESH_SECONDS="${KEEP_ALIVE_REFRESH_SECONDS:-240}"
# Model tag served by each tier: defaults only. The prompts take the tags the
# servers really have (what you `ollama pull`ed, or a non-Ollama server's ID).
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
# Prometheus and Grafana in the router CT (install/setup-metrics.sh): a local
# dashboard of the router's /metrics. true (default) tries to install them,
# which needs Debian's and Grafana's package repositories; a failure leaves the
# router running. false leaves them out; add them later with that script.
INSTALL_METRICS="${INSTALL_METRICS:-true}"
INSTALL_MATTERMOST="${INSTALL_MATTERMOST:-false}"
# Optional targets from targets/ (the Gitea and Mattermost services, model
# servers, Honcho memory, the Hermes / OpenClaw / DeepSeek / OpenCode agents and the Open Terminal /
# ComfyUI tools), each in its own LXC. Interactive installs ask which to create
# (names or menu numbers). INSTALL_TARGETS pre-fills the answer with target
# names, comma-separated, e.g. INSTALL_TARGETS=ollama,hermes; menu numbers are
# refused there, because they follow the menu's grouping and can change.
# Unattended installs refuse a non-empty list.
INSTALL_TARGETS="${INSTALL_TARGETS:-}"
TARGETS_DIR="${TARGETS_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/targets}"
TARGETS=""
# Root SSH between the nodes of a Proxmox cluster, which tools/upgrade-all.sh
# needs to reach CTs on other nodes: fix (check, and repair what is safe;
# default), check (report only) or skip.
CLUSTER_SSH="${CLUSTER_SSH:-fix}"
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
GITEA_REPO_DEFAULT_NAME="open-smart-router"
GITEA_REPO_NAME="${GITEA_REPO_NAME:-$GITEA_REPO_DEFAULT_NAME}"
# The default name before the rename from Ollama Smart Router. When the default
# name above finds no repository but this one exists, it is used, so a rerun
# keeps the configuration committed there instead of seeding an empty
# repository. Set it empty to turn that off; a GITEA_REPO_NAME of your own is
# never replaced.
GITEA_REPO_LEGACY_NAME="${GITEA_REPO_LEGACY_NAME-ollama-smart-router}"
# Owner of that repository. Leave empty to resolve automatically: the token
# owner first, then a search across everything the token can see. Set this
# explicitly when the repo belongs to an organisation, or when several accounts
# have a repo by the same name.
GITEA_REPO_OWNER="${GITEA_REPO_OWNER:-}"
GITEA_REPO_PRIVATE="${GITEA_REPO_PRIVATE:-true}"
# TurnKey appliances ship a self-signed certificate, so this defaults to false:
# the deploy token is then sent over a connection whose certificate is not
# authenticated. Set GITEA_VERIFY_TLS=true once the appliance's CA (or a real
# certificate) is trusted on this host. Every Gitea call, the container's clone
# and GITEA_VERIFY_TLS in env/router.env follow it. Anything but "true" is false.
GITEA_VERIFY_TLS="${GITEA_VERIFY_TLS:-false}"
[[ "$GITEA_VERIFY_TLS" == "true" ]] || GITEA_VERIFY_TLS=false
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
  services/osr-router/router.py
  services/osr-router/requirements.txt
  services/osr-router/osr-router.service
  services/osr-monitor/monitor.py
  services/osr-monitor/requirements.txt
  services/osr-monitor/osr-monitor.service
  services/litellm-proxy/requirements.txt
  services/litellm-proxy/requirements.lock
  services/litellm-proxy/litellm-proxy.service
  services/open-webui/open-webui.service
  install/apply-config.sh
  install/manage-model-servers.sh
  install/setup-metrics.sh
)
# OLD:NEW service directories renamed with the project (the unit file inside
# is renamed too). Seeding moves an existing repo's old directories.
LEGACY_SERVICE_DIRS=(ollama-router:osr-router ollama-monitor:osr-monitor)
# Repo owner: discovered from the deploy token at runtime; this is the fallback.
GITEA_OWNER="${GITEA_ADMIN_USER}"
MATTERMOST_WEBHOOK_URL="${MATTERMOST_WEBHOOK_URL:-}"
MATTERMOST_MONITOR_USER="${MATTERMOST_MONITOR_USER:-OSRMonitor}"
MATTERMOST_CHANNEL="${MATTERMOST_CHANNEL:-osr-monitor}"
# Verification is ON by default. An internal Mattermost behind a self-signed
# certificate needs this false, or every alert fails as a transport error.
MATTERMOST_VERIFY_TLS="${MATTERMOST_VERIFY_TLS:-true}"

# --- small helpers -------------------------------------------------------------
# router_settings for litellm_config.yaml. Input on stdin: one line per tier
# that has deployments, in size order: "<model_name> <signature>". Each tier
# falls back to the nearest other tiers (smaller first on a tie), skipping a
# tier with identical deployments -- the same model on the same host cannot
# succeed where the original just failed. A tier with Kindi is a fallback
# only for another Kindi tier on other Kindi servers (litellm_fallbacks in
# manage-model-servers has the reasons). Same rule as manage-model-servers.
litellm_router_settings() {
  python3 -c '
import json, re, sys
tiers = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        name, _, sig = line.partition(" ")
        tiers.append((name, sig))
print("router_settings:")
print("  routing_strategy: latency-based-routing")
print("  num_retries: 2")
print("  timeout: 600")
def kindi(sig):
    return set(re.findall(r"kindi[+][^,@\s]+", sig))
def may_fall_back(sig, osig):
    return not kindi(osig) or (kindi(sig) and not kindi(sig) & kindi(osig))
rows = []
for i, (name, sig) in enumerate(tiers):
    others = [(abs(i - j), j, o) for j, (o, osig) in enumerate(tiers)
              if o != name and osig != sig and may_fall_back(sig, osig)]
    if others:
        rows.append("    - %s: %s" % (name, json.dumps([o for _, _, o in sorted(others)])))
if rows:
    print("  fallbacks:")
    print("\n".join(rows))
# Tiers with a Kindi deployment: no retry after a timeout, one after a 429.
# LiteLLM 1.75 does not read InternalServerErrorRetries, so the router caps the
# other errors for those tiers with x-litellm-num-retries: 1.
rows = []
for name, sig in tiers:
    if "@kindi+" in sig or ",kindi+" in sig:
        rows += ["    %s:" % name, "      # osr-kindi-policy", "      TimeoutErrorRetries: 0",
                 "      RateLimitErrorRetries: 1"]
if rows:
    print("  model_group_retry_policy:")
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
prompt_template_storage() {
  local -a names=() types=()
  local name type choice i default_idx=0
  while IFS=$'\t' read -r name type _; do
    [[ -n "$name" ]] || continue
    names+=("$name"); types+=("$type")
    [[ "$name" == "$TEMPLATE_STORAGE" ]] && default_idx=${#names[@]}
  done < <(storage_candidates vztmpl)
  if (( ${#names[@]} == 0 )); then
    echo "No active storage accepts LXC templates (vztmpl)." >&2
    diagnose_storage vztmpl
    return 1
  fi
  if (( default_idx == 0 )); then
    if [[ -n "$TEMPLATE_STORAGE_EXPLICIT" && "$NONINTERACTIVE" == true ]]; then
      echo "Template storage '${TEMPLATE_STORAGE}' is not active or does not support vztmpl." >&2
      return 1
    fi
    default_idx=1
  fi
  echo
  echo "  Storage for the router's LXC template:"
  for (( i=0; i<${#names[@]}; i++ )); do
    printf '    %d) %s (%s)\n' "$((i + 1))" "${names[i]}" "${types[i]}"
  done
  if [[ "$NONINTERACTIVE" == true ]]; then
    TEMPLATE_STORAGE="${names[default_idx - 1]}"
  else
    while true; do
      read -r -p "  Select template storage [${default_idx}]: " choice || return 1
      [[ -n "$choice" ]] || choice="$default_idx"
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
        TEMPLATE_STORAGE="${names[choice - 1]}"
        break
      fi
      echo "    Enter a number from 1 to ${#names[@]}." >&2
    done
  fi
  TEMPLATE_STORAGE_EXPLICIT=1
  echo "  Using template storage: ${TEMPLATE_STORAGE}"
}
router_template_storages() {
  if [[ -n "$TEMPLATE_STORAGE_EXPLICIT" ]]; then
    printf '%s\n' "$TEMPLATE_STORAGE"
  else
    template_storages
  fi
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
    [[ -z "$TEMPLATE_NAME" ]] || continue
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
  done < <(router_template_storages)
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
valid_router_template_ref() {
  local ref="$1" storage name free_gib
  [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-13-standard_[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] || return 1
  storage="${ref%%:*}"
  name="${ref#*:vztmpl/}"
  pveam list "$storage" 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq -- "$ref" && return 0
  if ! storage_supports_vztmpl "$storage"; then
    echo "    Storage '${storage}' cannot hold LXC templates." >&2
    return 1
  fi
  if ! pveam available --section system 2>/dev/null | awk 'NR > 1 {print $2}' | grep -Fxq -- "$name"; then
    echo "    Template '${name}' is neither downloaded nor available to download." >&2
    return 1
  fi
  free_gib="$(storage_free_gib "$storage" vztmpl)"
  if [[ "$free_gib" =~ ^[0-9]+$ ]] && (( free_gib < TEMPLATE_MIN_GIB )); then
    echo "    Storage '${storage}' has only ${free_gib} GiB free; ${TEMPLATE_MIN_GIB} GiB is needed." >&2
    return 1
  fi
}
show_router_template_alternatives() {
  local selected="$1" storage ref shown=0
  while IFS= read -r storage; do
    while IFS= read -r ref; do
      [[ "$ref" != "$selected" && "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-13-standard_[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] || continue
      if (( shown == 0 )); then
        echo "  Other downloaded Debian 13 templates:"
        shown=1
      fi
      printf '    %s\n' "$ref"
    done < <(pveam list "$storage" 2>/dev/null | awk 'NR > 1 {print $1}' | sort -V -r)
  done < <(template_storages)
}
select_router_template() {
  local n t a suggested="${TEMPLATE_REF:-}" free_gib name
  DOWNLOAD_TEMPLATE_NAME=""
  if [[ -z "$suggested" ]]; then
    if suggested="$(find_existing_debian_template)"; then
      :
    else
      if ! storage_supports_vztmpl "$TEMPLATE_STORAGE"; then
        echo "Storage '${TEMPLATE_STORAGE}' does not support vztmpl content; cannot download a template there." >&2
        echo "Set TEMPLATE_STORAGE to a storage that lists 'vztmpl' in 'pvesm status -content vztmpl'." >&2
        echo "Candidates with free space:" >&2
        storage_candidates vztmpl | while IFS=$'\t' read -r n t a; do
          echo "  ${n} (${t}): $(kib_to_gib "$a") GiB free" >&2
        done
        return 1
      fi
      free_gib="$(storage_free_gib "$TEMPLATE_STORAGE" vztmpl)"
      if [[ "$free_gib" =~ ^[0-9]+$ ]] && (( free_gib < TEMPLATE_MIN_GIB )); then
        echo "Storage '${TEMPLATE_STORAGE}' has only ${free_gib} GiB free;" >&2
        echo "at least ${TEMPLATE_MIN_GIB} GiB is wanted for the container template." >&2
        select_storage_with_space vztmpl "$TEMPLATE_MIN_GIB" TEMPLATE_STORAGE "$TEMPLATE_STORAGE" || return 1
      fi
      name="$(select_available_debian_template)" || return 1
      suggested="${TEMPLATE_STORAGE}:vztmpl/${name}"
    fi
  fi
  [[ "$NONINTERACTIVE" == true ]] || show_router_template_alternatives "$suggested"
  prompt_until_valid "  Router template (storage:vztmpl/name)" TEMPLATE_REF "$suggested" valid_router_template_ref || return 1
  TEMPLATE_STORAGE="${TEMPLATE_REF%%:*}"
  name="${TEMPLATE_REF#*:vztmpl/}"
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq -- "$TEMPLATE_REF"; then
    echo "Using existing Debian container template: ${TEMPLATE_REF}"
  else
    DOWNLOAD_TEMPLATE_NAME="$name"
  fi
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
  raw="${raw#avalon+}"
  [[ "$raw" == avalon://* ]] && raw="${raw#avalon://}"
  raw="${raw#kindi+}"
  [[ "$raw" == kindi://* ]] && raw="${raw#kindi://}"
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
# LM Studio, Strata, Basalt, Maya, Xolotl, Avalon and Kindi, matching the manager, router and monitor.
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
  elif [[ "$raw" == avalon+* ]]; then
    prefix="avalon+"; raw="${raw#avalon+}"; port="${AVALON_PORT:-8080}"
  elif [[ "$raw" == avalon://* ]]; then
    prefix="avalon+"; raw="${raw#avalon://}"; port="${AVALON_PORT:-8080}"
  elif [[ "$raw" == kindi+* ]]; then
    prefix="kindi+"; raw="${raw#kindi+}"; port="${KINDI_PORT:-8093}"
  elif [[ "$raw" == kindi://* ]]; then
    prefix="kindi+"; raw="${raw#kindi://}"; port="${KINDI_PORT:-8093}"
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

# next_free_ct_id [RESERVED...]: the cluster's next free CT ID (pvesh get
# /cluster/nextid), stepping past IDs this install has already given out, since
# none of its CTs exists until it is created. Prints nothing when the cluster
# cannot be asked; the prompt then has no default.
next_free_ct_id() {
  local id reserved=" $* " tries=0
  command -v pvesh >/dev/null 2>&1 || return 0
  id="$(pvesh get /cluster/nextid 2>/dev/null)" || return 0
  id="${id//[^0-9]/}"
  [[ "$id" =~ ^[1-9][0-9]{2,8}$ ]] || return 0
  while [[ "$reserved" == *" ${id} "* ]] || ! ct_id_free "$id"; do
    id=$(( id + 1 )); tries=$(( tries + 1 ))
    (( tries < 1000 && id <= 999999999 )) || return 0
  done
  printf '%s\n' "$id"
}

# True when no guest in the cluster uses the ID (pct only sees this node).
ct_id_free() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1
  else
    ! pct status "$1" >/dev/null 2>&1
  fi
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
# front and created after the router. Memory infrastructure follows the model
# servers, then companions that need the router's Open WebUI come last.
#
# A gateway (FreeLLMAPI) is created with the model targets but is no model
# server: its provisioner registers it with the router as an explicit-only
# endpoint (manage-model-servers set-freellmapi).
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
    'airllm|model|AirLLM: one model larger than RAM/VRAM, streamed from disk (slow)|http://@IP@:11434||:nvidia' \
    'kindi|model|Kindi (Ternary-Bonsai-2 2B-27B) on a small or old NVIDIA GPU (Kepler to RTX 50), or the CPU|kindi+http://@IP@:@PORT@|kindi|optional:nvidia' \
    'llamacpp|model|llama.cpp llama-server behind an Ollama bridge (CUDA, or Vulkan on AMD/Intel Arc)|http://@IP@:11434||required:nvidia,amd,intel' \
    'strata|model|Strata (Qwen3.8-Flash-Next) on an NVIDIA GPU|strata+http://@IP@:@PORT@|strata|required:nvidia' \
    'basalt|model|Basalt on a Blackwell GPU (CUDA 13)|basalt+http://@IP@:@PORT@|basalt|required:nvidia:rtx50' \
    'maya|model|Project Maya (GLM-5.3-Flash) on an NVIDIA GPU|maya+http://@IP@:@PORT@|maya|required:nvidia' \
    'xolotl|model|Xolotl (DeepSeek-V4.1-Flash, 552B) on a 24 GB NVIDIA GPU; ~372 GB download|xolotl+http://@IP@:@PORT@|xolotl|required:nvidia' \
    'avalon|model|Avalon (Qwen3.8-Flash-Next, llama.cpp fork) on a 16-20 GB AMD RX 7000 (ROCm) or NVIDIA GPU; ~90 GiB download|avalon+http://@IP@:@PORT@|avalon|required:amd,nvidia:rdna3,rtx20,rtx30,rtx40,rtx50' \
    'honcho|companion|Honcho AI: agent and per-user memory and MCP tools; CPU, with its own embedding model|||' \
    'hermes|companion|Hermes Agent: offered in Open WebUI as the model hermes-agent|||' \
    'openclaw|companion|OpenClaw: agent offered in Open WebUI as the model openclaw|||' \
    'deepseek-harness|companion|DeepSeek Harness: agent Web UI in its own LXC, using OSR models|||' \
    'opencode|companion|OpenCode: coding agent with its own web UI, also offered in Open WebUI as the model opencode|||' \
    'open-terminal|companion|Open Terminal: a private workspace per user, for Open WebUI and the agents|||' \
    'comfyui|companion|ComfyUI: image generation for Open WebUI (NVIDIA, AMD or Intel Arc GPU when present)|||optional:nvidia,amd,intel' \
    'freellmapi|gateway|FreeLLMAPI: free cloud tiers behind one key, offered as freellmapi/<id> and used only when named (needs Proxmox VE 9.1)|||'
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
# AirLLM uses an NVIDIA GPU only when GPU_DEVICES is given. Avalon follows
# AVALON_BACKEND (rocm: AMD, cuda: NVIDIA). Kindi uses an NVIDIA GPU when
# present, needs one with KINDI_BACKEND=cuda and none with cpu. Ollama and
# ComfyUI follow GPU (nvidia, amd or intel picks one; no or none runs on the CPU).
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
    avalon)
      case "${AVALON_BACKEND:-auto}" in
        rocm) vendors=amd ;;
        cuda) vendors=nvidia ;;
      esac ;;
    kindi)
      case "${KINDI_BACKEND:-auto}" in
        cuda) need=required ;;
        cpu) need="" ;;
      esac ;;
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
# configured, so that each install asks which card it gets? So does Kindi,
# which is meant for a spare old NVIDIA card beside the others. The other
# NVIDIA-only targets use the NVIDIA driver's GPU 0 (or their GPU_DEVICES).
target_gpu_prompted() {
  local need vendors
  IFS='|' read -r need vendors _ <<< "$(target_gpu_spec "$1")" || return 1
  [[ -n "$need" ]] || return 1
  [[ "$1" == kindi || ",$vendors," == *",amd,"* || ",$vendors," == *",intel,"* ]]
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
# Arc (Ollama, llama.cpp, ComfyUI), and for Kindi, ask which of the host's GPUs it gets; the
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
        echo "${var}=none: ${name} needs a GPU (llama.cpp: set BACKEND=cpu to build without one; Kindi: KINDI_BACKEND=cpu)." >&2
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

# cluster_ssh_tool: tools/setup-cluster-ssh.sh of this checkout.
cluster_ssh_tool() {
  local tool="${TARGETS_DIR}/../tools/setup-cluster-ssh.sh"
  if [[ ! -r "$tool" ]]; then
    echo "Missing ${tool}. Run the OSR installer from the full repository checkout." >&2
    return 1
  fi
  printf '%s\n' "$tool"
}

# prepare_cluster_ssh: in a Proxmox cluster, make sure root on every node can
# reach every other node over SSH, the way Proxmox does, so tools/upgrade-all.sh
# can later upgrade CTs on any node from any node. tools/setup-cluster-ssh.sh
# checks it and repairs what it safely can (pvecm updatecerts on this node, and
# on nodes it reaches); on a terminal it can also sign in to a node once with
# its root password to repair it. CLUSTER_SSH=check only reports, skip skips
# it; an unattended install repairs without questions. The router does not need
# it, so a problem left over is a warning and the install goes on. A standalone
# host has nothing to do.
prepare_cluster_ssh() {
  local tool rc=0
  local -a args=()
  case "${CLUSTER_SSH}" in
    skip) echo "Cluster SSH check skipped (CLUSTER_SSH=skip)."; return 0 ;;
    check) args+=(--check) ;;
    fix) [[ "${NONINTERACTIVE}" != true ]] || args+=(--yes) ;;
    *) echo "CLUSTER_SSH must be fix, check or skip (not '${CLUSTER_SSH}')." >&2; return 1 ;;
  esac
  tool="$(cluster_ssh_tool)" || return 1
  echo
  echo "--- Root SSH between the cluster's nodes (for upgrades from any node) ---"
  if [[ "${NONINTERACTIVE}" == true ]]; then
    bash "$tool" "${args[@]}" </dev/null || rc=$?
  else
    bash "$tool" "${args[@]}" || rc=$?
  fi
  case "$rc" in
    0) ;;
    1)
      echo "WARNING: root SSH between the cluster's nodes is incomplete (see above). The install" >&2
      echo "  goes on; tools/upgrade-all.sh cannot reach CTs on those nodes until it is fixed." >&2
      echo "  Check again with: bash ${tool}" >&2 ;;
    *) echo "WARNING: the cluster SSH check could not run (exit ${rc}); check later with: bash ${tool}" >&2 ;;
  esac
  return 0
}

# target_gpu_env NAME: the GPU settings a target gets from prepare_host_gpu
# (NAME=value lines), unless they were preset: GPU for Ollama and ComfyUI and,
# for a chosen card, GPU_CARD (its PCI address); for llama.cpp BACKEND (cuda
# or vulkan) and GPU_DEVICES: the card's render node for Vulkan, its
# /dev/nvidia<minor> with the control and UVM devices for CUDA; for Avalon
# AVALON_BACKEND (rocm or cuda) and GPU_DEVICES: /dev/kfd and the card's
# render node for ROCm, the NVIDIA nodes for CUDA; for Kindi KINDI_BACKEND
# (cuda with a ready NVIDIA card, else cpu) and that card's NVIDIA nodes.
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
    avalon)
      local avalon_backend="${AVALON_BACKEND:-auto}"
      [[ $state == ready ]] || return 0
      if [[ "$avalon_backend" == auto ]]; then
        case "$vendor" in nvidia) avalon_backend=cuda ;; amd) avalon_backend=rocm ;; *) return 0 ;; esac
        echo "AVALON_BACKEND=${avalon_backend}"
      fi
      [[ -z "${GPU_DEVICES:-}" ]] || return 0
      if [[ "$avalon_backend" == rocm && -n "$render" ]]; then
        echo "GPU_DEVICES=/dev/kfd ${render}"
      elif [[ "$avalon_backend" == cuda && -n "$minor" ]]; then
        echo "GPU_DEVICES=/dev/nvidia${minor} /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools"
      fi ;;
    kindi)
      local kindi_backend="${KINDI_BACKEND:-auto}"
      if [[ $state != ready || $vendor != nvidia ]]; then
        [[ "$kindi_backend" != auto ]] || echo "KINDI_BACKEND=cpu"
        return 0
      fi
      [[ "$kindi_backend" != auto ]] || echo "KINDI_BACKEND=cuda"
      if [[ -z "${GPU_DEVICES:-}" && -n "$minor" ]]; then
        echo "GPU_DEVICES=/dev/nvidia${minor} /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools"
      fi ;;
  esac
}

# Strata, Basalt, Maya, Xolotl, Avalon and Kindi take a template; the others choose or prompt for theirs.
target_needs_template() {
  [[ "$1" == strata || "$1" == basalt || "$1" == maya || "$1" == xolotl || "$1" == avalon || "$1" == kindi ]]
}

# The newer NVIDIA repositories do not carry the targets' CUDA defaults.
# Keep an explicit user choice, including an unavailable one (the target's
# preflight explains that error before it creates a CT).
target_cuda_env() {
  local name=$1 template=$2 key release
  case "$name" in
    basalt) key=CUDA_VERSION ;;
    maya) key=MAYA_CUDA_VERSION ;;
    xolotl) key=XOLOTL_CUDA_VERSION ;;
    avalon) key=AVALON_CUDA_VERSION ;;
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

target_menu_group() {
  case "$1" in
    gitea|mattermost) echo 'Services (CPU): configuration and alerts; created before OSR.' ;;
    ollama|airllm|kindi) echo 'Model servers (CPU or optional GPU):' ;;
    honcho) echo 'Memory infrastructure (CPU): created before agents.' ;;
    freellmapi) echo 'Cloud gateway (CPU): prompts leave your network; never chosen by auto.' ;;
    *)
      case "$(target_field "$1" phase)" in
        model) echo 'Model servers (GPU required by default):' ;;
        companion)
          case "$1" in
            hermes|openclaw|deepseek-harness|opencode) echo 'Agents (CPU): OSR-backed, with optional Honcho memory.' ;;
            open-terminal) echo 'Open WebUI tools (CPU):' ;;
            comfyui) echo 'Image generation (GPU optional):' ;;
          esac ;;
      esac ;;
  esac
}
prompt_target_selection() {
  local name phase label group i=0 prev_group=""
  TARGETS=""
  # A preset names its targets: menu numbers follow the menu's grouping and
  # change when targets are added or regrouped, so a saved number could pick
  # another target without a word.
  local token
  for token in ${INSTALL_TARGETS//,/ }; do
    if [[ "$token" =~ ^[0-9]+$ ]]; then
      echo "INSTALL_TARGETS takes target names (e.g. ollama,hermes), not menu numbers: '${token}'." >&2
      echo "Menu numbers change when targets are added or regrouped; names do not." >&2
      return 1
    fi
  done
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
    group="$(target_menu_group "$name")"
    [[ "$group" == "$prev_group" ]] || echo "$group"
    printf '  %d) %-14s %s\n' "$i" "$name" "$label"
    prev_group="$group"
  done < <(target_table)
  echo "Target-specific settings (GPU_DEVICES, BACKEND, STRATA_MODEL, HERMES_MODEL, OPENCLAW_MODEL, OPENCODE_MODEL, COMFYUI_MODEL_URL, ...) are read"
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
# Avalon: ROCm on Radeon cards needs Ubuntu 24.04 or 22.04. Its CUDA build
# also supports the other templates accepted by the target provisioner.
valid_avalon_template() {
  valid_target_template "$1" || return 1
  case ${AVALON_BACKEND:-auto} in
    cuda) return 0 ;;
    rocm) ;;
    auto)
      if [[ -n ${GPU_DEVICES:-} ]]; then
        [[ " $GPU_DEVICES " == *' /dev/nvidia'* ]] && return 0
      else
        local state vendor
        IFS='|' read -r state vendor _ <<< "$(target_gpu_result avalon)"
        [[ $state == ready && $vendor == nvidia ]] && return 0
      fi ;;
  esac
  [[ "$1" == *:vztmpl/ubuntu-24.04-* || "$1" == *:vztmpl/ubuntu-22.04-* ]]
}
# Kindi: the CUDA 10.2 runfile runs on Debian 12/13 and Ubuntu 22.04/24.04.
valid_kindi_template() { valid_strata_template "$1"; }
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
valid_freellmapi_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; }
# freellmapi_host_ready: FreeLLMAPI's CT is made from its container image,
# which needs Proxmox VE 9.1 (OCI images as CT templates) and skopeo. Said
# when the target is chosen, not after the router is built.
freellmapi_host_ready() {
  local version
  version="$(pveversion 2>/dev/null)" || version=""
  if [[ ! "$version" =~ ^pve-manager/([0-9]+)\.([0-9]+) ]] ||
     (( BASH_REMATCH[1] < 9 || ( BASH_REMATCH[1] == 9 && BASH_REMATCH[2] < 1 ) )); then
    echo "    FreeLLMAPI needs Proxmox VE 9.1 or later (its CT is made from a container image); this host: ${version:-unknown}." >&2
    return 1
  fi
  if ! command -v skopeo >/dev/null 2>&1; then
    echo "    FreeLLMAPI needs skopeo on this host to pull its image: apt install skopeo" >&2
    return 1
  fi
}
valid_honcho_model() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]]; }
# Blank: Honcho's own token budgets (fine for a context window of 128k or more).
valid_honcho_context_tokens() { [[ -z $1 || ( $1 =~ ^[1-9][0-9]{3,6}$ && $1 -ge 8192 && $1 -le 1048576 ) ]]; }
valid_dsh_context_tokens() { [[ $1 =~ ^[1-9][0-9]{4,6}$ && $1 -ge 16384 && $1 -le 1048576 ]]; }
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
# Ubuntu 24.04/22.04 and Debian 12 repositories carry. Avalon's ROCm build
# needs Ubuntu 24.04 or 22.04 (AMD's Radeon support; its CUDA build runs there too).
# Kindi's CUDA 10.2 runfile runs on the releases Strata uses.
gpu_target_template_order() {
  case "$1" in
    strata|kindi) echo debian-13 ubuntu-24.04 ubuntu-22.04 debian-12 ;;
    avalon) echo ubuntu-24.04 ubuntu-22.04 ;;
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

# For each selected target: a CT ID (default: the next free one not already
# taken by this install), static address and storage (and a template for
# Strata, Basalt, Maya, Xolotl, Avalon and Kindi). Presets: <NAME>_CT_ID,
# <NAME>_IP_CIDR, <NAME>_STORAGE, <NAME>_TEMPLATE.
prompt_target_settings() {
  local name prefix id_var ip_var storage_var template_var default ip id_default host_mib
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
    id_default="${!id_var:-}"
    # shellcheck disable=SC2086  # the reserved IDs are separate arguments
    [[ -n "$id_default" ]] || id_default="$(next_free_ct_id $TARGET_RESERVED_IDS)"
    prompt_until_valid "    CT ID" "$id_var" "$id_default" valid_target_ct_id || return 1
    TARGET_RESERVED_IDS+=" ${!id_var}"
    prompt_until_valid "    IP address / CIDR" "$ip_var" "${!ip_var:-}" valid_target_ip || return 1
    ip="${!ip_var}"
    TARGET_RESERVED_IPS+=" ${ip%/*}"
    if ! ip_in_same_subnet "$ip" "$GATEWAY"; then
      echo "    WARNING: gateway ${GATEWAY} is outside ${ip}." >&2
    fi
    prompt_until_valid "    Storage" "$storage_var" "${!storage_var:-$STORAGE}" valid_nonempty || return 1
    if [[ $name == honcho ]]; then
      echo "    Honcho's chat model comes from OSR and must support tools and structured output."
      prompt_until_valid "    Chat model or tier" HONCHO_MODEL "${HONCHO_MODEL:-fast}" valid_honcho_model || return 1
      echo "    Its embedding model needs no answer: Qwen3-Embedding-0.6B runs on llama.cpp in Honcho's CT."
      echo "    Its context window is asked with the model targets' windows, below."
    fi
    if [[ $name == freellmapi ]]; then
      freellmapi_host_ready || return 1
      echo "    Its models answer from third-party free tiers. OSR offers them as freellmapi/<id>"
      echo "    and never picks one for auto or a tier. Provider keys are added in its dashboard."
      prompt_until_valid "    Dashboard e-mail (a sign-in name)" FREELLMAPI_ADMIN_EMAIL \
        "${FREELLMAPI_ADMIN_EMAIL:-admin@osr.local}" valid_freellmapi_email || return 1
      echo "    The dashboard password is generated in the CT; the target's summary says how to read it."
    fi
    if [[ $name == deepseek-harness ]]; then
      echo "    DeepSeek runs its own tools; choose an OSR model that supports tool calls."
      prompt_until_valid "    Model or tier" DEEPSEEK_HARNESS_MODEL "${DEEPSEEK_HARNESS_MODEL:-auto}" valid_honcho_model || return 1
    fi
    if [[ $name == opencode ]]; then
      echo "    OpenCode runs its own tools; choose an OSR model that supports tool calls."
      prompt_until_valid "    Model or tier" OPENCODE_MODEL "${OPENCODE_MODEL:-auto}" valid_honcho_model || return 1
    fi
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
      elif [[ $name == avalon ]]; then
        [[ -n "$default" ]] || default="$(default_gpu_target_template "$name")" || default=""
        prompt_until_valid "    Template (Ubuntu 24.04/22.04; CUDA also supports Debian 12/13 and Ubuntu 26.04; downloaded if missing)" \
          "$template_var" "$default" valid_avalon_template || return 1
      elif [[ $name == kindi ]]; then
        [[ -n "$default" ]] || default="$(default_gpu_target_template "$name")" || default=""
        prompt_until_valid "    Template (Debian 12/13 or Ubuntu 22.04/24.04; downloaded if missing)" \
          "$template_var" "$default" valid_kindi_template || return 1
      else
        [[ -n "$default" ]] || default="$(default_gpu_target_template "$name")" || default=""
        prompt_until_valid "    Template (Ubuntu 22.04/24.04/26.04 or Debian 12/13; downloaded if missing; Ubuntu 26.04 needs CUDA 13.3+)" \
          "$template_var" "$default" valid_target_template || return 1
      fi
    fi
    if [[ $name == strata ]]; then
      host_mib="$(host_memory_mib)"
      echo "    Strata holds its model in RAM: about 48 GB for IQ2_XS, 60 for IQ3_XXS and 62 for IQ3_S,"
      echo "    plus from a 64K window the context's cache (1.8 GB at 128K, 3.6 GB at 256K)."
      [[ -z $host_mib ]] || echo "    This host has ${host_mib} MiB; leave some for Proxmox."
      prompt_until_valid "    RAM (MiB, 32768 or more)" STRATA_MEMORY_MB "${STRATA_MEMORY_MB:-65536}" \
        valid_strata_memory_mb || return 1
      if [[ -n $host_mib ]] && (( STRATA_MEMORY_MB > host_mib )); then
        echo "    WARNING: ${STRATA_MEMORY_MB} MiB is more than this host's ${host_mib} MiB." >&2
      fi
    fi
  done
}
# valid_strata_memory_mb MIB: Strata's CT memory, 32768 MiB or more (its
# provisioner's minimum).
valid_strata_memory_mb() { [[ $1 =~ ^[1-9][0-9]{4,8}$ ]] && (( $1 >= 32768 )); }
# host_memory_mib: this host's RAM in MiB (MemTotal), or nothing when it cannot
# be read. HOST_MEMINFO overrides /proc/meminfo (tests).
host_memory_mib() {
  local kib
  kib="$(awk '/^MemTotal:/ { print $2; exit }' "${HOST_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  if [[ $kib =~ ^[0-9]+$ ]]; then echo $(( kib / 1024 )); fi
  return 0
}

# --- context windows ----------------------------------------------------------
# A model target's context window is the most tokens one request can hold
# (prompt, history, tool definitions and reply). Every target that has the
# setting defaults to 65536; prompt_target_contexts asks for each one and
# recommends a size from the target's engine, its GPU's memory and the agents
# selected with it.

# target_context_var NAME: the variable holding a model target's per-request
# context window; fails for a target without one. llama.cpp's CONTEXT_SIZE is
# shared by its PARALLEL_SLOTS, so its per-request window is LLAMACPP_CONTEXT
# here. AirLLM streams layers from disk and keeps its own AIRLLM_MAX_SEQ_LEN.
target_context_var() {
  case "$1" in
    ollama) echo OLLAMA_CONTEXT_LENGTH ;;
    llamacpp) echo LLAMACPP_CONTEXT ;;
    strata|basalt|maya|xolotl|avalon|kindi) echo "$(target_var_prefix "$1")_CONTEXT" ;;
    *) return 1 ;;
  esac
}
# llamacpp_slots: PARALLEL_SLOTS when it is a positive number, else 1.
llamacpp_slots() {
  if [[ ${PARALLEL_SLOTS:-} =~ ^[1-9][0-9]*$ ]]; then echo "$PARALLEL_SLOTS"; else echo 1; fi
}
# target_context_preset NAME: the context window preset for a target, or
# nothing. A preset llama.cpp CONTEXT_SIZE is divided among its slots.
target_context_preset() {
  local var
  var="$(target_context_var "$1")" || return 1
  if [[ $1 == llamacpp && -z ${LLAMACPP_CONTEXT:-} && ${CONTEXT_SIZE:-} =~ ^[1-9][0-9]*$ ]]; then
    echo $(( CONTEXT_SIZE / $(llamacpp_slots) ))
    return 0
  fi
  printf '%s\n' "${!var:-}"
}
# target_context_env NAME: the setting the target's provisioner reads, as
# VAR=value, or nothing when no window was chosen. llama.cpp gets CONTEXT_SIZE,
# the window times its slots.
target_context_env() {
  local var
  var="$(target_context_var "$1")" || return 0
  [[ -n ${!var:-} ]] || return 0
  if [[ $1 == llamacpp ]]; then
    echo "CONTEXT_SIZE=$(( ${!var} * $(llamacpp_slots) ))"
  else
    echo "${var}=${!var}"
  fi
}
valid_target_context() { [[ $1 =~ ^[1-9][0-9]{3,6}$ ]] && (( $1 >= 4096 && $1 <= 1048576 )); }
# Avalon's llama-server takes 4096..262144, or auto (from the card's VRAM).
valid_avalon_context() { [[ $1 == auto ]] || { valid_target_context "$1" && (( $1 <= 262144 )); }; }
# avalon_auto_context VRAM_MIB: what AVALON_CONTEXT=auto gives (65536 when the
# card's memory is not known).
avalon_auto_context() {
  if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 19000 )); then echo 262144; else echo 65536; fi
}
# Kindi takes 4096..262144 here, or auto: its own profile for the card, which
# its engine then fits to the free card memory.
valid_kindi_context() { valid_avalon_context "$1"; }
# kindi_auto_context VRAM_MIB: the least KINDI_CONTEXT=auto gives on such a
# card (24576 on the CPU, a small card or when the card is not known; 65536
# from 7.5 GB, 131072 on an RTX 30 or newer with 9.5 GB).
kindi_auto_context() {
  if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 7500 )); then echo 65536; else echo 24576; fi
}

# gpu_vram_mib [ADDRESS]: a GPU's memory in MiB, or nothing when it is not known
# (its driver is not loaded yet). ADDRESS (0000:03:00.0) picks the card: an
# AMD card's from amdgpu's sysfs file, an NVIDIA card's from nvidia-smi.
# Without one, NVIDIA GPU 0 (the card the NVIDIA-only targets use).
gpu_vram_mib() {
  local address="${1,,}" sysfs="${HOST_PCI_SYSFS:-/sys/bus/pci/devices}" bytes bus mib
  [[ -z $address || $address == *:*:* ]] || address="0000:${address}"
  if [[ -n $address && -r $sysfs/$address/mem_info_vram_total ]]; then
    bytes="$(< "$sysfs/$address/mem_info_vram_total")"
    if [[ $bytes =~ ^[0-9]+$ ]] && (( bytes > 0 )); then echo $(( bytes / 1048576 )); return 0; fi
  fi
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  while IFS=', ' read -r bus mib; do
    [[ $mib =~ ^[0-9]+$ ]] || continue
    # nvidia-smi writes the domain with 8 digits (00000000:03:00.0).
    if [[ -z $address || ${bus,,} == *":${address#*:}" ]]; then echo "$mib"; return 0; fi
  done < <(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null)
  return 0
}
# target_vram NAME: the memory of the GPU a model target will use in MiB, cpu
# when it runs on the CPU, or nothing when that is not known yet.
target_vram() {
  local name="$1" card
  [[ -n "$(target_gpu_need "$name")" ]] || { echo cpu; return 0; }
  if target_gpu_prompted "$name"; then
    card="$(target_setting "$name" GPU_CARD)"
    if [[ ${card,,} == none || ( -z $card && "$(target_gpu_need "$name")" == optional ) ]]; then
      echo cpu; return 0
    fi
    [[ -z $card ]] || gpu_vram_mib "$card"
    return 0
  fi
  gpu_vram_mib
}
# context_recommendation NAME VRAM: TOKENS|REASON, the window to suggest for a
# model target. VRAM is target_vram's answer. The GPU sets a ceiling: Avalon
# and Xolotl by their upstream sizing (Avalon's auto rule; Xolotl's 128k on a
# 24 GB card), Strata, Basalt and Maya (hybrid or compressed attention, a small
# KV cache) from their card's size, and Ollama and llama.cpp more cautiously, as
# a full-attention model's KV cache grows fastest. Under that ceiling, 65536,
# or 131072 when Honcho is selected (its full budgets).
context_recommendation() {
  local name="$1" vram="$2" ceiling reason want=65536 why="the default"
  if [[ " ${TARGETS:-} " == *" honcho "* ]]; then want=131072; why="Honcho's full budgets"; fi
  if [[ $vram == cpu ]]; then
    ceiling=32768; reason="it runs on the CPU, where long prompts are slow"
  elif [[ ! $vram =~ ^[0-9]+$ ]]; then
    ceiling=65536; reason="its GPU's memory is not known yet"
  else
    case "$name" in
      avalon) ceiling="$(avalon_auto_context "$vram")" ;;
      kindi) ceiling="$(kindi_auto_context "$vram")" ;;
      xolotl) if (( vram >= 24000 )); then ceiling=131072; else ceiling=65536; fi ;;
      strata|basalt|maya)
        if (( vram >= 24000 )); then ceiling=131072
        elif (( vram >= 12000 )); then ceiling=65536
        else ceiling=32768; fi ;;
      *)
        if (( vram >= 48000 )); then ceiling=131072
        elif (( vram >= 16000 )); then ceiling=65536
        else ceiling=32768; fi ;;
    esac
    reason="its ${vram} MiB GPU fits about ${ceiling}"
  fi
  if (( want <= ceiling )); then
    echo "${want}|${why}; ${reason}"
  else
    echo "${ceiling}|${reason}; ${why} would use ${want}"
  fi
}
# context_agent_needs: one line for each selected agent that needs a minimum.
context_agent_needs() {
  local name
  for name in ${TARGETS:-}; do
    case "$name" in
      hermes) echo "  Hermes needs 64000 tokens or more; it does not use a server with less." ;;
      openclaw) echo "  OpenClaw needs 32768 tokens or more (65536 by default)." ;;
      honcho) echo "  Honcho fits its budgets to its model's window; 131072 or more runs its full budgets." ;;
      deepseek-harness) echo "  DeepSeek Harness needs 16384 tokens or more." ;;
      opencode) echo "  OpenCode needs 32768 tokens or more (65536 by default); it does not use a server with less." ;;
    esac
  done
}
# context_shortfall TOKENS: a warning for each selected agent that needs more.
context_shortfall() {
  if [[ " ${TARGETS:-} " == *" hermes "* ]] && (( $1 < 64000 )); then
    echo "    Note: Hermes will not use this server (it needs 64000 tokens or more)."
  fi
  if [[ " ${TARGETS:-} " == *" openclaw "* ]] && (( $1 < 32768 )); then
    echo "    Note: OpenClaw will not fit on this server (it needs 32768 tokens or more)."
  fi
  if [[ " ${TARGETS:-} " == *" opencode "* ]] && (( $1 < 32768 )); then
    echo "    Note: OpenCode will not use this server (it needs 32768 tokens or more)."
  fi
  return 0
}

# prompt_target_contexts: the context window of each selected model target,
# with a recommendation, then Honcho's and DeepSeek Harness's windows, which
# default to the smallest window chosen above. Asked after the GPU choices, so
# each recommendation knows its card. Presets (STRATA_CONTEXT, CONTEXT_SIZE,
# OLLAMA_CONTEXT_LENGTH, HONCHO_CONTEXT_TOKENS, ...) are the defaults.
prompt_target_contexts() {
  local name var vram rec reason default value smallest="" any=false
  for name in ${TARGETS:-}; do
    if target_context_var "$name" >/dev/null || [[ $name == honcho || $name == deepseek-harness ]]; then any=true; fi
  done
  [[ $any == true ]] || return 0
  echo
  echo "--- Context windows ---"
  echo "  A context window is the most tokens one request can hold: prompt, history,"
  echo "  tool definitions and reply. Every token costs GPU memory (the KV cache)."
  context_agent_needs
  for name in $TARGETS; do
    var="$(target_context_var "$name")" || continue
    vram="$(target_vram "$name")"
    IFS='|' read -r rec reason <<< "$(context_recommendation "$name" "$vram")"
    echo "  ${name}: ${rec} tokens recommended (${reason})."
    default="$(target_context_preset "$name")"
    if [[ $name == avalon ]]; then
      echo "    auto: 262144 with 19 GB of VRAM or more, else 65536."
      prompt_until_valid "    Context window (tokens, or auto)" "$var" "${default:-65536}" valid_avalon_context || return 1
    elif [[ $name == kindi ]]; then
      echo "    auto: Kindi's own size for the card (24576 to 131072), fitted to its free memory."
      prompt_until_valid "    Context window (tokens, or auto)" "$var" "${default:-auto}" valid_kindi_context || return 1
    else
      prompt_until_valid "    Context window (tokens)" "$var" "${default:-65536}" valid_target_context || return 1
    fi
    value="${!var}"
    if [[ $value == auto && $name == kindi ]]; then value="$(kindi_auto_context "$vram")"
    elif [[ $value == auto ]]; then value="$(avalon_auto_context "$vram")"; fi
    if [[ $name == llamacpp && $(llamacpp_slots) -gt 1 ]]; then
      echo "    llama.cpp shares CONTEXT_SIZE among its ${PARALLEL_SLOTS} slots: CONTEXT_SIZE=$(( value * $(llamacpp_slots) ))."
    fi
    context_shortfall "$value"
    if [[ -z $smallest ]] || (( value < smallest )); then smallest=$value; fi
  done
  if [[ " ${TARGETS} " == *" honcho "* ]]; then
    echo "  honcho: its budgets follow its chat model's context window. Give the window the"
    echo "    server behind HONCHO_MODEL serves${smallest:+ (the smallest above is ${smallest})}. Blank: Honcho's"
    echo "    own budgets, which need models that report 131072 tokens or more."
    prompt_until_valid "    Model context window" HONCHO_CONTEXT_TOKENS \
      "${HONCHO_CONTEXT_TOKENS-${smallest:-65536}}" valid_honcho_context_tokens || return 1
  fi
  if [[ " ${TARGETS} " == *" deepseek-harness "* ]]; then
    echo "  deepseek-harness: the context its OSR model serves${smallest:+ (the smallest above is ${smallest})}."
    prompt_until_valid "    Served context tokens" DEEPSEEK_HARNESS_CONTEXT_WINDOW \
      "${DEEPSEEK_HARNESS_CONTEXT_WINDOW:-${smallest:-65536}}" valid_dsh_context_tokens || return 1
  fi
}

# Strata's KV cache: int8 (8-bit keys and values, Strata's default and most
# precise), k8v4 (8-bit keys, 4-bit values: 23% smaller) or q4_0 (4-bit: 45%
# smaller, less precise on long documents). A smaller cache leaves room for more
# of the model on the GPU. Strata uses it above an 8192-token context.
valid_strata_kv() { [[ $1 == int8 || $1 == k8v4 || $1 == q4_0 ]]; }
# strata_model_ram_gb MODEL: the RAM (GB) Strata's setup counts for MODEL beside
# a streamed KV cache (its MODELS ram_gb at the tested commit); nothing for a
# model this installer does not know.
strata_model_ram_gb() {
  case "$1" in
    IQ1_M) echo 32 ;;
    Q2_0|IQ2_XS|UD-IQ4_XS|UD-Q4_K_XL) echo 48 ;;
    IQ3_XXS) echo 60 ;;
    IQ3_S) echo 62 ;;
  esac
}
# strata_target_model: the model Strata's provisioner installs (STRATA_MODEL, or
# STRATA_FAMILY's default).
strata_target_model() {
  case "${STRATA_FAMILY:-qwen}" in
    coder) echo "${STRATA_MODEL:-IQ1_M}" ;;
    unsloth) echo "${STRATA_MODEL:-UD-IQ4_XS}" ;;
    *) echo "${STRATA_MODEL:-IQ2_XS}" ;;
  esac
}
# strata_ct_memory_mib: the RAM assigned to Strata's CT in MiB: STRATA_MEMORY_MB
# (asked with its container settings and passed to the provisioner as
# MEMORY_MB), else the provisioner's default.
strata_ct_memory_mib() { echo "${STRATA_MEMORY_MB:-65536}"; }
# strata_kv_streams CONTEXT MODEL RAM_MIB: will Strata's setup keep the KV cache
# in RAM, with only a 32K-token window on the GPU? Its rule: from 65536 tokens,
# when the RAM (GiB) holds the model's RAM, the 8-bit cache (13 x 1056 bytes
# per token, in GB) and 1 GB more. Compared in integers.
strata_kv_streams() {
  local ram_gb
  [[ $1 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] && (( $1 >= 65536 )) || return 1
  ram_gb="$(strata_model_ram_gb "$2")"
  [[ -n $ram_gb ]] || return 1
  (( $3 * 1000000000 >= 1024 * ((ram_gb + 1) * 1000000000 + $1 * 13728) ))
}
# strata_kv_recommendation VRAM [CONTEXT MODEL RAM_MIB]: VALUE|REASON, the cache
# to suggest (Strata's provisioner suggests the same). VRAM is target_vram's
# answer. A cache streamed to RAM: int8 (the GPU holds only a 32K window, so the
# most precise cache costs it about 0.1 GB more). Otherwise by the card: below
# 24 GB (12 and 16 GB cards) k8v4, where every GB freed holds about 700 more
# experts on the GPU; on 24 and 32 GB cards, and when the card is not known,
# int8.
strata_kv_recommendation() {
  if strata_kv_streams "${2:-}" "${3:-}" "${4:-}"; then
    echo "int8|at this context the cache is kept in the CT's RAM with only a 32K window on the GPU"
  elif [[ ! $1 =~ ^[0-9]+$ ]]; then
    echo "int8|its GPU's memory is not known yet; int8 is Strata's default"
  elif (( $1 >= 24000 )); then
    echo "int8|its $1 MiB GPU has room for the most precise cache"
  else
    echo "k8v4|its $1 MiB GPU fits more of the model with a 23% smaller cache"
  fi
}
# prompt_strata_kv_cache: Strata's KV cache, with a suggestion from its GPU's
# memory. Asked after the context windows: a window of 8192 or less keeps
# Strata's 16-bit cache, so nothing is asked. A preset STRATA_KV is the default.
prompt_strata_kv_cache() {
  local vram rec reason
  [[ " ${TARGETS:-} " == *" strata "* ]] || return 0
  if [[ ${STRATA_CONTEXT:-} =~ ^[0-9]+$ ]] && (( STRATA_CONTEXT <= 8192 )); then return 0; fi
  vram="$(target_vram strata)"
  IFS='|' read -r rec reason <<< "$(strata_kv_recommendation "$vram" "${STRATA_CONTEXT:-65536}" \
    "$(strata_target_model)" "$(strata_ct_memory_mib)")"
  echo
  echo "--- Strata KV cache ---"
  echo "  How Strata stores the text it is working on (its context):"
  echo "    int8  8-bit keys and values: the most precise, Strata's default"
  echo "    k8v4  8-bit keys, 4-bit values: 23% smaller, more of the model fits on the GPU"
  echo "    q4_0  4-bit keys and values: 45% smaller, less precise on long documents"
  echo "  Suggested: k8v4 for 12 GB and 16 GB cards, int8 for 24 GB and 32 GB cards;"
  echo "    int8 on any card when the cache fits in the CT's RAM (from a 64K context)."
  echo "  strata: ${rec} recommended (${reason})."
  prompt_until_valid "    KV cache (int8, k8v4 or q4_0)" STRATA_KV "${STRATA_KV:-$rec}" valid_strata_kv || return 1
}
# prompt_strata_message_cache: Strata's opt-in message cache (STRATA_MESSAGE_CACHE):
# one more checkpoint before the last message of a prompt of 8192+ tokens, so an
# agent that rewrites its last message reuses the history. Not asked for a
# window of 8192 or less. A preset is the default; otherwise false, as upstream.
prompt_strata_message_cache() {
  [[ " ${TARGETS:-} " == *" strata "* ]] || return 0
  if [[ ${STRATA_CONTEXT:-} =~ ^[0-9]+$ ]] && (( STRATA_CONTEXT <= 8192 )); then return 0; fi
  echo
  echo "--- Strata message cache ---"
  echo "  One more checkpoint before the last message of a long conversation (8192+"
  echo "  tokens), so an agent that rewrites its last message does not make Strata read"
  echo "  the history again. Off upstream by default: it adds about 0.2 s to a fresh"
  echo "  long request."
  prompt_until_valid "    Message cache (true/false)" STRATA_MESSAGE_CACHE \
    "${STRATA_MESSAGE_CACHE:-false}" valid_bool || return 1
}

# target_default_port NAME: the API port a model target serves by default
# (Kindi keeps its own 8093; the other Strata-style targets use 8080).
target_default_port() { if [[ $1 == kindi ]]; then echo 8093; else echo 8080; fi; }
# target_server_entry NAME: the router's server entry for a model target.
target_server_entry() {
  local name="$1" prefix ip_var entry port_var
  prefix="$(target_var_prefix "$name")"
  ip_var="${prefix}_IP_CIDR"; port_var="${prefix}_PORT"
  entry="$(target_field "$name" entry)" || return 1
  [[ -n "$entry" ]] || return 1
  entry="${entry//@IP@/${!ip_var%/*}}"
  printf '%s\n' "${entry//@PORT@/${!port_var:-$(target_default_port "$name")}}"
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
  local name="$1" phase script id ip storage template image_variant hf_token="" gpu_env cuda_env context_env client_ips="" client
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
  if [[ $name == honcho ]]; then
    for client in hermes openclaw deepseek-harness opencode; do
      if [[ " ${TARGETS:-} " == *" ${client} "* ]]; then
        client_ips+="${client_ips:+ }$(target_setting "$client" IP_CIDR | cut -d/ -f1)"
      fi
    done
  fi
  [[ -n "$id" && -n "$ip" ]] || { echo "${name}: no CT ID or address was chosen." >&2; return 1; }
  case "$name" in
    ollama|airllm) flags=(--install-target) ;;
    llamacpp) if llamacpp_model_given; then flags=(--install-target); fi ;;
    open-terminal|hermes|openclaw|deepseek-harness|opencode) template="${template:-${TEMPLATE_REF:-}}" ;;
    honcho)
      if [[ -z $template && ${TEMPLATE_REF:-} == *:vztmpl/debian-13-* ]]; then
        template=$TEMPLATE_REF
      fi ;;
  esac
  local script_url script_sha channel="${MATTERMOST_CHANNEL:-osr-monitor}"
  script_url="$(target_setting "$name" COMMUNITY_SCRIPT_URL)"
  script_sha="$(target_setting "$name" COMMUNITY_SCRIPT_SHA256)"
  gpu_env="$(target_gpu_env "$name")"
  cuda_env="$(target_cuda_env "$name" "$template")"
  context_env="$(target_context_env "$name")"
  (
    local router_ct="$CT_ID" router_ip="${IP_CIDR%/*}" gateway="$GATEWAY" bridge="$BRIDGE" nameserver="$NAMESERVER"
    local webui_port="$OPENWEBUI_PORT" admin_token="${TARGET_ADMIN_TOKEN:-}"
    unset CT_ID CT_NAME CT_HOSTNAME IP_CIDR GATEWAY STORAGE BRIDGE NAMESERVER VLAN_TAG \
      CORES MEMORY MEMORY_MB SWAP SWAP_MB ROOTFS_GB ONBOOT TEMPLATE FIREWALL NONINTERACTIVE \
      ROUTER ROUTER_CT_ID ROUTER_SSH_HOST ROUTER_IP ROUTER_URL ROUTER_API_KEY \
      OPENWEBUI_PORT OPENWEBUI_ADMIN_TOKEN TARGET_ADMIN_TOKEN COMFYUI_IMAGE_VARIANT \
      HF_TOKEN TARGET_HF_TOKEN PVE_INTERACTIVE PVE_ROUTER_SUGGESTION
    export CT_ID="$id" IP_CIDR="$ip" GATEWAY="$gateway" STORAGE="$storage" BRIDGE="$bridge"
    # The installer already asked its questions and showed one summary: the
    # provisioner takes the defaults for the rest and does not ask to confirm.
    export PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false
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
    [[ -z "$context_env" ]] || export "${context_env?}"
    [[ "$name" != strata || -z ${STRATA_KV:-} ]] || export STRATA_KV
    [[ "$name" != strata || -z ${STRATA_MESSAGE_CACHE:-} ]] || export STRATA_MESSAGE_CACHE
    # The router's MEMORY is unset above; Strata gets the RAM chosen for its CT.
    [[ "$name" != strata || -z ${STRATA_MEMORY_MB:-} ]] || export MEMORY_MB="$STRATA_MEMORY_MB"
    if [[ "$phase" == gateway ]]; then
      # FreeLLMAPI hands its endpoint and key to the router CT itself, and
      # admits the router and the API access range to its one port.
      export ROUTER_CT_ID="$router_ct" FREELLMAPI_ADMIN_EMAIL="${FREELLMAPI_ADMIN_EMAIL:-admin@osr.local}"
      [[ -z ${API_ALLOW_CIDR:-} || -n ${FREELLMAPI_ACCESS_CIDR:-} ]] || export FREELLMAPI_ACCESS_CIDR="$API_ALLOW_CIDR"
    fi
    if [[ "$phase" == companion ]]; then
      export ROUTER_CT_ID="$router_ct" OPENWEBUI_PORT="$webui_port"
      if [[ "$name" == honcho ]]; then
        export ROUTER_IP="$router_ip" HONCHO_MODEL="${HONCHO_MODEL:-fast}"
        export HONCHO_CLIENT_IPS="${client_ips:-${HONCHO_CLIENT_IPS:-}}"
        # Set and empty: Honcho's own budgets (not the first install's 65536).
        [[ -z ${HONCHO_CONTEXT_TOKENS+set} ]] || export HONCHO_CONTEXT_TOKENS
      fi
      # Only the agents use Honcho, and only once its CT was provisioned.
      if [[ ( "$name" == hermes || "$name" == openclaw || "$name" == deepseek-harness || "$name" == opencode ) && "${HONCHO_READY:-false}" == true ]]; then
        local honcho_ct
        honcho_ct="$(target_setting honcho CT_ID)"
        export HONCHO_URL="http://${HONCHO_IP_CIDR%/*}:8000" HONCHO_CT_ID="$honcho_ct"
      fi
      # The same for Open Terminal: each agent gets its own workspace there,
      # with a client key the terminal CT issues.
      if [[ ( "$name" == hermes || "$name" == openclaw || "$name" == deepseek-harness || "$name" == opencode ) && "${OPEN_TERMINAL_READY:-false}" == true ]]; then
        local ot_ct ot_ip
        ot_ct="$(target_setting open-terminal CT_ID)"
        ot_ip="$(target_setting open-terminal IP_CIDR)"
        export OPEN_TERMINAL_URL="http://${ot_ip%/*}:${OPEN_TERMINAL_PORT:-8000}" OPEN_TERMINAL_CT_ID="$ot_ct"
      fi
      # DeepSeek Harness: its own Web UI for the access range, and its chat
      # endpoint registered in Open WebUI with the admin token (below). A run
      # without the token installs it without Open WebUI.
      if [[ "$name" == deepseek-harness ]]; then
        export DEEPSEEK_HARNESS_MODEL="${DEEPSEEK_HARNESS_MODEL:-auto}"
        export DEEPSEEK_HARNESS_CONTEXT_WINDOW="${DEEPSEEK_HARNESS_CONTEXT_WINDOW:-65536}"
        export DSH_ACCESS_CIDR="${DEEPSEEK_HARNESS_ACCESS_CIDR:-${API_ALLOW_CIDR:-$ip}}"
        if [[ ${TARGET_WEBUI_READY:-true} != true || -z "$admin_token" ]]; then
          export OPENWEBUI=false
          exec bash "$script" "${flags[@]}"
        fi
      fi
      # OpenCode: its own web UI for the access range, and its chat endpoint
      # registered in Open WebUI with the admin token (below).
      if [[ "$name" == opencode ]]; then
        export OPENCODE_MODEL="${OPENCODE_MODEL:-auto}"
        export OPENCODE_ACCESS_CIDR="${OPENCODE_ACCESS_CIDR:-${API_ALLOW_CIDR:-$ip}}"
      fi
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
        echo "Mattermost alerts go to its channel ${MATTERMOST_CHANNEL:-osr-monitor}." ;;
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
  local name id companions=false webui_companions=false webui_ready=true status=0
  local -a key_targets=()
  declare -A result=()
  HONCHO_READY=false OPEN_TERMINAL_READY=false TARGET_WEBUI_READY=true
  [[ -n "${TARGETS:-}" ]] || return 0
  for name in $TARGETS; do
    case "$(target_field "$name" phase)" in
      service)
        if [[ " ${SERVICES_DONE:-} " == *" ${name} "* ]]; then result[$name]="ok (created before OSR)"; fi
        continue ;;
      companion)
        companions=true webui_companions=true
        continue ;;
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
    if $webui_companions && ! { wait_for_openwebui && prompt_openwebui_admin_token; }; then
      webui_ready=false TARGET_WEBUI_READY=false
    fi
    # Honcho and Open Terminal first: the agents connect to both.
    local ordered=""
    for name in honcho open-terminal $TARGETS; do
      [[ " ${TARGETS} " == *" ${name} "* && " ${ordered} " != *" ${name} "* ]] || continue
      ordered+="${ordered:+ }${name}"
    done
    for name in $ordered; do
      [[ "$(target_field "$name" phase)" == companion ]] || continue
      if [[ $name != deepseek-harness ]] && ! $webui_ready; then
        result[$name]="skipped (no Open WebUI admin key)"
        continue
      fi
      echo
      echo "=== Target ${name} (CT $(target_setting "$name" CT_ID)) ==="
      if run_target_provisioner "$name"; then
        result[$name]=ok
        # DeepSeek Harness runs without Open WebUI when there is no admin key.
        [[ "$name" != deepseek-harness ]] || $webui_ready || result[$name]="ok (without Open WebUI)"
        [[ "$name" != honcho ]] || HONCHO_READY=true
        [[ "$name" != open-terminal ]] || OPEN_TERMINAL_READY=true
      else result[$name]=failed; fi
    done
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
      elif [[ ( "$name" == honcho || "$name" == hermes || "$name" == openclaw || "$name" == deepseek-harness || "$name" == opencode ) && "${result[$name]}" == failed ]]; then
        echo "                 see targets/${name}/README.md; if CT ${id} exists, resume on the Proxmox host with:"
        echo "                 CT_ID=${id} ROUTER_CT_ID=${CT_ID} bash targets/${name}/provision-lxc.sh --reconfigure"
      else
        echo "                 see targets/${name}/README.md; rerun targets/${name}/provision-lxc.sh"
      fi
    fi
  done
  echo "=============================================================================="
  return "$status"
}

# --- interactive configuration ----------------------------------------------
# The router's CT ID: a supplied CT_ID, else the cluster's next free ID, is the
# default (Enter takes it; NONINTERACTIVE=true uses it). A malformed or
# occupied ID is refused and re-asked (or stops unattended runs).
prompt_router_ct_id() {
  echo
  echo "--- Open Smart Router container ---"
  prompt_until_valid "OSR CT ID" CT_ID "${CT_ID:-$(next_free_ct_id)}" valid_router_ct_id
}
# Proxmox accepts guest IDs 100-999999999.
valid_router_ct_id() {
  [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] || { echo "  A CT ID is a whole number from 100 to 999999999." >&2; return 1; }
  ct_id_free "$1" || { echo "  CT $1 is already in use in this cluster." >&2; return 1; }
}

prompt_network_config() {
  echo
  echo "--- Container network ---"
  prompt_until_valid "Proxmox bridge"            BRIDGE     "$BRIDGE"     valid_nonempty || return 1
  prompt_until_valid "OSR IP address / CIDR"     IP_CIDR    "$IP_CIDR"    valid_cidr || return 1
  prompt_until_valid "Gateway IP"                GATEWAY    "$GATEWAY"    valid_ipv4 || return 1
  prompt_until_valid "DNS nameserver (blank = inherit host)" \
                                                 NAMESERVER "$NAMESERVER" valid_optional_ipv4 || return 1
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
    echo "  The channel name is the URL handle (osr-monitor), not the display"
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
  echo "--- Model servers ---"
  while true; do
    if [[ "$NONINTERACTIVE" == "true" ]]; then
      count="$MODEL_SERVER_COUNT"
    else
      read -r -p "How many model servers? (${MODEL_SERVER_MIN}-${MODEL_SERVER_MAX}) [${MODEL_SERVER_COUNT}]: " count
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
    prompt_until_valid "  Server ${i} (IP, host:port, URL, lmstudio://host, strata://host, basalt://host, maya://host, xolotl://host, avalon://host or kindi://host)" \
      raw "$default_addr" valid_ollama_addr || return 1
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

  # GITEA_VERIFY_TLS (false unless preset to true, see the top of the script)
  # is settled before init_gitea_curl_opts, so the credential check, the repo
  # resolution, the seeding API calls and the container's `git clone` all use
  # the same setting.
  [[ "$GITEA_VERIFY_TLS" == "true" ]] || GITEA_VERIFY_TLS=false

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
    run_ct runuser -u osr-router -- "$candidate" -c '' >/dev/null 2>&1
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
  # osr-router, so it must be readable/executable by non-root.
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
    echo "NOTE: TLS verification disabled for Gitea (GITEA_VERIFY_TLS=false); set" >&2
    echo "      GITEA_VERIFY_TLS=true once its certificate is trusted on this host." >&2
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
          echo "         run again without GITEA_VERIFY_TLS=true (verification off)." >&2
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
  # The body goes to curl on stdin, never on its command line: Linux limits a
  # single argument to 128 KiB, which a large file's base64 content exceeds.
  if [[ -n "$data" ]]; then
    printf '%s' "$data" |
      curl -sS "${GITEA_CURL_OPTS[@]}" -X "$method" -H "$auth" -H 'Content-Type: application/json' \
        --data-binary @- -w $'\n%{http_code}' "$url" 2>/dev/null || true
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

# Move a repository's pre-rename service directories (LEGACY_SERVICE_DIRS)
# through the contents API. Before seeding, move operator-owned files such as
# router.ini and monitor.ini so their tuned copies win. After seeding, remove
# installer-owned old paths only when their new copies exist. Uses $api, $auth
# and $owner from seed_gitea_repo.
migrate_gitea_service_dirs() {
  local phase="$1" pair old new resp http body path sha name new_rel payload failed=0
  local repo="${api}/repos/${owner}/${GITEA_REPO_NAME}/contents"
  for pair in "${LEGACY_SERVICE_DIRS[@]}"; do
    old="services/${pair%%:*}"; new="services/${pair#*:}"
    resp="$(gitea_api GET "${repo}/${old}")"
    http="${resp##*$'\n'}"
    [[ "$http" == "200" ]] || continue
    body="${resp%$'\n'*}"
    while IFS=$'\t' read -r path sha; do
      [[ -n "$path" && -n "$sha" ]] || continue
      name="${path##*/}"
      [[ "$name" != "${pair%%:*}.service" ]] || name="${pair#*:}.service"
      new_rel="${new}/${name}"
      if is_installer_owned "$new_rel"; then
        [[ "$phase" == after ]] || continue
        resp="$(gitea_api GET "${repo}/${new_rel}")"
        http="${resp##*$'\n'}"
        if [[ "$http" != "200" ]]; then
          echo "  WARNING: ${new_rel} is not present (HTTP ${http}); ${path} left in place." >&2
          failed=$((failed + 1)); continue
        fi
      else
        [[ "$phase" == before ]] || continue
        resp="$(gitea_api GET "${repo}/${new_rel}")"
        http="${resp##*$'\n'}"
        if [[ "$http" == "404" ]]; then
          resp="$(gitea_api GET "${repo}/${path}")"
          http="${resp##*$'\n'}"
          if [[ "$http" == "200" ]]; then
            payload="$(printf '%s' "${resp%$'\n'*}" | python3 -c '
import json, sys
meta = json.load(sys.stdin)
print(json.dumps({"message": "Move %s to %s (renamed)" % (sys.argv[1], sys.argv[2]),
                  "content": (meta.get("content") or "").replace("\n", "")}))' "$path" "$new_rel")" || http=000
            [[ "$http" != "200" ]] || { resp="$(gitea_api POST "${repo}/${new_rel}" "$payload")"; http="${resp##*$'\n'}"; }
          fi
          if [[ "$http" != "201" ]]; then
            echo "  WARNING: could not move ${path} to ${new_rel} (HTTP ${http}); left in place." >&2
            failed=$((failed + 1)); continue
          fi
          echo "  moved: ${path} -> ${new_rel}" >&2
        elif [[ "$http" != "200" ]]; then
          echo "  WARNING: could not check ${new_rel} (HTTP ${http}); ${path} left in place." >&2
          failed=$((failed + 1)); continue
        fi
      fi
      payload="$(python3 -c 'import json, sys
print(json.dumps({"message": "Remove %s (renamed to %s)" % (sys.argv[1], sys.argv[2]), "sha": sys.argv[3]}))' \
        "$path" "$new_rel" "$sha")"
      resp="$(gitea_api DELETE "${repo}/${path}" "$payload")"
      http="${resp##*$'\n'}"
      if [[ "$http" == "200" || "$http" == "204" ]]; then
        echo "  removed: ${path} (now ${new_rel})" >&2
      else
        echo "  WARNING: could not remove ${path} (HTTP ${http})." >&2
        failed=$((failed + 1))
      fi
    done < <(printf '%s' "$body" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in items if isinstance(items, list) else []:
    if item.get("type") == "file":
        print("%s\t%s" % (item.get("path", ""), item.get("sha", "")))')
  done
  (( failed == 0 ))
}

# Push the generated tree to the repo via the Gitea contents API.
#   * a file the repo lacks is created (anything you committed by hand wins);
#   * an INSTALLER-OWNED code file that differs is updated in place, when
#     CONFIG_UPDATE_CODE=true, so a re-install never leaves stale code behind.
# $2 is the deploy token.
seed_gitea_repo() {
  local tree="$1" token="$2"
  local base api auth owner resp http body sha rel payload
  local created=0 skipped=0 updated=0 failed=0
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

  # First move what the repo still has under the pre-rename names, so the
  # operator's tuned files are found at the new paths and not seeded over.
  migrate_gitea_service_dirs before || failed=$((failed + 1))

  # Walk the generated tree deterministically.
  while IFS= read -r rel; do
    resp="$(gitea_api GET "${api}/repos/${owner}/${GITEA_REPO_NAME}/contents/${rel}")"
    http="${resp##*$'\n'}"
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
      # The content reaches python on stdin, not as an argument (see gitea_api).
      payload="$(base64 -w0 < "${tree}/${rel}" | python3 -c '
import json,sys
print(json.dumps({"message": "Update %s from installer" % sys.argv[1],
                  "content": sys.stdin.read(), "sha": sys.argv[2]}))' "$rel" "$sha")"
      resp="$(gitea_api PUT "${api}/repos/${owner}/${GITEA_REPO_NAME}/contents/${rel}" "$payload")"
      http="${resp##*$'\n'}"
      if [[ "$http" == "200" ]]; then
        updated=$((updated + 1))
        echo "  updated: ${rel}" >&2
      else
        echo "  WARNING: failed to update ${rel} (HTTP ${http})" >&2
        failed=$((failed + 1))
      fi
      continue
    fi
    payload="$(base64 -w0 < "${tree}/${rel}" | python3 -c '
import json,sys
print(json.dumps({"message": "Seed %s from installer" % sys.argv[1],
                  "content": sys.stdin.read()}))' "$rel")"
    resp="$(gitea_api POST "${api}/repos/${owner}/${GITEA_REPO_NAME}/contents/${rel}" "$payload")"
    http="${resp##*$'\n'}"
    if [[ "$http" == "201" ]]; then
      created=$((created + 1))
      echo "  seeded: ${rel}" >&2
    else
      echo "  WARNING: failed to seed ${rel} (HTTP ${http})" >&2
      failed=$((failed + 1))
    fi
  done < <(cd "$tree" && find . -type f -printf '%P\n' | sort)

  migrate_gitea_service_dirs after || failed=$((failed + 1))

  echo "Repo seeding complete: ${created} created, ${updated} updated, ${skipped} already present, ${failed} failed." >&2
  (( failed == 0 ))
}

# verify_config_clone TREE: the installer-owned files in the CT's clone must be
# the ones this installer generated in TREE. Seeding can fail file by file, and
# a clone without them would install without the management tool (no
# manage-model-servers on PATH) or without LiteLLM's hash lock. A file that
# differs only counts when CONFIG_UPDATE_CODE=true, since otherwise the repo's
# own version is kept on purpose.
verify_config_clone() {
  local tree="$1" rel want hash
  local -a missing=() stale=()
  local -A remote=()
  while read -r hash rel; do
    [[ -n "$rel" ]] && remote["$rel"]="$hash"
  done < <(run_ct bash -c 'cd "$1" || exit 0; shift; for f; do [ -f "$f" ] && sha256sum -- "$f"; done; exit 0' \
             _ "$CONFIG_REPO_DIR" "${INSTALLER_OWNED_CODE[@]}")
  for rel in "${INSTALLER_OWNED_CODE[@]}"; do
    [[ -f "${tree}/${rel}" ]] || continue
    want="$(sha256sum < "${tree}/${rel}" | cut -d' ' -f1)"
    if [[ -z "${remote[$rel]:-}" ]]; then
      missing+=("$rel")
    elif [[ "${remote[$rel]}" != "$want" && "$CONFIG_UPDATE_CODE" == "true" ]]; then
      stale+=("$rel")
    fi
  done
  local pair
  for pair in "${LEGACY_SERVICE_DIRS[@]}"; do
    if run_ct test -d "${CONFIG_REPO_DIR}/services/${pair%%:*}"; then
      echo "WARNING: the config repository still has services/${pair%%:*} (renamed services/${pair#*:});" >&2
      echo "         its unit is not installed. Move any file you changed there to services/${pair#*:}." >&2
    fi
  done
  (( ${#missing[@]} + ${#stale[@]} )) || return 0
  echo "ERROR: the config repository clone in ${CONFIG_REPO_DIR} is incomplete." >&2
  (( ${#missing[@]} == 0 )) || printf '  missing: %s\n' "${missing[@]}" >&2
  (( ${#stale[@]} == 0 )) || printf '  not updated: %s\n' "${stale[@]}" >&2
  echo "Seeding them into ${GITEA_OWNER}/${GITEA_REPO_NAME} failed; see the warnings above." >&2
  return 1
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
# Returns as resolve_gitea_repo_named. When the default name is not found, the
# name it had before the rename (GITEA_REPO_LEGACY_NAME) is looked up the same
# way; a repository found there becomes GITEA_REPO_NAME, so its committed
# configuration is used rather than a new, empty repository seeded with
# defaults. An ambiguous or failed lookup of the old name returns 1: creating
# a repository beside one that may hold the configuration would hide it.
resolve_gitea_repo() {
  local token="$1" rc=0 wanted="$GITEA_REPO_NAME" owner="$GITEA_OWNER"
  resolve_gitea_repo_named "$token" || rc=$?
  [[ "$rc" == "2" && -n "${GITEA_REPO_LEGACY_NAME:-}" \
     && "$wanted" == "${GITEA_REPO_DEFAULT_NAME:-}" \
     && "$wanted" != "$GITEA_REPO_LEGACY_NAME" ]] || return "$rc"
  rc=0
  GITEA_REPO_NAME="$GITEA_REPO_LEGACY_NAME"
  resolve_gitea_repo_named "$token" >/dev/null || rc=$?
  case "$rc" in
    0)
      echo "NOTE: no repository is named ${wanted}; using ${GITEA_OWNER}/${GITEA_REPO_NAME}," >&2
      echo "      the configuration repository from before the rename. To move to the" >&2
      echo "      new name, rename it in Gitea (and update the remote of /app/config-repo" >&2
      echo "      in the router CT). GITEA_REPO_LEGACY_NAME= ignores the old repository." >&2
      return 0 ;;
    2)
      GITEA_REPO_NAME="$wanted"; GITEA_OWNER="$owner"
      return 2 ;;
  esac
  echo "WARNING: ${wanted} does not exist, and the pre-rename repository" >&2
  echo "         ${GITEA_REPO_NAME} could not be resolved (see above). Set GITEA_REPO_NAME" >&2
  echo "         (and GITEA_REPO_OWNER) to the repository to use, or" >&2
  echo "         GITEA_REPO_LEGACY_NAME= to ignore the old one." >&2
  GITEA_REPO_NAME="$wanted"; GITEA_OWNER="$owner"
  return 1
}

# Look GITEA_REPO_NAME up, and set GITEA_OWNER to its real owner.
# Without this, a repo that lives under an organisation (or another account)
# would 404 against the token owner and a duplicate would be created silently.
# Returns: 0 = found and GITEA_OWNER set, 2 = does not exist anywhere the token
# can see (caller should create it), 1 = ambiguous or an explicit owner missed.
resolve_gitea_repo_named() {
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
      repo_name="$GITEA_REPO_NAME"   # the pre-rename repository may have been chosen
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
      payload="$(printf '{"name":"%s","private":%s,"auto_init":true,"default_branch":"main","description":"Provisioned by the open-smart-router installer"}' \
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
  content_b64="$(printf 'Provisioning test commit\nCreated (UTC): %s\nProxmox host: %s\nService: open-smart-router\n' \
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
prompt_network_config || exit 1
prompt_storage_config
prompt_template_storage || exit 1
echo "Updating Proxmox appliance template index."
pveam update
select_router_template || exit 1
prompt_target_settings || exit 1
# Which GPU each AMD/Intel-capable target gets, then the host driver for every
# chosen card: set up now, when missing, before anything is created (a reboot
# then costs nothing but a rerun).
prompt_target_gpus || exit 1
# Each model target's context window, recommended from its GPU and the agents.
prompt_target_contexts || exit 1
# Strata's KV cache precision (suggested from its context, CT memory and GPU)
# and its opt-in message cache.
prompt_strata_kv_cache || exit 1
prompt_strata_message_cache || exit 1
prepare_host_gpu || exit 1
# Root SSH between the cluster's nodes, for later upgrades from any node.
prepare_cluster_ssh || exit 1
# Gitea and Mattermost, if selected, are created now: the prompts below take
# their URL, token and webhook.
provision_service_targets || exit 1

# Ask for the Gitea URL, username + auth token and verify them against the
# server. GITEA_DEPLOY_TOKEN may be preset in the environment for unattended
# runs, in which case only the username prompt appears.
prompt_gitea_credentials

prompt_mattermost_config
preset_target_model_servers
prompt_model_servers || exit 1

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
  -tags "ai;ai-tools;osr-router;openwebui"
  -start 1
)
[[ -n "$NAMESERVER" ]] && create_args+=(-nameserver "$NAMESERVER")
# Proxmox inherits the caller's umask while extracting an unprivileged CT.
(umask 022; pct create "${create_args[@]}")
CT_CREATED=1

wait_for_ct_ready

echo "Setting container root password."
printf 'root:%s\n' "$ROOT_PASSWORD" | pct exec "$CT_ID" -- chpasswd
unset ROOT_PASSWORD

echo "Installing base packages inside container."
apt_get update
apt_get install -y python3 python3-pip python3-venv curl ca-certificates

echo "Creating application user and directories."
run_ct groupadd --system osr-router
run_ct useradd --system --gid osr-router --home-dir /app/router --shell /usr/sbin/nologin osr-router
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
  "${REPO_DIR}/services/osr-router" \
  "${REPO_DIR}/services/litellm-proxy" \
  "${REPO_DIR}/services/osr-monitor" \
  "${REPO_DIR}/services/open-webui" \
  "${REPO_DIR}/env" \
  "${REPO_DIR}/install"

# --- env/router.env ---
# Shared by the router, litellm-proxy and monitor units (they run from one venv).
# Backend URLs are per-tier so the monitor can probe each Ollama box directly.
# Every key written here is read by the router, the monitor or
# manage-model-servers (tests/test-repo.sh checks that, and that env/router.env
# in the repository shows the same keys). How the services behave is tuned in
# router.ini and monitor.ini, not here.
cat > "${REPO_DIR}/env/router.env" <<EOF
# Where things are, for the router, LiteLLM and the monitor. How they behave
# is tuned in services/osr-router/router.ini and
# services/osr-monitor/monitor.ini. No secrets: tokens, the webhook and keys
# live in /app/router/secrets.env (see manage-model-servers set-token,
# set-webhook, set-api-key, set-cloud-key).
GITEA_SERVER_URL=${GITEA_SERVER_URL}
GITEA_ADMIN_USER=${GITEA_ADMIN_USER}
GITEA_VERIFY_TLS=${GITEA_VERIFY_TLS}
MATTERMOST_MONITOR_USER=${MATTERMOST_MONITOR_USER}
MATTERMOST_CHANNEL=${MATTERMOST_CHANNEL}
MATTERMOST_VERIFY_TLS=${MATTERMOST_VERIFY_TLS}
LITELLM_BASE_URL=http://127.0.0.1:4000
# Explicit cloud models (provider model IDs, comma-separated), set with
# manage-model-servers set-cloud-models. Empty keeps a provider off; cloud
# models are never chosen by auto routing.
CLOUD_OPENAI_MODELS=
CLOUD_ANTHROPIC_MODELS=
CLOUD_GEMINI_MODELS=
# FreeLLMAPI server (targets/freellmapi), set with manage-model-servers
# set-freellmapi: its root URL. Its models are offered as freellmapi/<id> and,
# like the cloud models, never chosen by auto routing. FREELLMAPI_MODELS:
# available lists every model it can serve now, auto only freellmapi/auto.
FREELLMAPI_BASE_URL=
FREELLMAPI_MODELS=available
# Optional separate LiteLLM gateway for signed-in Codex and Claude Code
# clients: its root URL (HTTPS, or loopback HTTP).
SUBSCRIPTION_GATEWAY_BASE_URL=
# Model servers, and which of them serves each tier (manage-model-servers
# add, remove, set-tier, set-model).
BACKEND_FAST=$(indices_to_urls "$TIER_FAST_IDX")
BACKEND_MEDIUM=$(indices_to_urls "$TIER_MEDIUM_IDX")
BACKEND_LARGE=$(indices_to_urls "$TIER_LARGE_IDX")
BACKEND_XLARGE=$(indices_to_urls "$TIER_XLARGE_IDX")
MODEL_SERVERS=$(IFS=,; printf '%s' "${MODEL_SERVERS[*]}")
MODEL_FAST=${MODEL_FAST}
MODEL_MEDIUM=${MODEL_MEDIUM}
MODEL_LARGE=${MODEL_LARGE}
MODEL_XLARGE=${MODEL_XLARGE}
# How long Ollama keeps a model loaded (manage-model-servers set-keepalive).
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
TORCH_CPU_ONLY=${TORCH_CPU_ONLY}
OPENWEBUI_HEALTH_URL=http://127.0.0.1:${OPENWEBUI_PORT}/health
EOF
# The monitor's settings live in monitor.ini. A keep-alive refresh asked for at
# install is the one exception: it is written as an override, since monitor.ini
# is seeded as it stands. The default is left to the file.
if [[ "$KEEP_ALIVE_REFRESH_SECONDS" != "240" ]]; then
  printf 'KEEP_ALIVE_REFRESH_SECONDS=%s\n' "$KEEP_ALIVE_REFRESH_SECONDS" >> "${REPO_DIR}/env/router.env"
fi
# --- secrets.env (NOT part of the repo tree) ---
# The deploy token and the webhook URL (whose path is itself a credential) never
# enter the config repo. They are pushed straight into the container as
# /app/router/secrets.env (0640 root:osr-router) after apply-config.sh runs,
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
cat > "${REPO_DIR}/services/osr-router/router.py" <<'PYEOF'
import asyncio
import configparser
import contextvars
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import time
from collections import OrderedDict
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, HTTPException, Request
from starlette.background import BackgroundTask
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.datastructures import Headers

logging.basicConfig(level=os.getenv("ROUTER_LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("router")
# httpx logs every request at INFO; the router logs its own decisions instead.
logging.getLogger("httpx").setLevel(logging.WARNING)

# --- request IDs ---------------------------------------------------------------
# Every request has an ID: the caller's X-Request-ID when it sends a plain one,
# else a new one. It is returned as X-Router-Request-ID (and as X-Request-ID
# unless the upstream answer already carries its own), sent upstream as
# X-Request-ID, and put in front of every line the router logs for the request,
# so one grep finds the routing decision, the failovers and the backend's side.
_REQUEST_ID = contextvars.ContextVar("osr_request_id", default="")
_REQUEST_ID_OK = re.compile(r"[A-Za-z0-9._:-]{1,64}")


def request_id() -> str:
    """The ID of the request being handled, or "" outside one (discovery)."""
    return _REQUEST_ID.get()


def accept_request_id(supplied) -> str:
    """A caller's X-Request-ID when it is a plain token of up to 64 characters;
    otherwise (none, too long, or with characters that could confuse a log or a
    header) a new random one."""
    if supplied and _REQUEST_ID_OK.fullmatch(supplied):
        return supplied
    return secrets.token_hex(8)


class _RequestIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        current = _REQUEST_ID.get()
        if current:
            record.msg = "[%s] %s" % (current, record.msg)
        return True


# The logger outlives a reload of this module (the tests load it many times).
log.filters[:] = [f for f in log.filters if type(f).__name__ != "_RequestIdFilter"]
log.addFilter(_RequestIdFilter())

# --- metrics ---------------------------------------------------------------------
# Counters and histograms behind GET /metrics, in Prometheus text format, kept
# in this process (they start again at zero with the router). Label values come
# from the router's own configuration and inventory (servers, models, classes,
# statuses), never from what a client sent, so the number of series is bounded.
_STARTED = time.time()
_COUNTERS = {}      # (name, ((label, value), ...)) -> count
_HISTOGRAMS = {}    # (name, ((label, value), ...)) -> [per-bucket counts..., sum, count]
DURATION_BUCKETS = (0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0)
METRIC_SERIES_MAX = 5000   # a last guard; never reached with bounded labels
METRICS = {
    "osr_requests_total": ("counter", "Requests answered, by route (chat, v1, routing), "
                           "how they were served and the HTTP status returned."),
    "osr_upstream_failures_total": ("counter", "Attempts on a model server that failed, by reason: "
                                    "connect, transport, no_reply, http_<status>, tool_rejection."),
    "osr_response_start_seconds": ("histogram", "Chat requests answered below 400: seconds from "
                                   "arrival until the response headers were sent (model load and "
                                   "prompt processing included, where the server waits for them)."),
    "osr_request_duration_seconds": ("histogram", "Chat requests answered below 400: seconds from "
                                     "arrival until the last byte of the body was sent."),
    "osr_in_flight_requests": ("gauge", "Requests this router has in flight on a model server."),
    "osr_server_up": ("gauge", "1 when the last discovery poll (or dispatch) found the server up, else 0."),
    "osr_server_models": ("gauge", "Models the server listed at the last discovery poll."),
    "osr_inventory_age_seconds": ("gauge", "Seconds since the inventory was last refreshed."),
    "osr_remembered_conversations": ("gauge", "Conversations whose last server is remembered (affinity)."),
    "osr_start_time_seconds": ("gauge", "Unix time at which this router process started."),
}


def count(name: str, **labels) -> None:
    """Add one to a counter."""
    key = (name, tuple(sorted(labels.items())))
    if key in _COUNTERS or len(_COUNTERS) < METRIC_SERIES_MAX:
        _COUNTERS[key] = _COUNTERS.get(key, 0) + 1


def observe(name: str, seconds: float, **labels) -> None:
    """Record one duration in a histogram."""
    key = (name, tuple(sorted(labels.items())))
    series = _HISTOGRAMS.get(key)
    if series is None:
        if len(_HISTOGRAMS) >= METRIC_SERIES_MAX:
            return
        series = _HISTOGRAMS[key] = [0] * len(DURATION_BUCKETS) + [0.0, 0]
    for index, bound in enumerate(DURATION_BUCKETS):
        if seconds <= bound:
            series[index] += 1
            break
    series[-2] += seconds
    series[-1] += 1


def _label_text(labels, extra: str = "") -> str:
    """{a="b",...} for a series, values escaped as the text format requires."""
    parts = ['%s="%s"' % (name, str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n"))
             for name, value in labels]
    if extra:
        parts.append(extra)
    return "{%s}" % ",".join(parts) if parts else ""


def _number(value) -> str:
    return str(int(value)) if float(value).is_integer() else repr(float(value))

# The router is a drop-in OpenAI endpoint in front of the LiteLLM proxy.
# /v1/chat/completions has its model chosen by complexity analysis; every other
# /v1/* path (notably /v1/models, which Open WebUI calls to populate its model
# list) is proxied through unchanged unless the caller explicitly selects the
# optional subscription gateway.
LITELLM_BASE = os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_URL = os.getenv("LITELLM_URL", f"{LITELLM_BASE}/v1/chat/completions")

# Optional newer LiteLLM gateway for per-client subscription logins. The
# built-in pinned LiteLLM remains the local/API-key path.
SUBSCRIPTION_GATEWAY_BASE = (os.getenv("SUBSCRIPTION_GATEWAY_BASE_URL") or "").rstrip("/")
if SUBSCRIPTION_GATEWAY_BASE:
    try:
        _subscription_url = urlsplit(SUBSCRIPTION_GATEWAY_BASE)
        _subscription_valid = (
            (_subscription_url.scheme == "https" or
             (_subscription_url.scheme == "http" and _subscription_url.hostname in
              ("localhost", "127.0.0.1", "::1")))
            and bool(_subscription_url.hostname)
            and (_subscription_url.port is None or _subscription_url.port > 0)
            and not (_subscription_url.path or _subscription_url.username or
                     _subscription_url.password or _subscription_url.query or
                     _subscription_url.fragment))
    except ValueError:
        _subscription_valid = False
    if not _subscription_valid:
        log.error("invalid SUBSCRIPTION_GATEWAY_BASE_URL: use HTTPS or loopback HTTP root URL")
        SUBSCRIPTION_GATEWAY_BASE = ""

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
        # Server kinds listed at /v1/models whose text models are reported
        # tool-capable. Their APIs say nothing per model, but each of these
        # servers parses "tools" and returns OpenAI tool_calls. A kind left
        # out is reported unknown. Blank: none.
        "tool_kinds": "strata, basalt, maya, xolotl, avalon, kindi",
    },
    "http": {
        # Seconds to establish a TCP connection to a backend. Short on purpose:
        # this is how long a dead host delays failover to the next candidate.
        "connect_timeout_seconds": "3",
        # Seconds allowed between bytes of a response (generation can be slow).
        "read_timeout_seconds": "300",
        # The same for Kindi, which serves one request at a time and reads a
        # long prompt slowly on a small card (its agent guide: 30-60 minutes).
        # Never below read_timeout_seconds.
        "kindi_read_timeout_seconds": "3600",
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
        # How long an /api/show answer is kept for a model the server lists
        # with a digest (see SHOW_CACHE_SECONDS below).
        "show_cache_seconds": "3600",
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
        # Bonus for a model that is already resident in memory (LM Studio and
        # the Strata-style servers report it per model, Ollama through /api/ps).
        "loaded_bonus": "0.1",
        # Bonus, on a tool request, for a model the server reports as
        # tool-capable over one whose tool support is unknown.
        "tool_match": "0.3",
    },
    # How load is spread once the scores have been compared.
    "balancing": {
        # Taken off a candidate's score for each request this router has in
        # flight on its server. 0 turns load awareness off.
        "busy_penalty": "0.03",
        # How long a conversation prefers the server and model that answered
        # it last, among equally good candidates. 0 turns it off.
        "sticky_seconds": "1800",
    },
    # Sizes for exact model ids that an OpenAI-compatible server (Strata,
    # Basalt, Maya, Xolotl, Avalon) lists without a parameter count. Matching is by the whole
    # id, case-insensitive, so variants and aliases stay unknown-size unless
    # given a line of their own. A blank value removes a built-in entry.
    "model_sizes": {
        "strata": "125B",               # Strata's default id: Qwen3.8-Flash-Next
        "qwen3.8-flash-next": "125B",   # Basalt's default alias
        # Strata's qwen family ids, qwen3.8-flash-next-<quant>: one 125B model.
        "qwen3.8-flash-next-q2_0": "125B",
        "qwen3.8-flash-next-iq2_xs": "125B",
        "qwen3.8-flash-next-iq3_xxs": "125B",
        "qwen3.8-flash-next-iq3_s": "125B",
        "glm-5.3-flash": "321B",        # Project Maya (GLM-5.3-Flash, 321B total)
        "deepseek-v4.1-flash": "552B",  # Xolotl's default id (DeepSeek-V4.1-Flash, 552B total)
        "qwen3.8-flash-next-avalon": "125B",  # Avalon's default alias (Qwen3.8-Flash-Next)
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

# Cloud models are explicit choices. They are never mixed into local discovery
# or automatic routing, which could otherwise incur API charges unexpectedly.
CLOUD_PROVIDERS = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "gemini": "GEMINI_API_KEY",
}
CLOUD_MODELS = {
    f"{provider}/{model.strip()}": provider
    for provider, key in CLOUD_PROVIDERS.items()
    if (os.getenv(key) or "").strip()
    for model in (os.getenv(f"CLOUD_{provider.upper()}_MODELS") or "").split(",")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", model.strip())
}

# FreeLLMAPI (targets/freellmapi) fronts the free tiers of cloud providers with
# one OpenAI-compatible endpoint and one key. Like the cloud models above it is
# an explicit choice: a request must name freellmapi/<id> (freellmapi/auto lets
# FreeLLMAPI pick), and it is never part of local discovery, "auto", the tier
# aliases or LiteLLM's fallbacks. Its prompts leave the network.
FREELLMAPI_PREFIX = "freellmapi/"
FREELLMAPI_BASE = (os.getenv("FREELLMAPI_BASE_URL") or "").strip().rstrip("/")
FREELLMAPI_KEY = (os.getenv("FREELLMAPI_API_KEY") or "").strip()
if FREELLMAPI_BASE:
    try:
        _freellmapi_url = urlsplit(FREELLMAPI_BASE)
        _freellmapi_ok = (_freellmapi_url.scheme in ("http", "https")
                          and bool(_freellmapi_url.hostname)
                          and not (_freellmapi_url.username or _freellmapi_url.password
                                   or _freellmapi_url.path or _freellmapi_url.query
                                   or _freellmapi_url.fragment))
        _freellmapi_url.port  # noqa: B018 - raises on a bad port
    except ValueError:
        _freellmapi_ok = False
    if not _freellmapi_ok:
        log.warning("ignoring FREELLMAPI_BASE_URL: use the root URL, e.g. http://10.0.0.20:3001")
        FREELLMAPI_BASE = ""
FREELLMAPI_ENABLED = bool(FREELLMAPI_BASE and FREELLMAPI_KEY)
if FREELLMAPI_BASE and not FREELLMAPI_KEY:
    log.warning("FREELLMAPI_BASE_URL is set without FREELLMAPI_API_KEY; freellmapi/ models are off")
# available: list every model FreeLLMAPI can serve now; auto: only its own
# routing entries (freellmapi/auto and the like).
FREELLMAPI_MODELS = (os.getenv("FREELLMAPI_MODELS") or "available").strip().lower()
if FREELLMAPI_MODELS not in ("available", "auto"):
    log.warning("ignoring FREELLMAPI_MODELS=%r (use available or auto)", FREELLMAPI_MODELS)
    FREELLMAPI_MODELS = "available"
FREELLMAPI_REFRESH = 300.0
_FREELLMAPI_LIST = {"at": 0.0, "ids": ["auto"]}
_FREELLMAPI_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@/+-]{0,199}")


def freellmapi_headers() -> dict:
    return {"Authorization": f"Bearer {FREELLMAPI_KEY}"}


async def freellmapi_models() -> list:
    """Model ids FreeLLMAPI serves now, without the prefix, refreshed at most
    every FREELLMAPI_REFRESH seconds. "auto" is always first, so the entry
    stays selectable while FreeLLMAPI is down or has no provider key yet; a
    failed refresh keeps the previous list."""
    now = time.monotonic()
    if _FREELLMAPI_LIST["at"] and now - _FREELLMAPI_LIST["at"] < FREELLMAPI_REFRESH:
        return _FREELLMAPI_LIST["ids"]
    _FREELLMAPI_LIST["at"] = now
    try:
        response = await http_client().get(
            f"{FREELLMAPI_BASE}/v1/models", params={"available": "true"},
            headers=freellmapi_headers(), timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        ids = ["auto"]
        for entry in (response.json().get("data") or []):
            name = str(entry.get("id") or "")
            if not _FREELLMAPI_ID.fullmatch(name) or name in ids:
                continue
            if entry.get("available") is False:
                continue
            # FreeLLMAPI's own routing entries carry owned_by "freellmapi".
            if FREELLMAPI_MODELS == "auto" and entry.get("owned_by") != "freellmapi":
                continue
            ids.append(name)
        _FREELLMAPI_LIST["ids"] = ids
    except Exception as exc:  # noqa: BLE001 - the model list must still be served
        log.warning("freellmapi: model list unavailable (%s)", exc)
    return _FREELLMAPI_LIST["ids"]

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
BUSY_PENALTY = max(0.0, _cfg.getfloat("balancing", "busy_penalty"))
STICKY_SECONDS = max(0.0, _cfg.getfloat("balancing", "sticky_seconds"))

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
    "avalon": {"prefix": "avalon+", "key_env": "AVALON_API_KEY",
               "label": "Avalon", "openai": True},
    "kindi": {"prefix": "kindi+", "key_env": "KINDI_API_KEY",
              "label": "Kindi", "openai": True},
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
TOOL_KINDS = frozenset(k for k in _json_list(_cfg, "classification", "tool_kinds")
                       if k in OPENAI_KINDS)
for _kind in sorted(set(_json_list(_cfg, "classification", "tool_kinds")) - TOOL_KINDS):
    log.warning("ignoring [classification] tool_kinds entry %r (use %s)",
                _kind, ", ".join(sorted(OPENAI_KINDS)))
CONNECT_TIMEOUT = _cfg.getfloat("http", "connect_timeout_seconds")
READ_TIMEOUT = _cfg.getfloat("http", "read_timeout_seconds")
KINDI_READ_TIMEOUT = max(READ_TIMEOUT, _cfg.getfloat("http", "kindi_read_timeout_seconds"))

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


def litellm_read_timeout(tier: str | None = None) -> float:
    """Read gap for this LiteLLM request; passthrough keeps the normal limit."""
    return KINDI_READ_TIMEOUT if tier and tier_has_kindi(tier) else READ_TIMEOUT


def tier_has_kindi(tier: str) -> bool:
    """Whether LiteLLM can select a Kindi deployment for this tier."""
    return any(server_kind(entry.strip()) == "kindi"
               for entry in _tier_env(tier).split(",") if entry.strip())


# --- live inventory -----------------------------------------------------------
# Replaced wholesale on each refresh, so readers never see a half-built dict.
INVENTORY = {"models": [], "servers": {}, "updated_at": 0.0, "errors": {}}
_rotation = {}

# --- load and conversation affinity -------------------------------------------
# server -> requests this router has sent there and not yet seen finish. Only
# its own traffic: what the agents' dispatchers or other clients send a server
# directly is not seen.
_IN_FLIGHT = {}


class InFlight:
    """One request counted against a server from the moment it is sent until
    release(): when its body has been relayed, it failed, or the client left.
    release() may be called more than once, and a forgotten one is released
    when it is collected, so a lost count cannot weigh on a server for good."""

    __slots__ = ("server", "open", "streaming")

    def __init__(self, server: str):
        self.server, self.open, self.streaming = server, True, False
        _IN_FLIGHT[server] = _IN_FLIGHT.get(server, 0) + 1

    def release(self) -> None:
        if not self.open:
            return
        self.open = False
        left = _IN_FLIGHT.get(self.server, 0) - 1
        if left > 0:
            _IN_FLIGHT[self.server] = left
        else:
            _IN_FLIGHT.pop(self.server, None)

    def __del__(self):
        self.release()


def in_flight(server: str) -> int:
    """Requests in flight on a server, as far as load awareness is on."""
    return _IN_FLIGHT.get(server, 0) if BUSY_PENALTY > 0 else 0


# conversation key -> (server, model, time of its last answer), oldest first.
_STICKY = OrderedDict()
STICKY_MAX = 4096


def conversation_keys(messages) -> list:
    """Fingerprints of how a conversation began, most specific first.

    Clients resend the whole history with every turn, so its beginning names a
    conversation. Two keys: one through the first assistant reply after the
    first user turn (there from the second turn on, and as good as unique), and
    one through the first user turn alone (all a first request has; two
    conversations that open with the same words share it). Only hashes of the
    roles and text are kept. Empty when affinity is off or no user has spoken."""
    if STICKY_SECONDS <= 0:
        return []
    digest, opening = hashlib.blake2b(digest_size=16), None
    for message in messages or []:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "")
        digest.update(role.encode("utf-8", "replace") + b"\0")
        digest.update(_message_parts(message)[0].encode("utf-8", "replace") + b"\0")
        if opening is None:
            if role == "user":
                opening = digest.hexdigest()
        elif role == "assistant":
            # A reply that only calls tools has no text; its calls tell it apart.
            calls = message.get("tool_calls")
            if calls:
                digest.update(json.dumps(calls, sort_keys=True, default=str).encode("utf-8", "replace"))
            return [digest.hexdigest(), opening]
    return [opening] if opening else []


def sticky_choice(keys: list):
    """(server, model) that last answered this conversation, or None."""
    now = time.monotonic()
    for key in keys or ():
        found = _STICKY.get(key)
        if found is None:
            continue
        if now - found[2] > STICKY_SECONDS:
            del _STICKY[key]
            continue
        return found[0], found[1]
    return None


def remember_choice(keys: list, entry: dict) -> None:
    """Note which server and model answered this conversation."""
    now = time.monotonic()
    for key in keys or ():
        _STICKY[key] = (entry["server"], entry["name"], now)
        _STICKY.move_to_end(key)
    while len(_STICKY) > STICKY_MAX:
        _STICKY.popitem(last=False)


def order_tied(tied: list, sticky=None) -> list:
    """Order candidates that are equally good: the server with the fewest
    requests in flight first, then the one this conversation used last. What is
    still equal keeps the order it came in (the rotation's)."""
    if len(tied) < 2:
        return tied
    return sorted(tied, key=lambda entry: (
        in_flight(entry["server"]),
        0 if sticky and (entry["server"], entry["name"]) == sticky else 1))


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
# A digest identifies what was probed: Ollama gives a re-pulled or re-created
# model a new one, and AirLLM puts its served window into its digest. Such an
# answer is kept for show_cache_seconds (an hour), so a poll does not ask every
# host about every model again. A server that lists no digest (the llama.cpp
# bridge) can change a runtime setting, such as its context size, with nothing
# to show for it, so its answers expire after a minute, as all did before.
# POST /routing/refresh re-probes everything at once.
SHOW_CACHE_SECONDS = max(0.0, _cfg.getfloat("discovery", "show_cache_seconds"))
SHOW_CACHE_SECONDS_NO_DIGEST = 60.0
_SHOW_TIMES = {}


def _show_ttl(raw: dict) -> float:
    """Seconds a cached /api/show answer for this /api/tags entry stays valid."""
    if raw.get("digest"):
        return SHOW_CACHE_SECONDS
    return min(SHOW_CACHE_SECONDS, SHOW_CACHE_SECONDS_NO_DIGEST)


def _forget_show_answers(server: str, current: set) -> None:
    """Drop the cached answers of models a server no longer lists (a removed
    model, or the previous digest of a re-pulled one)."""
    for key in [k for k in _CAPABILITIES if k[0] == server and k not in current]:
        for cache in (_CAPABILITIES, _CONTEXTS, _SHOW_TIMES):
            cache.pop(key, None)


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
            and time.monotonic() - _SHOW_TIMES[key] < _show_ttl(raw)):
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
    """Read Strata, Basalt, Maya, Xolotl, Avalon or Kindi model IDs and capabilities at /v1/models."""
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
            outputs = architecture.get("output_modalities") if isinstance(architecture, dict) else None
            meta = model.get("meta") if isinstance(model.get("meta"), dict) else {}
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
                   # max_model_len included), then the served context that
                   # llama-server and Strata-style servers give as meta.n_ctx
                   # (not n_ctx_train, the model's own limit). None required.
                   "context_length": next(filter(None, (
                       *(positive_int(model.get(k)) for k in
                         ("context_length", "max_model_len", "context_window")),
                       positive_int(meta.get("n_ctx")))), None)}
            # An image generator listed beside the chat model (Strata's
            # /v1/images model) outputs no text, so it takes no tools.
            if server_kind(server) in TOOL_KINDS:
                raw["tools"] = True if not isinstance(outputs, list) or "text" in outputs else None
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
        _forget_show_answers(server, {_show_key(server, raw) for raw in raws})
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


app = FastAPI(title="Open Smart Router", lifespan=lifespan)


def api_key_failure(path: str, headers) -> Response | None:
    """The response that refuses a request, or None when it may proceed."""
    if path != "/healthz" and headers.get("x-router-subscription") == "1" \
            and not ROUTER_API_KEY:
        return _error(503, "Subscription pass through requires ROUTER_API_KEY.",
                      "subscription_auth_not_configured")
    if ROUTER_API_KEY and path != "/healthz":
        if headers.get("x-router-subscription") == "1":
            # Keep Authorization free for the signed-in Codex/Claude client.
            token = headers.get("x-router-api-key", "")
        else:
            supplied = headers.get("authorization", "")
            token = supplied[7:].strip() if supplied.lower().startswith("bearer ") else ""
        if not hmac.compare_digest(token.encode(), ROUTER_API_KEY.encode()):
            return JSONResponse(
                {"error": {"message": "Missing or invalid router API key.",
                           "type": "invalid_request_error",
                           "code": "invalid_api_key"}},
                status_code=401)
    return None


class RouterKeyMiddleware:
    """The API-key check as plain ASGI middleware.

    @app.middleware("http") would build Starlette's BaseHTTPMiddleware, which
    runs the application in a second task and relays every response chunk
    through an in-memory stream: a cost paid for each token of a streamed
    completion. Here an admitted request reaches the application with its own
    receive and send, untouched."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            denied = api_key_failure(scope["path"], Headers(scope=scope))
            if denied is not None:
                await denied(scope, receive, send)
                return
        await self.app(scope, receive, send)


def _metrics_route(path: str) -> str:
    """Which family of requests a path belongs to in osr_requests_total; ""
    for the ones not counted (/healthz and /metrics are polled by machines)."""
    if path == "/v1/chat/completions":
        return "chat"
    if path.startswith("/v1/"):
        return "v1"
    if path.startswith("/routing/"):
        return "routing"
    return ""


class RequestMiddleware:
    """Gives each request its ID and counts and times it for /metrics.

    Plain ASGI, like the key check: the only thing put between the application
    and the server is one function call per message sent. The labels are read
    from the X-Router-* headers the router itself puts on an answer."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        current = accept_request_id(Headers(scope=scope).get("x-request-id"))
        token = _REQUEST_ID.set(current)
        route = _metrics_route(scope["path"])
        started = time.monotonic()
        timed = {}

        async def send_with_id(message):
            kind = message["type"]
            record_start = record_duration = False
            if kind == "http.response.start":
                headers = list(message.get("headers") or [])
                given = {name.lower(): value for name, value in headers}
                headers.append((b"x-router-request-id", current.encode("ascii")))
                if b"x-request-id" not in given:
                    headers.append((b"x-request-id", current.encode("ascii")))
                message = dict(message, headers=headers)
                if route:
                    labels = {label: given.get(b"x-router-" + label.encode(), b"").decode("latin-1")
                              for label in ("mode", "model", "server")}
                    count("osr_requests_total", route=route, status=str(message["status"]),
                          **{"class": given.get(b"x-router-class", b"").decode("latin-1")}, **labels)
                    if route == "chat" and message["status"] < 400:
                        timed.update(labels)
                        record_start = True
            elif kind == "http.response.body" and timed and not message.get("more_body"):
                record_duration = True
            await send(message)
            # ASGI send completion is the closest available point to headers
            # and the final body reaching the server's output transport.
            if record_start:
                observe("osr_response_start_seconds", time.monotonic() - started, **timed)
            if record_duration:
                observe("osr_request_duration_seconds", time.monotonic() - started, **timed)
                timed.clear()

        try:
            await self.app(scope, receive, send_with_id)
        finally:
            _REQUEST_ID.reset(token)


app.add_middleware(RouterKeyMiddleware)
# Added last, so it is outermost: a refused request has an ID and is counted too.
app.add_middleware(RequestMiddleware)


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
    # Each request already in flight on the server counts against it, so a busy
    # server gives way to an equally good idle one at once, and to a slightly
    # worse one (the same model not yet loaded elsewhere, say) as it gets busier.
    score -= BUSY_PENALTY * in_flight(entry["server"])
    return score


def rank_candidates(need: dict, inventory: dict = None, affinity: list = None) -> list:
    """All usable (server, model) pairs, best first. affinity: the request's
    conversation_keys, so that equally good candidates start with the one the
    conversation used last."""
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
    sticky = sticky_choice(affinity)
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
        # The model the task has been using stays the one, while it is tied.
        best_name = tied[0]["name"]
        if sticky and any(e["name"] == sticky[1] for e in tied):
            best_name = sticky[1]
        rest = [e for e in tied if e["name"] != best_name] + rest
        tied = [e for e in tied if e["name"] == best_name]
    if len(tied) > 1:
        key = f"{need['class']}|{need['code']}|{need['vision']}|{need.get('tools', False)}"
        index = _rotation.get(key, 0) % len(tied)
        _rotation[key] = index + 1
        tied = tied[index:] + tied[:index]
    return order_tied(tied, sticky) + rest


def find_named_model(model_name: str, affinity: list = None) -> list:
    """Servers hosting an explicitly requested model, best first: the least
    busy, then the one the conversation used last, in rotation otherwise."""
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
    return order_tied(matches, sticky_choice(affinity))


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
    router's own API key is never handed to an Ollama host. The request's ID
    goes along as X-Request-ID (the caller's own, when the router adopted it)."""
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in HOP_BY_HOP
               and k.lower() not in ("x-router-api-key", "x-router-subscription", "x-request-id")
               and not (drop_auth and k.lower() == "authorization")}
    if request_id():
        headers["X-Request-ID"] = request_id()
    return headers


async def _proxy_subscription(request: Request) -> Response:
    if not SUBSCRIPTION_GATEWAY_BASE:
        return _error(503, "Subscription gateway is not configured.",
                      "subscription_gateway_not_configured")
    url = f"{SUBSCRIPTION_GATEWAY_BASE}{request.url.path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"
    raw = await request.body()
    return await _stream_upstream(
        request.method, url, _forward_headers(request), content=raw or None,
        extra_headers={"X-Router-Mode": "subscription"})


def _response_headers(upstream: httpx.Response, extra: dict = None) -> dict:
    headers = {k: v for k, v in upstream.headers.items()
               if k.lower() not in RESPONSE_HOP_BY_HOP
               and not k.lower().startswith("x-router-")}
    # Only this router may set X-Router-* response headers. Metrics use them
    # as labels, so forwarding an upstream value could create unbounded series.
    if extra:
        headers.update(extra)
    return headers


async def close_upstream(response: httpx.Response, slot: InFlight = None) -> None:
    await response.aclose()
    if slot is not None:
        slot.release()


async def _relay_counted(slot: InFlight, chunks: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
    """Relay a streamed body. The request stops counting against its server
    when the stream ends, breaks, or the client stops reading."""
    try:
        async for chunk in chunks:
            yield chunk
    finally:
        slot.release()


async def _stream_upstream(method: str, url: str, headers: dict,
                           json_body=None, content=None,
                           extra_headers: dict = None,
                           read_timeout: float = READ_TIMEOUT,
                           kindi_tier: bool = False) -> Response:
    client = http_client()
    try:
        upstream_request = client.build_request(
            method, url, headers=headers, json=json_body, content=content,
            timeout=httpx.Timeout(read_timeout, connect=CONNECT_TIMEOUT),
        )
        upstream_response = await client.send(upstream_request, stream=True)
    except httpx.ReadTimeout as exc:
        if kindi_tier:
            return kindi_no_reply("LiteLLM did not answer for a tier with Kindi.")
        raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
    if kindi_tier and upstream_response.status_code == 408:
        # LiteLLM answers its own timeout with 408, which an SDK retries.
        await upstream_response.aclose()
        return kindi_no_reply("LiteLLM gave up on a tier with Kindi.")
    if (kindi_tier and isinstance(json_body, dict) and json_body.get("stream") is not True
            and 200 <= upstream_response.status_code < 300):
        # LiteLLM can send 200 headers before a Kindi-backed completion body.
        # Finish the non-streaming response before committing our own 200.
        try:
            buffered = b"".join([chunk async for chunk in upstream_response.aiter_raw()])
        except httpx.ReadTimeout:
            await upstream_response.aclose()
            return kindi_no_reply("LiteLLM did not finish a tier with Kindi.")
        except httpx.RequestError as exc:
            await upstream_response.aclose()
            raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
        await upstream_response.aclose()
        return Response(content=buffered, status_code=upstream_response.status_code,
                        headers=_response_headers(upstream_response, extra_headers))
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response, extra_headers),
        background=BackgroundTask(close_upstream, upstream_response),
    )


# Upstream statuses that mean "try the next candidate": the host is failing
# (5xx) or no longer has the model (404, e.g. removed since the last poll).
RETRYABLE_STATUS = {404} | set(range(500, 600))
CLIENT_RETRYABLE_STATUS = {408, 409, 429} | set(range(500, 600))

# A Kindi request that got no reply after it was sent may still be running:
# Kindi serves one request at a time, and an OpenAI SDK retries a 5xx (a 408
# too), so the retry would queue behind it. Such a failure is answered 424 with
# x-should-retry: false; the message avoids the words clients match as a
# timeout. The router hung up, so Kindi stops the request at its next prompt
# batch or token; until its /health confirms it is idle, nothing more is sent
# to it and callers get a retryable 503. A newer busy request does not prove
# the unanswered one has finished: it could still be waiting in Kindi's queue.
KINDI_HEALTH_CACHE_SECONDS = 5
_KINDI_DRAINING: dict = {}  # server -> [last /health check, busy]


def kindi_no_reply(prefix: str) -> JSONResponse:
    return JSONResponse(
        {"error": {"message": prefix + " No complete reply arrived within the read budget; the request "
                   "was not sent again, because Kindi may still be working on it.",
                   "type": "upstream_no_reply", "code": "kindi_no_reply"}},
        status_code=424, headers={"x-should-retry": "false"})


def mark_kindi_draining(server: str) -> None:
    _KINDI_DRAINING[server] = [float("-inf"), True]


async def kindi_busy(server: str) -> bool:
    """True while a Kindi server that left a request unanswered still reports
    work in progress on /health (checked at most every 5 s)."""
    state = _KINDI_DRAINING.get(server)
    if state is None:
        return False
    now = time.monotonic()
    if now - state[0] < KINDI_HEALTH_CACHE_SECONDS:
        return state[1]
    try:
        response = await http_client().get(f"{server_base(server)}/health", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        health = response.json()
        if not isinstance(health, dict) or "busy" not in health:
            raise ValueError("Kindi health response has no busy field")
        busy = health["busy"] is not None and health["busy"] is not False
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("dispatch: cannot confirm Kindi %s is idle (%s)", server, exc)
        busy = True
    # A concurrent request may have recorded a newer unanswered POST while
    # this probe was in flight. Its drain state takes precedence.
    current = _KINDI_DRAINING.get(server)
    if current is not state:
        return current[1] if current is not None else False
    if busy:
        _KINDI_DRAINING[server] = [now, True]
    else:
        _KINDI_DRAINING.pop(server, None)
    return busy


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


async def _relay_kindi_stream(server: str, response: httpx.Response, first_chunk: bytes,
                              remaining: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
    """Relay SSE after its first chunk; keep Kindi gated if it later stalls."""
    try:
        if first_chunk:
            yield first_chunk
        async for chunk in remaining:
            yield chunk
    except httpx.ReadTimeout:
        mark_kindi_draining(server)
        raise
    finally:
        await response.aclose()


def _json_bytes(payload) -> bytes:
    """A JSON body as httpx encodes json=: compact UTF-8, non-ASCII kept."""
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def body_for_model(body: dict, name: str, raw: bytes | None, encoded: dict) -> bytes:
    """The request body with "model" set to name, as bytes.

    A long conversation or an inline image makes the body megabytes of JSON,
    and encoding it holds the event loop, and with it every other stream. So
    it is encoded once per model name (encoded caches it across the fail-forward
    attempts, where the same model on another host is the usual next candidate),
    and not at all when the client already named this model: its own bytes
    (raw, when they are UTF-8 JSON) are sent as they came."""
    if name not in encoded:
        if raw is not None and body.get("model") == name and json.detect_encoding(raw) == "utf-8":
            encoded[name] = raw
        else:
            encoded[name] = _json_bytes(dict(body, model=name))
    return encoded[name]


async def _dispatch_direct(candidates: list, body: dict, headers: dict,
                           need: dict, extra_headers: dict = None,
                           raw: bytes | None = None, affinity: list = None) -> Response:
    """Send to the best candidate, falling forward through the ranked list on
    connection errors, 404 or 5xx. Retrying is only safe before any body has
    been streamed, which is why the status is checked before returning. A host
    that refuses or times out the CONNECTION is marked down immediately so the
    next request skips it too."""
    client = http_client()
    last_error = None
    no_reply = kindi_was_busy = False
    encoded: dict = {}

    def failed(entry: dict, reason: str) -> None:
        count("osr_upstream_failures_total", server=entry["server"], reason=reason)

    if not any(key.lower() == "content-type" for key in headers):
        headers = dict(headers, **{"Content-Type": "application/json"})
    for position, entry in enumerate(candidates):
        if not INVENTORY.get("servers", {}).get(entry["server"], {}).get("up", True):
            last_error = f"{entry['server']}: marked down"
            continue
        if entry["kind"] == "kindi" and await kindi_busy(entry["server"]):
            last_error = (f"{entry['server']} is still busy after an earlier request got no reply; "
                          "nothing was sent to it")
            kindi_was_busy = True
            continue
        slot = InFlight(entry["server"])
        try:
            url = f"{server_base(entry['server'])}/v1/chat/completions"
            try:
                upstream_request = client.build_request(
                    "POST", url, headers=dict(headers, **backend_headers(entry["server"])),
                    content=body_for_model(body, entry["name"], raw, encoded),
                    timeout=httpx.Timeout(
                        KINDI_READ_TIMEOUT if entry["kind"] == "kindi" else READ_TIMEOUT,
                        connect=CONNECT_TIMEOUT,
                    ),
                )
                upstream_response = await client.send(upstream_request, stream=True)
            except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
                last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                failed(entry, "connect")
                mark_server_down(entry["server"], last_error)
                continue
            except httpx.RequestError as exc:
                last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                if entry["kind"] == "kindi" and isinstance(exc, httpx.ReadTimeout):
                    # Sent, but no reply: Kindi may still be working on it.
                    no_reply = True
                    failed(entry, "no_reply")
                    mark_kindi_draining(entry["server"])
                    log.warning("dispatch: Kindi %s sent no reply; not sending it again", entry["server"])
                    continue
                failed(entry, "transport")
                log.warning("dispatch: %s", last_error)
                continue
            is_last = position == len(candidates) - 1
            if upstream_response.status_code in RETRYABLE_STATUS:
                # Counted whether another candidate follows or this answer is
                # passed on as it is.
                failed(entry, f"http_{upstream_response.status_code}")
            if upstream_response.status_code in RETRYABLE_STATUS and not is_last:
                await upstream_response.aclose()
                last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
                log.warning("dispatch: %s for %s; trying the next candidate",
                            last_error, entry["name"])
                continue
            if no_reply and upstream_response.status_code in CLIENT_RETRYABLE_STATUS:
                # A later error must not turn an unanswered Kindi POST into a
                # response that makes clients replay the whole call.
                last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
                if upstream_response.status_code not in RETRYABLE_STATUS:
                    failed(entry, f"http_{upstream_response.status_code}")
                await upstream_response.aclose()
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
                    failed(entry, "tool_rejection")
                    last_error = f"{entry['server']}: {entry['name']} rejected the tools (HTTP 400)"
                    if not is_last:
                        log.warning("dispatch: %s; trying the next candidate", last_error)
                        continue
                    log.warning("dispatch: %s; no candidates left", last_error)
            kindi_stream = None
            if entry["kind"] == "kindi" and upstream_response.status_code < 400:
                try:
                    raw_stream = upstream_response.aiter_raw()
                    if body.get("stream") is True:
                        first_chunk = await anext(raw_stream, b"")
                        kindi_stream = _relay_kindi_stream(entry["server"], upstream_response,
                                                            first_chunk, raw_stream)
                    else:
                        # The client expects one complete JSON reply. Read every
                        # raw byte before sending 200, so a late read timeout can
                        # still become 424 and the original encoding is preserved.
                        buffered = b"".join([chunk async for chunk in raw_stream])
                        await upstream_response.aclose()
                except httpx.ReadTimeout as exc:
                    last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                    no_reply = True
                    failed(entry, "no_reply")
                    mark_kindi_draining(entry["server"])
                    await upstream_response.aclose()
                    continue
                except httpx.RequestError as exc:
                    last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                    failed(entry, "transport")
                    mark_server_down(entry["server"], last_error)
                    await upstream_response.aclose()
                    continue
            kept = sticky_choice(affinity) == (entry["server"], entry["name"])
            if upstream_response.status_code < 400:
                remember_choice(affinity, entry)
            log.info("route class=%s code=%s vision=%s tools=%s tokens~%s -> %s @ %s (%d/%d)%s",
                     need["class"], need["code"], need["vision"], need.get("tools", False),
                     need.get("approx_tokens"), entry["name"], entry["server"],
                     position + 1, len(candidates), " same server as last turn" if kept else "")
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
            # The body is still to come: the request counts against the server
            # until it has been relayed.
            slot.streaming = True
            return StreamingResponse(
                _relay_counted(slot, kindi_stream if kindi_stream is not None
                               else upstream_response.aiter_raw()),
                status_code=upstream_response.status_code,
                headers=_response_headers(upstream_response, router_headers),
                background=BackgroundTask(close_upstream, upstream_response, slot),
            )
        finally:
            if not slot.streaming:
                slot.release()
    if no_reply:
        return kindi_no_reply("No usable model target.")
    if kindi_was_busy:
        return JSONResponse({"error": {"message": f"No usable model target. Last error: {last_error}",
                                       "type": "kindi_busy", "code": "kindi_busy"}},
                            status_code=503, headers={"Retry-After": "15"})
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
        # Requests this router has in flight per server (others are not seen).
        "in_flight": dict(_IN_FLIGHT),
        "errors": INVENTORY.get("errors", {}),
        "models": INVENTORY.get("models", []),
        # The direct dispatchers of Hermes, OpenClaw and Honcho compare this
        # with the budget their CT was configured for.
        "kindi_read_timeout_seconds": KINDI_READ_TIMEOUT,
    })


def render_metrics() -> str:
    """Everything /metrics reports, in Prometheus text format (version 0.0.4)."""
    servers = INVENTORY.get("servers", {})
    known = list(dict.fromkeys([*SERVERS, *servers, *_IN_FLIGHT]))
    gauges = {
        "osr_in_flight_requests": [((("server", s),), _IN_FLIGHT.get(s, 0)) for s in known],
        "osr_server_up": [((("kind", server_kind(s)), ("server", s)), 1 if state.get("up") else 0)
                          for s, state in servers.items()],
        "osr_server_models": [((("server", s),), state.get("model_count", 0))
                              for s, state in servers.items()],
        "osr_inventory_age_seconds": ([((), round(time.time() - INVENTORY["updated_at"], 3))]
                                      if INVENTORY.get("updated_at") else []),
        "osr_remembered_conversations": [((), len(_STICKY))],
        "osr_start_time_seconds": [((), round(_STARTED, 3))],
    }
    lines = []
    for name, (kind, text) in METRICS.items():
        lines.append(f"# HELP {name} {text}")
        lines.append(f"# TYPE {name} {kind}")
        if kind == "counter":
            lines += [f"{name}{_label_text(labels)} {_number(value)}"
                      for (metric, labels), value in sorted(_COUNTERS.items()) if metric == name]
        elif kind == "gauge":
            lines += [f"{name}{_label_text(labels)} {_number(value)}" for labels, value in gauges[name]]
        else:
            for (metric, labels), series in sorted(_HISTOGRAMS.items()):
                if metric != name:
                    continue
                running = 0
                for bound, hits in zip(DURATION_BUCKETS, series, strict=False):
                    running += hits
                    upper = 'le="%s"' % _number(bound)
                    lines.append(f"{name}_bucket{_label_text(labels, upper)} {running}")
                upper = 'le="+Inf"'
                lines.append(f"{name}_bucket{_label_text(labels, upper)} {series[-1]}")
                lines.append(f"{name}_sum{_label_text(labels)} {repr(float(series[-2]))}")
                lines.append(f"{name}_count{_label_text(labels)} {series[-1]}")
    return "\n".join(lines) + "\n"


@app.get("/metrics")
async def metrics():
    """Prometheus metrics. Like every path but /healthz it needs the router key:
    the labels name the model servers and models."""
    return Response(render_metrics(), media_type="text/plain; version=0.0.4; charset=utf-8")


@app.post("/routing/refresh")
async def routing_refresh(probe: bool = True):
    """Poll every server now. By default every Ollama model is also asked for
    its capabilities again; ?probe=false keeps the cached /api/show answers,
    for callers that only need to know which servers are up with which models
    (tools/upgrade-all.sh polls this while it waits for a target)."""
    await refresh_inventory(force_probe=probe)
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
             "tools": e.get("tools"), "score": round(score_entry(e, need), 4),
             "in_flight": _IN_FLIGHT.get(e["server"], 0)}
            for e in candidates[:10]
        ],
    })


def _error(status: int, message: str, code: str) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "invalid_request_error",
                                   "code": code}}, status_code=status)


@app.post("/v1/chat/completions")
async def route_chat_completion(request: Request):
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
    raw = await request.body()
    try:
        body = json.loads(raw)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    if not isinstance(body, dict):
        return _error(400, "Request body must be a JSON object.", "invalid_body")
    messages = body.get("messages") or []
    requested = str(body.get("model") or "").strip()
    need = apply_tool_needs(classify_request(messages), body)
    affinity = conversation_keys(messages)

    if requested in CLOUD_MODELS:
        log.info("route explicit cloud model=%s", requested)
        return await _stream_upstream(
            "POST", LITELLM_URL, _forward_headers(request, drop_auth=True),
            json_body=body,
            extra_headers={"X-Router-Mode": "cloud", "X-Router-Model": requested},
        )
    if requested.startswith(FREELLMAPI_PREFIX):
        if not FREELLMAPI_ENABLED:
            return _error(404, f"Model '{requested}' needs FreeLLMAPI, which is not configured "
                          "(manage-model-servers set-freellmapi).", "freellmapi_not_configured")
        upstream_model = requested[len(FREELLMAPI_PREFIX):]
        if not _FREELLMAPI_ID.fullmatch(upstream_model):
            return _error(400, f"'{requested}' is not a FreeLLMAPI model name.",
                          "freellmapi_model_invalid")
        log.info("route explicit freellmapi model=%s", requested)
        headers = _forward_headers(request, drop_auth=True)
        headers.update(freellmapi_headers())
        return await _stream_upstream(
            "POST", f"{FREELLMAPI_BASE}/v1/chat/completions", headers,
            json_body=dict(body, model=upstream_model),
            extra_headers={"X-Router-Mode": "freellmapi", "X-Router-Model": requested},
        )
    if requested.split("/", 1)[0] in CLOUD_PROVIDERS and "/" in requested \
            and not known_chat_model(requested) and not embedding_only_match(requested):
        # Local servers may use the same prefixes (LM Studio lists
        # "openai/gpt-oss-20b"), so only a name no local host knows is refused.
        return _error(404, f"Cloud model '{requested}' is not configured with an API key.",
                      "cloud_model_not_configured")

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        # An explicitly requested real model is honoured; tier aliases and
        # "auto" mean "decide for me".
        candidates, explicit = [], False
        if requested and requested.lower() not in ("auto", "") \
                and requested not in TIER_NAMES:
            candidates = find_named_model(requested, affinity)
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
            candidates = rank_candidates(need, affinity=affinity)
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
                need, extra, raw=raw, affinity=affinity)

    # Fallback: the original static path through LiteLLM, which keeps its own
    # latency routing and cross-tier fallbacks.
    tier = _CLASS_TO_TIER[need["class"]]
    body["model"] = globals()[tier]
    log.info("route class=%s -> LiteLLM %s", need["class"], body["model"])
    headers = _forward_headers(request, drop_auth=True)
    if tier_has_kindi(need["class"]):
        # Kindi asks for one retry at most. LiteLLM 1.75 does not read the
        # policy's InternalServerErrorRetries, so this request header caps the
        # retries of every error but a timeout (the policy's 0) at one. A
        # client's own retry or timeout header is dropped; the timeout comes
        # from each deployment (Kindi's follows router.ini), and a request-wide
        # one would also lift LiteLLM's 600 s from the tier's other servers.
        headers = {key: value for key, value in headers.items()
                   if key.lower() not in ("x-litellm-num-retries", "x-litellm-timeout")}
        headers["x-litellm-num-retries"] = "1"
    return await _stream_upstream(
        "POST", LITELLM_URL, headers, json_body=body,
        extra_headers={"X-Router-Mode": "litellm", "X-Router-Model": body["model"]},
        read_timeout=litellm_read_timeout(need["class"]),
        kindi_tier=tier_has_kindi(need["class"]),
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
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
    seen, data = set(), []
    for alias in ("auto", TIER_FAST, TIER_MEDIUM, TIER_LARGE, TIER_XLARGE):
        if alias and alias not in seen:
            seen.add(alias)
            data.append({"id": alias, "object": "model", "owned_by": "router"})

    for name, provider in CLOUD_MODELS.items():
        if name not in seen:
            seen.add(name)
            data.append({"id": name, "object": "model", "owned_by": provider})

    if FREELLMAPI_ENABLED:
        for name in await freellmapi_models():
            name = FREELLMAPI_PREFIX + name
            if name not in seen:
                seen.add(name)
                data.append({"id": name, "object": "model", "owned_by": "freellmapi"})

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
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
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
cat > "${REPO_DIR}/services/osr-monitor/monitor.py" <<'PYEOF'
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
MATTERMOST_USER = os.getenv("MATTERMOST_MONITOR_USER", "OSRMonitor")
MATTERMOST_CHANNEL = os.getenv("MATTERMOST_CHANNEL", "osr-monitor")
MATTERMOST_VERIFY_TLS = os.getenv("MATTERMOST_VERIFY_TLS", "true").lower() == "true"

# Polling behaviour comes from monitor.ini (version controlled). An environment
# variable of the names in ENV_OVERRIDES still wins when it is set to a value,
# so an operator can override one without a commit; the overrides that differ
# from monitor.ini are logged at start, so none is in force unnoticed.
_DEFAULTS = {
    "polling": {"interval_seconds": "15", "timeout_seconds": "5",
                "health_path": "/api/tags"},
    "alerting": {"fail_threshold": "3", "recover_threshold": "2"},
    "startup": {"notice_interval_seconds": "3600"},
    "local_services": {
        "enabled": "true",
        "litellm-proxy": "http://127.0.0.1:4000/health/liveliness",
        "osr-router": "http://127.0.0.1:8000/healthz",
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

# (environment variable, monitor.ini section, option, default without the file)
ENV_OVERRIDES = (
    ("MONITOR_INTERVAL_SECONDS", "polling", "interval_seconds", "15"),
    ("MONITOR_TIMEOUT_SECONDS", "polling", "timeout_seconds", "5"),
    ("MONITOR_HEALTH_PATH", "polling", "health_path", "/api/tags"),
    ("MONITOR_FAIL_THRESHOLD", "alerting", "fail_threshold", "3"),
    ("MONITOR_RECOVER_THRESHOLD", "alerting", "recover_threshold", "2"),
    ("KEEP_ALIVE_REFRESH_SECONDS", "keep_alive", "refresh_seconds", "240"),
)


def _ini(section: str, option: str, default: str) -> str:
    return _cfg.get(section, option, fallback=default).strip()


def _setting(name: str) -> str:
    """One ENV_OVERRIDES setting: the environment's value when it has one (an
    empty variable counts as not set), else monitor.ini's."""
    for env_name, section, option, default in ENV_OVERRIDES:
        if env_name == name:
            return (os.getenv(env_name) or "").strip() or _ini(section, option, default)
    raise KeyError(name)


def env_overrides() -> list:
    """The settings an environment variable changes from what monitor.ini
    says, as text for the log."""
    def same(left: str, right: str) -> bool:
        try:
            return float(left) == float(right)
        except ValueError:
            return left == right

    found = []
    for env_name, section, option, default in ENV_OVERRIDES:
        value, ini = (os.getenv(env_name) or "").strip(), _ini(section, option, default)
        if value and not same(value, ini):
            found.append(f"{env_name}={value} (monitor.ini has [{section}] {option} = {ini})")
    return found


CHECK_INTERVAL = int(_setting("MONITOR_INTERVAL_SECONDS"))
CHECK_TIMEOUT = float(_setting("MONITOR_TIMEOUT_SECONDS"))
HEALTH_PATH = _setting("MONITOR_HEALTH_PATH")
FAIL_THRESHOLD = max(1, int(_setting("MONITOR_FAIL_THRESHOLD")))
RECOVER_THRESHOLD = max(1, int(_setting("MONITOR_RECOVER_THRESHOLD")))
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
KEEP_ALIVE_INTERVAL = int(_setting("KEEP_ALIVE_REFRESH_SECONDS"))
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
    "avalon": {"prefix": "avalon+", "key_env": "AVALON_API_KEY",
               "label": "Avalon", "openai": True},
    "kindi": {"prefix": "kindi+", "key_env": "KINDI_API_KEY",
              "label": "Kindi", "openai": True},
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
    freellmapi = (os.getenv("FREELLMAPI_BASE_URL") or "").strip().rstrip("/")
    if freellmapi.startswith(("http://", "https://")):
        # targets/freellmapi: not a model server (the router uses it only for
        # freellmapi/<id>), but an outage should still be reported. /api/ping
        # needs no key.
        checks.append(Check("freellmapi", f"{freellmapi}/api/ping",
                            f"FreeLLMAPI `{freellmapi}` (freellmapi/ models)"))
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
        f"Health monitor online on `{host}` — health alerting is active. "
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


def keep_alive_plan() -> dict:
    """Ollama host URL -> the tier models to keep loaded there, in tier order.
    A model that two of a host's tiers share is listed once."""
    plan = {}
    for tier, urls in BACKENDS.items():
        model = TIER_MODELS.get(tier, "")
        if not model:
            continue
        for url in urls:
            if server_kind(url) != "ollama":
                # LM Studio has no keep_alive: it loads on demand and unloads
                # on its own idle TTL (configure that in LM Studio itself).
                continue
            models = plan.setdefault(url, [])
            if model not in models:
                models.append(model)
    return plan


def resident_models(url: str):
    """The model names Ollama's /api/ps reports loaded on url, or None when it
    cannot say (a failed call, or a bridge without /api/ps)."""
    try:
        with httpx.Client() as client:
            resp = client.get(f"{url.rstrip('/')}/api/ps", timeout=CHECK_TIMEOUT)
            resp.raise_for_status()
            models = resp.json().get("models")
        if not isinstance(models, list):
            return None
        return {name for model in models if isinstance(model, dict)
                for name in (model.get("name"), model.get("model")) if isinstance(name, str)}
    except Exception:  # noqa: BLE001 - residency is then simply unknown
        return None


def _is_resident(model: str, resident: set) -> bool:
    return model in resident or (":" not in model and f"{model}:latest" in resident)


# Hosts seen unloading one of their tier models to load another: they cannot
# hold all of them at once.
_CROWDED = set()


def pin_host(url: str, models: list) -> int:
    """Pin one host's tier models, one after another (a host loads one model at
    a time). Returns how many were pinned.

    A host that serves several tiers gets all of its models on the first pass.
    If loading one of them unloaded another, the host cannot hold them all, and
    loading each in turn on every refresh would evict the model in use again
    and again. Such a host then only has the timers of its resident tier models
    refreshed (the first is loaded when none is resident); the others load when
    a request needs them. It is treated normally again once /api/ps shows all
    of its models loaded together."""
    wanted = models
    if len(models) > 1 and url in _CROWDED:
        resident = resident_models(url)
        if resident is not None:
            if all(_is_resident(model, resident) for model in models):
                _CROWDED.discard(url)
            else:
                wanted = [m for m in models if _is_resident(m, resident)] or models[:1]
    done = [model for model in wanted if pin_model(url, model)]
    # keep_alive 0 unloads at once, so nothing stays resident to compare.
    if len(done) > 1 and url not in _CROWDED and _keep_alive_value() != 0:
        resident = resident_models(url)
        if resident is not None and not all(_is_resident(model, resident) for model in done):
            _CROWDED.add(url)
            logging.warning(
                "keep-alive: %s unloaded one tier model to load another (%s): it cannot "
                "hold them together. Only its loaded tier models are kept alive from now "
                "on; give each tier its own host, or one model, to keep them all loaded.",
                url, ", ".join(done))
    return len(done)


def refresh_keep_alive(is_up) -> int:
    """Pin each tier's model on every host serving that tier that is up.
    is_up(url) -> bool comes from the health checks. Hosts are pinned side by
    side, so one host's cold load (up to timeout_seconds) does not hold back
    the others until their models have already been unloaded."""
    # Down hosts are left out: don't wait on a host we already know is down.
    plan = [(url, models) for url, models in keep_alive_plan().items() if is_up(url)]
    if len(plan) > 1:
        with ThreadPoolExecutor(max_workers=min(16, len(plan)),
                                thread_name_prefix="keep-alive") as pool:
            pinned = sum(pool.map(lambda item: pin_host(*item), plan))
    else:
        pinned = sum(pin_host(url, models) for url, models in plan)
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
        logging.error("No model hosts or local services configured; nothing to monitor.")
        return
    logging.info("Monitoring %d endpoint(s): %s (alert after %d failures, "
                 "recover after %d passes)", len(checks),
                 ", ".join(c.key for c in checks), FAIL_THRESHOLD, RECOVER_THRESHOLD)
    for override in env_overrides():
        logging.info("The environment (router.env) overrides monitor.ini: %s", override)
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
      elif [[ "$url" == kindi+* ]]; then
        printf '      model: openai/%s\n' "$tag"
        printf '      api_base: %s/v1\n' "${url#kindi+}"
        printf '      api_key: none\n'
        printf '      timeout: 3600\n'
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
cat > "${REPO_DIR}/services/osr-router/requirements.txt" <<'REQEOF'
fastapi==0.116.1
uvicorn==0.35.0
httpx==0.28.1
python-dotenv==1.1.1
# uvicorn picks these up by itself when they are installed (its loop and HTTP
# parser are "auto"): libuv's event loop and a C request parser, which cut the
# per-chunk cost of streamed completions. Without them (another platform) it
# runs on asyncio and h11 as before.
uvloop==0.21.0; sys_platform == "linux" and (platform_machine == "x86_64" or platform_machine == "aarch64")
httptools==0.6.4; sys_platform == "linux" and (platform_machine == "x86_64" or platform_machine == "aarch64")
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

cat > "${REPO_DIR}/services/osr-monitor/requirements.txt" <<'REQEOF'
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
cat > "${REPO_DIR}/services/osr-router/router.ini" <<'INIEOF'
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
# Server kinds whose text models are reported tool-capable. Their /v1/models
# says nothing per model, but each of these servers takes "tools" and returns
# OpenAI tool_calls. Remove a kind to report its models' tool support as
# unknown again. Blank: none.
tool_kinds = strata, basalt, maya, xolotl, avalon, kindi

[http]
# Seconds to open a connection to a backend. This is how long a dead host can
# delay failover to the next candidate, so keep it short.
connect_timeout_seconds = 3
# Seconds allowed between bytes of a response (slow generation is fine).
read_timeout_seconds = 300
# The same for Kindi servers, which take one request at a time and read a long
# prompt slowly on small cards. Also used for LiteLLM while any configured
# server is Kindi. Never below read_timeout_seconds.
kindi_read_timeout_seconds = 3600

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
# How long an /api/show answer is kept for a model the server lists with a
# digest. A re-pulled or re-created Ollama model gets a new digest and is asked
# again at once; AirLLM's digest includes its window. Servers that list no
# digest (the llama.cpp bridge) are asked again after a minute whatever this
# says. POST /routing/refresh asks every model again.
show_cache_seconds = 3600
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
# Bonus for a model that is already resident (LM Studio and the Strata-style
# servers report it per model, Ollama through /api/ps). Small: it breaks
# near-ties, it does not override fit. It is larger than tie_epsilon, so a
# server that has the model in memory is used before one that would load it.
loaded_bonus = 0.1
# On a tool request, bonus for a model reported tool-capable over one whose
# tool support is unknown (LM Studio's untrained models, a kind left out of tool_kinds).
tool_match = 0.3

[balancing]
# How load is spread once the scores above have been compared.
#
# busy_penalty is taken off a candidate's score for each request this router
# already has in flight on its server, and equally good candidates (within
# tie_epsilon) are tried idle-first. So the same model on two servers goes to
# the idle one, and a busy server that leads only by loaded_bonus (the model
# is in memory there, not yet on the other) gives way once
# loaded_bonus - busy_penalty x requests is within tie_epsilon: with the
# defaults, from its second request in flight. Only this router's own requests
# are counted, not what agents or other clients send a server directly.
# 0 turns load awareness off (ties then simply rotate).
busy_penalty = 0.03
# A conversation prefers the server and model that answered it last, among
# equally good candidates, for this many seconds after its last answer: the
# server still holds the conversation's prompt cache, and the model stays the
# same. It yields to a less busy candidate and never overrides the scores.
# Conversations are told apart by a hash of how they began. 0 turns it off
# (every request then takes the next server in rotation).
sticky_seconds = 1800

[model_sizes]
# Sizes for exact model ids that an OpenAI-compatible server (Strata, Basalt,
# Maya, Xolotl, Avalon) lists without a parameter count, so the router can size-band them.
# Matching is by the whole id, case-insensitive: variants and aliases (Strata's
# Coder, a renamed Basalt alias) stay unknown-size unless listed here.
# Add a line for a custom alias (e.g. the BASALT_ALIAS a target serves);
# a blank value removes one of these built-in entries.
strata = 125B
qwen3.8-flash-next = 125B
# Strata serves the qwen family as qwen3.8-flash-next-<quant>; every quant is
# the same 125B model (Coder is a different, smaller model and stays unlisted).
qwen3.8-flash-next-q2_0 = 125B
qwen3.8-flash-next-iq2_xs = 125B
qwen3.8-flash-next-iq3_xxs = 125B
qwen3.8-flash-next-iq3_s = 125B
glm-5.3-flash = 321B
deepseek-v4.1-flash = 552B
# Avalon's default alias (Qwen3.8-Flash-Next, its IQ3_KS hybrid).
qwen3.8-flash-next-avalon = 125B
# Kindi's ids name their size (bonsai2-27b, nanbeige-33b-iq3) and need no line.
INIEOF

cat > "${REPO_DIR}/services/osr-monitor/monitor.ini" <<'INIEOF'
# Health-monitor tunables. Backend URLs stay in env/router.env and the webhook
# in /app/router/secrets.env; only polling/alerting behaviour lives here.
# Every model host in MODEL_SERVERS and the BACKEND_* lists is watched.
[polling]
interval_seconds = 15
timeout_seconds = 5
# Path appended to each Ollama backend URL for the health probe. LM Studio,
# Strata, Basalt, Maya, Xolotl, Avalon and Kindi are probed on /v1/models with their own keys
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
osr-router = http://127.0.0.1:8000/healthz
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
# systemctl restart litellm-proxy osr-router osr-monitor open-webui
set -euo pipefail
REPO_DIR="${1:-/app/config-repo}"
ROUTER_DIR="${2:-/app/router}"
OPENWEBUI_DIR="${3:-/app/openwebui}"
UNIT_DIR="${4:-/etc/systemd/system}"

install -d -m 0755 "$ROUTER_DIR" "$OPENWEBUI_DIR"

# Application code + per-service config
install -m 0644 "${REPO_DIR}/services/osr-router/router.py"   "${ROUTER_DIR}/router.py"
install -m 0644 "${REPO_DIR}/services/osr-router/router.ini"  "${ROUTER_DIR}/router.ini"
install -m 0644 "${REPO_DIR}/services/osr-monitor/monitor.py"  "${ROUTER_DIR}/monitor.py"
install -m 0644 "${REPO_DIR}/services/osr-monitor/monitor.ini" "${ROUTER_DIR}/monitor.ini"
install -m 0644 "${REPO_DIR}/services/litellm-proxy/litellm_config.yaml" \
                "${ROUTER_DIR}/litellm_config.yaml"

# Environment files (contain secrets -> root:osr-router 0640)
install -m 0640 -o root -g osr-router "${REPO_DIR}/env/router.env"    "${ROUTER_DIR}/.env"
install -m 0640 -o root -g osr-router "${REPO_DIR}/env/openwebui.env" "${OPENWEBUI_DIR}/.env"

# systemd units. Units from before the rename (ollama-router, ollama-monitor)
# left in the repo next to their successors are not installed, so two routers
# never compete for the same port.
for unit in "${REPO_DIR}"/services/*/*.service; do
  name="$(basename "$unit")"
  case "$name" in
    ollama-router.service|ollama-monitor.service)  # pre-rename names
      new="osr-${name#ollama-}"
      if [ -f "${REPO_DIR}/services/${new%.service}/${new}" ]; then
        echo "Not installing ${unit#"${REPO_DIR}"/}: it was renamed to ${new}." >&2
        continue
      fi ;;
  esac
  install -m 0644 "$unit" "${UNIT_DIR}/${name}"
done

# Seeding through the Gitea contents API does not preserve the executable bit,
# so restore it on the repo's own scripts.
chmod 0755 "${REPO_DIR}"/install/*.sh 2>/dev/null || true

# Expose the server-management tool on PATH. A symlink (not a copy) means a
# `git pull` in the repo updates the command too.
if [ -f "${REPO_DIR}/install/manage-model-servers.sh" ]; then
  ln -sfn "${REPO_DIR}/install/manage-model-servers.sh" /usr/local/bin/manage-model-servers
else
  echo "WARNING: ${REPO_DIR}/install/manage-model-servers.sh is missing, so manage-model-servers is not on PATH." >&2
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
# manage-model-servers.sh — add / remove / re-tier the model servers of
# a running open-smart-router container, without re-running the installer.
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
ROUTER_INI="${REPO_DIR}/services/osr-router/router.ini"
MONITOR_INI="${REPO_DIR}/services/osr-monitor/monitor.ini"
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
# Strata/Basalt/Maya/Xolotl/Avalon 8080, Kindi 8093); LMSTUDIO_PORT,
# STRATA_PORT, BASALT_PORT, MAYA_PORT, XOLOTL_PORT, AVALON_PORT and KINDI_PORT
# in the environment override them.
LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
SERVER_TYPE="auto"   # --type ollama|<kind>|auto for add / set-tier (see server_kinds)
MODEL_SERVER_MAX="${MODEL_SERVER_MAX:-20}"
MODEL_SERVER_MIN="${MODEL_SERVER_MIN:-1}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:8000}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
SERVICES=(litellm-proxy osr-router osr-monitor open-webui)
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
# OLD=NEW: units renamed with the project (apply moves an installed OLD unit to
# NEW), and the parent of their StateDirectory.
LEGACY_UNITS=(ollama-router=osr-router ollama-monitor=osr-monitor)
STATE_ROOT="${STATE_ROOT:-/var/lib}"
# The service account's name before the rename; apply renames it in place to
# SERVICE_USER (osr-router), keeping its UID, so file ownership is unchanged.
LEGACY_ACCOUNT="${LEGACY_ACCOUNT:-ollama-router}"
# Set by migrate_legacy_account: whether it renamed the account, and the units
# it stopped to do so.
ACCOUNT_RENAMED=false
ACCOUNT_STOPPED=()
# Snapshots of the runtime files taken before each apply (root-only).
APPLY_BACKUP_DIR="${APPLY_BACKUP_DIR:-/var/backups/open-smart-router}"
APPLY_BACKUP_KEEP="${APPLY_BACKUP_KEEP:-5}"
# The snapshot directory before the rename from Ollama Smart Router. The next
# apply moves its snapshots into APPLY_BACKUP_DIR, so they are found in one
# place and pruned with the rest. Empty leaves that directory alone.
APPLY_BACKUP_DIR_LEGACY="${APPLY_BACKUP_DIR_LEGACY-/var/backups/ollama-smart-router}"
# One config change at a time (this tool and install/update-router.sh share it).
# The lock is an flock on this file: it lasts only as long as the process that
# holds it, so a crash or reboot never leaves it in force. CONFIG_LOCK_WAIT
# seconds to wait for it (0 = fail at once); `clear-lock` deals with a hung holder.
CONFIG_LOCK_FILE="${CONFIG_LOCK_FILE:-/run/lock/open-smart-router-config.lock}"
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
                             LM Studio, Strata, Basalt, Maya, Xolotl, Avalon and
                             Kindi are detected automatically, or use
                             lmstudio://host / strata://host / basalt://host /
                             maya://host / xolotl://host / avalon://host /
                             kindi://host or --type.
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
  set-avalon-token [token|--off]
                             Bearer token for Avalon servers with an API key
                             (stored in secrets.env)
  set-kindi-token [token|--off]
                             Bearer token for Kindi servers with an API key
                             (stored in secrets.env)
  set-api-key [key|--generate|--off]
                             Require "Authorization: Bearer <key>" on OSR
                             API (Open WebUI is given the same key)
  set-cloud-key <openai|anthropic|gemini> [key|--off]
                             Store a provider API key in secrets.env (prompts
                             when omitted); --off removes its deployments
  set-cloud-models <openai|anthropic|gemini> <model[,model...]|--off>
                             Expose specific provider model IDs through OSR
  set-freellmapi <url|--off> [key]
                             Offer a FreeLLMAPI server's models as
                             freellmapi/<id>, used only when asked for by name
                             (never by auto or the tiers). <url> is its root
                             URL, e.g. http://10.0.0.20:3001; its unified API
                             key goes to secrets.env (prompts when omitted)
  set-webui-version [v]      Show, or pin, the Open WebUI version (use 'latest').
                             Checks the version exists and that the venv's
                             Python satisfies its Requires-Python
  clear-lock [--force]       Show who holds the config lock. A crash or reboot
                             never leaves it in force (it dies with its
                             process); a live but hung holder is only stopped
                             with --force (SIGTERM, then SIGKILL)

Options:
  --tier <t[,t...]>          With 'add': also assign the new server(s) to these tiers
  --type <ollama|lmstudio|strata|basalt|maya|xolotl|avalon|kindi> With 'add' / 'set-tier': the server's API (default:
                             auto-detect by probing; ollama when --no-probe)
  --apply                    Apply + restart services after the change
  --commit[=msg]             Commit and push the change after applying
  --no-probe                 Skip the reachability check when adding, and the
                             model-availability check when setting a model
  --dry-run                  Show what would change; write nothing
  --yes, -y                  Do not prompt for confirmation
  --force                    With 'clear-lock': stop the process holding the lock
  -h, --help                 This help

Examples (one or more for every command and option):

  Inspecting
    manage-model-servers.sh list
    manage-model-servers.sh status
    manage-model-servers.sh discover
    ROUTER_URL=http://10.0.0.20:8000 manage-model-servers.sh discover
    manage-model-servers.sh models

  Adding and removing servers
    manage-model-servers.sh add 10.0.0.55 --tier large --apply
    manage-model-servers.sh add ollama7.lan:11434 --tier fast,medium --apply --commit
    manage-model-servers.sh add http://10.0.0.56:11434 10.0.0.57 --tier medium
    manage-model-servers.sh add lmstudio://10.0.0.9 --tier fast --apply
    manage-model-servers.sh add 10.0.0.14:8093 --type kindi --tier xlarge --apply
    manage-model-servers.sh add 10.0.0.60 --no-probe --type ollama --tier fast
    manage-model-servers.sh add 10.0.0.61 --tier large --dry-run
    manage-model-servers.sh remove 10.0.0.52 --apply
    manage-model-servers.sh remove 3 --yes --apply
    manage-model-servers.sh remove 10.0.0.52 10.0.0.53 --apply --commit="Retire old GPU boxes"

  Tiers and models
    manage-model-servers.sh set-tier large 10.0.0.54 10.0.0.55 --apply
    manage-model-servers.sh set-tier fast strata://10.0.0.8 --type strata --apply
    manage-model-servers.sh set-model large qwen3:32b --apply --commit
    manage-model-servers.sh set-model fast llama3.2:3b --no-probe
    manage-model-servers.sh set-server-model large 10.0.0.54 llama3.3:70b --apply
    manage-model-servers.sh set-server-model medium 192.0.2.14 smtek/Qwen3.8-27B:Q3_K_XL-16gb --apply
    manage-model-servers.sh set-keepalive 2h --apply
    manage-model-servers.sh set-keepalive -1 --apply
    manage-model-servers.sh set-keepalive '' --apply

  Applying and committing
    manage-model-servers.sh apply
    manage-model-servers.sh apply --all
    manage-model-servers.sh commit
    manage-model-servers.sh commit "Move qwen3 to the large tier"

  Credentials and alerting
    manage-model-servers.sh set-token
    manage-model-servers.sh set-token <gitea-deploy-token>
    manage-model-servers.sh set-api-key --generate --apply
    manage-model-servers.sh set-api-key <key> --apply
    manage-model-servers.sh set-api-key --off --apply
    manage-model-servers.sh set-lmstudio-token <token> --apply
    manage-model-servers.sh set-strata-token <token> --apply
    manage-model-servers.sh set-basalt-token <token> --apply
    manage-model-servers.sh set-maya-token <token> --apply
    manage-model-servers.sh set-xolotl-token <token> --apply
    manage-model-servers.sh set-avalon-token <token> --apply
    manage-model-servers.sh set-kindi-token <token> --apply
    manage-model-servers.sh set-kindi-token --off --apply
    manage-model-servers.sh set-webhook https://mm.example.lan/hooks/abc123 --apply
    manage-model-servers.sh set-webhook --channel alerts --username osr-monitor --apply
    manage-model-servers.sh set-webhook --verify-tls false --apply
    manage-model-servers.sh set-webhook --channel '' --apply
    manage-model-servers.sh set-webhook '' --apply
    manage-model-servers.sh test-alert
    manage-model-servers.sh test-alert "Hello from manage-model-servers"

  Maintenance
    manage-model-servers.sh set-webui-version
    manage-model-servers.sh set-webui-version 0.12.4 --apply
    manage-model-servers.sh set-webui-version latest --apply
    manage-model-servers.sh clear-lock
    manage-model-servers.sh clear-lock --force
    manage-model-servers.sh --help

  Environment overrides
    CT_ID=105 manage-model-servers.sh list            (on the Proxmox host: skip the container search)
    CONFIG_REPO_DIR=/srv/osr-config manage-model-servers.sh list
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
server_kinds() { printf '%s\n' lmstudio strata basalt maya xolotl avalon kindi; }
kind_field() {
  local spec key label port_var port_default openai value
  case "$1" in
    lmstudio) spec='LMSTUDIO_API_TOKEN|LM Studio|LMSTUDIO_PORT|1234|0' ;;
    strata)   spec='STRATA_API_KEY|Strata|STRATA_PORT|8080|1' ;;
    basalt)   spec='BASALT_API_KEY|Basalt|BASALT_PORT|8080|1' ;;
    maya)     spec='MAYA_API_KEY|Maya|MAYA_PORT|8080|1' ;;
    xolotl)   spec='XOLOTL_API_KEY|Xolotl|XOLOTL_PORT|8080|1' ;;
    avalon)   spec='AVALON_API_KEY|Avalon|AVALON_PORT|8080|1' ;;
    kindi)    spec='KINDI_API_KEY|Kindi|KINDI_PORT|8093|1' ;;
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
# Membership tests read the whole list before comparing. "list | grep -q" lets
# grep exit at the first match while the list is still being written; under
# pipefail the writer's SIGPIPE (or EPIPE, when SIGPIPE is ignored, as under
# pct exec) then fails the test even though the key matched.
is_server_kind() {
  local k
  [[ -n "$1" ]] || return 1
  for k in $(server_kinds); do [[ "$k" == "$1" ]] && return 0; done
  return 1
}
is_openai_kind() { is_server_kind "$1" && [[ "$(kind_field "$1" openai)" == 1 ]]; }
openai_kinds() { local k; for k in $(server_kinds); do is_openai_kind "$k" && echo "$k"; done; return 0; }
# "Ollama, LM Studio, Strata, Basalt, Maya, Xolotl, Avalon or Kindi"
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
    if [[ "$hostport" != *:* || "$hostport" == *']' ]]; then
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
    # Kindi names itself and its version ("kindi": "0.4.0") on /health.
    if [[ "$body" =~ \"kindi\"[[:space:]]*:[[:space:]]*\"[0-9] ]]; then
      echo kindi; return 0
    fi
  fi
  local code path status_code=''
  body="$(curl -sS --max-time "$PROBE_TIMEOUT" -w '\n%{http_code}' "${base}/v1/status" 2>/dev/null || true)"
  status_code="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [[ "$status_code" == 200 && "$body" == *'"auto_load"'* && "$body" == *'"loaded"'* ]]; then
    echo strata; return 0
  fi
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/v1/models" 2>/dev/null)"; then
    if [[ "$body" =~ \"(id|owned_by)\"[[:space:]]*:[[:space:]]*\"strata\" ]]; then
      echo strata; return 0
    fi
    # Avalon serves llama.cpp's API (its /health says only "status"): a
    # llama-server whose model id names Avalon (qwen3.8-flash-next-avalon).
    if [[ "$body" =~ \"owned_by\"[[:space:]]*:[[:space:]]*\"llamacpp\" ]] &&
       [[ "$body" =~ \"id\"[[:space:]]*:[[:space:]]*\"[^\"]*avalon[^\"]*\" ]]; then
      echo avalon; return 0
    fi
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
  printf '%s\n' GITEA_DEPLOY_TOKEN MATTERMOST_WEBHOOK_URL ROUTER_API_KEY OPENAI_API_KEYS \
    OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY FREELLMAPI_API_KEY
  for k in $(server_kinds); do kind_field "$k" key; done
}
is_secret_key() {
  local k
  for k in $(secret_keys); do [[ "$k" == "$1" ]] && return 0; done
  return 1
}

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
  # root:osr-router ownership and mode instead of inheriting the temp file's.
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
  chown root:osr-router "$SECRETS_FILE" 2>/dev/null || true
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
    note "  They may still be in the repo's git history. Rotate any exposed"
    note "  provider API keys, deploy tokens or webhooks if the repo was pushed."
  fi
}

# ini_get FILE SECTION KEY: the value of KEY in [SECTION], or nothing.
ini_get() {
  [[ -f "$1" ]] || return 0
  awk -v section="[$2]" -v key="$3" '
    /^[[:space:]]*\[/ { inside = ($1 == section); next }
    inside && !/^[[:space:]]*[#;]/ {
      at = index($0, "=")
      if (!at) next
      name = substr($0, 1, at - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name != key) next
      value = substr($0, at + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value; exit
    }' "$1"
}

# Take out of the version-controlled env file the settings older installers
# wrote there that do nothing, or only repeat another setting:
#   * LITELLM_HEALTH_URL and MODEL_SERVER_COUNT are read by nothing;
#   * LITELLM_URL, when it is LITELLM_BASE_URL plus the chat path, which is
#     what the router uses without it;
#   * MONITOR_INTERVAL_SECONDS and KEEP_ALIVE_REFRESH_SECONDS, when they say
#     what monitor.ini says (or nothing). They override monitor.ini, so left in
#     place they keep a later edit of monitor.ini from taking effect.
# Nothing that runs changes: a value that differs from what it would repeat
# was put there on purpose and stays. Runs before every commit and apply.
tidy_env() {
  local key value base section option fallback removed=""
  $DRY_RUN && return 0
  [[ -f "$ENV_FILE" ]] || return 0
  for key in LITELLM_HEALTH_URL MODEL_SERVER_COUNT; do
    if kv_has "$ENV_FILE" "$key"; then
      kv_del "$ENV_FILE" "$key"; removed+=" ${key}"
    fi
  done
  if kv_has "$ENV_FILE" LITELLM_URL; then
    base="$(kv_get "$ENV_FILE" LITELLM_BASE_URL)"
    base="${base:-http://127.0.0.1:4000}"
    if [[ "$(kv_get "$ENV_FILE" LITELLM_URL)" == "${base%/}/v1/chat/completions" ]]; then
      kv_del "$ENV_FILE" LITELLM_URL; removed+=" LITELLM_URL"
    fi
  fi
  while read -r key section option fallback; do
    kv_has "$ENV_FILE" "$key" || continue
    value="$(kv_get "$ENV_FILE" "$key")"
    base="$(ini_get "$MONITOR_INI" "$section" "$option")"
    if [[ -z "$value" || "$value" == "${base:-$fallback}" ]]; then
      kv_del "$ENV_FILE" "$key"; removed+=" ${key}"
    fi
  done <<'SETTINGS'
MONITOR_INTERVAL_SECONDS polling interval_seconds 15
KEEP_ALIVE_REFRESH_SECONDS keep_alive refresh_seconds 240
SETTINGS
  if [[ -n "$removed" ]]; then
    note "Tidied $(basename "$ENV_FILE"): removed${removed} (unused, or the same as the setting"
    note "  it repeated). Nothing that runs changes; the next commit records it."
  fi
  return 0
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

cloud_key_name() {
  case "$1" in
    openai) echo OPENAI_API_KEY ;;
    anthropic) echo ANTHROPIC_API_KEY ;;
    gemini) echo GEMINI_API_KEY ;;
    *) die "cloud provider must be openai, anthropic or gemini (got '$1')" ;;
  esac
}

cloud_models_name() { printf 'CLOUD_%s_MODELS\n' "${1^^}"; }

validate_cloud_models() {
  local id provider="$1" value="$2"
  cloud_key_name "$provider" >/dev/null || return 1
  [[ -n "$value" ]] || return 0
  while IFS= read -r id; do
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || die "invalid ${provider} model ID '$id'"
  done < <(csv_to_lines "$value")
}

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
  grep -Fxq -- "$tag" <<< "$names" && return 0
  # Ollama treats a bare name as ":latest", so accept that spelling too.
  if [[ "$(server_kind "$url")" == ollama && "$tag" != *:* ]]; then
    grep -Fxq -- "${tag}:latest" <<< "$names" && return 0
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
  local freellmapi; freellmapi="$(env_get FREELLMAPI_BASE_URL)"
  if [[ -n "$freellmapi" ]]; then
    echo "FreeLLMAPI: ${freellmapi} (freellmapi/<id>; only when named, never by auto)"
  fi
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
    note "  Check it is running:  systemctl status osr-router"
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
# same host cannot succeed where the original failed. A tier with Kindi is a
# fallback only for another Kindi tier on other Kindi servers: the router waits
# read_timeout_seconds (not Kindi's budget) on a request for a tier without
# Kindi, and a fallback to the same Kindi server would queue behind the request
# it is still reading.
litellm_fallbacks() {
  python3 -c '
import json, re, sys
tiers = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        name, _, sig = line.partition(" ")
        tiers.append((name, sig))
def kindi(sig):
    return set(re.findall(r"kindi[+][^,@\s]+", sig))
def may_fall_back(sig, osig):
    return not kindi(osig) or (kindi(sig) and not kindi(sig) & kindi(osig))
rows = []
for i, (name, sig) in enumerate(tiers):
    others = [(abs(i - j), j, other) for j, (other, osig) in enumerate(tiers)
              if other != name and osig != sig and may_fall_back(sig, osig)]
    if others:
        rows.append("    - %s: %s" % (name, json.dumps([o for _, _, o in sorted(others)])))
if rows:
    print("  fallbacks:")
    print("\n".join(rows))
'
}

# router_settings.model_group_retry_policy for litellm_config.yaml, from the
# same "<model_name> <signature>" lines. Kindi serves one request at a time and
# upstream asks for one retry at most: no retry after a timeout (Kindi may
# still be reading the prompt), one after a 429. LiteLLM 1.75 does not read
# InternalServerErrorRetries, so the router caps every other error at one retry
# with x-litellm-num-retries: 1 on requests for these tiers. Policies for other
# current tiers are kept, block or flow style. The marker lets removal discard
# only OSR's policy; the unmarked forms written before it are recognised too.
litellm_retry_policy() {
  python3 -c '
import re, sys
tiers = dict(line.strip().partition(" ")[::2] for line in sys.stdin.read().splitlines() if line.strip())
with open(sys.argv[1], encoding="utf-8") as source:
    old = source.read().splitlines()
preserved = {}
in_policy = False
name = None
for line in old:
    if line == "  model_group_retry_policy:":
        in_policy = True
        continue
    if in_policy and line and not line.startswith("    "):
        in_policy = False
    if not in_policy:
        continue
    match = re.match(r"^    ([^:#\s][^:#]*):\s*(.*)$", line)
    if match:
        name = match.group(1).strip().strip("\"\x27")
        if name in tiers and "@kindi+" not in tiers[name]:
            preserved[name] = [line]
        if match.group(2) and not match.group(2).startswith("#"):
            name = None  # a flow-style entry is complete on its line
        continue
    if name in preserved:
        preserved[name].append(line)
unmarked = ({"TimeoutErrorRetries: 0", "InternalServerErrorRetries: 1", "RateLimitErrorRetries: 1"},
            {"TimeoutErrorRetries: 0", "RateLimitErrorRetries: 1"})
for name, lines in list(preserved.items()):
    fields = {line.strip() for line in lines[1:] if line.strip() and not line.lstrip().startswith("#")}
    if any("# osr-kindi-policy" in line for line in lines) or fields in unmarked:
        del preserved[name]
rows = []
for name, sig in tiers.items():
    if "@kindi+" in sig:
        rows += ["    %s:" % name, "      # osr-kindi-policy", "      TimeoutErrorRetries: 0",
                 "      RateLimitErrorRetries: 1"]
    elif name in preserved:
        rows += preserved[name]
if rows:
    print("  model_group_retry_policy:")
    print("\n".join(rows))
' "$LITELLM_YAML"
}

# kindi_timeout_seconds: the router's Kindi read budget from router.ini, never
# below read_timeout_seconds (as router.py computes it), in whole seconds.
kindi_timeout_seconds() {
  python3 -c 'import configparser, math, sys; c=configparser.ConfigParser(); c.read(sys.argv[1]); print(math.ceil(max(c.getfloat("http", "read_timeout_seconds", fallback=300), c.getfloat("http", "kindi_read_timeout_seconds", fallback=3600))))' "$ROUTER_INI"
}

# sync_kindi_timeouts: give every Kindi deployment in litellm_config.yaml the
# router.ini budget, so `apply` after editing kindi_read_timeout_seconds keeps
# LiteLLM in step without rebuilding the model list. Only the timeout line of
# a deployment whose api_base is a configured Kindi server changes.
sync_kindi_timeouts() {
  local timeout url changed
  local -a bases=()
  [[ -f "$LITELLM_YAML" ]] || return 0
  timeout="$(kindi_timeout_seconds)" || die 'Invalid router.ini timeout.'
  while IFS= read -r url; do
    [[ -n "$url" && "$(server_kind "$url")" == kindi ]] && bases+=("$(litellm_api_base "$url")")
  done < <(get_servers)
  ((${#bases[@]})) || return 0
  changed="$(KINDI_BASES="${bases[*]}" python3 - "$LITELLM_YAML" "$timeout" <<'PY'
import os, re, sys
path, timeout = sys.argv[1], sys.argv[2]
bases = set(os.environ["KINDI_BASES"].split())
lines = open(path, encoding="utf-8").read().splitlines()
out, block, changed = [], [], False
def flush():
    global changed
    base = next((m.group(1) for m in (re.match(r"^      api_base:\s*(\S+)\s*$", l) for l in block) if m), None)
    if base in bases:
        want = "      timeout: %s" % timeout
        if want not in block:
            kept = [l for l in block if not re.match(r"^      timeout:", l)]
            at = next(i for i, l in enumerate(kept) if l.startswith("      api_base:")) + 1
            block[:] = kept[:at] + [want] + kept[at:]
            changed = True
    out.extend(block)
    block.clear()
in_list = False
for line in lines:
    if line.startswith("  - model_name:") and in_list:
        flush()
    if re.match(r"^\S", line):
        flush()
        in_list = line.startswith("model_list:")
        out.append(line)
        continue
    (block if in_list else out).append(line)
flush()
if changed:
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
print("yes" if changed else "")
PY
)" || die "Could not update the Kindi timeouts in ${LITELLM_YAML}."
  [[ -z "$changed" ]] || echo "  Kindi deployments in $(basename "$LITELLM_YAML") now wait ${timeout}s (router.ini)."
}

# kindi_budget_note OLD NEW: after an apply that changed the router's Kindi
# read budget, say what does not follow it. The dispatchers of Hermes, OpenClaw
# and Honcho take a lower budget from the router at once, but keep their own
# for a higher one (their callers' limits were sized for it) and log that.
kindi_budget_note() {
  local old="$1" new="$2" url kindi=false
  [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || return 0
  while IFS= read -r url; do
    [[ -n "$url" && "$(server_kind "$url")" == kindi ]] && kindi=true
  done < <(get_servers)
  $kindi || return 0
  echo "The router's Kindi read budget is now ${new}s (was ${old}s)."
  if (( new > old )); then
    echo "  Hermes, OpenClaw and Honcho keep ${old}s until each is reconfigured:"
  else
    echo "  Their dispatchers already use ${new}s; their callers' longer limits stay until each is reconfigured:"
  fi
  echo "  run its targets/<hermes|openclaw|honcho>/provision-lxc.sh --reconfigure on the Proxmox host."
}

regenerate_litellm() {
  local tmp tier name tag tier_tag url tail_block keep_alive fallbacks retry_policy sig kindi_timeout
  local provider cloud_key cloud_ids cloud_id
  local -a sig_lines=()
  local kind key_env k
  local -A kind_has_token=()
  keep_alive="$(env_get OLLAMA_KEEP_ALIVE)"
  for k in $(server_kinds); do
    [[ -n "$(env_get "$(kind_field "$k" key)")" ]] && kind_has_token[$k]=1
  done
  $DRY_RUN && { echo "  [dry-run] would regenerate ${LITELLM_YAML}"; return 0; }
  [[ -f "$LITELLM_YAML" ]] || die "missing ${LITELLM_YAML}"
  kindi_timeout="$(kindi_timeout_seconds)" || die 'Invalid router.ini timeout.'
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
        if [[ "$kind" == kindi ]]; then
          # A first prompt can take minutes on a small card, and Kindi serves
          # one request at a time: allow the hour its agent guide asks for.
          printf '      timeout: %s\n' "$kindi_timeout"
        fi
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
    for provider in openai anthropic gemini; do
      cloud_key="$(cloud_key_name "$provider")"
      cloud_ids="$(env_get "$(cloud_models_name "$provider")")"
      validate_cloud_models "$provider" "$cloud_ids"
      [[ -n "$(env_get "$cloud_key")" ]] || continue
      while IFS= read -r cloud_id; do
        [[ -n "$cloud_id" ]] || continue
        printf '  - model_name: %s/%s\n' "$provider" "$cloud_id"
        printf '    litellm_params:\n'
        printf '      model: %s/%s\n' "$provider" "$cloud_id"
        printf '      api_key: os.environ/%s\n' "$cloud_key"
      done < <(csv_to_lines "$cloud_ids" | sort -u)
    done
    # router_settings: every hand-edited key (strategy, retries, ...) is kept,
    # `fallbacks` are regenerated. Retry policies for non-Kindi tiers survive;
    # stale tiers and Kindi-specific policies are regenerated.
    fallbacks="$( ((${#sig_lines[@]})) && printf '%s\n' "${sig_lines[@]}" | litellm_fallbacks)"
    retry_policy="$( ((${#sig_lines[@]})) && printf '%s\n' "${sig_lines[@]}" | litellm_retry_policy)"
    tail_block="$(awk '/^router_settings:/{f=1} f' "$LITELLM_YAML")"
    [[ -n "$tail_block" ]] || tail_block=$'router_settings:\n  routing_strategy: latency-based-routing\n  num_retries: 2\n  timeout: 600'
    printf '%s\n' "$tail_block" | FALLBACKS="$fallbacks" RETRY_POLICY="$retry_policy" awk '
      /^router_settings:/ {
        print
        if (ENVIRON["FALLBACKS"] != "") print ENVIRON["FALLBACKS"]
        if (ENVIRON["RETRY_POLICY"] != "") print ENVIRON["RETRY_POLICY"]
        next
      }
      skip && ($0 ~ /^   / || $0 ~ /^  -/) { next }
      { skip = 0 }
      /^  (fallbacks|model_group_retry_policy):/ { skip = 1; next }
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

# litellm_venv_fingerprint WANT HAVE: everything the import test's result
# depends on, on one line: the pinned and installed versions, the lock the venv
# is built from, the interpreter behind the venv, and its site-packages
# directories (pip changes a directory's modification time with every package
# it adds, replaces or removes there).
litellm_venv_fingerprint() {
  local venv="${LITELLM_DIR}/venv" lock='-' python packages
  [[ ! -f "$LITELLM_LOCK" ]] || lock="$(sha256sum < "$LITELLM_LOCK" | cut -d' ' -f1)"
  python="$(readlink -f "${venv}/bin/python" 2>/dev/null || true)"
  python+=" $(stat -c '%Y %s' "$python" 2>/dev/null || true)"
  packages="$(stat -c '%n %Y' "$venv"/lib/python*/site-packages 2>/dev/null | tr '\n' ' ' || true)"
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$lock" "$python" "$packages"
}

# True when the venv has the pinned litellm AND the proxy extra's imports work.
# The import is the real test: a plain `litellm` install passes a version check
# but `litellm --config` then dies with "Missing dependency ... backoff".
# Importing the proxy takes several seconds, and every apply asks, so a passed
# test is remembered in the venv with litellm_venv_fingerprint and repeated only
# when that changes (a rebuilt venv has no record at all).
litellm_venv_ok() {
  local want have print stamp="${LITELLM_DIR}/venv/.osr-imports-ok"
  want="$(litellm_pinned_version)"
  have="$(litellm_installed_version)"
  [[ -n "$have" ]] || return 1
  [[ -z "$want" || "$want" == "$have" ]] || return 1
  print="$(litellm_venv_fingerprint "$want" "$have")"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$print" ]]; then
    return 0
  fi
  if ! "${LITELLM_DIR}/venv/bin/python" -c 'import litellm.proxy.proxy_server' >/dev/null 2>&1; then
    rm -f "$stamp" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$print" > "$stamp" 2>/dev/null || true
  return 0
}

# Build (or bring up to date) LiteLLM's own venv, hash-checked when the repo
# carries requirements.lock.
litellm_install() {
  local pip="${LITELLM_DIR}/venv/bin/pip" rc=0
  # The service runs as osr-router from this root-owned tree: build it world-
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
SERVICE_USER="${SERVICE_USER:-osr-router}"

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
from urllib.parse import urlsplit

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
    entries = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.strip() and not line.lstrip().startswith("#") \
                and not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", line):
            err(rel, "line %d is not KEY=value: %r" % (number, line[:60]))
        elif "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            entries[key] = value
    if rel == "env/router.env":
        for provider in ("OPENAI", "ANTHROPIC", "GEMINI"):
            for model in filter(None, entries.get("CLOUD_%s_MODELS" % provider, "").split(",")):
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", model):
                    err(rel, "CLOUD_%s_MODELS has invalid ID %r" % (provider, model))
        base = entries.get("SUBSCRIPTION_GATEWAY_BASE_URL", "").rstrip("/")
        if base:
            try:
                url = urlsplit(base)
                allowed = (url.scheme == "https" or (url.scheme == "http" and
                           url.hostname in ("localhost", "127.0.0.1", "::1")))
                valid = allowed and bool(url.hostname) and \
                    (url.port is None or url.port > 0) and not (
                    url.path or url.username or url.password or url.query or url.fragment)
            except ValueError:
                valid = False
            if not valid:
                err(rel, "SUBSCRIPTION_GATEWAY_BASE_URL needs HTTPS or loopback HTTP root URL")
        base = entries.get("FREELLMAPI_BASE_URL", "").rstrip("/")
        if base:
            try:
                url = urlsplit(base)
                valid = url.scheme in ("http", "https") and bool(url.hostname) and \
                    (url.port is None or url.port > 0) and not (
                    url.path or url.username or url.password or url.query or url.fragment)
            except ValueError:
                valid = False
            if not valid:
                err(rel, "FREELLMAPI_BASE_URL needs a root URL such as http://10.0.0.20:3001")
        if entries.get("FREELLMAPI_MODELS", "available") not in ("", "available", "auto"):
            err(rel, "FREELLMAPI_MODELS must be available or auto")

# Python services must at least compile.
for rel in ("services/osr-router/router.py", "services/osr-monitor/monitor.py"):
    try:
        compile((repo / rel).read_text(), rel, "exec")
    except (OSError, SyntaxError) as exc:
        err(rel, "does not compile: %s" % exc)

# router.ini
rel = "services/osr-router/router.ini"
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
    # Numbers the router reads at start: a bad one would stop it from starting.
    for section, option in (("discovery", "show_cache_seconds"), ("balancing", "busy_penalty"),
                            ("balancing", "sticky_seconds")):
        if cp.has_option(section, option) and float(cp.get(section, option)) < 0:
            err(rel, "[%s] %s must not be negative" % (section, option))
except (configparser.Error, ValueError) as exc:
    err(rel, str(exc))

# monitor.ini
rel = "services/osr-monitor/monitor.ini"
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
            provider = str(params.get("model") or "").split("/", 1)[0]
            cloud_keys = {"openai": "OPENAI_API_KEY", "anthropic": "ANTHROPIC_API_KEY",
                          "gemini": "GEMINI_API_KEY"}
            if not (item or {}).get("model_name") or not params.get("model"):
                err(rel, "model_list[%d] needs model_name and litellm_params.model" % index)
            elif provider in cloud_keys and not params.get("api_base") and params.get("api_key") != \
                    "os.environ/" + cloud_keys[provider]:
                err(rel, "model_list[%d] needs its %s API key reference" % (index, provider))
            elif provider not in cloud_keys and not params.get("api_base"):
                err(rel, "model_list[%d] needs litellm_params.api_base" % index)
            else:
                names.add(item["model_name"])
                deployments.setdefault(item["model_name"], set()).add(
                    (params["model"], params.get("api_base", "")))
        settings = (doc.get("router_settings") or {}) if isinstance(doc, dict) else {}
        for entry in settings.get("fallbacks") or []:
            if not isinstance(entry, dict) or len(entry) != 1:
                err(rel, "each fallbacks entry must be {tier: [tiers]}")
                continue
            (source, targets), = entry.items()
            for name in [source] + list(targets or []):
                if name not in names:
                    err(rel, "fallback names %r, which has no deployment" % name)
        policy = settings.get("model_group_retry_policy") or {}
        retry_fields = {"BadRequestErrorRetries", "AuthenticationErrorRetries", "TimeoutErrorRetries",
                        "RateLimitErrorRetries", "ContentPolicyViolationErrorRetries",
                        "InternalServerErrorRetries"}
        if not isinstance(policy, dict):
            err(rel, "model_group_retry_policy must map tiers to retry counts")
            policy = {}
        for name, counts in policy.items():
            if name not in names:
                err(rel, "model_group_retry_policy names %r, which has no deployment" % name)
            if not isinstance(counts, dict) or any(
                    key not in retry_fields or not isinstance(value, int) or isinstance(value, bool) or value < 0
                    for key, value in counts.items()):
                err(rel, "model_group_retry_policy %r needs <Error>Retries: <count> entries" % name)

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
services/osr-router/router.py|${ROUTER_DIR}/router.py|osr-router
services/osr-router/router.ini|${ROUTER_DIR}/router.ini|osr-router
services/osr-monitor/monitor.py|${ROUTER_DIR}/monitor.py|osr-monitor
services/osr-monitor/monitor.ini|${ROUTER_DIR}/monitor.ini|osr-monitor
services/litellm-proxy/litellm_config.yaml|${ROUTER_DIR}/litellm_config.yaml|litellm-proxy
env/router.env|${ROUTER_DIR}/.env|litellm-proxy osr-router osr-monitor
env/openwebui.env|${OPENWEBUI_DIR}/.env|open-webui
services/litellm-proxy/litellm-proxy.service|${UNIT_DIR}/litellm-proxy.service|litellm-proxy
services/osr-router/osr-router.service|${UNIT_DIR}/osr-router.service|osr-router
services/osr-monitor/osr-monitor.service|${UNIT_DIR}/osr-monitor.service|osr-monitor
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
    want[osr-router]=1; want[osr-monitor]=1; want[open-webui]=1
  fi
  for svc in "${SERVICES[@]}"; do
    systemctl is-active --quiet "${svc}.service" 2>/dev/null || want[$svc]=1
  done
  for svc in "${SERVICES[@]}"; do
    [[ -n "${want[$svc]:-}" ]] && printf '%s\n' "$svc"
  done
  return 0
}

# Move the snapshots taken before the rename (APPLY_BACKUP_DIR_LEGACY) into
# APPLY_BACKUP_DIR and remove the old directory once it is empty. Snapshot
# names are timestamps, so the moved ones sort before new ones and are pruned
# first. A name already present in APPLY_BACKUP_DIR is left where it is.
# Never fails: an apply must not stop over an old snapshot.
adopt_legacy_snapshots() {
  local old name moved=0
  [[ -n "${APPLY_BACKUP_DIR_LEGACY:-}" && "$APPLY_BACKUP_DIR_LEGACY" != "$APPLY_BACKUP_DIR" \
     && -d "$APPLY_BACKUP_DIR_LEGACY" ]] || return 0
  mkdir -p "$APPLY_BACKUP_DIR" 2>/dev/null && chmod 0700 "$APPLY_BACKUP_DIR" 2>/dev/null || return 0
  for old in "$APPLY_BACKUP_DIR_LEGACY"/*/; do
    [[ -d "$old" ]] || continue
    old="${old%/}"; name="${old##*/}"
    [[ ! -e "${APPLY_BACKUP_DIR}/${name}" ]] || continue
    if mv -- "$old" "${APPLY_BACKUP_DIR}/${name}" 2>/dev/null; then moved=$((moved + 1)); fi
  done
  rmdir -- "$APPLY_BACKUP_DIR_LEGACY" 2>/dev/null || true
  if (( moved > 0 )); then
    note "  moved ${moved} snapshot(s) from ${APPLY_BACKUP_DIR_LEGACY} to ${APPLY_BACKUP_DIR}"
  fi
  return 0
}

# Copy every runtime file apply-config.sh may overwrite into a new timestamped
# snapshot directory; print its path. Old snapshots beyond APPLY_BACKUP_KEEP
# are pruned, those from before the rename included (adopt_legacy_snapshots).
snapshot_runtime() {
  local dir src dest svcs
  adopt_legacy_snapshots
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
    osr-router|ollama-router) printf '%s/healthz\n' "$ROUTER_URL" ;;
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

# After the new units have passed their health checks, take out the stopped
# pre-rename units and move their StateDirectory to the new name. Prints the
# new units whose old unit was enabled, to enable in turn.
# Never fails: a leftover old unit is reported, not fatal.
migrate_legacy_units() {
  local pair old new was_enabled
  for pair in "${LEGACY_UNITS[@]}"; do
    old="${pair%%=*}"; new="${pair#*=}"
    [[ -f "${UNIT_DIR}/${old}.service" && -f "${UNIT_DIR}/${new}.service" ]] || continue
    was_enabled=false
    systemctl is-enabled --quiet "${old}.service" >/dev/null 2>&1 && was_enabled=true
    echo "  ${old}.service is now ${new}.service: stopping and removing the old unit" >&2
    systemctl disable --now "${old}.service" >/dev/null 2>&1 ||
      systemctl stop "${old}.service" >/dev/null 2>&1 || true
    rm -f -- "${UNIT_DIR}/${old}.service" ||
      note "  WARNING: could not remove ${UNIT_DIR}/${old}.service; remove it by hand."
    if [[ -d "${STATE_ROOT}/${old}" && ! -e "${STATE_ROOT}/${new}" ]]; then
      mv -- "${STATE_ROOT}/${old}" "${STATE_ROOT}/${new}" 2>/dev/null || true
    fi
    if $was_enabled; then printf '%s\n' "$new"; fi
  done
  return 0
}

# Rename the pre-rename service account (LEGACY_ACCOUNT) to SERVICE_USER, with
# its group: usermod/groupmod keep the UID and GID, so every file it owns
# stays its own. Linux refuses to rename an account a process runs as, so the
# units that run as it are stopped first (ACCOUNT_STOPPED; the caller restarts
# them) and started again here if the rename fails. On such an install the
# alert channel and posting name the monitor used by default are written to
# env/router.env when missing, so alerts keep going where they went.
# Returns 1 when the account could not be renamed (nothing else was changed).
migrate_legacy_account() {
  local old="$LEGACY_ACCOUNT" new="$SERVICE_USER" f
  ACCOUNT_RENAMED=false; ACCOUNT_STOPPED=()
  [[ -n "$old" && "$old" != "$new" ]] || return 0
  getent passwd "$old" >/dev/null 2>&1 || return 0
  if getent passwd "$new" >/dev/null 2>&1; then
    note "WARNING: both ${old} and ${new} accounts exist; the services run as ${new}. Remove ${old} by hand."
    return 0
  fi
  for f in "${UNIT_DIR}"/*.service; do
    [[ -f "$f" ]] && grep -qx "User=${old}" "$f" && ACCOUNT_STOPPED+=("$(basename "$f" .service)")
  done
  echo "  The service account ${old} is now ${new}: stopping ${ACCOUNT_STOPPED[*]:-no service} to rename it" >&2
  if (( ${#ACCOUNT_STOPPED[@]} )); then
    systemctl stop "${ACCOUNT_STOPPED[@]/%/.service}" >/dev/null 2>&1 || true
  fi
  if usermod -l "$new" "$old" >/dev/null 2>&1; then
    if ! getent group "$old" >/dev/null 2>&1 || groupmod -n "$new" "$old" >/dev/null 2>&1; then
      ACCOUNT_RENAMED=true
    else
      usermod -l "$old" "$new" >/dev/null 2>&1 || true
    fi
  fi
  if ! $ACCOUNT_RENAMED; then
    note "ERROR: could not rename the service account ${old} to ${new} (is a process still running as ${old}?)."
    if (( ${#ACCOUNT_STOPPED[@]} )); then
      systemctl start "${ACCOUNT_STOPPED[@]/%/.service}" >/dev/null 2>&1 || true
    fi
    ACCOUNT_STOPPED=()
    return 1
  fi
  # The monitor's defaults before the rename:
  kv_has "$ENV_FILE" MATTERMOST_CHANNEL || kv_set "$ENV_FILE" MATTERMOST_CHANNEL ollama-monitor  # pre-rename
  kv_has "$ENV_FILE" MATTERMOST_MONITOR_USER || kv_set "$ENV_FILE" MATTERMOST_MONITOR_USER OllamaMonitor  # pre-rename
  return 0
}

# Give the local Prometheus (install/setup-metrics.sh) the router key again
# after an apply, in case the key changed. Does nothing where that stack is not
# installed, and never fails an apply: the scrape only shows 401 until fixed.
sync_metrics_key() {
  [[ -f "${REPO_DIR}/install/setup-metrics.sh" && -f "${UNIT_DIR}/osr-prometheus.service" ]] || return 0
  bash "${REPO_DIR}/install/setup-metrics.sh" sync-key ||
    note 'WARNING: Prometheus scrape key could not be updated; rerun setup-metrics.sh sync-key.'
  return 0
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
  local svc pair old new snapshot failed webui_from=""
  local -a affected=() legacy_pairs=() legacy_running=() renamed=() rollback=()
  if $DRY_RUN; then echo "  [dry-run] would apply config and restart services"; return 0; fi
  # Checked with -f, not -x: seeding through the Gitea contents API does not
  # preserve the executable bit, and we invoke it via `bash` anyway.
  [[ -f "$APPLY_SCRIPT" ]] || die "apply script not found: ${APPLY_SCRIPT}"
  migrate_secrets
  tidy_env
  sync_kindi_timeouts

  echo "Validating configuration..."
  if ! validate_config; then
    note "Configuration is invalid; nothing was applied or restarted."
    return 1
  fi

  mapfile -t affected < <(affected_services)
  local budget_before="" budget_after=""
  [[ ! -f "${ROUTER_DIR}/router.ini" ]] ||
    budget_before="$(ROUTER_INI="${ROUTER_DIR}/router.ini" kindi_timeout_seconds 2>/dev/null)" || budget_before=""
  budget_after="$(kindi_timeout_seconds 2>/dev/null)" || budget_after=""
  # Remember which old services were running before the account migration
  # stops them. Their units stay in place until the replacements are healthy.
  for pair in "${LEGACY_UNITS[@]}"; do
    old="${pair%%=*}"; new="${pair#*=}"
    [[ -f "${UNIT_DIR}/${old}.service" &&
       ( -f "${UNIT_DIR}/${new}.service" || -f "${REPO_DIR}/services/${new}/${new}.service" ) ]] || continue
    legacy_pairs+=("$pair")
    if systemctl is-active --quiet "${old}.service" 2>/dev/null; then
      legacy_running+=("$old")
    fi
  done
  # Before apply-config.sh, which gives the env files the new account's group.
  if ! migrate_legacy_account; then
    note "Nothing was applied."
    return 1
  fi
  affected+=("${ACCOUNT_STOPPED[@]}")
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
  for pair in "${legacy_pairs[@]}"; do
    old="${pair%%=*}"; new="${pair#*=}"
    systemctl stop "${old}.service" >/dev/null 2>&1 ||
      note "WARNING: could not stop ${old}.service before starting ${new}.service."
    affected+=("$new")
  done
  mapfile -t affected < <(for svc in "${SERVICES[@]}"; do
    printf '%s\n' "${affected[@]}" | grep -qx -- "$svc" && echo "$svc"; done)
  if (( ${#affected[@]} )); then
    echo "Restarting: ${affected[*]}"
    if ! failed="$(restart_and_check "${affected[@]}")"; then
      note "ERROR: ${failed} did not become healthy. Rolling back to the previous files..."
      note "  (see: journalctl -u ${failed} -n 50)"
      # Stop the replacements before bringing back the old units on the same
      # ports. Leave the old unit files and their enabled state in place.
      for pair in "${legacy_pairs[@]}"; do
        systemctl stop "${pair#*=}.service" >/dev/null 2>&1 || true
      done
      restore_runtime "$snapshot"
      # A renamed account is not renamed back: point the restored units at it.
      if $ACCOUNT_RENAMED; then
        sed -i -e "s/^User=${LEGACY_ACCOUNT}\$/User=${SERVICE_USER}/" -e "s/^Group=${LEGACY_ACCOUNT}\$/Group=${SERVICE_USER}/" \
          "${UNIT_DIR}"/*.service 2>/dev/null || true
      fi
      if [[ -n "$webui_from" ]]; then
        note "  Reinstalling open-webui ${webui_from} and restoring its database..."
        systemctl stop open-webui.service 2>/dev/null || true
        ( umask 022; "${OPENWEBUI_DIR}/venv/bin/pip" install --no-cache-dir "open-webui==${webui_from}" ) >/dev/null 2>&1 || \
          note "  WARNING: reinstalling open-webui ${webui_from} failed."
        openwebui_restore_db "$snapshot"
      fi
      for svc in "${affected[@]}"; do
        for pair in "${legacy_pairs[@]}"; do
          [[ "$svc" != "${pair#*=}" ]] || continue 2
        done
        rollback+=("$svc")
      done
      rollback+=("${legacy_running[@]}")
      systemctl daemon-reload 2>/dev/null || true
      if restart_and_check "${rollback[@]}" >/dev/null; then
        note "Rolled back; the previous configuration is running again."
      else
        note "Rolled back the files, but a service is still unhealthy — check it by hand."
      fi
      note "  The LiteLLM venv is not rolled back. The repo still holds the new config;"
      note "  fix it (or git revert) and run apply again."
      return 1
    fi
  fi
  # Only now is it safe to disable and remove the old units.
  mapfile -t renamed < <(migrate_legacy_units)
  if (( ${#renamed[@]} )); then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "${renamed[@]/%/.service}" >/dev/null 2>&1 ||
      note "WARNING: could not enable ${renamed[*]}; run systemctl enable ${renamed[*]} so they start at boot."
  fi
  if (( ${#affected[@]} )); then
    echo "Applied; all restarted services are healthy."
  else
    echo "No service is affected by this change; nothing restarted."
  fi
  secrets_fingerprint > "${ROUTER_DIR}/.secrets.applied"
  sync_metrics_key
  kindi_budget_note "$budget_before" "$budget_after"
  return 0
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
  user="$(env_get MATTERMOST_MONITOR_USER)"; [[ -n "$user" ]] || user="OSRMonitor"
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
# LM Studio servers with "Require authentication" on, or Strata, Basalt, Maya,
# Xolotl, Avalon and Kindi servers started with an API key. One token per kind, stored in
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

cmd_set_cloud_key() {
  local provider="$1" key="${2:-}" confirm_key="" key_env
  key_env="$(cloud_key_name "$provider")" || exit 1
  if [[ "$key" == --off ]]; then
    env_set "$key_env" ""
    regenerate_litellm
    echo "${provider} API key cleared."
    CHANGED=true
    return 0
  fi
  if [[ -z "$key" ]]; then
    [[ "$ASSUME_YES" == "true" ]] && die "set-cloud-key: no key given"
    read -r -s -p "${provider} API key: " key; echo
    read -r -s -p "Confirm API key: " confirm_key; echo
    [[ "$key" == "$confirm_key" ]] || die "API keys did not match"
  fi
  [[ "$key" =~ ^[A-Za-z0-9._~+/=:-]+$ ]] || die "invalid API key characters"
  env_set "$key_env" "$key"
  regenerate_litellm
  echo "Stored the ${provider} API key in ${SECRETS_FILE}."
  CHANGED=true
}

# FreeLLMAPI (targets/freellmapi): one OpenAI-compatible server in front of
# free cloud tiers. The router sends it only requests that name
# freellmapi/<id>; it is not a model server and has no LiteLLM deployment.
valid_freellmapi_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit
try:
    url = urlsplit(sys.argv[1])
    ok = (url.scheme in ("http", "https") and bool(url.hostname)
          and (url.port is None or url.port > 0)
          and not (url.path or url.username or url.password or url.query or url.fragment))
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

cmd_set_freellmapi() {
  local url="${1:-}" key="${2:-}" confirm_key=""
  [[ -n "$url" ]] || die "set-freellmapi: give the server's root URL (http://host:3001) or --off"
  if [[ "$url" == --off ]]; then
    env_set FREELLMAPI_BASE_URL ""
    env_set FREELLMAPI_API_KEY ""
    echo "FreeLLMAPI is off: freellmapi/ models are no longer offered."
    CHANGED=true
    return 0
  fi
  url="${url%/}"
  valid_freellmapi_url "$url" || die "set-freellmapi: '${url}' is not a root URL such as http://10.0.0.20:3001"
  if [[ -z "$key" ]]; then
    [[ "$ASSUME_YES" == "true" ]] && die "set-freellmapi: no key given"
    read -r -s -p "FreeLLMAPI unified API key: " key; echo
    read -r -s -p "Confirm API key: " confirm_key; echo
    [[ "$key" == "$confirm_key" ]] || die "API keys did not match"
  fi
  [[ "$key" =~ ^freellmapi-[A-Za-z0-9]+$ ]] ||
    die "set-freellmapi: that is not a FreeLLMAPI unified API key (freellmapi-..., on its dashboard's Keys page)"
  env_set FREELLMAPI_BASE_URL "$url"
  env_set FREELLMAPI_API_KEY "$key"
  echo "FreeLLMAPI at ${url}: its models are offered as freellmapi/<id>; the key is in ${SECRETS_FILE}."
  echo "They are used only when a request names one. Prompts sent to them leave your network."
  CHANGED=true
}

cmd_set_cloud_models() {
  local provider="$1" models="${2:-}" env_key
  cloud_key_name "$provider" >/dev/null || exit 1
  [[ -n "$models" ]] || die "set-cloud-models: provide comma-separated model IDs or --off"
  [[ "$models" == --off ]] && models=""
  validate_cloud_models "$provider" "$models"
  env_key="$(cloud_models_name "$provider")"
  env_set "$env_key" "$models"
  regenerate_litellm
  echo "Configured ${provider} models: ${models:-none}."
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
  tidy_env
  git -C "$REPO_DIR" add -A
  if git -C "$REPO_DIR" diff --cached --quiet; then
    note "Nothing to commit."
  else
    git -C "$REPO_DIR" -c user.name="${GIT_AUTHOR_NAME:-open-smart-router}" \
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
    set-token|set-api-key|set-cloud-key|set-cloud-models|set-freellmapi|set-webhook|set-webui-version) return 0 ;;
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
  echo "  pct exec <CTID> -- /usr/local/bin/manage-model-servers ${ORIG_ARGS[*]}" >&2
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
      [[ "$COMMAND" == "set-api-key" || "$COMMAND" == "set-cloud-key" ||
         "$COMMAND" == "set-cloud-models" || "$COMMAND" == "set-freellmapi" || -n "$(token_command_kind "$COMMAND")" ]] || die "unknown option: $1"
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
  set-cloud-key) cmd_set_cloud_key "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
  set-cloud-models) cmd_set_cloud_models "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
  set-freellmapi) cmd_set_freellmapi "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
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
  add|remove|set-tier|set-model|set-server-model|set-keepalive|set-webui-version|set-webhook|set-cloud-models)
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
  set-api-key|set-cloud-key|set-freellmapi|set-*-token)
    if $CHANGED && $AUTO_APPLY && ! $DRY_RUN; then cmd_apply; fi
    ;;
esac
MANAGEEOF
chmod 0755 "${REPO_DIR}/install/manage-model-servers.sh"

# --- optional local metrics stack (Prometheus + Grafana) ---
cat > "${REPO_DIR}/install/setup-metrics.sh" <<'METRICSEOF'
#!/usr/bin/env bash
# Install a small local Prometheus + Grafana stack in the router CT.
# Run as root: bash /app/config-repo/install/setup-metrics.sh [install|sync-key|login]
# login prints Grafana's address and first login and changes nothing.
set -euo pipefail

MODE="${1:-install}"
ROUTER_DIR="${ROUTER_DIR:-/app/router}"
SECRETS_FILE="${SECRETS_FILE:-${ROUTER_DIR}/secrets.env}"
# Optional: an exact Grafana package version (apt's grafana=<version>) instead
# of the newest in Grafana's stable repository, and the fingerprint its signing
# key must have (40 hex digits, spaces allowed). Without a fingerprint the key
# is trusted as downloaded over HTTPS.
GRAFANA_VERSION="${GRAFANA_VERSION:-}"
GRAFANA_KEY_FINGERPRINT="${GRAFANA_KEY_FINGERPRINT:-}"
# Tests only: a directory that stands in for / when files are written. What the
# written files say (paths in units and configuration) is never prefixed.
FS="${OSR_METRICS_ROOT:-}"
KEY_FILE=/etc/prometheus/osr-router-key

die() { printf 'metrics setup: %s\n' "$*" >&2; exit 1; }
note() { printf 'metrics setup: %s\n' "$*" >&2; }

[[ $EUID -eq 0 || -n $FS ]] || die 'run as root in the router CT'
[[ $MODE == install || $MODE == sync-key || $MODE == login ]] || die 'usage: setup-metrics.sh [install|sync-key|login]'

env_value() {
  local file=$1 key=$2
  [[ -f $file ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

sync_key() {
  local key tmp
  [[ -d ${FS}/etc/prometheus ]] || { [[ $MODE == sync-key ]] && return 0; die 'Prometheus is not installed'; }
  key="$(env_value "$SECRETS_FILE" ROUTER_API_KEY)"
  if [[ -z $key && -f ${FS}${KEY_FILE} ]]; then
    # An older router may deliberately have authentication off. Retain an
    # existing token: the router ignores it while authentication is disabled.
    return 0
  fi
  # No key and no file yet: the scrape needs the file to exist, so it starts
  # empty. The router asks for nothing while it has no key, and the next apply
  # after `set-api-key` fills it in.
  [[ $key != *$'\n'* && $key != *$'\r'* ]] || die 'invalid router key'
  tmp="$(mktemp "${FS}/etc/prometheus/.osr-router-key.XXXXXX")"
  if [[ -n $key ]]; then printf '%s\n' "$key" > "$tmp"; fi
  chown prometheus:prometheus "$tmp"
  chmod 0600 "$tmp"
  if [[ -f ${FS}${KEY_FILE} ]] && cmp -s "$tmp" "${FS}${KEY_FILE}"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "${FS}${KEY_FILE}"
  if [[ $MODE == sync-key ]] && systemctl is-active --quiet osr-prometheus.service; then
    systemctl restart osr-prometheus.service
  fi
  note 'router scrape key updated'
}

# Grafana's address and first login, on stdout so that whoever ran the setup
# can copy them. osr.env holds only the password a new Grafana database started
# with, so it is tried first: one that no longer signs in is not shown as if it
# did. It reaches curl on stdin, never on a command line. Says nothing where
# this script has not set Grafana up.
show_login() {
  local address password code
  [[ -e ${FS}/etc/systemd/system/grafana-server.service.d/osr.conf ]] || return 0
  address="$(hostname -I 2>/dev/null | awk '{ print $1 }')" || true
  password="$(env_value "${FS}/etc/grafana/osr.env" GF_SECURITY_ADMIN_PASSWORD)"
  printf 'Grafana:  http://%s:3000\n' "${address:-<ct-ip>}"
  if [[ -z $password ]]; then
    printf '  No password was set here: Grafana kept the login it already had.\n'
    return 0
  fi
  code="$(printf 'user = "admin:%s"\n' "$password" |
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -K - http://127.0.0.1:3000/api/user 2>/dev/null)" || true
  if [[ $code == 401 ]]; then
    printf '  The admin password has been changed since setup; the first one no longer signs in.\n'
    return 0
  fi
  printf 'Username: admin\nPassword: %s\n' "$password"
  [[ $code == 200 ]] || printf '  (not checked: Grafana did not answer. This is the password it started with.)\n'
}

if [[ $MODE == sync-key ]]; then
  sync_key
  exit 0
fi
if [[ $MODE == login ]]; then
  show_login
  exit 0
fi

[[ -f $SECRETS_FILE ]] || die "missing ${SECRETS_FILE}"
if [[ -n $GRAFANA_KEY_FINGERPRINT ]]; then
  GRAFANA_KEY_FINGERPRINT="${GRAFANA_KEY_FINGERPRINT// /}"
  [[ ${GRAFANA_KEY_FINGERPRINT^^} =~ ^[0-9A-F]{40}$ ]] || die 'GRAFANA_KEY_FINGERPRINT must be 40 hex digits'
fi
[[ -z $GRAFANA_VERSION || $GRAFANA_VERSION =~ ^[0-9][0-9A-Za-z.+~:-]*$ ]] || die 'invalid GRAFANA_VERSION'

# Put authentication in place before the package is installed: a package
# post-install step may start Grafana immediately. systemd reads EnvironmentFile
# itself, so Grafana needs no access to the file; the package may still make
# files under /etc/grafana readable by the grafana group, which changes
# nothing: Grafana has the password in its environment either way.
install -d -m 0755 "${FS}/etc/grafana" "${FS}/etc/systemd/system/grafana-server.service.d"
if [[ ! -e ${FS}/etc/grafana/osr.env && ! -e ${FS}/var/lib/grafana/grafana.db ]]; then
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  ( umask 077; printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$password" > "${FS}/etc/grafana/osr.env" )
  chmod 0600 "${FS}/etc/grafana/osr.env"
elif [[ ! -e ${FS}/etc/grafana/osr.env ]]; then
  note 'Grafana already has a database; preserving its existing admin login'
  : > "${FS}/etc/grafana/osr.env"
  chmod 0600 "${FS}/etc/grafana/osr.env"
fi
cat > "${FS}/etc/systemd/system/grafana-server.service.d/osr.conf" <<'EOF'
[Service]
EnvironmentFile=/etc/grafana/osr.env
Environment=GF_SERVER_HTTP_ADDR=0.0.0.0 GF_SERVER_HTTP_PORT=3000 GF_AUTH_ANONYMOUS_ENABLED=false GF_USERS_ALLOW_SIGN_UP=false GF_ANALYTICS_REPORTING_ENABLED=false GF_ANALYTICS_CHECK_FOR_UPDATES=false
EOF
systemctl daemon-reload

# Debian's Prometheus package supplies the binary and its unprivileged user.
# Use our own loopback-only unit, so the package's default web listener is not
# exposed and its storage budget is explicit.
if systemctl is-active --quiet prometheus.service; then
  die 'an existing prometheus.service is running; stop it or keep using it instead of the local OSR stack'
fi
systemctl mask prometheus.service
export DEBIAN_FRONTEND=noninteractive
apt-get update
# --no-install-recommends: Debian's prometheus recommends prometheus-node-exporter,
# which would start an unauthenticated listener on every address (port 9100).
apt-get install -y --no-install-recommends ca-certificates wget prometheus
systemctl mask --now prometheus.service

# Grafana OSS from the vendor's signed stable Debian repository.
install -d -m 0755 "${FS}/etc/apt/keyrings" "${FS}/etc/apt/sources.list.d"
key_tmp="$(mktemp "${FS}/etc/apt/keyrings/.grafana.XXXXXX")"
wget -qO "$key_tmp" https://apt.grafana.com/gpg-full.key || { rm -f "$key_tmp"; die 'could not download the Grafana signing key'; }
if [[ -n $GRAFANA_KEY_FINGERPRINT ]]; then
  command -v gpg >/dev/null 2>&1 || apt-get install -y --no-install-recommends gnupg
  # Every primary key in the file must be the expected one.
  found="$(gpg --show-keys --with-colons "$key_tmp" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }' | sort -u)"
  if [[ ${found^^} != "${GRAFANA_KEY_FINGERPRINT^^}" ]]; then
    rm -f "$key_tmp"
    die "the Grafana signing key is not ${GRAFANA_KEY_FINGERPRINT} (found: ${found:-none}); nothing was installed from it"
  fi
fi
chmod 0644 "$key_tmp"
mv -f "$key_tmp" "${FS}/etc/apt/keyrings/grafana.asc"
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > "${FS}/etc/apt/sources.list.d/grafana.list"
apt-get update
apt-get install -y "grafana${GRAFANA_VERSION:+=${GRAFANA_VERSION}}"
systemctl stop grafana-server.service 2>/dev/null || true

sync_key

router_host="$(env_value "${ROUTER_DIR}/.env" ROUTER_HOST)"
router_port="$(env_value "${ROUTER_DIR}/.env" ROUTER_PORT)"
router_port="${router_port:-8000}"
[[ $router_port =~ ^[0-9]+$ ]] && (( router_port >= 1 && router_port <= 65535 )) || die 'invalid ROUTER_PORT'
case "$router_host" in
  ''|0.0.0.0|127.0.0.1|localhost|::|::1) router_host=127.0.0.1 ;;
  *:*) [[ $router_host =~ ^[0-9a-fA-F:]+$ ]] || die 'invalid ROUTER_HOST'; router_host="[$router_host]" ;;
  *) [[ $router_host =~ ^[a-zA-Z0-9.-]+$ ]] || die 'invalid ROUTER_HOST' ;;
esac

cat > "${FS}/etc/prometheus/osr.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: osr
    metrics_path: /metrics
    authorization:
      credentials_file: ${KEY_FILE}
    static_configs:
      - targets: ['${router_host}:${router_port}']
EOF
chmod 0644 "${FS}/etc/prometheus/osr.yml"
promtool check config "${FS}/etc/prometheus/osr.yml"
mkdir -p "${FS}/var/lib/prometheus/osr"
chown prometheus:prometheus "${FS}/var/lib/prometheus/osr"
chmod 0750 "${FS}/var/lib/prometheus/osr"

cat > "${FS}/etc/systemd/system/osr-prometheus.service" <<'EOF'
[Unit]
Description=Open Smart Router Prometheus scraper
After=network-online.target osr-router.service
Wants=network-online.target
[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/bin/prometheus --config.file=/etc/prometheus/osr.yml --storage.tsdb.path=/var/lib/prometheus/osr --storage.tsdb.retention.time=7d --storage.tsdb.retention.size=512MB --web.listen-address=127.0.0.1:9090
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/prometheus/osr
CapabilityBoundingSet=
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 "${FS}/etc/grafana/provisioning/datasources" "${FS}/etc/grafana/provisioning/dashboards" "${FS}/etc/grafana/osr-dashboards"
cat > "${FS}/etc/grafana/provisioning/datasources/osr.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: OSR Prometheus
    uid: osr-prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF
cat > "${FS}/etc/grafana/provisioning/dashboards/osr.yml" <<'EOF'
apiVersion: 1
providers:
  - name: Open Smart Router
    orgId: 1
    folder: Open Smart Router
    type: file
    disableDeletion: false
    editable: false
    options:
      path: /etc/grafana/osr-dashboards
EOF
cat > "${FS}/etc/grafana/osr-dashboards/router.json" <<'EOF'
{
  "uid": "osr-router", "title": "Open Smart Router", "schemaVersion": 39,
  "version": 2, "refresh": "15s", "time": {"from": "now-6h", "to": "now"},
  "panels": [
    {"id": 1, "type": "stat", "title": "Router scrape", "description": "Prometheus can scrape the protected router /metrics endpoint.", "gridPos": {"x": 0, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"mappings": [{"type": "value", "options": {"0": {"text": "Down", "color": "red"}, "1": {"text": "Up", "color": "green"}}}], "thresholds": {"mode": "absolute", "steps": [{"color": "red"}, {"color": "green", "value": 1}]}}, "overrides": []}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "up{job=\"osr\"}", "instant": true}]},
    {"id": 2, "type": "stat", "title": "Requests / sec", "description": "All router answers, averaged over five minutes.", "gridPos": {"x": 4, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "reqps"}}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "sum(rate(osr_requests_total[5m])) or vector(0)", "instant": true}]},
    {"id": 3, "type": "stat", "title": "HTTP 5xx %", "description": "Router answers with a 5xx status as a share of all answers over five minutes.", "gridPos": {"x": 8, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "yellow", "value": 1}, {"color": "red", "value": 5}]}}}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "100 * (sum(rate(osr_requests_total{status=~\"5..\"}[5m])) or vector(0)) / clamp_min(sum(rate(osr_requests_total[5m])) or vector(0), 1e-9)", "instant": true}]},
    {"id": 4, "type": "stat", "title": "Servers up", "description": "Model servers currently marked up by the router.", "gridPos": {"x": 12, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "sum(osr_server_up)", "instant": true}]},
    {"id": 5, "type": "stat", "title": "Models listed", "description": "Sum of models found across model servers; the same model may appear on several servers.", "gridPos": {"x": 16, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "sum(osr_server_models)", "instant": true}]},
    {"id": 6, "type": "stat", "title": "Inventory age", "description": "Time since the router last refreshed model inventory.", "gridPos": {"x": 20, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "osr_inventory_age_seconds", "instant": true}]},
    {"id": 7, "type": "timeseries", "title": "Requests by route and status", "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "reqps"}}, "targets": [{"refId": "A", "expr": "sum by (route, status) (rate(osr_requests_total[5m]))", "legendFormat": "{{route}} {{status}}"}]},
    {"id": 8, "type": "timeseries", "title": "Upstream failures by server and reason", "description": "Failed attempts can be followed by a successful retry on another server.", "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "ops"}}, "targets": [{"refId": "A", "expr": "sum by (server, reason) (rate(osr_upstream_failures_total[5m]))", "legendFormat": "{{server}} {{reason}}"}]},
    {"id": 9, "type": "timeseries", "title": "Response start latency", "description": "Arrival until response headers are sent, across all requests.", "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.5, sum by (le) (rate(osr_response_start_seconds_bucket[5m])))", "legendFormat": "p50"}, {"refId": "B", "expr": "histogram_quantile(0.95, sum by (le) (rate(osr_response_start_seconds_bucket[5m])))", "legendFormat": "p95"}]},
    {"id": 10, "type": "timeseries", "title": "Request duration", "description": "Arrival until the final response byte, across all requests.", "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.5, sum by (le) (rate(osr_request_duration_seconds_bucket[5m])))", "legendFormat": "p50"}, {"refId": "B", "expr": "histogram_quantile(0.95, sum by (le) (rate(osr_request_duration_seconds_bucket[5m])))", "legendFormat": "p95"}]},
    {"id": 11, "type": "timeseries", "title": "Response start p95 by model", "gridPos": {"x": 0, "y": 20, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, model) (rate(osr_response_start_seconds_bucket{model!=\"\"}[5m])))", "legendFormat": "{{model}}"}]},
    {"id": 12, "type": "timeseries", "title": "Request duration p95 by model", "gridPos": {"x": 12, "y": 20, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, model) (rate(osr_request_duration_seconds_bucket{model!=\"\"}[5m])))", "legendFormat": "{{model}}"}]},
    {"id": 13, "type": "timeseries", "title": "Requests in flight by server", "gridPos": {"x": 0, "y": 28, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "targets": [{"refId": "A", "expr": "osr_in_flight_requests", "legendFormat": "{{server}}"}]},
    {"id": 14, "type": "timeseries", "title": "Server availability", "description": "1 means up; 0 means down according to the last discovery poll or dispatch.", "gridPos": {"x": 12, "y": 28, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"min": 0, "max": 1}}, "targets": [{"refId": "A", "expr": "osr_server_up", "legendFormat": "{{server}}"}]},
    {"id": 15, "type": "timeseries", "title": "Models per server", "gridPos": {"x": 0, "y": 36, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "targets": [{"refId": "A", "expr": "osr_server_models", "legendFormat": "{{server}}"}]},
    {"id": 16, "type": "timeseries", "title": "Remembered conversations", "description": "Conversations whose last server is remembered for affinity.", "gridPos": {"x": 12, "y": 36, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "targets": [{"refId": "A", "expr": "osr_remembered_conversations", "legendFormat": "remembered"}]}
  ]
}
EOF
chmod 0644 "${FS}/etc/grafana/provisioning/datasources/osr.yml" "${FS}/etc/grafana/provisioning/dashboards/osr.yml" "${FS}/etc/grafana/osr-dashboards/router.json"

systemctl daemon-reload
# restart, not enable --now: a rerun must pick up a changed unit or scrape
# target, and --now leaves a running service as it is.
systemctl enable osr-prometheus.service
systemctl restart osr-prometheus.service
systemctl enable grafana-server.service
systemctl restart grafana-server.service
# "active" only says the process was started: a service that exits a moment
# later, or one still migrating its database, is active too. Ready means it
# answers. Grafana's first start can take a while, so it gets READY_TIMEOUT
# seconds (default 180); on failure the end of its journal says why.
wait_ready() {
  local unit=$1 url=$2 waited=0 limit="${READY_TIMEOUT:-180}"
  while (( waited < limit )); do
    if systemctl is-failed --quiet "$unit"; then break; fi
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then return 0; fi
    sleep 3
    waited=$((waited + 3))
  done
  note "${unit} does not answer on ${url}. Its last log lines:"
  journalctl -u "$unit" -n 25 --no-pager >&2 2>/dev/null || true
  return 1
}
wait_ready osr-prometheus.service http://127.0.0.1:9090/-/ready || die 'Prometheus failed to start'
wait_ready grafana-server.service http://127.0.0.1:3000/api/health || die 'Grafana failed to start'
note 'ready: Grafana answers on port 3000, Prometheus on loopback port 9090; dashboard Open Smart Router'
note 'if a browser cannot reach port 3000, allow it in the CT firewall (README, Local Grafana dashboard)'
show_login
METRICSEOF
chmod 0755 "${REPO_DIR}/install/setup-metrics.sh"

# --- repo README so the tree is self-documenting in Gitea ---
cat > "${REPO_DIR}/README.md" <<'RDEOF'
# open-smart-router — service configuration

Version-controlled configuration for the Open Smart Router LXC. The installer
clones this repo into the container during provisioning and runs
`install/apply-config.sh` to copy each file into place.

    services/<service>/     unit file, code, .ini tunables, requirements.txt
    env/                    environment files consumed via systemd EnvironmentFile
    install/apply-config.sh copies everything into its runtime location

Config is pulled **once, at provisioning time** — services do not contact Gitea
to start, so a Gitea outage can never block a boot.

## Changing configuration on a running container

    cd /app/config-repo && git pull
    manage-model-servers apply        # validates, snapshots, applies, health-checks, rolls back on failure

`manage-model-servers` (a link to `install/manage-model-servers.sh`) also adds
and removes model servers, sets tiers and tokens, and commits changes back
here. Secrets live outside this repository in `/app/router/secrets.env`.

## Layout notes

* `services/osr-router` and `osr-monitor` share one venv
  (`/app/router/venv`). `litellm-proxy` has its own (`/app/litellm/venv`),
  installed from `requirements.lock` with hash checking when present.
* `services/open-webui` has its own venv on Python 3.12 — every open-webui
  release requires `>=3.11,<3.13`, and Debian 13 ships 3.13.
* `router.ini` holds the complexity-routing thresholds and keyword lists, so
  routing behaviour can change without editing `router.py`.
RDEOF

# --- systemd units (one per service directory) ---
cat > "${REPO_DIR}/services/osr-router/osr-router.service" <<'UNITEOF'
[Unit]
Description=Open Smart Router Middleware
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
User=osr-router
Group=osr-router
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
User=osr-router
Group=osr-router
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

cat > "${REPO_DIR}/services/osr-monitor/osr-monitor.service" <<'UNITEOF'
[Unit]
Description=Open Smart Router Health Monitor
# The monitor probes model hosts and local services, including LiteLLM, and
# posts transitions to Mattermost. LiteLLM is monitored, not a hard dependency:
# its failure must not stop health checks for the other services and hosts.
After=network-online.target litellm-proxy.service
Wants=network-online.target litellm-proxy.service
[Service]
Type=simple
User=osr-router
Group=osr-router
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
# /var/lib/osr-monitor holds the startup-notice timestamp.
StateDirectory=osr-monitor
Environment=MONITOR_STATE_DIR=/var/lib/osr-monitor
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
# Wants=, not Requires=: the router is the UI's only backend, so it is started
# with the UI and before it (After=), but Requires= would also restart the UI
# with every router restart. A router restart takes about a second; the UI's
# takes far longer and drops its users' sessions, and every routing change
# (router.ini, router.py, a key) restarts the router. While the router is away
# the UI shows a connection error and carries on afterwards.
After=network-online.target osr-router.service
Wants=network-online.target osr-router.service
[Service]
Type=simple
User=osr-router
Group=osr-router
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
  verify_config_clone "$REPO_DIR"
else
  echo "Installing the generated configuration directly (no Gitea repo)."
  push_local_config_tree "$REPO_DIR"
fi

echo "Applying configuration."
run_ct bash "${CONFIG_REPO_DIR}/install/apply-config.sh" "$CONFIG_REPO_DIR"

echo "Installing secrets outside the config repo."
pct push "$CT_ID" "$SECRETS_STAGE" /app/router/secrets.env --perms 0640
run_ct chown root:osr-router /app/router/secrets.env

rm -rf "$STAGE_DIR"; STAGE_DIR=""
unset GITEA_DEPLOY_TOKEN_KEEP

echo "Installing Python dependencies (from the repo's requirements files)."
# The config tree above was built under `umask 077` (it holds secrets), and
# `pct exec` hands the caller's umask to the container. Venvs built under it
# are unreadable by the osr-router service account: LiteLLM, which is not
# chowned below, then fails with status=203/EXEC "Permission denied".
umask 022
# The router and monitor share /app/router/venv. LiteLLM gets its own venv:
# `litellm --config` needs the litellm[proxy] extra, and that extra pins
# fastapi/uvicorn versions that conflict with the router's pins.
run_ct python3 -m venv /app/router/venv
run_ct /app/router/venv/bin/pip install --no-cache-dir \
  -r "${CONFIG_REPO_DIR}/services/osr-router/requirements.txt" \
  -r "${CONFIG_REPO_DIR}/services/osr-monitor/requirements.txt"

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
run_ct chown -R osr-router:osr-router /app/router /app/openwebui
run_ct chown root:osr-router /app/router/.env
run_ct chmod 0640 /app/router/.env
run_ct chown root:osr-router /app/openwebui/.env
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
  Open Smart Router        ${CT_NAME}  (CT ${CT_ID})
==============================================================================
  Container IP : ${ROUTER_IP}

  SERVICES
  ---------------------------------------------------------------------------
   Open WebUI (chat UI)       http://${ROUTER_IP}:${OPENWEBUI_PORT}        [open-webui.service]
   OSR (OpenAI API)           http://${ROUTER_IP}:8000/v1     [osr-router.service]
     (Bearer key: ROUTER_API_KEY in /app/router/secrets.env)
   LiteLLM proxy              http://127.0.0.1:4000  (local)  [litellm-proxy.service]
   Health monitor             Mattermost alerts               [osr-monitor.service]

  MODEL TIERS  ->  MODEL SERVER(S)
  ---------------------------------------------------------------------------
   fast     ->  $(indices_to_urls "$TIER_FAST_IDX")   (${MODEL_FAST})
   medium   ->  $(indices_to_urls "$TIER_MEDIUM_IDX")   (${MODEL_MEDIUM})
   large    ->  $(indices_to_urls "$TIER_LARGE_IDX")   (${MODEL_LARGE})
   xlarge   ->  $(indices_to_urls "$TIER_XLARGE_IDX")   (${MODEL_XLARGE})
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
   Status        : systemctl status open-webui osr-router litellm-proxy osr-monitor
   Logs          : journalctl -u osr-router -f
==============================================================================
EOF
pct push "$CT_ID" "$motd_tmp" /etc/motd --perms 0644
rm -f "$motd_tmp"

echo "Starting services."
run_ct systemctl daemon-reload
run_ct systemctl enable --now \
  litellm-proxy.service osr-router.service osr-monitor.service open-webui.service

METRICS_INSTALLED=false
if [[ "$INSTALL_METRICS" != "true" ]]; then
  echo "Skipping the local Prometheus and Grafana (INSTALL_METRICS=${INSTALL_METRICS})."
  echo "  Add them later inside the CT: bash ${CONFIG_REPO_DIR}/install/setup-metrics.sh install"
else
  echo "Installing local Prometheus and Grafana."
  if run_ct bash "${CONFIG_REPO_DIR}/install/setup-metrics.sh" install; then
    METRICS_INSTALLED=true
  else
    echo "WARNING: Metrics dashboard setup failed; the router remains available." >&2
    echo "         Retry inside the CT: bash ${CONFIG_REPO_DIR}/install/setup-metrics.sh install" >&2
  fi
fi

# Provisioning succeeded — disarm the failure trap so we keep the container.
CT_CREATED=""
trap - ERR

# After the trap is disarmed: a firewall file that cannot be written must not
# remove a container that is otherwise complete.
if $METRICS_INSTALLED && [[ "$FIREWALL" == "1" && -n "$API_ALLOW_CIDR" ]]; then
  ensure_fw_rule "/etc/pve/firewall/${CT_ID}.fw" \
    "IN ACCEPT -source ${API_ALLOW_CIDR} -p tcp -dport 3000 -log nolog" ||
    echo "WARNING: could not allow tcp/3000 (Grafana) from ${API_ALLOW_CIDR} in the CT firewall; add the rule by hand." >&2
fi

echo "=============================================================================="
echo "Provisioning complete."
echo "Container ID: ${CT_ID}"
echo "Service IP: ${ROUTER_IP}"
echo "OpenAI-compatible API base URL: http://${ROUTER_IP}:8000/v1"
echo "Open WebUI (chat UI):          http://${ROUTER_IP}:${OPENWEBUI_PORT}"
echo "  -> create the admin account on first visit; it is pre-connected to OSR."
if $METRICS_INSTALLED; then
  echo "Grafana (router metrics):     http://${ROUTER_IP}:3000"
  # Username and password, ready to copy (setup-metrics.sh login).
  run_ct bash "${CONFIG_REPO_DIR}/install/setup-metrics.sh" login 2>/dev/null |
    sed -e '/^Grafana:/d' -e 's/^ */  /' ||
    echo "  -> admin initial password: /etc/grafana/osr.env inside the CT"
fi
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
