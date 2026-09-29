# Ollama inference target

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
4 cores, **16 GB RAM, 128 GB disk**. `GPU=auto` passes the GPU through when
the host has `/dev/nvidia0`; when `nvidia-smi` is then missing inside the CT,
the repository's NVIDIA 580.173.02 user-space helper runs before adoption.

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

`--upgrade` downloads the release archive and its `sha256sum.txt`, refuses a
mismatch (and, with `OLLAMA_SHA256`, anything but that exact archive), keeps
the old release as `/usr/local/lib/ollama.prev`, and restores it if the server
does not report the new version within `UPGRADE_HEALTH_TIMEOUT` seconds.

## Adding it to the router

```bash
manage-model-servers add http://<CT address>:11434
```

It listens on all interfaces without authentication, like the other targets:
keep it on the isolated network or firewall TCP 11434 to the router's address.
The monitor pins tier models with the router's `OLLAMA_KEEP_ALIVE`; the
server-side `OLLAMA_KEEP_ALIVE` in `ollama.env` covers everything else.
