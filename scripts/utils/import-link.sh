#!/system/bin/sh
# Import a node link into the default group (used by the CLI and the WebUI).
# Normalizes socks:// links with base64 credentials before calling proxylink.
# Usage: import-link.sh <node-link>

MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEFAULT_GROUP_DIR="$MODDIR/config/xray/outbounds/default"

link="${1:-}"
[ -n "$link" ] || {
  echo "Error: please provide a node link"
  exit 1
}

link=$(sh "$MODDIR/scripts/utils/socks-fix.sh" link "$link")

mkdir -p "$DEFAULT_GROUP_DIR"
chmod +x "$MODDIR/bin/proxylink" 2> /dev/null
# proxylink writes the generated node file into the current directory
cd "$DEFAULT_GROUP_DIR" && "$MODDIR/bin/proxylink" -parse "$link" -insecure -format xray -auto
