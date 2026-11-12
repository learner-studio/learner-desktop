#!/usr/bin/env bash
#
# auto-update.sh -- installs main's newest CI-tested build on the owner's Mac. One
# implementation for two callers:
#
#   the updater LaunchAgent (scripts/install-updater.sh), every 5 minutes:
#       installs a newer green build of main, but never during a call (the coach's saved
#       session names a call app); waits for the call to end. Logs to
#       ~/.ai-aggregator/logs/updater.log and posts a notification when it installs or fails.
#   scripts/install-latest.sh (by hand, or an agent asked to):  --manual
#       the same install, printed to the terminal, without waiting for a call to end.
#
# The build is the exact bundle CI installed and tested ("learner-desktop-app" artifact of
# a push run on main that passed every phase). It ships its own install kit (build-app.sh
# and the LaunchAgent), so what installs it always matches what was tested; this script
# also updates itself from that kit. build-app.sh re-signs the bundle with this Mac's
# Apple Development identity, so macOS keeps the app's grants.
#
#   RUN_ID=<id>   that run instead of the newest (it must have passed)
#   FORCE=1       reinstall even if that commit is already installed
#   paused:       touch "$UPDATER_DIR/PAUSED" stops the LaunchAgent's runs (not --manual)
#
set -uo pipefail

REPO="learner-studio/learner-desktop"
BUNDLE_ID="com.benpollack.ai-aggregator-menubar"
UPDATER_DIR="${HOME}/Library/Application Support/Learner Desktop/updater"
STAMP="${HOME}/.ai-aggregator/installed-build.txt"
LOG="${HOME}/.ai-aggregator/logs/updater.log"
EXE_PATTERN="Learner Desktop.app/Contents/MacOS/learner-desktop"

manual=0
[ "${1:-}" = "--manual" ] && manual=1

say() {   # to the terminal when manual, to the log always
  local line; line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  mkdir -p "$(dirname "$LOG")"
  echo "$line" >> "$LOG"
  [ $manual = 1 ] && echo "$*"
  return 0
}
notify() { osascript -e "display notification \"$2\" with title \"Learner Desktop\" subtitle \"$1\"" >/dev/null 2>&1 || true; }
fail() { say "FAILED: $*"; [ $manual = 1 ] || notify "Update failed" "$*"; exit 1; }

if [ $manual = 0 ] && [ -e "$UPDATER_DIR/PAUSED" ]; then exit 0; fi

# One run at a time (a slow download can outlast the 5-minute interval).
lock="${TMPDIR:-/tmp}/learner-auto-update.lock"
if ! mkdir "$lock" 2>/dev/null; then
  # A lock older than 30 minutes is a crashed run's.
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rm -rf "$lock"; mkdir "$lock" || exit 0; else
    [ $manual = 1 ] && echo "another update is running"; exit 0; fi
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/learner-update.XXXXXX")"
trap 'rm -rf "$work" "$lock"' EXIT

command -v gh >/dev/null || fail "gh is not installed"

# The run to install.
if [ -n "${RUN_ID:-}" ]; then
  read -r run sha conclusion < <(gh run view "$RUN_ID" -R "$REPO" --json databaseId,headSha,conclusion \
    -q '"\(.databaseId) \(.headSha) \(.conclusion)"' 2>>"$LOG") || fail "cannot read CI run $RUN_ID"
  [ "${conclusion:-}" = success ] || fail "CI run $RUN_ID did not pass (${conclusion:-no conclusion}); not installing it"
else
  read -r run sha < <(gh run list -R "$REPO" --workflow ci.yml --branch main --event push --status success -L 1 \
    --json databaseId,headSha -q '.[0] | "\(.databaseId) \(.headSha)"' 2>>"$LOG") \
    || { [ $manual = 1 ] && fail "cannot reach GitHub"; say "cannot reach GitHub; trying again next time"; exit 0; }
  [ -n "${run:-}" ] || fail "no passing CI run on main yet"
