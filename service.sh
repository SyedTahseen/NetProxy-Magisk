#!/system/bin/sh
set -e

readonly MODDIR="${0%/*}"
readonly MODULE_CONF="$MODDIR/config/module.conf"
readonly LOG_FILE="$MODDIR/logs/service.log"

. "$MODDIR/scripts/utils/log.sh"

#######################################
# Load module config
#######################################
load_module_config() {
  # Defaults
  AUTO_START=1
  ONEPLUS_A16_FIX=1

  if [ -f "$MODULE_CONF" ]; then
    . "$MODULE_CONF"
    log "INFO" "Module config loaded"
  else
    log "WARN" "Module config file not found, using defaults"
  fi
}

#######################################
# Wait for system boot to complete
#######################################
wait_for_boot() {
  log "INFO" "Waiting for system boot to complete..."

  # Wait for the system to finish booting
  while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
  done
  log "INFO" "System boot complete"

  # Wait for storage to be mounted
  while [ ! -d "/sdcard/Android" ]; do
    sleep 1
  done
  log "INFO" "Storage mounted"
}

#######################################
# Run the device-specific fix script
#######################################
check_device_specific() {
  if [ "$ONEPLUS_A16_FIX" = "1" ]; then
    log "INFO" "OnePlus A16 fix enabled, running fix script"
    sh "$MODDIR/scripts/utils/oneplus_a16_fix.sh" || log "WARN" "OnePlus A16 fix script failed"
  fi
}

#######################################
# Record environment info
#######################################
log_env_info() {
  log "INFO" "========== Environment Detection =========="

  # KernelSU
  if [ "$KSU" = "true" ]; then
    log "INFO" "Environment: KernelSU"
    log "INFO" "KSU_VER: ${KSU_VER:-unknown}"
    log "INFO" "KSU_VER_CODE: ${KSU_VER_CODE:-unknown}"
    log "INFO" "KSU_KERNEL_VER_CODE: ${KSU_KERNEL_VER_CODE:-unknown}"
  fi

  # APatch
  if [ "$APATCH" = "true" ] || [ "$KERNELPATCH" = "true" ]; then
    log "INFO" "Environment: APatch / KernelPatch"
    log "INFO" "APATCH_VER: ${APATCH_VER:-unknown}"
    log "INFO" "APATCH_VER_CODE: ${APATCH_VER_CODE:-unknown}"
    log "INFO" "KERNEL_VERSION: ${KERNEL_VERSION:-unknown}"
    log "INFO" "KERNELPATCH_VERSION: ${KERNELPATCH_VERSION:-unknown}"
  fi

  # Magisk
  if [ -n "$MAGISK_VER" ]; then
    log "INFO" "Environment: Magisk"
    log "INFO" "MAGISK_VER: $MAGISK_VER"
    log "INFO" "MAGISK_VER_CODE: $MAGISK_VER_CODE"
  fi

  # Module Info
  if [ -f "$MODDIR/module.prop" ]; then
    local version version_code
    version=$(grep "^version=" "$MODDIR/module.prop" | cut -d= -f2)
    version_code=$(grep "^versionCode=" "$MODDIR/module.prop" | cut -d= -f2)
    log "INFO" "VERSION: ${version:-unknown}"
    log "INFO" "VERSION_CODE: ${version_code:-unknown}"
  fi

  log "INFO" "=================================="
}

# Main flow
log "INFO" "========== NetProxy Service Starting =========="
log_env_info
load_module_config

wait_for_boot

# Check whether autostart on boot is enabled
if [ "$AUTO_START" = "1" ]; then
  log "INFO" "Starting service..."
  # A failed start must not skip the device fix below (this script runs with set -e)
  if sh "$MODDIR/scripts/core/service.sh" start; then
    log "INFO" "Service startup complete"
  else
    log "ERROR" "Service failed to start, see service.log"
  fi
else
  log "INFO" "Autostart on boot is disabled, skipping startup"
fi

# Run the OnePlus A16 fix
check_device_specific

log "INFO" "========== Service Startup Sequence Finished =========="
