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
TEMPLATE_NAME=""
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

describe ct_id_free
assert_ok   "a free ID, asked of the cluster" ct_id_free 906
assert_fail "a used ID, asked of the cluster" ct_id_free 905
mkdir -p "$_ids/pct-only"; cp "$_ids/pct" "$_ids/pct-only/pct"
assert_fail "without pvesh, pct status decides" \
  env PATH="$_ids/pct-only:$NO_PVESH_BIN" bash -c 'source "$1"; ct_id_free 905' _ "$FUNCS"
assert_ok   "and a free ID passes" \
  env PATH="$_ids/pct-only:$NO_PVESH_BIN" bash -c 'source "$1"; ct_id_free 906' _ "$FUNCS"

describe cluster_next_ct_id
assert_eq "reads the cluster's next free ID" "910" "$(cluster_next_ct_id)"
: > "$_ids/nextid"
assert_fail "an unanswered nextid is an error" cluster_next_ct_id
assert_contains "that says the guest list is unreadable" "Cannot read the cluster's guest list" \
  "$(cluster_next_ct_id 2>&1)"
assert_fail "rejects an ID printed by a failed pvesh" \
  bash -c 'source "$1"; pvesh() { echo 910; return 1; }; cluster_next_ct_id' _ "$FUNCS"
echo 910 > "$_ids/nextid"
assert_eq "without pvesh there is no cluster answer, and no error" "" \
  "$(env PATH="$_ids/pct-only:$NO_PVESH_BIN" bash -c 'source "$1"; cluster_next_ct_id' _ "$FUNCS")"

describe next_free_ct_id_excluding
assert_eq "takes the cluster's next free ID" "910" "$(next_free_ct_id_excluding)"
assert_eq "skips an ID this run will use later" "911" "$(next_free_ct_id_excluding 910)"
echo "905 911" > "$_ids/used"
assert_eq "and IDs already in use" "912" "$(next_free_ct_id_excluding 910)"
echo 905 > "$_ids/used"
: > "$_ids/nextid"
assert_fail "an unreadable guest list stops the search" next_free_ct_id_excluding 910
echo 910 > "$_ids/nextid"
assert_fail "a scan with no free ID gives up" \
  env PATH="$_ids/pct-only:$NO_PVESH_BIN" timeout 30 bash -c \
    'source "$1"; ct_id_free() { return 1; }; next_free_ct_id_excluding' _ "$FUNCS"

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
for _name in gitea mattermost ollama llamacpp airllm strata basalt maya xolotl open-terminal hermes comfyui; do
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
[[ -z ${GPU:-}${BACKEND:-}${GPU_DEVICES:-} ]] || printf 'gpu-env %s|%s|%s\n' "${GPU:-}" "${BACKEND:-}" "${GPU_DEVICES:-}" >> "$MOCK_LOG"
[[ -z ${CUDA_VERSION:-}${MAYA_CUDA_VERSION:-}${XOLOTL_CUDA_VERSION:-} ]] ||
  printf 'cuda-env %s|%s|%s\n' "${CUDA_VERSION:-}" "${MAYA_CUDA_VERSION:-}" "${XOLOTL_CUDA_VERSION:-}" >> "$MOCK_LOG"
if [[ -n ${HF_TOKEN:-} ]]; then
  if [[ $HF_TOKEN == "${EXPECT_HF_TOKEN:-unset}" ]]; then echo 'hf-token match'; else echo 'hf-token other'; fi >> "$MOCK_LOG"
fi
exit "${FAKE_PROVISION_RC:-0}"
EOF
done
unset _name

describe target_table
assert_eq "lists the twelve targets in menu order" \
  "gitea mattermost ollama llamacpp airllm strata basalt maya xolotl open-terminal hermes comfyui" \
  "$(target_table | cut -d'|' -f1 | paste -sd' ')"

