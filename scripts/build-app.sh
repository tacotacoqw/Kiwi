#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARM64_BUILD_DIR="$PROJECT_DIR/.build/arm64/arm64-apple-macosx/release"
X86_64_BUILD_DIR="$PROJECT_DIR/.build/x86_64/x86_64-apple-macosx/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Kiwi.app"
STAGING_DIR="$DIST_DIR/.Kiwi.app.staging"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
swift build \
    -c release \
    --triple arm64-apple-macosx13.0 \
    --scratch-path "$PROJECT_DIR/.build/arm64" \
    --disable-sandbox \
    --product KiwiPet
swift build \
    -c release \
    --triple x86_64-apple-macosx13.0 \
    --scratch-path "$PROJECT_DIR/.build/x86_64" \
    --disable-sandbox \
    --product KiwiPet

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Contents/MacOS"
mkdir -p "$STAGING_DIR/Contents/Resources/Frames"
mkdir -p "$STAGING_DIR/Contents/Resources/Icons"
mkdir -p "$STAGING_DIR/Contents/Resources/Sounds"

lipo -create \
    "$ARM64_BUILD_DIR/KiwiPet" \
    "$X86_64_BUILD_DIR/KiwiPet" \
    -output "$STAGING_DIR/Contents/MacOS/KiwiPet"
cp "$PROJECT_DIR/Info.plist" "$STAGING_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Assets/AppIcon/AppIcon.icns" "$STAGING_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon/StatusIconTemplate.png" "$STAGING_DIR/Contents/Resources/StatusIconTemplate.png"
cp "$PROJECT_DIR"/Assets/Frames/*.png "$STAGING_DIR/Contents/Resources/Frames/"
cp "$PROJECT_DIR"/Assets/Icons/*.svg "$STAGING_DIR/Contents/Resources/Icons/"
cp "$PROJECT_DIR"/Assets/Sounds/*.mp3 "$STAGING_DIR/Contents/Resources/Sounds/"

# A plain ad-hoc signature synthesizes a cdhash-only designated requirement,
# which changes for every build. The login keychain then treats each build as
# a different app and asks for the user's password. Give local Kiwi builds one
# stable designated requirement so Keychain ACL trust survives updates.
codesign \
    --force \
    --deep \
    --sign - \
    -r='designated => identifier "com.leo.kiwipet"' \
    "$STAGING_DIR"
rm -rf "$APP_DIR"
mv "$STAGING_DIR" "$APP_DIR"

echo "$APP_DIR"
