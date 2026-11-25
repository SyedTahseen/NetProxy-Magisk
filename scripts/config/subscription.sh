#!/system/bin/sh

set -e

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly OUTBOUNDS_DIR="$MODDIR/config/xray/outbounds"
readonly LOG_FILE="$MODDIR/logs/subscription.log"

. "$MODDIR/scripts/utils/log.sh"
. "$MODDIR/scripts/utils/common.sh"

show_help() {
  cat << EOF
Usage: $0 <command> [args]

Commands:
    add <name> <url>    Add subscription
    update <name>       Update the given subscription
    update-all          Update all subscriptions
    remove <name>       Delete subscription
    list                List all subscriptions

Examples:
    $0 add "ProviderA" "https://example.com/sub"
    $0 update "ProviderA"
    $0 remove "ProviderA"
EOF
}

sanitize_name() {
  echo "$1" | sed 's/[\/\\:*?"<>| ]/_/g'
}

write_meta() {
  cat > "$1" << EOF
{
  "name": "$2",
  "url": "$3",
  "updated": "$(date -Iseconds)"
}
EOF
}

cmd_add() {
  local name="${1:-}"
  local url="${2:-}"

  if [ -z "$name" ] || [ -z "$url" ]; then
    echo "Error: please provide a subscription name and URL"
    exit 1
  fi

  case "$name$url" in
    *\"* | *\\*)
      echo "Error: name and URL must not contain double quotes or backslashes"
      exit 1
      ;;
  esac

  local safe_name
  safe_name=$(sanitize_name "$name")
  local sub_dir="$OUTBOUNDS_DIR/sub_$safe_name"

  if [ -d "$sub_dir" ]; then
    echo "Error: subscription '$name' already exists"
    exit 1
  fi

  mkdir -p "$sub_dir"
  write_meta "$sub_dir/_meta.json" "$name" "$url"

  if ! update_subscription "$url" "$sub_dir"; then
    rm -rf "$sub_dir"
    exit 1
  fi

  echo "Subscription '$name' added successfully"
}

cmd_update() {
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "Error: please provide a subscription name"
    exit 1
  fi

  local safe_name
  safe_name=$(sanitize_name "$name")
  local sub_dir="$OUTBOUNDS_DIR/sub_$safe_name"
  local meta_file="$sub_dir/_meta.json"

  if [ ! -f "$meta_file" ]; then
    echo "Error: subscription '$name' does not exist"
    exit 1
  fi

  local url
  url=$(json_field "$meta_file" "url")

  update_subscription "$url" "$sub_dir" || exit 1

  sed -i "s/\"updated\": *\"[^\"]*\"/\"updated\": \"$(date -Iseconds)\"/" "$meta_file"

  echo "Subscription '$name' updated successfully"
}

cmd_update_all() {
  local ok=0 failed=0
  local sub_dir meta_file name
  for sub_dir in "$OUTBOUNDS_DIR"/sub_*; do
    meta_file="$sub_dir/_meta.json"
    [ -f "$meta_file" ] || continue

    name=$(json_field "$meta_file" "name")
    echo "Updating subscription: $name"
    if (cmd_update "$name"); then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
  done

  echo "Updated $ok subscription(s), $failed failed"
  [ "$failed" -eq 0 ]
}

cmd_remove() {
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "Error: please provide a subscription name"
    exit 1
  fi

  local safe_name
  safe_name=$(sanitize_name "$name")
  local sub_dir="$OUTBOUNDS_DIR/sub_$safe_name"

  if [ ! -d "$sub_dir" ]; then
    echo "Error: subscription '$name' does not exist"
    exit 1
  fi

  rm -rf "$sub_dir"
  echo "Subscription '$name' deleted"
}

cmd_list() {
  echo "Subscription list:"
  local sub_dir meta_file name updated node_count
  for sub_dir in "$OUTBOUNDS_DIR"/sub_*; do
    meta_file="$sub_dir/_meta.json"
    [ -f "$meta_file" ] || continue

    name=$(json_field "$meta_file" "name")
    updated=$(json_field "$meta_file" "updated")
    node_count=$(find "$sub_dir" -name "*.json" ! -name "_meta.json" | wc -l)

    echo "  - $name ($node_count nodes, updated $updated)"
  done
}

update_subscription() {
  local url="$1"
  local sub_dir="$2"
  local tmp_dir="$OUTBOUNDS_DIR/.tmp_${sub_dir##*/}"

  log "INFO" "========== Starting Subscription Update =========="
  log "DEBUG" "Target directory: $sub_dir"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  local runner=""
  command -v timeout > /dev/null 2>&1 && runner="timeout 300"

  if $runner "$MODDIR/bin/proxylink" -sub "$url" -dns -format xray -dir "$tmp_dir" >> "$LOG_FILE" 2>&1; then
    if [ -z "$(find "$tmp_dir" -name "*.json" 2> /dev/null | head -n 1)" ]; then
      rm -rf "$tmp_dir"
      log "ERROR" "Subscription returned no nodes, keeping the existing ones"
      echo "Error: subscription returned no nodes, existing nodes were kept"
      return 1
    fi

    # Only files that contain SOCKS nodes need the credential fix
    local socks_files
    socks_files=$(grep -l '"socks"' "$tmp_dir"/*.json 2> /dev/null || true)
    if [ -n "$socks_files" ]; then
      # shellcheck disable=SC2086
      sh "$MODDIR/scripts/utils/socks-fix.sh" json $socks_files >> "$LOG_FILE" 2>&1 || true
    fi

    # proxylink names duplicates "Name_2.json"; use "Name 2.json" like the default group
    local f fname base num
    for f in "$tmp_dir"/*_[0-9]*.json; do
      [ -f "$f" ] || continue
      fname="${f##*/}"
      fname="${fname%.json}"
      num="${fname##*_}"
      base="${fname%_*}"
      case "$num" in '' | *[!0-9]*) continue ;; esac
      [ -f "$tmp_dir/$base.json" ] || continue
      [ -e "$tmp_dir/$base $num.json" ] && continue
      mv "$f" "$tmp_dir/$base $num.json"
    done

    find "$sub_dir" -name "*.json" ! -name "_meta.json" -delete
    mv "$tmp_dir"/*.json "$sub_dir/"
    rm -rf "$tmp_dir"
    log "INFO" "Subscription update complete"
    echo "Nodes imported"
  else
    rm -rf "$tmp_dir"
    log "ERROR" "Subscription update failed"
    echo "Error: subscription update failed, please check the logs"
    return 1
  fi
}

case "${1:-}" in
  add)
    cmd_add "${2:-}" "${3:-}"
    ;;
  update)
    cmd_update "${2:-}"
    ;;
  update-all)
    cmd_update_all
    ;;
  remove)
    cmd_remove "${2:-}"
    ;;
  list)
    cmd_list
    ;;
  -h | --help | "")
    show_help
    ;;
  *)
    echo "Error: unknown command '$1'" >&2
    show_help >&2
    exit 1
    ;;
esac
