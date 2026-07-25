#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Kiwi.app"
PLIST="$APP_DIR/Contents/Info.plist"
STAGING_DIR="$DIST_DIR/.pkg-staging"
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
PKG_PATH="$DIST_DIR/Kiwi-$VERSION-macOS-$ARCHITECTURE_LABEL.pkg"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Applications"
ditto \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$APP_DIR" \
    "$STAGING_DIR/Applications/Kiwi.app"

rm -f "$PKG_PATH"
pkgbuild \
    --root "$STAGING_DIR" \
    --install-location "/" \
    --identifier "com.leo.kiwipet.installer" \
    --version "$VERSION" \
    "$PKG_PATH"

echo "$PKG_PATH"
