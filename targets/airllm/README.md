# AirLLM inference target

An Ollama-compatible API in front of [AirLLM](https://github.com/lyogavin/airllm),
so the router, LiteLLM and Open WebUI can use a model far larger than the CT's
RAM or VRAM. AirLLM streams the model one layer at a time from disk, so expect
**seconds to minutes per token**. One model per target, one generation at a
time. It follows the llama.cpp target's conventions: a dedicated CT, a
hardened unit, `--upgrade` with rollback, and `/api/tags` and `/healthz` that
answer **503 until the model is ready**, so no traffic reaches a target that is
still downloading or has failed.

| File | Purpose |
| --- | --- |
| `server.py` | The API (FastAPI), installed as `/opt/airllm-target/server.py` |
| `airllm-ollama-api.service` | Unit: user `airllm-target`, `ProtectSystem=strict`, only `/var/lib/airllm-target` writable |
| `airllm.env.example` | Every setting with its default |
| `requirements.txt`, `requirements.lock` | Exact pins and the hash lock installed with `pip --require-hashes` |
| `install-target.sh` | Installs, upgrades (`--upgrade`) or migrates an old `/opt/airllm-ollama-api` install |
| `provision-lxc.sh` | Creates the CT on the PVE host and optionally runs the installer |
| `test_server.py`, `airllm_fakes.py`, `test-install.sh`, `test-provision.sh` | Stubbed tests: no weights, network or CT |

| Path in the CT | Owner | Contents |
| --- | --- | --- |
| `/opt/airllm-target` | root, read-only to the service | `server.py`, `venv/`, requirements, this README |
| `/etc/airllm-target/airllm.env` | root:airllm-target 0640 | Settings, including `HF_TOKEN` |
| `/var/lib/airllm-target/hf-cache` | airllm-target | Hugging Face download (`HF_HOME`) |
| `/var/lib/airllm-target/shards` | airllm-target | AirLLM's per-layer shards |

## Provision and install

On the PVE host, from this directory:

```bash
CT_ID=260 TEMPLATE=local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.60/24 GATEWAY=192.0.2.1 \
AIRLLM_MODEL_ID=Qwen/Qwen2.5-72B-Instruct AIRLLM_MODEL_ALIAS=qwen2.5:72b \
bash provision-lxc.sh --install-target
```

On a terminal, missing settings are prompted for (IP/CIDR or `dhcp`, gateway,
downloaded templates, `rootdir` storage with room for `ROOTFS_GB`); no address
is chosen automatically. The CT ID defaults to the cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID` to choose another). `--dry-run` prints the plan without
Proxmox queries, so give `CT_ID`, `TEMPLATE` and `STORAGE` explicitly. Debian
12/13 and Ubuntu 24.04/26.04 templates are accepted (Python 3.11+). No root
password is set: use `pct enter <id>` or `SSH_PUBLIC_KEY=<file>`.

**Disk.** `ROOTFS_GB` defaults to the bf16 weights twice (download plus
shards) plus 5% and 20 GB, about **323 GB for a 72B**; less is refused unless
`ALLOW_SMALL_DISK=true`. `AIRLLM_DELETE_ORIGINAL=true` deletes the checkpoint
once split, but the peak is unchanged.

**GPU.** Pass `GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
/dev/nvidia-uvm-tools'`. The CT gets NVIDIA user-space matching the host
driver and streams through `cuda:0`; torch is PyPI's CUDA 13 build (needs the
580-series host driver; also runs CPU-only). Devices are mapped
`gid=993,mode=0660`; the installer adds `airllm-target` to each node's group
(creating `airllm-gpu` for the nameless gid 993) and checks the GPU as that
account. Root-group nodes already usable (0666) are accepted with a warning.
`--upgrade` repairs the membership on older CUDA installs.

In an existing CT or VM, run the installer directly as root:

```bash
AIRLLM_MODEL_ID=Qwen/Qwen2.5-72B-Instruct AIRLLM_MODEL_ALIAS=qwen2.5:72b bash install-target.sh
```

