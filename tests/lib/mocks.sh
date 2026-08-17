#!/usr/bin/env bash
# Stub external commands so functions that shell out can be tested without a
# Proxmox host, a Gitea server, or live Ollama backends.
#
# Every stub logs its invocation to $MOCK_LOG, so tests can assert on what a
# function *tried* to do, not just what it returned.

MOCK_BIN=""
MOCK_LOG=""

mocks_init() {
  MOCK_BIN="$(mktemp -d)"
  MOCK_LOG="${MOCK_BIN}/calls.log"
  : > "$MOCK_LOG"
  export MOCK_BIN MOCK_LOG
  export PATH="${MOCK_BIN}:${PATH}"
}

mocks_cleanup() {
  [[ -n "$MOCK_BIN" && -d "$MOCK_BIN" ]] && rm -rf "$MOCK_BIN"
  MOCK_BIN=""; MOCK_LOG=""
}

mock_calls()      { cat "$MOCK_LOG" 2>/dev/null; }
mock_reset_log()  { : > "$MOCK_LOG"; }
mock_called()     { grep -qF -- "$1" "$MOCK_LOG" 2>/dev/null; }
# NOTE: `grep -c` prints 0 *and* exits 1 when there are no matches, so a
# `|| echo 0` fallback would emit "0\n0". Swallow the exit status instead.
mock_call_count() { local n; n="$(grep -cF -- "$1" "$MOCK_LOG" 2>/dev/null)" || true; printf '%s' "${n:-0}"; }

# mock_command <name> <exit-code> [stdout...]
# Creates an executable stub that logs its args, prints the given stdout and
# exits with the given code.
mock_command() {
  local name="$1" code="${2:-0}"; shift 2 || true
  local out="${*:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$name" "$MOCK_LOG"
    if [[ -n "$out" ]]; then
      printf 'cat <<'"'"'MOCKOUT'"'"'\n%s\nMOCKOUT\n' "$out"
    fi
    printf 'exit %s\n' "$code"
  } > "${MOCK_BIN}/${name}"
  chmod +x "${MOCK_BIN}/${name}"
}

# mock_script <name> <<'EOF' ... EOF
# For stubs needing real logic. The body is a bash script; $MOCK_LOG is set.
mock_script() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$name" "$MOCK_LOG"
    cat
  } > "${MOCK_BIN}/${name}"
  chmod +x "${MOCK_BIN}/${name}"
}

# --- fixtures -----------------------------------------------------------------

# A config repo laid out exactly as apply-config.sh expects.
make_config_repo() {
  local root="$1"
  mkdir -p "${root}"/{env,install} \
           "${root}"/services/{ollama-router,litellm-proxy,ollama-monitor,open-webui}
  cat > "${root}/env/router.env" <<'EOF'
GITEA_SERVER_URL=https://git.example.net
GITEA_ADMIN_USER=tester
GITEA_DEPLOY_TOKEN=
GITEA_VERIFY_TLS=false
MATTERMOST_CHANNEL=ollama-monitor
LITELLM_BASE_URL=http://127.0.0.1:4000
BACKEND_FAST=http://10.0.0.51:11434
BACKEND_MEDIUM=http://10.0.0.52:11434
BACKEND_LARGE=http://10.0.0.52:11434,http://10.0.0.53:11434
BACKEND_XLARGE=http://10.0.0.54:11434
MODEL_SERVER_COUNT=4
MODEL_SERVERS=http://10.0.0.51:11434,http://10.0.0.52:11434,http://10.0.0.53:11434,http://10.0.0.54:11434
MODEL_FAST=qwen2.5-coder:7b
MODEL_MEDIUM=qwen3:14b
MODEL_LARGE=qwen3:32b
MODEL_XLARGE=llama3.3:70b
OLLAMA_KEEP_ALIVE=
TORCH_CPU_ONLY=true
EOF
  cat > "${root}/services/litellm-proxy/litellm_config.yaml" <<'EOF'
model_list:
  - model_name: fast
    litellm_params:
      model: ollama/qwen2.5-coder:7b
      api_base: http://10.0.0.51:11434
  - model_name: medium
    litellm_params:
      model: ollama/qwen3:14b
      api_base: http://10.0.0.52:11434
  - model_name: large
    litellm_params:
      model: ollama/qwen3:32b
      api_base: http://10.0.0.52:11434
  - model_name: large
    litellm_params:
      model: ollama/mixtral:8x7b
      api_base: http://10.0.0.53:11434
  - model_name: xlarge
    litellm_params:
      model: ollama/llama3.3:70b
      api_base: http://10.0.0.54:11434
router_settings:
  routing_strategy: latency-based-routing
  fallbacks:
    - xlarge: ["large", "medium", "fast"]
    - large: ["medium", "fast"]
EOF
  cat > "${root}/services/ollama-router/router.ini" <<'EOF'
[tiers]
fast = fast
medium = medium
large = large
xlarge = xlarge
EOF
  printf 'open-webui==0.6.5\n' > "${root}/services/open-webui/requirements.txt"
  printf '#!/usr/bin/env bash\necho "apply-config ran for $1"\n' > "${root}/install/apply-config.sh"
  chmod +x "${root}/install/apply-config.sh"
}

