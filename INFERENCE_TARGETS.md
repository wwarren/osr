# Inference targets

Each target has a host-side `provision-lxc.sh` (with `--dry-run`), a guest-side
`install-target.sh` (also `--upgrade`) and a README with requirements,
settings and recovery steps.

| Target | Register as | Port | Key requirement |
|---|---|---|---|
| [Ollama](targets/ollama/README.md) | Plain address | 11434 | NVIDIA, AMD, Intel or CPU |
| [llama.cpp](targets/llamacpp/README.md) | Plain address | 11434 (monitor dashboard on 8082) | One GGUF; CUDA, Vulkan or CPU |
| [AirLLM](targets/airllm/README.md) | Plain address | 11434 | Large disk; slow, give it its own tier |
| [Strata](targets/strata/README.md) | `strata://` | 8080 | NVIDIA |
| [PolyStrata](targets/polystrata/README.md) | `polystrata://` | 8080 | NVIDIA; Qwen3.8-Flash-Next on the Strata engine or 14 experimental families (GLM 5.3 Flash, DeepSeek V4 Flash, Gemma 4, Qwen3.6, Ornith, ...) on its own, chosen from a family and size menu with setup's RAM estimates; 11 to 190 GB downloads |
| [Basalt](targets/basalt/README.md) | `basalt://` | 8080 | Blackwell (sm_120), CUDA 13 |
| [Maya](targets/maya/README.md) | `maya://` | 8080 | NVIDIA; CUDA must suit CT and card |
| [Xolotl](targets/xolotl/README.md) | `xolotl://` | 8080 | NVIDIA 24 GB; ~372 GB of pinned weights |
| [Avalon](targets/avalon/README.md) | `avalon://` | 8080 | AMD RX 7000 (ROCm) or NVIDIA, experts in RAM; ~90 GiB of pinned weights |
| [Kindi](targets/kindi/README.md) | `kindi://` | 8093 | Old or small NVIDIA (from a 1 GB Kepler) or CPU; one request at a time |
| [Colibri](targets/colibri/README.md) | `colibri://` | 8080 | Large MoE models with experts across GPU, RAM and NVMe; CPU, NVIDIA (CUDA) or AMD/Intel Arc (Vulkan); a menu of colibri's 12 pinned models, grouped chat-from-RAM, chat-from-disk and images, with a suggestion per group from the CT's RAM, disk and GPU, changeable later with `provision-lxc.sh --reconfigure`; colibri's web dashboard at `http://<CT>:8080/` |

Services and companions use separate CTs and stay out of the model pool:

