#!/system/bin/sh

set -e
set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly MODULE_CONF="$MODDIR/config/module.conf"
readonly XRAY_BIN="$MODDIR/bin/xray"

. "$MODDIR/scripts/utils/log.sh"
. "$MODDIR/scripts/utils/common.sh"

# Xray cannot drop live connections itself: after the outbound swap, apps that
# were already connected keep using the old server. Destroy the sockets that go
# to the old server so Xray closes the matching app connections and the apps
# reconnect through the new outbound.
kill_old_connections() {
  local old_cfg="$1" addr port out

  command -v ss > /dev/null 2>&1 || {
    log "WARN" "ss not found, open connections stay on the old node until they close"
    return 0
  }
  [ -n "$old_cfg" ] && [ -f "$old_cfg" ] || return 0

  addr=$(json_field "$old_cfg" "address")
  port=$(grep -o '"port": *[0-9]*' "$old_cfg" 2> /dev/null | head -n 1 | grep -o '[0-9]*$')

  if [ -z "$addr" ] || [ -z "$port" ]; then
    log "WARN" "Could not read old server address/port, open connections not closed"
    return 0
  fi

  # Only IPs work for the socket filter (re-import the node to store an IP)
  if ! printf '%s' "$addr" | grep -Eq '^[0-9]+(\.[0-9]+){3}$|:'; then
    log "WARN" "Old server '$addr' is a hostname, open connections not closed"
    return 0
  fi

  out=$(ss -K -t dst "$addr" dport = ":$port" 2>&1) || true
  log "INFO" "Closed $(printf '%s\n' "$out" | grep -c ESTAB) connection(s) to old server $addr:$port"
}

hot_switch() {
  local config_file="$1"

  [ -f "$config_file" ] || die "Config file does not exist: $config_file"

  log "INFO" "========== Starting Config Hot Switch =========="
  log "INFO" "New config: $config_file"

  local previous_config
  previous_config=$(conf_get "$MODULE_CONF" "CURRENT_CONFIG")

  log "INFO" "Removing proxy outbound..."
  "$XRAY_BIN" api rmo --server="$XRAY_API_SERVER" "proxy" 2> /dev/null || true

  log "INFO" "Adding new outbound..."
  if "$XRAY_BIN" api ado --server="$XRAY_API_SERVER" "$config_file"; then
    log "INFO" "New outbound added successfully"
  else
    if [ -n "$previous_config" ] && [ -f "$previous_config" ] \
      && "$XRAY_BIN" api ado --server="$XRAY_API_SERVER" "$previous_config" > /dev/null 2>&1; then
      log "WARN" "Previous outbound restored: $previous_config"
    else
      log "ERROR" "Could not restore the previous outbound, restart the service"
    fi
    die "Failed to add the new outbound"
  fi

  conf_set "$MODULE_CONF" "CURRENT_CONFIG" "\"$config_file\""

  kill_old_connections "$previous_config"

  log "INFO" "========== Hot Switch Complete =========="
}

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <config_file>"
  echo "  config_file - full path of the new config file"
  exit 1
fi

hot_switch "$1"
