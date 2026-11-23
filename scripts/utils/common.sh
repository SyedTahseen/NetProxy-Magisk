#!/system/bin/sh

#######################################
# Shared helpers (sourced by the other scripts)
#######################################

#######################################
# Read a string field from a flat JSON file (e.g. a subscription _meta.json)
# Usage: json_field <file> <key>
#######################################
json_field() {
  grep -o "\"$2\": *\"[^\"]*\"" "$1" 2> /dev/null \
    | head -n 1 \
    | sed "s/\"$2\": *\"\\([^\"]*\\)\"/\\1/"
}

#######################################
# Read KEY=value from a shell-style config file (surrounding quotes removed)
# Usage: conf_get <file> <KEY> [default]
#######################################
conf_get() {
  local value
  value=$(grep "^$2=" "$1" 2> /dev/null | head -n 1 | cut -d= -f2- | tr -d '"\r')
  echo "${value:-${3:-}}"
}

#######################################
# Set KEY=value in a shell-style config file (appended if missing).
# The value is written verbatim, so callers add quotes themselves if needed.
# Usage: conf_set <file> <KEY> <value>
#######################################
conf_set() {
  local file="$1" key="$2" value="$3" escaped
  if grep -q "^$key=" "$file" 2> /dev/null; then
    escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
    sed -i "s|^$key=.*|$key=$escaped|" "$file"
  else
    echo "$key=$value" >> "$file"
  fi
}
