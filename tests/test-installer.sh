#!/usr/bin/env bash
# Fixture variables are consumed by dynamically extracted helpers.
# shellcheck disable=SC2034
# Unit tests for the functions in ollama-smart-router-install.sh
#
# Functions are extracted (heredoc-aware) and sourced in isolation, so no
# container is created and no Proxmox host is required.

# Never read the caller's stdin: a prompt under test that is not fed input
# explicitly would otherwise block forever when run from a pipe or CI runner.
exec </dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-${HERE}/../ollama-smart-router-install.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"
# shellcheck source=lib/mocks.sh
source "${HERE}/lib/mocks.sh"

[[ -f "$SCRIPT" ]] || { echo "installer not found: $SCRIPT" >&2; exit 1; }

FUNCS="$(mktemp)"
python3 "${HERE}/lib/extract-functions.py" "$SCRIPT" > "$FUNCS" || exit 1
bash -n "$FUNCS" || { echo "extracted functions do not parse" >&2; exit 1; }

mocks_init
trap 'mocks_cleanup; rm -f "$FUNCS"' EXIT

# Defaults the functions expect to exist (normally set at the top of the script).
NONINTERACTIVE=false
OLLAMA_PORT=11434
MODEL_SERVER_COUNT=3
MODEL_SERVER_MIN=1
MODEL_SERVER_MAX=20
STORAGE_CFG=""
GITEA_VERIFY_TLS=false
GITEA_SERVER_URL="https://git.example.net"
GITEA_ADMIN_USER="tester"
GITEA_OWNER="tester"
GITEA_REPO_NAME="ollama-smart-router"
GITEA_REPO_OWNER=""
GITEA_REPO_PRIVATE=true
MODEL_SERVERS=()
STORAGE_QUERY_ERROR=""
GITEA_CURL_OPTS=(--location)
CT_ID=100
TEMPLATE_STORAGE="local"
TEMPLATE_STORAGE_EXPLICIT=""
TEMPLATE_NAME=""
TEMPLATE_REF=""
TEMPLATE_MIN_GIB=2
CONFIG_UPDATE_CODE=true
# The owned-code list is data, not a function: lift it from the real script so
# the tests exercise the list that actually ships.
eval "$(sed -n '/^INSTALLER_OWNED_CODE=(/,/^)/p' "$SCRIPT")"
# shellcheck source=/dev/null
source "$FUNCS"

echo "Testing $(basename "$SCRIPT") — $(python3 "${HERE}/lib/extract-functions.py" "$SCRIPT" --list | wc -l) functions extracted"

# ── a PATH without pvesh ──────────────────────────────────────────────────────
# The "no pvesh" cases run with only these tools on PATH. /usr/bin:/bin would
# not do: on a Proxmox host it holds the real pvesh, which those cases would
# then query.
NO_PVESH_BIN="$MOCK_BIN/no-pvesh-tools"
mkdir -p "$NO_PVESH_BIN"
for _tool in bash awk cat timeout; do
  ln -s "$(command -v "$_tool")" "$NO_PVESH_BIN/$_tool"
done
unset _tool
if env PATH="$NO_PVESH_BIN" bash -c 'command -v pvesh' >/dev/null 2>&1; then
  echo "NO_PVESH_BIN unexpectedly finds pvesh" >&2; exit 1
fi

# ── CT IDs ────────────────────────────────────────────────────────────────────
# Silent cluster stubs (not logged).
# IDs listed in $_ids/used exist; pvesh offers $_ids/nextid as the next free ID.
_ids="$(mktemp -d)"; _saved_path="$PATH"
printf '%s\n' '#!/usr/bin/env bash' \
  "used=\" \$(cat '$_ids/used') \"" \
  'args="$*"; if [[ $args == *"--vmid "* ]]; then id=${args##*--vmid }; [[ $used != *" $id "* ]]; exit; fi' \
  "cat '$_ids/nextid'" > "$_ids/pvesh"
printf '%s\n' '#!/usr/bin/env bash' \
  "used=\" \$(cat '$_ids/local-used') \"" \
  '[[ $1 == status && $used == *" $2 "* ]]' > "$_ids/pct"
chmod +x "$_ids/pvesh" "$_ids/pct"
echo 905 > "$_ids/used"; echo 905 > "$_ids/local-used"; echo 910 > "$_ids/nextid"
PATH="$_ids:$PATH"

BRIDGE=vmbr2; NAMESERVER=192.0.2.53; MATTERMOST_CHANNEL=ollama-monitor
CT_ID=910; IP_CIDR=192.0.2.80/24; GATEWAY=192.0.2.1; STORAGE=router-store
ROOTFS_GB=32; CORES=8
GITEA_CT_ID=911; GITEA_IP_CIDR=192.0.2.81/24
GITEA_GATEWAY=192.0.2.1; GITEA_STORAGE=git-store
GITEA_COMMUNITY_SCRIPT_URL=https://example.test/gitea.sh
MATTERMOST_CT_ID=912; MATTERMOST_IP_CIDR=192.0.2.82/24
MATTERMOST_GATEWAY=192.0.2.1; MATTERMOST_STORAGE=chat-store
MATTERMOST_COMMUNITY_SCRIPT_URL=https://example.test/mattermost.sh

describe next_free_ct_id
assert_eq "the cluster's next free ID" 910 "$(next_free_ct_id)"
assert_eq "steps past IDs this install already gave out" 912 "$(next_free_ct_id 910 911)"
echo "905 906" > "$_ids/used"; echo 905 > "$_ids/nextid"
assert_eq "and past IDs the cluster reports in use" 907 "$(next_free_ct_id)"
echo 905 > "$_ids/used"; echo garbage > "$_ids/nextid"
assert_eq "an unreadable answer gives no default" "" "$(next_free_ct_id)"
echo 910 > "$_ids/nextid"
assert_eq "without pvesh there is no default" "" \
  "$(env PATH="$NO_PVESH_BIN" bash -c 'source "$1"; next_free_ct_id' _ "$FUNCS")"

describe ct_id_free
assert_ok   "a free ID, asked of the cluster" ct_id_free 906
assert_fail "a used ID, asked of the cluster" ct_id_free 905
mkdir -p "$_ids/pct-only"; cp "$_ids/pct" "$_ids/pct-only/pct"
assert_fail "without pvesh, pct status decides" \
  env PATH="$_ids/pct-only:$NO_PVESH_BIN" bash -c 'source "$1"; ct_id_free 905' _ "$FUNCS"
assert_ok   "and a free ID passes" \
  env PATH="$_ids/pct-only:$NO_PVESH_BIN" bash -c 'source "$1"; ct_id_free 906' _ "$FUNCS"

describe require_companion_credentials
TARGETS="ollama"; CONFIG_SOURCE=local; MATTERMOST_WEBHOOK_URL=""
assert_ok "no new services, nothing to check" require_companion_credentials
TARGETS="gitea ollama"; GITEA_CT_ID=911
assert_fail "a new Gitea that fell back to local config stops the install" require_companion_credentials
assert_contains "and says how to use it on a rerun" "without selecting gitea, with GITEA_SERVER_URL" \
  "$(require_companion_credentials 2>&1)"
assert_contains "naming its CT" "CT 911" "$(require_companion_credentials 2>&1)"
CONFIG_SOURCE=repo
assert_ok "a new Gitea with a working repository passes" require_companion_credentials
TARGETS="mattermost"; MATTERMOST_CT_ID=912
assert_fail "a new Mattermost without a webhook stops the install" require_companion_credentials
assert_contains "and names where its webhook is" "/etc/mattermost-target/webhook-url" \
  "$(require_companion_credentials 2>&1)"
MATTERMOST_WEBHOOK_URL="https://chat.example.test/hooks/abc"
assert_ok "a new Mattermost with a webhook passes" require_companion_credentials
TARGETS=""

# Restore what the rest of the suite expects.
PATH="$_saved_path"; rm -rf "$_ids" "$_out"
CT_ID=100; INSTALL_GITEA=false; INSTALL_MATTERMOST=false; NONINTERACTIVE=false
unset MATTERMOST_WEBHOOK_URL CONFIG_SOURCE BRIDGE NAMESERVER MATTERMOST_CHANNEL IP_CIDR GATEWAY STORAGE ROOTFS_GB CORES \
  GITEA_CT_ID GITEA_IP_CIDR GITEA_GATEWAY GITEA_STORAGE GITEA_COMMUNITY_SCRIPT_URL \
  MATTERMOST_CT_ID MATTERMOST_IP_CIDR MATTERMOST_GATEWAY MATTERMOST_STORAGE \
  MATTERMOST_COMMUNITY_SCRIPT_URL _ids _saved_path _out

# ── optional targets ──────────────────────────────────────────────────────────
# Functions the target code calls out to are replaced by shell functions here
# and restored by re-sourcing the extracted functions at the end.
_tt="$(mktemp -d)"
TARGETS_DIR="$_tt/targets"
for _name in gitea mattermost ollama airllm kindi llamacpp strata basalt maya xolotl avalon honcho hermes openclaw deepseek-harness opencode open-terminal comfyui; do
  mkdir -p "$TARGETS_DIR/$_name"
  # The fake provisioner records what it was given: settings, flags, and
  # whether the admin token reached it (by value, compared to $EXPECT_TOKEN).
  cat > "$TARGETS_DIR/$_name/provision-lxc.sh" <<'EOF'
token=no; [[ -n ${OPENWEBUI_ADMIN_TOKEN:-} ]] && token=yes
[[ ${OPENWEBUI_ADMIN_TOKEN:-} == "${EXPECT_TOKEN:-unset}" ]] && token=match
printf 'provision %s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$(basename "$(dirname "$0")")" \
  "${CT_ID:-}" "${IP_CIDR:-}" "${GATEWAY:-}" "${STORAGE:-}" "${BRIDGE:-}" "${TEMPLATE:-}" \
  "${CORES:-}" "${ROOTFS_GB:-}" "${ROUTER_CT_ID:-}" "${OPENWEBUI_PORT:-}" "$token" "$*" >> "$MOCK_LOG"
[[ -z ${COMMUNITY_SCRIPT_URL:-}${COMMUNITY_SCRIPT_SHA256:-}${MATTERMOST_CHANNEL:-} ]] ||
  printf 'service-env %s|%s|%s\n' "${COMMUNITY_SCRIPT_URL:-}" "${COMMUNITY_SCRIPT_SHA256:-}" "${MATTERMOST_CHANNEL:-}" >> "$MOCK_LOG"
[[ -z ${COMFYUI_IMAGE_VARIANT:-} ]] || printf 'image-variant %s\n' "$COMFYUI_IMAGE_VARIANT" >> "$MOCK_LOG"
printf 'prompt-env %s|%s|%s\n' "${PVE_ACCEPT_DEFAULTS:-}" "${PVE_CONFIRM:-}" "${PVE_INTERACTIVE:-}" > "$MOCK_LOG.prompt"
[[ -z ${HONCHO_CLIENT_IPS:-}${HONCHO_URL:-}${HONCHO_CT_ID:-} ]] ||
  printf 'honcho-env %s|%s|%s\n' "${HONCHO_CLIENT_IPS:-}" "${HONCHO_URL:-}" "${HONCHO_CT_ID:-}" >> "$MOCK_LOG"
[[ -z ${OPEN_TERMINAL_URL:-}${OPEN_TERMINAL_CT_ID:-} ]] ||
  printf 'open-terminal-env %s|%s\n' "${OPEN_TERMINAL_URL:-}" "${OPEN_TERMINAL_CT_ID:-}" >> "$MOCK_LOG"
[[ -z ${HONCHO_EMBEDDING_MODEL:-}${HONCHO_EMBEDDING_DIMENSIONS:-}${HONCHO_EMBEDDING_BASE_URL:-} ]] ||
  printf 'embedding-env %s|%s|%s\n' "${HONCHO_EMBEDDING_MODEL:-}" "${HONCHO_EMBEDDING_DIMENSIONS:-}" "${HONCHO_EMBEDDING_BASE_URL:-}" >> "$MOCK_LOG"
[[ $(basename "$(dirname "$0")") != honcho ]] ||
  printf 'router-ip %s\n' "${ROUTER_IP:-}" >> "$MOCK_LOG"
[[ $(basename "$(dirname "$0")") != honcho ]] ||
  printf 'chat-model %s\n' "${HONCHO_MODEL:-}" >> "$MOCK_LOG"
[[ -z ${GPU:-}${BACKEND:-}${GPU_DEVICES:-}${GPU_CARD:-} ]] ||
  printf 'gpu-env %s|%s|%s|%s\n' "${GPU:-}" "${BACKEND:-}" "${GPU_DEVICES:-}" "${GPU_CARD:-}" >> "$MOCK_LOG"
_ctx="${OLLAMA_CONTEXT_LENGTH:-}|${CONTEXT_SIZE:-}|${STRATA_CONTEXT:-}|${AVALON_CONTEXT:-}|${HONCHO_CONTEXT_TOKENS-unset}|${DEEPSEEK_HARNESS_CONTEXT_WINDOW:-}"
[[ $_ctx == '||||unset|' ]] || printf 'context-env %s\n' "$_ctx" >> "$MOCK_LOG"
[[ -z ${STRATA_KV:-} ]] || printf 'strata-kv %s\n' "$STRATA_KV" >> "$MOCK_LOG"
[[ $(basename "$(dirname "$0")") != opencode ]] ||
  printf 'opencode-env %s|%s\n' "${OPENCODE_MODEL:-}" "${OPENCODE_ACCESS_CIDR:-}" >> "$MOCK_LOG"
[[ $(basename "$(dirname "$0")") != deepseek-harness ]] ||
  printf 'dsh-env openwebui=%s\n' "${OPENWEBUI:-default}" >> "$MOCK_LOG"
[[ -z ${KINDI_BACKEND:-}${KINDI_CONTEXT:-} ]] ||
  printf 'kindi-env %s|%s|%s\n' "${KINDI_BACKEND:-}" "${GPU_DEVICES:-}" "${KINDI_CONTEXT:-}" >> "$MOCK_LOG"
[[ -z ${CUDA_VERSION:-}${MAYA_CUDA_VERSION:-}${XOLOTL_CUDA_VERSION:-}${AVALON_CUDA_VERSION:-} ]] ||
  printf 'cuda-env %s|%s|%s|%s\n' "${CUDA_VERSION:-}" "${MAYA_CUDA_VERSION:-}" "${XOLOTL_CUDA_VERSION:-}" "${AVALON_CUDA_VERSION:-}" >> "$MOCK_LOG"
if [[ -n ${HF_TOKEN:-} ]]; then
  if [[ $HF_TOKEN == "${EXPECT_HF_TOKEN:-unset}" ]]; then echo 'hf-token match'; else echo 'hf-token other'; fi >> "$MOCK_LOG"
fi
exit "${FAKE_PROVISION_RC:-0}"
EOF
done
unset _name

describe target_table
assert_eq "lists the eighteen targets in menu order" \
  "gitea mattermost ollama airllm kindi llamacpp strata basalt maya xolotl avalon honcho hermes openclaw deepseek-harness opencode open-terminal comfyui" \
  "$(target_table | cut -d'|' -f1 | paste -sd' ')"

describe target_field
assert_eq "model phase" model "$(target_field strata phase)"
assert_eq "companion phase" companion "$(target_field hermes phase)"
assert_eq "ComfyUI is a companion of Open WebUI" companion "$(target_field comfyui phase)"
assert_eq "and not a model server" "" "$(target_field comfyui entry)"
assert_eq "OpenClaw is a companion" companion "$(target_field openclaw phase)"
assert_eq "DeepSeek Harness is a separate companion" companion "$(target_field deepseek-harness phase)"
assert_eq "and not a model server" "" "$(target_field deepseek-harness entry)"
assert_eq "OpenCode is a separate companion" companion "$(target_field opencode phase)"
assert_eq "not a model server" "" "$(target_field opencode entry)"
assert_eq "and needs no GPU" "" "$(target_field opencode gpu)"
assert_eq "Honcho is a CPU memory companion" companion "$(target_field honcho phase)"
assert_eq "and has no GPU requirement" "" "$(target_field honcho gpu)"
assert_eq "and runs without a GPU" "" "$(target_field openclaw gpu)"
assert_eq "service phase" service "$(target_field gitea phase)"
assert_eq "router entry template" "strata+http://@IP@:@PORT@" "$(target_field strata entry)"
assert_eq "key kind" basalt "$(target_field basalt key)"
assert_eq "Xolotl has its own key kind" xolotl "$(target_field xolotl key)"
assert_eq "Xolotl router entry template" "xolotl+http://@IP@:@PORT@" "$(target_field xolotl entry)"
assert_eq "Avalon has its own key kind" avalon "$(target_field avalon key)"
assert_eq "Avalon router entry template" "avalon+http://@IP@:@PORT@" "$(target_field avalon entry)"
assert_eq "Avalon needs an RDNA 3 or an RTX card" required:amd,nvidia:rdna3,rtx20,rtx30,rtx40,rtx50 "$(target_field avalon gpu)"
assert_eq "Kindi has its own key kind" kindi "$(target_field kindi key)"
assert_eq "Kindi router entry template" "kindi+http://@IP@:@PORT@" "$(target_field kindi entry)"
assert_eq "Kindi uses any NVIDIA card when present, of any generation" optional:nvidia "$(target_field kindi gpu)"
assert_eq "Kindi is a model server" model "$(target_field kindi phase)"
assert_eq "no key for Ollama" "" "$(target_field ollama key)"
assert_fail "an unknown target" target_field nope phase
assert_eq "Strata needs an NVIDIA GPU" required:nvidia "$(target_field strata gpu)"
assert_eq "Basalt needs an RTX 50" required:nvidia:rtx50 "$(target_field basalt gpu)"
assert_eq "Ollama uses any GPU when present" optional:nvidia,amd,intel "$(target_field ollama gpu)"
assert_eq "Hermes runs without" "" "$(target_field hermes gpu)"
assert_fail "an unknown field" target_field ollama colour

describe target_gpu_spec
unset BACKEND GPU_DEVICES GPU
assert_eq "Xolotl: NVIDIA only" "required|nvidia|" "$(target_gpu_spec xolotl)"
assert_eq "Basalt: RTX 50 only" "required|nvidia|rtx50" "$(target_gpu_spec basalt)"
assert_eq "llama.cpp: any vendor by default" "required|nvidia,amd,intel|" "$(target_gpu_spec llamacpp)"
assert_eq "llama.cpp BACKEND=cuda: NVIDIA" "required|nvidia|" "$(BACKEND=cuda target_gpu_spec llamacpp)"
assert_eq "llama.cpp BACKEND=vulkan: AMD or Intel" "required|amd,intel|" "$(BACKEND=vulkan target_gpu_spec llamacpp)"
assert_eq "llama.cpp BACKEND=cpu: none" "||" "$(BACKEND=cpu target_gpu_spec llamacpp)"
assert_eq "AirLLM with GPU_DEVICES: NVIDIA" "required|nvidia|" "$(GPU_DEVICES=/dev/nvidia0 target_gpu_spec airllm)"
assert_eq "AirLLM without: none" "||" "$(target_gpu_spec airllm)"
assert_eq "ComfyUI: any vendor when present" "optional|nvidia,amd,intel|" "$(target_gpu_spec comfyui)"
assert_eq "ComfyUI GPU=amd: AMD" "optional|amd|" "$(GPU=amd target_gpu_spec comfyui)"
assert_eq "Ollama GPU=no: none" "||" "$(GPU=no target_gpu_spec ollama)"
assert_eq "ComfyUI GPU=none: none" "||" "$(GPU=none target_gpu_spec comfyui)"
assert_eq "Gitea: none" "||" "$(target_gpu_spec gitea)"
assert_eq "Avalon: AMD (ROCm) first, or NVIDIA" "required|amd,nvidia|rdna3,rtx20,rtx30,rtx40,rtx50" "$(target_gpu_spec avalon)"
assert_eq "Avalon AVALON_BACKEND=rocm: AMD" "required|amd|rdna3,rtx20,rtx30,rtx40,rtx50" "$(AVALON_BACKEND=rocm target_gpu_spec avalon)"
assert_eq "Avalon AVALON_BACKEND=cuda: NVIDIA" "required|nvidia|rdna3,rtx20,rtx30,rtx40,rtx50" "$(AVALON_BACKEND=cuda target_gpu_spec avalon)"
assert_eq "Kindi: an NVIDIA card when present" "optional|nvidia|" "$(target_gpu_spec kindi)"
assert_eq "Kindi KINDI_BACKEND=cuda: one is required" "required|nvidia|" "$(KINDI_BACKEND=cuda target_gpu_spec kindi)"
assert_eq "Kindi KINDI_BACKEND=cpu: none" "||" "$(KINDI_BACKEND=cpu target_gpu_spec kindi)"
assert_fail "an unknown target" target_gpu_spec nope

describe target_gpu_need
assert_eq "Xolotl requires the GPU" required "$(target_gpu_need xolotl)"
assert_eq "the generation limit is not part of the need" required "$(target_gpu_need basalt)"
assert_eq "ComfyUI uses one when present" optional "$(target_gpu_need comfyui)"
assert_eq "llama.cpp's default build requires it" required "$(target_gpu_need llamacpp)"
assert_eq "llama.cpp with BACKEND=cpu does not" "" "$(BACKEND=cpu target_gpu_need llamacpp)"
assert_eq "AirLLM without GPU_DEVICES does not" "" "$(target_gpu_need airllm)"
assert_eq "AirLLM with GPU_DEVICES does" required "$(GPU_DEVICES=/dev/nvidia0 target_gpu_need airllm)"
assert_eq "Gitea never" "" "$(target_gpu_need gitea)"
assert_eq "Kindi uses one when present" optional "$(target_gpu_need kindi)"
assert_fail "an unknown target" target_gpu_need nope

# The GPU step's fake tool: --list prints FAKE_GPU_LIST; a run for --card
# 0000:03:00.0 or 0000:04:00.0 answers for that AMD or Intel card, any other
# run FAKE_GPU_OUT with FAKE_GPU_RC.
mkdir -p "$_tt/tools"
cat > "$_tt/tools/setup-host-gpu.sh" <<'EOF'
printf 'gpu-tool %s\n' "$*" >> "$MOCK_LOG"
case " $* " in
  *" --list "*) [[ -z ${FAKE_GPU_LIST:-} ]] || printf '%s\n' "$FAKE_GPU_LIST"; exit 0 ;;
  *" --card 0000:03:00.0 "*) printf '%s\n' GPU_STATE=ready GPU_GENERATION=rdna3 GPU_VENDOR=amd GPU_GFX=gfx1100 \
      GPU_RENDER_NODE=/dev/dri/renderD128 GPU_PCI=0000:03:00.0; exit 0 ;;
  *" --card 0000:04:00.0 "*) printf '%s\n' GPU_STATE=ready GPU_GENERATION=arc-b GPU_VENDOR=intel \
      GPU_RENDER_NODE=/dev/dri/renderD129 GPU_PCI=0000:04:00.0; exit 0 ;;
esac
printf '%s\n' "${FAKE_GPU_OUT:-GPU_STATE=ready}"
exit "${FAKE_GPU_RC:-0}"
EOF
_cards=$'0000:01:00.0|nvidia|rtx40|nouveau|NVIDIA AD102 [GeForce RTX 4090]
0000:03:00.0|amd|rdna3|amdgpu|AMD Radeon Navi 31 [Radeon RX 7900 XTX]
0000:04:00.0|intel|arc-b||Intel Arc Battlemage G21 [Arc B580]
0000:05:00.0|amd|rdna4|vfio-pci|AMD Radeon Navi 48 [Radeon RX 9070 XT]'
_card_list="$(sed 's/^/GPU_CARD=/' <<< "$_cards")"
_gpu_reset() {
  unset OLLAMA_GPU_CARD LLAMACPP_GPU_CARD COMFYUI_GPU_CARD GPU_RESULT_OLLAMA GPU_RESULT_LLAMACPP GPU_RESULT_COMFYUI \
    GPU_RESULT_STRATA GPU_RESULT_BASALT GPU_RESULT_XOLOTL FAKE_GPU_OUT FAKE_GPU_RC FAKE_GPU_LIST BACKEND GPU GPU_DEVICES \
    KINDI_GPU_CARD GPU_RESULT_KINDI KINDI_BACKEND
  HOST_GPU_CARDS="" HOST_GPU_CUDA_ARCH=""
  mock_reset_log
}

describe host_gpu_tool
_gpu_reset
assert_eq "the checkout's tool" "$TARGETS_DIR/../tools/setup-host-gpu.sh" "$(host_gpu_tool)"
mv "$_tt/tools/setup-host-gpu.sh" "$_tt/tools/gone"
assert_fail "the tool must be in the checkout" host_gpu_tool
assert_contains "and says so" "Run the OSR installer from the full repository checkout" "$(host_gpu_tool 2>&1)"
mv "$_tt/tools/gone" "$_tt/tools/setup-host-gpu.sh"

describe load_host_gpu_cards
_gpu_reset
export FAKE_GPU_LIST="$_card_list"
load_host_gpu_cards
assert_eq "every card, without the GPU_CARD= prefix" "$_cards" "$HOST_GPU_CARDS"
assert_contains "listed for every vendor" "gpu-tool --list --vendors nvidia,amd,intel" "$(cat "$MOCK_LOG")"
unset FAKE_GPU_LIST
load_host_gpu_cards
assert_eq "a host without cards lists none" "" "$HOST_GPU_CARDS"

