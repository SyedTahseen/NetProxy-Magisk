#!/system/bin/sh

set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly XRAY_BIN="$MODDIR/bin/xray"
readonly MODULE_CONF="$MODDIR/config/module.conf"
readonly XRAY_LOG_FILE="$MODDIR/logs/xray.log"
readonly CONFDIR="$MODDIR/config/xray/confdir"

readonly KILL_TIMEOUT=5

detect_busybox() {
  local path
  for path in "/data/adb/ksu/bin/busybox" "/data/adb/ap/bin/busybox" "/data/adb/magisk/busybox"; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  echo "busybox"
}

readonly BUSYBOX="$(detect_busybox)"

. "$MODDIR/scripts/utils/log.sh"

export PATH="$MODDIR/bin:$PATH"

get_pid() {
  pidof -s "$XRAY_BIN" 2> /dev/null || true
}

warn_domain_outbound() {
  local f="$1" host
  grep -q '"domainStrategy"' "$f" 2> /dev/null && return 0
  host=$(grep -o '"address": *"[^"]*"' "$f" 2> /dev/null | sed 's/.*: *"\(.*\)"/\1/' | grep '[A-Za-z]' | grep -v ':' | head -n 1)
  if [ -n "$host" ]; then
    log "WARN" "Outbound uses hostname '$host' without sockopt.domainStrategy; if it fails to connect, re-import the node (resolves to IP) or set domainStrategy to UseIP"
  fi
  return 0
}

RUN_CONFDIR=""
ROUTING_CONFIG=""
OUTBOUND_CONFIG=""

