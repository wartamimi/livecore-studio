#!/usr/bin/env bash
# CI helper (macOS): installs the NDI 6 runtime from NDI's redistributable link, so that
# livecore-ndi-check can send and receive NDI. LiveCore itself never ships the runtime.
#   Usage: scripts/install_ndi_runtime.sh
set -euo pipefail
URL="${NDI_REDIST_URL:-http://ndi.link/NDIRedistV6Apple}"
DIR="$(mktemp -d)"
echo "== Download $URL"
curl -fsSL --retry 3 -o "$DIR/ndi-redist" "$URL"
KIND="$(file -b "$DIR/ndi-redist")"
echo "downloaded: $KIND ($(wc -c < "$DIR/ndi-redist") bytes)"
case "$KIND" in
  *xar*)
    sudo installer -pkg "$DIR/ndi-redist" -target / ;;
  *zlib*|*bzip2*|*"Apple Disk"*|*data*)
    mv "$DIR/ndi-redist" "$DIR/ndi.dmg"
    hdiutil attach -nobrowse -readonly -mountpoint "$DIR/mnt" "$DIR/ndi.dmg"
    PKG="$(find "$DIR/mnt" -maxdepth 2 -name '*.pkg' | head -1)"
    [ -n "$PKG" ] || { echo "no .pkg in the disk image"; ls -la "$DIR/mnt"; exit 1; }
    sudo installer -pkg "$PKG" -target /
    hdiutil detach "$DIR/mnt" || true ;;
  *)
    echo "ERROR: unexpected download type"; exit 1 ;;
esac
echo "== Installed NDI libraries"
find /usr/local/lib /Library /opt -maxdepth 4 -name 'libndi*.dylib' 2>/dev/null || true
