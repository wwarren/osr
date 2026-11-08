# Kindi (Ternary-Bonsai-2 on small and old GPUs) inference target

[Kindi](https://github.com/ahtx/kindi) (Amir Husain, AGPL-3.0) serves Prism
ML's ternary [Ternary-Bonsai-2](https://huggingface.co/prism-ml) models (2B,
4B, 9B, 27B) and AH-Nanbeige4.3-33B on **cheap and old NVIDIA cards**, from a
1 GB Quadro K420 (Kepler) to the RTX 50 series, or on the CPU. Its greedy
output matches llama.cpp's token for token for the same file, several times
faster on small cards (upstream: 20.8 vs 1.65 tok/s for the 2B on a K420; 63
tok/s for the 27B on an RTX 3080, up to 1.8× with the 2B as draft). It speaks
the OpenAI API with tool calls, so a spare card can be a fast-tier host.
Register it as `kindi://<CT address>` (port 8093); ids (`bonsai2-2b` ...
`bonsai2-27b`, `nanbeige-33b-iq3`) are sized from the id, and the fitted
context is listed as `context_length` (read by Hermes and OpenClaw).

`provision-lxc.sh` creates an unprivileged LXC with one NVIDIA card (or none)
and runs `install-target.sh`, which installs Kindi natively as its
`docker/Dockerfile` does:

- the **CUDA 10.2** toolkit, user space only (`cuda-toolkit.sh`): NVIDIA's
  runfile with `--toolkit`, MD5-checked. It is the last toolkit for Kepler and
  the one CuPy 9.6 targets; no current apt repository carries it;
- a standalone **Python 3.9** and Kindi's venv through a pinned uv, from hash
  locks of Kindi's pins (`requirements-cuda.lock`, or `requirements-cpu.lock`
  without CuPy);
- Kindi at the tested commit, the pinned GGUF (`kindi-weights.txt`) converted
  to Kindi's pack with `kindi convert`, and `kindi verify` against llama.cpp's
  reference before anything is served;
- the hardened `kindi` service with per-card engine settings (`kindi.env`) and
  a generated key in its config file.

## Requirements

- **GPU:** one NVIDIA card of compute capability 3.0+ per CT (upstream tested
  K420, K1200, K6000, P100, GTX 1080, RTX 3080; RTX 20–50 pass `kindi verify`).
- **Host driver:** at least 440.33. **Kepler needs the 470 driver**; Maxwell,
  Pascal and Volta need branch 580 or older with proprietary modules.
  `tools/setup-host-gpu.sh` installs the 580 open modules (Turing and newer
  only), so for older cards install the host driver yourself first (Maxwell to
  Volta: `KERNEL_MODULE_TYPE=proprietary bash tools/install-nvidia-driver.sh
  host`). The CT gets matching user space through `targets/nvidia-lxc.sh`.
- **No GPU:** `KINDI_BACKEND=cpu` (also `auto` without an NVIDIA driver) runs
  the 2B, 4B or 9B on an AVX2 CPU.
- **RAM:** 4 GB (2B/4B), 6 GB (9B), 10 GB (Nanbeige), ~14 GB for the 27B's
  first start; 16 GiB by default.
- **Disk:** ~3 GB for CUDA 10.2 (plus 2.6 GB runfile during install), 1 GB
  venv, model plus pack (0.9 GB for the 2B; 12 GB plus 5.6 GB of 5-trit
  weights on Pascal+ for the 27B; 13 GB for Nanbeige) and one rollback
  snapshot; 64 GiB by default.
- **Templates:** Debian 12/13 or Ubuntu 22.04/24.04 (the runfile needs their
  `libxml2.so.2`).

## Models and profiles

`KINDI_MODEL=auto` and `KINDI_PROFILE=auto` read GPU 0 with `nvidia-smi` and
pick what Kindi's own `install.sh` would for one server on that card (CI checks
they match):