describe target_field
assert_eq "model phase" model "$(target_field strata phase)"
assert_eq "companion phase" companion "$(target_field hermes phase)"
assert_eq "ComfyUI is a companion of Open WebUI" companion "$(target_field comfyui phase)"
assert_eq "and not a model server" "" "$(target_field comfyui entry)"
assert_eq "service phase" service "$(target_field gitea phase)"
assert_eq "router entry template" "strata+http://@IP@:@PORT@" "$(target_field strata entry)"
assert_eq "key kind" basalt "$(target_field basalt key)"
assert_eq "Xolotl has its own key kind" xolotl "$(target_field xolotl key)"
assert_eq "Xolotl router entry template" "xolotl+http://@IP@:@PORT@" "$(target_field xolotl entry)"
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
assert_fail "an unknown target" target_gpu_need nope

describe prepare_host_gpu
mkdir -p "$_tt/tools"
cat > "$_tt/tools/setup-host-gpu.sh" <<'EOF'
printf 'gpu-tool %s\n' "$*" >> "$MOCK_LOG"
printf '%s\n' "${FAKE_GPU_OUT:-GPU_STATE=ready}"
exit "${FAKE_GPU_RC:-0}"
EOF
mock_reset_log
TARGETS="gitea hermes"
assert_ok "nothing to do without GPU targets" prepare_host_gpu
assert_eq "and the tool is not run" "" "$(cat "$MOCK_LOG")"
TARGETS="ollama strata basalt"
export FAKE_GPU_OUT=$'GPU_STATE=ready\nGPU_GENERATION=rtx50\nGPU_CUDA_ARCH=120\nGPU_VENDOR=nvidia'
_out="$(prepare_host_gpu 2>&1)"
assert_contains "required targets set the need and the shared vendor" \
  "gpu-tool --need required --vendors nvidia --for strata basalt --allow rtx50:basalt" "$(cat "$MOCK_LOG")"
assert_contains "reports the GPU" "NVIDIA GPU ready: rtx50 (compute capability 120)" "$_out"
mock_reset_log
TARGETS="ollama comfyui"; export FAKE_GPU_OUT=GPU_STATE=absent
_out="$(prepare_host_gpu 2>&1)"
assert_contains "optional targets alone, any vendor" "gpu-tool --need optional --vendors nvidia,amd,intel --for ollama comfyui" "$(cat "$MOCK_LOG")"
assert_contains "go on without a GPU" "No GPU (absent): ollama comfyui will run without one." "$_out"
mock_reset_log
TARGETS="llamacpp comfyui"
export FAKE_GPU_OUT=$'GPU_STATE=ready\nGPU_GENERATION=rdna3\nGPU_VENDOR=amd\nGPU_GFX=gfx1100\nGPU_RENDER_NODE=/dev/dri/renderD128'
_out="$(BACKEND=vulkan prepare_host_gpu 2>&1)"
assert_contains "llama.cpp's Vulkan build narrows the vendors" "--vendors amd,intel --for llamacpp" "$(cat "$MOCK_LOG")"
assert_contains "an AMD card is reported" "AMD Radeon GPU ready: rdna3 (gfx1100, /dev/dri/renderD128 and /dev/kfd)" "$_out"
export FAKE_GPU_OUT=$'GPU_STATE=ready\nGPU_GENERATION=arc-b\nGPU_VENDOR=intel\nGPU_RENDER_NODE=/dev/dri/renderD129'
assert_contains "and an Intel Arc" "Intel Arc GPU ready: arc-b (/dev/dri/renderD129)" "$(prepare_host_gpu 2>&1)"
mock_reset_log
TARGETS="strata llamacpp"
BACKEND=vulkan
assert_fail "targets that cannot share a GPU" prepare_host_gpu
unset BACKEND
_out="$(BACKEND=vulkan prepare_host_gpu 2>&1 || true)"
assert_contains "are named, before the tool runs" "cannot share one GPU: strata (nvidia) llamacpp (amd/intel)" "$_out"
assert_eq "and nothing ran" "" "$(cat "$MOCK_LOG")"
TARGETS="xolotl"; export FAKE_GPU_RC=2
assert_fail "a reboot stops the install" prepare_host_gpu
assert_contains "and says to rerun" "Reboot this host" "$(prepare_host_gpu 2>&1)"
FAKE_GPU_RC=1
assert_fail "a GPU that is not ready stops it" prepare_host_gpu
assert_contains "naming the targets" "The GPU is not ready for: xolotl" "$(prepare_host_gpu 2>&1)"
unset FAKE_GPU_RC
export FAKE_GPU_OUT=$'GPU_STATE=ready\nGPU_VENDOR=amd\nGPU_RENDER_NODE=/dev/dri/renderD128'
TARGETS="ollama"
prepare_host_gpu >/dev/null 2>&1
assert_eq "the result is kept for the targets" "ready amd /dev/dri/renderD128" "$HOST_GPU_STATE $HOST_GPU_VENDOR $HOST_GPU_RENDER_NODE"
unset FAKE_GPU_OUT
mv "$_tt/tools/setup-host-gpu.sh" "$_tt/tools/gone"
assert_fail "the tool must be in the checkout" prepare_host_gpu
mv "$_tt/tools/gone" "$_tt/tools/setup-host-gpu.sh"
TARGETS=""; unset _out
mock_reset_log

