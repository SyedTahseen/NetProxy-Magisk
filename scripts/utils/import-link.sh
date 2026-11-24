#!/system/bin/sh

MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTBOUNDS_DIR="$MODDIR/config/xray/outbounds"
DEFAULT_GROUP_DIR="$OUTBOUNDS_DIR/default"

. "$MODDIR/scripts/utils/common.sh"

link="${1:-}"
[ -n "$link" ] || {
  echo "Error: please provide a node link"
  exit 1
}

case "$link" in
  *"[Interface]"* | *"[interface]"*)
    exec sh "$MODDIR/scripts/utils/import-wireguard.sh" --text "$link"
    ;;
  wireguard://* | wg://*)
    exec sh "$MODDIR/scripts/utils/import-wireguard.sh" "$link"
    ;;
  /*.conf | /*.CONF)
    exec sh "$MODDIR/scripts/utils/import-wireguard.sh" "$link"
    ;;
esac

link=$(sh "$MODDIR/scripts/utils/socks-fix.sh" link "$link")

mkdir -p "$DEFAULT_GROUP_DIR"
chmod +x "$MODDIR/bin/proxylink" 2> /dev/null

tmp_dir="$OUTBOUNDS_DIR/.tmp_import_$$"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

if ! (cd "$tmp_dir" && "$MODDIR/bin/proxylink" -parse "$link" -format xray -auto); then
  rm -rf "$tmp_dir"
  exit 1
fi

imported=0
for f in "$tmp_dir"/*.json; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .json)"
  target=$(unique_json_path "$DEFAULT_GROUP_DIR" "$base")
  mv "$f" "$target"
  imported=$((imported + 1))
done
rm -rf "$tmp_dir"

if [ "$imported" -eq 0 ]; then
  echo "Error: no node was generated from the link"
  exit 1
fi
