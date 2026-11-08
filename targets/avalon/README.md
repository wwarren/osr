# Avalon (Qwen3.8-Flash-Next) inference target

[Avalon](https://github.com/freriadoc/Avalon) is a llama.cpp fork built for one
model, [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)
(125B MoE, 512 experts, 10 active), on **one consumer GPU with the experts in
system RAM**: the GPU holds dense weights, KV cache and the hottest experts,
the CPU computes misses (AVX2), and an MTP draft head speeds generation.
Upstream measured 91 tok/s on an RX 7900 XT (20 GB, ROCm) with 64 GB DDR4 and
120 tok/s once on an RTX 4090. It serves the Strata/Basalt model family on AMD
Radeon as well as NVIDIA, from its own ~90 GiB IQ3_KS hybrid quant. Register it
as `avalon://<CT address>` (port 8080); the id `qwen3.8-flash-next-avalon` is
sized 125B.

`provision-lxc.sh` creates an unprivileged LXC and runs `install-target.sh`,
which:

- installs user-space only: **ROCm 7.2.4** from AMD's repository
  (`rocm-toolkit.sh`) for AMD, or a **CUDA** toolkit (12.9 by default,
  `cuda-toolkit.sh`) for NVIDIA;
- builds `llama-server` at the tested commit as upstream does
  (`-DGGML_HIP=ON -DAMDGPU_TARGETS=<gfx>` with ROCm's `amdclang`, or
  `-DGGML_CUDA=ON` for the card's compute capability), without the web UI;
- downloads the pinned
  [Qwen3.8-Flash-Next-Avalon-GGUF](https://huggingface.co/freriadoc/Qwen3.8-Flash-Next-Avalon-GGUF)
  files (33 shards, MTP head, expert ranking; `avalon-weights.txt`);
- serves it with upstream's launcher settings (q8_0/q4_0 KV cache, MTP with 2
  draft tokens, `--parallel 1`, 64k context) as the hardened `avalon` service
  with a generated key.

## Requirements

- **AMD GPU (default, upstream's reference):** Radeon RX 7000 or PRO W7000,
  RDNA 3 only (`gfx1100` RX 7900 XTX/XT/GRE, `gfx1101` RX 7800/7700, `gfx1102`
  RX 7600; only `gfx1100` measured). RDNA 4 and older cards are refused. The
  host runs in-kernel `amdgpu`; the CT gets `/dev/kfd` and the render node.
- **NVIDIA GPU:** compute capability 7.5+ (kernels are tuned for RDNA 3). CUDA
  12.9 needs driver 570+.
- **VRAM:** 16 GB+. `AVALON_CONTEXT=auto` gives 256k with 19 GB or more, else
  64k.
- **CPU:** AVX2; 8 cores by default.
- **RAM:** the model is memory-mapped; 64 GiB by default, at least 32 GiB
  (upstream: generation 2–6% and a new 19k prompt's prefill ~30% slower than
  64 GB).
- **Disk:** 160 GiB by default (at least 130) for weights, ROCm (~8 GB) or
  CUDA, build and rollback snapshot; NVMe when RAM is below the model size.
- **Templates:** Ubuntu 24.04 (default) or 22.04: AMD supports ROCm on Radeon
  only on Ubuntu/RHEL and 7.2.4 ships for noble and jammy. With
  `AVALON_BACKEND=cuda` also Debian 12/13 and Ubuntu 26.04 (set
  `AVALON_CUDA_VERSION=13.1` or `13.3` there).
- **Host:** Proxmox VE 9 with the GPU driver loaded; `tools/setup-host-gpu.sh`
  installs a missing one (the router installer runs it).

Missing address, gateway, template and storage are prompted for on a
terminal (no address is chosen automatically); the CT ID defaults to the
cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID`
to choose another). Dry runs query nothing, so they need `CT_ID`, `TEMPLATE`
and `STORAGE`. The first install downloads ~90 GiB, then loads the model.

## Create and launch

```bash
CT_ID=254 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.54/24 GATEWAY=192.0.2.1 \
bash targets/avalon/provision-lxc.sh --dry-run     # then without --dry-run
```

`AVALON_BACKEND=auto` follows `GPU_DEVICES` when given (`/dev/kfd
/dev/dri/renderD<n>` is ROCm, `/dev/nvidia*` CUDA), else ROCm for a single
RDNA 3 card on `amdgpu`, else CUDA when the NVIDIA driver lists a GPU. With
several RDNA 3 cards, set `GPU_DEVICES`. The router installer asks for the card
and passes `AVALON_BACKEND` and `GPU_DEVICES`. An existing CT ID is refused; a
failed new CT is kept; an interrupted download resumes on rerun.

| Setting | Default | |
|---|---|---|
| `AVALON_REF` / `AVALON_COMMIT` | Commit in `upstream-commit.txt` | A branch or another full commit |
| `AVALON_BACKEND` | `auto` | `rocm` or `cuda` |
| `AVALON_ROCM_VERSION` | `7.2.4` | 7.x |
| `AVALON_GPU_TARGET` | `auto` | `gfx1100`/`1101`/`1102`; `auto` reads the PCI ID |
| `AVALON_CUDA_VERSION` | `12.9` | 12.4+; RTX 50 needs 12.8+ |
| `AVALON_CUDA_ARCH` | `auto` | Compute capability as a number; `auto` reads GPU 0 |
| `AVALON_PORT` | `8080` | |
| `AVALON_CONTEXT` | `65536` | `-c`, 4096–262144, or `auto` |
| `AVALON_MTP` | `true` | `false` skips the 1.4 GB draft head |
| `AVALON_MODEL_NAME` | `qwen3.8-flash-next-avalon` | `--alias` |
| `AVALON_READY_TIMEOUT` | `1800` | Seconds to wait for the load |

Host-side settings (`CORES=8`, `MEMORY_MB=65536`, `ROOTFS_GB=160`,
`GPU_DEVICES`, `GPU_GID=44`, ...) are listed by `--help`.

## Connect the router

```bash
pct exec 254 -- cat /etc/avalon-target/api-key
manage-model-servers set-avalon-token --apply
manage-model-servers add avalon://192.0.2.54 --tier xlarge --apply
```

Avalon's public `/health` says only `{"status":"ok"}`, so the manager
identifies it from `/v1/models` (`"owned_by": "llamacpp"` and an id containing
`avalon`), which needs the key once one is set: add a keyed server as
`avalon://`. Add a `[model_sizes]` line for another `AVALON_MODEL_NAME`.
Restrict the API port to the router (the CT's firewall flag is on, without
rules). Logs: `pct exec 254 -- journalctl -u avalon -f`.

| Path | |
|---|---|
| `/opt/avalon` | Checkout and `build/bin/llama-server` (read-only to the service) |
| `/opt/rocm-7.2.4` | ROCm from `repo.radeon.com` (AMD) |
| `/var/lib/avalon/models` | 33 shards, `MTP/`, `moe-cache-ranking.bin` |
| `/etc/avalon/api-key` | The server's key copy (0640 root:avalon), read via `--api-key-file`; never in argv, unit or env |
| `/etc/avalon-target/` | Root-only key, settings, verified-weights record, `avalon.env` (arguments, no key) |

## Weights

`avalon-weights.txt` lists every file's size and SHA-256 at Hugging Face
revision `372fe3a4e572c5ba75a90e579de0695633d083a8`. The installer checks each
missing file's size and hash with Hugging Face and the free disk first, then
downloads each file beside its place, verifies and moves it in. Interrupted
downloads resume; corrupt files are deleted. Verified files are recorded in
`/etc/avalon-target/verified-weights`, so reruns neither rehash ~90 GiB nor
need the network. To adopt a newer upload, review it and replace the rows and
URL revisions; old files stay until you delete them.

## Versions and upgrade

Every run fetches the tested commit in `upstream-commit.txt`
(`7fc482745eabd54b7a779ed54296c8a2d253c76f`), checked by
`test-pinned-upstream.py` and CI's `avalon-upstream` job; the installer also
checks the checkout's files, CMake options and llama-server flags before
building. Move the pin only after that check passes; the commit is not a saved
setting, so the next rerun moves to it.

```bash
for f in install-target.sh rocm-toolkit.sh cuda-toolkit.sh avalon.service avalon-weights.txt upstream-commit.txt; do
    pct push 254 targets/avalon/$f /root/avalon-target-deploy/$f
done
pct exec 254 -- bash /root/avalon-target-deploy/install-target.sh --upgrade
```

**Settings record.** Every rerun reuses `/etc/avalon-target/installed-env`;
non-empty environment values override it. A new `AVALON_CUDA_VERSION` without
`AVALON_NVCC` takes that release's `nvcc`; a new `AVALON_BACKEND` re-detects
the GPU target and sets the context to `auto` unless `AVALON_CONTEXT` is
given. Only a fresh install uses defaults; it writes `pending-env` first so an
interrupted install resumes. An existing checkout or unit without a readable
record needs every setting explicitly.

**Rollback.** The commit is fetched and weights verified or completed while
the service runs; a failure there changes nothing. If commit, settings, unit
and weights are unchanged and the server answers, nothing happens. Otherwise
the checkout with its build, unit, env and key file are snapshotted to the
root-only `/var/lib/avalon-target/`, then `llama-server` is rebuilt and
restarted. On failure the snapshot is restored without building or
downloading and the old service is health-checked. The snapshot is deleted
after success or rollback; if the rollback also fails it is kept beside a
`rollback-failed` marker and every later run stops until you inspect or restore
it and delete the marker. ROCm releases replace each other in place, so the
snapshot cannot undo a new `AVALON_ROCM_VERSION`: change it on its own, not
with a new commit.

## Checks

```bash
bash targets/avalon/test-install.sh         # stubbed end-to-end runs need root
bash targets/avalon/test-provision.sh       # dry-run plans, validation, GPU detection
bash targets/avalon/test-rocm-toolkit.sh    # ROCm repository table and key check
bash targets/avalon/test-cuda-toolkit.sh    # CUDA repository table
git init /tmp/avalon-src && git -C /tmp/avalon-src fetch --depth 1 \
    https://github.com/freriadoc/Avalon.git "$(cat targets/avalon/upstream-commit.txt)"
git -C /tmp/avalon-src checkout -q FETCH_HEAD
python3 targets/avalon/test-pinned-upstream.py /tmp/avalon-src
```

The pinned check (CI's `avalon-upstream` job) runs the installer's own
`validate_checkout`, compares the unit's arguments with upstream's
`avalon-server` launcher and checks the API behaviour the probe, router and
manager rely on. None of these build Avalon, download weights or need a GPU.

**Not yet run on real hardware:** ROCm 7.2.4 in an unprivileged CT on the PVE
kernel's `amdgpu` (only `/dev/kfd` and one render node), the HIP and CUDA
builds of the pin, load time against `AVALON_READY_TIMEOUT`, and the expert
cache under `lxc.prlimit.memlock: unlimited`.