# A config repo in the PRE-RENAME layout: Qwen-specific tier keys and LiteLLM
# aliases. Used to prove migrate_legacy_names upgrades an existing deployment.
make_legacy_config_repo() {
  local root="$1"
  make_config_repo "$root"
  # Wind the fixture back two generations: "large" was "heavy", and the tier
  # keys carried a QWEN_ infix. The xlarge tier did not exist at all.
  sed -i -e '/^BACKEND_XLARGE=/d' -e '/^MODEL_XLARGE=/d' "${root}/env/router.env"
  sed -i -e 's/^BACKEND_LARGE=/BACKEND_QWEN_HEAVY=/' \
         -e 's/^BACKEND_FAST=/BACKEND_QWEN_FAST=/' \
         -e 's/^BACKEND_MEDIUM=/BACKEND_QWEN_MEDIUM=/' \
         -e 's/^MODEL_LARGE=/MODEL_HEAVY=/' "${root}/env/router.env"
  # Drop the xlarge deployment and rename the aliases.
  sed -i -e '/model_name: xlarge/,+3d' -e '/- xlarge:/d' \
    "${root}/services/litellm-proxy/litellm_config.yaml"
  sed -i -E 's/\b(fast|medium)\b/qwen-\1/g; s/\blarge\b/qwen-heavy/g' \
    "${root}/services/litellm-proxy/litellm_config.yaml"
  cat > "${root}/services/ollama-router/router.ini" <<'EOF'
[thresholds]
heavy = 800
medium = 250

[keywords]
code_first = true
heavy = ["analyze", "evaluate"]

[tiers]
fast = qwen-fast
medium = qwen-medium
heavy = qwen-heavy

[discovery]
enabled = true
fast_params = 0:9
medium_params = 9:20
heavy_params = 20:999

[weights]
prefer_larger_heavy = 0.15
prefer_smaller_fast = 0.15
EOF
}

# `pvesm status` output in the real current format, including the "(KiB)" unit
# tokens that shift header columns relative to data rows.
PVESM_REAL_OUTPUT='Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
ant-hp-nfs-backups         nfs     active     22562971648       368882688     22194088960    1.63%
iso_fs                  cephfs     active      2569900032          126976      2569773056    0.00%
local                      dir     active        20155608        10782840         8323580   53.50%
local-lvm              lvmthin     active         8282112               0         8282112    0.00%
dead-store                 nfs   inactive        10485760               0        10485760    0.00%
vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%'

# The older column order (total/available/used) documented in the 2017 rework.
PVESM_ALT_ORDER='Name             Type     Status           Total       Available            Used        %
local             dir     active        98559220        79629336        13886820   14.09%
local-lvm     lvmthin     active       354275328       308819968        45455360   12.83%'
