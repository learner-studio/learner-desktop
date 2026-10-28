#!/bin/bash
# UI tests against the INSTALLED, running Learner Desktop: XCUITest clicks its menu-bar item
# and times the menu against a plain AppKit menu (UITests/Host). Not in the hooks: it moves
# the pointer, and macOS asks once to allow UI automation.
#   scripts/ui-test.sh
set -euo pipefail
cd "$(dirname "$0")/../UITests"
command -v xcodegen >/dev/null || { echo "needs XcodeGen: brew install xcodegen" >&2; exit 2; }
pgrep -f "Learner Desktop.app/Contents/MacOS/learner-desktop" >/dev/null || { echo "Learner Desktop is not running" >&2; exit 2; }
xcodegen generate --quiet
dd="${TMPDIR:-/tmp}/learner-uitests"
set +e
xcodebuild test -project LearnerUITests.xcodeproj -scheme UITestHost -destination 'platform=macOS' -derivedDataPath "$dd" > "$dd.log" 2>&1
rc=$?
set -e
grep -E "MENU-OPEN-MS|XCTAssert|error:|Test Suite 'All tests'" "$dd.log" || true
[ $rc -eq 0 ] && echo "ui tests passed" || echo "ui tests failed (log: $dd.log)"
exit $rc
