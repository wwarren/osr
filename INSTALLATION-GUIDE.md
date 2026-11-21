# First-time installation guide

This guide takes you from a Proxmox host to a working Open WebUI chat and OpenAI-compatible API. It assumes you are new to Open Smart Router (OSR). The simplest path is **one router container and one Ollama model-server container**. You can add more model servers, agents, image generation, Gitea, and Mattermost later.

OSR runs in a Proxmox Linux container (CT). It routes requests to a **separate model server**; the router CT does not run the models. An Ollama target is one way to create that server during installation. If you already have a reachable model server, you can use it instead.

## 1. Check the requirements

You need:

- A Proxmox host you can access as `root`, with the `pct`, `pveam`, and `pvesm` tools. The installer also needs `curl` and `python3` on the host.
- A **full checkout** of this repository on that host. The installer reads files from `install/`, `services/`, `targets/`, and `tools/`; a copy of the installer script alone is insufficient.
- A Proxmox network bridge, such as `vmbr0`, and an unused **static IPv4 address with CIDR prefix** for the router (for example, `192.0.2.50/24`). That example address is reserved for documentation; use an address from your own network. Have the gateway address ready. Every optional target CT needs its own unused static address and CT ID.
- Storage that supports Proxmox `rootdir` content and has enough free space. Template storage must support `vztmpl` content. The router defaults to **2 vCPU, 4 GB RAM, and a 32 GB root disk**. A new Ollama target defaults to **4 cores, 16 GB RAM, and a 128 GB disk**; its disk must also hold the models you pull. A host running both default CTs needs room for **20 GB of assigned RAM and 160 GB of CT disks**, with additional capacity for Proxmox itself. See [storage and CT settings](INSTALLATION.md#router-settings) and the [Ollama target guide](targets/ollama/README.md#provision).
- Network access from the CTs to package and model download sources, plus access between the router and its model server. The installer updates the Proxmox template index and can download a Debian 13 CT template. Open WebUI can take up to ten minutes on first start while it downloads an embedding model.
- At least one model server. You can select the Ollama target in the installer, or provide the address of an existing Ollama, LM Studio, or other [supported inference target](INFERENCE_TARGETS.md).

A GPU is optional for the router and for Ollama, though CPU inference can be slow. Other targets have different GPU, RAM, disk, and distribution requirements. Check the [target table](INFERENCE_TARGETS.md) and [GPU requirements](INSTALLATION.md#host-gpu) before selecting them. The installer checks selected GPU drivers before creating CTs; if a driver installation requires a reboot, reboot and rerun the installer.

If the Proxmox firewall is enabled, plan which trusted subnet may reach the router's ports **8000** (API), **8080** (Open WebUI), and **3000** (Grafana). Set `API_ALLOW_CIDR` for that subnet when using `FIREWALL=1`; otherwise those ports may be dropped. The router must also be able to reach each model server's port. See [network and ports](ARCHITECTURE.md#8-network-and-ports).

### Write down your choices

| Item | Your value |
|---|---|
| Proxmox bridge and gateway | `vmbr0`, `________` |
| Router CT ID and unused IP/CIDR | `________`, `________/____` |
| Router rootfs storage and template storage | `________`, `________` |
| Model server: new Ollama CT or existing server | `________` |
| If new Ollama: CT ID, IP/CIDR, storage | `________`, `________/____`, `________` |
| Model ID to serve (must fit your hardware) | `________` |
| Trusted client subnet for firewall rules, if used | `________/____` |

The installer proposes the next free CT ID, but **never chooses an IP address**. Make sure each address is unused before starting. An IP/CIDR is the address *with* its prefix length; a gateway is just an IP address.

## 2. Get the full repository on the Proxmox host

Log in to the Proxmox host as `root` and clone the project:

```bash
git clone https://github.com/wwarren/osr.git
cd osr
```

If you already have a full checkout, change into its directory instead. Confirm that `open-smart-router-install.sh` and the `targets/` directory are present. Run all following installer commands from this directory. You'll have to make the installer executable with "```chmod +x open-smart-router-install.sh```".

## 3. Choose the first model server

**New to model serving?** Select `ollama` when the installer asks for optional targets. It will ask for the Ollama CT's ID, IP/CIDR, and storage, then create and provision it after the router is ready. The Ollama target offers a prompt for models to pull. Choose a model that fits the available RAM or VRAM, and write down its exact tag. For a small first setup, the [Ollama guide](targets/ollama/README.md) uses `qwen3:8b` as an example; the model download needs enough free disk space.

**Already running a model server?** Select `none` for optional targets, then enter that server's reachable IP, host and port, or supported `kind://host` address when asked for model servers. Make sure it serves a model and accepts connections from the router CT. The [inference target guide](INFERENCE_TARGETS.md) lists address formats and ports.

The installer requires **1–20 model servers**. It fills the first server slots for any model targets you selected. If you selected one Ollama target, choose one server unless you are adding existing servers too.

## 4. Run the interactive installer

```bash
bash open-smart-router-install.sh
```

Work through the prompts in this order:

1. **Optional targets:** For the simple path, enter `ollama`. Choose `none` if you already have a model server. Gitea, Mattermost, agents, and tools can wait until the basic router works. The menu accepts names or numbers; `INSTALL_TARGETS` environment presets accept names only.
2. **Router CT:** Accept the suggested free CT ID or enter your chosen one. Set a root password for the CT.
3. **Network:** Enter the Proxmox bridge, the router's static IP/CIDR, and the gateway. The gateway should be on the router's subnet. You can leave DNS blank to inherit the host's nameserver.
4. **Storage and template:** Accept the 32 GB router disk unless you have a reason to change it. Choose storage with `rootdir` support and enough space. Choose template storage; the installer updates the index and offers a Debian 13 template, downloading one if needed.
5. **Selected target settings:** For each new target, enter a different CT ID, unused static IP/CIDR, and storage. For Ollama, choose a GPU card if offered, or `none` for CPU. Check the suggested context window against your available memory. If a community-script menu appears for Ollama, choose **Default**.
6. **Cluster SSH:** On a Proxmox cluster, the installer checks root SSH between nodes for later upgrades. Follow its repair prompts if needed. A standalone host has no cluster SSH work.
7. **Gitea and Mattermost:** Leave the Gitea URL blank if you are not using Gitea; OSR will install its configuration locally without version control. Leave the Mattermost webhook blank if you are not using alerts; the monitor will log alerts instead. If you selected these service CTs, use the credentials and webhook created for them. See [Gitea settings](INSTALLATION.md#router-settings) for token requirements.
8. **Model servers and tiers:** For one Ollama target, keep its prefilled server address and enter `1` for the server count. Assign server `1` to the `fast`, `medium`, `large`, and `xlarge` tiers. Enter the **exact model tag you will pull** for each tier; using the same tag in all four tiers is fine for a first setup. Do not accept the example defaults unless your server actually has those models. Leave keep-alive blank to use the Ollama server setting, or choose a duration such as `2h`.
9. **Review the routing plan:** Check the server addresses, tier assignments, and model tags before the installer creates the router CT. The installer then provisions the router and selected targets. Model downloads can take time.

If you select a companion such as Hermes, Honcho, or Open Terminal, the installer will later pause for an **Open WebUI admin API key**. Open the printed WebUI URL, create the first admin account, enable API keys under **Admin Settings > Authentication**, then create a key under **Settings > Account > API keys** and paste it into the installer. Without a key, most companions are skipped; DeepSeek Harness can install without its Open WebUI endpoint. See [companion setup](INSTALLATION.md#install).

The installer prints the router CT ID, service IP, WebUI URL, API URL, Grafana login, and any target failures at the end. Save that summary. A failed model or companion target leaves the router running and includes retry instructions.

## 5. Finish model setup and open the UI

For a new Ollama target, confirm that the intended model was pulled. If you did not request a pull during provisioning, pull it in the Ollama CT (replace `456` and the example tag with your choices):

```bash
pct exec 456 -- ollama pull qwen3:8b
pct exec 456 -- ollama list
```

The model tag shown by `ollama list` must match the tag you entered for the router tiers. See the [Ollama target guide](targets/ollama/README.md#operate) if the pull or service fails.

Open `http://<router-ip>:8080` in a browser. The **first visitor creates the Open WebUI admin account**. WebUI is preconnected to OSR. Its first start may take up to ten minutes; refresh after the embedding model download finishes. Start a chat with the model you configured. The router API base URL is `http://<router-ip>:8000/v1` and requires the generated bearer key in `/app/router/secrets.env` inside the router CT.

## 6. Verify the installation

Use the router CT ID printed by the installer. In these examples, replace `123` with that ID:

```bash
pct status 123
pct exec 123 -- systemctl status osr-router open-webui litellm-proxy osr-monitor
pct exec 123 -- /usr/local/bin/manage-model-servers status
pct exec 123 -- /usr/local/bin/manage-model-servers models
```

The services should be active, and the model-server status should show a reachable host with the model you chose. If Grafana was installed, open `http://<router-ip>:3000`; the installer prints its initial `admin` password. To retrieve that initial login again:

```bash
pct exec 123 -- bash /app/config-repo/install/setup-metrics.sh login
```

If WebUI shows no models, check the server status and the [troubleshooting guide](TROUBLESHOOTING.md). For a failed target, follow the retry command in the installer's summary. For ongoing changes, see [managing model servers](MODEL_SERVERS.md), [applying configuration](CONFIGURATION.md), and [updating](UPDATING.md). You can add [MQTT and hcom agent coordination](AGENT_COORDINATION.md) after the basic setup works.