describe target_gpu_env
HOST_GPU_STATE="" HOST_GPU_VENDOR="" HOST_GPU_RENDER_NODE=""
assert_eq "nothing before the GPU step ran" "" "$(target_gpu_env ollama)"
HOST_GPU_STATE=ready HOST_GPU_VENDOR=amd HOST_GPU_RENDER_NODE=/dev/dri/renderD128
assert_eq "Ollama gets the vendor" GPU=amd "$(target_gpu_env ollama)"
assert_eq "so does ComfyUI" GPU=amd "$(target_gpu_env comfyui)"
assert_eq "unless GPU was set" "" "$(GPU=no target_gpu_env comfyui)"
assert_eq "llama.cpp gets Vulkan and the render node" $'BACKEND=vulkan\nGPU_DEVICES=/dev/dri/renderD128' "$(target_gpu_env llamacpp)"
assert_eq "a preset GPU_DEVICES is kept" "BACKEND=vulkan" "$(GPU_DEVICES=/dev/dri/renderD129 target_gpu_env llamacpp)"
assert_eq "a preset BACKEND is kept" "" "$(BACKEND=cpu target_gpu_env llamacpp)"
HOST_GPU_VENDOR=nvidia HOST_GPU_RENDER_NODE=""
assert_eq "NVIDIA: llama.cpp builds for CUDA" BACKEND=cuda "$(target_gpu_env llamacpp)"
assert_eq "NVIDIA: ComfyUI" GPU=nvidia "$(target_gpu_env comfyui)"
HOST_GPU_STATE=declined
assert_eq "no GPU: Ollama runs on the CPU" GPU=none "$(target_gpu_env ollama)"
assert_eq "no GPU: llama.cpp keeps its own default" "" "$(target_gpu_env llamacpp)"
assert_eq "other targets get nothing" "" "$(target_gpu_env strata)"
HOST_GPU_STATE="" HOST_GPU_VENDOR="" HOST_GPU_RENDER_NODE=""

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
assert_fail "llama.cpp prompts for its own" target_needs_template llamacpp
assert_fail "Hermes uses the router's" target_needs_template hermes
assert_fail "ComfyUI's community script picks its own" target_needs_template comfyui

describe valid_target_selection
for _sel in "" none "1,10" "ollama hermes" " 2 , strata " "8" "12" "comfyui" "xolotl"; do
  assert_ok "accepts '${_sel}'" valid_target_selection "$_sel"
done
for _sel in 0 13 bogus "ollama,bogus"; do
  assert_fail "rejects '${_sel}'" valid_target_selection "$_sel"
done
unset _sel

