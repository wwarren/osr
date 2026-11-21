#!/usr/bin/env bash
# Install a small local Prometheus + Grafana stack in the router CT.
# Run as root: bash /app/config-repo/install/setup-metrics.sh [install|sync-key|login]
# login prints Grafana's address and first login and changes nothing.
set -euo pipefail

MODE="${1:-install}"
ROUTER_DIR="${ROUTER_DIR:-/app/router}"
SECRETS_FILE="${SECRETS_FILE:-${ROUTER_DIR}/secrets.env}"
# Optional: an exact Grafana package version (apt's grafana=<version>) instead
# of the newest in Grafana's stable repository, and the fingerprint its signing
# key must have (40 hex digits, spaces allowed). Without a fingerprint the key
# is trusted as downloaded over HTTPS.
GRAFANA_VERSION="${GRAFANA_VERSION:-}"
GRAFANA_KEY_FINGERPRINT="${GRAFANA_KEY_FINGERPRINT:-}"
# Tests only: a directory that stands in for / when files are written. What the
# written files say (paths in units and configuration) is never prefixed.
FS="${OSR_METRICS_ROOT:-}"
KEY_FILE=/etc/prometheus/osr-router-key

die() { printf 'metrics setup: %s\n' "$*" >&2; exit 1; }
note() { printf 'metrics setup: %s\n' "$*" >&2; }

[[ $EUID -eq 0 || -n $FS ]] || die 'run as root in the router CT'
[[ $MODE == install || $MODE == sync-key || $MODE == sync-sensors || $MODE == login ]] || die 'usage: setup-metrics.sh [install|sync-key|sync-sensors|login]'

env_value() {
  local file=$1 key=$2
  [[ -f $file ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

sync_key() {
  local key tmp
  [[ -d ${FS}/etc/prometheus ]] || { [[ $MODE == sync-key ]] && return 0; die 'Prometheus is not installed'; }
  key="$(env_value "$SECRETS_FILE" ROUTER_API_KEY)"
  if [[ -z $key && -f ${FS}${KEY_FILE} ]]; then
    # An older router may deliberately have authentication off. Retain an
    # existing token: the router ignores it while authentication is disabled.
    return 0
  fi
  # No key and no file yet: the scrape needs the file to exist, so it starts
  # empty. The router asks for nothing while it has no key, and the next apply
  # after `set-api-key` fills it in.
  [[ $key != *$'\n'* && $key != *$'\r'* ]] || die 'invalid router key'
  tmp="$(mktemp "${FS}/etc/prometheus/.osr-router-key.XXXXXX")"
  if [[ -n $key ]]; then printf '%s\n' "$key" > "$tmp"; fi
  chown prometheus:prometheus "$tmp"
  chmod 0600 "$tmp"
  if [[ -f ${FS}${KEY_FILE} ]] && cmp -s "$tmp" "${FS}${KEY_FILE}"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "${FS}${KEY_FILE}"
  if [[ $MODE == sync-key ]] && systemctl is-active --quiet osr-prometheus.service; then
    systemctl restart osr-prometheus.service
  fi
  note 'router scrape key updated'
}

# Grafana's address and first login, on stdout so that whoever ran the setup
# can copy them. osr.env holds only the password a new Grafana database started
# with, so it is tried first: one that no longer signs in is not shown as if it
# did. It reaches curl on stdin, never on a command line. Says nothing where
# this script has not set Grafana up.
show_login() {
  local address password code
  [[ -e ${FS}/etc/systemd/system/grafana-server.service.d/osr.conf ]] || return 0
  address="$(hostname -I 2>/dev/null | awk '{ print $1 }')" || true
  password="$(env_value "${FS}/etc/grafana/osr.env" GF_SECURITY_ADMIN_PASSWORD)"
  printf 'Grafana:  http://%s:3000\n' "${address:-<ct-ip>}"
  if [[ -z $password ]]; then
    printf '  No password was set here: Grafana kept the login it already had.\n'
    return 0
  fi
  code="$(printf 'user = "admin:%s"\n' "$password" |
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -K - http://127.0.0.1:3000/api/user 2>/dev/null)" || true
  if [[ $code == 401 ]]; then
    printf '  The admin password has been changed since setup; the first one no longer signs in.\n'
    return 0
  fi
  printf 'Username: admin\nPassword: %s\n' "$password"
  [[ $code == 200 ]] || printf '  (not checked: Grafana did not answer. This is the password it started with.)\n'
}

if [[ $MODE == sync-key ]]; then
  sync_key
  exit 0
fi
if [[ $MODE == login ]]; then
  show_login
  exit 0
fi

write_scrape_config() {
  local router_host router_port sensor_target
  router_host="$(env_value "${ROUTER_DIR}/.env" ROUTER_HOST)"
  router_port="$(env_value "${ROUTER_DIR}/.env" ROUTER_PORT)"
  router_port="${router_port:-8000}"
  [[ $router_port =~ ^[0-9]+$ ]] && (( router_port >= 1 && router_port <= 65535 )) || die 'invalid ROUTER_PORT'
  case "$router_host" in
    ''|0.0.0.0|127.0.0.1|localhost|::|::1) router_host=127.0.0.1 ;;
    *:*) [[ $router_host =~ ^[0-9a-fA-F:]+$ ]] || die 'invalid ROUTER_HOST'; router_host="[$router_host]" ;;
    *) [[ $router_host =~ ^[a-zA-Z0-9.-]+$ ]] || die 'invalid ROUTER_HOST' ;;
  esac
  cat > "${FS}/etc/prometheus/osr.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: osr
    metrics_path: /metrics
    authorization:
      credentials_file: ${KEY_FILE}
    static_configs:
      - targets: ['${router_host}:${router_port}']
EOF
  sensor_target="$(cat "${FS}/etc/prometheus/osr-sensors-target" 2>/dev/null || true)"
  if [[ -n $sensor_target ]]; then
    [[ $sensor_target =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:9408$ ]] || die 'invalid sensor target'
    [[ -s ${FS}/etc/prometheus/osr-sensors-key ]] || die 'missing sensor scrape key'
    cat >> "${FS}/etc/prometheus/osr.yml" <<EOF
  - job_name: osr-temperature
    metrics_path: /metrics
    authorization:
      credentials_file: /etc/prometheus/osr-sensors-key
    static_configs:
      - targets: ['${sensor_target}']
EOF
  fi
  chmod 0644 "${FS}/etc/prometheus/osr.yml"
  promtool check config "${FS}/etc/prometheus/osr.yml"
}

