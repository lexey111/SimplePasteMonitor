#!/usr/bin/env bash
set -euo pipefail

# Build a Release .app and package it as a .dmg
# Usage: ./scripts/build-release.sh [version]
#   version  – e.g. "1.1.0" (used in output filename; defaults to "dev")

VERSION="${1:-dev}"
SCHEME="SimplePasteMonitor"
APP_NAME="SimplePasteMonitor"
BUILD_DIR="$(mktemp -d)"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build"

echo "==> Building ${SCHEME} (Release)…"
xcodebuild -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -arch "$(uname -m)" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    ONLY_ACTIVE_ARCH=NO \
    clean build 2>&1 | tail -5

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: ${APP_PATH} not found"
    exit 1
fi

echo "==> Creating DMG…"
mkdir -p "$OUTPUT_DIR"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
rm -f "$DMG_PATH"

# Create a temporary directory with the .app and an Applications symlink
STAGING="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Cleanup
rm -rf "$STAGING" "$BUILD_DIR"

echo ""
echo "==> Done: ${DMG_PATH}"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
