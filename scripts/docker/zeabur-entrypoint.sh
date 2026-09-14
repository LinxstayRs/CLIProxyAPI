#!/bin/sh

# Zeabur keeps /data on a persistent volume. The first boot creates a minimal
# config; later boots preserve all changes made through the management panel.
DATA_DIR="${CPA_DATA_DIR:-/data}"
CONFIG_FILE="${CPA_CONFIG_FILE:-${DATA_DIR}/config.yaml}"
AUTH_DIR="${DATA_DIR}/auths"
PLUGINS_DIR="${DATA_DIR}/plugins"
PERSISTENT_APP_DATA_DIR="${DATA_DIR}/data"
APP_DATA_LINK="${CPA_APP_DATA_LINK:-/CLIProxyAPI/data}"
PORT_VALUE="${PORT:-8080}"
INTERNAL_PORT_VALUE="${CPA_INTERNAL_PORT:-8317}"
BLOCKED_DOMAINS="${CPA_BLOCKED_DOMAINS:-skynexyl.com}"
BLOCKED_REQUESTED_WITH="${CPA_BLOCKED_REQUESTED_WITH:-com.skynex.app}"

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
case "$INTERNAL_PORT_VALUE" in
  ''|*[!0-9]*) fail "CPA_INTERNAL_PORT must be a number" ;;
esac
[ "$PORT_VALUE" != "$INTERNAL_PORT_VALUE" ] || fail "PORT and CPA_INTERNAL_PORT must be different"

mkdir -p "$DATA_DIR" "$AUTH_DIR" "$PLUGINS_DIR" "$PERSISTENT_APP_DATA_DIR"

# Keep relative plugin data paths persistent. CPA v8.0.28+ loads dynamic
# libraries from shadow copies under /tmp, so plugins may no longer be able to
# derive the original /data/plugins root and can fall back to the CPA working
# directory. Point /CLIProxyAPI/data back at the existing persistent data tree.
if [ -L "$APP_DATA_LINK" ]; then
  current_target="$(readlink "$APP_DATA_LINK")" || fail "failed to inspect application data symlink"
  [ "$current_target" = "$PERSISTENT_APP_DATA_DIR" ] || fail "$APP_DATA_LINK points to unexpected target $current_target"
elif [ -e "$APP_DATA_LINK" ]; then
  [ -d "$APP_DATA_LINK" ] || fail "$APP_DATA_LINK exists and is not a directory"
  if [ -n "$(find "$APP_DATA_LINK" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    RECOVERY_DIR="${DATA_DIR}/recovery"
    recovery_stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf unknown-time)"
    recovery_path="${RECOVERY_DIR}/app-data-${recovery_stamp}-$$"
    mkdir -p "$RECOVERY_DIR" || fail "failed to create recovery directory"
    mv "$APP_DATA_LINK" "$recovery_path" || fail "failed to preserve transient application data"
    echo "Preserved transient application data at $recovery_path"
  else
    rmdir "$APP_DATA_LINK" || fail "failed to remove empty application data directory"
  fi
  ln -s "$PERSISTENT_APP_DATA_DIR" "$APP_DATA_LINK" || fail "failed to link application data directory"
else
  ln -s "$PERSISTENT_APP_DATA_DIR" "$APP_DATA_LINK" || fail "failed to link application data directory"
fi

if [ ! -s "$CONFIG_FILE" ]; then
  validate_secret "CPA_API_KEY" "${CPA_API_KEY:-}"
  validate_secret "CPA_MANAGEMENT_KEY" "${CPA_MANAGEMENT_KEY:-}"

  umask 077
  cat > "$CONFIG_FILE" <<EOF
host: "127.0.0.1"
port: ${INTERNAL_PORT_VALUE}

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

# CPA listens only on loopback. The public port belongs to the request filter.
# Rewrite only top-level host/port keys so settings managed through the control
# panel remain untouched. Add either key if an older config does not contain it.
/usr/local/bin/zeabur-request-filter \
  -prepare-config "$CONFIG_FILE" \
  -internal-port "$INTERNAL_PORT_VALUE" || fail "failed to update internal listener config"

shutdown() {
  trap - TERM INT EXIT
  [ -z "${FILTER_PID:-}" ] || kill "$FILTER_PID" 2>/dev/null || true
  [ -z "${CPA_PID:-}" ] || kill "$CPA_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap shutdown TERM INT EXIT

/CLIProxyAPI/CLIProxyAPI -config "$CONFIG_FILE" &
CPA_PID=$!

/usr/local/bin/zeabur-request-filter \
  -listen ":${PORT_VALUE}" \
  -upstream "http://127.0.0.1:${INTERNAL_PORT_VALUE}" \
  -blocked-domains "$BLOCKED_DOMAINS" \
  -blocked-requested-with "$BLOCKED_REQUESTED_WITH" &
FILTER_PID=$!

# POSIX sh has no portable wait -n. Monitor both children and terminate the
# container if either CPA or the public filter exits.
while kill -0 "$CPA_PID" 2>/dev/null && kill -0 "$FILTER_PID" 2>/dev/null; do
  sleep 2
done

exit 1