if [[ $MODE == sync-sensors ]]; then
  [[ -d ${FS}/etc/prometheus && -f ${FS}/etc/prometheus/osr.yml ]] || die 'install the metrics stack first'
  [[ -s ${FS}/etc/prometheus/osr-sensors-key ]] || die 'missing sensor scrape key'
  [[ ${OSR_SENSOR_TARGET:-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:9408$ ]] || die 'OSR_SENSOR_TARGET must be a host IPv4 address on port 9408'
  printf '%s\n' "$OSR_SENSOR_TARGET" > "${FS}/etc/prometheus/osr-sensors-target"
  chmod 0644 "${FS}/etc/prometheus/osr-sensors-target"
  write_scrape_config
  systemctl restart osr-prometheus.service
  note "sensor scrape configured for ${OSR_SENSOR_TARGET}"
  exit 0
fi

[[ -f $SECRETS_FILE ]] || die "missing ${SECRETS_FILE}"
if [[ -n $GRAFANA_KEY_FINGERPRINT ]]; then
  GRAFANA_KEY_FINGERPRINT="${GRAFANA_KEY_FINGERPRINT// /}"
  [[ ${GRAFANA_KEY_FINGERPRINT^^} =~ ^[0-9A-F]{40}$ ]] || die 'GRAFANA_KEY_FINGERPRINT must be 40 hex digits'
fi
[[ -z $GRAFANA_VERSION || $GRAFANA_VERSION =~ ^[0-9][0-9A-Za-z.+~:-]*$ ]] || die 'invalid GRAFANA_VERSION'

# Put authentication in place before the package is installed: a package
# post-install step may start Grafana immediately. systemd reads EnvironmentFile
# itself, so Grafana needs no access to the file; the package may still make
# files under /etc/grafana readable by the grafana group, which changes
# nothing: Grafana has the password in its environment either way.
install -d -m 0755 "${FS}/etc/grafana" "${FS}/etc/systemd/system/grafana-server.service.d"
if [[ ! -e ${FS}/etc/grafana/osr.env && ! -e ${FS}/var/lib/grafana/grafana.db ]]; then
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  ( umask 077; printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$password" > "${FS}/etc/grafana/osr.env" )
  chmod 0600 "${FS}/etc/grafana/osr.env"
elif [[ ! -e ${FS}/etc/grafana/osr.env ]]; then
  note 'Grafana already has a database; preserving its existing admin login'
  : > "${FS}/etc/grafana/osr.env"
  chmod 0600 "${FS}/etc/grafana/osr.env"
fi
cat > "${FS}/etc/systemd/system/grafana-server.service.d/osr.conf" <<'EOF'
[Service]
EnvironmentFile=/etc/grafana/osr.env
Environment=GF_SERVER_HTTP_ADDR=0.0.0.0 GF_SERVER_HTTP_PORT=3000 GF_AUTH_ANONYMOUS_ENABLED=false GF_USERS_ALLOW_SIGN_UP=false GF_ANALYTICS_REPORTING_ENABLED=false GF_ANALYTICS_CHECK_FOR_UPDATES=false
EOF
systemctl daemon-reload

# Debian's Prometheus package supplies the binary and its unprivileged user.
# Use our own loopback-only unit, so the package's default web listener is not
# exposed and its storage budget is explicit.
if systemctl is-active --quiet prometheus.service; then
  die 'an existing prometheus.service is running; stop it or keep using it instead of the local OSR stack'
fi
systemctl mask prometheus.service
export DEBIAN_FRONTEND=noninteractive
apt-get update
# --no-install-recommends: Debian's prometheus recommends prometheus-node-exporter,
# which would start an unauthenticated listener on every address (port 9100).
apt-get install -y --no-install-recommends ca-certificates wget prometheus
systemctl mask --now prometheus.service

# Grafana OSS from the vendor's signed stable Debian repository.
install -d -m 0755 "${FS}/etc/apt/keyrings" "${FS}/etc/apt/sources.list.d"
key_tmp="$(mktemp "${FS}/etc/apt/keyrings/.grafana.XXXXXX")"
wget -qO "$key_tmp" https://apt.grafana.com/gpg-full.key || { rm -f "$key_tmp"; die 'could not download the Grafana signing key'; }
if [[ -n $GRAFANA_KEY_FINGERPRINT ]]; then
  command -v gpg >/dev/null 2>&1 || apt-get install -y --no-install-recommends gnupg
  # Every primary key in the file must be the expected one.
  found="$(gpg --show-keys --with-colons "$key_tmp" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }' | sort -u)"
  if [[ ${found^^} != "${GRAFANA_KEY_FINGERPRINT^^}" ]]; then
    rm -f "$key_tmp"
    die "the Grafana signing key is not ${GRAFANA_KEY_FINGERPRINT} (found: ${found:-none}); nothing was installed from it"
  fi
fi
chmod 0644 "$key_tmp"
mv -f "$key_tmp" "${FS}/etc/apt/keyrings/grafana.asc"
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > "${FS}/etc/apt/sources.list.d/grafana.list"
apt-get update
apt-get install -y "grafana${GRAFANA_VERSION:+=${GRAFANA_VERSION}}"
systemctl stop grafana-server.service 2>/dev/null || true

sync_key

write_scrape_config
mkdir -p "${FS}/var/lib/prometheus/osr"
chown prometheus:prometheus "${FS}/var/lib/prometheus/osr"
chmod 0750 "${FS}/var/lib/prometheus/osr"

cat > "${FS}/etc/systemd/system/osr-prometheus.service" <<'EOF'
[Unit]
Description=Open Smart Router Prometheus scraper
After=network-online.target osr-router.service
Wants=network-online.target
[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/bin/prometheus --config.file=/etc/prometheus/osr.yml --storage.tsdb.path=/var/lib/prometheus/osr --storage.tsdb.retention.time=7d --storage.tsdb.retention.size=512MB --web.listen-address=127.0.0.1:9090
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/prometheus/osr
CapabilityBoundingSet=
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 "${FS}/etc/grafana/provisioning/datasources" "${FS}/etc/grafana/provisioning/dashboards" "${FS}/etc/grafana/osr-dashboards"
cat > "${FS}/etc/grafana/provisioning/datasources/osr.yml" <<'EOF'
apiVersion: 1
datasources:
  - name: OSR Prometheus
    uid: osr-prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
EOF
cat > "${FS}/etc/grafana/provisioning/dashboards/osr.yml" <<'EOF'
apiVersion: 1
providers:
  - name: Open Smart Router
    orgId: 1
    folder: Open Smart Router
    type: file
    disableDeletion: false
    editable: false
    options:
      path: /etc/grafana/osr-dashboards
EOF
cat > "${FS}/etc/grafana/osr-dashboards/router.json" <<'EOF'
{
  "uid": "osr-router", "title": "Open Smart Router", "schemaVersion": 39,
  "version": 3, "refresh": "15s", "time": {"from": "now-6h", "to": "now"},
  "panels": [
    {"id": 1, "type": "stat", "title": "Router scrape", "description": "Prometheus can scrape the protected router /metrics endpoint.", "gridPos": {"x": 0, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"mappings": [{"type": "value", "options": {"0": {"text": "Down", "color": "red"}, "1": {"text": "Up", "color": "green"}}}], "thresholds": {"mode": "absolute", "steps": [{"color": "red"}, {"color": "green", "value": 1}]}}, "overrides": []}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "up{job=\"osr\"}", "instant": true}]},
    {"id": 2, "type": "stat", "title": "Requests / sec", "description": "All router answers, averaged over five minutes.", "gridPos": {"x": 4, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "reqps"}}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "sum(rate(osr_requests_total[5m])) or vector(0)", "instant": true}]},
    {"id": 3, "type": "stat", "title": "HTTP 5xx %", "description": "Router answers with a 5xx status as a share of all answers over five minutes.", "gridPos": {"x": 8, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "percent", "thresholds": {"mode": "absolute", "steps": [{"color": "green"}, {"color": "yellow", "value": 1}, {"color": "red", "value": 5}]}}}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "100 * (sum(rate(osr_requests_total{status=~\"5..\"}[5m])) or vector(0)) / clamp_min(sum(rate(osr_requests_total[5m])) or vector(0), 1e-9)", "instant": true}]},
    {"id": 4, "type": "stat", "title": "Servers up", "description": "Model servers currently marked up by the router.", "gridPos": {"x": 12, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "sum(osr_server_up)", "instant": true}]},
    {"id": 5, "type": "stat", "title": "Models listed", "description": "Sum of models found across model servers; the same model may appear on several servers.", "gridPos": {"x": 16, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "sum(osr_server_models)", "instant": true}]},
    {"id": 6, "type": "stat", "title": "Inventory age", "description": "Time since the router last refreshed model inventory.", "gridPos": {"x": 20, "y": 0, "w": 4, "h": 4}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}}, "targets": [{"refId": "A", "expr": "osr_inventory_age_seconds", "instant": true}]},
    {"id": 7, "type": "timeseries", "title": "Requests by route and status", "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "reqps"}}, "targets": [{"refId": "A", "expr": "sum by (route, status) (rate(osr_requests_total[5m]))", "legendFormat": "{{route}} {{status}}"}]},
    {"id": 8, "type": "timeseries", "title": "Upstream failures by server and reason", "description": "Failed attempts can be followed by a successful retry on another server.", "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "ops"}}, "targets": [{"refId": "A", "expr": "sum by (server, reason) (rate(osr_upstream_failures_total[5m]))", "legendFormat": "{{server}} {{reason}}"}]},
    {"id": 9, "type": "timeseries", "title": "Response start latency", "description": "Arrival until response headers are sent, across all requests.", "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.5, sum by (le) (rate(osr_response_start_seconds_bucket[5m])))", "legendFormat": "p50"}, {"refId": "B", "expr": "histogram_quantile(0.95, sum by (le) (rate(osr_response_start_seconds_bucket[5m])))", "legendFormat": "p95"}]},
    {"id": 10, "type": "timeseries", "title": "Request duration", "description": "Arrival until the final response byte, across all requests.", "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.5, sum by (le) (rate(osr_request_duration_seconds_bucket[5m])))", "legendFormat": "p50"}, {"refId": "B", "expr": "histogram_quantile(0.95, sum by (le) (rate(osr_request_duration_seconds_bucket[5m])))", "legendFormat": "p95"}]},
    {"id": 11, "type": "timeseries", "title": "Response start p95 by model", "gridPos": {"x": 0, "y": 20, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, model) (rate(osr_response_start_seconds_bucket{model!=\"\"}[5m])))", "legendFormat": "{{model}}"}]},
    {"id": 12, "type": "timeseries", "title": "Request duration p95 by model", "gridPos": {"x": 12, "y": 20, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, model) (rate(osr_request_duration_seconds_bucket{model!=\"\"}[5m])))", "legendFormat": "{{model}}"}]},
    {"id": 13, "type": "timeseries", "title": "Requests in flight by server", "gridPos": {"x": 0, "y": 28, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "targets": [{"refId": "A", "expr": "osr_in_flight_requests", "legendFormat": "{{server}}"}]},
    {"id": 14, "type": "timeseries", "title": "Server availability", "description": "1 means up; 0 means down according to the last discovery poll or dispatch.", "gridPos": {"x": 12, "y": 28, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"min": 0, "max": 1}}, "targets": [{"refId": "A", "expr": "osr_server_up", "legendFormat": "{{server}}"}]},
    {"id": 15, "type": "timeseries", "title": "Models per server", "gridPos": {"x": 0, "y": 36, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "targets": [{"refId": "A", "expr": "osr_server_models", "legendFormat": "{{server}}"}]},
    {"id": 16, "type": "timeseries", "title": "Remembered conversations", "description": "Conversations whose last server is remembered for affinity.", "gridPos": {"x": 12, "y": 36, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "targets": [{"refId": "A", "expr": "osr_remembered_conversations", "legendFormat": "remembered"}]},
    {"id": 17, "type": "timeseries", "title": "Host CPU temperature", "description": "CPU sensor readings from the Proxmox host running the router.", "gridPos": {"x": 0, "y": 44, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "celsius"}}, "targets": [{"refId": "A", "expr": "osr_cpu_temperature_celsius", "legendFormat": "{{chip}} {{sensor}}"}]},
    {"id": 18, "type": "timeseries", "title": "Host GPU temperature", "description": "GPU sensor readings from the Proxmox host running the router.", "gridPos": {"x": 12, "y": 44, "w": 12, "h": 8}, "datasource": {"type": "prometheus", "uid": "osr-prometheus"}, "fieldConfig": {"defaults": {"unit": "celsius"}}, "targets": [{"refId": "A", "expr": "osr_gpu_temperature_celsius", "legendFormat": "{{vendor}} {{device}} {{sensor}}"}]}
  ]
}
EOF
chmod 0644 "${FS}/etc/grafana/provisioning/datasources/osr.yml" "${FS}/etc/grafana/provisioning/dashboards/osr.yml" "${FS}/etc/grafana/osr-dashboards/router.json"

systemctl daemon-reload
# restart, not enable --now: a rerun must pick up a changed unit or scrape
# target, and --now leaves a running service as it is.
systemctl enable osr-prometheus.service
systemctl restart osr-prometheus.service
systemctl enable grafana-server.service
systemctl restart grafana-server.service
# "active" only says the process was started: a service that exits a moment
# later, or one still migrating its database, is active too. Ready means it
# answers. Grafana's first start can take a while, so it gets READY_TIMEOUT
# seconds (default 180); on failure the end of its journal says why.
wait_ready() {
  local unit=$1 url=$2 waited=0 limit="${READY_TIMEOUT:-180}"
  while (( waited < limit )); do
    if systemctl is-failed --quiet "$unit"; then break; fi
    if curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; then return 0; fi
    sleep 3
    waited=$((waited + 3))
  done
  note "${unit} does not answer on ${url}. Its last log lines:"
  journalctl -u "$unit" -n 25 --no-pager >&2 2>/dev/null || true
  return 1
}
wait_ready osr-prometheus.service http://127.0.0.1:9090/-/ready || die 'Prometheus failed to start'
wait_ready grafana-server.service http://127.0.0.1:3000/api/health || die 'Grafana failed to start'
note 'ready: Grafana answers on port 3000, Prometheus on loopback port 9090; dashboard Open Smart Router'
note 'if a browser cannot reach port 3000, allow it in the CT firewall (README, Local Grafana dashboard)'
show_login
