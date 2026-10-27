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

# Zoom Meeting SDK (optional): present only after scripts/fetch_zoom_sdk.sh. Zoom's frameworks are
# signed by Zoom, so an ad-hoc signed app must run without the hardened runtime's library validation.
ZOOM_DIR="$PWD/ThirdParty/ZoomSDK"
ZOOM_ARGS=()
if [ -d "$ZOOM_DIR/ZoomSDK.framework" ]; then
  echo "== Zoom Meeting SDK found: building with LIVECORE_ZOOM=1"
  ZOOM_ARGS=(LIVECORE_ZOOM=1 "LIVECORE_ZOOM_SDK_DIR=$ZOOM_DIR" "LIVECORE_ZOOM_LDFLAGS=-framework ZoomSDK" ENABLE_HARDENED_RUNTIME=NO)
else
  echo "== Zoom Meeting SDK not present: Zoom input compiles as a stub"
fi

echo "== Build app ($XC_CONFIG)"
mkdir -p build
xcodebuild -project LiveCoreStudio.xcodeproj -scheme LiveCoreStudio -configuration "$XC_CONFIG" \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  ${ZOOM_ARGS[@]+"${ZOOM_ARGS[@]}"} build > build/xcodebuild.log 2>&1 \
  || { grep -E "error:" build/xcodebuild.log | head -50; echo "Full log: build/xcodebuild.log"; exit 1; }
tail -n 5 build/xcodebuild.log

APP="build/DerivedData/Build/Products/$XC_CONFIG/LiveCoreStudio.app"
if [ ${#ZOOM_ARGS[@]} -gt 0 ]; then
  echo "== Embed Zoom Meeting SDK"
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$ZOOM_DIR" "$APP/Contents/Frameworks"
  # Re-seal the outer app only; Zoom's nested code keeps Zoom's own signatures.
  codesign --force --sign - --entitlements Config/LiveCoreStudio.entitlements "$APP"
  du -sh "$APP"
fi
echo "== Verify bundle"
plutil -p "$APP/Contents/Info.plist" | grep -E "NSCameraUsage|NSMicrophoneUsage|LSMinimumSystemVersion"
lipo -archs "$APP/Contents/MacOS/LiveCoreStudio"
codesign --verify --deep --strict --verbose=2 "$APP" || true
echo "Built: $APP"
echo "Run:   open \"$APP\""
