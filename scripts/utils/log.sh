#!/system/bin/sh

#######################################
# Standard logging library
# Usage:
#   log <message>          -> defaults to INFO level
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

  local log_content
  log_content="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"

  # Never let a logging failure (e.g. unwritable log file) abort the caller
  if [ -n "${LOG_FILE:-}" ]; then
    echo "$log_content" >> "$LOG_FILE" 2> /dev/null || true
  fi

  # stderr lets the console or a parent process capture the log output
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
# Prepare the log file: make sure its directory exists, and keep it small
# (when LOG_FILE exceeds 512 KB only the last 1000 lines are kept).
# Runs once whenever this file is sourced (i.e. at the start of each script run).
#######################################
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