describe host_gpu_card
HOST_GPU_CARDS="$_cards"
assert_eq "by its full address" "0000:04:00.0|intel|arc-b||Intel Arc Battlemage G21 [Arc B580]" "$(host_gpu_card 0000:04:00.0)"
assert_eq "or the short one, in any case" "0000:03:00.0" "$(host_gpu_card 03:00.0 | cut -d'|' -f1)"
assert_fail "a card not on the host" host_gpu_card 0000:09:00.0
assert_fail "nothing for nothing" host_gpu_card ""

describe gpu_card_label
assert_eq "a card and its driver" "0000:03:00.0  AMD Radeon Navi 31 [Radeon RX 7900 XTX] (rdna3, driver amdgpu)" \
  "$(gpu_card_label "$(host_gpu_card 03:00.0)")"
assert_eq "one without a driver yet" "0000:04:00.0  Intel Arc Battlemage G21 [Arc B580] (arc-b, no driver yet; set up next)" \
  "$(gpu_card_label "$(host_gpu_card 04:00.0)")"
assert_eq "an NVIDIA card of no listed generation" "0000:41:00.0  NVIDIA GA100 (driver nvidia)" \
  "$(gpu_card_label '0000:41:00.0|nvidia||nvidia|NVIDIA GA100')"

describe target_gpu_prompted
_gpu_reset
assert_ok "Ollama asks" target_gpu_prompted ollama
assert_ok "so does llama.cpp" target_gpu_prompted llamacpp
assert_ok "and ComfyUI" target_gpu_prompted comfyui
assert_fail "not llama.cpp built for CUDA" env BACKEND=cuda bash -c "$(declare -f target_gpu_prompted target_gpu_spec target_field target_table); target_gpu_prompted llamacpp"
assert_fail "not Ollama on NVIDIA only" env GPU=nvidia bash -c "$(declare -f target_gpu_prompted target_gpu_spec target_field target_table); target_gpu_prompted ollama"
assert_fail "not without a GPU" env GPU=none bash -c "$(declare -f target_gpu_prompted target_gpu_spec target_field target_table); target_gpu_prompted comfyui"
assert_fail "not the NVIDIA-only targets" target_gpu_prompted strata
assert_ok "but Kindi, meant for a spare old NVIDIA card" target_gpu_prompted kindi
assert_fail "not Kindi on the CPU" env KINDI_BACKEND=cpu bash -c "$(declare -f target_gpu_prompted target_gpu_spec target_field target_table); target_gpu_prompted kindi"
assert_fail "not the targets without a GPU" target_gpu_prompted hermes

describe target_gpu_choices
HOST_GPU_CARDS="$_cards"
assert_eq "Ollama: the target's vendor order, no vfio-pci card" "0000:01:00.0 0000:03:00.0 0000:04:00.0" \
  "$(target_gpu_choices ollama | cut -d'|' -f1 | paste -sd' ')"
assert_eq "llama.cpp's Vulkan build: AMD and Intel" "0000:03:00.0 0000:04:00.0" \
  "$(BACKEND=vulkan target_gpu_choices llamacpp | cut -d'|' -f1 | paste -sd' ')"
assert_eq "GPU=intel: Intel only" "0000:04:00.0" "$(GPU=intel target_gpu_choices comfyui | cut -d'|' -f1)"
assert_eq "a generation limit applies (Basalt: rtx50)" "" "$(target_gpu_choices basalt)"
assert_eq "no GPU, no choice" "" "$(GPU=none target_gpu_choices ollama)"
assert_eq "Kindi: the NVIDIA cards, of any generation" "0000:01:00.0 0000:41:00.0" \
  "$(HOST_GPU_CARDS="$_cards"$'\n0000:41:00.0|nvidia||nvidia|NVIDIA GK107GL [Quadro K420]' target_gpu_choices kindi | cut -d'|' -f1 | paste -sd' ')"

describe valid_gpu_choice
GPU_CHOICE_ADDRESSES="0000:03:00.0 0000:04:00.0" GPU_CHOICE_NONE=false
assert_ok "a menu number" valid_gpu_choice 2
assert_fail "past the menu" valid_gpu_choice 3
assert_fail "zero" valid_gpu_choice 0
assert_ok "a listed address" valid_gpu_choice 0000:04:00.0
assert_ok "short and upper-case" valid_gpu_choice 03:00.0
assert_fail "an unlisted card" valid_gpu_choice 0000:05:00.0
assert_fail "none for a target that needs a GPU" valid_gpu_choice none
GPU_CHOICE_NONE=true
assert_ok "none for one that does not" valid_gpu_choice none
assert_ok "or the number after the cards" valid_gpu_choice 3
assert_fail "free text" valid_gpu_choice radeon
unset GPU_CHOICE_ADDRESSES GPU_CHOICE_NONE

describe prompt_target_gpus
_gpu_reset
TARGETS="strata hermes"
assert_ok "nothing to ask without an AMD/Intel-capable target" prompt_target_gpus
assert_eq "and the host is not even listed" "" "$(cat "$MOCK_LOG")"
export FAKE_GPU_LIST="$_card_list"
TARGETS="ollama llamacpp strata"
_out="$(mktemp)"
prompt_target_gpus > "$_out" 2>&1 <<< $'3\n9\n2\n'
assert_eq "Ollama takes the third card" 0000:04:00.0 "${OLLAMA_GPU_CARD:-}"
assert_eq "llama.cpp re-asks past the menu, then takes the second" 0000:03:00.0 "${LLAMACPP_GPU_CARD:-}"
assert_contains "the host's cards are shown" "0000:05:00.0  AMD Radeon Navi 48 [Radeon RX 9070 XT] (rdna4, bound to vfio-pci)" "$(cat "$_out")"
assert_contains "Ollama's menu" "Which GPU should ollama use?" "$(cat "$_out")"
assert_contains "offers the CPU" "4) none: run on the CPU" "$(cat "$_out")"
assert_not_contains "llama.cpp's does not" "4) none" "$(sed -n '/llamacpp use/,$p' "$_out")"
assert_not_contains "the NVIDIA-only target is not asked" "strata use" "$(cat "$_out")"
assert_eq "no vfio-pci card in a menu" 0 "$(grep -c '[0-9]) 0000:05:00.0' "$_out")"
_gpu_reset; export FAKE_GPU_LIST="$_card_list"
TARGETS="ollama comfyui"
prompt_target_gpus > "$_out" 2>&1 <<< $'none\n4\n'
assert_eq "none by name" none "$OLLAMA_GPU_CARD"
assert_eq "or by number" none "$COMFYUI_GPU_CARD"
_gpu_reset; export FAKE_GPU_LIST="$_card_list"
OLLAMA_GPU_CARD=03:00.0 TARGETS=ollama
prompt_target_gpus > "$_out" 2>&1 <<< $'\n'
assert_eq "a preset is the default, written out in full" 0000:03:00.0 "$OLLAMA_GPU_CARD"
OLLAMA_GPU_CARD=0000:05:00.0
assert_fail "a preset card the target cannot use" prompt_target_gpus
assert_contains "is named" "OLLAMA_GPU_CARD=0000:05:00.0 is not a GPU ollama can use on this host." "$(prompt_target_gpus 2>&1 <<< '')"
_gpu_reset; export FAKE_GPU_LIST="$_card_list"
LLAMACPP_GPU_CARD=none TARGETS=llamacpp
assert_contains "none for a target that needs a GPU" "LLAMACPP_GPU_CARD=none: llamacpp needs a GPU" "$(prompt_target_gpus 2>&1 <<< '')"
_gpu_reset; export FAKE_GPU_LIST="GPU_CARD=0000:03:00.0|amd|rdna3|amdgpu|AMD Radeon Navi 31"
TARGETS=llamacpp
prompt_target_gpus > "$_out" 2>&1 </dev/null
assert_eq "one card and a target that needs it: taken without asking" 0000:03:00.0 "$LLAMACPP_GPU_CARD"
assert_contains "and said" "llamacpp uses the only GPU it can: 0000:03:00.0" "$(cat "$_out")"
TARGETS=comfyui
prompt_target_gpus > "$_out" 2>&1 <<< $'\n'
assert_eq "a target that can do without is still asked (card or CPU)" 0000:03:00.0 "$COMFYUI_GPU_CARD"
_gpu_reset
TARGETS="ollama"
prompt_target_gpus > "$_out" 2>&1 </dev/null
assert_contains "a host without cards says so" "No NVIDIA, AMD Radeon (RX 7000/9000) or Intel Arc GPU" "$(cat "$_out")"
assert_eq "and leaves the target to the GPU step" "" "${OLLAMA_GPU_CARD:-}"
_gpu_reset; export FAKE_GPU_LIST="$_card_list"$'\nGPU_CARD=0000:41:00.0|nvidia||nvidia|NVIDIA GK107GL [Quadro K420]'
TARGETS="strata kindi"
prompt_target_gpus > "$_out" 2>&1 <<< $'2\n'
assert_eq "Kindi is asked for its card: the old one" 0000:41:00.0 "$KINDI_GPU_CARD"
assert_contains "or the CPU" "3) none: run on the CPU" "$(cat "$_out")"
assert_not_contains "only NVIDIA cards are offered to it" "Radeon RX 7900 XTX] (rdna3, driver amdgpu)"$'\n'"    3)" "$(sed -n '/kindi use/,$p' "$_out")"
_gpu_reset
rm -f "$_out"; TARGETS=""

describe target_gpu_result
GPU_RESULT_OLLAMA="ready|amd|/dev/dri/renderD128||0000:03:00.0"
assert_eq "the whole result" "ready|amd|/dev/dri/renderD128||0000:03:00.0" "$(target_gpu_result ollama)"
assert_eq "its state" ready "$(target_gpu_result ollama state)"
assert_eq "the render node" /dev/dri/renderD128 "$(target_gpu_result ollama render)"
assert_eq "the card" 0000:03:00.0 "$(target_gpu_result ollama pci)"
assert_eq "an empty field" "" "$(target_gpu_result ollama minor)"
assert_eq "nothing before the step" "" "$(target_gpu_result comfyui state)"
assert_fail "an unknown field" target_gpu_result ollama colour

describe run_host_gpu_tool
_gpu_reset
_out="$(run_host_gpu_tool optional amd 0000:03:00.0 "ollama comfyui" 2>&1)"
assert_contains "one run for the card, with its vendor" "gpu-tool --need optional --vendors amd --for ollama comfyui --card 0000:03:00.0" "$(cat "$MOCK_LOG")"
assert_contains "headed by the card" "--- GPU 0000:03:00.0 for: ollama comfyui ---" "$_out"
assert_contains "the card is reported" "AMD Radeon GPU ready: rdna3 (gfx1100, /dev/dri/renderD128 and /dev/kfd)" "$_out"
run_host_gpu_tool optional amd 0000:03:00.0 "ollama comfyui" >/dev/null 2>&1
assert_eq "each target gets the result" "ready|amd|/dev/dri/renderD128||0000:03:00.0 ready|amd|/dev/dri/renderD128||0000:03:00.0" \
  "${GPU_RESULT_OLLAMA} ${GPU_RESULT_COMFYUI}"
mock_reset_log
export FAKE_GPU_OUT=$'GPU_STATE=ready\nGPU_GENERATION=rtx50\nGPU_CUDA_ARCH=120\nGPU_VENDOR=nvidia\nGPU_NVIDIA_MINOR=1\nGPU_PCI=0000:02:00.0'
run_host_gpu_tool required nvidia "" "strata basalt" --allow rtx50:basalt > "$MOCK_BIN/out" 2>&1
assert_contains "no card: the vendors and --allow rules" "gpu-tool --need required --vendors nvidia --for strata basalt --allow rtx50:basalt" "$(cat "$MOCK_LOG")"
assert_not_contains "and no --card" "--card" "$(cat "$MOCK_LOG")"
assert_contains "NVIDIA is reported" "NVIDIA GPU ready: rtx50 (compute capability 120)" "$(cat "$MOCK_BIN/out")"
assert_eq "its compute capability is kept" 120 "$HOST_GPU_CUDA_ARCH"
assert_eq "and its minor" 1 "$(target_gpu_result basalt minor)"
export FAKE_GPU_OUT=GPU_STATE=absent
assert_contains "no GPU: the targets go on without" "No GPU (absent): ollama will run without one." "$(run_host_gpu_tool optional nvidia "" ollama 2>&1)"
export FAKE_GPU_RC=2
assert_fail "a reboot stops the install" run_host_gpu_tool required nvidia "" xolotl
assert_contains "and says to rerun" "Reboot this host" "$(run_host_gpu_tool required nvidia "" xolotl 2>&1)"
FAKE_GPU_RC=1
assert_contains "a GPU that is not ready names the targets" "The GPU is not ready for: xolotl" "$(run_host_gpu_tool required nvidia "" xolotl 2>&1)"
_gpu_reset

# The cluster SSH step's fake tool: logs its arguments, answers FAKE_SSH_RC.
cat > "$_tt/tools/setup-cluster-ssh.sh" <<'EOF'
printf 'ssh-tool %s\n' "$*" >> "$MOCK_LOG"
echo 'cluster ssh report'
exit "${FAKE_SSH_RC:-0}"
EOF

describe cluster_ssh_tool
assert_eq "the checkout's tool" "$TARGETS_DIR/../tools/setup-cluster-ssh.sh" "$(cluster_ssh_tool)"
mv "$_tt/tools/setup-cluster-ssh.sh" "$_tt/tools/gone"
assert_fail "the tool must be in the checkout" cluster_ssh_tool
assert_contains "and says so" "Run the OSR installer from the full repository checkout" "$(cluster_ssh_tool 2>&1)"
mv "$_tt/tools/gone" "$_tt/tools/setup-cluster-ssh.sh"

describe prepare_cluster_ssh
mock_reset_log; CLUSTER_SSH=fix NONINTERACTIVE=false
_out="$(prepare_cluster_ssh 2>&1)"
assert_eq "checks and repairs, asking on a terminal" "ssh-tool " "$(cat "$MOCK_LOG")"
assert_contains "under its own heading" "--- Root SSH between the cluster's nodes (for upgrades from any node) ---" "$_out"
assert_contains "showing the tool's report" "cluster ssh report" "$_out"
mock_reset_log; NONINTERACTIVE=true
prepare_cluster_ssh >/dev/null 2>&1
assert_eq "unattended: repairs without questions" "ssh-tool --yes" "$(cat "$MOCK_LOG")"
NONINTERACTIVE=false
mock_reset_log; CLUSTER_SSH=check
prepare_cluster_ssh >/dev/null 2>&1
assert_eq "CLUSTER_SSH=check only reports" "ssh-tool --check" "$(cat "$MOCK_LOG")"
mock_reset_log; CLUSTER_SSH=skip
assert_contains "CLUSTER_SSH=skip skips it" "Cluster SSH check skipped" "$(prepare_cluster_ssh 2>&1)"
assert_eq "without running the tool" "" "$(cat "$MOCK_LOG")"
CLUSTER_SSH=maybe
assert_fail "another value is refused" prepare_cluster_ssh
CLUSTER_SSH=fix; export FAKE_SSH_RC=1
assert_ok "a problem left over does not stop the install" prepare_cluster_ssh
assert_contains "but is a warning" "WARNING: root SSH between the cluster's nodes is incomplete" "$(prepare_cluster_ssh 2>&1)"
assert_contains "saying how to check again" "Check again with: bash $TARGETS_DIR/../tools/setup-cluster-ssh.sh" "$(prepare_cluster_ssh 2>&1)"
FAKE_SSH_RC=2
assert_ok "nor does a check that could not run" prepare_cluster_ssh
assert_contains "which is reported" "the cluster SSH check could not run (exit 2)" "$(prepare_cluster_ssh 2>&1)"
unset FAKE_SSH_RC
mv "$_tt/tools/setup-cluster-ssh.sh" "$_tt/tools/gone"
assert_fail "a checkout without the tool stops" prepare_cluster_ssh
mv "$_tt/tools/gone" "$_tt/tools/setup-cluster-ssh.sh"
mock_reset_log

describe prepare_host_gpu
_gpu_reset
TARGETS="gitea hermes"
assert_ok "nothing to do without GPU targets" prepare_host_gpu
assert_eq "and the tool is not run" "" "$(cat "$MOCK_LOG")"
HOST_GPU_CARDS="$_cards"
TARGETS="ollama comfyui llamacpp strata basalt"
OLLAMA_GPU_CARD=0000:03:00.0 COMFYUI_GPU_CARD=03:00.0 LLAMACPP_GPU_CARD=0000:04:00.0
export FAKE_GPU_OUT=$'GPU_STATE=ready\nGPU_GENERATION=rtx50\nGPU_CUDA_ARCH=120\nGPU_VENDOR=nvidia'
_out="$(prepare_host_gpu 2>&1)"
assert_contains "targets sharing a card share a run" "gpu-tool --need optional --vendors amd --for ollama comfyui --card 0000:03:00.0" "$(cat "$MOCK_LOG")"
assert_contains "each card gets its own" "gpu-tool --need required --vendors intel --for llamacpp --card 0000:04:00.0" "$(cat "$MOCK_LOG")"
assert_contains "the NVIDIA-only targets share one, with their limits" \
  "gpu-tool --need required --vendors nvidia --for strata basalt --allow rtx50:basalt" "$(cat "$MOCK_LOG")"
assert_eq "three runs" 3 "$(mock_call_count gpu-tool)"
assert_contains "the Arc card is reported" "Intel Arc GPU ready: arc-b (/dev/dri/renderD129)" "$_out"
prepare_host_gpu >/dev/null 2>&1
assert_eq "each target keeps its card's result" "amd intel nvidia" \
  "$(target_gpu_result ollama vendor) $(target_gpu_result llamacpp vendor) $(target_gpu_result basalt vendor)"
_gpu_reset; HOST_GPU_CARDS="$_cards"
TARGETS="ollama comfyui"; OLLAMA_GPU_CARD=none COMFYUI_GPU_CARD=0000:04:00.0
_out="$(prepare_host_gpu 2>&1)"
assert_contains "none: the CPU, no run" "ollama runs on the CPU (no GPU chosen)." "$_out"
assert_eq "only the chosen card is set up" 1 "$(mock_call_count gpu-tool)"
prepare_host_gpu >/dev/null 2>&1
assert_eq "and the target knows" declined "$(target_gpu_result ollama state)"
OLLAMA_GPU_CARD=0000:09:00.0
assert_fail "a card that is not on the host" prepare_host_gpu
_gpu_reset; HOST_GPU_CARDS="$_cards"
TARGETS="ollama llamacpp comfyui"; OLLAMA_GPU_CARD=0000:03:00.0 LLAMACPP_GPU_CARD=0000:03:00.0 COMFYUI_GPU_CARD=0000:03:00.0
prepare_host_gpu >/dev/null 2>&1
assert_contains "a card shared with a target that needs it is required" \
  "gpu-tool --need required --vendors amd --for ollama llamacpp comfyui --card 0000:03:00.0" "$(cat "$MOCK_LOG")"
_gpu_reset
TARGETS="ollama comfyui"; export FAKE_GPU_OUT=GPU_STATE=absent
_out="$(prepare_host_gpu 2>&1)"
assert_contains "without chosen cards (no inventory): one run, any vendor" "gpu-tool --need optional --vendors nvidia,amd,intel --for ollama comfyui" "$(cat "$MOCK_LOG")"
assert_contains "and they go on without a GPU" "No GPU (absent): ollama comfyui will run without one." "$_out"
_gpu_reset
TARGETS="strata llamacpp"
assert_fail "card-less targets that cannot share a GPU" env BACKEND=vulkan bash -c "$(declare -f); TARGETS='$TARGETS' TARGETS_DIR='$TARGETS_DIR' prepare_host_gpu"
_out="$(BACKEND=vulkan prepare_host_gpu 2>&1 || true)"
assert_contains "are named, before the tool runs" "cannot share one GPU: strata (nvidia) llamacpp (amd/intel)" "$_out"
assert_eq "and nothing ran" "" "$(cat "$MOCK_LOG")"
HOST_GPU_CARDS="$_cards" LLAMACPP_GPU_CARD=0000:03:00.0
_out="$(BACKEND=vulkan prepare_host_gpu 2>&1)"
assert_contains "with a card each, mixed vendors are fine" "--vendors amd --for llamacpp --card 0000:03:00.0" "$(cat "$MOCK_LOG")"
TARGETS="xolotl"; unset LLAMACPP_GPU_CARD; export FAKE_GPU_RC=2
assert_fail "a reboot stops the install" prepare_host_gpu
FAKE_GPU_RC=1
assert_fail "a GPU that is not ready stops it" prepare_host_gpu
_gpu_reset
TARGETS=""; unset _out

describe target_gpu_env
_gpu_reset
assert_eq "nothing before the GPU step ran" "" "$(target_gpu_env ollama)"
GPU_RESULT_OLLAMA="ready|amd|/dev/dri/renderD128||0000:03:00.0"
GPU_RESULT_COMFYUI="ready|intel|/dev/dri/renderD129||0000:04:00.0"
assert_eq "Ollama gets the vendor and its card" $'GPU=amd\nGPU_CARD=0000:03:00.0' "$(target_gpu_env ollama)"
assert_eq "ComfyUI its own" $'GPU=intel\nGPU_CARD=0000:04:00.0' "$(target_gpu_env comfyui)"
assert_eq "a preset GPU is kept; the card is still passed" "GPU_CARD=0000:04:00.0" "$(GPU=intel target_gpu_env comfyui)"
GPU_RESULT_LLAMACPP="ready|intel|/dev/dri/renderD129||0000:04:00.0"
assert_eq "llama.cpp gets Vulkan and its card's render node" $'BACKEND=vulkan\nGPU_DEVICES=/dev/dri/renderD129' "$(target_gpu_env llamacpp)"
assert_eq "a preset GPU_DEVICES is kept" "BACKEND=vulkan" "$(GPU_DEVICES=/dev/dri/renderD130 target_gpu_env llamacpp)"
assert_eq "a preset BACKEND is kept" "" "$(BACKEND=cpu target_gpu_env llamacpp)"
GPU_RESULT_LLAMACPP="ready|nvidia|||"
GPU_RESULT_COMFYUI="ready|nvidia|||"
assert_eq "NVIDIA without a chosen card: llama.cpp asks for its devices itself" BACKEND=cuda "$(target_gpu_env llamacpp)"
assert_eq "NVIDIA: ComfyUI" GPU=nvidia "$(target_gpu_env comfyui)"
GPU_RESULT_LLAMACPP="ready|nvidia||1|0000:02:00.0"
assert_eq "NVIDIA card: its /dev/nvidia<minor> with the control and UVM devices" \
  $'BACKEND=cuda\nGPU_DEVICES=/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' "$(target_gpu_env llamacpp)"
GPU_RESULT_OLLAMA="declined||||" GPU_RESULT_LLAMACPP="absent||||"
assert_eq "no GPU: Ollama runs on the CPU" GPU=none "$(target_gpu_env ollama)"
assert_eq "no GPU: llama.cpp keeps its own default" "" "$(target_gpu_env llamacpp)"
GPU_RESULT_STRATA="ready|nvidia|||"
assert_eq "other targets get nothing" "" "$(target_gpu_env strata)"
GPU_RESULT_AVALON="ready|amd|/dev/dri/renderD128||0000:03:00.0"
assert_eq "Avalon on an AMD card: ROCm with /dev/kfd and the card's render node" \
  $'AVALON_BACKEND=rocm\nGPU_DEVICES=/dev/kfd /dev/dri/renderD128' "$(target_gpu_env avalon)"
assert_eq "a preset AVALON_BACKEND and GPU_DEVICES are kept" "" \
  "$(AVALON_BACKEND=rocm GPU_DEVICES='/dev/kfd /dev/dri/renderD129' target_gpu_env avalon)"
GPU_RESULT_AVALON="ready|nvidia||2|0000:02:00.0"
assert_eq "Avalon on an NVIDIA card: CUDA with its /dev/nvidia<minor>" \
  $'AVALON_BACKEND=cuda\nGPU_DEVICES=/dev/nvidia2 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' "$(target_gpu_env avalon)"
GPU_RESULT_AVALON="absent||||"
assert_eq "Avalon without a GPU: nothing (its provisioner stops)" "" "$(target_gpu_env avalon)"
GPU_RESULT_KINDI="ready|nvidia||3|0000:41:00.0"
assert_eq "Kindi on its NVIDIA card: CUDA with that card's /dev/nvidia<minor>" \
  $'KINDI_BACKEND=cuda\nGPU_DEVICES=/dev/nvidia3 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' "$(target_gpu_env kindi)"
assert_eq "a preset KINDI_BACKEND and GPU_DEVICES are kept" "" \
  "$(KINDI_BACKEND=cuda GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm' target_gpu_env kindi)"
GPU_RESULT_KINDI="ready|nvidia|||"
assert_eq "Kindi on GPU 0: its provisioner picks the nodes" KINDI_BACKEND=cuda "$(target_gpu_env kindi)"
GPU_RESULT_KINDI="declined||||"
assert_eq "Kindi given no card: its CPU engine" KINDI_BACKEND=cpu "$(target_gpu_env kindi)"
GPU_RESULT_KINDI="absent||||"
assert_eq "Kindi without a GPU: its CPU engine" KINDI_BACKEND=cpu "$(target_gpu_env kindi)"
_gpu_reset

