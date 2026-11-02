#!/usr/bin/env bash
# Fails when an app bundle would be refused by dyld at launch:
#   * an @rpath framework the executable links is not embedded;
#   * the app is ad-hoc signed (no Team ID) with the hardened runtime and embeds any framework or
#     dylib: library validation rejects every non-system library without the app's Team ID, and an
#     ad-hoc signature has none (0.13.0/0.13.1 crashed at launch this way with Lottie.framework).
#   Usage: scripts/check_app_loadable.sh path/to/LiveCoreStudio.app
set -euo pipefail
APP="$1"
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
for fw in $(otool -L "$EXE" | awk '/@rpath\//{print $1}' | sed -E 's#@rpath/([^/]+).*#\1#' | sort -u); do
  [ -e "$APP/Contents/Frameworks/$fw" ] || { echo "ERROR: $fw is linked but not embedded in the app"; exit 1; }
done
INFO=$(codesign -dvvv "$APP" 2>&1 || true)
TEAM=$(printf '%s\n' "$INFO" | sed -n 's/^TeamIdentifier=//p')
if printf '%s\n' "$INFO" | grep -q "flags=.*runtime" && { [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; }; then
  EMBEDDED=$(find "$APP/Contents" \( -name "*.framework" -o -name "*.dylib" \) -not -path "*/Resources/*" 2>/dev/null || true)
  if [ -n "$EMBEDDED" ]; then
    echo "ERROR: ad-hoc signed app with hardened runtime embeds libraries that dyld will refuse:"
    echo "$EMBEDDED"
    exit 1
  fi
fi
echo "App is loadable: $APP"
