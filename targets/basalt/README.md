# Basalt inference target

`provision-lxc.sh` creates an unprivileged LXC on a Blackwell GPU host,
installs host-matched NVIDIA user-space and a CUDA 13 toolkit, builds the
[Basalt engine](https://github.com/jesdga95/basalt), downloads one
[`.basalt` model](https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt) and
runs its API as the `basalt` account with a generated key. Register it as
`basalt://<CT address>` (port 8080).

The host installer lists the current Qwen3.8-Flash-Next packs and asks which
one to install. Its suggested pack uses the selected GPUs' VRAM, available
host RAM, planned CT RAM and root disk. It allows 16 GiB of RAM beyond the
pack's expert weights and 30 GiB of disk beyond the pack file, then limits the
suggestion on smaller GPUs to favor throughput. This is a conservative
estimate, not a runtime guarantee; any listed pack can be chosen. A preset
`BASALT_MODEL` (full `.basalt` filename, or a listed suffix) skips the prompt,
including in unattended runs. Dry runs do not probe host resources and use a
conservative GPU tier; a standalone guest install still defaults to the
81.6 GiB UD-IQ3_XXS pack. When launched from the router installer,
`BASALT_MEMORY_MB` and `BASALT_ROOTFS_GB` set the planned CT sizes used for
the recommendation; otherwise they are 131072 MiB and 200 GiB.
Set `BASALT_MODEL` alongside a custom `BASALT_HF_REPO`; the menu describes
the official repository's packs.

Other defaults: alias `qwen3.8-flash-next`, context 65536, 8 cores, 128 GiB
RAM (floor 64 GiB: the expert arena is pinned host RAM), 200 GiB disk.
Basalt needs a Blackwell GPU (sm_120: RTX 50 or RTX PRO
Blackwell), CUDA 13 and CMake 3.24+ (installed into its venv if the system's
is older).

## Requirements

Run as root on the Proxmox VE 9 GPU host with a downloaded
Ubuntu 22.04/24.04/26.04 or Debian 12/13 amd64 template, `rootdir` storage,
network access and `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`.
Missing address, gateway, template and storage are prompted for on a
terminal (no address is chosen automatically); the CT ID defaults to the
cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID`
to choose another). Dry runs query nothing, so they need `CT_ID`, `TEMPLATE`
and `STORAGE`. GPU nodes get CT group `GPU_GID` (44, `video`), which `basalt`
joins; the CT gets unlimited `lxc.prlimit.memlock` and the unit
`LimitMEMLOCK=infinity`. Host-driver matching and group-root troubleshooting
work as in the [Strata target](../strata/README.md#gpu-node-shows-group-root)
(`NVIDIA_DRIVER_VERSION=auto` or an exact version).

### GPU node appears as group root

The guest installer checks whether the `basalt` account can read and write
each NVIDIA node and run `nvidia-smi`. A node shown as `root:root` is accepted
with a warning when that access works; the account is never added to group
`root`. Inspect the host mapping and the node permissions if it fails:

```bash
pct config <id> | grep -E '^(dev[0-9]+|lxc\.mount\.entry):'
pct exec <id> -- stat -c '%n gid=%g mode=%a' /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
pct exec <id> -- runuser -u basalt -- nvidia-smi -L
```

The default layout is `dev0` for nvidia0, `dev1` for nvidiactl and `dev2`
for nvidia-uvm. If a `devN` mapping is missing or wrong, correct the matching
entry to `path=/dev/nvidiaN,gid=44,mode=0660` and reboot the CT. If `pct config`
already shows that mapping but the CT reports `gid=0,mode=666`, repeating
`pct set` will not change the effective node; inspect any competing
`lxc.mount.entry` and the CT device mounts. Mode 0666 exposes the GPU to all
CT users, so restore the intended mapping after diagnosis.

After a failed first provision, push the current installer into the existing
CT and run it there. The saved `pending-env` keeps the original model, port
and other settings; do not rerun `provision-lxc.sh` against that CT.

If a download of the former `Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt` default returned
404, the pack has been removed from the model repository's `main` branch.
Resume the existing CT with the current pack name explicitly, because its
`pending-env` retains the previous selection:

```bash
pct push 164 targets/basalt/install-target.sh /root/basalt-target-deploy/install-target.sh --perms 0755
pct exec 164 -- env BASALT_MODEL=Qwen3.8-FN-UD-IQ3_XXS.basalt \
    bash /root/basalt-target-deploy/install-target.sh
```

Use your CT ID in place of `164`. The previous `.part` file can be left in
place; the new pack has a different filename. An interrupted download of the
new pack resumes on the next run.

**CUDA.** The toolkit comes from NVIDIA's apt repository for the CT's
distribution. Ubuntu 22.04/24.04 and Debian 12 carry the default 13.0;
**Debian 13 starts at 13.1** and **Ubuntu 26.04 at 13.3**, so set
`CUDA_VERSION` accordingly (the router installer does this for those
templates unless you set it). Both scripts refuse a combination the repository
cannot provide before changing anything, unless a toolkit meeting
`CUDA_VERSION` is already installed in the CT.

## Create and launch

```bash
CT_ID=250 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.50/24 GATEWAY=192.0.2.1 \
bash targets/basalt/provision-lxc.sh --dry-run     # then without --dry-run

pct exec 250 -- cat /etc/basalt-target/api-key
pct exec 250 -- journalctl -u basalt -f
```

The first build and download take time; the installer waits
`BASALT_READY_TIMEOUT` (3600 s) for a loaded model. A failed step leaves the CT
for inspection. An interrupted model download stays as `.part` and resumes on
the next run.

Settings: `BASALT_PORT`, `BASALT_MODEL`, `BASALT_HF_REPO`, `BASALT_ALIAS`,
`BASALT_GPUS` (for `0,1` also add `/dev/nvidia1` to `GPU_DEVICES`),
`BASALT_CONTEXT` (at most 999999), `BASALT_PARALLEL` (1 to 8),
`BASALT_KV`, `BASALT_KV_RESIDENT`,
`BASALT_VRAM_RESERVE_MIB`,
`CUDA_VERSION`, and `BASALT_ALLOW_NO_KEY=true` for an unauthenticated API. `BASALT_URL` and `BASALT_REF` (default `main`) select the
source; pin a tested commit with `BASALT_COMMIT` for production.

To increase the context while keeping 32,768 KV cells on the GPU and streaming
the rest from pinned CT RAM, set `BASALT_KV=int8` and
`BASALT_KV_RESIDENT=32768`. The resident count must be at least 20,480 and no
greater than the context per parallel slot. The defaults are `fp16` and `0` (all KV in
VRAM). Basalt also supports `q4_0` and `k8v4`, but `k8v4` cannot use
`BASALT_KV_RESIDENT`. These settings are saved across reruns, and an existing
install with the defaults is not restarted by an installer that adds them.

`BASALT_PARALLEL=4` serves four concurrent requests. `BASALT_CONTEXT` is
shared, so 262144 gives each slot 65536 tokens. Parallel counts above one
require `BASALT_KV=int8`; with KV streaming, each slot keeps
`BASALT_KV_RESIDENT` cells in VRAM. The installer validates these combinations
before changing the service. For example:

```bash
pct exec 164 -- env BASALT_CONTEXT=262144 BASALT_PARALLEL=4 BASALT_KV=int8 \
    BASALT_KV_RESIDENT=32768 bash /root/basalt-target-deploy/install-target.sh
```

`BASALT_VRAM_RESERVE_MIB` controls how much GPU memory Basalt's automatic
expert cache leaves for other allocations. Its default is 700 MiB; the Linux
minimum is 128 MiB. A larger value reduces the expert cache and can help a
new engine version start on a nearly full GPU, at a possible speed cost. For
example, set `BASALT_VRAM_RESERVE_MIB=2048` on a 16 GiB card that has less
than 1 GiB free after the model loads. The installer saves this setting and
restores the previous value if the new configuration fails its health check.

The pinned RAM copy holds the whole context, not only the cells beyond the
resident count: about 26 KiB per token for `fp16`, 13.4 KiB for `int8` and
7.3 KiB for `q4_0` (3.3, 1.7 and 0.9 GiB at 131,072 tokens). It comes out of
the same CT RAM as the experts. The provisioner sets it aside before
suggesting a pack, and both the provisioner and `install-target.sh` warn when
the cache, the pack's routed experts and 16 GiB for the server exceed the CT's
RAM (and, on the host, its available RAM). The warning does not stop the
install; raise the CT memory (`pct set <id> --memory <MiB>`), lower the
context or KV precision, or set `BASALT_KV_RESIDENT=0`.

For an existing CT (replace `164` if yours differs), run from the repository
clone on the Proxmox host:

```bash
pct push 164 targets/basalt/install-target.sh /root/basalt-target-deploy/install-target.sh --perms 0755
pct exec 164 -- env BASALT_CONTEXT=131072 BASALT_KV=int8 BASALT_KV_RESIDENT=32768 \
    bash /root/basalt-target-deploy/install-target.sh
```

The installer reuses the other saved settings, updates the launcher, and
health-checks the restarted service. It may also fetch a newer Basalt commit
when `BASALT_REF` is unpinned; set `BASALT_COMMIT` to the installed commit to
keep the engine version. The native context limit of Qwen3.8-Flash-Next is
262,144 tokens.

## Compaction from clients

Basalt's chat and Responses APIs are stateless: a client sends the active
conversation on each request. To compact a conversation, the client asks the
model to summarize older turns, retains the summary and recent turns, and
sends that shorter history on its next request. Basalt matches the new prompt
against its cached prefixes and reads the changed portion. No Basalt cache
command or server-side Responses compaction endpoint is involved. Keep
`BASALT_KV_RESIDENT` if you need KV streaming; it does not prevent client
compaction.

| Client | How to use compaction with Basalt |
| --- | --- |
| [Open WebUI](https://docs.openwebui.com/troubleshooting/context-window/#the-built-in-option-context-compaction) | An admin enables **Context Compaction** in Settings > Interface. Set its token threshold below the Basalt context served, leaving room for the summary and next answer. For the default 65,536-token Basalt window, 49,152 is a starting point. If other models use the same WebUI, set their model-specific thresholds in Advanced Params; the global token cap must be at least as high as any per-model threshold. An admin or API client can request compaction with `POST /api/v1/chats/{id}/compact` on Open WebUI, not on Basalt. |
| [OpenClaw](https://docs.openclaw.ai/concepts/compaction) | Its built-in runtime automatically summarizes near the configured model window. Use `/compact` in the chat for an immediate summary. Keep `OPENCLAW_CONTEXT_LENGTH=auto` (or set it to the actual served window). |
| [Hermes](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/developer-guide/context-compression-and-caching.md) | Its `compression.enabled` default is `true`; use `/compress` to summarize now. Keep `HERMES_CONTEXT_LENGTH=auto` (or set it to the actual served window). Its compression model must have enough context to read the history being summarized. |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/README.md) | The shipped `dsh` base enables automatic summary compaction and `/compact`. Keep `DSH_CONTEXT_WINDOW=auto` (or set it to the actual served window). |
| [OpenCode](https://opencode.ai/docs/compaction) | Automatic summary compaction is on by default. Use `opencode api post /api/session/<session-id>/compact --data '{}'` to request it. Keep `OPENCODE_CONTEXT_LENGTH=auto` (or set it to the actual served window). Use OpenCode's `summary` compaction type for Basalt; its `native` type calls a provider compaction endpoint that Basalt does not implement. |

Select the concrete Basalt model in an agent when possible: an `auto` or tier
alias can route the summary request to another model with a different context
window. The router advertises Basalt's served context from `/v1/models`, and
the agent installers use that value with their `auto` context setting.

Compaction reduces the **tokens in later requests**. It does not shrink the KV
cache allocated for `BASALT_CONTEXT`, change the pinned RAM estimate above, or
immediately erase cached checkpoints of the old prompt. Size the CT and KV
settings for the configured maximum context even when clients compact early.

## Router registration

```bash
manage-model-servers set-basalt-token --apply
manage-model-servers add basalt://192.0.2.50 --tier xlarge --apply
manage-model-servers set-server-model xlarge basalt://192.0.2.50 qwen3.8-flash-next --apply
```

The key goes to the router's `secrets.env` for discovery, dispatch, monitoring
and LiteLLM. Basalt's public `/health` also allows auto-detection of a bare
address; use `basalt://host:port` for a custom port. With a custom
`BASALT_ALIAS`, use it in `set-server-model` and add `<alias> = 125B` to
`[model_sizes]` in `router.ini` so discovery sizes it.

## Upgrade

```bash
pct push 250 targets/basalt/install-target.sh /root/basalt-target-deploy/install-target.sh --perms 0755
pct push 250 targets/basalt/cuda-toolkit.sh /root/basalt-target-deploy/cuda-toolkit.sh --perms 0755
pct push 250 targets/basalt/basalt.service /root/basalt-target-deploy/basalt.service --perms 0644
pct exec 250 -- bash /root/basalt-target-deploy/install-target.sh --upgrade   # a plain rerun is the same
```

**Settings record.** Every rerun reuses `/etc/basalt-target/installed-env`
(older installs: the `installed-settings` fingerprint); non-empty environment
values override it. Only a fresh install uses defaults; it writes
`pending-env` first so an interrupted first install resumes with the same
choices. An existing checkout or unit without a readable record needs every
setting explicitly; repair or remove a malformed `installed-env`. Healthy
unchanged reruns backfill a missing record.

**Rollback.** The source is fetched before anything stops; nothing happens if
commit, settings, model, unit and health are unchanged. Otherwise Basalt is
stopped, its runnable checkout, venv, launcher and unit are snapshotted to the
root-only `/var/lib/basalt-target/` (a snapshot failure restarts the
original), and it is rebuilt and health-checked. On failure the snapshot is
restored without rebuilding or pip and the old service is health-checked. The
snapshot can contain secrets and is deleted after success or rollback; if the
rollback also fails, it is kept beside a `rollback-failed` marker and every
later run stops until you inspect or restore it and delete the marker. Leave
disk for one checkout copy; `/var/lib/basalt` is not copied (weights inside
`/opt/basalt` are).

## Checks

`bash targets/basalt/test-provision.sh`, `test-install.sh` and
`test-upgrade.sh` (root, against stubs) cover plans, validation, failed
downloads, install, no-op rerun, upgrade and rollback. A real build, download
and health check need the target host.