| Profile | Card | Model (auto) | Context (auto) | Engine settings |
|---|---|---|---|---|
| `tc` | CC 8.0+, 9.5 GB+ (RTX 30+) | 27B, 2B draft | 131072 | Tensor cores, flash-decode, speculative (`KINDI_SPEC=auto`) |
| `pascal8` | CC 6.1+, 7.5 GB+ (GTX 1080, RTX 20, 8 GB RTX 30) | 27B | 65536 | One-card engine, blocking sync off |
| `p100` | CC 6.0, 12 GB+ | 27B | 65536 | As `pascal8` |
| `kepler` | CC < 5.0 (Quadro/Tesla K, GTX 600/700) | 27B ≥11 GB, 9B ≥3.8 GB, 4B ≥1.9 GB, else 2B | 24576; 65536 from 1.5 GB (23808 for the 4B on 2 GB) | Blocking sync off |
| `maxwell` | Other (Maxwell, small Pascal/Turing) | 9B ≥3.8 GB, 4B ≥1.9 GB, else 2B | 24576 | Blocking sync off |
| `nanbeige` | CC 8.0+ or P100, 16.2 GB+ | `nanbeige-33b` only when asked | 16384 | `KINDI_MAX_TOKENS=16384` |
| `cpu` | No GPU | 2B (4B, 9B when asked) | 24576 | `KINDI_DEVICE=cpu`, the CT's cores |

The engine fits the context to free memory and reports it (`/health`,
`/v1/models`); the installer prints it when it differs. The 470 driver does
not report compute capability, so Kepler is recognized by name; set
`KINDI_PROFILE` for any other card without one.

## Create and launch

```bash
CT_ID=255 TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.55/24 GATEWAY=192.0.2.1 \
GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm' \
bash targets/kindi/provision-lxc.sh --dry-run     # then without --dry-run
```

