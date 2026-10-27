# Ollama inference target

On an interactive run, `provision-lxc.sh` lists active LXC template storage and `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE_STORAGE` and `STORAGE` to skip the menus. The community script chooses or downloads its template on the selected template storage. Dry runs make no Proxmox queries.

A plain Ollama server in its own CT, for the router to use like any other
Ollama host. The CT and the initial Ollama install come from the Proxmox VE
community script
[`ct/ollama.sh`](https://community-scripts.github.io/ProxmoxVE/scripts?id=ollama);
the files here preset that script and then bring the result into the same
conventions as the llama.cpp and AirLLM targets.

| | Community script alone | After `install-target.sh` |
| --- | --- | --- |
| Service account | root | `ollama` (unprivileged), video/render groups |
| Models | `/root/.ollama/models` | `/var/lib/ollama-target/models` (moved, not re-downloaded) |
| Settings | `Environment=` lines in the unit | `/etc/ollama-target/ollama.env` |
| Hardening | none | `ProtectSystem=strict`, no capabilities, only `/var/lib/ollama-target` writable |
| Upgrades | `update` (latest release, no rollback) | `install-target.sh --upgrade` (pinned, checksum-verified, rollback); `update` still works |

The adoption is a systemd drop-in
(`/etc/systemd/system/ollama.service.d/10-ollama-target.conf`), so the
community unit is never edited and its `update` command keeps working.

## Files

| File | Purpose |
| --- | --- |
| `provision-lxc.sh` | PVE host: runs the community script with presets, copies these files into the CT, optionally adopts. |
| `install-target.sh` | Inside the CT: adopts the install (safe to re-run), pulls models, `--upgrade`. |
| `ollama-target.conf` | The drop-in: user, env file, hardening. |
| `ollama.env.example` | Server settings with defaults. Installed as `/etc/ollama-target/ollama.env` (0640). |
| `test-install.sh`, `test-provision.sh` | Tests with stubbed system commands; nothing is downloaded or created. |

## Provision

On the PVE host, from this directory:

```bash
CT_ID=270 IP_CIDR=192.0.2.70/24 GATEWAY=192.0.2.1 STORAGE=local-lvm \
OLLAMA_PULL_MODELS='qwen3:8b qwen3:14b' \
bash provision-lxc.sh --install-target
```

This downloads and runs

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/ollama.sh)"
```

with the settings preset as its `var_*` variables (`var_ctid`, `var_cpu`,
`var_ram`, `var_disk`, `var_net`, `var_gateway`, `var_gpu`, ...). The script
still shows its menu: choose **Default** to accept the presets. Defaults
here are larger than the community ones, because models need the room:
4 cores, **16 GB RAM, 128 GB disk**, and a **Debian 13** CT (`var_os`/
`var_version`; the community script's installer handles Debian 13 itself).
`OLLAMA_CT_OS=ubuntu OLLAMA_CT_VERSION=26.04` (or 24.04, 22.04; Debian 12)
picks another distribution; Ollama's releases bundle their CUDA and ROCm
runtimes, so the distribution only supplies Mesa for Intel Arc.

The GPU: `GPU=auto` picks NVIDIA when the host has `/dev/nvidia0`, else AMD
when it has `/dev/kfd`, else Intel for an Arc card's render node, else none;
`GPU=nvidia|amd|intel|none` chooses (`yes` still means NVIDIA, `no` none). The
community script passes the devices through itself; when the host has more
than one GPU type it asks which, so answer the vendor the wrapper names. The
wrapper then checks the CT config and warns if the GPU is missing.

`GPU_CARD=<PCI address>` (for example `0000:03:00.0`, as `lspci -D` shows it)
picks one card on a host with several; `GPU=auto` then means that card's
vendor. The community script passes every card of the vendor, so afterwards
the wrapper deletes the CT's device entries of the other cards (their
`/dev/dri/renderD*` and `card*` nodes, or `/dev/nvidia<N>`), keeps the shared
ones (`/dev/kfd`, `/dev/nvidiactl`, `/dev/nvidia-uvm*`, `/dev/nvidia-caps/*`)
and restarts the CT before `install-target.sh` runs. It warns if the CT does
not pass the chosen card at all. The router installer asks which card Ollama
should use and passes `GPU` and `GPU_CARD`.

| GPU | Passed through | `install-target.sh` adds |
|---|---|---|
| NVIDIA | `/dev/nvidia*` | the repository's NVIDIA 580.173.02 user-space helper, when `nvidia-smi` is missing (before adoption) |
| AMD Radeon RX 7000/9000, PRO W7000 | `/dev/dri/renderD*`, `/dev/kfd` | Ollama's ROCm libraries for the installed release (`ollama-linux-amd64-rocm.tar.zst`, checksum-verified; they bundle ROCm, so nothing else is installed) |
| Intel Arc A/B | `/dev/dri/renderD*` | Mesa's Vulkan driver (`mesa-vulkan-drivers libvulkan1`) for Ollama's built-in Vulkan backend; Arc B needs Mesa 24.2+ (Debian 13 has 25.0, Ubuntu 24.04 25.0 after `apt upgrade`, Ubuntu 26.04 26.0) |

Set the host's driver up first with `tools/setup-host-gpu.sh --vendors
nvidia,amd,intel` (add `--card <address>` for one card; the router installer
does this, and passes `GPU` and `GPU_CARD`). Inside the CT,
`OLLAMA_GPU` (auto: `/dev/kfd` is AMD, an Intel render node is an Arc) tells
`install-target.sh` which runtime to add. Without exposing VRAM through
`cap_perfmon` (which the hardened unit does not grant), Ollama's Vulkan backend
sizes models approximately.

The script comes from the community repo's `main` branch, so it can change
between runs. The wrapper prints its SHA-256; set `COMMUNITY_SCRIPT_SHA256`
to refuse any other version, or `COMMUNITY_SCRIPT_URL` to use a copy you
reviewed. `--dry-run` prints the plan without running anything.

Without `--install-target` the CT is left as the community script built it
(Ollama running as root) with the deployment files in
`/root/ollama-target-deploy`; adopt it later with
`bash /root/ollama-target-deploy/install-target.sh` inside the CT.

## Operate

```bash
systemctl status ollama
journalctl -u ollama -f                       # look for "inference compute" to confirm the GPU
ollama pull qwen3:8b                           # models land in /var/lib/ollama-target/models
bash /root/ollama-target-deploy/install-target.sh --upgrade             # pinned release
OLLAMA_VERSION=v0.35.0 bash /root/ollama-target-deploy/install-target.sh --upgrade
```

On an AMD GPU (or whenever the installed release carries ROCm libraries),
`--upgrade` downloads and verifies the new release's ROCm archive too and
installs both together, so an upgrade never drops ROCm support.

When the requested version is already installed and the server answers as
that version (or the service is stopped), `--upgrade` prints "nothing to do"
without downloading anything. Otherwise it downloads the release archive and
its `sha256sum.txt`, refuses a
mismatch (and, with `OLLAMA_SHA256`, anything but that exact archive), keeps
the old release as `/usr/local/lib/ollama.prev`, and restores it if the server
does not report the new version within `UPGRADE_HEALTH_TIMEOUT` seconds. The
upgrade touches only the release directory, never the drop-in or
`ollama.env`. After a rollback it waits for the previous version to answer and
reports whether it did.

## Adding it to the router

```bash
manage-model-servers add http://<CT address>:11434
```

It listens on all interfaces without authentication, like the other targets:
keep it on the isolated network or firewall TCP 11434 to the router's address.
The monitor pins tier models with the router's `OLLAMA_KEEP_ALIVE`; the
server-side `OLLAMA_KEEP_ALIVE` in `ollama.env` covers everything else.

Upgrades keep an explicitly inactive service stopped. A failed unit is
reapplied and restarted rather than treated as deliberately stopped.
