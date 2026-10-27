# AirLLM inference target

On an interactive Proxmox run, `provision-lxc.sh` lists downloaded compatible templates and active `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE` and `STORAGE` to skip the menus. Dry runs make no Proxmox queries, so supply those values explicitly.

An Ollama-compatible API in front of [AirLLM](https://github.com/lyogavin/airllm),
so the smart router, LiteLLM and Open WebUI can use a model far larger than the
target's RAM or VRAM. AirLLM streams the model one layer at a time from disk.
The price is speed: expect **seconds to minutes per token**. One model per
target, one generation at a time.

It is a sibling of the llama.cpp target (`targets/llamacpp`) and follows the
same conventions: a dedicated CT, `install-target.sh` inside it,
`provision-lxc.sh` on the PVE host, a hardened systemd unit, `--upgrade` with
rollback, and `/api/tags` + `/healthz` that answer **503 until the model is
ready**, so the router and monitor never send traffic to a target that is
still downloading or has failed.

## Files

| File | Purpose |
| --- | --- |
| `server.py` | The API (FastAPI). Installed as `/opt/airllm-target/server.py`. |
| `airllm-ollama-api.service` | systemd unit: user `airllm-target`, `ProtectSystem=strict`, writable `/var/lib/airllm-target` only. |
| `airllm.env.example` | Every setting with its default. Installed as `/etc/airllm-target/airllm.env` (0640). |
| `requirements.txt` | Exact pins of the direct dependencies. |
| `requirements.lock` | Hash lock generated from it; installed with `pip --require-hashes`. |
| `install-target.sh` | Installs, upgrades (`--upgrade`) or migrates an old `/opt/airllm-ollama-api` install. |
| `provision-lxc.sh` | Creates the CT on the PVE host and optionally runs the installer in it. |
| `test_server.py`, `airllm_fakes.py` | API tests against a stubbed model: no weights, no network. |
| `test-install.sh`, `test-provision.sh` | Installer and provisioning tests with stubbed system commands. |

## Layout on the target

| Path | Owner | Contents |
| --- | --- | --- |
| `/opt/airllm-target` | root, read-only to the service | `server.py`, `venv/`, requirements, this README |
| `/etc/airllm-target/airllm.env` | root:airllm-target 0640 | settings, including `HF_TOKEN` |
| `/var/lib/airllm-target/hf-cache` | airllm-target | the Hugging Face download (`HF_HOME`) |
| `/var/lib/airllm-target/shards` | airllm-target | AirLLM's per-layer shards |

## Provision and install

On the PVE host, from this directory:

```bash
CT_ID=260 TEMPLATE=local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.60/24 GATEWAY=192.0.2.1 \
AIRLLM_MODEL_ID=Qwen/Qwen2.5-72B-Instruct AIRLLM_MODEL_ALIAS=qwen2.5:72b \
bash provision-lxc.sh --install-target
```

Missing settings are prompted for on a terminal; `--dry-run` prints the plan.
Debian 12/13 and Ubuntu 24.04/26.04 templates are accepted. No root password is
set: use `pct enter <id>` or `SSH_PUBLIC_KEY=<file>`.

The root disk defaults to what the model needs: its weights twice (the
download plus AirLLM's shards) plus 20 GB, so about **323 GB for a 72B**. A
smaller `ROOTFS_GB` is refused unless `ALLOW_SMALL_DISK=true`. To reclaim the
download afterwards, set `AIRLLM_DELETE_ORIGINAL=true`: AirLLM then deletes the
original checkpoint once it has been split, but the peak usage is unchanged.

For a GPU, pass `GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
/dev/nvidia-uvm-tools'`. The CT gets those devices, the repository's NVIDIA
580.173.02 user-space helper runs before the installer, and the model streams
through `cuda:0`. torch comes from PyPI as its CUDA 13 build, which needs the
580-series driver on the host and also runs on CPU-only targets.

Inside an existing CT or VM, run the installer directly as root:

```bash
AIRLLM_MODEL_ID=Qwen/Qwen2.5-72B-Instruct AIRLLM_MODEL_ALIAS=qwen2.5:72b bash install-target.sh
```

It installs the hash-locked venv, writes `/etc/airllm-target/airllm.env`
(`AIRLLM_DEVICE=cuda:0` when `nvidia-smi` sees a GPU, otherwise `cpu`), and
starts the service, which begins the download. Gated repos (Llama 3) need
`HF_TOKEN` in the env file, then `systemctl restart airllm-ollama-api`. The
token is never passed on a command line.

```bash
journalctl -u airllm-ollama-api -f       # download, split and load progress
curl -s localhost:11434/health            # loading / ready / error, always 200
curl -s localhost:11434/healthz           # 200 only once requests can be served
```

### Upgrading

```bash
bash install-target.sh --upgrade
```

Refreshes `server.py`, the venv and the unit and keeps the model, settings and
data. When the server files, unit and settings are already current and the
target is healthy (or stopped), it prints "nothing to do" and changes nothing. It refuses to restart a target that is still downloading or loading
unless `ALLOW_INTERRUPT=true` (the download resumes, but splitting starts
over). If the target is not healthy again within `UPGRADE_HEALTH_TIMEOUT`
seconds (default 900), everything it replaced is put back, including
`airllm.env` as it was before new settings were added. The previous
installation is then restarted, health-checked, and reported as running
again or not.

### Migrating the earlier `airllm-ollama-api` install

The first version installed to `/opt/airllm-ollama-api`. Run
`MIGRATE_LEGACY=true bash install-target.sh` once: it stops the old service,
copies the model, token and tuning settings into `/etc/airllm-target/airllm.env`,
moves the downloaded weights and shards into `/var/lib/airllm-target` so
nothing is fetched again, replaces the unit, and keeps the old tree as
`/opt/airllm-ollama-api.legacy` for you to delete.

## Adding it to the router

Register the target like any Ollama server
(`manage-model-servers add http://<target>:11434`). It listens on all
interfaces without authentication, exactly like the llama.cpp bridge, so keep
it on the isolated network or firewall TCP 11434 to the router's address.

Speed decides how to use it:

- Give it **its own tier** (for example `xlarge`) and never make it a fallback
  for the faster tiers.
- LiteLLM's `timeout: 600` ends any request that takes longer than ten minutes.
  At one token a minute that is about 10 tokens, so keep
  `AIRLLM_MAX_NEW_TOKENS` small, or point Open WebUI at the target directly
  with a long request timeout for batch-style questions.
- `/api/tags` only lists the model once it is loaded, so discovery picks it up
  automatically when the first download finishes.

## Behaviour

- **Context window.** `AIRLLM_MAX_SEQ_LEN` bounds prompt plus reply. A long
  prompt loses its *oldest* tokens (as Ollama does), never the newest turn,
  and the reply keeps up to half the window.
- **Load failures exit.** A bad model ID or missing token makes the process
  exit, systemd retries 3 times in 30 minutes, then leaves the unit failed so
  the monitor reports it. `/health` shows the error while it is up.
- **One generation at a time.** Requests queue behind a lock. A client that
  disconnects, streaming or not, cancels its generation and frees the model.
- **Seeds** are applied after the request gets the model, so a seeded request
  never changes another request's sampling.
- Tool calling, images and embeddings are not supported (embeddings return 501).
  Requests naming another model return 404.

## Endpoints

| Endpoint | Notes |
| --- | --- |
| `GET /`, `GET /api/version` | Always answer; `/api/version` includes `"backend": "airllm"`. |
| `GET /api/tags` | The model once ready; **503** while loading or after a failed load. |
| `GET /healthz` | 200 `{"status":"ok"}` when ready, otherwise 503 (the llama.cpp bridge's contract). |
| `GET /health` | Diagnostics, always 200: status, device, error. |
| `POST /api/show`, `GET /api/ps` | Metadata; family from `AIRLLM_MODEL_FAMILY` or the model config. |
| `POST /api/chat`, `POST /api/generate` | Streaming NDJSON or `"stream": false`. |
| `POST /v1/chat/completions` | OpenAI chat completions, used by the router's direct dispatch. JSON, or SSE ending with `data: [DONE]` when `"stream": true`. `max_tokens`/`max_completion_tokens`, `temperature`, `top_p` and `seed` are honoured; other fields are ignored. Requests offering `tools` or legacy `functions` get 400 "does not support tools" unless their choice is `none`; image parts are dropped with a warning. |
| `GET /v1/models` | The model once ready; 503 before. |
| `POST /api/pull` | Starts the background load for the configured model. |
| `POST /api/embed(dings)`, `/api/create`, `/api/copy`, `/api/push`, `/api/delete` | 501. |

## Dependencies

`requirements.txt` pins airllm 4.0.0, transformers 5.17.0 (within airllm's
`>=4.49,<6`), torch 2.14.0 and the HTTP stack at the llama.cpp bridge's
versions. `requirements.lock` is generated from it with the command in its
header, for Python 3.11 and newer. The combination resolves cleanly and the API
tests pass against it with stubs; it has not been run against real weights in
CI, so watch the first load after changing a pin.

## Tests

From the repository root: `bash tests/run-tests.sh airllm` (pytest), and
`bash targets/airllm/test-install.sh`, `bash targets/airllm/test-provision.sh`.
`run-tests.sh` runs all of them.

Upgrades keep an explicitly inactive service stopped. A failed unit is
reapplied and restarted rather than treated as deliberately stopped.