Missing address, gateway, template and storage are prompted for on a
terminal (no address is chosen automatically); the CT ID defaults to the
cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID`
to choose another). Dry runs query nothing, so they need `CT_ID`, `TEMPLATE`
and `STORAGE`. `KINDI_BACKEND=auto` uses CUDA when `GPU_DEVICES` names an NVIDIA
node or the host driver lists a GPU (then `/dev/nvidia0`), else the CPU. On a
multi-card host give the old card's `/dev/nvidia<minor>` (see `nvidia-smi
--query-gpu=index,pci.bus_id` and `/proc/driver/nvidia/gpus/<bus>/information`).
The router installer asks for the card (or `none`) and passes `KINDI_BACKEND`
and `GPU_DEVICES`. An existing CT ID is refused; a failed new CT is kept; an
interrupted download resumes on rerun.

| Setting | Default | |
|---|---|---|
| `KINDI_REF` / `KINDI_COMMIT` | Commit in `upstream-commit.txt` | A branch or another full commit |
| `KINDI_BACKEND` | `auto` | `cuda` or `cpu` |
| `KINDI_MODEL` | `auto` | `bonsai-2b`, `bonsai-4b`, `bonsai-9b`, `bonsai-27b`, `nanbeige-33b` |
| `KINDI_PROFILE` | `auto` | A profile above |
| `KINDI_PORT` | `8093` | Kindi's own default |
| `KINDI_CONTEXT` | `auto` | 1024–262144; fitted to free memory |
| `KINDI_HEAD` | `exact` | `fast`: shortlist head, ~15% faster, same token 99.4% of the time (built by `kindi fast-head`, ~2 min) |
| `KINDI_SPEC` | `auto` | 27B on `tc` drafts with the 2B (also downloaded); `off` |
| `KINDI_THREADS` | `auto` | CPU engine threads |
| `KINDI_MODEL_NAME` | `auto` | API id (`bonsai2-<size>`, `nanbeige-33b-iq3`) |
| `KINDI_VERIFY` | `true` | Run `kindi verify` before each (re)start |
| `KINDI_PYTHON_VERSION` | `3.9.25` | 3.9.x |
| `KINDI_READY_TIMEOUT` | `1800` | The first start compiles kernels (and writes 5-trit weights for the 27B on Pascal+), up to 15 minutes |

Host-side settings (`CORES=4`, `MEMORY_MB=16384`, `ROOTFS_GB=64`,
`GPU_DEVICES`, `GPU_GID=44`, ...) are listed by `--help`.

## Connect the router

```bash
pct exec 255 -- cat /etc/kindi-target/api-key
manage-model-servers set-kindi-token --apply
manage-model-servers add kindi://192.0.2.55 --tier fast --apply
```

Kindi's public `/health` names it (`"kindi": "<version>"`), so a bare
`192.0.2.55:8093` is identified without a key. Hermes, OpenClaw and Honcho's
dispatchers read the key from the router's `secrets.env` when installed or
reconfigured. Restrict the port to the router (the CT's firewall flag is on,
without rules). Logs: `pct exec 255 -- journalctl -u kindi -f`.

### Timeouts and retries

Kindi serves **one request at a time** and reads prompts slowly on small cards
(~30 tok/s on a K420): give it a tier with short requests, and use it for
Hermes (64000 tokens) and OpenClaw only where its context is large enough.
Kindi asks clients for a 30–60 minute timeout and at most one retry, because a
retry waits behind the request still being read. OSR follows that:

- **Budget.** The router waits `kindi_read_timeout_seconds` (`router.ini`,
  3600) between bytes from a Kindi server, also on the LiteLLM hop, and
  publishes it in `/routing/inventory`. Hermes, OpenClaw and Honcho
  dispatchers copy it on `--reconfigure`; a lower router value applies to them
  at once, a higher one only after that CT's `provision-lxc.sh --reconfigure`
  (the dispatcher logs this and `manage-model-servers apply` says so).
- **LiteLLM.** Each Kindi deployment gets that timeout (regeneration writes it;
  `apply` syncs it after a `router.ini` edit). Kindi tiers retry once after a
  429 and never after a timeout; since LiteLLM 1.75 ignores
  `InternalServerErrorRetries`, the router sends `x-litellm-num-retries: 1`
  for them. A Kindi tier is a fallback only for another Kindi tier on other
  servers: other tiers keep the router's 300 s, and the same server would
  queue the retry behind the original.
- **Callers wait longer** than the dispatcher, so the dispatcher reports a
  silent Kindi first: Honcho's client waits twice the budget; Hermes's stream
  and stale limits and OpenClaw's `timeoutSeconds` for Kindi providers and
  `osr` allow twice the budget plus a reply at one token a second (8192 tokens
  for Hermes, `OPENCLAW_MAX_TOKENS` for OpenClaw). Open WebUI sets no timeout.
- **No reply within the budget** is never replayed (streams rarely get there:
  Kindi sends an SSE keep-alive every 15 s while reading). After any other
  candidate has failed, the router and the Hermes/OpenClaw/Honcho dispatchers
  answer 424 with `x-should-retry: false` and type `upstream_no_reply`, which
  OpenAI SDKs and Honcho do not retry; Hermes may still use a configured
  fallback provider (its and OpenClaw's named providers go through the same
  dispatcher, so the same Kindi answers 503 while busy). OpenClaw has no 424
  rule, so the message avoids words it reads as a timeout. LiteLLM's 408 or a
  silent hop on a Kindi tier becomes the same 424. A failed connection stays a
  retryable 502.
- **Bodies.** Non-streaming replies are read whole before 200 is sent (also on
  the router's LiteLLM hop for a Kindi tier), so a body timeout can still give
  424. Streaming direct replies wait for the first chunk; a stall after it
  closes the stream and gates Kindi.
- **Gate.** After hanging up, the router or dispatcher sends Kindi nothing
  until its `/health` shows no request in progress (Kindi drops an abandoned
  request at its next batch or token). A failed probe keeps the gate closed; a
  newer busy request does not open it. Busy traffic from other clients can keep
  it closed until a probe catches Kindi idle. Callers meanwhile get a retryable
  503 with `Retry-After: 15`.

## Where things are

| Path | |
|---|---|
| `/opt/kindi` | Checkout and `.venv` (read-only to the service) |
| `/opt/kindi-runtime` | Pinned uv and its standalone Pythons |
| `/usr/local/cuda-10.2` | CUDA 10.2 (CUDA only) |
| `/var/lib/kindi/models` | GGUF files |
| `/var/lib/kindi/packs/<model>-f<format>` | Packs, one per format (a rollback keeps the old one) |
| `/var/lib/kindi/state` | Kernel caches, saved prompt openings, head mode |
| `/etc/kindi/kindi.conf` | Server config with the key (`KINDI_CONFIG`; root-owned, `kindi` group read); never in argv, unit or env |
| `/etc/kindi-target/` | Root-only key, settings, verified-weights record, `kindi.env` (engine settings, no key) |

Other Kindi commands run as the service (`bench` and `head fast` with it
stopped):

```bash
pct exec 255 -- runuser -u kindi -- env PYTHONPATH=/opt/kindi KINDI_CONFIG=/etc/kindi/kindi.conf \
    /opt/kindi/.venv/bin/python -m kindi info