describe target_var_prefix
assert_eq "dashes become underscores" OPEN_TERMINAL "$(target_var_prefix open-terminal)"
assert_eq "letters are upper-cased" LLAMACPP "$(target_var_prefix llamacpp)"

describe target_setting
OPEN_TERMINAL_CT_ID=283
assert_eq "reads <PREFIX>_<FIELD>" 283 "$(target_setting open-terminal CT_ID)"
assert_eq "an unset field is empty" "" "$(target_setting open-terminal TEMPLATE)"
unset OPEN_TERMINAL_CT_ID

describe llamacpp_model_given
unset MODEL_ALIAS MODEL_DOWNLOAD_URL MODEL_PATH
assert_fail "no model by default" llamacpp_model_given
MODEL_ALIAS=qwen3:8b
assert_fail "an alias alone is not enough" llamacpp_model_given
MODEL_DOWNLOAD_URL=https://huggingface.co/o/r/resolve/main/m.gguf
assert_ok "an alias and a URL are" llamacpp_model_given
unset MODEL_ALIAS MODEL_DOWNLOAD_URL

describe target_needs_template
assert_ok "Strata takes a template" target_needs_template strata
assert_ok "Maya takes a template" target_needs_template maya
assert_ok "Xolotl takes a template" target_needs_template xolotl
assert_ok "Avalon takes a template" target_needs_template avalon
assert_ok "Kindi takes a template" target_needs_template kindi
assert_fail "llama.cpp prompts for its own" target_needs_template llamacpp
assert_fail "Hermes uses the router's" target_needs_template hermes
assert_fail "OpenClaw uses the router's" target_needs_template openclaw
assert_fail "DeepSeek Harness uses the router's" target_needs_template deepseek-harness
assert_fail "OpenCode uses the router's" target_needs_template opencode
assert_fail "ComfyUI's community script picks its own" target_needs_template comfyui

describe valid_target_selection
for _sel in "" none "1,10" "ollama hermes" " 2 , strata " "8" "13" "14" "17" "18" "comfyui" "xolotl" "avalon" "kindi" "openclaw" "opencode"; do
  assert_ok "accepts '${_sel}'" valid_target_selection "$_sel"
done
for _sel in 0 19 bogus "ollama,bogus"; do
  assert_fail "rejects '${_sel}'" valid_target_selection "$_sel"
done
unset _sel

describe normalize_target_selection
assert_eq "names and numbers, in menu order" "gitea ollama kindi strata hermes" "$(normalize_target_selection 'hermes,3, 7,1,5')"
assert_eq "each target once" ollama "$(normalize_target_selection '3,ollama')"
assert_eq "none is empty" "" "$(normalize_target_selection none)"
assert_eq "blank is empty" "" "$(normalize_target_selection '')"

describe prompt_target_selection
NONINTERACTIVE=true; INSTALL_TARGETS=""
assert_ok "an unattended install without targets passes" prompt_target_selection
INSTALL_TARGETS=ollama
assert_fail "an unattended install refuses targets" prompt_target_selection
assert_contains "and says what to do instead" "targets/<name>/provision-lxc.sh" "$(prompt_target_selection 2>&1)"
INSTALL_TARGETS=bogus
assert_fail "an invalid preset is refused" prompt_target_selection
INSTALL_TARGETS="ollama,13"
assert_fail "a preset with a menu number is refused" prompt_target_selection
assert_contains "and says to use names" "not menu numbers: '13'" "$(prompt_target_selection 2>&1)"
NONINTERACTIVE=false
assert_fail "also when the menu would be shown" prompt_target_selection <<< $'\n'
NONINTERACTIVE=true
NONINTERACTIVE=false; INSTALL_TARGETS=""
_out="$(mktemp)"
prompt_target_selection > "$_out" 2>&1 <<< $'19\n6,hermes\n'
assert_eq "re-prompts until valid, then keeps the choice" "llamacpp hermes" "$TARGETS"
assert_contains "the menu lists the model servers" "10) xolotl" "$(cat "$_out")"
assert_contains "Avalon among them" "11) avalon" "$(cat "$_out")"
assert_contains "Kindi with the CPU or optional-GPU servers" "5) kindi" "$(sed -n '/CPU or optional GPU/,/GPU required/p' "$_out")"
assert_contains "the menu lists the companions" "13) hermes" "$(cat "$_out")"
assert_contains "ComfyUI among them" "18) comfyui" "$(cat "$_out")"
assert_contains "OpenClaw is grouped with agents" "14) openclaw" "$(cat "$_out")"
assert_contains "DeepSeek Harness has its own menu choice" "15) deepseek-harness" "$(cat "$_out")"
assert_contains "OpenCode follows the other agents" "16) opencode" "$(cat "$_out")"
assert_contains "and Open Terminal after them" "17) open-terminal" "$(cat "$_out")"
assert_contains "memory comes before agents" "Memory infrastructure (CPU)" "$(cat "$_out")"
assert_contains "the GPU model group is explicit" "Model servers (GPU required by default)" "$(cat "$_out")"
assert_contains "the CPU model group is explicit" "Model servers (CPU or optional GPU)" "$(cat "$_out")"
assert_contains "the services come first" "Services (CPU): configuration and alerts" "$(cat "$_out")"
assert_contains "starting with Gitea" "1) gitea" "$(cat "$_out")"
INSTALL_TARGETS=""; INSTALL_GITEA=true; INSTALL_MATTERMOST=true
prompt_target_selection > /dev/null 2>&1 <<< $'\n'
assert_eq "INSTALL_GITEA / INSTALL_MATTERMOST pre-select the services" "gitea mattermost" "$TARGETS"
NONINTERACTIVE=true; INSTALL_TARGETS=""
assert_fail "and are refused unattended, like any target" prompt_target_selection
NONINTERACTIVE=false; INSTALL_GITEA=false; INSTALL_MATTERMOST=false
INSTALL_TARGETS=""
prompt_target_selection > /dev/null 2>&1 <<< $'\n'
assert_eq "Enter selects none" "" "$TARGETS"
rm "$TARGETS_DIR/maya/provision-lxc.sh"
INSTALL_TARGETS=""
assert_fail "a target missing from the checkout stops the install" prompt_target_selection <<< $'maya\n'
assert_contains "naming the full checkout" "full repository checkout" \
  "$(prompt_target_selection 2>&1 <<< $'maya\n')"
cp "$TARGETS_DIR/ollama/provision-lxc.sh" "$TARGETS_DIR/maya/provision-lxc.sh"
INSTALL_TARGETS=""; TARGETS=""

describe valid_target_ct_id
ct_id_free() { [[ $1 != 905 ]]; }
TARGET_RESERVED_IDS="910 920"
assert_ok "a free ID" valid_target_ct_id 921
assert_fail "the router's or an earlier target's ID" valid_target_ct_id 920
assert_fail "an ID in use on the cluster" valid_target_ct_id 905
assert_fail "below 100" valid_target_ct_id 99

describe valid_router_ct_id
ct_id_free() { [[ $1 != 905 ]]; }
assert_ok   "a free ID" valid_router_ct_id 921
assert_ok   "the top of the Proxmox range" valid_router_ct_id 999999999
assert_fail "an ID in use on the cluster" valid_router_ct_id 905
assert_contains "says it is taken" "already in use" "$(valid_router_ct_id 905 2>&1)"
assert_fail "below 100" valid_router_ct_id 99
assert_fail "a leading zero" valid_router_ct_id 0123
assert_fail "not a number" valid_router_ct_id abc
assert_fail "blank" valid_router_ct_id ""
assert_fail "above the Proxmox range" valid_router_ct_id 1000000000

describe prompt_router_ct_id
# The cluster stubs are gone by now: a pvesh function offers 910 as the next ID.
pvesh() { if [[ $* == *--vmid* ]]; then [[ ${*##* } != 905 ]]; else echo 910; fi; }
_saved_ct_id="$CT_ID"
CT_ID=""
prompt_router_ct_id >/dev/null 2>&1 <<< $'\n'
assert_eq "Enter takes the cluster's next free ID" 910 "$CT_ID"
CT_ID=""
prompt_router_ct_id >/dev/null 2>&1 <<< $'950\n'
assert_eq "or a typed one" 950 "$CT_ID"
CT_ID=""
_out="$(prompt_router_ct_id 2>&1 <<< $'905\nabc\n951\n'; echo "id=$CT_ID")"
assert_contains "a taken ID is refused and re-asked" "already in use" "$_out"
assert_contains "so is a malformed one" "Not a valid value: 'abc'" "$_out"
assert_contains "until a free ID is given" "id=951" "$_out"
CT_ID=960
prompt_router_ct_id >/dev/null 2>&1 <<< $'\n'
assert_eq "a CT_ID preset is the default Enter takes" 960 "$CT_ID"
CT_ID=905
prompt_router_ct_id >/dev/null 2>&1 <<< $'\n952\n'
assert_eq "a taken preset is re-asked, not accepted" 952 "$CT_ID"
CT_ID=905
assert_fail "input running out on a taken ID gives up" prompt_router_ct_id <<< $'905\n'
CT_ID=""
assert_fail "no router ID and no next free ID stops the install" \
  env PATH="$NO_PVESH_BIN" bash -c 'source "$1"; NONINTERACTIVE=false; CT_ID=""; prompt_router_ct_id' _ "$FUNCS" <<< $'\n'
NONINTERACTIVE=true
CT_ID=""
prompt_router_ct_id >/dev/null 2>&1
assert_eq "NONINTERACTIVE takes the next free ID" 910 "$CT_ID"
CT_ID=""
assert_fail "NONINTERACTIVE without a next free ID needs a preset" \
  env PATH="$NO_PVESH_BIN" bash -c 'source "$1"; NONINTERACTIVE=true; CT_ID=""; prompt_router_ct_id' _ "$FUNCS"
CT_ID=940
assert_ok "NONINTERACTIVE accepts an explicit free ID" prompt_router_ct_id
CT_ID=905
assert_fail "NONINTERACTIVE refuses a taken preset" prompt_router_ct_id
NONINTERACTIVE=false
# shellcheck source=/dev/null
source "$FUNCS"   # restore the real ct_id_free
CT_ID="$_saved_ct_id"; unset _saved_ct_id _out
unset -f pvesh

describe valid_target_ip
TARGET_RESERVED_IPS="192.0.2.80 192.0.2.90"
assert_ok "a new static address" valid_target_ip 192.0.2.91/24
assert_fail "the router's address" valid_target_ip 192.0.2.80/24
assert_fail "an earlier target's address" valid_target_ip 192.0.2.90/24
assert_fail "DHCP (the router needs a fixed address)" valid_target_ip dhcp
assert_fail "no prefix" valid_target_ip 192.0.2.91

describe valid_target_template
assert_ok "Ubuntu 24.04" valid_target_template local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
assert_ok "Ubuntu 26.04" valid_target_template local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
assert_ok "Debian 12" valid_target_template nfs:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst
assert_ok "Debian 13" valid_target_template nfs:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
assert_fail "another distro" valid_target_template local:vztmpl/alpine-3.20-default_20240908_amd64.tar.xz
assert_fail "no storage" valid_target_template vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst

describe valid_strata_template
assert_ok "Strata on Debian 13" valid_strata_template local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
assert_ok "Strata on Ubuntu 24.04" valid_strata_template local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
assert_fail "not Ubuntu 26.04 (upstream setup lacks it)" valid_strata_template local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
assert_fail "nor another distro" valid_strata_template local:vztmpl/alpine-3.20-default_20240908_amd64.tar.xz

describe valid_avalon_template
assert_ok "Avalon on Ubuntu 24.04" valid_avalon_template local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
assert_ok "Avalon on Ubuntu 22.04" valid_avalon_template local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
assert_fail "not Debian 13 (ROCm supports Radeon cards on Ubuntu only)" valid_avalon_template local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
assert_fail "not Ubuntu 26.04 (no ROCm 7.2.4 repository)" valid_avalon_template local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
assert_eq "CUDA accepts Debian 13" 0 "$(AVALON_BACKEND=cuda valid_avalon_template local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst; echo $?)"
assert_eq "CUDA accepts Ubuntu 26.04" 0 "$(AVALON_BACKEND=cuda valid_avalon_template local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst; echo $?)"
assert_eq "an automatically selected NVIDIA card accepts Debian 13" 0 "$(GPU_RESULT_AVALON='ready|nvidia||0|' valid_avalon_template local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst; echo $?)"
assert_eq "NVIDIA GPU_DEVICES accepts Debian 13" 0 "$(GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm' valid_avalon_template local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst; echo $?)"
assert_fail "nor another distro" valid_avalon_template local:vztmpl/alpine-3.20-default_20240908_amd64.tar.xz

describe valid_kindi_template
assert_ok "Kindi on Debian 13" valid_kindi_template local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
assert_ok "Kindi on Ubuntu 24.04" valid_kindi_template local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
assert_ok "Kindi on Debian 12" valid_kindi_template local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
assert_fail "not Ubuntu 26.04 (the CUDA 10.2 runfile is not checked there)" valid_kindi_template local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
assert_fail "nor another distro" valid_kindi_template local:vztmpl/alpine-3.20-default_20240908_amd64.tar.xz

describe host_gpu_cuda_arch
HOST_GPU_CUDA_ARCH=120
assert_eq "the GPU step's result first" 120 "$(host_gpu_cuda_arch)"
HOST_GPU_CUDA_ARCH=""
nvidia-smi() { echo "${FAKE_CAP:-8.9}"; }
assert_eq "else nvidia-smi's compute capability" 89 "$(host_gpu_cuda_arch)"
assert_eq "an unreadable one is empty" "" "$(FAKE_CAP='[N/A]' host_gpu_cuda_arch)"
unset -f nvidia-smi

describe gpu_target_template_order
assert_eq "Strata: Debian 13 first, never Ubuntu 26.04" "debian-13 ubuntu-24.04 ubuntu-22.04 debian-12" "$(gpu_target_template_order strata)"
assert_eq "Xolotl: Debian 13, then Ubuntu 26.04" "debian-13 ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 debian-12" "$(gpu_target_template_order xolotl)"
assert_eq "Maya on an RTX card: Debian 13 first" "debian-13 ubuntu-26.04 ubuntu-24.04 ubuntu-22.04 debian-12" "$(HOST_GPU_CUDA_ARCH=89 gpu_target_template_order maya)"
assert_eq "Maya on a V100: only CUDA 12 distributions" "ubuntu-24.04 ubuntu-22.04 debian-12" "$(HOST_GPU_CUDA_ARCH=70 gpu_target_template_order maya)"
assert_eq "Avalon: the Ubuntu releases ROCm supports" "ubuntu-24.04 ubuntu-22.04" "$(gpu_target_template_order avalon)"
assert_eq "Kindi: Strata's releases, Debian 13 first" "debian-13 ubuntu-24.04 ubuntu-22.04 debian-12" "$(gpu_target_template_order kindi)"

describe target_cuda_env
assert_eq "Basalt on Ubuntu 26.04 uses CUDA 13.3" CUDA_VERSION=13.3 "$(target_cuda_env basalt local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)"
assert_eq "Maya on Debian 13 uses CUDA 13.1" MAYA_CUDA_VERSION=13.1 "$(target_cuda_env maya local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst)"
assert_eq "Xolotl on Ubuntu 26.04 uses CUDA 13.3" XOLOTL_CUDA_VERSION=13.3 "$(target_cuda_env xolotl local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)"
assert_eq "Ubuntu 24.04 keeps its CUDA default" "" "$(target_cuda_env basalt local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
assert_eq "Avalon keeps its CUDA default on Ubuntu 24.04" "" "$(target_cuda_env avalon local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
assert_eq "Avalon on Debian 13 uses CUDA 13.1" AVALON_CUDA_VERSION=13.1 "$(target_cuda_env avalon local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst)"
assert_eq "Avalon on Ubuntu 26.04 uses CUDA 13.3" AVALON_CUDA_VERSION=13.3 "$(target_cuda_env avalon local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)"
MAYA_CUDA_VERSION=13.4
assert_eq "an explicit CUDA choice is kept" "" "$(target_cuda_env maya local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)"
unset MAYA_CUDA_VERSION

describe default_gpu_target_template
template_storages() { printf '%s\n' local nfs; }
_pveam_list_local='NAME SIZE
local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst 120MB'
_pveam_list_nfs='NAME SIZE
nfs:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst 140MB
nfs:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst 140MB'
pveam() {
  echo "pveam $*" >> "$MOCK_LOG"
  case "$1 $2" in
    "list local") printf '%s\n' "$_pveam_list_local" ;;
    "list nfs") printf '%s\n' "$_pveam_list_nfs" ;;
    "available --section") printf '%s\n' "system ubuntu-22.04-standard_22.04-1_amd64.tar.zst" \
                                       "system ubuntu-24.04-standard_24.04-2_amd64.tar.zst" \
                                       "system debian-13-standard_13.1-2_amd64.tar.zst" \
                                       "system ubuntu-26.04-standard_26.04-1_amd64.tar.zst" ;;
    download*) return "${FAKE_DOWNLOAD_RC:-0}" ;;
  esac
}
assert_eq "without Debian 13 or Ubuntu 26.04: the newest downloaded Ubuntu 24.04, on any storage" \
  nfs:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$(default_gpu_target_template xolotl)"
_pveam_list_local='NAME SIZE
local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst 120MB
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB
local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst 150MB'
assert_eq "Debian 13 is preferred" local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$(default_gpu_target_template xolotl)"
assert_eq "Maya on a V100 keeps a CUDA 12 distribution" \
  nfs:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$(HOST_GPU_CUDA_ARCH=70 default_gpu_target_template maya)"
_pveam_list_local='NAME SIZE
local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst 120MB
local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst 150MB'
assert_eq "then Ubuntu 26.04" local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst "$(default_gpu_target_template basalt)"
assert_eq "but not for Strata" nfs:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$(default_gpu_target_template strata)"
_pveam_list_local='NAME SIZE
local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst 120MB'
_pveam_list_nfs='NAME SIZE'
assert_eq "then Debian 12" local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst "$(default_gpu_target_template xolotl)"
_pveam_list_local='NAME SIZE'; TEMPLATE_STORAGE=local
assert_eq "else a Debian 13 one to download into TEMPLATE_STORAGE" \
  local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$(default_gpu_target_template xolotl)"
assert_eq "an Ubuntu 24.04 one for Maya on a V100" \
  local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$(HOST_GPU_CUDA_ARCH=70 default_gpu_target_template maya)"

describe show_strata_template_alternatives
_pveam_list_local='NAME SIZE
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB
local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst 150MB'
_pveam_list_nfs='NAME SIZE
nfs:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst 140MB'
out="$(show_strata_template_alternatives local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst)"
assert_contains "lists a compatible alternate on another storage" \
  nfs:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$out"
assert_not_contains "does not list the selected default" \
  local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$out"
assert_not_contains "does not list Ubuntu 26.04 for Strata" \
  local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst "$out"

describe prompt_template_storage
_saved_storage_candidates="$(declare -f storage_candidates)"
storage_candidates() { printf 'nfs\tnfs\t10000000\nlocal\tdir\t10000000\n'; }
TEMPLATE_STORAGE=local; TEMPLATE_STORAGE_EXPLICIT=""
_out="$(mktemp)"
prompt_template_storage > "$_out" <<< ''
assert_eq "local is the default even when Proxmox lists NFS first" local "$TEMPLATE_STORAGE"
assert_contains "shows both template storages" 'nfs (nfs)' "$(cat "$_out")"
TEMPLATE_STORAGE=local
prompt_template_storage > "$_out" <<< '1'
assert_eq "the user can select the NFS alternative" nfs "$TEMPLATE_STORAGE"
eval "$_saved_storage_candidates"
rm -f "$_out"
TEMPLATE_STORAGE_EXPLICIT=""

describe select_router_template
_pveam_list_local='NAME SIZE'
_pveam_list_nfs='NAME SIZE
nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB'
TEMPLATE_STORAGE=local; TEMPLATE_NAME=""; TEMPLATE_REF=""
select_router_template > /dev/null
assert_eq "records the storage of the router's existing template" nfs "$TEMPLATE_STORAGE"
assert_eq "keeps that router template" \
  nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$TEMPLATE_REF"
assert_eq "an existing template does not need a download" "" "$DOWNLOAD_TEMPLATE_NAME"
_pveam_list_nfs='NAME SIZE'
storage_supports_vztmpl() { [[ $1 == local ]]; }
storage_free_gib() { echo 10; }
TEMPLATE_STORAGE=local; TEMPLATE_REF=""
select_router_template > /dev/null
assert_eq "a missing router template will be downloaded into its chosen storage" \
  local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$TEMPLATE_REF"
assert_eq "records the needed download" debian-13-standard_13.1-2_amd64.tar.zst "$DOWNLOAD_TEMPLATE_NAME"
_pveam_list_local='NAME SIZE
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB'
_pveam_list_nfs='NAME SIZE
nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB'
TEMPLATE_STORAGE=nfs; TEMPLATE_REF=""
select_router_template > /dev/null <<< 'local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst'
assert_eq "a typed local reference wins over the NFS default" \
  local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$TEMPLATE_REF"
assert_eq "the router uses the typed template storage" local "$TEMPLATE_STORAGE"
TEMPLATE_REF=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
TEMPLATE_STORAGE=nfs; NONINTERACTIVE=true
select_router_template > /dev/null
assert_eq "an explicit TEMPLATE_REF wins unattended" local "$TEMPLATE_STORAGE"
NONINTERACTIVE=false
_pveam_list_local='NAME SIZE'
TEMPLATE_STORAGE=local; TEMPLATE_STORAGE_EXPLICIT=1; TEMPLATE_REF=""
select_router_template > /dev/null
assert_eq "an explicit TEMPLATE_STORAGE does not fall back to NFS" \
  local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$TEMPLATE_REF"
assert_eq "it downloads to the requested storage" \
  debian-13-standard_13.1-2_amd64.tar.zst "$DOWNLOAD_TEMPLATE_NAME"
TEMPLATE_STORAGE_EXPLICIT=""

describe router_template_storages
TEMPLATE_STORAGE=local; TEMPLATE_STORAGE_EXPLICIT=1
assert_eq "an explicit TEMPLATE_STORAGE is the only one searched" local "$(router_template_storages)"
TEMPLATE_STORAGE_EXPLICIT=""
assert_eq "otherwise every template storage" "$(printf 'local\nnfs')" "$(router_template_storages)"

describe valid_router_template_ref
_saved_list_local=$_pveam_list_local; _saved_list_nfs=$_pveam_list_nfs
_saved_supports="$(declare -f storage_supports_vztmpl)"; _saved_free="$(declare -f storage_free_gib)"
_saved_min_gib=${TEMPLATE_MIN_GIB:-}
TEMPLATE_MIN_GIB=2
_pveam_list_local='NAME SIZE
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB'
_pveam_list_nfs='NAME SIZE'
storage_supports_vztmpl() { [[ $1 == local || $1 == nfs ]]; }
storage_free_gib() { echo "${FAKE_FREE_GIB:-10}"; }
assert_ok "a downloaded Debian 13 template" \
  valid_router_template_ref local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
assert_ok "one pveam can download into a template storage" \
  valid_router_template_ref nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
assert_fail "another distribution" \
  valid_router_template_ref local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
assert_fail "a bare template name" valid_router_template_ref debian-13-standard_13.1-2_amd64.tar.zst
assert_fail "a path in the name" valid_router_template_ref 'local:vztmpl/../debian-13-standard_13.1-2_amd64.tar.zst'
assert_fail "a non-amd64 template" valid_router_template_ref local:vztmpl/debian-13-standard_13.1-2_arm64.tar.zst
_out="$(valid_router_template_ref nfs:vztmpl/debian-13-standard_13.9-9_amd64.tar.zst 2>&1)"; _rc=$?
assert_ne "neither downloaded nor downloadable" 0 "$_rc"
assert_contains "and says so" "neither downloaded nor available to download" "$_out"
storage_supports_vztmpl() { [[ $1 == local ]]; }
_out="$(valid_router_template_ref nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 2>&1)"; _rc=$?
assert_ne "a download into a storage without vztmpl content" 0 "$_rc"
assert_contains "names the storage" "Storage 'nfs' cannot hold LXC templates" "$_out"
storage_supports_vztmpl() { [[ $1 == local || $1 == nfs ]]; }
_out="$(FAKE_FREE_GIB=1 valid_router_template_ref nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 2>&1)"; _rc=$?
assert_ne "a download into a storage without the space" 0 "$_rc"
assert_contains "gives the space needed" "only 1 GiB free; 2 GiB is needed" "$_out"
FAKE_FREE_GIB=1 assert_ok "a downloaded template needs no free space" \
  valid_router_template_ref local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
unset _out _rc

describe show_router_template_alternatives
_pveam_list_local='NAME SIZE
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB
local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst 125MB
local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst 140MB'
_pveam_list_nfs='NAME SIZE
nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB'
out="$(show_router_template_alternatives local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst)"
assert_contains "has a heading" "Other downloaded Debian 13 templates:" "$out"
assert_contains "lists the same release on another storage" \
  nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst "$out"
assert_contains "and an older release" local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst "$out"
assert_not_contains "but not the selected template" \
  "    local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst" "$out"
