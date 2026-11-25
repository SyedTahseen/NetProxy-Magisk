#!/system/bin/sh

XRAY_API_SERVER="127.0.0.1:8080"

json_field() {
  grep -o "\"$2\": *\"[^\"]*\"" "$1" 2> /dev/null \
    | head -n 1 \
    | sed "s/\"$2\": *\"\\([^\"]*\\)\"/\\1/"
}

conf_get() {
  local value
  value=$(grep "^$2=" "$1" 2> /dev/null | head -n 1 | cut -d= -f2- | tr -d '"\r')
  echo "${value:-${3:-}}"
}

conf_set() {
  local file="$1" key="$2" value="$3" escaped
  if grep -q "^$key=" "$file" 2> /dev/null; then
    escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
    sed -i "s|^$key=.*|$key=$escaped|" "$file"
  else
    echo "$key=$value" >> "$file"
  fi
}

unique_json_path() {
  local target="$1/$2.json" n=2
  while [ -e "$target" ]; do
    target="$1/$2 $n.json"
    n=$((n + 1))
  done
  echo "$target"
}

net_bypass_exec() {
  local bb="" p
  for p in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    if [ -x "$p" ]; then
      bb="$p"
      break
    fi
  done
  [ -n "$bb" ] || bb=$(command -v busybox 2> /dev/null || true)
  if [ -n "$bb" ]; then
    "$bb" setuidgid root:net_admin "$@"
  else
    "$@"
  fi
}
