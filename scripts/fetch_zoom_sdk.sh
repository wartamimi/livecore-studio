#!/usr/bin/env bash
# Fetch the Zoom Meeting SDK for macOS into ThirdParty/ZoomSDK (never committed; see .gitignore).
# The SDK lives as a release asset in a private repository; ZOOM_SDK_TOKEN must be able to read it.
# Without the token this does nothing and the app builds with the Zoom stub.
#   Usage: ZOOM_SDK_TOKEN=... scripts/fetch_zoom_sdk.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${ZOOM_SDK_REPO:-wartamimi/livecore-zoom-sdk}"
TAG="${ZOOM_SDK_TAG:-sdk-v1}"
ASSET="zoom-sdk-macos-7.2.1.88430.zip"
SHA256="95195e33bee4e49cf5e7eff5c0bf4cc76d58f669d089d5e6c4c43aef4f8b6b89"
DEST="ThirdParty/ZoomSDK"

if [ -z "${ZOOM_SDK_TOKEN:-}" ]; then
  echo "ZOOM_SDK_TOKEN not set: building without the Zoom Meeting SDK (stub)."
  exit 0
fi
if [ -d "$DEST/ZoomSDK.framework" ]; then
  echo "Zoom SDK already present in $DEST"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GH_TOKEN="$ZOOM_SDK_TOKEN"

ID="$(gh api "repos/$REPO/releases/tags/$TAG" --jq ".assets[] | select(.name == \"$ASSET\") | .id")"
[ -n "$ID" ] || { echo "ERROR: $ASSET not found in $REPO release $TAG"; exit 1; }
echo "== Downloading $ASSET"
gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$ID" > "$WORK/sdk.zip"

echo "$SHA256  $WORK/sdk.zip" | shasum -a 256 -c -
ditto -x -k "$WORK/sdk.zip" "$WORK/x"
SRC="$(find "$WORK/x" -maxdepth 3 -type d -name ZoomSDK.framework -path '*/ZoomSDK/*' | head -1)"
[ -n "$SRC" ] || { echo "ERROR: ZoomSDK.framework not found in archive"; exit 1; }
mkdir -p ThirdParty
rm -rf "$DEST"
mv "$(dirname "$SRC")" "$DEST"
echo "Zoom SDK ready: $DEST ($(du -sh "$DEST" | cut -f1))"
