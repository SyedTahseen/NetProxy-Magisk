#!/system/bin/sh
set -e
set -u

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly LOG_FILE="$MODDIR/logs/service.log"

. "$MODDIR/scripts/utils/log.sh"

remove_block_rules_from_chain() {
  local cmd="$1"
  local chain="$2"
  local table="filter"

  local line_numbers
  line_numbers=$(
    $cmd -t "$table" -nvL "$chain" --line-numbers 2> /dev/null \
      | awk '/REJECT|DROP/ {print $1}' \
      | sort -rn
  )

  if [ -z "$line_numbers" ]; then
    log "INFO" "$cmd: no REJECT/DROP rules found in chain $chain"
    return 0
  fi

  local count=0
  local line_num

  for line_num in $line_numbers; do
    if $cmd -t "$table" -D "$chain" "$line_num" 2> /dev/null; then
      log "INFO" "Deleted REJECT/DROP rule ($cmd) $chain line $line_num"
      count=$((count + 1))
    else
      log "WARN" "Delete failed ($cmd) $chain line $line_num"
    fi
  done

  log "INFO" "$cmd: deleted $count REJECT/DROP rule(s) from chain $chain"
}

clean_chains() {
  local chain
  for chain in $1; do
    [ "$has_iptables" -eq 1 ] && remove_block_rules_from_chain "iptables" "$chain"
    [ "$has_ip6tables" -eq 1 ] && remove_block_rules_from_chain "ip6tables" "$chain"
  done
  return 0
}

fix_by_device() {
  has_iptables=0
  has_ip6tables=0

  command -v iptables > /dev/null 2>&1 && has_iptables=1
  command -v ip6tables > /dev/null 2>&1 && has_ip6tables=1

  if [ "$has_iptables" -eq 0 ] && [ "$has_ip6tables" -eq 0 ]; then
    log "ERROR" "Neither iptables nor ip6tables exists"
    return 1
  fi

  log "INFO" "Starting detection and repair..."

  if iptables -t filter -L zte_fw_gms > /dev/null 2>&1; then
    log "INFO" "REDMAGIC OS / ZTE detected, cleaning up zte_fw_gms"
    clean_chains "zte_fw_gms"
  elif iptables -t filter -L fw_INPUT > /dev/null 2>&1; then
    log "INFO" "OnePlus/ColorOS detected, cleaning up fw_INPUT/fw_OUTPUT"
    clean_chains "fw_INPUT fw_OUTPUT"
  else
    log "INFO" "No supported vendor firewall chain found, nothing to do"
  fi
}

log "INFO" "========== Multi-device compatibility fix: started (OnePlus + REDMAGIC) =========="

fix_by_device

log "INFO" "========== Multi-device compatibility fix: finished =========="
