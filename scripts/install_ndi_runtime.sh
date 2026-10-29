#!/usr/bin/env bash
# CI helper (macOS): installs the NDI 6 runtime from NDI's redistributable link, so that
# livecore-ndi-check can send and receive NDI. LiveCore itself never ships the runtime.
#   Usage: scripts/install_ndi_runtime.sh
set -euo pipefail
DIR="$(mktemp -d)"

install_file() {   # $1 = downloaded .pkg or .dmg
  local kind; kind="$(file -b "$1")"
  echo "downloaded: $kind ($(wc -c < "$1") bytes)"
  case "$kind" in
    *xar*) sudo installer -pkg "$1" -target / ;;
    *zlib*|*bzip2*|*"Apple Disk"*|*data*)
      hdiutil attach -nobrowse -readonly -mountpoint "$DIR/mnt" "$1"
      local pkg; pkg="$(find "$DIR/mnt" -maxdepth 2 -name '*.pkg' | head -1)"
      [ -n "$pkg" ] || { echo "no .pkg in the disk image"; ls -la "$DIR/mnt"; return 1; }
      sudo installer -pkg "$pkg" -target /
      hdiutil detach "$DIR/mnt" || true ;;
    *) echo "unexpected download type"; return 1 ;;
  esac
}

try_url() {
  echo "== Download $1"
  curl -fsSL --retry 3 --retry-delay 5 -o "$DIR/ndi-download" "$1" && install_file "$DIR/ndi-download"
}

# NDI's redistributable link first; its server sometimes answers 502, so fall back to the
# Homebrew cask and to the SDK installer (which also contains libndi.dylib).
try_url "${NDI_REDIST_URL:-http://ndi.link/NDIRedistV6Apple}" \
  || { echo "== brew install --cask libndi"; brew install --cask libndi; } \
  || try_url "https://downloads.ndi.tv/SDK/NDI_SDK_Mac/Install_NDI_SDK_v6_Apple.pkg" \
  || { echo "ERROR: could not install the NDI runtime"; exit 1; }

echo "== Installed NDI libraries"
find /usr/local/lib /opt/homebrew/lib "/Library/NDI SDK for Apple" -maxdepth 4 -name 'libndi*.dylib' 2>/dev/null || true