describe normalize_target_selection
assert_eq "names and numbers, in menu order" "gitea ollama strata hermes" "$(normalize_target_selection 'hermes,3, 6,1')"
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
NONINTERACTIVE=false; INSTALL_TARGETS=""
_out="$(mktemp)"
prompt_target_selection > "$_out" 2>&1 <<< $'13\n4,hermes\n'
assert_eq "re-prompts until valid, then keeps the choice" "llamacpp hermes" "$TARGETS"
assert_contains "the menu lists the model servers" "9) xolotl" "$(cat "$_out")"
assert_contains "the menu lists the companions" "11) hermes" "$(cat "$_out")"
assert_contains "ComfyUI among them" "12) comfyui" "$(cat "$_out")"
assert_contains "and separates them from the model servers" "Companions:" "$(cat "$_out")"
assert_contains "the services come first" "Services: created now, before the router" "$(cat "$_out")"
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

describe target_cuda_env
assert_eq "Basalt on Ubuntu 26.04 uses CUDA 13.3" CUDA_VERSION=13.3 "$(target_cuda_env basalt local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)"
assert_eq "Maya on Debian 13 uses CUDA 13.1" MAYA_CUDA_VERSION=13.1 "$(target_cuda_env maya local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst)"
assert_eq "Xolotl on Ubuntu 26.04 uses CUDA 13.3" XOLOTL_CUDA_VERSION=13.3 "$(target_cuda_env xolotl local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)"
assert_eq "Ubuntu 24.04 keeps its CUDA default" "" "$(target_cuda_env basalt local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst)"
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
next_free_ct_id_excluding() { local id max=0; for id in "$@"; do (( id > max )) && max=$id; done; echo $((max + 1)); }
default_gpu_target_template() { echo local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst; }
CT_ID=910; IP_CIDR=192.0.2.80/24; GATEWAY=192.0.2.1; BRIDGE=vmbr0; STORAGE=router-store
TARGETS="ollama strata"
unset OLLAMA_CT_ID OLLAMA_IP_CIDR OLLAMA_STORAGE STRATA_CT_ID STRATA_IP_CIDR STRATA_STORAGE STRATA_TEMPLATE
_out="$(mktemp)"
prompt_target_settings > "$_out" 2>&1 <<< $'\n192.0.2.80/24\n192.0.2.90/24\n\n\n192.0.2.90/24\n192.0.2.91/24\ngpu-store\n\n'
assert_eq "the first target takes the ID after the router's" 911 "$OLLAMA_CT_ID"
assert_eq "the next one skips it" 912 "$STRATA_CT_ID"
assert_eq "the router's address is refused, the next answer kept" 192.0.2.90/24 "$OLLAMA_IP_CIDR"
assert_eq "an address already taken is refused" 192.0.2.91/24 "$STRATA_IP_CIDR"
assert_eq "storage defaults to the router's" router-store "$OLLAMA_STORAGE"
assert_eq "or takes the answer" gpu-store "$STRATA_STORAGE"
assert_eq "a GPU target gets a template" local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst "$STRATA_TEMPLATE"
assert_eq "Ollama is not given one (the community script chooses)" "" "${OLLAMA_TEMPLATE:-}"
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

