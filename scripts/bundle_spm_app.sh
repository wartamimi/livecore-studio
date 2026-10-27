#!/usr/bin/env bash
# Alternative without XcodeGen: build with SwiftPM and assemble a minimal .app bundle
# (Info.plist with camera/microphone usage strings + ad-hoc signature with entitlements).
# A bare `swift run LiveCoreStudio` would be killed by TCC on first camera access because a
# command-line binary has no NSCameraUsageDescription — always run the bundled .app.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LiveCoreStudio
BIN="$(swift build -c release --show-bin-path)"
APP="build/LiveCoreStudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LiveCoreStudio" "$APP/Contents/MacOS/LiveCoreStudio"
# SwiftPM resource bundle (localisations) must sit next to the executable or in Resources.
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
sed -e 's/$(EXECUTABLE_NAME)/LiveCoreStudio/' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/studio.livecore.LiveCoreStudio/' \
  Config/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements Config/LiveCoreStudio.entitlements "$APP"
codesign --verify --verbose=2 "$APP"
echo "Built $APP — run with: open $APP"
