#!/bin/bash
# Generates Resources/AppIcon.icns and Resources/PlateDocument.icns
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift Tools/make_icon.swift "$WORK/AppIcon.iconset" >/dev/null
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"

swift Tools/make_doc_icon.swift "$WORK/PlateDocument.iconset" >/dev/null
iconutil -c icns "$WORK/PlateDocument.iconset" -o Resources/PlateDocument.icns
echo "Wrote Resources/PlateDocument.icns"
