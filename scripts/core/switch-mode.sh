#!/system/bin/sh

set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly XRAY_BIN="$MODDIR/bin/xray"
readonly MODULE_CONF="$MODDIR/config/module.conf"
readonly FREEDOM_OUTBOUND="$MODDIR/config/xray/confdir/routing/internal/proxy_freedom.json"
readonly ROUTING_DIR="$MODDIR/config/xray/confdir/routing"
readonly ROUTING_JSON="$ROUTING_DIR/rule.json"
readonly GLOBAL_ROUTING="$ROUTING_DIR/global.json"
readonly DIRECT_ROUTING="$ROUTING_DIR/direct.json"
readonly LOG_FILE="$MODDIR/logs/service.log"

. "$MODDIR/scripts/utils/log.sh"
. "$MODDIR/scripts/utils/common.sh"

fail() {
  log "ERROR" "Mode switch aborted: $1"
  echo "error: $1"
  exit 1
}

replace_routing_rules() {
  local rules_file="$1"
  if [ -f "$rules_file" ]; then
    log "INFO" "Replacing routing rules: $rules_file"
    if "$XRAY_BIN" api adrules --server="$XRAY_API_SERVER" "$rules_file" 2> /dev/null; then
      log "INFO" "Routing rules replaced successfully"
      return 0
    else
      log "ERROR" "Failed to replace routing rules"
      return 1
    fi
  else
    log "ERROR" "Rules file does not exist: $rules_file"
    return 1
  fi
}

replace_proxy_outbound() {
  local outbound_file="$1"
  "$XRAY_BIN" api rmo --server="$XRAY_API_SERVER" "proxy" 2> /dev/null || true
  "$XRAY_BIN" api ado --server="$XRAY_API_SERVER" "$outbound_file" 2> /dev/null
}

switch_to_freedom() {
  log "INFO" "Switching outbound to freedom..."
  if replace_proxy_outbound "$FREEDOM_OUTBOUND"; then
    log "INFO" "Switched to freedom outbound"
    return 0
  else
    log "ERROR" "Failed to switch to freedom outbound"
    return 1
  fi
}

restore_proxy_outbound() {
  local current_config
  current_config=$(conf_get "$MODULE_CONF" "CURRENT_CONFIG")

  if [ -z "$current_config" ] || [ ! -f "$current_config" ]; then
    log "WARN" "Unable to get the current node config, using the freedom outbound"
    current_config="$FREEDOM_OUTBOUND"
  fi

  log "INFO" "Restoring node config: $current_config"
  if replace_proxy_outbound "$current_config"; then
    log "INFO" "Node outbound restored"
    return 0
  else
    log "ERROR" "Failed to restore node outbound"
    return 1
  fi
}

update_mode_config() {
  local mode="$1"
  conf_set "$MODULE_CONF" "OUTBOUND_MODE" "$mode"
  log "INFO" "Updated module.conf: OUTBOUND_MODE=$mode"
}

main() {
  local target_mode="${1:-}"
  local routing_file

  if [ -z "$target_mode" ]; then
    echo "Usage: $0 <mode>"
    echo "  mode: rule | global | direct"
    exit 1
  fi

  case "$target_mode" in
    rule) routing_file="$ROUTING_JSON" ;;
    global) routing_file="$GLOBAL_ROUTING" ;;
    direct) routing_file="$DIRECT_ROUTING" ;;
    *)
      log "ERROR" "Unknown mode: $target_mode"
      echo "error: unknown mode"
      exit 1
      ;;
  esac

  local current_mode
  current_mode=$(conf_get "$MODULE_CONF" "OUTBOUND_MODE" "rule")

  log "INFO" "========== Switching Outbound Mode =========="
  log "INFO" "Current mode: $current_mode -> target mode: $target_mode"

  if [ "$current_mode" = "direct" ] && [ "$target_mode" != "direct" ]; then
    log "INFO" "Switching from direct mode, restoring node outbound..."
    restore_proxy_outbound || fail "failed to restore node outbound"
  fi

  if [ "$target_mode" = "direct" ] && [ "$current_mode" != "direct" ]; then
    log "INFO" "Switching to direct mode, replacing with freedom outbound..."
    switch_to_freedom || fail "failed to switch to freedom outbound"
  fi

  log "INFO" "Applying routing rules for $target_mode mode: $(basename "$routing_file")"
  replace_routing_rules "$routing_file" || fail "failed to apply routing rules"

  update_mode_config "$target_mode"

  flush_connections

  log "INFO" "========== Mode Switch Complete =========="
  echo "success"
}

main "$@"
