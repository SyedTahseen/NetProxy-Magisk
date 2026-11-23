#!/system/bin/sh

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
    target="$DEFAULT_GROUP_DIR/${base} $n.json"
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
