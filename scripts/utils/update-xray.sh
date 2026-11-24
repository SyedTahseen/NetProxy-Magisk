#!/system/bin/sh

set -e

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly BIN_DIR="$MODDIR/bin"
readonly TEMP_DIR="$BIN_DIR/.tmp"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly REPO="XTLS/Xray-core"
readonly ARCH="android-arm64-v8a"
readonly MIRROR="https://ghfast.top/"

. "$MODDIR/scripts/utils/log.sh"

cleanup() {
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
  return 0
}
trap cleanup EXIT

xray_version() {
  "$BIN_DIR/xray" version 2> /dev/null | head -n 1 | sed 's/Xray \([0-9.]*\).*/\1/'
}

mkdir -p "$TEMP_DIR"

log "INFO" "========== Starting Xray Update =========="

log "INFO" "Fetching the latest version..."
VERSION=$(curl -fsS --connect-timeout 15 "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')

[ -n "$VERSION" ] || die "Unable to get version info"

log "INFO" "Latest version: $VERSION"

if [ -x "$BIN_DIR/xray" ]; then
  CURRENT=$(xray_version)
  if [ -n "$CURRENT" ]; then
    log "INFO" "Local version: $CURRENT"

    LATEST_NUM="${VERSION#v}"
    if [ "$CURRENT" = "$LATEST_NUM" ]; then
      log "INFO" "Already up to date, no update needed"
      exit 0
    fi

    log "INFO" "Preparing to update: $CURRENT -> $LATEST_NUM"
  fi
else
  log "INFO" "No local installation detected, starting first-time installation"
fi

FILENAME="Xray-${ARCH}.zip"
GITHUB_BASE="https://github.com/$REPO/releases/download/$VERSION"
ZIP_FILE="$TEMP_DIR/$FILENAME"
DGST_FILE="$TEMP_DIR/$FILENAME.dgst"

fetch() {
  curl -fL --connect-timeout 15 --retry 2 -o "$2" "$1"
}

# The checksum file is always taken from GitHub directly (never from a mirror),
# so a malicious mirror cannot supply both a tampered binary and a matching hash.
log "INFO" "Fetching checksum from GitHub..."
fetch "$GITHUB_BASE/$FILENAME.dgst" "$DGST_FILE" || die "Could not fetch the checksum file from GitHub, refusing to install an unverified binary"

EXPECTED=$(grep -iE '^SHA(2-)?256' "$DGST_FILE" | head -n 1 | sed 's/.*= *//' | tr -d '[:space:]' | tr 'A-F' 'a-f')
[ -n "$EXPECTED" ] || die "Could not read SHA-256 from the checksum file"

log "INFO" "Starting download..."
if ! fetch "$GITHUB_BASE/$FILENAME" "$ZIP_FILE"; then
  log "WARN" "Direct download failed, trying mirror (checksum is still enforced)"
  fetch "${MIRROR}${GITHUB_BASE}/${FILENAME}" "$ZIP_FILE" || die "Download failed"
fi

FILE_SIZE=$(stat -c%s "$ZIP_FILE" 2> /dev/null || echo "0")
[ "$FILE_SIZE" -ge 1000000 ] || die "Abnormal file size: $FILE_SIZE bytes"

ACTUAL=$(sha256sum "$ZIP_FILE" | cut -d' ' -f1)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  rm -f "$ZIP_FILE"
  die "Checksum mismatch (expected $EXPECTED, got $ACTUAL), update aborted"
fi
log "INFO" "Checksum verified, size: $(echo "$FILE_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')"

log "INFO" "Extracting files..."
unzip -oq "$ZIP_FILE" -d "$TEMP_DIR" || die "Extraction failed"
[ -f "$TEMP_DIR/xray" ] || die "xray binary not found in the downloaded archive"

[ -f "$BIN_DIR/xray" ] && mv "$BIN_DIR/xray" "$BIN_DIR/xray.bak"
if ! cp "$TEMP_DIR/xray" "$BIN_DIR/xray"; then
  [ -f "$BIN_DIR/xray.bak" ] && mv "$BIN_DIR/xray.bak" "$BIN_DIR/xray"
  die "Installation failed, the previous version was restored"
fi
chmod +x "$BIN_DIR/xray"

[ -f "$TEMP_DIR/geoip.dat" ] && cp "$TEMP_DIR/geoip.dat" "$BIN_DIR/"
[ -f "$TEMP_DIR/geosite.dat" ] && cp "$TEMP_DIR/geosite.dat" "$BIN_DIR/"

INSTALLED=$(xray_version)
if [ -z "$INSTALLED" ]; then
  [ -f "$BIN_DIR/xray.bak" ] && mv "$BIN_DIR/xray.bak" "$BIN_DIR/xray"
  die "The new binary does not run, the previous version was restored"
fi

rm -f "$BIN_DIR/xray.bak"

log "INFO" "========== Update successful =========="
log "INFO" "Downloaded version: $VERSION"
log "INFO" "Installed version: $INSTALLED"