assert_not_contains "nor another distribution" ubuntu-24.04 "$out"
_pveam_list_local='NAME SIZE
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst 130MB'
_pveam_list_nfs='NAME SIZE'
assert_eq "nothing, not even the heading, without an alternative" "" \
  "$(show_router_template_alternatives local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst)"
_pveam_list_local=$_saved_list_local; _pveam_list_nfs=$_saved_list_nfs
eval "$_saved_supports"; eval "$_saved_free"
TEMPLATE_MIN_GIB=$_saved_min_gib
unset _saved_list_local _saved_list_nfs _saved_supports _saved_free _saved_min_gib

describe ensure_target_template
_pveam_list_local='NAME SIZE
local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst 140MB'
mock_reset_log
assert_ok "a downloaded template is used" ensure_target_template local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
assert_not_contains "without downloading it" "pveam download" "$(mock_calls)"
assert_ok "a missing one is downloaded" ensure_target_template local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst >/dev/null
assert_contains "into its storage" "pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst" "$(mock_calls)"
FAKE_DOWNLOAD_RC=1
assert_fail "a failed download fails" ensure_target_template local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
unset FAKE_DOWNLOAD_RC

describe prompt_target_settings
default_gpu_target_template() { echo local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst; }
TEMPLATE_REF=nfs:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
CT_ID=910; IP_CIDR=192.0.2.80/24; GATEWAY=192.0.2.1; BRIDGE=vmbr0; STORAGE=router-store
TARGETS="ollama strata"
unset OLLAMA_CT_ID OLLAMA_IP_CIDR OLLAMA_STORAGE STRATA_CT_ID STRATA_IP_CIDR STRATA_STORAGE STRATA_TEMPLATE
_out="$(mktemp)"
prompt_target_settings > "$_out" 2>&1 <<< $'911\n192.0.2.80/24\n192.0.2.90/24\n\n912\n192.0.2.90/24\n192.0.2.91/24\ngpu-store\n\n'
assert_eq "the first target takes the entered ID" 911 "$OLLAMA_CT_ID"
assert_eq "the next target takes its own entered ID" 912 "$STRATA_CT_ID"
assert_eq "the router's address is refused, the next answer kept" 192.0.2.90/24 "$OLLAMA_IP_CIDR"
assert_eq "an address already taken is refused" 192.0.2.91/24 "$STRATA_IP_CIDR"
assert_eq "storage defaults to the router's" router-store "$OLLAMA_STORAGE"
assert_eq "or takes the answer" gpu-store "$STRATA_STORAGE"
assert_eq "Strata defaults to the router's selected template location" "$TEMPLATE_REF" "$STRATA_TEMPLATE"
assert_eq "Ollama is not given one (the community script chooses)" "" "${OLLAMA_TEMPLATE:-}"
pvesh() { if [[ $* == *--vmid* ]]; then [[ ${*##* } != 905 ]]; else echo 910; fi; }
TARGETS="ollama strata"; unset OLLAMA_CT_ID STRATA_CT_ID
OLLAMA_IP_CIDR=192.0.2.90/24; STRATA_IP_CIDR=192.0.2.91/24; STRATA_TEMPLATE="$TEMPLATE_REF"
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\n\n\n\n\n'
assert_eq "an unprovided target ID defaults to the next free one" 911 "$OLLAMA_CT_ID"
assert_eq "the next target skips the IDs this install already took" 912 "$STRATA_CT_ID"
TARGETS=ollama; unset OLLAMA_CT_ID
assert_fail "without a next free ID a target ID must be given" \
  env PATH="$NO_PVESH_BIN" bash -c 'source "$1"; TARGETS=ollama; CT_ID=910; prompt_target_settings' _ "$FUNCS" <<< $'\n'
unset -f pvesh; STRATA_CT_ID=912; STRATA_IP_CIDR=192.0.2.91/24
OLLAMA_CT_ID=911
TARGETS=strata; STRATA_TEMPLATE=""
_pveam_list_local='NAME SIZE
local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst 140MB'
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\nlocal:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst\n'
assert_contains "offers the alternate template at the prompt" \
  local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$(cat "$_out")"
assert_eq "accepts the alternate template location" \
  local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$STRATA_TEMPLATE"
TARGETS=avalon; AVALON_CT_ID=932; AVALON_IP_CIDR=192.0.2.94/24; AVALON_STORAGE=router-store; AVALON_TEMPLATE=""
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\nlocal:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst\n\n'
assert_contains "a Debian template is refused for Avalon" "Not a valid value: 'local:vztmpl/debian-13" "$(cat "$_out")"
assert_eq "Avalon takes the Ubuntu default" local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$AVALON_TEMPLATE"
unset AVALON_CT_ID AVALON_IP_CIDR AVALON_STORAGE AVALON_TEMPLATE
OLLAMA_CT_ID=930; OLLAMA_IP_CIDR=10.9.9.9/24; TARGETS=ollama
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\n'
assert_eq "a preset CT ID is the default" 930 "$OLLAMA_CT_ID"
assert_contains "an address outside the gateway's subnet is flagged" "outside 10.9.9.9/24" "$(cat "$_out")"
TARGETS=""
assert_ok "nothing selected, nothing asked" prompt_target_settings
TARGETS=comfyui
COMFYUI_CT_ID=931; COMFYUI_IP_CIDR=192.0.2.98/24; COMFYUI_STORAGE=router-store
unset COMFYUI_IMAGE_VARIANT
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\n\n'
assert_eq "ComfyUI defaults to the distilled 4B workflow" klein-4b "$COMFYUI_IMAGE_VARIANT"
COMFYUI_IMAGE_VARIANT=klein-9b
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\n\n'
assert_eq "a preset 9B workflow is kept" klein-9b "$COMFYUI_IMAGE_VARIANT"
assert_fail "other model families need their own workflow" valid_comfyui_variant sdxl
unset COMFYUI_IMAGE_VARIANT
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\nsdxl\nklein-4b\n'
assert_contains "invalid image model is re-prompted" "Not a valid value: 'sdxl'" "$(cat "$_out")"
assert_eq "the corrected model is kept" klein-4b "$COMFYUI_IMAGE_VARIANT"
assert_eq "4B needs no Hugging Face token" "" "${TARGET_HF_TOKEN:-}"
unset COMFYUI_IMAGE_VARIANT; TARGET_HF_TOKEN=""
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\nklein-9b\nnot-a-token\nhf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5\n'
assert_eq "9B asks for the Hugging Face token of its gated weights" "hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5" "$TARGET_HF_TOKEN"
assert_contains "and says where to accept the license" "huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8" "$(cat "$_out")"
assert_contains "a malformed token is asked for again" "not a Hugging Face access token" "$(cat "$_out")"
assert_not_contains "the token is not echoed" "hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5" "$(cat "$_out")"
unset COMFYUI_IMAGE_VARIANT; TARGET_HF_TOKEN=""
assert_fail "EOF instead of a token stops the prompts" prompt_target_settings <<< $'\n\n\nklein-9b\n'
TARGET_HF_TOKEN="hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5"; unset COMFYUI_IMAGE_VARIANT
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\nklein-9b\n'
assert_not_contains "a preset HF_TOKEN is not asked for" "Hugging Face token (hf_" "$(cat "$_out")"
TARGET_HF_TOKEN=""; unset COMFYUI_IMAGE_VARIANT
TARGETS=honcho
HONCHO_CT_ID=934; HONCHO_IP_CIDR=192.0.2.101/24; HONCHO_STORAGE=router-store
unset HONCHO_MODEL
prompt_target_settings > "$_out" 2>&1 <<< $'\n\n\nlarge\n'
assert_eq "Honcho asks for its router chat model or tier" large "$HONCHO_MODEL"
assert_contains "and no embedding model: it runs its own" "Qwen3-Embedding-0.6B runs on llama.cpp in Honcho's CT" "$(cat "$_out")"
assert_not_contains "(no embedding question)" "Embedding" "$(grep -v 'Qwen3-Embedding' "$_out")"
HONCHO_MODEL=fast
TARGETS=""

describe valid_honcho_context_tokens
assert_ok "blank keeps Honcho's budgets" valid_honcho_context_tokens ""
assert_ok "a 32k window" valid_honcho_context_tokens 32768
assert_ok "the smallest" valid_honcho_context_tokens 8192
assert_ok "the largest" valid_honcho_context_tokens 1048576
assert_fail "too small to hold a request" valid_honcho_context_tokens 4096
assert_fail "too large" valid_honcho_context_tokens 2097152
assert_fail "a unit suffix" valid_honcho_context_tokens 32k
assert_fail "a leading zero" valid_honcho_context_tokens 032768

describe valid_dsh_context_tokens
assert_ok "a 32k DeepSeek window" valid_dsh_context_tokens 32768
assert_ok "DeepSeek minimum" valid_dsh_context_tokens 16384
assert_ok "DeepSeek maximum" valid_dsh_context_tokens 1048576
assert_fail "DeepSeek refuses an 8k window" valid_dsh_context_tokens 8192
assert_fail "DeepSeek refuses excessive context" valid_dsh_context_tokens 1048577
assert_fail "DeepSeek refuses a unit suffix" valid_dsh_context_tokens 32k
assert_fail "DeepSeek refuses a leading zero" valid_dsh_context_tokens 032768

describe valid_honcho_model
assert_ok "a router tier" valid_honcho_model fast
assert_ok "an Ollama tag with a namespace" valid_honcho_model "hf.co/nomic-ai/nomic-embed-text:v1.5"
assert_fail "empty" valid_honcho_model ""
assert_fail "a leading dash" valid_honcho_model -fast
assert_fail "a space" valid_honcho_model "nomic embed"

describe target_menu_group
assert_eq "services" 'Services (CPU): configuration and alerts; created before OSR.' "$(target_menu_group gitea)"
assert_eq "CPU model servers" 'Model servers (CPU or optional GPU):' "$(target_menu_group airllm)"
assert_eq "GPU model servers" 'Model servers (GPU required by default):' "$(target_menu_group llamacpp)"
assert_eq "Honcho alone" 'Memory infrastructure (CPU): created before agents.' "$(target_menu_group honcho)"
assert_eq "the agents" "$(target_menu_group hermes)" "$(target_menu_group openclaw)"
assert_eq "DeepSeek Harness is grouped with agents" "$(target_menu_group hermes)" "$(target_menu_group deepseek-harness)"
assert_eq "OpenCode is grouped with agents" "$(target_menu_group hermes)" "$(target_menu_group opencode)"
assert_contains "Open Terminal's group" "Open WebUI tools" "$(target_menu_group open-terminal)"
assert_contains "ComfyUI's group" "Image generation" "$(target_menu_group comfyui)"
_groups=""
while IFS='|' read -r _name _; do _groups+="$(target_menu_group "$_name")"$'\n'; done < <(target_table)
assert_eq "every target has a group, and each group is one run of the menu" 7 \
  "$(printf '%s' "$_groups" | uniq | grep -c .)"
assert_eq "no target falls outside a group" 0 "$(printf '%s' "$_groups" | grep -c '^$')"
unset _groups _name

describe valid_comfyui_variant
assert_ok "klein-4b" valid_comfyui_variant klein-4b
assert_ok "klein-9b" valid_comfyui_variant klein-9b
assert_fail "anything else" valid_comfyui_variant klein

describe valid_hf_token
assert_ok "an access token" valid_hf_token "hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5"
assert_fail "a short one" valid_hf_token hf_abc
assert_fail "no hf_ prefix" valid_hf_token "$(printf 'x%.0s' {1..34})"

describe target_server_entry
OLLAMA_IP_CIDR=192.0.2.90/24; STRATA_IP_CIDR=192.0.2.91/24; MAYA_IP_CIDR=192.0.2.92/24
assert_eq "Ollama-kind targets on 11434" http://192.0.2.90:11434 "$(target_server_entry ollama)"
assert_eq "Strata with its kind prefix" strata+http://192.0.2.91:8080 "$(target_server_entry strata)"
MAYA_PORT=8123
assert_eq "honouring <NAME>_PORT" maya+http://192.0.2.92:8123 "$(target_server_entry maya)"
unset MAYA_PORT
assert_fail "a companion is not a server" target_server_entry hermes
XOLOTL_IP_CIDR=192.0.2.93/24
assert_eq "Xolotl with its kind prefix" xolotl+http://192.0.2.93:8080 "$(target_server_entry xolotl)"
unset XOLOTL_IP_CIDR
AVALON_IP_CIDR=192.0.2.94/24
assert_eq "Avalon with its kind prefix" avalon+http://192.0.2.94:8080 "$(target_server_entry avalon)"
unset AVALON_IP_CIDR
KINDI_IP_CIDR=192.0.2.95/24
assert_eq "Kindi on its own port" kindi+http://192.0.2.95:8093 "$(target_server_entry kindi)"
assert_eq "or KINDI_PORT" kindi+http://192.0.2.95:8100 "$(KINDI_PORT=8100 target_server_entry kindi)"
unset KINDI_IP_CIDR

describe target_default_port
assert_eq "Kindi keeps its own 8093" 8093 "$(target_default_port kindi)"
assert_eq "the other Strata-style targets 8080" 8080 "$(target_default_port avalon)"

describe preset_target_model_servers
MODEL_SERVER_COUNT=3; MODEL_SERVER_MAX=20
MODEL_SERVER_1=10.0.0.51; MODEL_SERVER_2=10.0.0.52; MODEL_SERVER_3=10.0.0.53
TARGETS="ollama strata hermes"
preset_target_model_servers > /dev/null
assert_eq "the targets come first" "http://192.0.2.90:11434 strata+http://192.0.2.91:8080" "$MODEL_SERVER_1 $MODEL_SERVER_2"
assert_eq "the configured defaults follow" "10.0.0.51 10.0.0.52 10.0.0.53" "$MODEL_SERVER_3 $MODEL_SERVER_4 $MODEL_SERVER_5"
assert_eq "the count covers the targets" 2 "$MODEL_SERVER_COUNT"
MODEL_SERVER_COUNT=3; MODEL_SERVER_1=10.0.0.51; TARGETS="hermes"
preset_target_model_servers > /dev/null
assert_eq "companions alone change nothing" "3 10.0.0.51" "$MODEL_SERVER_COUNT $MODEL_SERVER_1"
for _i in 1 2 3 4 5; do unset "MODEL_SERVER_$_i"; done; unset _i

describe target_context_var
assert_eq "Ollama's window is OLLAMA_CONTEXT_LENGTH" OLLAMA_CONTEXT_LENGTH "$(target_context_var ollama)"
assert_eq "llama.cpp's is per request, not CONTEXT_SIZE" LLAMACPP_CONTEXT "$(target_context_var llamacpp)"
assert_eq "the Strata-style targets use <NAME>_CONTEXT" "STRATA_CONTEXT BASALT_CONTEXT MAYA_CONTEXT XOLOTL_CONTEXT AVALON_CONTEXT KINDI_CONTEXT" \
  "$(for _n in strata basalt maya xolotl avalon kindi; do target_context_var "$_n"; done | paste -sd' ')"
assert_fail "AirLLM keeps its own small window" target_context_var airllm
assert_fail "an agent has none" target_context_var hermes

describe llamacpp_slots
assert_eq "one slot by default" 1 "$(unset PARALLEL_SLOTS; llamacpp_slots)"
assert_eq "PARALLEL_SLOTS when set" 3 "$(PARALLEL_SLOTS=3 llamacpp_slots)"
assert_eq "one for a value that is not a count" 1 "$(PARALLEL_SLOTS=0 llamacpp_slots)"

describe target_context_preset
assert_eq "no preset" "" "$(unset STRATA_CONTEXT; target_context_preset strata)"
assert_eq "a target's own preset" 32768 "$(STRATA_CONTEXT=32768 target_context_preset strata)"
assert_eq "llama.cpp's CONTEXT_SIZE is divided among its slots" 32768 \
  "$(unset LLAMACPP_CONTEXT; CONTEXT_SIZE=65536 PARALLEL_SLOTS=2 target_context_preset llamacpp)"
assert_eq "an explicit LLAMACPP_CONTEXT wins" 16384 \
  "$(LLAMACPP_CONTEXT=16384 CONTEXT_SIZE=65536 target_context_preset llamacpp)"
assert_fail "a target without a window" target_context_preset hermes

describe target_context_env
assert_eq "nothing before a window is chosen" "" "$(unset STRATA_CONTEXT; target_context_env strata)"
assert_eq "a model target gets its own variable" STRATA_CONTEXT=65536 "$(STRATA_CONTEXT=65536 target_context_env strata)"
assert_eq "Ollama's server default" OLLAMA_CONTEXT_LENGTH=32768 "$(OLLAMA_CONTEXT_LENGTH=32768 target_context_env ollama)"
assert_eq "llama.cpp gets the window times its slots" CONTEXT_SIZE=131072 \
  "$(LLAMACPP_CONTEXT=65536 PARALLEL_SLOTS=2 target_context_env llamacpp)"
assert_eq "Avalon's auto is passed as it is" AVALON_CONTEXT=auto "$(AVALON_CONTEXT=auto target_context_env avalon)"
assert_eq "so is Kindi's" KINDI_CONTEXT=auto "$(KINDI_CONTEXT=auto target_context_env kindi)"
assert_eq "an agent gets none" "" "$(target_context_env hermes)"

describe valid_target_context
assert_ok "the default" valid_target_context 65536
assert_ok "the smallest" valid_target_context 4096
assert_ok "the largest" valid_target_context 1048576
assert_fail "too small" valid_target_context 2048
assert_fail "too large" valid_target_context 2097152
assert_fail "a unit suffix" valid_target_context 64k
assert_fail "a leading zero" valid_target_context 065536
assert_fail "auto is Avalon's only" valid_target_context auto

describe valid_avalon_context
assert_ok "auto" valid_avalon_context auto
assert_ok "256k, its largest" valid_avalon_context 262144
assert_fail "more than llama-server takes" valid_avalon_context 524288
assert_fail "too small" valid_avalon_context 2048

describe avalon_auto_context
assert_eq "256k from 19 GB" 262144 "$(avalon_auto_context 24564)"
assert_eq "64k below" 65536 "$(avalon_auto_context 16376)"
assert_eq "64k when the card is not known" 65536 "$(avalon_auto_context '')"

describe valid_kindi_context
assert_ok "auto" valid_kindi_context auto
assert_ok "Kindi's 24k" valid_kindi_context 24576
assert_ok "256k" valid_kindi_context 262144
assert_fail "more than Kindi takes here" valid_kindi_context 524288
assert_fail "too small" valid_kindi_context 2048

describe kindi_auto_context
assert_eq "24k on a small card (a 1 GB K420)" 24576 "$(kindi_auto_context 980)"
assert_eq "64k from 7.5 GB" 65536 "$(kindi_auto_context 8192)"
assert_eq "24k on the CPU or an unknown card" 24576 "$(kindi_auto_context cpu)"

describe gpu_vram_mib
_sys="$(mktemp -d)"; mkdir -p "$_sys/0000:03:00.0"
echo 17163091968 > "$_sys/0000:03:00.0/mem_info_vram_total"
assert_eq "an AMD card's from amdgpu's sysfs file" 16368 "$(HOST_PCI_SYSFS="$_sys" gpu_vram_mib 03:00.0)"
nvidia-smi() { printf '00000000:01:00.0, 24564\n00000000:02:00.0, 12288\n'; }
assert_eq "an NVIDIA card's from nvidia-smi, by address" 12288 "$(HOST_PCI_SYSFS="$_sys" gpu_vram_mib 0000:02:00.0)"
assert_eq "GPU 0 without an address" 24564 "$(HOST_PCI_SYSFS="$_sys" gpu_vram_mib)"
assert_eq "nothing for a card nvidia-smi does not list" "" "$(HOST_PCI_SYSFS="$_sys" gpu_vram_mib 0000:09:00.0)"
nvidia-smi() { echo 'No devices were found'; return 6; }
assert_eq "nothing when the driver has no answer" "" "$(HOST_PCI_SYSFS="$_sys" gpu_vram_mib)"
unset -f nvidia-smi
assert_eq "nothing without nvidia-smi" "" "$(PATH=/nonexistent HOST_PCI_SYSFS="$_sys" gpu_vram_mib)"

describe target_vram
nvidia-smi() { printf '00000000:01:00.0, 24564\n'; }
HOST_GPU_CARDS=""
assert_eq "an NVIDIA-only target uses GPU 0" 24564 "$(HOST_PCI_SYSFS="$_sys" target_vram strata)"
assert_eq "Ollama with GPU=none runs on the CPU" cpu "$(GPU=none target_vram ollama)"
assert_eq "so does llama.cpp's CPU build" cpu "$(BACKEND=cpu target_vram llamacpp)"
assert_eq "a target given no card runs on the CPU" cpu "$(OLLAMA_GPU_CARD=none target_vram ollama)"
assert_eq "an optional target with no usable card too" cpu "$(OLLAMA_GPU_CARD='' target_vram ollama)"
assert_eq "a prompted target uses its chosen card" 16368 \
  "$(HOST_PCI_SYSFS="$_sys" AVALON_GPU_CARD=0000:03:00.0 target_vram avalon)"
assert_eq "unknown when a required card was not found" "" "$(LLAMACPP_GPU_CARD='' target_vram llamacpp)"
unset -f nvidia-smi
rm -rf "$_sys"; unset _sys

describe context_recommendation
TARGETS="strata"
assert_eq "65536 when the GPU fits more and nothing needs it" \
  "65536|the default; its 24564 MiB GPU fits about 131072" "$(context_recommendation strata 24564)"
assert_eq "the GPU's ceiling below that" \
  "32768|its 8192 MiB GPU fits about 32768; the default would use 65536" "$(context_recommendation strata 8192)"
TARGETS="strata honcho"
assert_eq "Honcho's full budgets raise it to 131072" \
  "131072|Honcho's full budgets; its 24564 MiB GPU fits about 131072" "$(context_recommendation strata 24564)"
assert_eq "Avalon by its auto rule" \
  "131072|Honcho's full budgets; its 20480 MiB GPU fits about 262144" "$(context_recommendation avalon 20480)"
assert_eq "Kindi by its own sizing" \
  "24576|its 980 MiB GPU fits about 24576; Honcho's full budgets would use 131072" "$(context_recommendation kindi 980)"
assert_eq "Xolotl's 128k needs its 24 GB card" \
  "65536|its 16384 MiB GPU fits about 65536; Honcho's full budgets would use 131072" "$(context_recommendation xolotl 16384)"
assert_eq "Ollama and llama.cpp are sized for full attention" \
  "65536|its 24564 MiB GPU fits about 65536; Honcho's full budgets would use 131072" "$(context_recommendation ollama 24564)"
assert_eq "a 48 GB card for 128k there" "131072" "$(context_recommendation llamacpp 49152 | cut -d'|' -f1)"
assert_eq "32768 on the CPU" \
  "32768|it runs on the CPU, where long prompts are slow; Honcho's full budgets would use 131072" "$(context_recommendation ollama cpu)"
TARGETS="maya"
assert_eq "the default when the card's memory is not known" \
  "65536|the default; its GPU's memory is not known yet" "$(context_recommendation maya '')"
TARGETS=""

describe context_agent_needs
TARGETS="ollama open-terminal"
assert_eq "nothing without agents" "" "$(context_agent_needs)"
TARGETS="ollama honcho hermes openclaw deepseek-harness opencode"
_out="$(context_agent_needs)"
assert_contains "OpenCode's" "OpenCode needs 32768 tokens or more" "$_out"
assert_contains "Hermes's minimum" "Hermes needs 64000 tokens or more" "$_out"
assert_contains "OpenClaw's" "OpenClaw needs 32768 tokens or more" "$_out"
assert_contains "Honcho's budgets" "131072 or more runs its full budgets" "$_out"
assert_contains "DeepSeek Harness's" "DeepSeek Harness needs 16384 tokens or more" "$_out"
TARGETS=""

describe context_shortfall
TARGETS="ollama hermes openclaw"
assert_eq "nothing when the window fits every agent" "" "$(context_shortfall 65536)"
assert_contains "Hermes skips a server under 64000" "Hermes will not use this server" "$(context_shortfall 32768)"
assert_not_contains "OpenClaw fits 32768" "OpenClaw" "$(context_shortfall 32768)"
assert_contains "but not 16384" "OpenClaw will not fit" "$(context_shortfall 16384)"
TARGETS="ollama opencode"
assert_eq "OpenCode fits 32768" "" "$(context_shortfall 32768)"
assert_contains "but not 16384" "OpenCode will not use this server" "$(context_shortfall 16384)"
TARGETS="ollama"
assert_eq "no agents, no notes" "" "$(context_shortfall 8192)"
TARGETS=""

describe prompt_target_contexts
nvidia-smi() { printf '00000000:01:00.0, 24564\n'; }
HOST_GPU_CARDS=""
unset STRATA_CONTEXT XOLOTL_CONTEXT HONCHO_CONTEXT_TOKENS DEEPSEEK_HARNESS_CONTEXT_WINDOW OLLAMA_CONTEXT_LENGTH
TARGETS="open-terminal comfyui"
assert_eq "no target with a window, nothing asked" "" "$(prompt_target_contexts)"
TARGETS="strata xolotl honcho hermes"
_out="$(mktemp)"
prompt_target_contexts > "$_out" 2>&1 <<< $'\n32768\n\n'
assert_eq "Enter keeps the 65536 default" 65536 "$STRATA_CONTEXT"
assert_eq "an answer is kept" 32768 "$XOLOTL_CONTEXT"
assert_contains "each target shows its recommendation" "strata: 131072 tokens recommended (Honcho's full budgets; its 24564 MiB GPU fits about 131072)." "$(cat "$_out")"
assert_contains "the selected agents' needs are listed" "Hermes needs 64000 tokens or more" "$(cat "$_out")"
assert_contains "a window too small for Hermes is flagged" "Hermes will not use this server" "$(cat "$_out")"
assert_eq "Honcho defaults to the smallest window chosen" 32768 "$HONCHO_CONTEXT_TOKENS"
assert_contains "and says which that is" "the smallest above is 32768" "$(cat "$_out")"
STRATA_CONTEXT=131072; HONCHO_CONTEXT_TOKENS=""; TARGETS="strata honcho"
prompt_target_contexts > "$_out" 2>&1 <<< $'\n\n'
assert_eq "a preset is the default" 131072 "$STRATA_CONTEXT"
assert_eq "an empty Honcho preset keeps Honcho's own budgets" "" "$HONCHO_CONTEXT_TOKENS"
unset STRATA_CONTEXT HONCHO_CONTEXT_TOKENS
TARGETS="avalon"; AVALON_GPU_CARD=""; unset AVALON_CONTEXT
prompt_target_contexts > "$_out" 2>&1 <<< $'100\nauto\n'
assert_contains "a value out of range is asked again" "Not a valid value: '100'" "$(cat "$_out")"
assert_eq "Avalon takes auto" auto "$AVALON_CONTEXT"
TARGETS="kindi hermes"; KINDI_GPU_CARD=none; unset KINDI_CONTEXT
prompt_target_contexts > "$_out" 2>&1 <<< $'\n'
assert_eq "Kindi defaults to auto" auto "$KINDI_CONTEXT"
assert_contains "and says what auto is" "auto: Kindi's own size for the card" "$(cat "$_out")"
assert_contains "Hermes is warned off a CPU Kindi" "Hermes will not use this server" "$(cat "$_out")"
unset KINDI_CONTEXT KINDI_GPU_CARD
TARGETS="llamacpp deepseek-harness"; LLAMACPP_GPU_CARD=0000:01:00.0; PARALLEL_SLOTS=2; unset LLAMACPP_CONTEXT CONTEXT_SIZE
prompt_target_contexts > "$_out" 2>&1 <<< $'\n\n'
assert_eq "llama.cpp asks per request" 65536 "$LLAMACPP_CONTEXT"
assert_contains "and says what CONTEXT_SIZE becomes" "CONTEXT_SIZE=131072" "$(cat "$_out")"
assert_eq "DeepSeek defaults to the smallest window too" 65536 "$DEEPSEEK_HARNESS_CONTEXT_WINDOW"
TARGETS="honcho"; unset HONCHO_CONTEXT_TOKENS
prompt_target_contexts > "$_out" 2>&1 <<< $'\n'
assert_eq "without model targets, Honcho defaults to 65536" 65536 "$HONCHO_CONTEXT_TOKENS"
TARGETS="strata"; STRATA_CONTEXT=64k
assert_fail "an invalid preset with no more input stops the prompts" prompt_target_contexts <<< $'\n'
unset -f nvidia-smi
unset STRATA_CONTEXT XOLOTL_CONTEXT HONCHO_CONTEXT_TOKENS DEEPSEEK_HARNESS_CONTEXT_WINDOW AVALON_CONTEXT AVALON_GPU_CARD \
  LLAMACPP_GPU_CARD LLAMACPP_CONTEXT PARALLEL_SLOTS
TARGETS=""

describe valid_strata_kv
assert_ok "int8" valid_strata_kv int8
assert_ok "k8v4" valid_strata_kv k8v4
assert_ok "q4_0" valid_strata_kv q4_0
assert_fail "an unknown cache" valid_strata_kv q8
assert_fail "empty" valid_strata_kv ""

describe strata_kv_recommendation
assert_eq "a 12 GB card takes k8v4" k8v4 "$(strata_kv_recommendation 12282 | cut -d'|' -f1)"
assert_eq "a 16 GB card takes k8v4" k8v4 "$(strata_kv_recommendation 16311 | cut -d'|' -f1)"
assert_eq "a 24 GB card takes int8" int8 "$(strata_kv_recommendation 24564 | cut -d'|' -f1)"
assert_eq "a 32 GB card takes int8" int8 "$(strata_kv_recommendation 32607 | cut -d'|' -f1)"
assert_eq "an unknown card takes Strata's default" "int8|its GPU's memory is not known yet; int8 is Strata's default" "$(strata_kv_recommendation "")"
assert_contains "the reason names the card's memory" "its 16311 MiB GPU" "$(strata_kv_recommendation 16311)"

describe prompt_strata_kv_cache
HOST_GPU_CARDS=""
unset STRATA_KV STRATA_CONTEXT
_out="$(mktemp)"
TARGETS="ollama hermes"
assert_eq "no Strata, nothing asked" "" "$(prompt_strata_kv_cache)"
TARGETS="strata hermes"
nvidia-smi() { printf '00000000:01:00.0, 16311\n'; }
prompt_strata_kv_cache > "$_out" 2>&1 <<< $'\n'
assert_eq "Enter takes the 16 GB card's suggestion" k8v4 "$STRATA_KV"
assert_contains "the suggestion names its card" "strata: k8v4 recommended (its 16311 MiB GPU" "$(cat "$_out")"
assert_contains "the sizes are explained" "Suggested: k8v4 for 12 GB and 16 GB cards, int8 for 24 GB and 32 GB cards." "$(cat "$_out")"
unset STRATA_KV
nvidia-smi() { printf '00000000:01:00.0, 24564\n'; }
prompt_strata_kv_cache > "$_out" 2>&1 <<< $'q8\n\n'
assert_contains "a bad answer is asked again" "Not a valid value: 'q8'" "$(cat "$_out")"
assert_eq "a 24 GB card defaults to int8" int8 "$STRATA_KV"
STRATA_KV=q4_0
prompt_strata_kv_cache > "$_out" 2>&1 <<< $'\n'
assert_eq "a preset is the default" q4_0 "$STRATA_KV"
unset STRATA_KV
NONINTERACTIVE=true
nvidia-smi() { printf '00000000:01:00.0, 12282\n'; }
prompt_strata_kv_cache > "$_out" 2>&1
assert_eq "unattended takes the suggestion" k8v4 "$STRATA_KV"
NONINTERACTIVE=false
unset STRATA_KV
STRATA_CONTEXT=8192
assert_eq "a window of 8192 or less asks nothing" "" "$(prompt_strata_kv_cache)"
assert_eq "and chooses nothing" "" "${STRATA_KV:-}"
unset -f nvidia-smi
unset STRATA_KV STRATA_CONTEXT
TARGETS=""

describe run_target_provisioner
CT_ID=910; GATEWAY=192.0.2.1; BRIDGE=vmbr2; NAMESERVER=""; OPENWEBUI_PORT=8080
TEMPLATE_REF=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
export CORES=8 ROOTFS_GB=32 STORAGE=router-store
OLLAMA_CT_ID=911; OLLAMA_STORAGE=t-store
STRATA_CT_ID=912; STRATA_STORAGE=gpu-store; STRATA_TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
LLAMACPP_CT_ID=913; LLAMACPP_IP_CIDR=192.0.2.93/24; LLAMACPP_STORAGE=t-store
HERMES_CT_ID=914; HERMES_IP_CIDR=192.0.2.94/24; HERMES_STORAGE=t-store
OPENCLAW_CT_ID=918; OPENCLAW_IP_CIDR=192.0.2.98/24; OPENCLAW_STORAGE=t-store
DEEPSEEK_HARNESS_CT_ID=921; DEEPSEEK_HARNESS_IP_CIDR=192.0.2.101/24; DEEPSEEK_HARNESS_STORAGE=t-store
OPENCODE_CT_ID=922; OPENCODE_IP_CIDR=192.0.2.102/24; OPENCODE_STORAGE=t-store
HONCHO_CT_ID=920; HONCHO_IP_CIDR=192.0.2.100/24; HONCHO_STORAGE=t-store
TARGET_ADMIN_TOKEN=owui-admin-secret; export EXPECT_TOKEN=owui-admin-secret
mock_reset_log
assert_ok "runs Ollama's provisioner" run_target_provisioner ollama
assert_eq "with its own CT, network and storage, and the guest install" \
  "provision ollama|911|192.0.2.90/24|192.0.2.1|t-store|vmbr2||||||no|--install-target" "$(mock_calls)"
mock_reset_log
PVE_INTERACTIVE=true run_target_provisioner ollama
assert_contains "the provisioner takes defaults and skips its own confirmation" "prompt-env true|false|" "$(cat "$MOCK_LOG.prompt")"
mock_reset_log
run_target_provisioner strata
assert_eq "a GPU target gets its template; the router's CORES/ROOTFS_GB and the token do not leak" \
  "provision strata|912|192.0.2.91/24|192.0.2.1|gpu-store|vmbr2|local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst|||||no|" "$(mock_calls)"
MAYA_CT_ID=918; MAYA_IP_CIDR=192.0.2.98/24; MAYA_STORAGE=gpu-store
MAYA_TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
mock_reset_log
run_target_provisioner maya
assert_contains "Ubuntu 26.04's CUDA version reaches Maya" "cuda-env |13.3|" "$(mock_calls)"
MAYA_TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
mock_reset_log
run_target_provisioner maya
assert_contains "Debian 13's CUDA version reaches Maya" "cuda-env |13.1|" "$(mock_calls)"
unset MAYA_CT_ID MAYA_IP_CIDR MAYA_STORAGE MAYA_TEMPLATE
AVALON_CT_ID=919; AVALON_IP_CIDR=192.0.2.99/24; AVALON_STORAGE=gpu-store
AVALON_TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
mock_reset_log
run_target_provisioner avalon
assert_contains "Debian 13's CUDA version reaches Avalon" "cuda-env |||13.1" "$(mock_calls)"
unset AVALON_CT_ID AVALON_IP_CIDR AVALON_STORAGE AVALON_TEMPLATE
KINDI_CT_ID=923; KINDI_IP_CIDR=192.0.2.103/24; KINDI_STORAGE=gpu-store
KINDI_TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst KINDI_CONTEXT=auto
GPU_RESULT_KINDI="ready|nvidia||1|0000:41:00.0"
mock_reset_log
run_target_provisioner kindi
assert_contains "Kindi gets its card, its backend and its context" \
  "kindi-env cuda|/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools|auto" "$(mock_calls)"
assert_not_contains "and no CUDA version of the template's repository" "cuda-env" "$(mock_calls)"
GPU_RESULT_KINDI="declined||||"
mock_reset_log
run_target_provisioner kindi
assert_contains "Kindi given no card runs on the CPU" "kindi-env cpu||auto" "$(mock_calls)"
unset KINDI_CT_ID KINDI_IP_CIDR KINDI_STORAGE KINDI_TEMPLATE KINDI_CONTEXT GPU_RESULT_KINDI
mock_reset_log
run_target_provisioner llamacpp
assert_contains "llama.cpp without a model only gets its CT" "|no|" "$(mock_calls)"
assert_not_contains "(no guest install)" "--install-target" "$(mock_calls)"
MODEL_ALIAS=qwen3:8b MODEL_PATH=/var/lib/llama-target/models/m.gguf run_target_provisioner llamacpp
assert_contains "with a model it installs" "|no|--install-target" "$(mock_calls)"
mock_reset_log
GPU_RESULT_LLAMACPP="ready|intel|/dev/dri/renderD129||0000:04:00.0"
GPU_RESULT_OLLAMA="ready|amd|/dev/dri/renderD128||0000:03:00.0"
GPU_RESULT_STRATA="ready|nvidia|||"
run_target_provisioner llamacpp
assert_contains "llama.cpp gets its card's Vulkan settings" "gpu-env |vulkan|/dev/dri/renderD129|" "$(mock_calls)"
mock_reset_log
run_target_provisioner ollama
assert_contains "Ollama gets its card's vendor and address" "gpu-env amd|||0000:03:00.0" "$(mock_calls)"
mock_reset_log
run_target_provisioner strata
assert_not_contains "Strata gets none of it" "gpu-env" "$(mock_calls)"
unset GPU_RESULT_LLAMACPP GPU_RESULT_OLLAMA GPU_RESULT_STRATA
mock_reset_log
run_target_provisioner hermes
assert_eq "a companion gets the router CT, the router's template and the token" \
  "provision hermes|914|192.0.2.94/24|192.0.2.1|t-store|vmbr2|local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst|||910|8080|match|" "$(mock_calls)"
assert_not_contains "the token is never an argument" "owui-admin-secret" "$(mock_calls)"
mock_reset_log
run_target_provisioner openclaw
assert_eq "OpenClaw too gets the router CT, the router's template and the token" \
  "provision openclaw|918|192.0.2.98/24|192.0.2.1|t-store|vmbr2|local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst|||910|8080|match|" "$(mock_calls)"
mock_reset_log
run_target_provisioner deepseek-harness
assert_eq "DeepSeek gets its own CT and router, and the token (its chat endpoint is registered in Open WebUI)" \
  "provision deepseek-harness|921|192.0.2.101/24|192.0.2.1|t-store|vmbr2|local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst|||910|8080|match|
context-env ||||unset|65536
dsh-env openwebui=default" "$(mock_calls)"
mock_reset_log
TARGET_WEBUI_READY=false run_target_provisioner deepseek-harness
assert_contains "without an admin key it is installed without Open WebUI" "dsh-env openwebui=false" "$(mock_calls)"
assert_contains "and gets no token" "|8080|no|" "$(mock_calls)"
mock_reset_log
DEEPSEEK_HARNESS_CONTEXT_WINDOW=32768 run_target_provisioner deepseek-harness
assert_contains "and the window chosen for it" "context-env ||||unset|32768" "$(mock_calls)"
mock_reset_log
run_target_provisioner opencode
assert_eq "OpenCode gets its own CT and router, its model and web UI range, and the token (Open WebUI)" \
  "provision opencode|922|192.0.2.102/24|192.0.2.1|t-store|vmbr2|local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst|||910|8080|match|
opencode-env auto|192.0.2.102/24" "$(mock_calls)"
mock_reset_log
OPENCODE_MODEL=fast API_ALLOW_CIDR=192.0.2.0/24 run_target_provisioner opencode
assert_contains "the chosen model, and the router's API range for the web UI" "opencode-env fast|192.0.2.0/24" "$(mock_calls)"
mock_reset_log
STRATA_CONTEXT=131072 run_target_provisioner strata
assert_contains "a model target gets its chosen window" "context-env ||131072||unset|" "$(mock_calls)"
assert_not_contains "no KV cache was chosen, none is passed" "strata-kv" "$(mock_calls)"
STRATA_KV=k8v4
mock_reset_log
run_target_provisioner strata
assert_contains "Strata gets the KV cache chosen for it" "strata-kv k8v4" "$(mock_calls)"
mock_reset_log
run_target_provisioner ollama
assert_not_contains "another target does not" "strata-kv" "$(mock_calls)"
unset STRATA_KV
mock_reset_log
OLLAMA_CONTEXT_LENGTH=32768 run_target_provisioner ollama
assert_contains "Ollama as its server default" "context-env 32768||||unset|" "$(mock_calls)"
mock_reset_log
LLAMACPP_CONTEXT=65536 PARALLEL_SLOTS=2 run_target_provisioner llamacpp
assert_contains "llama.cpp as CONTEXT_SIZE for all its slots" "context-env |131072|||unset|" "$(mock_calls)"

TARGETS="honcho hermes openclaw deepseek-harness opencode"; HONCHO_READY=false
mock_reset_log
run_target_provisioner honcho
assert_contains "Honcho reuses the router's Debian 13 template" \
  "provision honcho|920|192.0.2.100/24|192.0.2.1|t-store|vmbr2|local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst" "$(mock_calls)"
assert_contains "Honcho gets every selected agent address" \
  "honcho-env 192.0.2.94 192.0.2.98 192.0.2.101 192.0.2.102||" "$(mock_calls)"
assert_not_contains "and no embedding settings: it embeds in its own CT" "embedding-env" "$(mock_calls)"
assert_contains "Honcho gets the router IP entered earlier" "router-ip 192.0.2.80" "$(mock_calls)"
assert_contains "Honcho gets the selected router chat model" "chat-model fast" "$(mock_calls)"
assert_not_contains "an unset Honcho window is not passed (a first install sizes for 65536)" "context-env" "$(mock_calls)"
mock_reset_log
HONCHO_CONTEXT_TOKENS=32768 run_target_provisioner honcho
assert_contains "a chosen Honcho window is passed" "context-env ||||32768|" "$(mock_calls)"
mock_reset_log
HONCHO_CONTEXT_TOKENS='' run_target_provisioner honcho
assert_contains "and a blank one, for Honcho's own budgets" "context-env |||||" "$(mock_calls)"
HONCHO_READY=true
mock_reset_log
run_target_provisioner hermes
assert_contains "Hermes gets the provisioned Honcho endpoint and CT" \
  "honcho-env |http://192.0.2.100:8000|920" "$(mock_calls)"
mock_reset_log
run_target_provisioner openclaw
assert_contains "OpenClaw gets it too" "honcho-env |http://192.0.2.100:8000|920" "$(mock_calls)"
mock_reset_log
run_target_provisioner deepseek-harness
assert_contains "and DeepSeek Harness (for Honcho's MCP server)" "honcho-env |http://192.0.2.100:8000|920" "$(mock_calls)"
assert_contains "with the Open WebUI admin token for its chat endpoint" "|match|" "$(mock_calls)"
mock_reset_log
run_target_provisioner opencode
assert_contains "and OpenCode (for Honcho's OpenCode plugin)" "honcho-env |http://192.0.2.100:8000|920" "$(mock_calls)"
assert_not_contains "no Open Terminal before it is provisioned" "open-terminal-env" "$(mock_calls)"
OPEN_TERMINAL_CT_ID=919; OPEN_TERMINAL_IP_CIDR=192.0.2.99/24; OPEN_TERMINAL_READY=true
for _agent in hermes openclaw deepseek-harness opencode; do
  mock_reset_log
  run_target_provisioner "$_agent"
  assert_contains "$_agent gets the provisioned Open Terminal gateway and CT" \
    "open-terminal-env http://192.0.2.99:8000|919" "$(mock_calls)"
done
OPEN_TERMINAL_READY=false
COMFYUI_CT_ID=917; COMFYUI_IP_CIDR=192.0.2.97/24; COMFYUI_STORAGE=t-store
COMFYUI_COMMUNITY_SCRIPT_SHA256=def456
COMFYUI_IMAGE_VARIANT=klein-4b
mock_reset_log
run_target_provisioner comfyui
assert_not_contains "other companions do not get Honcho" "honcho-env" "$(mock_calls)"
HONCHO_READY=false; TARGETS=""
mock_reset_log
run_target_provisioner comfyui
assert_contains "ComfyUI gets the router CT and the token, and no template" \
  "provision comfyui|917|192.0.2.97/24|192.0.2.1|t-store|vmbr2||||910|8080|match|" "$(mock_calls)"
assert_contains "COMFYUI_COMMUNITY_SCRIPT_SHA256 pins its community script" "service-env |def456|" "$(mock_calls)"
assert_contains "the selected image workflow reaches the ComfyUI provisioner" "image-variant klein-4b" "$(mock_calls)"
TARGET_HF_TOKEN="hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5"; export EXPECT_HF_TOKEN="hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5"
mock_reset_log
run_target_provisioner comfyui
assert_not_contains "4B gets no Hugging Face token" "hf-token" "$(mock_calls)"
COMFYUI_IMAGE_VARIANT=klein-9b
mock_reset_log
run_target_provisioner comfyui
assert_contains "9B gets the Hugging Face token, in its environment" "hf-token match" "$(mock_calls)"
assert_not_contains "never as an argument" "hf_A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5A1b2C3d4E5" "$(mock_calls)"
mock_reset_log
run_target_provisioner ollama
assert_not_contains "no other target gets it" "hf-token" "$(mock_calls)"
TARGET_HF_TOKEN=""; unset EXPECT_HF_TOKEN; COMFYUI_IMAGE_VARIANT=klein-4b
unset COMFYUI_COMMUNITY_SCRIPT_SHA256
export FAKE_PROVISION_RC=3
assert_fail "a failing provisioner fails" run_target_provisioner ollama
unset FAKE_PROVISION_RC
assert_fail "a target without settings is refused" run_target_provisioner basalt
assert_eq "the caller's CT_ID is untouched" 910 "$CT_ID"
GITEA_CT_ID=915; GITEA_IP_CIDR=192.0.2.95/24; GITEA_STORAGE=t-store
GITEA_COMMUNITY_SCRIPT_URL=https://example.test/gitea.sh; GITEA_COMMUNITY_SCRIPT_SHA256=abc123
export COMMUNITY_SCRIPT_URL=https://example.test/leaked.sh
mock_reset_log
run_target_provisioner gitea
assert_contains "a service gets its own CT and network, and no flags" "provision gitea|915|192.0.2.95/24|192.0.2.1|t-store|vmbr2||||||no|" "$(mock_calls)"
assert_contains "GITEA_COMMUNITY_SCRIPT_* become its COMMUNITY_SCRIPT_*" "service-env https://example.test/gitea.sh|abc123|" "$(mock_calls)"
MATTERMOST_CT_ID=916; MATTERMOST_IP_CIDR=192.0.2.96/24; MATTERMOST_STORAGE=t-store; MATTERMOST_CHANNEL=alerts
mock_reset_log
run_target_provisioner mattermost
assert_contains "Mattermost gets the router's alert channel, and no other service's script" "service-env ||alerts" "$(mock_calls)"
unset COMMUNITY_SCRIPT_URL GITEA_COMMUNITY_SCRIPT_URL GITEA_COMMUNITY_SCRIPT_SHA256 MATTERMOST_CHANNEL
export -n CORES ROOTFS_GB STORAGE; unset EXPECT_TOKEN

describe service_result
pct() { echo "pct $*" >> "$MOCK_LOG"; [[ $1 == exec && $2 == 915 && $5 == /etc/gitea-target/url ]] && printf 'http://192.0.2.95:3000\r\n'; }
assert_eq "reads a result file from the service CT, without line ends" http://192.0.2.95:3000 "$(service_result gitea url)"
assert_eq "a missing file is empty" "" "$(service_result gitea router-token)"

describe provision_service_targets
run_target_provisioner() { echo "run $1" >> "$MOCK_LOG"; [[ " ${FAKE_FAIL:-} " != *" $1 "* ]]; }
service_result() {
  case "$1/$2" in
    gitea/url) echo http://192.0.2.95:3000 ;; gitea/router-user) echo ollama-router ;;
    gitea/router-token) [[ -n ${FAKE_NO_TOKEN:-} ]] || echo 0123456789abcdef0123456789abcdef01234567 ;;
    mattermost/webhook-url) echo http://192.0.2.96:8065/hooks/abcdefghijklmnopqrstuvwxyz ;;
  esac
}
TARGETS="gitea mattermost ollama hermes"; GITEA_SERVER_URL=""; GITEA_ADMIN_USER=gitea; GITEA_DEPLOY_TOKEN=""; MATTERMOST_WEBHOOK_URL=""
mock_reset_log
provision_service_targets > "$_out" 2>&1; _rc=$?
assert_eq "both services are created" 0 "$_rc"
assert_eq "and only the services, in order" $'run gitea\nrun mattermost' "$(mock_calls)"
assert_eq "Gitea's URL becomes the router's" http://192.0.2.95:3000 "$GITEA_SERVER_URL"
assert_eq "its router account the Gitea user" ollama-router "$GITEA_ADMIN_USER"
assert_eq "and its token the deploy token" 0123456789abcdef0123456789abcdef01234567 "$GITEA_DEPLOY_TOKEN"
assert_eq "Mattermost's webhook becomes the alert webhook" http://192.0.2.96:8065/hooks/abcdefghijklmnopqrstuvwxyz "$MATTERMOST_WEBHOOK_URL"
assert_eq "both are recorded as done" "gitea mattermost " "$SERVICES_DONE"
assert_not_contains "the token is not printed" 0123456789abcdef "$(cat "$_out")"
mock_reset_log
FAKE_FAIL=gitea provision_service_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed service stops the install" 1 "$_rc"
assert_contains "saying how to repair it" "--reconfigure" "$(cat "$_out")"
assert_not_contains "before the next service" "run mattermost" "$(mock_calls)"
FAKE_NO_TOKEN=1 provision_service_targets > "$_out" 2>&1; _rc=$?
assert_eq "a Gitea without a token is a failure" 1 "$_rc"
TARGETS="ollama"; SERVICES_DONE="x"
assert_ok "no services, nothing to do" provision_service_targets
assert_eq "and nothing recorded" "" "$SERVICES_DONE"
# shellcheck source=/dev/null
source "$FUNCS"
unset GITEA_SERVER_URL GITEA_DEPLOY_TOKEN SERVICES_DONE; GITEA_ADMIN_USER="tester"

describe register_target_key
_stdin="$_tt/stdin"
pct() {
  echo "pct $*" >> "$MOCK_LOG"
  if [[ $1 == exec && $2 == 912 && $4 == cat ]]; then
    [[ -n ${FAKE_NO_KEY:-} ]] || echo sk-strata-generated
  elif [[ $1 == exec && $2 == 910 ]]; then
    cat > "$_stdin"
  fi
}
mock_reset_log
assert_ok "a target without a key needs nothing" register_target_key ollama
assert_eq "and runs nothing" "" "$(mock_calls)"
assert_ok "Strata's key is handed to the router" register_target_key strata
assert_contains "with set-strata-token in the router CT" "pct exec 910 -- /usr/local/bin/manage-model-servers set-strata-token" "$(mock_calls)"
assert_eq "on stdin, twice (token and confirmation)" $'sk-strata-generated\nsk-strata-generated' "$(cat "$_stdin")"
assert_not_contains "never as an argument" "sk-strata-generated" "$(mock_calls)"
FAKE_NO_KEY=1
assert_fail "an unreadable key is reported" register_target_key strata
assert_contains "with the command to run instead" "set-strata-token --apply" "$(register_target_key strata 2>&1)"
unset FAKE_NO_KEY
_saved_xolotl_id="${XOLOTL_CT_ID:-}"; XOLOTL_CT_ID=912
mock_reset_log
assert_ok "Xolotl's key is handed to the router" register_target_key xolotl
assert_contains "read from the Xolotl CT's record" "cat /etc/xolotl-target/api-key" "$(mock_calls)"
assert_contains "with set-xolotl-token, not the Strata command" "manage-model-servers set-xolotl-token" "$(mock_calls)"
assert_not_contains "never as an argument" "sk-strata-generated" "$(mock_calls)"
XOLOTL_CT_ID="$_saved_xolotl_id"; unset _saved_xolotl_id

describe wait_for_openwebui
pct() { echo "pct $*" >> "$MOCK_LOG"; [[ -z ${FAKE_WEBUI_DOWN:-} ]]; }
sleep() { :; }
mock_reset_log
assert_ok "returns once /health answers" wait_for_openwebui
assert_contains "asking from inside the router CT" "pct exec 910 -- curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/health" "$(mock_calls)"
FAKE_WEBUI_DOWN=1 OPENWEBUI_WAIT_SECONDS=1
assert_fail "gives up after OPENWEBUI_WAIT_SECONDS" wait_for_openwebui
unset FAKE_WEBUI_DOWN OPENWEBUI_WAIT_SECONDS

describe prompt_openwebui_admin_token
TARGET_ADMIN_TOKEN=preset-token
assert_ok "a preset token is used without asking" prompt_openwebui_admin_token < /dev/null
TARGET_ADMIN_TOKEN=""
prompt_openwebui_admin_token > "$_out" 2>&1 <<< $'typed-token\n'
assert_eq "takes the typed token" typed-token "$TARGET_ADMIN_TOKEN"
assert_contains "after saying where to create it" "Settings > Account > API keys" "$(cat "$_out")"
assert_not_contains "without echoing it" typed-token "$(cat "$_out")"
TARGET_ADMIN_TOKEN=""
assert_fail "blank skips the companions" prompt_openwebui_admin_token <<< $'\n'

describe provision_selected_targets
run_target_provisioner() {
  echo "run $1" >> "$MOCK_LOG"
  [[ $1 != deepseek-harness ]] || echo "dsh-webui ${TARGET_WEBUI_READY:-unset}" >> "$MOCK_LOG"
  [[ ${HONCHO_READY:-false} != true || $1 == honcho ]] || echo "honcho-ready $1" >> "$MOCK_LOG"
  [[ ${OPEN_TERMINAL_READY:-false} != true || $1 == open-terminal ]] || echo "open-terminal-ready $1" >> "$MOCK_LOG"
  [[ " ${FAKE_FAIL:-} " != *" $1 "* ]]
}
register_target_key() { echo "key $1" >> "$MOCK_LOG"; [[ -n "$(target_field "$1" key)" ]] || return 0; [[ -z ${FAKE_KEY_FAIL:-} ]]; }
ensure_target_template() { echo "template $1" >> "$MOCK_LOG"; }
wait_for_openwebui() { echo "wait" >> "$MOCK_LOG"; }
prompt_openwebui_admin_token() { echo "token" >> "$MOCK_LOG"; [[ -z ${FAKE_NO_TOKEN:-} ]]; }
run_ct() {
  echo "router $*" >> "$MOCK_LOG"
  [[ -z ${FAKE_APPLY_FAIL:-} || "$*" != '/usr/local/bin/manage-model-servers apply' ]]
}
TARGETS="ollama strata hermes"
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "all good is success" 0 "$_rc"
assert_eq "model targets, their keys, one apply, then the companions" \
  "$(printf '%s\n' 'run ollama' 'template local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst' 'run strata' 'key strata' \
     'router /usr/local/bin/manage-model-servers apply' wait token 'run hermes')" "$(mock_calls)"
assert_contains "the summary lists each target" "strata         CT 912    ok" "$(cat "$_out")"
mock_reset_log
FAKE_APPLY_FAIL=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed router key apply fails the run" 1 "$_rc"
assert_contains "the target is marked incomplete" "strata         CT 912    failed (OSR key apply)" "$(cat "$_out")"
assert_contains "the summary gives the apply command" "pct exec 910 -- /usr/local/bin/manage-model-servers apply" "$(cat "$_out")"
assert_contains "companions still run after an apply failure" "run hermes" "$(mock_calls)"
mock_reset_log
FAKE_FAIL=strata provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed target fails the run" 1 "$_rc"
assert_contains "and says how to retry it" "rerun targets/strata/provision-lxc.sh" "$(cat "$_out")"
assert_contains "while the others still run" "run hermes" "$(mock_calls)"
assert_not_contains "and no key is applied for it" "manage-model-servers apply" "$(mock_calls)"
FAKE_FAIL=hermes provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed Hermes companion fails the run" 1 "$_rc"
assert_contains "and gives the partial CT recovery command" \
  "CT_ID=914 ROUTER_CT_ID=910 bash targets/hermes/provision-lxc.sh --reconfigure" "$(cat "$_out")"
TARGETS="ollama openclaw"
FAKE_FAIL=openclaw provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed OpenClaw companion fails the run" 1 "$_rc"
assert_contains "and gives its partial CT recovery command" \
  "CT_ID=918 ROUTER_CT_ID=910 bash targets/openclaw/provision-lxc.sh --reconfigure" "$(cat "$_out")"
TARGETS="deepseek-harness"
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "DeepSeek alone succeeds" 0 "$_rc"
assert_eq "after the Open WebUI admin setup (its chat endpoint is registered there)" \
  "$(printf '%s\n' wait token 'run deepseek-harness' 'dsh-webui true')" "$(mock_calls)"
TARGETS="hermes deepseek-harness"
mock_reset_log
FAKE_NO_TOKEN=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "DeepSeek still runs when Open WebUI has no admin key, without Open WebUI" \
  "$(printf '%s\n' wait token 'run deepseek-harness' 'dsh-webui false')" "$(mock_calls)"
assert_contains "the summary says so" "deepseek-harness CT 921    ok (without Open WebUI)" "$(cat "$_out")"
assert_contains "Hermes is skipped" "skipped (no Open WebUI admin key)" "$(cat "$_out")"
TARGETS="opencode"
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "OpenCode alone succeeds" 0 "$_rc"
assert_eq "after the Open WebUI admin setup (its chat endpoint is registered there)" \
  "$(printf '%s\n' wait token 'run opencode')" "$(mock_calls)"
TARGETS="hermes opencode"
mock_reset_log
FAKE_NO_TOKEN=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "without an admin key OpenCode is not run" "$(printf '%s\n' wait token)" "$(mock_calls)"
assert_contains "but skipped like Hermes" "opencode       CT 922    skipped (no Open WebUI admin key)" "$(cat "$_out")"
TARGETS="ollama opencode"
FAKE_FAIL=opencode provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed OpenCode companion fails the run" 1 "$_rc"
assert_contains "and gives its partial CT recovery command" \
  "CT_ID=922 ROUTER_CT_ID=910 bash targets/opencode/provision-lxc.sh --reconfigure" "$(cat "$_out")"
TARGETS="ollama strata hermes"
FAKE_NO_TOKEN=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "no admin key fails the run" 1 "$_rc"
assert_contains "and the companions are skipped, not run" "skipped (no Open WebUI admin key)" "$(cat "$_out")"
FAKE_KEY_FAIL=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a key the router did not get is a failure to fix" 1 "$_rc"
assert_contains "named in the summary" "ok (OSR key not set)" "$(cat "$_out")"
TARGETS="gitea ollama"; SERVICES_DONE="gitea "
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "services done before the router are not run again" "run ollama" "$(mock_calls)"
assert_contains "but are in the summary" "ok (created before OSR)" "$(cat "$_out")"
TARGETS="ollama comfyui"; SERVICES_DONE=""
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "ComfyUI is added once Open WebUI is up and the admin key is known" \
  "$(printf '%s\n' 'run ollama' wait token 'run comfyui')" "$(mock_calls)"
assert_contains "and is in the summary" "comfyui        CT 917    ok" "$(cat "$_out")"
assert_eq "and count as success" 0 "$_rc"
TARGETS="hermes deepseek-harness open-terminal comfyui"
mock_reset_log
provision_selected_targets > "$_out" 2>&1
assert_eq "Open Terminal goes first, so the agents (in menu order) get it" \
  "$(printf '%s\n' wait token 'run open-terminal' 'run hermes' 'open-terminal-ready hermes' 'run deepseek-harness' 'dsh-webui true' \
     'open-terminal-ready deepseek-harness' 'run comfyui' 'open-terminal-ready comfyui')" "$(mock_calls)"
TARGETS="honcho hermes openclaw"
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "Honcho and both agents provision successfully" 0 "$_rc"
assert_eq "Honcho is installed before both agents use it" \
  "$(printf '%s\n' wait token 'run honcho' 'run hermes' 'honcho-ready hermes' 'run openclaw' 'honcho-ready openclaw')" "$(mock_calls)"
mock_reset_log
FAKE_FAIL=honcho provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed Honcho target fails the run" 1 "$_rc"
assert_not_contains "agents do not receive a failed Honcho instance" "honcho-ready" "$(mock_calls)"
assert_contains "Honcho recovery uses reconfigure after partial creation" \
  "CT_ID=920 ROUTER_CT_ID=910 bash targets/honcho/provision-lxc.sh --reconfigure" "$(cat "$_out")"
SERVICES_DONE=""
TARGETS=llamacpp; unset MODEL_ALIAS MODEL_PATH MODEL_DOWNLOAD_URL
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "llama.cpp with only its CT is not a failure" 0 "$_rc"
assert_contains "but the summary says what is left" "CT only: run install-target.sh" "$(cat "$_out")"
TARGETS=""
assert_ok "no targets, nothing to do" provision_selected_targets

# Restore the real functions and what the rest of the suite expects.
# shellcheck source=/dev/null
source "$FUNCS"
unset -f pveam pct sleep
rm -rf "$_tt" "$_out"
CT_ID=100; TARGETS=""; INSTALL_TARGETS=""; TARGET_ADMIN_TOKEN=""
unset TARGETS_DIR TARGET_RESERVED_IDS TARGET_RESERVED_IPS TEMPLATE_REF GATEWAY BRIDGE NAMESERVER \
  OPENWEBUI_PORT STORAGE CORES ROOTFS_GB IP_CIDR _tt _out _rc _stdin _pveam_list_local _pveam_list_nfs \
  OLLAMA_CT_ID OLLAMA_IP_CIDR OLLAMA_STORAGE STRATA_CT_ID STRATA_IP_CIDR STRATA_STORAGE STRATA_TEMPLATE \
  LLAMACPP_CT_ID LLAMACPP_IP_CIDR LLAMACPP_STORAGE HERMES_CT_ID HERMES_IP_CIDR HERMES_STORAGE MAYA_IP_CIDR \
  OPENCLAW_CT_ID OPENCLAW_IP_CIDR OPENCLAW_STORAGE
TEMPLATE_STORAGE="local"; MODEL_SERVER_COUNT=3

# ── validators ────────────────────────────────────────────────────────────────
describe valid_ipv4
assert_ok   "accepts 1.2.3.4"            valid_ipv4 1.2.3.4
assert_ok   "accepts 255.255.255.255"    valid_ipv4 255.255.255.255
assert_ok   "accepts 0.0.0.0"            valid_ipv4 0.0.0.0
assert_ok   "accepts leading zeros"      valid_ipv4 010.1.1.1
assert_fail "rejects octet > 255"        valid_ipv4 256.1.1.1
assert_fail "rejects 3 octets"           valid_ipv4 1.2.3
assert_fail "rejects 5 octets"           valid_ipv4 1.2.3.4.5
assert_fail "rejects empty"              valid_ipv4 ""
assert_fail "rejects hostname"           valid_ipv4 example.com

describe valid_cidr
assert_ok   "accepts 10.0.0.5/24"        valid_cidr 10.0.0.5/24
assert_ok   "accepts /32"                valid_cidr 10.0.0.5/32
assert_ok   "accepts /1"                 valid_cidr 10.0.0.5/1
assert_fail "rejects /0"                 valid_cidr 10.0.0.5/0
assert_fail "rejects /33"                valid_cidr 10.0.0.5/33
assert_fail "rejects missing prefix"     valid_cidr 10.0.0.5
assert_fail "rejects bad address"        valid_cidr 999.0.0.1/24
assert_fail "rejects non-numeric prefix" valid_cidr 10.0.0.5/ab

describe valid_hostname_or_ip
assert_ok   "accepts hostname"           valid_hostname_or_ip ollama1.lan
assert_ok   "accepts single label"       valid_hostname_or_ip ollama1
assert_ok   "accepts ip"                 valid_hostname_or_ip 10.0.0.5
assert_fail "rejects leading dash"       valid_hostname_or_ip -bad.lan
assert_fail "rejects trailing dot"       valid_hostname_or_ip bad.lan.
assert_fail "rejects spaces"             valid_hostname_or_ip "a b"
assert_fail "rejects empty"              valid_hostname_or_ip ""

describe valid_http_url
assert_ok   "accepts http"               valid_http_url http://h
assert_ok   "accepts https with port"    valid_http_url https://h:8443
assert_ok   "accepts path"               valid_http_url https://h/api/v1
assert_fail "rejects ftp"                valid_http_url ftp://h
assert_fail "rejects bare host"          valid_http_url example.com
assert_fail "rejects empty"              valid_http_url ""

describe valid_optional_url
assert_ok   "accepts blank"              valid_optional_url ""
assert_ok   "accepts valid url"          valid_optional_url https://mm/hooks/x
assert_fail "rejects junk"               valid_optional_url not-a-url

describe valid_optional_ipv4
assert_ok   "accepts blank"              valid_optional_ipv4 ""
assert_ok   "accepts ip"                 valid_optional_ipv4 10.0.0.1
assert_fail "rejects junk"               valid_optional_ipv4 nope

describe valid_nonempty
assert_ok   "accepts text"               valid_nonempty x
assert_fail "rejects empty"              valid_nonempty ""

describe valid_bool
assert_ok   "accepts true"        valid_bool true
assert_ok   "accepts false"       valid_bool false
assert_fail "rejects True"        valid_bool True
assert_fail "rejects yes"         valid_bool yes
assert_fail "rejects 1"           valid_bool 1
assert_fail "rejects empty"       valid_bool ""

describe valid_positive_int
assert_ok   "accepts 1"                  valid_positive_int 1
assert_ok   "accepts 64"                 valid_positive_int 64
assert_fail "rejects 0"                  valid_positive_int 0
assert_fail "rejects negative"           valid_positive_int -5
assert_fail "rejects text"               valid_positive_int abc
assert_fail "rejects empty"              valid_positive_int ""

describe valid_keep_alive
assert_ok   "accepts blank (server default)" valid_keep_alive ""
assert_ok   "accepts -1 (never unload)"      valid_keep_alive -1
assert_ok   "accepts 0"                      valid_keep_alive 0
assert_ok   "accepts seconds"                valid_keep_alive 600
assert_ok   "accepts 30m"                    valid_keep_alive 30m
assert_ok   "accepts 2h"                     valid_keep_alive 2h
assert_ok   "accepts compound 1h30m"         valid_keep_alive 1h30m
assert_fail "rejects text"                   valid_keep_alive abc
assert_fail "rejects bad unit"               valid_keep_alive 5x
assert_fail "rejects negative duration"      valid_keep_alive -5

describe valid_ollama_addr
assert_ok   "accepts bare ip"            valid_ollama_addr 10.0.0.5
assert_ok   "accepts ip:port"            valid_ollama_addr 10.0.0.5:11434
assert_ok   "accepts hostname"           valid_ollama_addr ollama1.lan
assert_ok   "accepts full url"           valid_ollama_addr http://h:11434
assert_fail "rejects port 0"             valid_ollama_addr 10.0.0.5:0
assert_fail "rejects port > 65535"       valid_ollama_addr 10.0.0.5:99999
assert_fail "rejects spaces"             valid_ollama_addr "a b"
assert_fail "rejects empty"              valid_ollama_addr ""
assert_ok   "accepts lmstudio://host"    valid_ollama_addr lmstudio://10.0.0.9
assert_ok   "accepts lmstudio+http url"  valid_ollama_addr lmstudio+http://h:1234
assert_fail "rejects lmstudio:// junk"   valid_ollama_addr "lmstudio://a b"
assert_ok   "accepts strata://host"      valid_ollama_addr strata://10.0.0.8
assert_ok   "accepts Strata on port 11434" valid_ollama_addr strata://10.0.0.8:11434
assert_ok   "accepts strata+http url"    valid_ollama_addr strata+http://h:8080
assert_ok   "accepts basalt://host"      valid_ollama_addr basalt://10.0.0.7
assert_ok   "accepts basalt+http url"    valid_ollama_addr basalt+http://h:8080
assert_ok   "accepts maya://host"        valid_ollama_addr maya://10.0.0.9
assert_ok   "accepts maya+http url"      valid_ollama_addr maya+http://h:8080
assert_ok   "accepts xolotl://host"      valid_ollama_addr xolotl://10.0.0.12
assert_ok   "accepts xolotl+http url"    valid_ollama_addr xolotl+http://h:8080
assert_fail "rejects xolotl:// junk"     valid_ollama_addr "xolotl://a b"
assert_ok   "accepts avalon://host"      valid_ollama_addr avalon://10.0.0.13
assert_ok   "accepts avalon+http url"    valid_ollama_addr avalon+http://h:8080
assert_fail "rejects avalon:// junk"     valid_ollama_addr "avalon://a b"
assert_ok   "accepts kindi://host"       valid_ollama_addr kindi://10.0.0.14
assert_ok   "accepts kindi+http url"     valid_ollama_addr kindi+http://h:8093
assert_fail "rejects kindi:// junk"      valid_ollama_addr "kindi://a b"

describe normalize_ollama_url
assert_eq "bare ip gets scheme and port" "http://10.0.0.5:11434" "$(normalize_ollama_url 10.0.0.5)"
assert_eq "explicit port preserved"      "http://10.0.0.5:9999"  "$(normalize_ollama_url 10.0.0.5:9999)"
assert_eq "url passes through"           "http://h:1"            "$(normalize_ollama_url http://h:1)"
assert_eq "trailing slash stripped"      "http://h:1"            "$(normalize_ollama_url http://h:1/)"
assert_eq "hostname gets default port"   "http://ollama1.lan:11434" "$(normalize_ollama_url ollama1.lan)"
assert_eq "https preserved"              "https://h:8443"        "$(normalize_ollama_url https://h:8443)"
assert_eq "lmstudio:// gets LM Studio's port" "lmstudio+http://h:1234" "$(normalize_ollama_url lmstudio://h)"
assert_eq "lmstudio:// keeps an explicit port" "lmstudio+http://h:4321" "$(normalize_ollama_url lmstudio://h:4321)"
assert_eq "lmstudio+http passes through"     "lmstudio+http://h:1234" "$(normalize_ollama_url lmstudio+http://h:1234/)"
assert_eq "strata:// default port"          "strata+http://h:8080"   "$(normalize_ollama_url strata://h)"
assert_eq "strata:// keeps port 11434"      "strata+http://h:11434" "$(normalize_ollama_url strata://h:11434)"
STRATA_PORT=11434
assert_eq "Strata default port can be 11434" "strata+http://h:11434" "$(normalize_ollama_url strata://h)"
unset STRATA_PORT
assert_eq "strata+http passes through"      "strata+http://h:8081"   "$(normalize_ollama_url strata+http://h:8081/)"
assert_eq "basalt:// default port"          "basalt+http://h:8080"   "$(normalize_ollama_url basalt://h)"
assert_eq "basalt+http passes through"      "basalt+http://h:8081"   "$(normalize_ollama_url basalt+http://h:8081/)"
assert_eq "maya:// default port"            "maya+http://h:8080"     "$(normalize_ollama_url maya://h)"
assert_eq "maya+http passes through"        "maya+http://h:8081"     "$(normalize_ollama_url maya+http://h:8081/)"
assert_eq "xolotl:// default port"          "xolotl+http://h:8080"   "$(normalize_ollama_url xolotl://h)"
assert_eq "xolotl+http passes through"      "xolotl+http://h:8150"   "$(normalize_ollama_url xolotl+http://h:8150/)"
assert_eq "avalon:// default port"          "avalon+http://h:8080"   "$(normalize_ollama_url avalon://h)"
assert_eq "avalon+http passes through"      "avalon+http://h:8181"   "$(normalize_ollama_url avalon+http://h:8181/)"
assert_eq "kindi:// gets Kindi's own port"  "kindi+http://h:8093"    "$(normalize_ollama_url kindi://h)"
assert_eq "kindi+http passes through"       "kindi+http://h:8094"    "$(normalize_ollama_url kindi+http://h:8094/)"
assert_eq "KINDI_PORT sets kindi://'s port" "kindi+http://h:8100"    "$(KINDI_PORT=8100 normalize_ollama_url kindi://h)"
AVALON_PORT=8181
assert_eq "AVALON_PORT sets avalon://'s port" "avalon+http://h:8181"  "$(normalize_ollama_url avalon://h)"
unset AVALON_PORT
XOLOTL_PORT=8150
assert_eq "Xolotl default port can be set"  "xolotl+http://h:8150"   "$(normalize_ollama_url xolotl://h)"
unset XOLOTL_PORT

describe valid_tier_selection
MODEL_SERVER_COUNT=3
assert_ok   "accepts single"             valid_tier_selection 1
assert_ok   "accepts list"               valid_tier_selection 1,3
assert_ok   "tolerates spaces"           valid_tier_selection "1, 3"
assert_fail "rejects above count"        valid_tier_selection 4
assert_fail "rejects zero"               valid_tier_selection 0
assert_fail "rejects empty"              valid_tier_selection ""
assert_fail "rejects text"               valid_tier_selection a

# ── tier maths ────────────────────────────────────────────────────────────────
describe tier_selection_to_indices
assert_eq "1 -> 0"           "0"     "$(tier_selection_to_indices 1)"
assert_eq "1,3 -> 0 2"       "0 2"   "$(tier_selection_to_indices 1,3)"
assert_eq "dedupes 2,2"      "1"     "$(tier_selection_to_indices 2,2)"
assert_eq "handles spaces"   "0 1"   "$(tier_selection_to_indices '1, 2')"
assert_eq "preserves order"  "2 0"   "$(tier_selection_to_indices 3,1)"

describe seq_csv
assert_eq "2..5"          "2,3,4,5" "$(seq_csv 2 5)"
assert_eq "single"        "3"       "$(seq_csv 3 3)"
assert_eq "empty range"   ""        "$(seq_csv 3 2)"

describe default_tier_selection
# Four tiers now. Every server must be used exactly once when there are enough
# of them, and every tier must still get *a* server when there are not.
for n in 1 2 3 4 5 6 8 9 12 20; do
  MODEL_SERVER_COUNT=$n
  f="$(default_tier_selection fast)";  m="$(default_tier_selection medium)"
  l="$(default_tier_selection large)"; x="$(default_tier_selection xlarge)"
  if (( n >= 4 )); then
    all="$(printf '%s,%s,%s,%s' "$f" "$m" "$l" "$x" | tr ',' '\n' | grep -c .)"
    uniq="$(printf '%s,%s,%s,%s' "$f" "$m" "$l" "$x" | tr ',' '\n' | sort -n | uniq | grep -c .)"
    if [[ "$all" == "$n" && "$uniq" == "$n" ]]; then
      _pass "N=${n} covers every server exactly once (${f} / ${m} / ${l} / ${x})"
    else
      _fail "N=${n} coverage" "${n} unique assignments" "${all} total / ${uniq} unique"
    fi
  else
    if [[ -n "$f" && -n "$m" && -n "$l" && -n "$x" ]]; then
      _pass "N=${n} every tier still gets a server (${f} / ${m} / ${l} / ${x})"
    else
      _fail "N=${n} tiers populated" "all non-empty" "${f}/${m}/${l}/${x}"
    fi
  fi
done
# Ordering: a tier never sits on a lower-numbered server than the tier below it.
MODEL_SERVER_COUNT=8
first() { printf '%s' "${1%%,*}"; }
assert_ok "tiers are assigned in ascending server order" bash -c "
  f=\$(printf '%s' '$(default_tier_selection fast)'   | cut -d, -f1)
  m=\$(printf '%s' '$(default_tier_selection medium)' | cut -d, -f1)
  l=\$(printf '%s' '$(default_tier_selection large)'  | cut -d, -f1)
  x=\$(printf '%s' '$(default_tier_selection xlarge)' | cut -d, -f1)
  [ \$f -le \$m ] && [ \$m -le \$l ] && [ \$l -le \$x ]"
# The remainder lands on xlarge, which gains most from parallel capacity.
MODEL_SERVER_COUNT=6
assert_eq "xlarge absorbs the remainder at N=6" "4,5,6" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=1
assert_eq "a single server backs every tier" "1" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=2
assert_eq "at N=2 the upper tiers share server 2" "2" "$(default_tier_selection large)"
assert_eq "and xlarge shares it too"              "2" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=3
assert_eq "at N=3 large and xlarge share server 3" "3" "$(default_tier_selection large)"
assert_eq "xlarge on server 3 as well"             "3" "$(default_tier_selection xlarge)"
MODEL_SERVER_COUNT=4

describe indices_to_urls
MODEL_SERVERS=(http://a:1 http://b:2 http://c:3)
assert_eq "single index"   "http://a:1"             "$(indices_to_urls '0')"
assert_eq "multiple"       "http://a:1,http://c:3"  "$(indices_to_urls '0 2')"
assert_eq "empty"          ""                       "$(indices_to_urls '')"

describe ip_in_same_subnet
assert_ok   "gateway inside /24"   ip_in_same_subnet 192.168.11.80/24 192.168.11.1
assert_fail "gateway outside /24"  ip_in_same_subnet 192.168.11.80/24 10.99.99.1
assert_ok   "wide prefix contains" ip_in_same_subnet 10.0.0.5/8 10.255.0.1
assert_ok   "unparseable is lenient" ip_in_same_subnet "garbage" "also-garbage"

# ── storage discovery ─────────────────────────────────────────────────────────
describe parse_pvesm_table
out="$(printf '%s\n' "$PVESM_REAL_OUTPUT" | parse_pvesm_table)"
assert_contains "reads Available despite (KiB) header tokens" "22194088960" "$out"
assert_eq "picks the Available column, not Used" \
  "2569773824" "$(printf '%s\n' "$PVESM_REAL_OUTPUT" | parse_pvesm_table | awk -F'\t' '$1=="vm_pool"{print $3}')"
assert_not_contains "excludes inactive storage" "dead-store" "$out"
assert_eq "row count (active only)" "5" "$(printf '%s\n' "$PVESM_REAL_OUTPUT" | parse_pvesm_table | grep -c .)"
alt="$(printf '%s\n' "$PVESM_ALT_ORDER" | parse_pvesm_table | awk -F'\t' '$1=="local-lvm"{print $3}')"
assert_eq "handles the alternate column order" "308819968" "$alt"

describe kib_to_gib
assert_eq "1 GiB"            "1"     "$(kib_to_gib 1048576)"
assert_eq "floors partial"   "0"     "$(kib_to_gib 1048575)"
assert_eq "large value"      "21165" "$(kib_to_gib 22194088960)"
assert_eq "zero"             "0"     "$(kib_to_gib 0)"
assert_eq "non-numeric -> 0" "0"     "$(kib_to_gib abc)"
assert_eq "empty -> 0"       "0"     "$(kib_to_gib '')"

describe storage_names_supporting
cfgdir="$(mktemp -d)"; STORAGE_CFG="${cfgdir}/storage.cfg"
cat > "$STORAGE_CFG" <<'EOF'
dir: local
	path /var/lib/vz
	content iso,vztmpl,backup

lvmthin: local-lvm
	thinpool data
	content rootdir,images

rbd: vm_pool
	pool rbd
	content images,rootdir
EOF
assert_eq "finds rootdir storages" "local-lvm vm_pool" "$(storage_names_supporting rootdir | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "finds vztmpl storages"  "local"             "$(storage_names_supporting vztmpl | tr -d '\n')"
assert_eq "unknown content type"   ""                  "$(storage_names_supporting snippets)"
STORAGE_CFG="/nonexistent"
assert_eq "unreadable config is silent" "" "$(storage_names_supporting rootdir)"
STORAGE_CFG="${cfgdir}/storage.cfg"

describe storage_candidates
mock_script pvesm <<'EOF'
for a in "$@"; do [ "$prev" = "-content" ] && content="$a"; prev="$a"; done
if [ "${content:-}" = "rootdir" ]; then
  echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
  echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
else
  echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
  echo "local                      dir     active        20155608        10782840         8323580   53.50%"
  echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
  echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
fi
exit 0
EOF
assert_eq "uses the server-side filter when it returns rows" \
  "local-lvm" "$(storage_candidates rootdir | awk -F'\t' '{print $1}' | tr -d '\n')"

mock_script pvesm <<'EOF'
for a in "$@"; do [ "$prev" = "-content" ] && content="$a"; prev="$a"; done
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
if [ -z "${content:-}" ]; then
  echo "local                      dir     active        20155608        10782840         8323580   53.50%"
  echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
  echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
fi
exit 0
EOF
assert_eq "falls back to storage.cfg when the filter is empty" \
  "local-lvm vm_pool" "$(storage_candidates rootdir | awk -F'\t' '{print $1}' | sort | tr '\n' ' ' | sed 's/ $//')"

cat > "$STORAGE_CFG" <<'EOF'
dir: local
	content iso,vztmpl,backup
EOF
assert_eq "readable config declaring none is definitive" "" "$(storage_candidates rootdir)"
STORAGE_CFG="/nonexistent"
assert_ne "unreadable config offers everything" "" "$(storage_candidates rootdir 2>/dev/null)"
STORAGE_CFG="${cfgdir}/storage.cfg"

describe storage_free_gib
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
exit 0
EOF
assert_eq "known storage"    "2450" "$(storage_free_gib vm_pool rootdir)"
assert_eq "unknown -> -1"    "-1"   "$(storage_free_gib nope rootdir)"

describe storage_supports_vztmpl
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "local                      dir     active        20155608        10782840         8323580   53.50%"
exit 0
EOF
assert_ok   "storage present"  storage_supports_vztmpl local
assert_fail "storage absent"   storage_supports_vztmpl vm_pool

describe select_storage_with_space
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "local-lvm              lvmthin     active         8282112               0         8282112    0.00%"
echo "vm_pool                    rbd     active      2888601515       318827691      2569773824   11.04%"
exit 0
EOF
NONINTERACTIVE=true
PICK=""
assert_ok "succeeds when something fits" select_storage_with_space rootdir 64 PICK ""
select_storage_with_space rootdir 64 PICK "" >/dev/null 2>&1
assert_eq "picks the largest that fits" "vm_pool" "$PICK"
PICK=""
select_storage_with_space rootdir 4 PICK "local-lvm" >/dev/null 2>&1
assert_eq "prefers the caller's choice when it fits" "local-lvm" "$PICK"
PICK=""
select_storage_with_space rootdir 4 PICK "does-not-exist" >/dev/null 2>&1
assert_eq "falls back when preferred is unknown" "vm_pool" "$PICK"
assert_fail "fails when nothing is big enough" select_storage_with_space rootdir 99999 PICK ""
NONINTERACTIVE=false

describe diagnose_storage
out="$(diagnose_storage rootdir 2>&1)"
assert_contains "reports the content type asked for" "rootdir" "$out"
assert_contains "shows all active storages"          "all active storages" "$out"

# ── template selection ────────────────────────────────────────────────────────
describe template_storages
TEMPLATE_STORAGE="my-tpl"
mock_script pvesm <<'EOF'
echo "Name                      Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %"
echo "local                      dir     active        20155608        10782840         8323580   53.50%"
exit 0
EOF
out="$(template_storages)"
assert_contains "includes the configured storage first" "my-tpl" "$out"
assert_contains "includes discovered storages"          "local"  "$out"
assert_eq "deduplicates" "$(template_storages | sort -u | wc -l)" "$(template_storages | wc -l)"

describe find_existing_debian_template
mock_script pvesm <<'EOF'
echo "Name  Type  Status  Total (KiB)  Used (KiB)  Available (KiB)  %"
echo "local  dir  active  100  10  90  10%"
exit 0
EOF
mock_script pveam <<'EOF'
if [ "$1" = "list" ]; then
  echo "NAME                                                         SIZE"
  echo "local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst          120MB"
  echo "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst          119MB"
fi
exit 0
EOF
TEMPLATE_STORAGE="local"; TEMPLATE_NAME=""
assert_eq "picks the highest version" \
  "local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst" "$(find_existing_debian_template)"
TEMPLATE_NAME="debian-13-standard_13.0-1_amd64.tar.zst"
assert_eq "honours an explicit TEMPLATE_NAME" \
  "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst" "$(find_existing_debian_template)"
TEMPLATE_NAME=""
mock_command pveam 0 "NAME  SIZE"
assert_fail "fails when no template exists" find_existing_debian_template

describe select_available_debian_template
mock_script pveam <<'EOF'
if [ "$1" = "available" ]; then
  echo "section  package"
  echo "system   debian-13-standard_13.1-1_amd64.tar.zst"
  echo "system   debian-12-standard_12.7-1_amd64.tar.zst"
fi
exit 0
EOF
assert_eq "selects the newest debian 13" \
  "debian-13-standard_13.1-1_amd64.tar.zst" "$(select_available_debian_template)"
mock_command pveam 0 "section  package"
assert_fail "fails when nothing is downloadable" select_available_debian_template

# ── container helpers ─────────────────────────────────────────────────────────
describe require_command
assert_ok   "existing command"  require_command bash
assert_fail "missing command"   bash -c "source '$FUNCS'; require_command definitely-not-a-real-binary"

describe run_ct
CT_ID=999
mock_command pct 0
run_ct echo hello >/dev/null 2>&1
assert_contains "delegates to pct exec" "exec 999 -- echo hello" "$(mock_calls)"

describe apt_get
mock_reset_log
mock_command pct 0
assert_ok "succeeds first try" apt_get update
mock_reset_log
mock_command pct 1
assert_fail "gives up after retries" apt_get update
assert_eq "retried three times" "3" "$(mock_call_count 'apt-get update')"

describe wait_for_ct_ready
mock_script pct <<'EOF'
# systemctl probe succeeds, DNS probe succeeds
case "$*" in
  *is-system-running*) echo running;;
esac
exit 0
EOF
assert_ok "returns once systemd and DNS are up" wait_for_ct_ready

# ── gitea helpers ─────────────────────────────────────────────────────────────
describe init_gitea_curl_opts
GITEA_VERIFY_TLS=true;  init_gitea_curl_opts 2>/dev/null
assert_not_contains "verification on omits --insecure" "--insecure" "${GITEA_CURL_OPTS[*]}"
GITEA_VERIFY_TLS=false; init_gitea_curl_opts 2>/dev/null
assert_contains "verification off adds --insecure" "--insecure" "${GITEA_CURL_OPTS[*]}"

describe gitea_diagnose_rc
assert_contains "6 mentions DNS"          "DNS"         "$(gitea_diagnose_rc 6 https://g 2>&1)"
assert_contains "7 mentions the appliance" "nginx"      "$(gitea_diagnose_rc 7 https://g 2>&1)"
assert_contains "7 mentions the community port" "port 3000" "$(gitea_diagnose_rc 7 http://g:3000 2>&1)"
assert_contains "22 mentions 401"          "401"        "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_contains "22 names the token scopes" "write:repository" "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_contains "22 explains existing-repo scopes" "Existing repositories need read:user and write:repository." "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_contains "22 names the extra creation scope" "Automatic repository creation also needs write:user" "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_contains "22 notes the account needs write access" "needs Write access" "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_not_contains "22 does not request unnecessary organisation scope" "write:organization" "$(gitea_diagnose_rc 22 https://g 2>&1)"
assert_contains "60 mentions certificate"  "certificate" "$(gitea_diagnose_rc 60 https://g 2>&1)"
assert_contains "unknown code is reported" "99"         "$(gitea_diagnose_rc 99 https://g 2>&1)"

describe gitea_probe_user
mock_command curl 0 '{"login":"mike"}'
assert_eq "returns the login" "mike" "$(gitea_probe_user TOKEN 2>/dev/null)"
mock_command curl 22
assert_fail "fails when curl fails" gitea_probe_user TOKEN

describe gitea_api
auth="Authorization: token X"
mock_command curl 0 'body'
out="$(gitea_api GET https://g/api 2>/dev/null)"
assert_contains "passes the method through" "-X GET" "$(mock_calls)"
mock_reset_log
gitea_api POST https://g/api '{"a":1}' >/dev/null 2>&1
assert_contains "sends a JSON body on POST" "Content-Type: application/json" "$(mock_calls)"
# A body over Linux's 128 KiB per-argument limit (a large file's base64) goes
# on stdin; on the command line, curl would not even start.
_body_seen="$(mktemp)"
mock_script curl <<EOF
cat > "${_body_seen}"
echo '{}'; echo 201
EOF
mock_reset_log
_big_body="{\"content\":\"$(head -c 150000 /dev/zero | tr '\0' 'A')\"}"
out="$(gitea_api POST https://g/api "$_big_body" 2>&1)"
assert_contains "a body over 128 KiB is sent" "201" "$out"
assert_eq "complete, on stdin" "${#_big_body}" "$(wc -c < "$_body_seen" | tr -d ' ')"
assert_contains "with --data-binary @-" "--data-binary @-" "$(mock_calls)"
assert_not_contains "and not on the command line" "AAAAAAAAAA" "$(mock_calls)"
rm -f "$_body_seen"; unset _body_seen _big_body

describe resolve_gitea_repo
GITEA_REPO_OWNER=""; GITEA_OWNER="mike"
mock_script curl <<'EOF'
# GET /repos/mike/... -> 200 with the trailing status line gitea_api appends
echo '{"default_branch":"main"}'
echo 200
exit 0
EOF
assert_status "found under the token owner" 0 resolve_gitea_repo TOKEN
GITEA_REPO_OWNER="org-team"
mock_script curl <<'EOF'
echo '{"message":"not found"}'
echo 404
exit 0
EOF
assert_status "explicit owner, repo missing -> 2" 2 resolve_gitea_repo TOKEN
GITEA_REPO_OWNER=""

# ── config generation ─────────────────────────────────────────────────────────
describe push_local_config_tree
tree="$(mktemp -d)"; mkdir -p "${tree}/env"; echo "X=1" > "${tree}/env/router.env"
mock_reset_log; mock_command pct 0
CT_ID=321
push_local_config_tree "$tree" >/dev/null 2>&1
assert_contains "pushes a tarball into the container" "push 321" "$(mock_calls)"
assert_contains "extracts it under the config dir"    "tar -xzf"  "$(mock_calls)"
rm -rf "$tree"

describe cleanup_on_error
CT_CREATED=""; STAGE_DIR="$(mktemp -d)"
mock_reset_log; mock_command pct 0
cleanup_on_error >/dev/null 2>&1 || true
assert_eq "no container destroyed when none was created" "0" "$(mock_call_count 'destroy')"
assert_ok "removes the staging directory" bash -c "[[ ! -d '$STAGE_DIR' ]]"
CT_CREATED=1; STAGE_DIR=""; CT_ID=777
mock_reset_log
cleanup_on_error >/dev/null 2>&1 || true
assert_contains "destroys a half-provisioned container" "destroy 777" "$(mock_calls)"
CT_CREATED=""

# ── prompts ───────────────────────────────────────────────────────────────────
describe prompt_value
NONINTERACTIVE=false
RESULT=""
prompt_value "x" RESULT "thedefault" <<< ""
assert_eq "empty input takes the default" "thedefault" "$RESULT"
prompt_value "x" RESULT "thedefault" <<< "typed"
assert_eq "typed input wins" "typed" "$RESULT"
NONINTERACTIVE=true
RESULT=""
prompt_value "x" RESULT "auto"
assert_eq "non-interactive uses the default" "auto" "$RESULT"
NONINTERACTIVE=false

describe prompt_until_valid
RESULT=""
prompt_until_valid "ip" RESULT "10.0.0.1" valid_ipv4 <<< "" >/dev/null 2>&1
assert_eq "accepts the default" "10.0.0.1" "$RESULT"
prompt_until_valid "ip" RESULT "10.0.0.1" valid_ipv4 <<< $'bad\n10.0.0.9' >/dev/null 2>&1
assert_eq "re-prompts until valid" "10.0.0.9" "$RESULT"
NONINTERACTIVE=true
assert_fail "non-interactive rejects an invalid preset" \
  prompt_until_valid "ip" RESULT "not-an-ip" valid_ipv4
NONINTERACTIVE=false
# Exhausted stdin with an invalid default used to spin forever, hanging any
# piped or partially-answered run. It must give up instead.
assert_status "gives up when stdin runs out" 1 \
  timeout 5 bash -c "source '$FUNCS'; NONINTERACTIVE=false; R=''; \
                     prompt_until_valid 'ip' R 'not-an-ip' valid_ipv4 < /dev/null"
assert_ok "still accepts a valid default at EOF" \
  timeout 5 bash -c "source '$FUNCS'; NONINTERACTIVE=false; R=''; \
                     prompt_until_valid 'ip' R '10.0.0.1' valid_ipv4 < /dev/null"

describe prompt_secret
SECRET=""
prompt_secret "pw" SECRET <<< $'a\nb\nsame\nsame' >/dev/null 2>&1
assert_eq "loops until both entries match" "same" "$SECRET"

describe prompt_optional_secret
SECRET="preset"
prompt_optional_secret "tok" SECRET <<< "" >/dev/null 2>&1
assert_eq "blank input yields empty" "" "$SECRET"
prompt_optional_secret "tok" SECRET <<< "abc123" >/dev/null 2>&1
assert_eq "captures the value" "abc123" "$SECRET"

describe prompt_network_config
BRIDGE=vmbr0; IP_CIDR=10.0.0.5/24; GATEWAY=10.0.0.1; NAMESERVER=""
_pn_out="$(mktemp)"
prompt_network_config > "$_pn_out" 2>&1 <<< $'\n\n\n\n' || true
assert_eq "keeps defaults on empty input" "10.0.0.5/24" "$IP_CIDR"
IP_CIDR=""; GATEWAY=""
assert_fail "missing network addresses cannot be inferred" prompt_network_config <<< $'\n\n'
IP_CIDR=192.168.50.10/24; GATEWAY=10.99.99.1
prompt_network_config > "$_pn_out" 2>&1 <<< $'\n\n\n\n' || true
assert_contains "warns when the gateway is off-subnet" "outside" "$(cat "$_pn_out")"
rm -f "$_pn_out"

describe prompt_mattermost_config
MATTERMOST_WEBHOOK_URL=""; MATTERMOST_CHANNEL="ollama-monitor"
MATTERMOST_MONITOR_USER="OllamaMonitor"; MATTERMOST_VERIFY_TLS="true"
_pm_out="$(mktemp)"
prompt_mattermost_config > "$_pm_out" 2>&1 <<< $'\n' || true
assert_contains "blank webhook disables alerting" "No webhook" "$(cat "$_pm_out")"
rm -f "$_pm_out"
prompt_mattermost_config <<< $'https://mm/hooks/x\nchan\nuser\nfalse' >/dev/null 2>&1
assert_eq "captures the webhook" "https://mm/hooks/x" "$MATTERMOST_WEBHOOK_URL"
assert_eq "captures the channel"  "chan" "$MATTERMOST_CHANNEL"
assert_eq "captures verify-tls"   "false" "$MATTERMOST_VERIFY_TLS"
# An internal Mattermost behind a self-signed cert must be configurable here.
MATTERMOST_VERIFY_TLS="true"
prompt_mattermost_config <<< $'https://mm/hooks/x\n\n\n\n' >/dev/null 2>&1
assert_eq "verify-tls defaults through" "true" "$MATTERMOST_VERIFY_TLS"
MATTERMOST_VERIFY_TLS="true"

describe prompt_model_servers
MODEL_SERVER_COUNT=3; MODEL_SERVER_MIN=1; MODEL_SERVER_MAX=20
MODEL_SERVER_1=10.0.0.51; MODEL_SERVER_2=10.0.0.52; MODEL_SERVER_3=10.0.0.53
MODEL_SERVER_4=""; MODEL_SERVER_5=""
TIER_FAST_SERVERS=""; TIER_MEDIUM_SERVERS=""; TIER_LARGE_SERVERS=""; TIER_XLARGE_SERVERS=""
MODEL_FAST=a; MODEL_MEDIUM=b; MODEL_LARGE=c; MODEL_XLARGE=d; OLLAMA_KEEP_ALIVE=""
MODEL_SERVERS=(); TIER_FAST_IDX=""; TIER_MEDIUM_IDX=""; TIER_LARGE_IDX=""; TIER_XLARGE_IDX=""
# Redirect to a file rather than $(...): command substitution runs the function
# in a subshell, where its assignments to MODEL_SERVERS et al. are discarded.
_pms_out="$(mktemp)"
prompt_model_servers > "$_pms_out" 2>&1 <<< $'0\n21\nabc\n2\n10.0.0.1\n10.0.0.2\n\n\n\n\n\n\n\n' || true
out="$(cat "$_pms_out")"
assert_contains "rejects a count below the minimum" "too few" "$out"
assert_contains "rejects a count above the maximum" "too many" "$out"
assert_contains "rejects a non-numeric count"       "not a whole number" "$out"
assert_eq "settles on the valid count" "2" "$MODEL_SERVER_COUNT"
assert_eq "normalises entered addresses" "http://10.0.0.1:11434" "${MODEL_SERVERS[0]}"
MODEL_SERVERS=(); MODEL_SERVER_COUNT=3
prompt_model_servers > "$_pms_out" 2>&1 <<< $'3\n10.0.0.1\n10.0.0.1\n10.0.0.3\n\n\n\n\n\n\n\n' || true
out="$(cat "$_pms_out")"; rm -f "$_pms_out"
assert_contains "warns about duplicate addresses" "same address" "$out"
MODEL_SERVERS=(); MODEL_SERVER_COUNT=1; MODEL_SERVER_1=strata://10.0.0.8:11434
prompt_model_servers > /dev/null 2>&1 <<< $'\n\n\n\n\n\n\n\n\n\n\n' || true
assert_eq "installer keeps Strata on port 11434" "strata+http://10.0.0.8:11434" "${MODEL_SERVERS[0]}"
MODEL_SERVERS=(); MODEL_SERVER_COUNT=1; MODEL_SERVER_1=basalt://10.0.0.7:11434
prompt_model_servers > /dev/null 2>&1 <<< $'\n\n\n\n\n\n\n\n\n\n\n' || true
assert_eq "installer keeps Basalt on port 11434" "basalt+http://10.0.0.7:11434" "${MODEL_SERVERS[0]}"
MODEL_SERVERS=(); MODEL_SERVER_COUNT=1; MODEL_SERVER_1=maya://10.0.0.9:11434
prompt_model_servers > /dev/null 2>&1 <<< $'\n\n\n\n\n\n\n\n\n\n\n' || true
assert_eq "installer keeps Maya on port 11434" "maya+http://10.0.0.9:11434" "${MODEL_SERVERS[0]}"
MODEL_SERVERS=(); MODEL_SERVER_COUNT=1; MODEL_SERVER_1=""
assert_fail "a missing model server address cannot be inferred" prompt_model_servers </dev/null
NONINTERACTIVE=true
assert_fail "an unattended install needs an explicit model server address" prompt_model_servers </dev/null
NONINTERACTIVE=false
MODEL_SERVER_COUNT=3; MODEL_SERVER_1=10.0.0.51

# ── python provisioning ───────────────────────────────────────────────────────
describe ensure_openwebui_python
OPENWEBUI_PY_VERSION=3.12; OPENWEBUI_PY_DIR=/opt/python
mock_script pct <<'EOF'
shift 2   # drop "exec <id>"
[ "$1" = "--" ] && shift
case "$1" in
  bash) case "$*" in
          *"command -v python3.12"*) echo "/usr/bin/python3.12"; exit 0;;
          *) exit 0;;
        esac;;
  runuser) exit 0;;   # service user can execute it
  *) exit 0;;
