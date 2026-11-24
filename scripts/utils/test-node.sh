#!/system/bin/sh
# Real connectivity/latency test for one outbound config.
#
# Starts a throw-away Xray instance whose only outbound is the node under test,
# fetches a tiny URL through it and prints one line:
#   "<n> ms" | "timeout" | "failed"
# Works for every protocol Xray supports (vless, socks, http, wireguard, ...),
# unlike an ICMP ping, which many servers block and which proves nothing about
# the proxy itself.
#
# Usage: test-node.sh <outbound.json> [url]

MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
XRAY_BIN="$MODDIR/bin/xray"
NODE_CONFIG="${1:-}"
TEST_URL="${2:-http://www.gstatic.com/generate_204}"
TEST_HOST="${TEST_URL#*://}"
TEST_HOST="${TEST_HOST%%/*}"
TIMEOUT=8

finish() {
  echo "$1"
  exit 0
}

[ -f "$NODE_CONFIG" ] || finish "failed"
[ -x "$XRAY_BIN" ] || finish "failed"

BUSYBOX=""
for path in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  [ -f "$path" ] && BUSYBOX="$path" && break
done
[ -n "$BUSYBOX" ] || BUSYBOX="busybox"

WORK_DIR="${TMPDIR:-/data/local/tmp}/netproxy_test_$$"
SOCKS_PORT=$((20000 + $$ % 20000))
DOOR_PORT=$((40000 + $$ % 20000))
XRAY_PID=""

cleanup() {
  [ -n "$XRAY_PID" ] && kill "$XRAY_PID" 2> /dev/null
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

now_ms() {
  awk '{printf "%d", $1 * 1000}' /proc/uptime
}

mkdir -p "$WORK_DIR" || finish "failed"
chmod 755 "$WORK_DIR"

# Local entry points (loopback only) routed to the node's "proxy" outbound.
# The dokodemo-door inbound forwards to the test host, so a plain HTTP client
# such as busybox wget works when curl is not available.
cat > "$WORK_DIR/test.json" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "test-socks",
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": { "udp": false }
    },
    {
      "tag": "test-door",
      "listen": "127.0.0.1",
      "port": $DOOR_PORT,
      "protocol": "dokodemo-door",
      "settings": { "address": "$TEST_HOST", "port": 80, "network": "tcp" }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["test-socks", "test-door"], "outboundTag": "proxy" }
    ]
  }
}
EOF
chmod 644 "$WORK_DIR/test.json"

# Run as the same user as the main core so its traffic bypasses the TPROXY rules
# (otherwise the test would be proxied twice while the service is running).
"$BUSYBOX" setuidgid root:net_admin "$XRAY_BIN" run \
  -config "$WORK_DIR/test.json" -config "$NODE_CONFIG" > "$WORK_DIR/xray.log" 2>&1 &
XRAY_PID=$!

# Wait up to ~3s for the core to come up
tries=0
while [ "$tries" -lt 15 ]; do
  kill -0 "$XRAY_PID" 2> /dev/null || finish "failed"
  grep -q "started" "$WORK_DIR/xray.log" 2> /dev/null && break
  sleep 0.2 2> /dev/null || sleep 1
  tries=$((tries + 1))
done
kill -0 "$XRAY_PID" 2> /dev/null || finish "failed"

start=$(now_ms)
if command -v curl > /dev/null 2>&1; then
  curl -s -o /dev/null --max-time "$TIMEOUT" --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$TEST_URL" 2> /dev/null
  rc=$?
else
  "$BUSYBOX" wget -q -O /dev/null -T "$TIMEOUT" --header "Host: $TEST_HOST" \
    "http://127.0.0.1:$DOOR_PORT/${TEST_URL#*://$TEST_HOST/}" 2> "$WORK_DIR/wget.err"
  rc=$?
  # A non-2xx answer still proves the node relayed our request
  [ "$rc" -ne 0 ] && grep -q "HTTP/" "$WORK_DIR/wget.err" 2> /dev/null && rc=0
fi
elapsed=$(($(now_ms) - start))

if [ "$rc" -eq 0 ]; then
  finish "${elapsed} ms"
elif [ "$rc" -eq 28 ] || [ "$elapsed" -ge $((TIMEOUT * 1000 - 500)) ]; then
  finish "timeout"
fi
finish "failed"
