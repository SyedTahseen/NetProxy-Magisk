#!/system/bin/sh

set -e
set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly MODULE_CONF="$MODDIR/config/module.conf"
readonly XRAY_BIN="$MODDIR/bin/xray"

. "$MODDIR/scripts/utils/log.sh"
. "$MODDIR/scripts/utils/common.sh"

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

  # Hot-swapping only affects new connections; long-lived ones (browser keep-alive, HTTP/2)
  # stay on the old outbound. Restarting Xray drops them so the new node takes effect at once.
  if [ "$(conf_get "$MODULE_CONF" "SWITCH_RESTART" "1")" = "1" ]; then
    log "INFO" "Restarting Xray to drop connections still using the old outbound"
    sh "$MODDIR/scripts/core/service.sh" restart || log "WARN" "Restart after switch failed"
  fi

  log "INFO" "========== Hot Switch Complete =========="
}

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <config_file>"
  echo "  config_file - full path of the new config file"
  exit 1
fi

hot_switch "$1"
