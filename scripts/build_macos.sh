#!/usr/bin/env bash
# Build, test and package LiveCore Studio on a Mac.
#   Requirements: macOS 13+, Xcode 15+ (Swift 5.9+), XcodeGen (brew install xcodegen).
#   Usage: scripts/build_macos.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
XC_CONFIG=$([ "$CONFIG" = "release" ] && echo Release || echo Debug)

echo "== Environment"
sw_vers; uname -m; xcodebuild -version; swift --version

echo "== Unit tests (LiveCoreCore)"
swift test

echo "== Generate Xcode project"
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate

echo "== Build app ($XC_CONFIG)"
xcodebuild -project LiveCoreStudio.xcodeproj -scheme LiveCoreStudio -configuration "$XC_CONFIG" \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' build | tail -n 20

APP="build/DerivedData/Build/Products/$XC_CONFIG/LiveCoreStudio.app"
echo "== Verify bundle"
plutil -p "$APP/Contents/Info.plist" | grep -E "NSCameraUsage|NSMicrophoneUsage|LSMinimumSystemVersion"
lipo -archs "$APP/Contents/MacOS/LiveCoreStudio"
codesign --verify --deep --strict --verbose=2 "$APP" || true
echo "Built: $APP"
echo "Run:   open \"$APP\""