fi

installed="$(sed -n 's/^commit //p' "$STAMP" 2>/dev/null)"
if [ "${FORCE:-0}" != 1 ] && [ "$installed" = "$sha" ]; then
  [ $manual = 1 ] && echo "commit ${sha:0:7} (CI run $run) is already installed; FORCE=1 reinstalls"
  exit 0
fi

# Never restart the app in the middle of a call: wait for it to end.
if [ $manual = 0 ]; then
  call="$(defaults export "$BUNDLE_ID" - 2>/dev/null | plutil -extract coach_session.app raw - 2>/dev/null || true)"
  if [ -n "$call" ]; then
    deferred="$UPDATER_DIR/deferred-$sha"
    [ -e "$deferred" ] || { say "commit ${sha:0:7} is ready; waiting for the call ($call) to end"; mkdir -p "$UPDATER_DIR"; : > "$deferred"; }
    exit 0
  fi
  rm -f "$UPDATER_DIR"/deferred-* 2>/dev/null
fi

say "installing commit ${sha:0:7} from CI run $run (installed: ${installed:0:7})"
gh run download "$run" -R "$REPO" -n learner-desktop-app -D "$work/artifact" >>"$LOG" 2>&1 \
  || fail "cannot download the tested app of CI run $run"
grep -qx "commit ${sha}" "$work/artifact/BUILD.txt" 2>/dev/null \
  || fail "the artifact of CI run $run does not name commit ${sha:0:7}"
ditto -x -k "$work/artifact/Learner-Desktop.zip" "$work/unpacked" || fail "cannot unpack the tested app"
kit="$work/artifact/kit"
[ -x "$kit/scripts/build-app.sh" ] || fail "the artifact of CI run $run has no install kit"

if [ $manual = 1 ]; then
  LEARNER_APP_BUNDLE="$work/unpacked/Learner Desktop.app" OUT_DIR="$work/bundle" "$kit/scripts/build-app.sh" 2>&1 | tee -a "$LOG"
  status=${PIPESTATUS[0]}
else
  LEARNER_APP_BUNDLE="$work/unpacked/Learner Desktop.app" OUT_DIR="$work/bundle" "$kit/scripts/build-app.sh" >>"$LOG" 2>&1
  status=$?
fi
[ "$status" -eq 0 ] || fail "build-app.sh could not install commit ${sha:0:7} (exit $status; see $LOG)"

# It must come up.
for _ in $(seq 1 30); do pgrep -f "$EXE_PATTERN" >/dev/null && break; sleep 1; done
pgrep -f "$EXE_PATTERN" >/dev/null || fail "commit ${sha:0:7} was installed but the app is not running"

mkdir -p "$(dirname "$STAMP")"
{ cat "$work/artifact/BUILD.txt"; echo "installed $(date -u +%FT%TZ)"; } > "$STAMP"
title="$(gh api "repos/$REPO/commits/$sha" -q '.commit.message | split("\n")[0]' 2>/dev/null | cut -c1-90)"
say "installed commit ${sha:0:7}${title:+: $title}"
[ $manual = 1 ] || notify "Updated to ${sha:0:7}" "${title:-a new build of main}"

# Keep the updater itself current from the kit (a rename, so this running copy is untouched).
if [ -f "$UPDATER_DIR/auto-update.sh" ] && [ -f "$kit/scripts/auto-update.sh" ] \
   && ! cmp -s "$kit/scripts/auto-update.sh" "$UPDATER_DIR/auto-update.sh"; then
  cp "$kit/scripts/auto-update.sh" "$UPDATER_DIR/auto-update.sh.new" && chmod +x "$UPDATER_DIR/auto-update.sh.new" \
    && mv "$UPDATER_DIR/auto-update.sh.new" "$UPDATER_DIR/auto-update.sh" && say "updater updated from commit ${sha:0:7}"
fi
exit 0
