#!/system/bin/sh

SKIPUNZIP=1

readonly MODULE_ID="netproxy"
readonly LIVE_DIR="/data/adb/modules/$MODULE_ID"
readonly CONFIG_DIR="$LIVE_DIR/config"
readonly BACKUP_DIR="$TMPDIR/netproxy_backup"

XRAY_WAS_RUNNING=false

readonly PRESERVE_CONFIGS="
    module.conf
    tproxy/
    xray/outbounds
    xray/confdir/02_dns.json
    xray/confdir/routing
"

readonly EXECUTABLE_FILES="
    bin/xray
    bin/proxylink
    bin/ipset
    action.sh
    scripts/cli
    scripts/core/service.sh
    scripts/core/switch-config.sh
    scripts/core/switch-mode.sh
    scripts/network/tproxy.sh
    scripts/config/subscription.sh
    scripts/utils/update-xray.sh
    scripts/utils/socks-fix.sh
    scripts/utils/import-link.sh
    scripts/utils/import-wireguard.sh
    scripts/utils/oneplus_a16_fix.sh
"

print_title() {
  ui_print ""
  ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ui_print "  $1"
  ui_print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

print_step() {
  ui_print "▶ $1"
}

print_ok() {
  ui_print "  ✓ $1"
}

print_warn() {
  ui_print "  ⚠ $1"
}

print_error() {
  ui_print "  ✗ $1"
}

dir_not_empty() {
  [ -d "$1" ] && [ "$(ls -A "$1" 2> /dev/null)" ]
}

backup_config() {
  print_step "Checking existing config..."

  if ! dir_not_empty "$CONFIG_DIR"; then
    print_ok "Fresh install, no backup needed"
    return 0
  fi

  print_step "Backing up existing config..."
  mkdir -p "$BACKUP_DIR"

  local config_item
  for config_item in $PRESERVE_CONFIGS; do
    local src="$CONFIG_DIR/$config_item"
    local dst="$BACKUP_DIR/$config_item"

    if [ -e "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      if cp -r "$src" "$dst" 2> /dev/null; then
        print_ok "Backed up: $config_item"
      else
        print_warn "Backup failed: $config_item"
      fi
    fi
  done

  return 0
}

extract_module() {
  print_step "Extracting module files..."

  if ! unzip -o "$ZIPFILE" -x "META-INF/*" -d "$MODPATH" > /dev/null 2>&1; then
    print_error "Extraction failed"
    return 1
  fi

  mkdir -p "$MODPATH/logs"

  print_ok "Module files extracted"
  return 0
}

restore_config() {
  if ! dir_not_empty "$BACKUP_DIR"; then
    return 0
  fi

  print_step "Restoring config files..."

  local config_item
  for config_item in $PRESERVE_CONFIGS; do
    local src="$BACKUP_DIR/$config_item"
    local dst="$MODPATH/config/$config_item"

    if [ -e "$src" ]; then
      mkdir -p "$(dirname "$dst")"
      rm -rf "$dst" 2> /dev/null
      if cp -r "$src" "$dst" 2> /dev/null; then
        print_ok "Restored: $config_item"
      else
        print_warn "Restore failed: $config_item"
      fi
    fi
  done

  return 0
}

stop_xray_if_running() {
  if [ ! -d "$LIVE_DIR" ]; then
    return 0
  fi

  if pidof -s "$LIVE_DIR/bin/xray" > /dev/null 2>&1; then
    XRAY_WAS_RUNNING=true
    print_step "Xray is running, stopping service..."
    sh "$LIVE_DIR/scripts/core/service.sh" stop > /dev/null 2>&1
    print_ok "Service stopped"
  fi

  return 0
}

sync_to_live() {
  print_step "Syncing to the runtime directory..."

  if [ ! -d "$LIVE_DIR" ]; then
    print_ok "First install, skipping sync"
    return 0
  fi

  local sync_dirs="bin scripts webroot action.sh service.sh module.prop"
  local item

  for item in $sync_dirs; do
    local src="$MODPATH/$item"
    local dst="$LIVE_DIR/$item"

    if [ -e "$src" ]; then
      rm -rf "$dst" 2> /dev/null
      if cp -r "$src" "$dst" 2> /dev/null; then
        print_ok "Synced: $item"
      else
        print_warn "Sync failed: $item"
      fi
    fi
  done

  mkdir -p "$LIVE_DIR/logs"

  if [ -d "$MODPATH/config" ]; then
    print_step "Applying incremental config update..."

    cp -rn "$MODPATH/config/"* "$LIVE_DIR/config/" 2> /dev/null
    print_ok "Config directory updated incrementally"
  fi

  return 0
}

restart_xray_if_needed() {
  if [ "$XRAY_WAS_RUNNING" = true ]; then
    print_step "Restarting Xray service..."
    sh "$LIVE_DIR/scripts/core/service.sh" start > /dev/null 2>&1
    print_ok "Service started"
  fi

  return 0
}

set_permissions() {
  print_step "Setting file permissions..."

  local file
  for file in $EXECUTABLE_FILES; do
    local path="$MODPATH/$file"
    if [ -e "$path" ]; then
      chmod 0755 "$path" 2> /dev/null
      [ -e "$LIVE_DIR/$file" ] && chmod 0755 "$LIVE_DIR/$file" 2> /dev/null
    fi
  done

  set_perm_recursive "$MODPATH" 0 0 0755 0755

  print_ok "Permissions set"
  return 0
}

cleanup() {
  rm -rf "$BACKUP_DIR" 2> /dev/null
}

unzip -o "$ZIPFILE" "module.prop" -d "$TMPDIR" > /dev/null 2>&1

print_title "NetProxy - Xray Transparent Proxy"
ui_print "  Version: $(grep_prop version "$TMPDIR/module.prop" 2> /dev/null || echo "unknown")"

if backup_config \
  && extract_module \
  && restore_config \
  && stop_xray_if_running \
  && sync_to_live \
  && set_permissions \
  && restart_xray_if_needed; then

  cleanup

  print_title "Installation complete, please reboot your device"
else
  cleanup
  print_title "Installation failed"
  ui_print ""
  ui_print "  Please check the error messages above"
  ui_print "  and report it on GitHub Issues"
  ui_print ""
  exit 1
fi
