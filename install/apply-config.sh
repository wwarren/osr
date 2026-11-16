#!/usr/bin/env bash
# Copy configuration from the cloned repo into its runtime locations.
# Invoked by the installer during provisioning; safe to re-run by hand after a
# `git pull` in the repo directory, followed by: systemctl daemon-reload &&
# systemctl restart litellm-proxy osr-router osr-monitor open-webui
set -euo pipefail
REPO_DIR="${1:-/app/config-repo}"
ROUTER_DIR="${2:-/app/router}"
OPENWEBUI_DIR="${3:-/app/openwebui}"
UNIT_DIR="${4:-/etc/systemd/system}"

install -d -m 0755 "$ROUTER_DIR" "$OPENWEBUI_DIR"

# Application code + per-service config
install -m 0644 "${REPO_DIR}/services/osr-router/router.py"   "${ROUTER_DIR}/router.py"
install -m 0644 "${REPO_DIR}/services/osr-router/router.ini"  "${ROUTER_DIR}/router.ini"
install -m 0644 "${REPO_DIR}/services/osr-monitor/monitor.py"  "${ROUTER_DIR}/monitor.py"
install -m 0644 "${REPO_DIR}/services/osr-monitor/monitor.ini" "${ROUTER_DIR}/monitor.ini"
install -m 0644 "${REPO_DIR}/services/litellm-proxy/litellm_config.yaml" \
                "${ROUTER_DIR}/litellm_config.yaml"

# Environment files (contain secrets -> root:osr-router 0640)
install -m 0640 -o root -g osr-router "${REPO_DIR}/env/router.env"    "${ROUTER_DIR}/.env"
install -m 0640 -o root -g osr-router "${REPO_DIR}/env/openwebui.env" "${OPENWEBUI_DIR}/.env"

# systemd units. Units from before the rename (ollama-router, ollama-monitor)
# left in the repo next to their successors are not installed, so two routers
# never compete for the same port.
for unit in "${REPO_DIR}"/services/*/*.service; do
  name="$(basename "$unit")"
  case "$name" in
    ollama-router.service|ollama-monitor.service)  # pre-rename names
      new="osr-${name#ollama-}"
      if [ -f "${REPO_DIR}/services/${new%.service}/${new}" ]; then
        echo "Not installing ${unit#"${REPO_DIR}"/}: it was renamed to ${new}." >&2
        continue
      fi ;;
  esac
  install -m 0644 "$unit" "${UNIT_DIR}/${name}"
done

# Seeding through the Gitea contents API does not preserve the executable bit,
# so restore it on the repo's own scripts.
chmod 0755 "${REPO_DIR}"/install/*.sh 2>/dev/null || true

# Expose the server-management tool on PATH. A symlink (not a copy) means a
# `git pull` in the repo updates the command too.
if [ -f "${REPO_DIR}/install/manage-model-servers.sh" ]; then
  ln -sfn "${REPO_DIR}/install/manage-model-servers.sh" /usr/local/bin/manage-model-servers
else
  echo "WARNING: ${REPO_DIR}/install/manage-model-servers.sh is missing, so manage-model-servers is not on PATH." >&2
fi

echo "Configuration applied from ${REPO_DIR}."
