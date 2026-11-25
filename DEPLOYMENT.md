# Deployment

An unprivileged Debian 13 CT (default 2 vCPU, 4 GB RAM, 32 GB disk) running
the router services as `osr-router`, plus a small local metrics stack:

| Service | Unit | Port | Role |
|---|---|---|---|
| Smart Router | `osr-router.service` | 8000 | OpenAI API; picks a model and host per request |
| Open WebUI | `open-webui.service` | 8080 | Chat UI; talks to the router |
| LiteLLM | `litellm-proxy.service` | 127.0.0.1:4000 | Static tier fallback, cloud models and non-chat `/v1` routes |
| Health monitor | `osr-monitor.service` | — | Probes hosts and local services, alerts to Mattermost, keeps Ollama models loaded |
| Prometheus | `osr-prometheus.service` | 127.0.0.1:9090 | Scrapes the router every 15 seconds with its API key; retains up to 7 days or 512 MB of blocks |
| Grafana | `grafana-server.service` | 3000 | Authenticated dashboard for router metrics |

Normal request path: **client or Open WebUI → router :8000 → model host**.
LiteLLM serves static tiers only when discovery is off or the inventory is
empty. The pool can mix Ollama, LM Studio, llama.cpp, AirLLM, Strata, PolyStrata,
Basalt, Maya, Xolotl, Avalon, Kindi and Colibri. Optional service, model and companion CTs are
listed under [Inference targets](INFERENCE_TARGETS.md#inference-targets); standalone
[MQTT and hcom targets](AGENT_COORDINATION.md#agent-coordination-targets) connect agents across
containers.

