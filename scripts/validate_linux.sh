#!/usr/bin/env bash
# Validation that runs without macOS: builds the portable targets, runs the unit tests and
# the RTMP end-to-end test against ffmpeg. macOS-only targets compile to empty modules here.
set -euo pipefail
cd "$(dirname "$0")/.."
swift --version
swift build
swift test 2>&1 | tee /tmp/livecore_unit_tests.log | grep -E "Executed|error" | tail -3
scripts/rtmp_e2e_test.sh
