#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Kiwi.app"
PLIST="$APP_DIR/Contents/Info.plist"
STAGING_DIR="$DIST_DIR/.dmg-staging"
trap 'rm -rf "$STAGING_DIR"' EXIT

if [[ ! -d "$APP_DIR" ]]; then
    echo "Missing $APP_DIR; run ./scripts/build-app.sh first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ARCHITECTURES="$(lipo -archs "$APP_DIR/Contents/MacOS/KiwiPet" | tr ' ' '-')"
if [[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]]; then
    ARCHITECTURE_LABEL="universal"
else
    ARCHITECTURE_LABEL="$ARCHITECTURES"
fi
DMG_PATH="$DIST_DIR/Kiwi-$VERSION-macOS-$ARCHITECTURE_LABEL.dmg"
VOLUME_NAME="Kiwi $VERSION"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_DIR" "$STAGING_DIR/Kiwi.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "$DMG_PATH"
