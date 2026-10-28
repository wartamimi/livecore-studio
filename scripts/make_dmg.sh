#!/usr/bin/env bash
# Packages a built LiveCoreStudio.app into a drag-to-Applications .dmg (macOS only, uses hdiutil).
#   Usage: scripts/make_dmg.sh [path/to/LiveCoreStudio.app] [output.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/DerivedData/Build/Products/Release/LiveCoreStudio.app}"
OUT="${2:-build/LiveCoreStudio-0.38.1-unsigned.dmg}"
[ -d "$APP" ] || { echo "App not found: $APP (run scripts/build_macos.sh release first)"; exit 1; }
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
# Check the exact copy that goes into the DMG.
"$(dirname "$0")/check_app_loadable.sh" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
# hdiutil on CI runners sometimes fails transiently ("Resource temporarily unavailable"): retry.
ok=0
for attempt in 1 2 3; do
  rm -f "$OUT"
  if hdiutil create -volname "LiveCore Studio" -srcfolder "$STAGE" -ov -format UDZO "$OUT" && sleep 2 && hdiutil verify "$OUT"; then
    ok=1; break
  fi
  echo "hdiutil attempt $attempt failed, retrying…"; sleep $((attempt * 5))
done
rm -rf "$STAGE"
[ "$ok" = 1 ] || { echo "DMG creation failed after 3 attempts"; exit 1; }
echo "DMG: $OUT"