esac
EOF
assert_eq "uses an existing usable interpreter" "/usr/bin/python3.12" "$(ensure_openwebui_python 2>/dev/null)"
mock_script pct <<'EOF'
shift 2; [ "$1" = "--" ] && shift
case "$1" in
  bash) case "$*" in
          *"command -v python3.12"*) echo "/root/.local/bin/python3.12"; exit 0;;
          *uv*) exit 0;;
          *) exit 0;;
        esac;;
  runuser) exit 1;;   # service user CANNOT execute the /root one
  *) exit 0;;
esac
EOF
out="$(ensure_openwebui_python 2>&1 >/dev/null)"
assert_contains "rejects an interpreter the service user cannot run" "not executable by the service user" "$out"

# ── privilege / fatal helpers ─────────────────────────────────────────────────
describe require_root
# `id` is stubbed rather than the test being run as a different user.
mock_command id 0 "0"
assert_ok "root passes" bash -c "source '$FUNCS'; require_root"
mock_command id 0 "1000"
assert_fail "non-root is rejected" bash -c "source '$FUNCS'; require_root"
out="$(bash -c "source '$FUNCS'; require_root" 2>&1)"
assert_contains "explains it needs the Proxmox host" "Proxmox host" "$out"
mock_command id 0 "0"

describe die_storage
assert_status "exits 1" 1 bash -c "source '$FUNCS'; die_storage"
assert_contains "names the reason" "storage that fits" \
  "$(bash -c "source '$FUNCS'; die_storage" 2>&1)"

