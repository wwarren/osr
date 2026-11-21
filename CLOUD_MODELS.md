# Cloud API models

Selected OpenAI, Anthropic and Google Gemini API models can be offered beside
local ones. Clients pick them explicitly as `openai/<id>`, `anthropic/<id>` or
`gemini/<id>`; `auto` and the tier aliases stay local. Cloud requests go
through LiteLLM (`X-Router-Mode: cloud`); provider keys stay in
`/app/router/secrets.env`. A configured cloud ID wins over a local model of the
same name; an unconfigured prefixed name still reaches a local server listing
it (LM Studio's `openai/gpt-oss-20b`), else 404 `cloud_model_not_configured`.

```bash
manage-model-servers set-cloud-key gemini       # prompts twice without echo
manage-model-servers set-cloud-models gemini '<Gemini-API-model-id>' --apply
manage-model-servers set-cloud-key openai
manage-model-servers set-cloud-models openai '<OpenAI-API-model-id>' --apply
manage-model-servers set-cloud-key anthropic
manage-model-servers set-cloud-models anthropic '<Claude-API-model-id>' --apply
```

IDs (comma-separated) are stored in `env/router.env` as
`CLOUD_OPENAI_MODELS`, `CLOUD_ANTHROPIC_MODELS` and `CLOUD_GEMINI_MODELS`; a
model appears in `/v1/models` only when its key is also set. `--off --apply`
clears a list or key. Cloud deployments in `litellm_config.yaml` are rebuilt on
every regeneration. Get keys and model IDs from the
[OpenAI platform](https://platform.openai.com/docs/models),
[Anthropic Console](https://docs.anthropic.com/en/docs/about-claude/models/overview)
or [Google AI Studio](https://ai.google.dev/gemini-api/docs/models); these use
API billing, so check account limits first.

## FreeLLMAPI (free cloud tiers)

The [FreeLLMAPI target](targets/freellmapi/README.md) runs
[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi), which fronts the free
tiers of many providers with one key and falls back between them. The router
lists `freellmapi/auto` and every model it can serve now as
`freellmapi/<id>` (refreshed every five minutes; `FREELLMAPI_MODELS=auto`
lists only `freellmapi/auto`), and sends a request naming one straight to
FreeLLMAPI with its own key (`X-Router-Mode: freellmapi`). Like the cloud
models these are explicit only: `auto`, the tiers and LiteLLM fallbacks never
use them, and their prompts leave your network. The provisioner registers the
endpoint; by hand:

```bash
manage-model-servers set-freellmapi http://<freellmapi-ct>:3001 --apply   # key from its dashboard, asked twice
manage-model-servers set-freellmapi --off --apply
```

`FREELLMAPI_BASE_URL` is in `env/router.env`, the key in `secrets.env`. Without
both, a `freellmapi/` request gets 404 `freellmapi_not_configured`.

## Signed-in subscription clients

LiteLLM documents per-client pass-through for
[Codex with a ChatGPT login](https://docs.litellm.ai/docs/tutorials/openai_codex_byok) and
[Claude Code with a Claude subscription](https://docs.litellm.ai/docs/tutorials/claude_code_max_subscription).
That needs a newer LiteLLM gateway with PostgreSQL, `chatgpt/*` or
`anthropic/*` deployments, a gateway virtual key and each client's login, run
separately from this project's pinned LiteLLM. Set its root URL (no `/v1`;
HTTPS or loopback HTTP) as `SUBSCRIPTION_GATEWAY_BASE_URL` in `env/router.env`
and apply. Point Codex at `http://<ct-ip>:8000/v1` and Claude Code at
`ANTHROPIC_BASE_URL=http://<ct-ip>:8000` (no `/v1`), sending on every request:

| Header | Value |
| --- | --- |
| `x-router-subscription` | `1` (selects the gateway) |
| `x-router-api-key` | OSR's `ROUTER_API_KEY`, bare (keep `Authorization` for the client login) |
| `x-litellm-api-key` | The gateway's virtual key |

The router forwards chat, Responses, Anthropic Messages and model-list
requests unchanged (`X-Router-Mode: subscription`), passing the client's
`Authorization` and removing its own two headers. Without `ROUTER_API_KEY` it
answers 503 `subscription_auth_not_configured`; without a valid gateway URL 503
`subscription_gateway_not_configured` (an invalid URL is logged at start).
Configure headers with Codex's `http_headers`/`env_http_headers` or Claude
Code's `ANTHROPIC_CUSTOM_HEADERS`. Never put a browser session or CLI OAuth
credential in `secrets.env`. Open WebUI's shared connection cannot carry
per-user logins. [Gemini CLI disallows third-party use of its OAuth
login](https://geminicli.com/docs/faq/); use a Gemini API key.

