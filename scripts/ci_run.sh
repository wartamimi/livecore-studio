#!/usr/bin/env bash
# CI helper: runs a command, keeps its output, and on failure posts the compiler/test errors
# as a commit comment (readable through the GitHub API even where log downloads are blocked).
#   Usage: scripts/ci_run.sh <label> <command...>
set -uo pipefail
LABEL="$1"; shift
mkdir -p build
LOG="build/ci-${LABEL}.log"
"$@" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ] && [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_SHA:-}" ]; then
  {
    echo "### CI step \`$LABEL\` failed (exit $rc) on $(sw_vers -productVersion 2>/dev/null || uname -s), $(xcodebuild -version 2>/dev/null | head -1)"
    echo '```'
    { grep -E "error:|error -|failed|XCTAssert|Fatal" "$LOG" | sort -u | head -150; } || true
    [ -f build/xcodebuild.log ] && grep -E "error:" build/xcodebuild.log | sort -u | head -150
    echo '--- last 40 lines ---'
    tail -n 40 "$LOG"
    echo '```'
  } > build/ci-comment.md
  gh api "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/comments" -F body=@build/ci-comment.md >/dev/null || true
fi
exit "$rc"