# ── storage prompt ────────────────────────────────────────────────────────────
describe prompt_storage_config
mock_command pvesm 0 "$PVESM_REAL_OUTPUT"
ROOTFS_GB=32; STORAGE="local"
_ps_out="$(mktemp)"
prompt_storage_config > "$_ps_out" 2>&1 <<< $'\n' || true
assert_eq   "keeps the default size on empty input" "32" "$ROOTFS_GB"
assert_ne   "picks a storage with room"             ""   "$STORAGE"
ROOTFS_GB=32; STORAGE="local"
prompt_storage_config > "$_ps_out" 2>&1 <<< $'64\n' || true
assert_eq   "takes the typed size" "64" "$ROOTFS_GB"
# 64 GiB does not fit in `local` (8.3 GiB free) — it must move elsewhere.
assert_ne   "will not choose a storage that is too small" "local" "$STORAGE"
# Nothing has room at all -> die_storage must fire rather than continue.
mock_command pvesm 0 'Name   Type   Status   Total (KiB)   Used (KiB)   Available (KiB)   %
tiny    dir   active       1048576       524288            524288  50.00%'
ROOTFS_GB=64
assert_fail "aborts when nothing fits" \
  bash -c "source '$FUNCS'; NONINTERACTIVE=true; ROOTFS_GB=64; STORAGE=''; STORAGE_CFG=''; prompt_storage_config"