# Resolve config paths and validate them. Exits (die) on failure, so callers
# can run it BEFORE touching a running core.
prepare_core() {
  [ -f "$MODULE_CONF" ] || die "Module config file does not exist: $MODULE_CONF"
  . "$MODULE_CONF"

  OUTBOUND_CONFIG=$(printf '%s' "${CURRENT_CONFIG:-}" | tr -d '"')
  [ -n "$OUTBOUND_CONFIG" ] || die "Unable to resolve the outbound config path"

  local outbound_mode="${OUTBOUND_MODE:-rule}"
  log "INFO" "Current outbound mode: $outbound_mode"

  case "$outbound_mode" in
    global) ROUTING_CONFIG="$CONFDIR/routing/global.json" ;;
    direct) ROUTING_CONFIG="$CONFDIR/routing/direct.json" ;;
    *) ROUTING_CONFIG="$CONFDIR/routing/rule.json" ;;
  esac

  [ -d "$CONFDIR" ] || die "confdir directory does not exist: $CONFDIR"
  [ -f "$ROUTING_CONFIG" ] || die "Routing config file does not exist: $ROUTING_CONFIG"
  [ -f "$OUTBOUND_CONFIG" ] || die "Outbound config file does not exist: $OUTBOUND_CONFIG"

  log "INFO" "Config directory: $CONFDIR"
  log "INFO" "Routing config: $ROUTING_CONFIG"
  log "INFO" "Outbound config: $OUTBOUND_CONFIG"

  RUN_CONFDIR="$CONFDIR"
  local proxy_mode_used
  proxy_mode_used=$("$MODDIR/scripts/network/tproxy.sh" detect -d "$MODDIR/config/tproxy" 2> /dev/null | tail -n 1)
  if [ "$proxy_mode_used" = "redirect" ]; then
    log "WARN" "Kernel lacks TPROXY, using REDIRECT mode (TCP only)"
    RUN_CONFDIR="$MODDIR/config/xray/.runtime_confdir"
    rm -rf "$RUN_CONFDIR"
    mkdir -p "$RUN_CONFDIR"
    local f
    for f in "$CONFDIR"/*.json; do
      [ -f "$f" ] || continue
      sed 's/"tproxy"[[:space:]]*:[[:space:]]*"tproxy"/"tproxy": "redirect"/' "$f" > "$RUN_CONFDIR/$(basename "$f")"
    done
  fi

  if ! "$XRAY_BIN" run -test -confdir "$RUN_CONFDIR" -config "$ROUTING_CONFIG" -config "$OUTBOUND_CONFIG" > "$XRAY_LOG_FILE" 2>&1; then
    tail -n 8 "$XRAY_LOG_FILE" >> "$LOG_FILE" 2> /dev/null
    die "Xray config test failed (unknown geosite/geoip tag or bad JSON?), see $XRAY_LOG_FILE"
  fi

  warn_domain_outbound "$OUTBOUND_CONFIG"
}

launch_core() {
  nohup "$BUSYBOX" setuidgid root:net_admin "$XRAY_BIN" run \
    -confdir "$RUN_CONFDIR" \
    -config "$ROUTING_CONFIG" \
    -config "$OUTBOUND_CONFIG" \
    > "$XRAY_LOG_FILE" 2>&1 &

  local xray_pid=$!
  log "INFO" "Xray process started, PID: $xray_pid"

  sleep 1

  if ! kill -0 "$xray_pid" 2> /dev/null; then
    die "Xray process failed to start, please check the config"
  fi
}

do_start() {
  log "INFO" "========== Starting Xray Service =========="

  local running_pid
  running_pid=$(get_pid)
  if [ -n "$running_pid" ]; then
    log "WARN" "Xray is already running (PID: $running_pid)"
    return 0
  fi

  prepare_core
  launch_core

  if ! "$MODDIR/scripts/network/tproxy.sh" start -d "$MODDIR/config/tproxy" >> "$LOG_FILE" 2>&1; then
    log "WARN" "TProxy rule setup reported errors, traffic may not be proxied (see $LOG_FILE)"
  fi

  log "INFO" "========== Xray Service Started =========="
}

stop_core() {
  local pid
  pid=$(get_pid)

  if [ -z "$pid" ]; then
    log "INFO" "No running Xray process found"
    return 0
  fi

  log "INFO" "Terminating Xray process (PID: $pid)..."

  if kill "$pid" 2> /dev/null; then
    local count=0
    while kill -0 "$pid" 2> /dev/null && [ "$count" -lt "$KILL_TIMEOUT" ]; do
      sleep 1
      count=$((count + 1))
    done

    if kill -0 "$pid" 2> /dev/null; then
      log "WARN" "Process did not respond to SIGTERM, sending SIGKILL"
      kill -9 "$pid" 2> /dev/null || true
    fi
  fi

  log "INFO" "Xray process terminated"
}

do_stop() {
  log "INFO" "========== Stopping Xray Service =========="

  log "INFO" "Cleaning up TProxy rules..."
  "$MODDIR/scripts/network/tproxy.sh" stop -d "$MODDIR/config/tproxy" >> "$LOG_FILE" 2>&1 \
    || log "WARN" "TProxy rule cleanup reported errors"

  stop_core

  log "INFO" "========== Xray Service Stopped =========="
}

# Drop every connection held by the core (client side and outbound side) by
# restarting only the Xray process. TProxy rules stay in place, so traffic is
# blocked (not leaked) for the ~2s the core is down. The new config is
# validated first; if it is bad the old core keeps running.
do_flush() {
  if [ -z "$(get_pid)" ]; then
    log "INFO" "Xray is not running, nothing to flush"
    return 0
  fi

  log "INFO" "========== Flushing Connections (core restart) =========="
  prepare_core
  stop_core
  launch_core
  log "INFO" "========== Connections Flushed =========="
}

# Re-apply TProxy rules, then flush so old connections follow the new rules.
do_reload_rules() {
  if [ -z "$(get_pid)" ]; then
    log "INFO" "Xray is not running, rules apply on next start"
    return 0
  fi

  log "INFO" "Reloading TProxy rules..."
  "$MODDIR/scripts/network/tproxy.sh" restart -d "$MODDIR/config/tproxy" >> "$LOG_FILE" 2>&1 \
    || log "WARN" "TProxy rule reload reported errors"

  do_flush
}

do_restart() {
  log "INFO" "========== Restarting Xray Service =========="
  do_stop
  sleep 1
  do_start
}

do_status() {
  local pid
  pid=$(get_pid)

  if [ -n "$pid" ]; then
    echo "Xray is running (PID: $pid)"
    if [ -f "/proc/$pid/stat" ]; then
      local uptime_ticks start_time now_ticks
      start_time=$(awk '{print $22}' "/proc/$pid/stat" 2> /dev/null || echo 0)
      now_ticks=$(awk '{print int($1 * 100)}' /proc/uptime 2> /dev/null || echo 0)
      if [ "$start_time" -gt 0 ] && [ "$now_ticks" -gt 0 ]; then
        uptime_ticks=$((now_ticks - start_time))
        echo "Uptime: $((uptime_ticks / 100)) seconds"
      fi
    fi
    return 0
  else
    echo "Xray is not running"
    return 1
  fi
}

show_usage() {
  cat << EOF
Usage: $(basename "$0") {start|stop|restart|flush|reload-rules|status}

Commands:
  start     Start the Xray service
  stop      Stop the Xray service
  restart   Restart the Xray service
  flush     Restart only the Xray core to drop all existing connections
  reload-rules  Re-apply TProxy rules and flush old connections
  status    Show service status

Examples:
  $(basename "$0") start
  $(basename "$0") restart
EOF
}

main() {
  case "${1:-}" in
    start)
      do_start
      ;;
    stop)
      do_stop
      ;;
    restart)
      do_restart
      ;;
    flush)
      do_flush
      ;;
    reload-rules)
      do_reload_rules
      ;;
    status)
      do_status
      ;;
    -h | --help | help)
      show_usage
      ;;
    *)
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
