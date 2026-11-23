#!/system/bin/sh
# Hot-switch the active node outbound through the Xray API
# Usage: switch-config.sh <config_file>

set -e
set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly MODULE_CONF="$MODDIR/config/module.conf"
readonly XRAY_BIN="$MODDIR/bin/xray"
readonly API_SERVER="127.0.0.1:8080"

. "$MODDIR/scripts/utils/log.sh"
. "$MODDIR/scripts/utils/common.sh"

#######################################
# Hot-switch config
# Arguments:
#   $1 - new config file path
#######################################
hot_switch() {
  local config_file="$1"

  [ -f "$config_file" ] || die "Config file does not exist: $config_file"

  log "INFO" "========== Starting Config Hot Switch =========="
  log "INFO" "New config: $config_file"

  # 1. Remove the existing proxy outbound
  log "INFO" "Removing proxy outbound..."
  "$XRAY_BIN" api rmo --server="$API_SERVER" "proxy" 2> /dev/null || true

  # 2. Add the new outbound
  log "INFO" "Adding new outbound..."
  if "$XRAY_BIN" api ado --server="$API_SERVER" "$config_file"; then
    log "INFO" "New outbound added successfully"
  else
    die "Failed to add the new outbound"
  fi

  # 3. Update CURRENT_CONFIG in module.conf
  conf_set "$MODULE_CONF" "CURRENT_CONFIG" "\"$config_file\""

  log "INFO" "========== Hot Switch Complete =========="
}

# Main flow
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <config_file>"
  echo "  config_file - full path of the new config file"
  exit 1
fi

hot_switch "$1"
