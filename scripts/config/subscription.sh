#!/system/bin/sh

#############################################################################
# Subscription management script
# Function: add/update/remove/list subscriptions
#############################################################################

set -e

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly OUTBOUNDS_DIR="$MODDIR/config/xray/outbounds"
readonly LOG_FILE="$MODDIR/logs/subscription.log"

# Import the utility library
. "$MODDIR/scripts/utils/log.sh"

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
# Add subscription
#######################################
cmd_add() {
  local name="$1"
  local url="$2"

  if [ -z "$name" ] || [ -z "$url" ]; then
    echo "Error: please provide a subscription name and URL"
    exit 1
  fi

  local safe_name=$(sanitize_name "$name")
  local sub_dir="$OUTBOUNDS_DIR/sub_$safe_name"

  if [ -d "$sub_dir" ]; then
    echo "Error: subscription '$name' already exists"
    exit 1
  fi

  mkdir -p "$sub_dir"

  # Save metadata
  cat > "$sub_dir/_meta.json" << EOF
{
  "name": "$name",
  "url": "$url",
  "updated": "$(date -Iseconds)"
}
EOF

  # Download and parse nodes
  update_subscription "$name" "$url" "$sub_dir"

  echo "Subscription '$name' added successfully"
}

#######################################
# Update subscription
#######################################
cmd_update() {
  local name="$1"

  if [ -z "$name" ]; then
    echo "Error: please provide a subscription name"
    exit 1
  fi

  local safe_name=$(sanitize_name "$name")
  local sub_dir="$OUTBOUNDS_DIR/sub_$safe_name"
  local meta_file="$sub_dir/_meta.json"

  if [ ! -f "$meta_file" ]; then
    echo "Error: subscription '$name' does not exist"
    exit 1
  fi

  # Read the URL
  local url=$(grep -o '"url": *"[^"]*"' "$meta_file" | sed 's/"url": *"\([^"]*\)"/\1/')

  # Clear old nodes (keep _meta.json)
  find "$sub_dir" -name "*.json" ! -name "_meta.json" -delete

  # Update nodes
  update_subscription "$name" "$url" "$sub_dir"

  # Update the timestamp
  local temp_meta=$(cat "$meta_file")
  echo "$temp_meta" | sed "s/\"updated\": *\"[^\"]*\"/\"updated\": \"$(date -Iseconds)\"/" > "$meta_file"

  echo "Subscription '$name' updated successfully"
}

#######################################
# Update all subscriptions
#######################################
cmd_update_all() {
  local count=0
  for sub_dir in "$OUTBOUNDS_DIR"/sub_*; do
    [ -d "$sub_dir" ] || continue
    local meta_file="$sub_dir/_meta.json"
    [ -f "$meta_file" ] || continue

    local name=$(grep -o '"name": *"[^"]*"' "$meta_file" | sed 's/"name": *"\([^"]*\)"/\1/')
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
  local name="$1"

  if [ -z "$name" ]; then
    echo "Error: please provide a subscription name"
    exit 1
  fi

  local safe_name=$(sanitize_name "$name")
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
  for sub_dir in "$OUTBOUNDS_DIR"/sub_*; do
    [ -d "$sub_dir" ] || continue
    local meta_file="$sub_dir/_meta.json"
    [ -f "$meta_file" ] || continue

    local name=$(grep -o '"name": *"[^"]*"' "$meta_file" | sed 's/"name": *"\([^"]*\)"/\1/')
    local updated=$(grep -o '"updated": *"[^"]*"' "$meta_file" | sed 's/"updated": *"\([^"]*\)"/\1/')
    local node_count=$(find "$sub_dir" -name "*.json" ! -name "_meta.json" | wc -l)

    echo "  - $name ($node_count nodes, updated $updated)"
  done
}

#######################################
# Download and parse the subscription
#######################################
update_subscription() {
  local name="$1"
  local url="$2"
  local sub_dir="$3"

  log "INFO" "========== Starting Subscription Update =========="
  log "DEBUG" "Subscription name: $name"
  log "DEBUG" "URL: $url"
  log "DEBUG" "Target directory: $sub_dir"

  # Use proxylink to convert the subscription
  # -sub: subscription URL
  # -format xray: output in xray format
  # -dir: output directory (one file per node)
  if "$MODDIR/bin/proxylink" -sub "$url" -insecure -dns -format xray -dir "$sub_dir" >> "$LOG_FILE" 2>&1; then
    log "INFO" "Subscription update complete"
    echo "Nodes imported"
  else
    log "ERROR" "Subscription update failed"
    echo "Error: subscription update failed, please check the logs"
    exit 1
  fi
}

#######################################
# Main program
#######################################
case "${1:-}" in
  add)
    cmd_add "$2" "$3"
    ;;
  update)
    cmd_update "$2"
    ;;
  update-all)
    cmd_update_all
    ;;
  remove)
    cmd_remove "$2"
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
