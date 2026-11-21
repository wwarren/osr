# How routing works

The router polls configured hosts every 60 s, classifies the newest user
message as `fast`, `medium`, `large` or `xlarge`, and scores each host/model
pair by size, code or vision fit, tool support and residency. A server loses a
little for each request the router already has in flight there, so an equally
good idle server is used first. Among equal choices a conversation keeps the
server and model that answered it last (its prompt cache is there); the rest
rotate. `[balancing]` in `router.ini` sets both (`busy_penalty`,
`sticky_seconds`; 0 turns either off). A named model is used if available; `auto` and tier aliases let the
router choose; embedding models are never used for chat. The models assigned
to a tier ([Several models in one tier](MODEL_SERVERS.md#several-models-in-one-tier)) are that
tier's first choice, whatever their size. Connect errors,
timeouts, 404s, 5xx and tool-support rejections try the next candidate until
streaming starts; other 400s go back to the client. With discovery off or an
empty inventory, LiteLLM serves static tiers (`X-Router-Mode: litellm`).
`X-Router-Model`, `-Server`, `-Class`, `-Mode`, `-Candidates` and `-Warning`
explain each choice, and `X-Router-Request-ID` names the request in the
router's log.

```text
POST /v1/images/generations  pictures from the image servers (the "image" alias), below
GET  /v1/images/models    the image alias, image models and configured cloud image models
GET  /metrics             Prometheus metrics (below)
GET  /routing/inventory   host models, image models, capabilities, context, errors and requests in flight
POST /routing/refresh     poll now and ask every Ollama model for its capabilities again (?probe=false: poll only)
POST /routing/explain     {"prompt": "..."} -> scored candidates
GET  /healthz             unauthenticated liveness
```

Capabilities and context come from Ollama's `/api/show`, asked once per model
digest and again after `[discovery] show_cache_seconds` (an hour): a re-pulled
or re-created model is asked at once, and `POST /routing/refresh` asks all of
them. Tune thresholds, keywords, weights, timeouts and sizes in
`services/osr-router/router.ini`; the rules are in
[ARCHITECTURE.md](ARCHITECTURE.md#5-request-routing).

**Binding.** The router reads `ROUTER_HOST`/`ROUTER_PORT` (default
`0.0.0.0:8000`; the installer sets neither). To change them, set them in
`env/router.env`, then update `OPENAI_API_BASE_URLS` in `env/openwebui.env`
(and Open WebUI's saved connection under **Admin Settings > Connections**),
`osr-router` (`ollama-router` in a `monitor.ini` from before the rename) in
`monitor.ini [local_services]`, the CT firewall and clients.
Management health checks use `ROUTER_URL` (default `http://127.0.0.1:8000`):
set it when running `apply`, `discover` or the updater inside the CT (the
host-side wrappers do not forward it). Reconfigure Hermes and OpenClaw: their
`--reconfigure` derives `ROUTER_URL` from the router's IP and `ROUTER_PORT`
unless you pass it, and does not remember a custom URL.

**API key.** New installs generate `ROUTER_API_KEY`; without one on a
non-loopback address the router logs a warning. For an older install run
`manage-model-servers set-api-key --apply` and paste the key into Open WebUI
**Admin Settings > Connections > OpenAI**.

## Request IDs and metrics

**Request IDs.** Every answer carries `X-Router-Request-ID`. It is the
caller's own `X-Request-ID` when that is a plain token (letters, digits and
`. _ : -`, up to 64 characters), otherwise 16 random hex digits. The same
value is returned as `X-Request-ID` (where OpenAI clients look for it) unless
the upstream answer already has one, is sent to the model server or LiteLLM as
`X-Request-ID`, and starts every line the router logs for the request:

```bash
journalctl -u osr-router | grep -F '[4c1f0e6a9b2d7730]'   # the decision and every failover of one request
```

**Metrics.** `GET /metrics` serves Prometheus text format. Like every path but
`/healthz` it needs the router key, because the labels name your servers and
models. The values start at zero with each router start and count only what
goes through the router (not what agents send a server directly).

| Metric | Labels | Meaning |
|---|---|---|
| `osr_requests_total` | `route` (`chat`, `v1`, `routing`), `mode`, `class`, `model`, `server`, `status` | Requests answered, with the HTTP status returned. Refused and failed ones have empty `model` and `server` |
| `osr_upstream_failures_total` | `server`, `reason` (`connect`, `transport`, `no_reply`, `http_<status>`, `tool_rejection`) | Attempts on a model server that failed, whether or not another server then answered |
| `osr_response_start_seconds` | `mode`, `model`, `server` | Histogram: chat requests answered below 400, from arrival until the response headers went out |
| `osr_request_duration_seconds` | `mode`, `model`, `server` | Histogram: the same requests, until the last byte of the body |
| `osr_in_flight_requests`, `osr_server_up`, `osr_server_models` | `server` (`osr_server_up` also `kind`) | Per model server: the router's requests in flight, up (1) or down (0), models listed |
| `osr_inventory_age_seconds`, `osr_remembered_conversations`, `osr_start_time_seconds` | — | Seconds since the last discovery poll, conversations with a remembered server, start time |

```yaml
scrape_configs:
  - job_name: osr
    authorization:
      credentials_file: /etc/prometheus/osr-router-key   # ROUTER_API_KEY, alone on one line
    static_configs:
      - targets: ['<ct-ip>:8000']
```

`/healthz` and `/metrics` themselves are not counted. No label is taken from a
request, so the number of series stays bounded by your servers and models.

## Local Grafana dashboard

New router installs install Prometheus and Grafana in the router CT
(`INSTALL_METRICS=false` leaves them out). Prometheus
scrapes `GET /metrics` on the CT's loopback address using a protected copy of
`ROUTER_API_KEY`; its HTTP API stays on `127.0.0.1:9090`. Grafana has a
provisioned `OSR Prometheus` data source and an **Open Smart Router** dashboard
with an at-a-glance scrape, traffic, 5xx, server, model and inventory summary;
traffic and upstream failures by label; p50/p95 latency and per-model p95;
and in-flight load, server state, model counts and conversation affinity.
The dashboard also graphs host CPU and GPU temperatures in Celsius. The
installer starts a small exporter on the Proxmox host at port 9408 and adds a
second authenticated Prometheus scrape in the router CT. It reads Linux
`hwmon` CPU and AMD/Intel GPU sensors plus `nvidia-smi` for NVIDIA GPUs.
That host endpoint supplies `osr_cpu_temperature_celsius{driver,chip,sensor}` and
`osr_gpu_temperature_celsius{vendor,device,sensor}`. These series are served by
the host exporter, not by the router's own `/metrics` endpoint.
Unavailable sensors have no series; the router CT's virtual CPU temperature is
not used. The exporter accepts requests only from the router CT's IP and with
a separate bearer key. If the Proxmox host firewall is enabled, allow TCP 9408
from the router CT IP to the host bridge IP. The scrape key stays outside Git
in `/etc/osr-temperature-exporter/token` on the host and
`/etc/prometheus/osr-sensors-key` in the CT.

Open `http://<ct-ip>:3000` and sign in as `admin`. A new Grafana database starts
with a random password, kept in `/etc/grafana/osr.env` (root-readable). The
installer, `setup-metrics.sh install` and `tools/upgrade-all.sh` print the
address, user name and password at the end, ready to copy; to see them again:

```bash
pct exec <CT_ID> -- bash /app/config-repo/install/setup-metrics.sh login
```

The password is checked against Grafana first. Once you change it in Grafana
the first one is no longer shown, only a line saying it has changed.
`upgrade-all.sh` prints it to the terminal only, never to its logs. Use
`http://`: Grafana here has no TLS, and a browser that switches to `https://`
gets no answer.

The installer allows port 3000 from `API_ALLOW_CIDR` when it configures the CT
firewall. If Grafana package installation fails, the router keeps running; rerun
the setup inside the CT after fixing package access:

```bash
pct exec <CT_ID> -- bash /app/config-repo/install/setup-metrics.sh install
```

To add host temperatures to an existing metrics installation, run this on the
Proxmox host from an updated OSR checkout. Refresh the dashboard in the CT
first so its CPU and GPU panels are provisioned:

```bash
pct exec <router-ct-id> -- bash /app/config-repo/install/setup-metrics.sh install
CT_ID=<router-ct-id> BRIDGE=<host-bridge> ROUTER_IP=<router-ct-ip> \
  bash tools/setup-temperature-exporter.sh
```

This installs and starts `osr-temperature-exporter.service`, copies the scrape
key into the router CT, and updates the Prometheus scrape configuration. Check
`up{job="osr-temperature"}` in Grafana's Explore view; it should be 1.

For an existing router CT, first update its config repo using
`install/update-router.sh` as described under [Updating](UPDATING.md#updating),
then run the setup command above. Add a firewall allow rule for TCP 3000 from
your trusted CIDR if the CT firewall is enabled. Re-running the command keeps
Grafana's database and initial password. `manage-model-servers apply` refreshes
Prometheus's scrape key when `ROUTER_API_KEY` changes. Prometheus is installed
without Debian's recommended node exporter, so nothing else starts listening.
Grafana is the newest release in Grafana's stable repository unless
`GRAFANA_VERSION=<version>` is set for the setup command; set
`GRAFANA_KEY_FINGERPRINT` to the fingerprint Grafana publishes for its
signing key to have the downloaded key checked before anything is installed
from it. Update both later with `apt-get install --only-upgrade prometheus
grafana` in the CT; `tools/upgrade-all.sh` checks that the two services still
run after a router upgrade but does not upgrade them. Check the scrape with
`systemctl status osr-prometheus grafana-server` and Grafana's data source
health. Prometheus retention is limited to 7 days and 512 MB of persistent
blocks; its write-ahead log needs additional disk space.

