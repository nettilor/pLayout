#!/bin/bash
# Builds pLayout.app into ./build
# --universal compiles for Apple Silicon and Intel both, for a distributable build.
set -euo pipefail
cd "$(dirname "$0")"

# Ask SwiftPM where it put the product rather than assuming a path: the
# multi-arch layout moved from .build/apple/Products to .build/out/Products
# between toolchains, and a wrong path here made the release DMG fail silently.
if [ "${1:-}" = "--universal" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi
BINARY="$BIN_DIR/PLayout"

APP_NAME="pLayout"
EXEC_NAME="PLayout"
APP_DIR="build/${APP_NAME}.app"

if [ ! -f "Resources/AppIcon.icns" ] || [ ! -f "Resources/PlateDocument.icns" ]; then
    Tools/make_icon.sh || echo "(icon generation skipped)"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/${EXEC_NAME}"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
# The .plate document icon, named by CFBundleTypeIconFile/UTTypeIconFile.
if [ -f "Resources/PlateDocument.icns" ]; then
    cp "Resources/PlateDocument.icns" "$APP_DIR/Contents/Resources/PlateDocument.icns"
fi
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
echo "Run it with:      open \"$APP_DIR\""
echo "Install it with:  cp -R \"$APP_DIR\" /Applications/"
