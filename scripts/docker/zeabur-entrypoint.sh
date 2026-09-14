#!/bin/sh

# Zeabur keeps /data on a persistent volume. The first boot creates a minimal
# config; later boots preserve all changes made through the management panel.
DATA_DIR="${CPA_DATA_DIR:-/data}"
CONFIG_FILE="${CPA_CONFIG_FILE:-${DATA_DIR}/config.yaml}"
AUTH_DIR="${DATA_DIR}/auths"
PLUGINS_DIR="${DATA_DIR}/plugins"
PORT_VALUE="${PORT:-8080}"

fail() {
  echo "CLIProxyAPI Zeabur setup error: $*" >&2
  exit 1
}

validate_secret() {
  name="$1"
  value="$2"
  [ -n "$value" ] || fail "$name is required"
  case "$value" in
    *[!A-Za-z0-9._~-]*)
      fail "$name may only contain letters, numbers, dot, underscore, tilde, and hyphen"
      ;;
  esac
}

case "$PORT_VALUE" in
  ''|*[!0-9]*) fail "PORT must be a number" ;;
esac

mkdir -p "$DATA_DIR" "$AUTH_DIR" "$PLUGINS_DIR"

if [ ! -s "$CONFIG_FILE" ]; then
  validate_secret "CPA_API_KEY" "${CPA_API_KEY:-}"
  validate_secret "CPA_MANAGEMENT_KEY" "${CPA_MANAGEMENT_KEY:-}"

  umask 077
  cat > "$CONFIG_FILE" <<EOF
host: ""
port: ${PORT_VALUE}

tls:
  enable: false
  cert: ""
  key: ""

remote-management:
  allow-remote: true
  secret-key: "${CPA_MANAGEMENT_KEY}"
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"

auth-dir: "${AUTH_DIR}"

plugins:
  enabled: true
  dir: "${PLUGINS_DIR}"

api-keys:
  - "${CPA_API_KEY}"

debug: false
commercial-mode: false
logging-to-file: false
usage-statistics-enabled: false
request-retry: 3
max-retry-credentials: 0
max-retry-interval: 30
disable-cooling: false
save-cooldown-status: true
EOF
  echo "Created initial CLIProxyAPI configuration at $CONFIG_FILE"
else
  echo "Using persisted CLIProxyAPI configuration at $CONFIG_FILE"
fi

exec /CLIProxyAPI/CLIProxyAPI -config "$CONFIG_FILE"
