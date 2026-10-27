#!/usr/bin/env bash
# Build, test and package LiveCore Studio on a Mac.
#   Requirements: macOS 13+, Xcode 15+ (Swift 5.9+), XcodeGen (brew install xcodegen).
#   Usage: scripts/build_macos.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
XC_CONFIG=$([ "$CONFIG" = "release" ] && echo Release || echo Debug)

# Full Xcode is required (xcodebuild, macOS SDK with Metal/AVFoundation, XCTest).
# Command Line Tools alone are not enough.
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: full Xcode is not active (current developer dir: ${DEV_DIR:-none})."
  if [ -d /Applications/Xcode.app ]; then
    echo "Xcode is installed. Activate it with:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "  sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
  else
    echo "Install Xcode 15 or newer from the Mac App Store (or developer.apple.com/download), open it once, then run:"
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "  sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
  fi
  exit 1
fi

echo "== Environment"
sw_vers; uname -m; xcodebuild -version; swift --version

echo "== Unit tests (LiveCoreCore)"
swift test

echo "== Generate Xcode project"
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate

echo "== Build app ($XC_CONFIG)"
mkdir -p build
xcodebuild -project LiveCoreStudio.xcodeproj -scheme LiveCoreStudio -configuration "$XC_CONFIG" \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' build > build/xcodebuild.log 2>&1 \
  || { grep -E "error:" build/xcodebuild.log | head -50; echo "Full log: build/xcodebuild.log"; exit 1; }
tail -n 5 build/xcodebuild.log

APP="build/DerivedData/Build/Products/$XC_CONFIG/LiveCoreStudio.app"
echo "== Verify bundle"
plutil -p "$APP/Contents/Info.plist" | grep -E "NSCameraUsage|NSMicrophoneUsage|LSMinimumSystemVersion"
lipo -archs "$APP/Contents/MacOS/LiveCoreStudio"
# Every @rpath framework the app links (Lottie) must be embedded, or the app cannot launch.
for fw in $(otool -L "$APP/Contents/MacOS/LiveCoreStudio" | awk '/@rpath\/.*\.framework/{print $1}' | sed -E 's#@rpath/([^/]+\.framework).*#\1#' | sort -u); do
  [ -d "$APP/Contents/Frameworks/$fw" ] || { echo "ERROR: $fw is linked but not embedded in the app"; exit 1; }
  echo "embedded: $fw"
done
# Embedded frameworks keep their vendor's signature (Lottie: Airbnb's Team ID). The hardened runtime
# only loads libraries signed by the app's own team, so when the app itself is ad-hoc signed every
# embedded framework is re-signed ad-hoc and the app re-sealed (inside-out, no --deep).
APP_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -d "$APP/Contents/Frameworks" ] && { [ -z "$APP_TEAM" ] || [ "$APP_TEAM" = "not set" ]; }; then
  for fw in "$APP"/Contents/Frameworks/*.framework; do
    [ -d "$fw" ] || continue
    codesign --force --sign - --timestamp=none "$fw"
  done
  codesign --force --sign - --timestamp=none --options runtime \
    --entitlements Config/LiveCoreStudio.entitlements "$APP"
fi
# Fail the build instead of shipping an app that dyld refuses to launch.
APP_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$fw" ] || continue
  FW_TEAM=$(codesign -dv "$fw" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ "$FW_TEAM" = "$APP_TEAM" ] || { echo "ERROR: $(basename "$fw") Team ID '$FW_TEAM' differs from the app's '$APP_TEAM'"; exit 1; }
  echo "signature ok: $(basename "$fw") (team: ${FW_TEAM:-none})"
done
codesign --verify --deep --strict --verbose=2 "$APP" || true
echo "Built: $APP"
echo "Run:   open \"$APP\""
