#!/system/bin/sh
# Download the latest Xray-core release (Android arm64) into bin/
# Usage: update-xray.sh

set -e

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly BIN_DIR="$MODDIR/bin"
readonly TEMP_DIR="$BIN_DIR/.tmp"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly REPO="XTLS/Xray-core"
readonly ARCH="android-arm64-v8a"
readonly MIRROR="https://ghfast.top/?q="

. "$MODDIR/scripts/utils/log.sh"

# Clean up temporary files
cleanup() {
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
  return 0
}
trap cleanup EXIT

# Print the installed Xray version number (e.g. 25.12.8)
xray_version() {
  "$BIN_DIR/xray" version 2> /dev/null | head -n 1 | sed 's/Xray \([0-9.]*\).*/\1/'
}

mkdir -p "$TEMP_DIR"

log "INFO" "========== Starting Xray Update =========="

# Get the latest version
log "INFO" "Fetching the latest version..."
VERSION=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')

[ -n "$VERSION" ] || die "Unable to get version info"

log "INFO" "Latest version: $VERSION"

# Check the local version
if [ -x "$BIN_DIR/xray" ]; then
  CURRENT=$(xray_version)
  if [ -n "$CURRENT" ]; then
    log "INFO" "Local version: $CURRENT"

    # Compare version numbers (strip the v prefix)
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

# Build the download URL (simplified URL encoding for the mirror)
FILENAME="Xray-${ARCH}.zip"
GITHUB_URL="https://github.com/$REPO/releases/download/$VERSION/$FILENAME"
ENCODED_URL=$(echo "$GITHUB_URL" | sed 's/:/%3A/g; s/\//%2F/g')
DOWNLOAD_URL="${MIRROR}${ENCODED_URL}"

log "INFO" "Starting download..."
ZIP_FILE="$TEMP_DIR/$FILENAME"

curl -L -o "$ZIP_FILE" "$DOWNLOAD_URL" || die "Download failed"

# Verify the file size
FILE_SIZE=$(stat -c%s "$ZIP_FILE" 2> /dev/null || stat -f%z "$ZIP_FILE" 2> /dev/null || echo "0")
[ "$FILE_SIZE" -ge 1000000 ] || die "Abnormal file size: $FILE_SIZE bytes"

log "INFO" "Download complete, size: $(echo "$FILE_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')"

# Extract into the temp dir first, so the old binary is untouched if this fails
log "INFO" "Extracting files..."
unzip -oq "$ZIP_FILE" -d "$TEMP_DIR" || die "Extraction failed"
[ -f "$TEMP_DIR/xray" ] || die "xray binary not found in the downloaded archive"

# Install (keep a backup of the old binary until the new one is in place)
[ -f "$BIN_DIR/xray" ] && mv "$BIN_DIR/xray" "$BIN_DIR/xray.bak"
if ! cp "$TEMP_DIR/xray" "$BIN_DIR/xray"; then
  [ -f "$BIN_DIR/xray.bak" ] && mv "$BIN_DIR/xray.bak" "$BIN_DIR/xray"
  die "Installation failed, the previous version was restored"
fi
chmod +x "$BIN_DIR/xray"

# Copy data files
[ -f "$TEMP_DIR/geoip.dat" ] && cp "$TEMP_DIR/geoip.dat" "$BIN_DIR/"
[ -f "$TEMP_DIR/geosite.dat" ] && cp "$TEMP_DIR/geosite.dat" "$BIN_DIR/"

# Verify the installation (format of `xray version`: Xray 25.12.8 ...)
INSTALLED=$(xray_version)
if [ -z "$INSTALLED" ]; then
  [ -f "$BIN_DIR/xray.bak" ] && mv "$BIN_DIR/xray.bak" "$BIN_DIR/xray"
  die "The new binary does not run, the previous version was restored"
fi

rm -f "$BIN_DIR/xray.bak"

log "INFO" "========== Update successful =========="
log "INFO" "Downloaded version: $VERSION"
log "INFO" "Installed version: $INSTALLED"
