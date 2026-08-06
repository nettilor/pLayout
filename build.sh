#!/bin/bash
# Builds pLayout.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP_NAME="pLayout"
EXEC_NAME="PLayout"
APP_DIR="build/${APP_NAME}.app"

if [ ! -f "Resources/AppIcon.icns" ]; then
    Tools/make_icon.sh || echo "(icon generation skipped)"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/${EXEC_NAME}" "$APP_DIR/Contents/MacOS/${EXEC_NAME}"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
echo "Run it with:      open \"$APP_DIR\""
echo "Install it with:  cp -R \"$APP_DIR\" /Applications/"
