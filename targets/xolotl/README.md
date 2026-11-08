# Xolotl (DeepSeek-V4.1-Flash) inference target

[Xolotl](https://github.com/Indras-Mirror/Xolotl) is Indras Mirror's fork of
[Strata](https://github.com/Niko1221/Strata) (merged at 0.1.44.1) with its own
engines for DeepSeek-V4.1-Flash (552B MoE), GLM-5.3-Flash and Qwen3.8. Like
Strata it keeps the hottest experts in VRAM, tens of GiB in a pinned RAM arena
and the rest on NVMe. This target runs the **DeepSeek-V4.1-Flash** engine
(GLM-5.3-Flash is the [Maya target](../maya/README.md), Qwen3.8-Flash-Next the
[Strata target](../strata/README.md)). Register it as `xolotl://<CT address>`
(port 8080).

`provision-lxc.sh` creates an unprivileged LXC on an NVIDIA GPU host and runs
`install-target.sh`, which:

- installs a driverless CUDA toolkit (13.0 by default, `cuda-toolkit.sh`);
- builds `ds41_generate` as Xolotl's README does: its pinned Python packages in
  a venv, `tools/xolotl/fetch-llama.sh` (llama.cpp at Xolotl's pin plus its
  ggml patch) and CMake with `-DSTRATA_DSV41_FQ_OP=ON -DSTRATA_DSV41_HC_MIX=ON`
  for the GPU's architecture;
- downloads the pinned
  [DeepSeek-V4.1-Flash-1017 V4 quant](https://huggingface.co/IndrasMirror/DeepSeek-V4.1-Flash-1017-XQ-Uncensored)
  (163 GB, with expert ranking, tokenizer and the 5.7 GB DSpark draft) and the
  two [DeepSeek-V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017)
  shards holding the Engram tables (203 GB);
- serves it with Strata's server (`tools/v41/serve/serve_ds41.py`) as the
  hardened `xolotl` service with a generated key.

## Requirements

Upstream measured about 26 tok/s decode and 290–400 tok/s prefill on one RTX
4090, 90 GB DDR4 and one NVMe drive.

- **GPU:** NVIDIA, compute capability 7.5+ (RTX 20 and newer), 24 GB VRAM (16 GB
  untested upstream; less will not work). GPU 0's VRAM and capability are
  checked before anything is installed; `XOLOTL_CUDA_ARCH=auto` builds for it,
  so the host driver must already be loaded: without it the provisioner stops
  and points to `tools/setup-host-gpu.sh --for xolotl` (the router installer
  runs that first). That tool installs NVIDIA 580.173.02 with open kernel
  modules via DKMS (unattended: `GPU_GENERATION=rtx20|rtx30|rtx40|rtx50
  INSTALL_HOST_DRIVER=yes`) and never replaces a running driver.
- **RAM:** 96 GiB by default; the engine pins a 60 GiB arena
  (`XOLOTL_ARENA_GIB`), refused within 16 GiB of the CT's memory. Less RAM means
  more experts read from disk; ~256 GB holds them all.
- **Disk:** ~372 GB of weights; root disk 420 GiB by default (minimum 380) on
  **fast NVMe** (each token reads ~48 random Engram rows plus missing experts).
  Not a hard drive, not exFAT.
- **Templates:** Debian 12/13 or Ubuntu 22.04/24.04/26.04 amd64. Debian 13's
  NVIDIA repository starts at CUDA 13.1 and Ubuntu 26.04's at 13.3: set
  `XOLOTL_CUDA_VERSION` by hand (the router installer does). RTX 50 needs CUDA
  13.0+; CUDA 13 needs driver 580+.
- **Host:** Proxmox VE 9 with `/dev/nvidia0`, `/dev/nvidiactl`,
  `/dev/nvidia-uvm`; `NVIDIA_DRIVER_VERSION=auto` (or an exact version). GPU
  group and memlock handling as in the
  [Strata target](../strata/README.md#requirements).

The first install downloads the weights (hours) and then loads the model.

## Create and launch

```bash
CT_ID=253 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.53/24 GATEWAY=192.0.2.1 \
bash targets/xolotl/provision-lxc.sh --dry-run     # then without --dry-run
```

Missing address, gateway, template and storage are prompted for on a
terminal (no address is chosen automatically); the CT ID defaults to the
cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID`
to choose another). Dry runs query nothing, so they need `CT_ID`, `TEMPLATE`
and `STORAGE`. An existing CT ID is refused; a failed new CT is kept. An
interrupted download resumes when the installer runs again.

| Setting | Default | |
|---|---|---|
| `XOLOTL_REF` / `XOLOTL_COMMIT` | Commit in `upstream-commit.txt` | A branch, or another full commit (`COMMIT` wins) |
| `XOLOTL_CUDA_VERSION` | `13.0` | 12.8 or newer; RTX 50 needs 13.x |
| `XOLOTL_CUDA_ARCH` | `auto` | Compute capability as a number (`86`, `89`, `120`) |
| `XOLOTL_PORT` | `8080` | |
| `XOLOTL_CONTEXT` | `65536` | `--ctx`; up to 512K with the 4-bit KV cache (upstream uses 131072 on 24 GB) |
| `XOLOTL_ARENA_GIB` | `60` | `--arena-gib` |
| `XOLOTL_DSPARK` | `true` | `false` skips the 5.7 GB draft and frees ~2.9 GB VRAM |
| `XOLOTL_MODEL_NAME` | `deepseek-v4.1-flash` | Model id the API lists |
| `XOLOTL_READY_TIMEOUT` | `1800` | Seconds to wait for the load |

Host-side settings (`CORES=8`, `MEMORY_MB=98304`, `ROOTFS_GB=420`,
`GPU_DEVICES`, `GPU_GID=44`, ...) are listed by `--help`. The engine uses
Xolotl's V4.1 serve settings: `--rank rank-1017-v4.bin --tier-batch-pcie 0.25`,
`--arena-adapt --kv-fp4`, route bias 0.5 / file 0.3, 12288-token prompt batch,
dense half re-quantized to Q6_K at load (cached in `/var/lib/xolotl/cache`),
DSpark depth 4. Text only (vision needs upstream's separate encoder).

## Connect the router

```bash
pct exec 253 -- cat /etc/xolotl-target/api-key
manage-model-servers set-xolotl-token --apply
manage-model-servers add xolotl://192.0.2.53 --tier xlarge --apply
```

Xolotl's `/health` says `"service": "strata"`; the manager tells it apart by
its DeepSeek-V4 model, and `xolotl://` always works. Its own kind and key mean
a Strata key is never sent to Xolotl or vice versa. `deepseek-v4.1-flash` is
sized 552B by `[model_sizes]` (add a line for another `XOLOTL_MODEL_NAME`).
Restrict the API port to the router (the CT's firewall flag is on, without
rules). Logs: `pct exec 253 -- journalctl -u xolotl -f`.

| Path | |
|---|---|
| `/opt/xolotl` | Checkout, venv, `third_party/llama.cpp`, `build-xolotl/ds41_generate` (read-only to the service) |
| `/var/lib/xolotl/models/v41-xq-1017-v4` | Quant, rank file, tokenizer, DSpark |
| `/var/lib/xolotl/models/engram-1017` | Engram shards and the installer's index |
| `/etc/xolotl/xolotl-ds41.json` | Server config including the key (0640 root:xolotl); the key is never in argv, unit or env file |
| `/etc/xolotl-target/` | Root-only key, settings, verified-weights record, `xolotl.env` (port) |

## Weights

`xolotl-weights.txt` lists every file with size and SHA-256 at a pinned
revision of each Hugging Face repository. The installer checks each missing
file's size and hash with Hugging Face and the free disk before downloading.
The quant's 16 byte-range parts are each verified, appended and deleted (never
parts and model at once), then the joined file is verified. Interrupted
downloads and joins resume; corrupt parts are refetched. Verified files are
recorded in `/etc/xolotl-target/verified-weights`, so reruns neither rehash
~370 GB nor need the network. DeepSeek's Engram index covers all 48 shards and
has no published hash, so `engram-index.py` writes one from the two verified
shards' headers; the engine reads them in place (no 203 GB extract step). To
move to a newer build, review it and replace the rows and URL revisions;
old files stay until you delete them.

## Versions and upgrade

Xolotl changes many times a day. Every run fetches the tested commit in
`upstream-commit.txt` (`c17cddadd06a47b34abfb1e93ab1f710d9705c07`), which
`test-pinned-upstream.py` and CI's `xolotl-upstream` job check; the installer
also checks the checkout's files, CMake options, engine flags and config keys
before building. Move the pin only after that check passes. The commit is not a
saved setting, so the next rerun moves to a new pin; installs that followed
`main` move to the (possibly older) pin unless rerun with `XOLOTL_REF=main`.

```bash
for f in install-target.sh cuda-toolkit.sh engram-index.py xolotl.service xolotl-weights.txt upstream-commit.txt; do
    pct push 253 targets/xolotl/$f /root/xolotl-target-deploy/$f
done
pct exec 253 -- bash /root/xolotl-target-deploy/install-target.sh --upgrade
```

**Settings record.** Every rerun reuses `/etc/xolotl-target/installed-env`;
non-empty environment values override it, a new `XOLOTL_CUDA_VERSION` without
`XOLOTL_NVCC` takes that release's `nvcc`, and `XOLOTL_CUDA_ARCH=auto` reads
the GPU again. Only a fresh install uses defaults; it writes `pending-env`
first so an interrupted install (a long download, say) resumes. An existing
checkout or unit without a readable record needs every setting explicitly.

**Rollback.** The commit is fetched and the weights verified or completed
while the service runs; a failure there changes nothing. If commit, settings,
config, unit and weights are unchanged and the model is loaded, nothing
happens. Otherwise the checkout (venv, llama.cpp, engine build), unit, env and
server config are snapshotted to the root-only `/var/lib/xolotl-target/`,
then the engine is rebuilt and restarted. On failure the snapshot is restored
without building or downloading and the old service is health-checked. The
snapshot is deleted after success or rollback; if the rollback also fails it
is kept beside a `rollback-failed` marker and every later run stops until you
inspect or restore it and delete the marker. Leave disk for one copy of the
checkout and build (models are outside it). Because `fetch-llama.sh` keeps any
already-patched tree, the installer refetches llama.cpp whenever its commit
differs from Xolotl's pin.

## Checks

```bash
bash targets/xolotl/test-install.sh         # stubbed end-to-end runs need root
bash targets/xolotl/test-provision.sh       # dry-run plans, validation
bash targets/xolotl/test-cuda-toolkit.sh    # CUDA repository table
git init /tmp/xolotl-src && git -C /tmp/xolotl-src fetch --depth 1 \
    https://github.com/Indras-Mirror/Xolotl.git "$(cat targets/xolotl/upstream-commit.txt)"
git -C /tmp/xolotl-src checkout -q FETCH_HEAD
python3 -m venv /tmp/xolotl-venv && /tmp/xolotl-venv/bin/pip install -r /tmp/xolotl-src/requirements.txt
/tmp/xolotl-venv/bin/python targets/xolotl/test-pinned-upstream.py /tmp/xolotl-src
```

The pinned check (CI's `xolotl-upstream` job) runs the installer's config
through the pinned server's own config, argument and environment code, checks
every engine flag and `STRATA_*` setting, the `/health` fields the probe and
manager read, and the Engram index lookups. None of these build the engine,
download weights or need a GPU.
