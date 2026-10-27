#!/usr/bin/env bash
# Packages a built LiveCoreStudio.app into a drag-to-Applications .dmg (macOS only, uses hdiutil).
#   Usage: scripts/make_dmg.sh [path/to/LiveCoreStudio.app] [output.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/DerivedData/Build/Products/Release/LiveCoreStudio.app}"
OUT="${2:-build/LiveCoreStudio-0.1.0-unsigned.dmg}"
[ -d "$APP" ] || { echo "App not found: $APP (run scripts/build_macos.sh release first)"; exit 1; }
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "LiveCore Studio" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
hdiutil verify "$OUT"
echo "DMG: $OUT"