It builds the venv, writes `airllm.env` (`AIRLLM_DEVICE=cuda:0` when
`nvidia-smi` sees a GPU, else `cpu`) and starts the service, which begins the
download. Gated repos (Llama 3) need `HF_TOKEN` in the env file, then
`systemctl restart airllm-ollama-api`; the token is never on a command line.

```bash
journalctl -u airllm-ollama-api -f    # download, split and load progress
curl -s localhost:11434/health         # loading / ready / error, always 200
curl -s localhost:11434/healthz        # 200 only once requests can be served
```

### Upgrading

`bash install-target.sh --upgrade` refreshes `server.py`, the venv and the
unit, keeping model, settings and data. If everything is current and healthy
(or stopped) it prints "nothing to do". It refuses to restart a target that is
still downloading or loading unless `ALLOW_INTERRUPT=true` (the download
resumes; splitting starts over). If the target is not healthy within
`UPGRADE_HEALTH_TIMEOUT` (900 s), everything replaced is restored, including
the previous `airllm.env`, and the old install is restarted and reported as
running again or not. An intentionally stopped service stays stopped.

**Legacy install.** The first version used `/opt/airllm-ollama-api`.
`MIGRATE_LEGACY=true bash install-target.sh` stops it, copies model, token and
tuning settings into `airllm.env`, moves the weights and shards (no
re-download), replaces the unit and keeps `/opt/airllm-ollama-api.legacy` for
you to delete.

## Adding it to the router

`manage-model-servers add http://<target>:11434`. It listens on all interfaces
without authentication: keep it on a trusted network or firewall TCP 11434 to
the router. Because it is slow:

- Give it **its own tier** (e.g. `xlarge`) and never make it a fallback for
  faster tiers.
- LiteLLM's `timeout: 600` ends requests after ten minutes (about 10 tokens at
  one a minute). Keep `AIRLLM_MAX_NEW_TOKENS` small, or point Open WebUI at the
  target directly with a long timeout.
- `/api/tags` lists the model only once loaded, so discovery picks it up when
  the first download finishes.

## Behaviour

- **Context.** `AIRLLM_MAX_SEQ_LEN` bounds prompt plus reply. Long prompts
  lose their *oldest* tokens, never the newest turn; the reply keeps up to half.
- **Load failures exit.** A bad model ID or missing token exits; systemd retries
  3 times in 30 minutes, then leaves the unit failed for the monitor. `/health`
  shows the error while up.
- **One generation at a time** behind a lock. A disconnecting client cancels
  its generation. Seeds are applied after the request gets the model.
- No tools, images or embeddings. Requests naming another model get 404.

| Endpoint | Notes |
| --- | --- |
| `GET /`, `GET /api/version` | Always answer; `/api/version` includes `"backend": "airllm"` |
| `GET /api/tags`, `GET /v1/models` | The model once ready; **503** while loading or after a failed load |
| `GET /healthz` | 200 `{"status":"ok"}` when ready, else 503 (the llama.cpp bridge's contract) |
| `GET /health` | Diagnostics, always 200: status, device, error |
| `POST /api/show`, `GET /api/ps` | Metadata; family from `AIRLLM_MODEL_FAMILY` or the model config |
| `POST /api/chat`, `POST /api/generate` | Streaming NDJSON or `"stream": false` |
| `POST /v1/chat/completions` | Used by direct dispatch. JSON or SSE ending in `data: [DONE]`. Honours `max_tokens`/`max_completion_tokens`, `temperature`, `top_p`, `seed`. Offered `tools`/`functions` (choice not `none`) get 400 "does not support tools"; image parts are dropped with a warning |
| `POST /api/pull` | Starts the background load of the configured model |
| `POST /api/embed(dings)`, `/api/create`, `/api/copy`, `/api/push`, `/api/delete` | 501 |

## Dependencies and tests

`requirements.txt` pins airllm 4.0.0, transformers 5.17.0 (within airllm's
`>=4.49,<6`), torch 2.14.0 and the llama.cpp bridge's HTTP stack;
`requirements.lock` is generated from it (command in its header) for Python
3.11+. The API tests pass against it with stubs, but CI never loads real
weights, so watch the first load after changing a pin.

Run the suites with `bash tests/run-tests.sh <suite>` for `airllm`,
`airllm-install` and `airllm-provision` (one name per run).
