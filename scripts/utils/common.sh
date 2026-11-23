#!/system/bin/sh

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