describe run_target_provisioner
CT_ID=910; GATEWAY=192.0.2.1; BRIDGE=vmbr2; NAMESERVER=""; OPENWEBUI_PORT=8080
TEMPLATE_REF=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
export CORES=8 ROOTFS_GB=32 STORAGE=router-store
OLLAMA_CT_ID=911; OLLAMA_STORAGE=t-store
STRATA_CT_ID=912; STRATA_STORAGE=gpu-store; STRATA_TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
LLAMACPP_CT_ID=913; LLAMACPP_IP_CIDR=192.0.2.93/24; LLAMACPP_STORAGE=t-store
HERMES_CT_ID=914; HERMES_IP_CIDR=192.0.2.94/24; HERMES_STORAGE=t-store
TARGET_ADMIN_TOKEN=owui-admin-secret; export EXPECT_TOKEN=owui-admin-secret
mock_reset_log
assert_ok "runs Ollama's provisioner" run_target_provisioner ollama
assert_eq "with its own CT, network and storage, and the guest install" \
  "provision ollama|911|192.0.2.90/24|192.0.2.1|t-store|vmbr2||||||no|--install-target" "$(mock_calls)"
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
mock_reset_log
run_target_provisioner llamacpp
assert_contains "llama.cpp without a model only gets its CT" "|no|" "$(mock_calls)"
assert_not_contains "(no guest install)" "--install-target" "$(mock_calls)"
MODEL_ALIAS=qwen3:8b MODEL_PATH=/var/lib/llama-target/models/m.gguf run_target_provisioner llamacpp
assert_contains "with a model it installs" "|no|--install-target" "$(mock_calls)"
mock_reset_log
HOST_GPU_STATE=ready HOST_GPU_VENDOR=intel HOST_GPU_RENDER_NODE=/dev/dri/renderD129
run_target_provisioner llamacpp
assert_contains "llama.cpp gets the host GPU's Vulkan settings" "gpu-env |vulkan|/dev/dri/renderD129" "$(mock_calls)"
mock_reset_log
run_target_provisioner ollama
assert_contains "Ollama gets the GPU vendor" "gpu-env intel||" "$(mock_calls)"
mock_reset_log
run_target_provisioner strata
assert_not_contains "Strata gets none of it" "gpu-env" "$(mock_calls)"
HOST_GPU_STATE="" HOST_GPU_VENDOR="" HOST_GPU_RENDER_NODE=""
mock_reset_log
run_target_provisioner hermes
assert_eq "a companion gets the router CT, the router's template and the token" \
  "provision hermes|914|192.0.2.94/24|192.0.2.1|t-store|vmbr2|local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst|||910|8080|match|" "$(mock_calls)"
assert_not_contains "the token is never an argument" "owui-admin-secret" "$(mock_calls)"
COMFYUI_CT_ID=917; COMFYUI_IP_CIDR=192.0.2.97/24; COMFYUI_STORAGE=t-store
COMFYUI_COMMUNITY_SCRIPT_SHA256=def456
COMFYUI_IMAGE_VARIANT=klein-4b
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
run_target_provisioner() { echo "run $1" >> "$MOCK_LOG"; [[ " ${FAKE_FAIL:-} " != *" $1 "* ]]; }
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
assert_contains "the target is marked incomplete" "strata         CT 912    failed (router key apply)" "$(cat "$_out")"
assert_contains "the summary gives the apply command" "pct exec 910 -- /usr/local/bin/manage-model-servers apply" "$(cat "$_out")"
assert_contains "companions still run after an apply failure" "run hermes" "$(mock_calls)"
mock_reset_log
FAKE_FAIL=strata provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a failed target fails the run" 1 "$_rc"
assert_contains "and says how to retry it" "rerun targets/strata/provision-lxc.sh" "$(cat "$_out")"
assert_contains "while the others still run" "run hermes" "$(mock_calls)"
assert_not_contains "and no key is applied for it" "manage-model-servers apply" "$(mock_calls)"
FAKE_NO_TOKEN=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "no admin key fails the run" 1 "$_rc"
assert_contains "and the companions are skipped, not run" "skipped (no Open WebUI admin key)" "$(cat "$_out")"
FAKE_KEY_FAIL=1 provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "a key the router did not get is a failure to fix" 1 "$_rc"
assert_contains "named in the summary" "ok (router key not set)" "$(cat "$_out")"
TARGETS="gitea ollama"; SERVICES_DONE="gitea "
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "services done before the router are not run again" "run ollama" "$(mock_calls)"
assert_contains "but are in the summary" "ok (created before the router)" "$(cat "$_out")"
TARGETS="ollama comfyui"; SERVICES_DONE=""
mock_reset_log
provision_selected_targets > "$_out" 2>&1; _rc=$?
assert_eq "ComfyUI is added once Open WebUI is up and the admin key is known" \
  "$(printf '%s\n' 'run ollama' wait token 'run comfyui')" "$(mock_calls)"
