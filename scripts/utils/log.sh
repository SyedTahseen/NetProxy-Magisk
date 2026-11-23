#!/system/bin/sh

log() {
  local level="INFO"
  local message="$1"

  if [ $# -ge 2 ]; then
    level="$1"
    message="$2"
  fi

  local log_content
  log_content="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"

  if [ -n "${LOG_FILE:-}" ]; then
    echo "$log_content" >> "$LOG_FILE" 2> /dev/null || true
  fi

  echo "$log_content" >&2
}

die() {
  log "ERROR" "$1"
  exit "${2:-1}"
}

init_log() {
  [ -n "${LOG_FILE:-}" ] || return 0
  mkdir -p "${LOG_FILE%/*}" 2> /dev/null || true
  [ -f "$LOG_FILE" ] || return 0

  local size
  size=$(wc -c < "$LOG_FILE" 2> /dev/null | tr -d ' ')
  if [ "${size:-0}" -gt 524288 ] 2> /dev/null; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2> /dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
  return 0
}
init_log
