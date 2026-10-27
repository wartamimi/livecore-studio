#!/usr/bin/env bash
# Compiles the embedded Metal shader source offline with the Metal compiler, so shader syntax or
# type errors fail CI instead of surfacing only at app launch (the app compiles it at runtime).
#   Usage: scripts/check_shaders.sh        (macOS with Xcode)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/shaders"
mkdir -p "$OUT"
# The source is the Swift multi-line string literal: after `= """`, up to the line that is just """.
awk '/= """[[:space:]]*$/{on=1; next} on && /^[[:space:]]*"""[[:space:]]*$/{exit} on{print}' Sources/LiveCoreEngine/Render/Shaders.swift \
  | sed 's/^    //' > "$OUT/LiveCoreShaders.metal"
[ -s "$OUT/LiveCoreShaders.metal" ] || { echo "could not extract shader source"; exit 1; }
xcrun -sdk macosx metal -c "$OUT/LiveCoreShaders.metal" -o "$OUT/LiveCoreShaders.air"
echo "Metal shaders compile: OK"
for fn in quad_vertex layer_fragment key_fragment transition_fragment wipe_mask; do
  grep -q "$fn" "$OUT/LiveCoreShaders.metal" || { echo "missing function $fn"; exit 1; }
done
