#!/system/bin/sh
# Import a node link into the default group (used by the CLI and the WebUI).
# Normalizes socks:// links with base64 credentials before calling proxylink.
# Nodes whose name already exists are kept side by side (Germany, Germany_2, ...)
# instead of overwriting the older node.
# Usage: import-link.sh <node-link>

MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTBOUNDS_DIR="$MODDIR/config/xray/outbounds"
DEFAULT_GROUP_DIR="$OUTBOUNDS_DIR/default"

link="${1:-}"
[ -n "$link" ] || {
  echo "Error: please provide a node link"
  exit 1
}

link=$(sh "$MODDIR/scripts/utils/socks-fix.sh" link "$link")

mkdir -p "$DEFAULT_GROUP_DIR"
chmod +x "$MODDIR/bin/proxylink" 2> /dev/null

# proxylink names the file after the node and writes it into the current
# directory, silently overwriting a node with the same name. So generate it in a
# temporary directory first and move it into the group with a unique name.
tmp_dir="$OUTBOUNDS_DIR/.tmp_import_$$"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

if ! (cd "$tmp_dir" && "$MODDIR/bin/proxylink" -parse "$link" -insecure -format xray -auto); then
  rm -rf "$tmp_dir"
  exit 1
fi

imported=0
for f in "$tmp_dir"/*.json; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .json)"
  target="$DEFAULT_GROUP_DIR/$base.json"
  n=2
  while [ -e "$target" ]; do
    target="$DEFAULT_GROUP_DIR/${base}_$n.json"
    n=$((n + 1))
  done
  mv "$f" "$target"
  imported=$((imported + 1))
done
rm -rf "$tmp_dir"

if [ "$imported" -eq 0 ]; then
  echo "Error: no node was generated from the link"
  exit 1
fi
