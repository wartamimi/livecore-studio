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

# CI runs the tests in a parallel job (LIVECORE_SKIP_TESTS=1) so the DMG is ready sooner.
if [ "${LIVECORE_SKIP_TESTS:-0}" != "1" ]; then
  echo "== Unit tests (LiveCoreCore)"
  swift test
fi

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
plutil -p "$APP/Contents/Info.plist" | grep -E "NSCameraUsage|NSMicrophoneUsage|NSLocalNetworkUsage|_ndi._tcp|LSMinimumSystemVersion"
lipo -archs "$APP/Contents/MacOS/LiveCoreStudio"
# Every @rpath framework the app links must be embedded, or the app cannot launch.
for fw in $(otool -L "$APP/Contents/MacOS/LiveCoreStudio" | awk '/@rpath\/.*\.framework/{print $1}' | sed -E 's#@rpath/([^/]+\.framework).*#\1#' | sort -u); do
  [ -d "$APP/Contents/Frameworks/$fw" ] || { echo "ERROR: $fw is linked but not embedded in the app"; exit 1; }
  echo "embedded: $fw"
done
# Stable signature (optional). An ad-hoc signature changes with every build, so macOS treats each
# update as a new app and its Screen Recording / camera permission no longer counts. With a
# certificate in LC_SIGN_P12 (base64 .p12) and LC_SIGN_P12_PASSWORD, every build keeps one identity.
if [ -n "${LC_SIGN_P12:-}" ]; then
  KC="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/livecore-sign.keychain-db"
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p livecore "$KC"
  security unlock-keychain -p livecore "$KC"
  echo "$LC_SIGN_P12" | base64 --decode > "$KC.p12"
  security import "$KC.p12" -k "$KC" -P "${LC_SIGN_P12_PASSWORD:-}" -T /usr/bin/codesign
  rm -f "$KC.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k livecore "$KC" >/dev/null
  IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/^ *1\)/{print $2; exit}')
  codesign --force --deep --options runtime --entitlements Config/LiveCoreStudio.entitlements \
    --keychain "$KC" --sign "$IDENTITY" "$APP"
  security delete-keychain "$KC"
  echo "signed with stable certificate $IDENTITY"
fi
scripts/check_app_loadable.sh "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" || true
# The NDI runtime is signed by NDI, so the hardened-runtime app must allow other signers' libraries.
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "disable-library-validation" \
  || { echo "ERROR: com.apple.security.cs.disable-library-validation is missing (NDI cannot load)"; exit 1; }
echo "entitlement: disable-library-validation"
echo "Built: $APP"
echo "Run:   open \"$APP\""
