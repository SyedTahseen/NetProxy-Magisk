#!/system/bin/sh
set -e
set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly STATUS_FILE="$MODDIR/config/status.conf"
readonly XRAY_BIN="$MODDIR/bin/xray"
readonly API_SERVER="127.0.0.1:8080"

# Import the utility library
. "$MODDIR/scripts/utils/log.sh"

#######################################
# Hot-switch config
# Arguments:
#   $1 - new config file path
#######################################
hot_switch() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    log "ERROR" "Config file does not exist: $config_file"
    exit 1
  fi

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
    log "ERROR" "Failed to add the new outbound"
    exit 1
  fi

  # 3. Update CURRENT_CONFIG in module.conf
  sed -i "s|^CURRENT_CONFIG=.*|CURRENT_CONFIG=\"$config_file\"|" "$MODDIR/config/module.conf"

  log "INFO" "Config file updated"
  log "INFO" "========== Hot Switch Complete =========="
}

# Main flow
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <config_file>"
  echo "  config_file - full path of the new config file"
  exit 1
fi

hot_switch "$1"