assert_contains "and is in the summary" "comfyui        CT 917    ok" "$(cat "$_out")"
assert_eq "and count as success" 0 "$_rc"
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
  LLAMACPP_CT_ID LLAMACPP_IP_CIDR LLAMACPP_STORAGE HERMES_CT_ID HERMES_IP_CIDR HERMES_STORAGE MAYA_IP_CIDR
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

describe find_next_ct_id
mock_script pct <<'EOF'
[ "$1" = "status" ] && { case "$2" in 100|101) exit 0;; *) exit 1;; esac; }
exit 0
EOF
mock_script pvesh <<'EOF'
if [[ "$*" == *"--vmid "* ]]; then
  case "${*: -1}" in 100|101|151) exit 1;; *) exit 0;; esac
fi
echo 102
EOF
CT_ID=""
assert_eq "uses pvesh nextid when free" "102" "$(find_next_ct_id)"
CT_ID="150"
assert_eq "honours an explicit free CT_ID" "150" "$(find_next_ct_id)"
CT_ID="100"
assert_fail "rejects an occupied CT_ID" find_next_ct_id
CT_ID="151"
assert_fail "rejects an ID occupied on another cluster node" find_next_ct_id
CT_ID="abc"
assert_fail "rejects a non-numeric CT_ID" find_next_ct_id
CT_ID="151"
assert_contains "a refused ID names every cause" "is in use or not available in this cluster" \
  "$(find_next_ct_id 2>&1)"
CT_ID=""
# A pvesh that cannot answer is an error at once, never an endless scan.
_broken="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$_broken/pvesh"
printf '#!/bin/sh\nexit 1\n' > "$_broken/pct"
chmod +x "$_broken/pvesh" "$_broken/pct"
_rc=0
_msg="$(env PATH="$_broken:$PATH" timeout 10 bash -c 'source "$1"; CT_ID=""; find_next_ct_id' _ "$FUNCS" 2>&1)" || _rc=$?
assert_eq       "a failing pvesh stops instead of looping" "1" "$_rc"
assert_contains "and says why" "Cannot read the cluster's guest list" "$_msg"
_rc=0
env PATH="$NO_PVESH_BIN" timeout 10 bash -c \
  'source "$1"; ct_id_free() { return 1; }; CT_ID=""; find_next_ct_id' _ "$FUNCS" \
  >/dev/null 2>&1 || _rc=$?
assert_eq       "without pvesh, a node with no free ID gives up" "1" "$_rc"
rm -rf "$_broken"; unset _broken _rc _msg

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

# The marker file is deleted again after the successful write.
mock_script curl <<'EOF'
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
out="$(seed_gitea_repo "$seedtree" TOKEN 2>&1)"
assert_contains "reports the failed file" "failed to seed" "$out"
assert_contains "still seeds the others"  "1 created"      "$out"

# Installer-owned code that differs is UPDATED (PUT with the blob sha); the
# user's config files are still never touched.
mkdir -p "${seedtree}/services/ollama-monitor"
echo "new code" > "${seedtree}/services/ollama-monitor/monitor.py"
_old_b64="$(printf 'old code\n' | base64 -w0)"
mock_script curl <<EOF
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
assert_contains "sets a timeout" "  timeout: 600" "$out"
assert_contains "falls back to the nearest tier" '- fast: ["medium", "large"]' "$out"
assert_contains "skips identical deployments"   '- medium: ["fast"]' "$out"
assert_not_contains "never names a tier without deployments" "xlarge" "$out"
assert_not_contains "a single tier has no fallbacks" "fallbacks" "$(printf 'fast q@a\n' | litellm_router_settings)"

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
