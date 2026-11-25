# PolyStrata inference target

`provision-lxc.sh` creates an unprivileged LXC on an NVIDIA GPU host, fetches
the [PolyStrata repository](https://github.com/simplexai-labs/PolyStrata) at a
tested commit, runs PolyStrata's Linux setup for the model family and size you
choose without starting the model, and runs the API as the hardened
`polystrata` service with an API key generated in the CT. Register it as
`polystrata://<CT address>` (`polystrata+http://<address>:8080`).

PolyStrata is a descendant of [Strata](../strata/README.md): the same
`setup.sh`, `run-<model>.sh` launchers, OpenAI-, Anthropic- and
Responses-compatible API and `/health` contract. It serves the
Qwen3.8-Flash-Next families on the Strata project's engine, and fourteen more
families on an engine written for PolyStrata ("strata-poly"), which upstream
marks **experimental**. This target is NVIDIA-only; upstream's AMD (HIP),
Intel Arc and Mac paths are not provisioned here.

Defaults: family `qwen`, size `IQ2_XS`, context 65536, KV cache `auto` (the
engine's default), 8 cores, 64 GiB RAM, 160 GiB disk, port **8080**. The first
install downloads 11 to 190 GB depending on the size.
For Unsloth `Q8_0`, set `ROOTFS_GB` to at least 200; its model download alone
is about 188 GB, above the default disk size.

## Model families

`families.sh` lists every family and size the pinned commit offers, with
setup's own RAM estimate for each; `test-pinned-upstream.py` checks it
against upstream's `setup.py`. Interactive provisioning shows a family menu,
then that family's sizes; enter a number or a name, or Enter for the default.
Preset `POLYSTRATA_FAMILY` or `POLYSTRATA_MODEL` skips its menu. The guest
checks both against the pinned checkout's `setup.sh --help` before anything
is downloaded.

| Engine | Families (`POLYSTRATA_FAMILY`) | Default size |
| --- | --- | --- |
| Strata | `qwen` (Qwen3.8-Flash-Next), `swift` (Swift 1.5), `coder`, `unsloth`, `gyro`, `nvfp4` | `IQ2_XS`; `IQ1_M` for coder, `UD-IQ4_XS` for unsloth, `Gyro-S`, `NVFP4` |
| PolyStrata (experimental) | `glm` (GLM 5.3 Flash), `deepseek` (DeepSeek V4 Flash), `lfm25`, `inkling`, `flint`, `kolibri`, `groot`, `qwen36` (Qwen3.6-35B-A3B), `clover`, `ornith`, `gemma4` (Gemma 4 26B-A4B), `tiel`, `minicpmv`, `ornith122` | the first size upstream lists (its own order of preference) |

Upstream's notes: Qwen3.8-Flash-Next wants a 12 GB card or more; GLM 5.3
Flash and DeepSeek V4 Flash want a 32 GB card; the smaller PolyStrata-engine
models run on 8 GB cards. RAM runs from about 13 GB (Inkling 2 Mini
UD-Q2_K_XL) to 136 GB (Unsloth Q8_0). The provisioner warns when the CT's
`MEMORY_MB` is below setup's estimate for the chosen size; setup itself then
reads part of the experts from disk or refuses the size.

`hy4-flash` (Tencent Hy4-Flash) is accepted from the environment with an
explicit `POLYSTRATA_MODEL` (`SQ-64`, `SQ-96` or `SQ-128`) but is not in the
menu: it has its own installer upstream and was not checked here.
`qwen36-strata` is left out: setup configures nothing for it at the pin.

## Source and setup options

Runs fetch the tested commit
[`36e654b1b7eb4cb462202445be296ba012c75edf`](https://github.com/simplexai-labs/PolyStrata/commit/36e654b1b7eb4cb462202445be296ba012c75edf)
(2026-11-23). `POLYSTRATA_COMMIT=<sha>` selects another commit;
`POLYSTRATA_REF=<name>` (with `POLYSTRATA_COMMIT` unset) follows a branch or
tag, and `POLYSTRATA_COMMIT=` follows `main`. Check a moving ref with
`test-pinned-upstream.py` first ([Checks](#checks)).

Settings are `POLYSTRATA_*`, never `STRATA_*`: upstream's setup and engines
read `STRATA_*` variables of their own (`STRATA_CUDA`, `STRATA_UV`,
`STRATA_PREBUILT_URL`, ...), and the target's settings must not reach them.

Because `setup.sh` options differ between releases, the installer reads the
checkout's `setup.sh --help` and:

- passes only supported options (`--no-browser`, `--family`, `--context`,
  `--kv`, `--parallel`, `--vision`, `--data-dir` or else `--models-dir`);
- stops before setup if `--setup`, `--no-start`, `--yes`, `--model`, `--port`
  or `--host` is missing (without `--host` the API binds to 127.0.0.1);
- refuses a checkout without `--api-key` unless `POLYSTRATA_ALLOW_NO_KEY=true`;
- checks `POLYSTRATA_FAMILY`, `POLYSTRATA_MODEL`, `POLYSTRATA_KV` and
  `POLYSTRATA_VISION` against the choices `setup.sh` lists.

The size is always passed with `--model`, so `--yes` counts as consent where
setup would otherwise stop and ask (a size it expects to page from disk, a
family upstream has run only on Linux).

`POLYSTRATA_PARALLEL=1` is the default; 2 to 8 passes `--parallel`. Upstream
answers several requests at once on the Strata engine and on some
PolyStrata-engine families; setup says so when a family answers one at a
time.

## KV cache

`POLYSTRATA_KV=auto` (the default) passes no `--kv`, so the engine keeps its
own default: int8 on the Strata engine, fp16 on PolyStrata's. Other values
depend on the family's engine (`families.sh`, from upstream's `STRATA_KV` and
`POLY_KV`):

| Engine | Values | Notes |
| --- | --- | --- |
| Strata | `int8`, `k8v4` (23% smaller), `q4_0` (45% smaller) | Asked with the Strata target's suggestion: int8 when the cache fits in the CT's RAM from a 64K context, else k8v4 for 12 and 16 GB cards and int8 for 24 and 32 GB cards. Not asked at 8192 tokens or less |
| PolyStrata | `fp16` and the family's own: `q8_0` for qwen36, ornith, ornith122, tiel, minicpmv, kolibri, flint and lfm25; `int8` and `int8k` for gemma4 | Asked only when the family has a format beside fp16; Enter keeps `auto` |

A value the family's engine does not have is refused by the provisioner and
by the guest. Change it on an existing CT with a rerun (setup, restart,
rollback on failure):

```bash
pct exec <id> -- env POLYSTRATA_KV=q8_0 bash /root/polystrata-target-deploy/install-target.sh
```

### Message cache (Strata engine)

`POLYSTRATA_MESSAGE_CACHE=true` sets upstream's opt-in
`STRATA_CACHE_MESSAGE_BOUNDARY=1` in the service environment
(`/etc/polystrata-target/polystrata.env`): one more checkpoint before the last
message of a prompt of 8,192+ tokens, for agents that rewrite their last
message. It is a Strata-engine setting, asked only for those families and
refused for the others. Default `false`, as upstream.

## Requirements

Run as root on the Proxmox VE 9 **GPU host** with a downloaded amd64
template (Ubuntu 22.04/24.04 or Debian 12/13), `rootdir` storage and an IP
with internet access (github.com, PyPI, Hugging Face, and NVIDIA's CUDA
repository when an engine has to be compiled). On a terminal the provisioner
prompts for missing address, gateway, template, storage, family, size and KV
cache. The CT ID defaults to the cluster's next free ID. Dry runs make no
Proxmox queries, so give `CT_ID`, `TEMPLATE` and `STORAGE`.

- **GPU nodes.** `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm` (and
  `/dev/nvidia-uvm-tools` if present) are passed through with CT group
  `GPU_GID` (44, `video`); `polystrata` joins that group, never root. Set
  `GPU_DEVICES` for another GPU.
- **Driver.** The provisioner installs NVIDIA user-space matching the loaded
  host driver (580 or newer: the default engines are CUDA 13).
- **Memory locking.** The CT gets `lxc.prlimit.memlock: unlimited` and the
  unit `LimitMEMLOCK=infinity`, so the engine can pin model memory.
- **Resources.** `MEMORY_MB` at least 16384 (default 65536), `ROOTFS_GB` at
  least 60 (default 160). Size both for the model.

## Create and launch

From the repository root on the Proxmox host:

```bash
bash targets/polystrata/provision-lxc.sh      # interactive
CT_ID=252 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.52/24 GATEWAY=192.0.2.1 \
POLYSTRATA_FAMILY=qwen36 POLYSTRATA_MODEL=UD-Q4_K_M POLYSTRATA_KV=q8_0 \
bash targets/polystrata/provision-lxc.sh --dry-run     # then without --dry-run
```

The installer waits `POLYSTRATA_READY_TIMEOUT` (900 s) for `/health` to
report `loaded=true`. Loading a large model can make the host sluggish for
one to three minutes. A failed setup keeps the CT for inspection; the
provisioner never deletes a CT and stops if the ID exists.

PolyStrata keeps its venv, engines and run configs in `/opt/polystrata`
(setup writes them in `/opt/polystrata/terminal/`) and models in
`/var/lib/polystrata`, the only paths the `polystrata` account can write.
Setup prints the generated `run-<model>.sh`; the installer checks it, writes
its path to `/etc/polystrata-target/polystrata.env`, and the unit runs it
directly. The key is passed to `setup.sh --setup` once and stored by
PolyStrata in its run config, never in the unit, env file or output.

```bash
pct exec <id> -- journalctl -u polystrata -f
pct exec <id> -- cat /etc/polystrata-target/api-key
```

**Engine build fallback.** PolyStrata's engines come ready-made for RTX 20 to
50 cards; when none fits, setup compiles one and calls `sudo` for the build
tools. The installer intercepts that, installs NVIDIA's toolkit-only package
as root (`cuda-toolkit-13-0` on Ubuntu 22.04/24.04 and Debian 12, `13-1` on
Debian 13) and retries setup once.

The GPU-node troubleshooting of the [Strata target](../strata/README.md#gpu-node-shows-group-root)
applies unchanged, with `polystrata` for `strata`.

## Register with the router

```bash
manage-model-servers set-polystrata-token --apply      # prompts for the key
manage-model-servers add polystrata://192.0.2.52 --tier large --apply
```

PolyStrata has its own key kind (`POLYSTRATA_API_KEY`), so a Strata key is
never sent to it or the other way round. Name it `polystrata://`: its
`/health` says `"service": "strata"` like Strata's. Auto-detection tells it
apart only by a model of its own engine (an id such as
`gemma-4-26b-a4b-ud-q3_k_m`); a Qwen3.8-Flash-Next family, or Qwen3.6 (whose
id Strata's own engine uses too), would be detected as Strata.

The router sizes ids that name their parameter count
(`qwen3.6-35b-a3b-ud-q3_k_m` is 35B) and lists the others in `[model_sizes]`
(Swift, Unsloth, Gyro and NVFP4 sizes 125B, GLM 5.3 Flash 321B, DeepSeek V4
Flash 284B, Hy4-Flash 220B). Coder, GLM's REAP50 and Kolibri stay unsized.

The CT is created with its firewall flag on but no rules: restrict the API
port to the router and intended clients. PolyStrata's web UI (Chat, Monitor)
is on the same port.

## Upgrade

`tools/upgrade-all.sh` pushes `install-target.sh`, `polystrata.service` and
`families.sh` and runs the installer with `--upgrade`. By hand:

```bash
for f in install-target.sh polystrata.service families.sh; do
    pct push <id> targets/polystrata/$f /root/polystrata-target-deploy/$f
done
pct exec <id> -- bash /root/polystrata-target-deploy/install-target.sh
pct exec <id> -- env POLYSTRATA_REF=main bash /root/polystrata-target-deploy/install-target.sh   # follow main
```

Upstream's `update.sh` is not used: its `git pull` cannot move a pinned
checkout or roll back.

**Settings record.** Every rerun reuses `/etc/polystrata-target/installed-env`;
non-empty environment values override it, and a new `POLYSTRATA_FAMILY`
without `POLYSTRATA_MODEL` takes that family's default. Only a fresh install
uses defaults; it writes `pending-env` before its first change so an
interrupted first install resumes with the same choices. A record missing a
setting is refused (repair it, or give every setting explicitly).

**Rollback.** As for Strata: a rerun fetches the source while the service
runs (a failed fetch changes nothing) and does nothing if commit, settings
(family, size, context, parallel, KV cache, message cache, vision, port, data
dir, key), unit and health are unchanged. Otherwise it stops the service,
snapshots the runnable checkout, venv, launcher and unit to the root-only
`/var/lib/polystrata-target/`, re-runs setup and health-checks; on failure it
restores the snapshot without setup or downloads. A failed rollback keeps the
snapshot beside a `rollback-failed` marker, and later runs stop there until
it is removed. Leave disk for one copy of the checkout; `/var/lib/polystrata`
is not copied.

## Checks

```bash
bash targets/polystrata/test-provision.sh       # dry-run plans, menus, validation
bash targets/polystrata/test-install.sh         # end-to-end cases need root
git init /tmp/polystrata-src && git -C /tmp/polystrata-src fetch --depth 1 \
    https://github.com/simplexai-labs/PolyStrata.git 36e654b1b7eb4cb462202445be296ba012c75edf
git -C /tmp/polystrata-src checkout -q FETCH_HEAD
python3 targets/polystrata/test-pinned-upstream.py /tmp/polystrata-src
```

`test-install.sh` covers `setup.sh --help` handling, the per-family KV cache,
launcher selection, installs, unchanged and changed reruns, a failed fetch, a
pinned upgrade and a rollback against stubs. The pinned check runs upstream's
real `setup.py --help` and launcher generator and compares `families.sh` with
upstream's tables; CI runs it as the `polystrata-upstream` job. None of these
downloads a model or needs a GPU.
