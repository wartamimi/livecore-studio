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
# Every @rpath framework the app links must be embedded, or the app cannot launch.
for fw in $(otool -L "$APP/Contents/MacOS/LiveCoreStudio" | awk '/@rpath\/.*\.framework/{print $1}' | sed -E 's#@rpath/([^/]+\.framework).*#\1#' | sort -u); do
  [ -d "$APP/Contents/Frameworks/$fw" ] || { echo "ERROR: $fw is linked but not embedded in the app"; exit 1; }
  echo "embedded: $fw"
done
# The LiveCore Virtual Camera (CoreMediaIO system extension) must be embedded where
# OSSystemExtensionRequest looks for it.
SYSEXT="$APP/Contents/Library/SystemExtensions/studio.livecore.LiveCoreStudio.CameraExtension.systemextension"
[ -d "$SYSEXT" ] || { echo "ERROR: camera extension not embedded at $SYSEXT"; find "$APP/Contents" -maxdepth 3 | head -40; exit 1; }
plutil -p "$SYSEXT/Contents/Info.plist" | grep -E "CFBundleIdentifier|CMIOExtensionMachServiceName"
scripts/check_app_loadable.sh "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" || true
echo "Built: $APP"
echo "Run:   open \"$APP\""
