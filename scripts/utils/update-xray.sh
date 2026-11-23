#!/system/bin/sh
set -e

readonly MODDIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly BIN_DIR="$MODDIR/bin"
readonly TEMP_DIR="$BIN_DIR/.tmp"
readonly LOG_FILE="$MODDIR/logs/service.log"
readonly REPO="XTLS/Xray-core"
readonly ARCH="android-arm64-v8a"
readonly MIRROR="https://ghfast.top/?q="
# Import the utility library
. "$MODDIR/scripts/utils/log.sh"

# Clean up temporary files
cleanup() {
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Ensure the directories exist
mkdir -p "$TEMP_DIR" "${LOG_FILE%/*}"

log "========== Starting Xray Update =========="

# Get the latest version
log "Fetching the latest version..."
VERSION=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')

if [ -z "$VERSION" ]; then
  log "Error: unable to get version info"
  exit 1
fi

log "Latest version: $VERSION"

# Check the local version
if [ -x "$BIN_DIR/xray" ]; then
  CURRENT=$("$BIN_DIR/xray" version 2> /dev/null | head -1 | sed 's/Xray \([0-9.]*\).*/\1/')
  if [ -n "$CURRENT" ]; then
    log "Local version: $CURRENT"

    # Compare version numbers (strip the v prefix)
    LATEST_NUM="${VERSION#v}"
    if [ "$CURRENT" = "$LATEST_NUM" ]; then
      log "Already up to date, no update needed"
      exit 0
    fi

    log "Preparing to update: $CURRENT -> $LATEST_NUM"
  fi
else
  log "No local installation detected, starting first-time installation"
fi

# Build the download URL
FILENAME="Xray-${ARCH}.zip"
GITHUB_URL="https://github.com/$REPO/releases/download/$VERSION/$FILENAME"

# URL encoding (simplified)
ENCODED_URL=$(echo "$GITHUB_URL" | sed 's/:/%3A/g; s/\//%2F/g')
DOWNLOAD_URL="${MIRROR}${ENCODED_URL}"

log "Starting download..."
ZIP_FILE="$TEMP_DIR/$FILENAME"

# Download the file
if ! curl -L -o "$ZIP_FILE" "$DOWNLOAD_URL"; then
  log "Error: download failed"
  exit 1
fi

# Verify the file size
FILE_SIZE=$(stat -c%s "$ZIP_FILE" 2> /dev/null || stat -f%z "$ZIP_FILE" 2> /dev/null || echo "0")
if [ "$FILE_SIZE" -lt 1000000 ]; then
  log "Error: abnormal file size"
  exit 1
fi

log "Download complete, size: $(echo "$FILE_SIZE" | awk '{printf "%.1f MB", $1/1024/1024}')"

# Back up the old version
[ -f "$BIN_DIR/xray" ] && mv "$BIN_DIR/xray" "$BIN_DIR/xray.bak"

# Extract
log "Extracting files..."
if ! unzip -oq "$ZIP_FILE" -d "$TEMP_DIR"; then
  log "Error: extraction failed"
  [ -f "$BIN_DIR/xray.bak" ] && mv "$BIN_DIR/xray.bak" "$BIN_DIR/xray"
  exit 1
fi

# Install
mkdir -p "$BIN_DIR"
cp "$TEMP_DIR/xray" "$BIN_DIR/xray"
chmod +x "$BIN_DIR/xray"

# Copy data files
[ -f "$TEMP_DIR/geoip.dat" ] && cp "$TEMP_DIR/geoip.dat" "$BIN_DIR/"
[ -f "$TEMP_DIR/geosite.dat" ] && cp "$TEMP_DIR/geosite.dat" "$BIN_DIR/"

# Delete the backup
rm -f "$BIN_DIR/xray.bak"

# Verify the installation
log "========== Update successful =========="
log "Downloaded version: $VERSION"

if [ -x "$BIN_DIR/xray" ]; then
  # Extract the actually installed version (format: Xray 25.12.8 ...)
  INSTALLED=$("$BIN_DIR/xray" version 2> /dev/null | head -1 | sed 's/Xray \([0-9.]*\).*/\1/')
  if [ -n "$INSTALLED" ]; then
    log "Installed version: $INSTALLED"
  fi
else
  log "Error: installation failed"
  exit 1
fi
