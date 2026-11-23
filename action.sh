#!/system/bin/sh

readonly MODDIR="${0%/*}"
readonly SERVICE_SCRIPT="$MODDIR/scripts/core/service.sh"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly XRAY_BIN="$MODDIR/bin/xray"

. "$MODDIR/scripts/utils/log.sh"

is_xray_running() {
  pidof -s "$XRAY_BIN" > /dev/null 2>&1
}

exec 2>&1

echo "==================================="
echo "       NetProxy Action Script      "
echo "==================================="

if is_xray_running; then
  log "INFO" "Xray is running, preparing to stop it..."
  sh "$SERVICE_SCRIPT" stop
  if is_xray_running; then
    result="Failed to stop the NetProxy service"
  else
    result="NetProxy service stopped"
  fi
else
  log "INFO" "Xray is not running, preparing to start it..."
  sh "$SERVICE_SCRIPT" start
  if is_xray_running; then
    result="NetProxy service started"
  else
    result="Failed to start the NetProxy service, check logs/service.log"
  fi
fi

echo "==================================="
echo " Result: $result"
echo "==================================="

sleep 1