```

## Weights

`kindi-weights.txt` lists each GGUF's size and SHA-256 at a pinned Hugging
Face commit, matching Kindi's `kindi/catalog.py` (CI checks). Missing files are
checked against Hugging Face and the free disk (twice the size, for the pack),
downloaded beside their place, verified and moved in; interrupted downloads
resume and corrupt files are deleted. Verified files are recorded in
`/etc/kindi-target/verified-weights`. Packs of unused models or old formats
stay until you delete them.

## Versions and upgrade

Every run fetches the tested commit in `upstream-commit.txt`
(`917ae685b2c54af17787a92cae1132cab8dcd1ce`, Kindi 0.4.0), checked by
`test-pinned-upstream.py` and CI's `kindi-upstream` job; the installer also
checks files, config keys, commands, engine settings and Dockerfile pins
before building, and every upgrade runs `kindi verify`. Move the pin only
after that check passes; if upstream changes its Dockerfile pins, recompile
the locks from `requirements-*.in` as their headers describe. The AGPL's
network clause covers modified copies; this target serves upstream unchanged.

```bash
for f in install-target.sh cuda-toolkit.sh kindi.service kindi-weights.txt upstream-commit.txt \
         requirements-cpu.lock requirements-cuda.lock uv.lock; do
    pct push 255 targets/kindi/$f /root/kindi-target-deploy/$f
done
pct exec 255 -- bash /root/kindi-target-deploy/install-target.sh --upgrade
```

**Settings record.** Every rerun reuses `/etc/kindi-target/installed-env`;
non-empty environment values override it, and a new `KINDI_MODEL` or
`KINDI_BACKEND` re-sizes profile, context and model id unless given. Only a
fresh install uses defaults; it writes `pending-env` first so an interrupted
install resumes. An existing checkout or unit without a readable record needs
every setting explicitly.

**Rollback.** The commit is fetched and model files verified or completed
while the service runs; a failure there changes nothing. If commit, settings,
unit and files are unchanged and the server answers, nothing happens.
Otherwise the checkout with venv, unit, env and config are snapshotted to the
root-only `/var/lib/kindi-target/`, then the venv is rebuilt, a changed GGUF or
pack format converted (the replaced pack moves into the snapshot), `kindi
verify` run and the service restarted. On failure commit, runtime and packs
are restored without building or downloading and the old service is
health-checked. The snapshot is deleted after success or rollback; if the
rollback also fails it is kept beside a `rollback-failed` marker and every
later run stops until you inspect or restore it and delete the marker. A pack
left in its `rollback-packs/` belongs in `/var/lib/kindi/packs/` (or can be
deleted); the next upgrade waits until that directory is empty.

## Checks

```bash
bash targets/kindi/test-install.sh         # stubbed end-to-end runs need root
bash targets/kindi/test-provision.sh       # dry-run plans, validation
bash targets/kindi/test-cuda-toolkit.sh    # distro table, runfile checksum and flags
git init /tmp/kindi-src && git -C /tmp/kindi-src fetch --depth 1 \
    https://github.com/ahtx/kindi.git "$(cat targets/kindi/upstream-commit.txt)"
git -C /tmp/kindi-src checkout -q FETCH_HEAD
python3 targets/kindi/test-pinned-upstream.py /tmp/kindi-src
```

The pinned check (CI's `kindi-upstream` job) runs the installer's
`validate_checkout`, loads the written config with Kindi's own loader, and
checks the unit's engine settings, weights against the catalog, venv pins
against the Dockerfile, profiles against `install.sh` and the API the probe,
router and manager use. None of these download a model or need a GPU.

**Not yet run on real hardware:** the CUDA 10.2 runfile in an unprivileged CT
on Debian 13 and Ubuntu 24.04, CuPy 9.6 with the 470 and 580 user space from
`nvidia-lxc.sh` (including its `lxc` mode with a 470 runfile), the Kepler name
fallback, `kindi verify` and the 27B's first start against
`KINDI_READY_TIMEOUT`, and the 470 driver on a Proxmox 9 kernel at all.
