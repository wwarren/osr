# Ollama inference target

A plain Ollama server in its own CT, used by the router like any other Ollama
host. The CT and first install come from the Proxmox VE community script
[`ct/ollama.sh`](https://community-scripts.github.io/ProxmoxVE/scripts?id=ollama);
`install-target.sh` then adopts it with a systemd drop-in
(`/etc/systemd/system/ollama.service.d/10-ollama-target.conf`), so the
community unit is never edited and its `update` command keeps working.

| | Community script alone | After `install-target.sh` |
| --- | --- | --- |
| Service account | root | `ollama` (unprivileged), video/render groups |
| Models | `/root/.ollama/models` | `/var/lib/ollama-target/models` (moved, not re-downloaded) |
| Settings | `Environment=` lines in the unit | `/etc/ollama-target/ollama.env` (0640) |
| Hardening | none | `ProtectSystem=strict`, no capabilities, only `/var/lib/ollama-target` writable |
| Upgrades | `update` (latest, no rollback) | `install-target.sh --upgrade` (pinned, checksum-verified, rollback) |

| File | Purpose |
| --- | --- |
| `provision-lxc.sh` | PVE host: runs the community script with presets, copies these files into the CT, optionally adopts |
| `install-target.sh` | In the CT: adopts the install (re-runnable), pulls models, `--upgrade` |
| `ollama-target.conf` | The drop-in: user, env file, hardening |
| `ollama.env.example` | Server settings with defaults |
| `test-install.sh`, `test-provision.sh` | Stubbed tests; nothing is downloaded or created |

## Provision

On the PVE host, from this directory:

```bash
OLLAMA_PULL_MODELS='qwen3:8b qwen3:14b' bash provision-lxc.sh --install-target
```

Interactive runs prompt for IP/CIDR (or `dhcp`), gateway and `rootdir`
storage; preset `IP_CIDR`, `GATEWAY`, `TEMPLATE_STORAGE` and `STORAGE` to skip
them. No address is chosen automatically. The CT ID defaults to the cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID` to choose another). The wrapper runs
the community script with its `var_*` presets; the script still shows its
menu, so choose **Default**. Defaults are larger than the community ones:
4 cores, 16 GB RAM, 128 GB disk, Debian 13. `OLLAMA_CT_OS`/`OLLAMA_CT_VERSION`
choose Debian 12|13 or Ubuntu 22.04|24.04|26.04; Ollama bundles its CUDA and
ROCm runtimes, so the distribution only supplies Mesa for Intel Arc.

The script comes from the community repo's `main` branch and can change
between runs. The wrapper prints its SHA-256; `COMMUNITY_SCRIPT_SHA256`
refuses any other version and `COMMUNITY_SCRIPT_URL` uses a reviewed copy.
`--dry-run` prints the plan and makes no Proxmox queries. Without
`--install-target` the CT stays as the community script built it (Ollama as
root), with the files in `/root/ollama-target-deploy`; adopt it later with
`bash /root/ollama-target-deploy/install-target.sh` in the CT.

**GPU.** `GPU=auto` picks NVIDIA if the host has `/dev/nvidia0`, else AMD if
it has `/dev/kfd`, else Intel for an Arc render node, else none;
`GPU=nvidia|amd|intel|none` forces it. When the host has several GPU types the
community script asks which: answer the vendor the wrapper names.
`GPU_CARD=<PCI address>` (`lspci -D`, e.g. `0000:03:00.0`) picks one card. The
community script passes every card of the vendor, so the wrapper then removes
the other cards' nodes (`renderD*`/`card*` or `/dev/nvidia<N>`), keeps the
shared ones (`/dev/kfd`, `/dev/nvidiactl`, `/dev/nvidia-uvm*`,
`/dev/nvidia-caps/*`), restarts the CT, and warns if the chosen card is
missing. The router installer passes `GPU` and `GPU_CARD`. Set up the host
driver first with `tools/setup-host-gpu.sh --vendors nvidia,amd,intel
[--card <address>]`.

| GPU | Passed through | `install-target.sh` adds |
|---|---|---|
| NVIDIA | `/dev/nvidia*` | NVIDIA user-space matching the host driver, when NVML or CUDA is missing or mismatched |
| AMD Radeon RX 7000/9000, PRO W7000 | `/dev/dri/renderD*`, `/dev/kfd` | Ollama's checksum-verified ROCm archive for the installed release (self-contained) |
| Intel Arc A/B | `/dev/dri/renderD*` | `mesa-vulkan-drivers libvulkan1` for Ollama's Vulkan backend; Arc B needs Mesa 24.2+ (Debian 13: 25.0; Ubuntu 24.04 after `apt upgrade`; Ubuntu 26.04) |

In the CT, `OLLAMA_GPU` (auto: `/dev/kfd` means AMD, an Intel render node
means Arc) selects the runtime. The hardened unit does not grant
`cap_perfmon`, so the Vulkan backend sizes models approximately.

**Context.** `OLLAMA_CONTEXT_LENGTH` (default 65536, 2048–1048576) is the
context for requests that do not set `num_ctx`; it is written to `ollama.env`
and kept by reruns that do not set it. It costs VRAM: under 16 GB use 32768 or
a smaller model. Agents need 65536 (Hermes at least 64000).

## Operate

```bash
systemctl status ollama
journalctl -u ollama -f        # "inference compute" confirms the GPU
ollama pull qwen3:8b           # lands in /var/lib/ollama-target/models
bash /root/ollama-target-deploy/install-target.sh --upgrade      # pinned release
OLLAMA_VERSION=v0.35.0 bash /root/ollama-target-deploy/install-target.sh --upgrade
```

`--upgrade` does nothing when the requested version is installed and answering
(or the service is stopped). Otherwise it downloads the release and
`sha256sum.txt` (plus the ROCm archive when the current release carries ROCm),
refuses a mismatch (`OLLAMA_SHA256` pins one exact archive), keeps the old
release as `/usr/local/lib/ollama.prev` and restores it if the new version
does not answer within `UPGRADE_HEALTH_TIMEOUT` seconds, then reports whether
the old one answers. It touches only the release directory, never the drop-in
or `ollama.env`. An intentionally stopped service stays stopped; a failed unit
is restarted.

## Adding it to the router

```bash
manage-model-servers add http://<CT address>:11434
```

Ollama listens on all interfaces without authentication: keep it on a trusted
network or firewall TCP 11434 to the router. The monitor pins tier models with
the router's `OLLAMA_KEEP_ALIVE`; `OLLAMA_KEEP_ALIVE` in `ollama.env` covers
everything else.