rm -f "$_ps_out"
mock_command pvesm 0 "$PVESM_REAL_OUTPUT"
ROOTFS_GB=32; STORAGE="local"

# ── gitea credential prompt ───────────────────────────────────────────────────
describe prompt_gitea_credentials
_pg_out="$(mktemp)"
GITEA_SERVER_URL="https://git.example.net"; GITEA_ADMIN_USER="tester"
GITEA_REPO_NAME="ollama-smart-router"; GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
mock_command curl 0 '{"login":"tester"}'
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\nTOKEN123\n' || true
assert_eq "accepts a verified token"  "TOKEN123" "$GITEA_DEPLOY_TOKEN"
assert_eq "owner comes from the token" "tester"  "$GITEA_OWNER"
assert_eq "config stays version controlled" "gitea" "$CONFIG_SOURCE"
# TLS verification is forced off for the TurnKey appliance's self-signed cert.
assert_eq "forces GITEA_VERIFY_TLS=false" "false" "$GITEA_VERIFY_TLS"

# A token owned by a different account: the real login wins as repo owner.
GITEA_DEPLOY_TOKEN=""; GITEA_ADMIN_USER="tester"
mock_command curl 0 '{"login":"someone-else"}'
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\nTOKEN123\n' || true
assert_eq "owner follows the token, not the typed username" "someone-else" "$GITEA_OWNER"
assert_contains "says whose token it is" "someone-else" "$(cat "$_pg_out")"