| Target | Role and operational note |
|---|---|
| [Gitea](targets/gitea/README.md) | Configuration history; optional |
| [Mattermost](targets/mattermost/README.md) | Health alerts and, with hcom, a separate handoff channel; optional |
| [Honcho](targets/honcho/README.md) | CPU-only agent memory and Open WebUI MCP tools, enabled for all Open WebUI users (`HONCHO_WEBUI_ACCESS=keep`: admin-only; a private memory per Open WebUI user and per agent, each client with its own key), with its own embedding model. Needs a router model with tools and structured output; its proxy dispatches directly to model hosts. Reconfigure after key rotation |
| [Hermes](targets/hermes/README.md) | Open WebUI agent `hermes-agent`; direct dispatch needs tools and 64K context. Reconfigure after key rotation or host changes |
| [OpenClaw](targets/openclaw/README.md) | Open WebUI agent `openclaw` and Control UI on :18789; same dispatcher. Reconfigure after key rotation or host changes |
| [DeepSeek Harness](targets/deepseek-harness/README.md) | Agent Web UI on :3080 using OSR as provider, also offered in Open WebUI as `deepseek-harness` through an OpenAI-compatible chat endpoint (:3081) over Harness's ACP server; installed without Open WebUI when no admin key is given |
| [OpenCode](targets/opencode/README.md) | Coding agent with its own web UI on :4096 (password-protected), also offered in Open WebUI as `opencode` through an OpenAI-compatible chat endpoint (:4097); Hermes's dispatcher, needs tools and 32K context. Reconfigure after key rotation or host changes |
| [Open Terminal](targets/open-terminal/README.md) | Open WebUI terminal connection, enabled for all users with an isolated workspace each (`OPEN_TERMINAL_WEBUI_ACCESS=keep`: admin-only); agents get their own through `OPEN_TERMINAL_URL` (MCP) |
| [ComfyUI](targets/comfyui/README.md) | Open WebUI image engine on :8188; FLUX.2 Klein 9B needs an accepted Hugging Face license and token |
| [FreeLLMAPI](targets/freellmapi/README.md) | Free cloud tiers behind one key on :3001, offered as `freellmapi/<id>` and used only when named ([below](CLOUD_MODELS.md#freellmapi-free-cloud-tiers)); its CT is made from the container image (Proxmox VE 9.1) |

Honcho reaches Hermes, OpenClaw and OpenCode through their memory plugins and
DeepSeek Harness through MCP tools.

## Proxmox tags

Each installer tags the CT it creates. `osr-target` marks every CT installed
alongside the router; the last tag is the target's directory name under
`targets/`.

| CT | Tags |
|---|---|
| Router | `ai`, `ai-tools`, `osr-router`, `openwebui` |
| Ollama, llama.cpp, AirLLM, Strata, PolyStrata, Basalt, Maya, Xolotl, Avalon, Kindi, Colibri, ComfyUI, FreeLLMAPI | `ai`, `ai-model`, `osr-target`, `<target>` |
| Gitea, Mattermost, Honcho, Open Terminal, Hermes, OpenClaw, DeepSeek Harness, OpenCode, MQTT | `ai`, `ai-tools`, `osr-target`, `<target>` |

`tools/upgrade-all.sh` finds CTs only by these tags (`osr-router`, and
`osr-target` plus the target's name), so every provisioner makes sure they are
there:

- A CT made with `pct create` gets them at creation.
- Community-script CTs (Ollama, ComfyUI, Gitea, Mattermost) also get
  `community-script`. Because the script's menus can change or drop the tags it
  was given, the provisioner adds any that are missing once the script is done.
- `--reconfigure` (Gitea, Mattermost, Honcho, Hermes, OpenClaw, DeepSeek Harness,
  OpenCode, MQTT, llama.cpp) adds any missing tags to the existing CT, so a CT made by hand or by an
  older version becomes visible to the upgrade.

Missing tags are added and the CT's other tags are kept (`pve_ensure_tags` in
`targets/pve-select.sh`). `--integrate-only` leaves the CT as it is. For any
other CT, add the tags yourself: `pct set <id> --tags 'ai;ai-model;osr-target;ollama'`.
hcom creates no CT. The lists live in each `provision-lxc.sh` and the router
installer; `tests/test-repo.sh` checks that they match `upgrade-all.sh`'s
targets. Keep this table in step with them.

## Provisioner questions

On a terminal, the provisioners used by the main installer ask in sections and
confirm a summary before changing anything:

```
== Router ==
  Router CT ID or address [280]:
== Hermes container ==
  New Hermes CT ID (unused) [282]:
  (numbered template and storage menus)
  Hermes IP/CIDR: 192.0.2.82/24
  Hermes gateway [192.0.2.1]:
== Hermes settings ==
  OSR model or tier [auto]:
  Context window the model serves (tokens) [65536]:
  Offer Hermes in Open WebUI (as hermes-agent)? [Y/n]:
  Run the Hermes dashboard? [Y/n]:
== Honcho memory ==
  Honcho API URL (none to skip) [http://192.0.2.85:8000]:
== Hermes: create ==
  Router                     CT 280, http://192.0.2.80:8000
  Hermes CT                  282 (hermes-target), ...
Create Hermes CT 282? [Y/n]:
```

- **Router first, then the target.** The router is offered from the CT tagged
  `osr-router`; the new CT's ID, template, storage, address and gateway follow
  (the gateway offered from the router's network), then the target's settings.
- **Enter takes the value in brackets.** A new CT's ID defaults to the
  cluster's next free ID (`pvesh get /cluster/nextid`): Enter takes it, typing
  another or presetting `CT_ID` overrides it, and an unattended run uses it
  and says so (dry runs query nothing, so they need `CT_ID`). An existing CT
  or gateway is only offered to a person, and addresses are always typed.
  Optional settings accept `none`.
- **`--reconfigure` starts from what is installed.** It asks for the CT
  (offering the one with the target's tag), then the router it uses, and every
  setting shows the running CT's recorded value, so Enter keeps it.
- **Environment variables win.** Preset variables are not asked. Without a
  terminal (or with `NONINTERACTIVE=true`), missing required settings stop the
  run naming the variable, and `--reconfigure` keeps recorded settings.
  `PVE_CONFIRM=false` skips the confirmation; the router installer runs
  provisioners with `PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false`.

The llama.cpp provisioner also supports `--reconfigure` for an installed
target's model and runtime settings. Set `CT_ID` and pass only the settings to
change as environment variables; it keeps omitted settings. See
[llama.cpp reconfiguration](targets/llamacpp/README.md#upgrading).

The shared helpers are `targets/pve-select.sh`; each provisioner using them
keeps an identical copy (checked by `targets/test-pve-select.sh`). llama.cpp
and AirLLM keep their own container prompts in the same order; MQTT prompts
for missing values without the confirmation flow; hcom asks for its target and
CT IDs (offered by tag; a reconfigure defaults to the CT's recorded settings). Review `--dry-run` output first.

