#!/system/bin/sh
# Convert a WireGuard (wg-quick) config into an Xray "wireguard" outbound.
#
# Usage:
#   import-wireguard.sh <file.conf> [name]     read config from a file
#   import-wireguard.sh - [name]               read config from stdin
#   import-wireguard.sh --text '<conf text>' [name]
#
# The result is written to the default outbound group as <name>.json and can
# be selected like any other node (cli config switch <name>).

MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTBOUNDS_DIR="$MODDIR/config/xray/outbounds"
DEFAULT_GROUP_DIR="$OUTBOUNDS_DIR/default"

die() {
  echo "Error: $1" >&2
  exit 1
}

src="${1:-}"
[ -n "$src" ] || die "usage: import-wireguard.sh <file.conf|-|--text TEXT> [name]"

tmp_in="${TMPDIR:-/data/local/tmp}/wg_import_$$.conf"
mkdir -p "$(dirname "$tmp_in")" 2> /dev/null
trap 'rm -f "$tmp_in"' EXIT

name=""
case "$src" in
  -)
    cat > "$tmp_in"
    name="${2:-}"
    ;;
  --text)
    [ -n "${2:-}" ] || die "no config text given"
    printf '%s\n' "$2" > "$tmp_in"
    name="${3:-}"
    ;;
  *)
    [ -f "$src" ] || die "file not found: $src"
    cp "$src" "$tmp_in"
    name="${2:-$(basename "$src" .conf)}"
    ;;
esac

# --- helpers -----------------------------------------------------------------

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Turn "a, b ,c" into "a","b","c" (JSON string list body)
json_list() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | sed 's/.*/"&"/' | paste -sd, -
}

# Turn "1, 2, 3" into "1,2,3" (validated numeric list)
num_list() {
  printf '%s' "$1" | tr -d ' ' | tr -d '\r'
}

valid_key() {
  case "$1" in
    '' | *[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  [ "${#1}" -eq 44 ]
}

safe_text() {
  case "$1" in
    *'"'* | *'\'*) return 1 ;;
  esac
  return 0
}

# --- parse -------------------------------------------------------------------

section=""
secret_key=""
address=""
mtu=""
reserved=""
peer_count=0
peers_json=""

# current peer fields
p_pub=""
p_psk=""
p_endpoint=""
p_allowed=""
p_keepalive=""

flush_peer() {
  [ "$section" = "peer" ] || return 0
  [ -n "$p_pub" ] || return 0
  valid_key "$p_pub" || die "invalid PublicKey in [Peer]"
  [ -z "$p_psk" ] || valid_key "$p_psk" || die "invalid PresharedKey in [Peer]"
  if [ -n "$p_endpoint" ]; then
    safe_text "$p_endpoint" || die "invalid Endpoint"
    case "$p_endpoint" in
      *:[0-9]*) ;;
      *) die "Endpoint must be host:port" ;;
    esac
  fi

  local entry="{\"publicKey\":\"$p_pub\""
  [ -z "$p_psk" ] || entry="$entry,\"preSharedKey\":\"$p_psk\""
  [ -z "$p_endpoint" ] || entry="$entry,\"endpoint\":\"$p_endpoint\""
  if [ -n "$p_allowed" ]; then
    entry="$entry,\"allowedIPs\":[$(json_list "$p_allowed")]"
  else
    entry="$entry,\"allowedIPs\":[\"0.0.0.0/0\",\"::/0\"]"
  fi
  case "$p_keepalive" in
    '' | *[!0-9]*) ;;
    *) entry="$entry,\"keepAlive\":$p_keepalive" ;;
  esac
  entry="$entry}"

  peers_json="${peers_json:+$peers_json,}$entry"
  peer_count=$((peer_count + 1))
  first_endpoint="${first_endpoint:-$p_endpoint}"

  p_pub="" p_psk="" p_endpoint="" p_allowed="" p_keepalive=""
}

first_endpoint=""

while IFS= read -r raw || [ -n "$raw" ]; do
  line=$(printf '%s' "$raw" | tr -d '\r')
  line=$(trim "$line")

  # "# Reserved = 1,2,3" (used by Cloudflare WARP exports) is meaningful
  case "$line" in
    \#*[Rr]eserved*=*)
      reserved=$(num_list "${line#*=}")
      continue
      ;;
    \#* | \;* | '') continue ;;
  esac

  # strip trailing inline comments
  line=$(printf '%s' "$line" | sed 's/[[:space:]]#.*$//')

  case "$line" in
    '[Interface]' | '[interface]')
      flush_peer
      section="interface"
      continue
      ;;
    '[Peer]' | '[peer]')
      flush_peer
      section="peer"
      continue
      ;;
  esac

  case "$line" in
    *=*) ;;
    *) continue ;;
  esac

  key=$(trim "${line%%=*}")
  val=$(trim "${line#*=}")
  lkey=$(printf '%s' "$key" | tr 'A-Z' 'a-z')

  case "$section:$lkey" in
    interface:privatekey) secret_key="$val" ;;
    interface:address) address="${address:+$address,}$val" ;;
    interface:mtu) mtu="$val" ;;
    interface:reserved | peer:reserved) reserved=$(num_list "$val") ;;
    interface:dns | interface:listenport | interface:table | interface:preup | interface:postup | interface:predown | interface:postdown | interface:saveconfig | interface:fwmark) ;;
    peer:publickey) p_pub="$val" ;;
    peer:presharedkey) p_psk="$val" ;;
    peer:endpoint) p_endpoint="$val" ;;
    peer:allowedips) p_allowed="${p_allowed:+$p_allowed,}$val" ;;
    peer:persistentkeepalive) p_keepalive="$val" ;;
  esac
done < "$tmp_in"
flush_peer

# --- validate ----------------------------------------------------------------

[ -n "$secret_key" ] || die "no PrivateKey found in [Interface]"
valid_key "$secret_key" || die "PrivateKey is not a valid WireGuard key"
[ -n "$address" ] || die "no Address found in [Interface]"
[ "$peer_count" -ge 1 ] || die "no [Peer] section found"

case "$address" in
  *'"'* | *'\'*) die "invalid Address" ;;
esac

# --- build -------------------------------------------------------------------

settings="\"secretKey\":\"$secret_key\",\"address\":[$(json_list "$address")],\"peers\":[$peers_json]"

case "$mtu" in
  '' | *[!0-9]*) settings="$settings,\"mtu\":1280" ;;
  *) settings="$settings,\"mtu\":$mtu" ;;
esac

if [ -n "$reserved" ]; then
  case "$reserved" in
    *[!0-9,]*) die "Reserved must be three comma-separated numbers (e.g. 0,0,0)" ;;
  esac
  settings="$settings,\"reserved\":[$reserved]"
fi

# --- name & write ------------------------------------------------------------

if [ -z "$name" ]; then
  host="${first_endpoint%:*}"
  host=$(printf '%s' "$host" | tr -d '[]')
  name="wireguard-${host:-node}"
fi
name=$(printf '%s' "$name" | sed 's/[\/\\:*?"<>|]/_/g')

mkdir -p "$DEFAULT_GROUP_DIR"
target="$DEFAULT_GROUP_DIR/$name.json"
n=2
while [ -e "$target" ]; do
  target="$DEFAULT_GROUP_DIR/${name} $n.json"
  n=$((n + 1))
done

cat > "$target" << EOF
{
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "wireguard",
      "settings": {$settings}
    }
  ]
}
EOF

echo "Imported WireGuard config: $(basename "$target")"
