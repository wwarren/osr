#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# tools/manager-ui/install.sh — install the OSR manager UI in the router CT.
#
# Run as root INSIDE the router CT (from the config repo clone):
#   bash /app/config-repo/tools/manager-ui/install.sh
# or from the Proxmox host:
#   pct exec <CT_ID> -- bash /app/config-repo/tools/manager-ui/install.sh
#
# It installs Node.js 26 from nodejs.org into /opt/node (SHA-256 checked
# against the release's SHASUMS256.txt), copies the UI to /opt/osr-manager-ui,
# creates /etc/osr-manager-ui/password (printed once) and enables
# osr-manager-ui.service on HTTP port 80. Re-run it to update the UI.
#
#   NODE_MAJOR=26            Node.js release line
#   NODE_VERSION=26.x.y      exact release instead of the newest of NODE_MAJOR
#   UI_PORT=80               listening port
#   --uninstall              stop and remove the unit and /opt/osr-manager-ui
#                            (keeps /opt/node and the password)
# ==============================================================================

NODE_MAJOR="${NODE_MAJOR:-26}"
NODE_VERSION="${NODE_VERSION:-}"
UI_PORT="${UI_PORT:-80}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR=/opt/osr-manager-ui
NODE_LINK=/opt/node
ETC_DIR=/etc/osr-manager-ui
UNIT=/etc/systemd/system/osr-manager-ui.service
MMS_BIN=/usr/local/bin/manage-model-servers

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

if [[ "${1:-}" == --uninstall ]]; then
  systemctl disable --now osr-manager-ui.service 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  rm -rf "$APP_DIR"
  echo "Removed the manager UI. Kept ${NODE_LINK} and ${ETC_DIR}."
  exit 0
fi

[[ -x "$MMS_BIN" ]] || die "${MMS_BIN} not found: run this inside the router CT (after an apply)"

# --- Node.js ------------------------------------------------------------------
case "$(uname -m)" in
  x86_64)  arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

current=""
[[ -x "${NODE_LINK}/bin/node" ]] && current="$("${NODE_LINK}/bin/node" --version 2>/dev/null || true)"
want_ok() {
  if [[ -n "$NODE_VERSION" ]]; then [[ "$current" == "v${NODE_VERSION}" ]]
  else [[ "$current" == "v${NODE_MAJOR}."* ]]; fi
}

if want_ok; then
  echo "Node.js ${current} already in ${NODE_LINK}."
else
  command -v curl >/dev/null || die "curl is needed"
  command -v xz >/dev/null || { apt-get update -qq && apt-get install -y -qq xz-utils; }
  if [[ -n "$NODE_VERSION" ]]; then base="https://nodejs.org/dist/v${NODE_VERSION}"
  else base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"; fi
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "${tmp}/SHASUMS256.txt" "${base}/SHASUMS256.txt" ||
    die "could not fetch ${base}/SHASUMS256.txt"
  tarball="$(grep -oE "node-v${NODE_MAJOR}\.[0-9]+\.[0-9]+-linux-${arch}\.tar\.xz$" "${tmp}/SHASUMS256.txt" | head -n1)"
  [[ -n "$NODE_VERSION" ]] && tarball="node-v${NODE_VERSION}-linux-${arch}.tar.xz"
  grep -q "  ${tarball}\$" "${tmp}/SHASUMS256.txt" || die "no ${tarball} in ${base}/SHASUMS256.txt"
  echo "Downloading ${tarball} ..."
  curl -fsSL --retry 3 -o "${tmp}/${tarball}" "${base}/${tarball}"
  (cd "$tmp" && grep "  ${tarball}\$" SHASUMS256.txt | sha256sum -c --quiet -) ||
    die "SHA-256 mismatch for ${tarball}"
  dest="/opt/${tarball%.tar.xz}"
  rm -rf "$dest"
  tar -xJf "${tmp}/${tarball}" -C /opt
  ln -sfn "$dest" "$NODE_LINK"
  echo "Installed $("${NODE_LINK}/bin/node" --version) in ${dest} (${NODE_LINK})."
fi

# --- the app ------------------------------------------------------------------
install -d -m 0755 "$APP_DIR" "${APP_DIR}/public"
install -m 0644 "${SRC_DIR}/server.mjs" "${SRC_DIR}/commands.mjs" "$APP_DIR/"
install -m 0644 "${SRC_DIR}/public/index.html" "${SRC_DIR}/public/app.js" "${SRC_DIR}/public/style.css" "${APP_DIR}/public/"

install -d -m 0700 "$ETC_DIR"
if [[ ! -s "${ETC_DIR}/password" ]]; then
  ( umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(18))' > "${ETC_DIR}/password" )
  new_password=true
else
  new_password=false
fi
if [[ "$UI_PORT" != 80 ]]; then
  ( umask 077; printf 'PORT=%s\n' "$UI_PORT" > "${ETC_DIR}/env" )
fi

if ss -Hltn "sport = :${UI_PORT}" 2>/dev/null | grep -q . && ! systemctl is-active --quiet osr-manager-ui.service; then
  die "port ${UI_PORT} is already in use (ss -ltnp 'sport = :${UI_PORT}'); set UI_PORT"
fi

install -m 0644 "${SRC_DIR}/osr-manager-ui.service" "$UNIT"
systemctl daemon-reload
systemctl enable osr-manager-ui.service >/dev/null
systemctl restart osr-manager-ui.service

for _ in $(seq 1 20); do
  curl -fsS -o /dev/null "http://127.0.0.1:${UI_PORT}/healthz" 2>/dev/null && break
  sleep 0.5
done
curl -fsS -o /dev/null "http://127.0.0.1:${UI_PORT}/healthz" ||
  die "the UI did not come up: journalctl -u osr-manager-ui -n 50"

ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
suffix=""
[[ "$UI_PORT" == 80 ]] || suffix=":${UI_PORT}"
echo "Manager UI: http://${ip:-<ct-ip>}${suffix}/  (user: admin)"
if $new_password; then
  echo "Password  : $(cat "${ETC_DIR}/password")   (stored in ${ETC_DIR}/password; shown once)"
else
  echo "Password  : unchanged (${ETC_DIR}/password)"
fi
echo "Plain HTTP: use it only on a trusted network, or put a TLS proxy in front."
