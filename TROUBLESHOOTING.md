# Troubleshooting

Inside the router CT (`pct enter <CT_ID>`):

```bash
KEY=$(sed -n 's/^ROUTER_API_KEY=//p' /app/router/secrets.env)
systemctl status open-webui osr-router litellm-proxy osr-monitor
manage-model-servers status           # configured hosts + live probe
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/routing/inventory
journalctl -u osr-router -f        # decisions for chats sent to /v1/chat/completions
```

Hermes (`custom:osr`, including `auto`) and OpenClaw (`osr`) use the router
only for inventory and ranking and send chat directly from their CTs: their
decisions are in `journalctl -u hermes-direct -f` or `-u openclaw-direct -f`
there. The router shows their inventory and `/routing/explain` requests but no
`route class=` line for those chats.

| Symptom | Cause / fix |
|---|---|
| Installer: no storage found | The storage lacks `rootdir`: `pvesm set <storage> --content rootdir,images`. Storage smaller than `ROOTFS_GB` is listed but not selectable |
| Installer: Gitea 401 or TLS error | Use the final URL (community CT `http://<ip>:3000`, TurnKey HTTPS 443), no redirects. The installer diagnoses DNS, connection, TLS and token errors; after 3 bad tokens it uses local mode |
| `open-webui==… (from versions: none)` | Open WebUI needs Python 3.11–3.12. The installer provisions 3.12 (system package, else `uv` into `/opt/python`, needing PyPI/GitHub); otherwise install 3.12 by hand and rerun |
| Open WebUI venv ~7.5 GB | `TORCH_CPU_ONLY=false`, or `download.pytorch.org` was unreachable; `apply` installs CPU torch and purges `nvidia-*`/`triton` wheels |
| Open WebUI shows no models / 401 | The router key changed: paste it into Admin Settings > Connections > OpenAI |
| A host or its models are missing | `/routing/inventory` shows the error: a wrong or missing `set-<kind>-token` (401), a Strata-style engine not running (empty `/v1/models`), or a server bound to `127.0.0.1`. A refused connection removes a host until its next good poll |
| Following one request | Take `X-Router-Request-ID` from the answer (or send your own `X-Request-ID`) and grep the router's journal for it; `/metrics` shows failures per server and reason |
| Request went to an unexpected model | Check the `X-Router-*` headers or `POST /routing/explain`. `model-unavailable`: the named model's hosts were down. Unknown sizes score low: add `[model_sizes]` |
| Long prompt fails with 4xx | Context windows are not considered and 4xx does not fail forward; use a larger-context model |
| "does not support tools" | No model reports tools (`X-Router-Warning: no-tool-model`); check `tools` in `/routing/inventory`; for llama.cpp add `tools` to `MODEL_CAPABILITIES` |
| Models unload after ~5 min | Set `OLLAMA_KEEP_ALIVE`, or on the host put `Environment="OLLAMA_KEEP_ALIVE=2h"` in the unit, `daemon-reload` and restart |
| No Mattermost alerts | `journalctl -u osr-monitor` shows rejected webhooks; `set-webhook`, `test-alert`. Alerts fire after 3 failed checks, recover after 2; the startup notice is at most hourly |
| hcom cannot connect across CTs | `osr-bus status` as the agent, broker `MQTT_CLIENT_CIDR`, agent egress rules, credentials, TLS trust; `journalctl -u osr-hcom-relay` (agent) and `-u mosquitto` (broker) |
| No Mattermost handoff posts | `journalctl -u osr-hcom-mattermost` in the observer CT; check its webhook and outbound HTTP(S); one observer per group |
| `apply` failed | The snapshot was restored and services restarted on the old files; read the reported check and `journalctl -u <unit>`. Snapshots: `/var/backups/open-smart-router/` |
| "config is locked" | Another change is running. For a hung one, `clear-lock` shows and `--force` stops it; then `git -C /app/config-repo status` and rerun `apply` |
| Target upgrade failed | The installer says whether the previous version is "running again"; else `journalctl -u <unit>` in the target CT. llama.cpp, AirLLM and Ollama keep replaced files as `*.prev`; the Strata-style targets keep their snapshot in `/var/lib/<target>-target/` when rollback fails. Basalt, Maya and Xolotl need a CUDA release the distro's NVIDIA repository carries (Debian 13 starts at 13.1: no V100 for Maya; `CUDA_VERSION=13.1` for Basalt) or an installed toolkit |