# No token at all -> fall back to a local, non-version-controlled config.
GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\n\n' || true
assert_eq "no token falls back to local" "local" "$CONFIG_SOURCE"

# Token rejected three times -> give up, but do not abort the install.
GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
mock_command curl 22
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n\n\nbad1\nbad2\nbad3\n' || true
assert_eq "gives up after 3 attempts" "local" "$CONFIG_SOURCE"
assert_contains "reports the attempt count" "3" "$(cat "$_pg_out")"
assert_ok "returns 0 so provisioning continues" \
  bash -c "source '$FUNCS'; NONINTERACTIVE=true; GITEA_DEPLOY_TOKEN=''; GITEA_SERVER_URL=https://g.example; \
           GITEA_ADMIN_USER=t; GITEA_REPO_NAME=r; GITEA_VERIFY_TLS=false; GITEA_CURL_OPTS=(); \
           prompt_gitea_credentials"
# No URL: there is no placeholder host to fall back on.
assert_ok "the URL has no built-in default" \
  bash -c "unset GITEA_SERVER_URL; source '$FUNCS'; [[ -z \$GITEA_SERVER_URL ]]"
GITEA_SERVER_URL=""; GITEA_DEPLOY_TOKEN=""; CONFIG_SOURCE="gitea"
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'\n' || true
assert_eq "blank URL installs a local config" "local" "$CONFIG_SOURCE"
assert_contains "and says so" "No Gitea server URL" "$(cat "$_pg_out")"
assert_fail "a token without a URL stops the install" \
  bash -c "source '$FUNCS'; NONINTERACTIVE=true; GITEA_DEPLOY_TOKEN=tok; GITEA_SERVER_URL=''; \
           prompt_gitea_credentials"
GITEA_SERVER_URL=""; CONFIG_SOURCE="gitea"
prompt_gitea_credentials > "$_pg_out" 2>&1 <<< $'https://git.example.org\n\n\n\n' || true
assert_eq "a typed URL is used" "https://git.example.org" "$GITEA_SERVER_URL"
GITEA_SERVER_URL="https://git.example.net"
rm -f "$_pg_out"
GITEA_ADMIN_USER="tester"; GITEA_OWNER="tester"; GITEA_DEPLOY_TOKEN=""

# ── gitea access test ─────────────────────────────────────────────────────────
describe test_gitea_access
GITEA_SERVER_URL="https://git.example.net"; GITEA_OWNER="tester"
GITEA_REPO_NAME="ollama-smart-router"; GITEA_REPO_OWNER=""; GITEA_REPO_PRIVATE=true
assert_ok "no token is a skip, not a failure" test_gitea_access ""

# NOTE on these curl stubs: gitea_probe_user calls curl WITHOUT -X and parses
# bare JSON, while gitea_api calls it WITH -X and appends a `\n<status>` line.
# A stub that answers both the same way makes the probe fail on the trailing
# status digits, so every case below branches on -X first.

# Happy path: auth ok, repo exists, commit created.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;      # probe
esac
case "$*" in
  *contents*) echo '{"commit":{"html_url":"https://git.example.net/c/1"}}'; echo 201; exit 0;;
  *)          echo '{"default_branch":"main"}'; echo 200; exit 0;;
esac
EOF
out="$(test_gitea_access TOKEN 2>&1)"; rc=$?
assert_eq       "succeeds end to end"        "0" "$rc"
assert_contains "reports the authenticated user" "tester" "$out"
assert_contains "reports the test commit"        "test commit succeeded" "$out"

# The marker file is deleted again after the successful write. Request bodies
# reach curl on stdin (see gitea_api); log them so the sha can be checked.
mock_script curl <<'EOF'
case "$*" in *--data-binary*) { printf 'body: '; cat; echo; } >> "$MOCK_LOG";; esac
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;
esac
case "$*" in
  *"-X DELETE"*) echo '{}'; echo 200; exit 0;;
  *contents*) echo '{"content":{"sha":"abc123"},"commit":{"html_url":"u"}}'; echo 201; exit 0;;
  *)          echo '{"default_branch":"main"}'; echo 200; exit 0;;
esac
EOF
mock_reset_log
out="$(test_gitea_access TOKEN 2>&1)"
assert_contains "removes the marker again" "Removed the test marker" "$out"
assert_contains "deletes with the blob sha" "abc123" "$(mock_calls)"

# http:// remote: note the clear-text token and the redirect that drops it.
GITEA_SERVER_URL="http://git.example.net"
out="$(test_gitea_access TOKEN 2>&1)"
assert_contains "http:// notes the token is sent unencrypted" "sent unencrypted" "$out"
assert_contains "http:// notes curl drops the token on an HTTPS redirect" "curl drops the token" "$out"
GITEA_SERVER_URL="https://git.example.net"

# Repo missing everywhere (404 + empty search) -> created under the token owner.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;
esac
case "$*" in
  *"user/repos"*) echo '{"full_name":"tester/ollama-smart-router"}'; echo 201; exit 0;;
  *search*)       echo '{"data":[]}'; echo 200; exit 0;;
  *contents*)     echo '{"commit":{"html_url":"u"}}'; echo 201; exit 0;;
  *)              echo '{"message":"Not Found"}'; echo 404; exit 0;;
esac
EOF
out="$(test_gitea_access TOKEN 2>&1)" || true
assert_contains "creates the repo when it is missing" "Creating repository" "$out"
assert_contains "and still commits into it"           "test commit succeeded" "$out"

# An explicit owner that is not the token owner (e.g. an organisation) is never
# created: POST /user/repos would put the repo under the token owner instead.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;
esac
case "$*" in
  *"user/repos"*) echo '{"full_name":"tester/ollama-smart-router"}'; echo 201; exit 0;;
  *contents*)     echo '{"commit":{"html_url":"u"}}'; echo 201; exit 0;;
  *)              echo '{"message":"Not Found"}'; echo 404; exit 0;;
esac
EOF
GITEA_REPO_OWNER="org-team"
mock_reset_log
out="$(test_gitea_access TOKEN 2>&1)"; rc=$?
assert_eq       "a missing repo under another owner fails" "1" "$rc"
assert_contains "and says to create it in Gitea first" "Create it in Gitea first" "$out"
assert_eq       "without creating a repo under the token owner" "0" "$(mock_call_count 'user/repos')"
assert_eq       "or writing a test commit" "0" "$(mock_call_count 'contents')"
# The same owner in different case is the token owner, so creation proceeds.
GITEA_REPO_OWNER="Tester"
mock_reset_log
out="$(test_gitea_access TOKEN 2>&1)" || true
assert_contains "the token owner in another case is still created" "Creating repository tester/ollama-smart-router" "$out"
assert_contains "and committed to"                     "test commit succeeded" "$out"
GITEA_REPO_OWNER=""

# Commit rejected -> non-zero and the HTTP code surfaced.
mock_script curl <<'EOF'
case "$*" in
  *-X*) ;;
  *)    echo '{"login":"tester"}'; exit 0;;
esac
case "$*" in
  *contents*) echo '{"message":"forbidden"}'; echo 403; exit 0;;
  *)          echo '{"default_branch":"main"}'; echo 200; exit 0;;
esac
EOF
assert_fail "a rejected commit fails the test" test_gitea_access TOKEN
assert_contains "surfaces the HTTP status" "403" "$(test_gitea_access TOKEN 2>&1)"

# Auth itself fails -> stop before touching the repository at all.
mock_command curl 22
mock_reset_log
assert_fail "an unusable token fails fast" test_gitea_access TOKEN
assert_eq   "no repo API calls are attempted" "0" "$(mock_call_count 'contents')"

# ── repo seeding ──────────────────────────────────────────────────────────────
describe seed_gitea_repo
seedtree="$(mktemp -d)"
mkdir -p "${seedtree}/env" "${seedtree}/services/ollama-router"
echo "A=1" > "${seedtree}/env/router.env"
echo "[tiers]" > "${seedtree}/services/ollama-router/router.ini"
CONFIG_SEED_IF_MISSING=true
assert_fail "no token means no seeding" seed_gitea_repo "$seedtree" ""
CONFIG_SEED_IF_MISSING=false
assert_ok   "seeding disabled is a clean no-op" seed_gitea_repo "$seedtree" TOKEN
assert_contains "and says so" "not writing" "$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"
CONFIG_SEED_IF_MISSING=true

# Everything absent -> every file is created.
mock_script curl <<'EOF'
case "$*" in
  *"-X POST"*) echo '{}'; echo 201; exit 0;;
  *)           echo '{"message":"Not Found"}'; echo 404; exit 0;;
esac
EOF
out="$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"
assert_contains "creates both files"    "2 created" "$out"
assert_contains "counts nothing skipped" "0 already present" "$out"

# Everything already present -> nothing is overwritten.
mock_script curl <<'EOF'
echo '{"path":"x"}'; echo 200; exit 0
EOF
mock_reset_log
out="$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"
assert_contains "existing files are left alone" "2 already present" "$out"
assert_eq       "no POST is issued"             "0" "$(mock_call_count '-X POST')"

# A single failure is reported without aborting the rest of the walk.
mock_script curl <<'EOF'
case "$*" in
  *"-X POST"*router.ini*) echo '{"message":"nope"}'; echo 422; exit 0;;
  *"-X POST"*)            echo '{}'; echo 201; exit 0;;
  *)                      echo '{}'; echo 404; exit 0;;
esac
EOF
out="$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"; _rc=$?
assert_contains "reports the failed file" "failed to seed" "$out"
assert_contains "still seeds the others"  "1 created"      "$out"
assert_contains "counts the failure"      "1 failed"       "$out"
assert_eq "and returns failure, so the clone is checked" 1 "$_rc"
unset _rc

# A file whose base64 is over 128 KiB (install/manage-model-servers.sh is) is
# seeded whole: its content never goes through a command-line argument.
_seen="$(mktemp)"
_bigtree="$(mktemp -d)"
mkdir -p "${_bigtree}/install"
head -c 110000 /dev/urandom | base64 -w 76 > "${_bigtree}/install/manage-model-servers.sh"
mock_script curl <<EOF
case "\$*" in
  *"-X POST"*) cat > "${_seen}"; echo '{}'; echo 201; exit 0;;
  *)           echo '{"message":"Not Found"}'; echo 404; exit 0;;
esac
EOF
out="$(seed_gitea_repo "$_bigtree" TOKEN 2>&1)"; _rc=$?
assert_eq "a file over the argument limit is seeded" 0 "$_rc"
assert_contains "and counted" "1 created" "$out"
assert_eq "with its exact content" "$(sha256sum < "${_bigtree}/install/manage-model-servers.sh" | cut -d' ' -f1)" \
  "$(python3 -c 'import base64,json,sys,hashlib; print(hashlib.sha256(base64.b64decode(json.load(open(sys.argv[1]))["content"])).hexdigest())' "$_seen")"
rm -rf "$_bigtree" "$_seen"; unset _bigtree _seen _rc

# Installer-owned code that differs is UPDATED (PUT with the blob sha); the
# user's config files are still never touched.
mkdir -p "${seedtree}/services/ollama-monitor"
echo "new code" > "${seedtree}/services/ollama-monitor/monitor.py"
_old_b64="$(printf 'old code\n' | base64 -w0)"
mock_script curl <<EOF
case "\$*" in *--data-binary*) { printf 'body: '; cat; echo; } >> "\$MOCK_LOG";; esac
case "\$*" in
  *"-X PUT"*)    echo '{}'; echo 200; exit 0;;
  *monitor.py*)  echo '{"sha":"abc123","content":"${_old_b64}"}'; echo 200; exit 0;;
  *)             echo '{"sha":"def456","content":"${_old_b64}"}'; echo 200; exit 0;;
esac
EOF
mock_reset_log
CONFIG_UPDATE_CODE=true
out="$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"
assert_contains "updates stale installer-owned code" "1 updated" "$out"
assert_contains "names the updated file" "updated: services/ollama-monitor/monitor.py" "$out"
assert_eq "exactly one PUT is issued" "1" "$(mock_call_count '-X PUT')"
assert_contains "sends the blob sha" "abc123" "$(mock_calls)"
assert_contains "leaves config alone" "2 already present" "$out"
CONFIG_UPDATE_CODE=false
mock_reset_log
out="$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"
assert_eq "CONFIG_UPDATE_CODE=false never PUTs" "0" "$(mock_call_count '-X PUT')"
CONFIG_UPDATE_CODE=true
rm -rf "$seedtree"

describe generate_api_key
k1="$(generate_api_key)"; k2="$(generate_api_key)"
assert_contains "has the router prefix" "sk-router-" "$k1"
assert_ne "is random" "$k1" "$k2"
assert_ok "is long enough" test "${#k1}" -ge 30

describe ensure_fw_rule
_fw="$(mktemp)"; printf '[OPTIONS]\nenable: 1\n' > "$_fw"
ensure_fw_rule "$_fw" "IN ACCEPT -p tcp -dport 22"
ensure_fw_rule "$_fw" "IN ACCEPT -p tcp -dport 22"
assert_eq "never duplicates a rule" "1" "$(grep -c 'dport 22' "$_fw")"
assert_eq "adds a [RULES] section when missing" "1" "$(grep -cx '\[RULES\]' "$_fw")"
rm -f "$_fw"

describe write_firewall_rules
_fw="$(mktemp -u)"
write_firewall_rules "$_fw" 10.0.0.0/24 8080
write_firewall_rules "$_fw" 10.0.0.0/24 8080
assert_file_contains "enables the firewall"   "enable: 1" "$_fw"
assert_file_contains "keeps SSH reachable"    "-source 10.0.0.0/24 -p tcp -dport 22 " "$_fw"
assert_file_contains "opens the router API"   "-dport 8000 " "$_fw"
assert_file_contains "opens Open WebUI"       "-dport 8080 " "$_fw"
assert_eq "re-running adds nothing" "3" "$(grep -c '^IN ACCEPT' "$_fw")"
rm -f "$_fw"

describe remove_marker_file
auth="Authorization: token T"
mock_command curl 0 $'{}\n200'
out="$(remove_marker_file https://g/api/v1 o r main provisioning-tests/x.md '{"content":{"sha":"s1"}}' 2>&1)"
assert_contains "deletes it" "Removed the test marker" "$out"
mock_command curl 0 $'{}\n409'
out="$(remove_marker_file https://g/api/v1 o r main p.md '{"content":{"sha":"s1"}}' 2>&1)"
assert_contains "a refused delete is only a note" "could not remove" "$out"
assert_ok "and never fails the run" remove_marker_file https://g/api/v1 o r main p.md '{"content":{"sha":"s1"}}'
out="$(remove_marker_file https://g/api/v1 o r main p.md 'not json' 2>&1)"
assert_contains "missing sha is reported" "could not read" "$out"

describe litellm_router_settings
out="$(printf 'fast q@a\nmedium m@b\nlarge m@b\n' | litellm_router_settings)"
assert_contains "sets retries"   "  num_retries: 2" "$out"
assert_not_contains "no Kindi, no retry policy" "model_group_retry_policy" "$out"
assert_contains "sets a timeout" "  timeout: 600" "$out"
assert_contains "falls back to the nearest tier" '- fast: ["medium", "large"]' "$out"
assert_contains "skips identical deployments"   '- medium: ["fast"]' "$out"
assert_not_contains "never names a tier without deployments" "xlarge" "$out"
assert_not_contains "a single tier has no fallbacks" "fallbacks" "$(printf 'fast q@a\n' | litellm_router_settings)"
out="$(printf 'fast q@http://a:11434\nmedium b@http://a:11434,kindi+http://k:8093\nlarge b@kindi+http://k:8093\n' | litellm_router_settings)"
assert_contains "Kindi keeps the router's retries for other errors" "  num_retries: 2" "$out"
assert_contains "a tier with Kindi gets a retry policy" "    medium:" "$out"
assert_contains "a tier of Kindi alone too"             "    large:" "$out"
assert_not_contains "a tier without Kindi has none"     "    fast:" "$out"
assert_contains "no retry after a Kindi timeout"        "      TimeoutErrorRetries: 0" "$out"
assert_contains "one retry after a Kindi 429"           "      RateLimitErrorRetries: 1" "$out"
assert_not_contains "no field LiteLLM 1.75 ignores"      "InternalServerErrorRetries" "$out"
assert_not_contains "a tier without Kindi never falls back into Kindi" '- fast: ["medium"' "$out"
assert_not_contains "nor a Kindi tier into its own Kindi server" '- medium: ["large"' "$out"

describe initial_litellm_deployments
# The first install emits deployments before manage-model-servers has run.
# shellcheck source=/dev/null
source <(sed -n '/^  emit_tier_deployments() {/,/^  }/p' "$SCRIPT")
_saved_servers=("${MODEL_SERVERS[@]}")
MODEL_SERVERS=("kindi+http://h:8093" "http://h:11434")
OLLAMA_KEEP_ALIVE=""
out="$(emit_tier_deployments fast bonsai2-2b '0')"
assert_contains "Kindi uses OpenAI on the first install" "model: openai/bonsai2-2b" "$out"
assert_contains "Kindi's initial base has /v1" "api_base: http://h:8093/v1" "$out"
assert_contains "Kindi's initial timeout" "timeout: 3600" "$out"
assert_not_contains "Kindi deployment does not use ignored retry field" "num_retries:" "$out"
out="$(emit_tier_deployments fast qwen:7b '1')"
assert_not_contains "Ollama keeps LiteLLM's timeout" "timeout: 3600" "$out"
MODEL_SERVERS=("${_saved_servers[@]}")

describe is_installer_owned
assert_ok   "router.py is owned"         is_installer_owned services/ollama-router/router.py
assert_ok   "the manage tool is owned"   is_installer_owned install/manage-model-servers.sh
assert_fail "router.ini is a tunable"    is_installer_owned services/ollama-router/router.ini
assert_fail "env files are config"       is_installer_owned env/router.env

describe gitea_sha_if_changed
_f="$(mktemp)"; printf 'same\n' > "$_f"
_same="$(printf 'same\n' | base64 -w0)"; _diff="$(printf 'other\n' | base64 -w0)"
assert_eq "identical content -> empty" "" \
  "$(printf '{"sha":"s1","content":"%s"}' "$_same" | gitea_sha_if_changed "$_f")"
assert_eq "different content -> sha" "s2" \
  "$(printf '{"sha":"s2","content":"%s"}' "$_diff" | gitea_sha_if_changed "$_f")"
assert_eq "unparseable body -> empty" "" "$(echo 'not json' | gitea_sha_if_changed "$_f")"
rm -f "$_f"

# ── container clone ───────────────────────────────────────────────────────────
describe verify_config_clone
_vtree="$(mktemp -d)"; _vclone="$(mktemp -d)"
mkdir -p "${_vtree}/install" "${_vtree}/services/ollama-router" "${_vclone}/install" "${_vclone}/services/ollama-router"
echo "tool v2" > "${_vtree}/install/manage-model-servers.sh"
echo "router v2" > "${_vtree}/services/ollama-router/router.py"
echo "A=1" > "${_vtree}/router.env"        # not installer-owned: never checked
cp "${_vtree}/install/manage-model-servers.sh" "${_vclone}/install/"
cp "${_vtree}/services/ollama-router/router.py" "${_vclone}/services/ollama-router/"
# pct exec <id> -- CMD...: run CMD here, against the fake clone.
mock_script pct <<'EOF'
[ "$1" = exec ] && { shift 3; exec "$@"; }
exit 0
EOF
_saved_repo_dir=$CONFIG_REPO_DIR; CONFIG_REPO_DIR=$_vclone; CONFIG_UPDATE_CODE=true
assert_ok "a complete, current clone passes" verify_config_clone "$_vtree"
rm "${_vclone}/install/manage-model-servers.sh"
out="$(verify_config_clone "$_vtree" 2>&1)"; _rc=$?
assert_eq "a missing installer-owned file fails" 1 "$_rc"
assert_contains "naming it" "missing: install/manage-model-servers.sh" "$out"
assert_contains "and the cause" "Seeding them into" "$out"
echo "tool v1" > "${_vclone}/install/manage-model-servers.sh"
out="$(verify_config_clone "$_vtree" 2>&1)"; _rc=$?
assert_eq "a stale one fails when code updates are on" 1 "$_rc"
assert_contains "naming it" "not updated: install/manage-model-servers.sh" "$out"
CONFIG_UPDATE_CODE=false
assert_ok "but not when the repo's own version is kept on purpose" verify_config_clone "$_vtree"
rm "${_vclone}/install/manage-model-servers.sh"
assert_fail "a missing one fails either way" verify_config_clone "$_vtree"
CONFIG_UPDATE_CODE=true; CONFIG_REPO_DIR=$_saved_repo_dir
rm -rf "$_vtree" "$_vclone"; unset _vtree _vclone _saved_repo_dir _rc

describe clone_config_repo
CT_ID=910; CONFIG_REPO_DIR="/app/config-repo"
GITEA_SERVER_URL="https://git.example.net"; GITEA_OWNER="tester"
GITEA_REPO_NAME="ollama-smart-router"; GITEA_VERIFY_TLS=false
mock_reset_log; mock_command pct 0
clone_config_repo "SECRETTOKEN" >/dev/null 2>&1
calls="$(mock_calls)"
assert_contains "pushes a credential file into the container" "push 910" "$calls"
assert_contains "with 0600 permissions"                       "--perms 0600" "$calls"
assert_contains "clones the configured repo"  "ollama-smart-router.git" "$calls"
assert_contains "honours GITEA_VERIFY_TLS"    "http.sslVerify=false"    "$calls"
assert_contains "removes the credential file afterwards" "rm -f /root/.git-credentials" "$calls"
assert_contains "tightens permissions on the clone" "chmod -R go-rwx" "$calls"
assert_not_contains "never puts the token on a command line" "SECRETTOKEN" "$calls"

# The credential entry must carry the remote's scheme; git will not match an
# https:// credential against an http:// request.
_cred_seen="$(mktemp)"
mock_script pct <<EOF
if [ "\$1" = "push" ]; then cp "\$3" "${_cred_seen}"; fi
exit 0
EOF
GITEA_SERVER_URL="http://git.example.net"
clone_config_repo "SECRETTOKEN" >/dev/null 2>&1
assert_file_contains "credential scheme follows the remote" \
  "http://tester:SECRETTOKEN@git.example.net" "$_cred_seen"
GITEA_SERVER_URL="https://git.example.net"
clone_config_repo "SECRETTOKEN" >/dev/null 2>&1
assert_file_contains "https remote gets an https credential" \
  "https://tester:SECRETTOKEN@git.example.net" "$_cred_seen"
rm -f "$_cred_seen"

# ── summary ───────────────────────────────────────────────────────────────────
rm -rf "$cfgdir"
summary
