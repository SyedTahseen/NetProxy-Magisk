#!/system/bin/sh

#############################################################################
# Subscription management script
# Function: add/update/remove/list subscriptions
#############################################################################

set -e

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly OUTBOUNDS_DIR="$MODDIR/config/xray/outbounds"
readonly LOG_FILE="$MODDIR/logs/subscription.log"

. "$MODDIR/scripts/utils/log.sh"
. "$MODDIR/scripts/utils/common.sh"

#######################################
# Show help
#######################################
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
  exit 0
}

#######################################
# Sanitize the file name
#######################################
sanitize_name() {
  echo "$1" | sed 's/[\/\\:*?"<>| ]/_/g'
}

#######################################
# Write the subscription metadata file
# Arguments: <meta_file> <name> <url>
#######################################
write_meta() {
  cat > "$1" << EOF
{
  "name": "$2",
  "url": "$3",
  "updated": "$(date -Iseconds)"
}
EOF
}

#######################################
# Add subscription
#######################################
cmd_add() {
  local name="${1:-}"
  local url="${2:-}"

  if [ -z "$name" ] || [ -z "$url" ]; then
    echo "Error: please provide a subscription name and URL"
    exit 1
  fi

  # The metadata is stored as flat JSON, so these characters cannot be represented safely
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

  # Download and parse nodes (do not leave an empty subscription behind on failure)
  if ! update_subscription "$url" "$sub_dir"; then
    rm -rf "$sub_dir"
    exit 1
  fi

  echo "Subscription '$name' added successfully"
}

#######################################
# Update subscription
#######################################
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

  # Existing nodes are replaced only after the new ones were downloaded successfully
  update_subscription "$url" "$sub_dir" || exit 1

  # Update the timestamp
  sed -i "s/\"updated\": *\"[^\"]*\"/\"updated\": \"$(date -Iseconds)\"/" "$meta_file"

  echo "Subscription '$name' updated successfully"
}

#######################################
# Update all subscriptions
#######################################
cmd_update_all() {
  local count=0
  local sub_dir meta_file name
  for sub_dir in "$OUTBOUNDS_DIR"/sub_*; do
    meta_file="$sub_dir/_meta.json"
    [ -f "$meta_file" ] || continue

    name=$(json_field "$meta_file" "name")
    echo "Updating subscription: $name"
    cmd_update "$name"
    count=$((count + 1))
  done

  echo "Updated $count subscription(s)"
}

#######################################
# Delete subscription
#######################################
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

#######################################
# List subscriptions
#######################################
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

#######################################
# Download and parse the subscription into <sub_dir>
# The nodes are first generated in a temporary directory, then swapped in,
# so a failed download never destroys the nodes that are already there.
# Arguments: <url> <sub_dir>
#######################################
update_subscription() {
  local url="$1"
  local sub_dir="$2"
  local tmp_dir="$OUTBOUNDS_DIR/.tmp_${sub_dir##*/}"

  log "INFO" "========== Starting Subscription Update =========="
  log "DEBUG" "URL: $url"
  log "DEBUG" "Target directory: $sub_dir"

  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  # Use proxylink to convert the subscription
  # -sub: subscription URL
  # -format xray: output in xray format
  # -dir: output directory (one file per node)
  if "$MODDIR/bin/proxylink" -sub "$url" -insecure -dns -format xray -dir "$tmp_dir" >> "$LOG_FILE" 2>&1; then
    # Replace the old nodes (keep _meta.json)
    find "$sub_dir" -name "*.json" ! -name "_meta.json" -delete
    find "$tmp_dir" -name "*.json" -exec mv {} "$sub_dir/" \;
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

#######################################
# Main program
#######################################
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
    echo "Error: unknown command '$1'"
    show_help
    ;;
esac
