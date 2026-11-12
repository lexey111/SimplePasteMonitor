#!/usr/bin/env bash
set -euo pipefail

# Build a Release .app and package it as a .dmg
# Usage: ./scripts/build-release.sh [version]
#   version  – e.g. "1.1.0" (used in output filename; defaults to "dev")
#
# With a «Developer ID Application» certificate in the keychain the app and
# the DMG are signed with it (hardened runtime, a secure timestamp), the DMG
# is notarized and the ticket stapled to it — macOS then opens it with no
# «Open Anyway». Notarization reads its credentials from a keychain profile
# (NOTARY_PROFILE, default "simple-utilities-notary"), stored once with
# `xcrun notarytool store-credentials`. Without the certificate the build is
# ad-hoc signed, as before.

VERSION="${1:-dev}"
SCHEME="SimplePasteMonitor"
APP_NAME="SimplePasteMonitor"
BUILD_DIR="$(mktemp -d)"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build"
NOTARY_PROFILE="${NOTARY_PROFILE:-simple-utilities-notary}"

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    TEAM="$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
    echo "==> Building ${SCHEME} (Release), signed with Developer ID…"
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" "DEVELOPMENT_TEAM=${TEAM}"
             PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=YES
             "OTHER_CODE_SIGN_FLAGS=--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
else
    echo "==> Building ${SCHEME} (Release), ad-hoc signed (no Developer ID certificate)…"
    SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES)
fi

xcodebuild -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -arch "$(uname -m)" \
    ONLY_ACTIVE_ARCH=NO \
    "${SIGNING[@]}" \
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

if [ -n "$IDENTITY" ]; then
    echo "==> Signing and notarizing the DMG…"
    codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
fi

# Cleanup
rm -rf "$STAGING" "$BUILD_DIR"

echo ""
echo "==> Done: ${DMG_PATH}"
echo "    Size: $(du -h "$DMG_PATH" | cut -f1)"
