#!/system/bin/sh

#######################################
# Standard logging function
# Usage:
#   log <message>         -> defaults to INFO level
#   log <level> <message>  -> specify the level (INFO, WARN, ERROR, DEBUG)
# Global variables:
#   LOG_FILE - log file path (optional)
# Output:
#   If LOG_FILE is defined, append the formatted log to that file
#   Also write the formatted log to standard error (stderr)
#######################################
log() {
  local level="INFO"
  local message="$1"

  # If two or more arguments are given, the first is the level and the second is the message
  if [ $# -ge 2 ]; then
    level="$1"
    message="$2"
  fi

  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local log_content="[$timestamp] [$level] $message"

  # If the LOG_FILE variable is non-empty, append to the log file
  [ -n "${LOG_FILE:-}" ] && echo "$log_content" >> "$LOG_FILE"

  # Write the log content to standard error (stderr); this lets the console or a parent process capture the log output
  echo "$log_content" >&2
}

#######################################
# Exit with an error
# Usage: die <message> [exit code]
#######################################
die() {
  log "ERROR" "$1"
  exit "${2:-1}"
}

#######################################
# Keep log files small: when LOG_FILE exceeds 512 KB, keep only the last 1000 lines.
# Runs once whenever this file is sourced (i.e. at the start of each script run).
#######################################
rotate_log() {
  [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ] || return 0
  local size
  size=$(wc -c < "$LOG_FILE" 2> /dev/null | tr -d ' ')
  if [ "${size:-0}" -gt 524288 ] 2> /dev/null; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" 2> /dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
  return 0
}
rotate_log
