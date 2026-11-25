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
export XRAY_LOCATION_ASSET="$MODDIR/bin"

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

# Resolve configs and launch Xray. Does NOT touch firewall rules.
# $1 = 1 to run "xray -test" first (slow: loads geo files), 0 to skip it.
# Returns non-zero (without exiting) on failure so callers can fall back.
launch_xray() {
  local do_test="${1:-1}"

  [ -f "$MODULE_CONF" ] || { log "ERROR" "Module config file does not exist: $MODULE_CONF"; return 1; }
  . "$MODULE_CONF"

  local outbound_config
  outbound_config=$(printf '%s' "${CURRENT_CONFIG:-}" | tr -d '"')
  [ -n "$outbound_config" ] || { log "ERROR" "Unable to resolve the outbound config path"; return 1; }

  local outbound_mode="${OUTBOUND_MODE:-rule}"
  log "INFO" "Current outbound mode: $outbound_mode"

  local routing_config
  case "$outbound_mode" in
    global) routing_config="$CONFDIR/routing/global.json" ;;
    direct) routing_config="$CONFDIR/routing/direct.json" ;;
    *) routing_config="$CONFDIR/routing/rule.json" ;;
  esac

  [ -d "$CONFDIR" ] || { log "ERROR" "confdir directory does not exist: $CONFDIR"; return 1; }
  [ -f "$routing_config" ] || { log "ERROR" "Routing config file does not exist: $routing_config"; return 1; }
  [ -f "$outbound_config" ] || { log "ERROR" "Outbound config file does not exist: $outbound_config"; return 1; }

  log "INFO" "Config directory: $CONFDIR"
  log "INFO" "Routing config: $routing_config"
  log "INFO" "Outbound config: $outbound_config"

  local run_confdir="$CONFDIR"
  local proxy_mode_used
  proxy_mode_used=$("$MODDIR/scripts/network/tproxy.sh" detect -d "$MODDIR/config/tproxy" 2> /dev/null | tail -n 1)
  if [ "$proxy_mode_used" = "redirect" ]; then
    log "WARN" "Kernel lacks TPROXY, using REDIRECT mode (TCP only)"
    run_confdir="$MODDIR/config/xray/.runtime_confdir"
    rm -rf "$run_confdir"
    mkdir -p "$run_confdir"
    local f
    for f in "$CONFDIR"/*.json; do
      [ -f "$f" ] || continue
      sed 's/"tproxy"[[:space:]]*:[[:space:]]*"tproxy"/"tproxy": "redirect"/' "$f" > "$run_confdir/$(basename "$f")"
    done
  fi

  if [ "$do_test" = "1" ]; then
    if ! "$XRAY_BIN" run -test -confdir "$run_confdir" -config "$routing_config" -config "$outbound_config" > "$XRAY_LOG_FILE" 2>&1; then
      tail -n 8 "$XRAY_LOG_FILE" >> "$LOG_FILE" 2> /dev/null
      log "ERROR" "Xray config test failed (unknown geosite/geoip tag or bad JSON?), see $XRAY_LOG_FILE"
      return 1
    fi
  fi

  warn_domain_outbound "$outbound_config"

  nohup "$BUSYBOX" setuidgid root:net_admin "$XRAY_BIN" run \
    -confdir "$run_confdir" \
    -config "$routing_config" \
    -config "$outbound_config" \
    > "$XRAY_LOG_FILE" 2>&1 &

  local xray_pid=$!
  log "INFO" "Xray process started, PID: $xray_pid"

  # Wait until Xray reports "started" (or dies), instead of a fixed sleep.
  local i=0
  while [ "$i" -lt 40 ]; do
    if ! kill -0 "$xray_pid" 2> /dev/null; then
      tail -n 8 "$XRAY_LOG_FILE" >> "$LOG_FILE" 2> /dev/null
      log "ERROR" "Xray process exited during startup, please check the config"
      return 1
    fi
    grep -q "started" "$XRAY_LOG_FILE" 2> /dev/null && return 0
    sleep 0.25
    i=$((i + 1))
  done

  # No "started" line after 10s but still alive: accept it.
  kill -0 "$xray_pid" 2> /dev/null
}

do_start() {
  log "INFO" "========== Starting Xray Service =========="

  local running_pid
  running_pid=$(get_pid)
  if [ -n "$running_pid" ]; then
    log "WARN" "Xray is already running (PID: $running_pid)"
    return 0
  fi

  launch_xray 1 || exit 1

  if ! "$MODDIR/scripts/network/tproxy.sh" start -d "$MODDIR/config/tproxy" >> "$LOG_FILE" 2>&1; then
    log "WARN" "TProxy rule setup reported errors, traffic may not be proxied (see $LOG_FILE)"
  fi

  log "INFO" "========== Xray Service Started =========="
}

# Fast restart used when switching proxies: kill Xray and relaunch it with the
# firewall rules left in place. Existing connections die with the old process,
# and while Xray is down new connections fail (nothing listens on the TPROXY
# port) instead of leaking out directly.
do_fast_restart() {
  log "INFO" "========== Fast Restart (firewall rules kept) =========="

  local pid
  pid=$(get_pid)
  if [ -n "$pid" ]; then
    kill -9 "$pid" 2> /dev/null || true
    local n=0
    while kill -0 "$pid" 2> /dev/null && [ "$n" -lt 20 ]; do
      sleep 0.1
      n=$((n + 1))
    done
  fi

  # Skip "-test": a bad config shows up as a startup failure below, and the
  # caller then falls back to the previous config.
  if launch_xray 0; then
    log "INFO" "========== Fast Restart Complete =========="
    return 0
  fi

  log "ERROR" "Fast restart failed"
  return 1
}

do_stop() {
  log "INFO" "========== Stopping Xray Service =========="

  log "INFO" "Cleaning up TProxy rules..."
  "$MODDIR/scripts/network/tproxy.sh" stop -d "$MODDIR/config/tproxy" >> "$LOG_FILE" 2>&1 \
    || log "WARN" "TProxy rule cleanup reported errors"

  local pid
  pid=$(get_pid)

  if [ -z "$pid" ]; then
    log "INFO" "No running Xray process found"
  else
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
  fi

  log "INFO" "========== Xray Service Stopped =========="
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
Usage: $(basename "$0") {start|stop|restart|fast-restart|status}

Commands:
  start     Start the Xray service
  stop      Stop the Xray service
  restart   Restart the Xray service
  fast-restart  Restart Xray only, keep firewall rules
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
    fast-restart)
      do_fast_restart
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
