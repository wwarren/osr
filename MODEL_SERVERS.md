# Managing model servers

`manage-model-servers` exists only in the router CT, as
`/usr/local/bin/manage-model-servers` → `/app/config-repo/install/manage-model-servers.sh`
(recreated by every `apply`, so a config-repo update updates it). Run it as
root:

```bash
pct enter <CT_ID>; manage-model-servers list                     # inside the CT
pct exec <CT_ID> -- /usr/local/bin/manage-model-servers list     # from the host
bash /path/to/clone/install/manage-model-servers.sh list         # from a clone on the host: finds the CT (CT_ID=<id> skips the search)
```

`<CT_ID>` is printed at the end of the install and shown by `pct list`
(`open-smart-router` unless `CT_NAME` was set; `ollama-smart-router` on an
install from before the rename). Writing commands take the
config lock; `--apply` validates, applies and health-checks
([Applying changes](CONFIGURATION.md#applying-configuration-changes)).

```bash
manage-model-servers list | status | discover | models     # config, live probe, router inventory, tags per host
manage-model-servers add 10.0.0.55 --tier large --apply      # probed before it is accepted (--no-probe skips)
manage-model-servers add lmstudio://10.0.0.9:1234 --tier fast   # or --type <kind>
manage-model-servers remove 10.0.0.55 --apply                # by address or list number
manage-model-servers set-tier large 10.0.0.54 10.0.0.55 --apply
manage-model-servers set-model large qwen3:32b --apply       # every server in the tier
manage-model-servers set-server-model large 10.0.0.54 llama3.3:70b --apply   # one server
manage-model-servers add-model xlarge qwen3:235b --apply     # one more model in a tier
manage-model-servers remove-model xlarge qwen3:235b --apply
manage-model-servers set-keepalive 2h --apply
manage-model-servers set-api-key [key|--generate|--off]
manage-model-servers set-<kind>-token [token|--off]          # lmstudio, strata, basalt, maya, xolotl, avalon, kindi, colibri
manage-model-servers set-cloud-key <openai|anthropic|gemini> [key|--off]
manage-model-servers set-cloud-models <openai|anthropic|gemini> <id[,id...]|--off>
manage-model-servers set-freellmapi <url|--off> [key]      # FreeLLMAPI: freellmapi/<id>, explicit only
manage-model-servers set-token | set-webhook [url] | test-alert [message]
manage-model-servers set-webui-version [version|latest] [--apply]
manage-model-servers apply [--all] | commit [message]
manage-model-servers clear-lock [--force]
```

Servers are keyed by URL, so removing one never re-points a tier. Models are
set per (tier, server) and checked on the server first; pass full Ollama names
without `ollama/` (e.g. `smtek/Qwen3.8-27B:Q3_K_XL-16gb`). A tier's models
drive the LiteLLM fallback and keep-alive pinning, and are the tier's first
choice in discovery routing (below). `commit` pushes with the deploy token from
`secrets.env` (replace with `set-token`).

## Several models in one tier

A tier can hold several models, on one server or spread over several. Each is
offered by name in Open WebUI's model list (from `/v1/models`), and `auto` and
the tier alias spread the tier's requests across all of them:

```bash
manage-model-servers set-tier xlarge 10.0.0.54 maya://10.0.0.9 10.0.0.56 --apply
manage-model-servers add-model xlarge llama3.3:70b --apply          # on every xlarge server that has it
manage-model-servers add-model xlarge glm-5.3-flash maya://10.0.0.9 --apply   # on the server named
manage-model-servers set-server-model xlarge 10.0.0.56 qwen3:235b,deepseek-r1:671b --apply
manage-model-servers remove-model xlarge deepseek-r1:671b --apply
manage-model-servers list                                            # one row per server, every model on it
```

`set-model` and `set-server-model` take a comma list; `add-model` adds one
model, on the servers named or else on every server of the tier that lists it
(`--no-probe`: on all of them); `remove-model` takes one out, and a server
keeps at least one. Each model becomes its own LiteLLM deployment under the
tier alias.

In discovery routing (`router.ini [balancing] tier_models = true`, the
default) the models assigned to a tier fit it whatever their size, score alike
and get `[weights] tier_member` (0.2) ahead of any model that is only the
right size. A request of that class therefore takes them in turn across every
server serving one of them, the least busy first. A conversation keeps its
model and server for `sticky_seconds`; an agent task (a request with tools)
keeps one model while each new task takes the next. Code, vision and tool
needs still decide first, and a resident model still wins over one that would
have to load (`loaded_bonus`), so keep them all loaded (`set-keepalive`) or
give each its own host. The router reads the assignments from
`litellm_config.yaml` and follows a change without a restart;
`/routing/inventory` shows them under `tier_models`, and `/routing/explain`
lists each candidate's `tiers`. `tier_models = false` goes back to sizes
alone.

## Server kinds

Non-Ollama servers are stored with a kind prefix (`maya+http://host:8080`);
`add` accepts `kind://host` or `--type kind`. A bare address is detected
without sending a key: Ollama `/api/tags`, the public `/health` markers of
Strata, Basalt, Maya, Xolotl (Strata's server, told apart by its DeepSeek-V4
model) and Kindi (`"kindi": "<version>"`), then LM Studio, trying each kind's
default port. Avalon is identified from `/v1/models` (`"owned_by": "llamacpp"`
and an Avalon id), which needs its key once set, so add a keyed Avalon as
`avalon://host`. Colibri is identified the same way (`"owned_by": "colibri"`),
so add a keyed Colibri (every one the target installs) as `colibri://host`.
Set the token before adding a keyed server, so the probe can
authenticate; a keyed server that cannot identify itself is added as
`kind://host` (or with `--no-probe`).

| Kind | Default port | Token (`secrets.env`) | Notes |
|---|---|---|---|
| Ollama (also llama.cpp bridge, AirLLM) | 11434 | — | Keep-alive pinned by the monitor |
| LM Studio | 1234 | `set-lmstudio-token` | Resident models preferred; `lmstudio_loaded_only = true` never triggers a just-in-time load. Names differ (`qwen/qwen3-14b`); set LM Studio's own idle TTL. Context counts per request: `context_length / parallel` unless `lmstudio_unified_kv = true` |
| Strata | 8080 | `set-strata-token` | Must listen on a reachable address (below); `strata://host:11434` for that port |
| Basalt | 8080 | `set-basalt-token` | Model ID `BASALT_ALIAS` (default `qwen3.8-flash-next`) |
| Maya | 8080 | `set-maya-token` | Model ID `glm-5.3-flash` |
| Xolotl | 8080 | `set-xolotl-token` | `XOLOTL_MODEL_NAME` (default `deepseek-v4.1-flash`, sized 552B) |
| Avalon | 8080 | `set-avalon-token` | `AVALON_MODEL_NAME` (default `qwen3.8-flash-next-avalon`, sized 125B) |
| Kindi | 8093 | `set-kindi-token` | `bonsai2-<size>` or `nanbeige-33b-iq3`, sized from the id; one request at a time |
| Colibri | 8080 | `set-colibri-token` | `<model>-colibri` ids, sized from the id or `[model_sizes]`; tool calls on every chat engine but Inkling and OLMoE; image and decision models are not offered for chat |

```bash
manage-model-servers set-maya-token --apply
manage-model-servers add maya://10.0.0.9 --tier xlarge --apply
manage-model-servers set-server-model xlarge maya://10.0.0.9 glm-5.3-flash --apply
```

A Strata you run yourself (not the [Strata target](targets/strata/README.md))
binds to `127.0.0.1` by default. Run its setup (`./setup.sh`, or
`START-HERE.bat` on Windows) with `--host` set to a reachable address,
`--port 11434` if wanted and `--api-key`
([options at the tested commit](https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/docs/INSTALL.md#options-without-questions));
the newer launcher on `main` uses `strata launch --access lan` and
[creates a key by default](https://github.com/Niko1221/Strata/blob/main/docs/TERMINAL_LAUNCH.md).
The Strata-style kinds load models themselves (no keep-alive), and the monitor
counts them down while `/v1/models` is empty (engine not running).

## Model sizes for unsized IDs

Strata, Basalt, Maya, Xolotl, Avalon and most Colibri models report no
parameter count (Kindi's ids include it). `[model_sizes]` in `router.ini` maps exact IDs
(case-insensitive) to a size; built-in entries include:

```ini
[model_sizes]
strata = 125B
qwen3.8-flash-next = 125B
# ... and its -q2_0, -iq2_xs, -iq3_xxs and -iq3_s quant IDs
qwen3.8-flash-next-avalon = 125B
glm-5.3-flash = 321B
deepseek-v4.1-flash = 552B
```

Add a line for a custom alias; a blank value removes a built-in. A size in the
ID (`coder:62b`) or a reported `parameter_size` wins. The older `[discovery]
*_default_params` / `*_default_id` keys are still read.

## Keeping models loaded

Ollama unloads idle models after ~5 minutes and its OpenAI endpoint ignores
`keep_alive`. With `OLLAMA_KEEP_ALIVE` set (at install, or `set-keepalive
30m|2h|-1|0|<seconds> --apply`), LiteLLM sends `keep_alive` on native calls and
the monitor calls each up Ollama host's `/api/chat` with an empty message every
240 s (`monitor.ini [keep_alive] refresh_seconds` or
`KEEP_ALIVE_REFRESH_SECONDS`), keeping each tier's models loaded: every model
`litellm_config.yaml` assigns to a tier on that host. Blank (the
default) sends nothing and leaves each server's own setting in charge.

Hosts are refreshed side by side. A host that serves several tiers with
different models gets all of them, as long as it can hold them together. If
loading one unloads another, the monitor logs that the host "cannot hold them
together" and from then on only refreshes the tier models that are loaded
(loading the first when none is), so the models in use are not swapped out
every 240 s. Give each tier its own host, or the same model, to keep them all
loaded.

