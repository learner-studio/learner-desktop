#!/usr/bin/env bash
#
# uninstall-app.sh -- the reverse of build-app.sh's install: stops the app, removes its
# LaunchAgent, ~/Applications/Learner Desktop.app and the automatic updater (which would
# otherwise reinstall it), then checks that nothing is left running or registered. Exits 1
# and names every leftover.
#
#   PURGE_DATA=1   also deletes the app's data (~/.ai-aggregator) and its saved settings
#                  (UserDefaults). For CI runners only: on the owner's Mac that is the
#                  coaching history and the experiment ledger.
#
set -uo pipefail

APP="${HOME}/Applications/Learner Desktop.app"
LABEL="com.benpollack.learner-desktop"
AGENT="${HOME}/Library/LaunchAgents/${LABEL}.plist"
BUNDLE_ID="com.benpollack.ai-aggregator-menubar"
DOMAIN="gui/$(id -u)"
EXE_PATTERN="Learner Desktop.app/Contents/MacOS/learner-desktop"
UPDATER_LABEL="com.benpollack.learner-desktop-updater"
UPDATER_AGENT="${HOME}/Library/LaunchAgents/${UPDATER_LABEL}.plist"
UPDATER_DIR="${HOME}/Library/Application Support/Learner Desktop/updater"

echo "Stopping the automatic updater..."
launchctl bootout "${DOMAIN}/${UPDATER_LABEL}" 2>/dev/null || true
rm -f "${UPDATER_AGENT}"
rm -rf "${UPDATER_DIR}"

echo "Stopping Learner Desktop..."
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
for _ in $(seq 1 30); do
  launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || break
  sleep 0.5
done
# A copy started by hand (open, a test) is not launchd's: SIGTERM is the app's clean quit.
if pgrep -f "${EXE_PATTERN}" >/dev/null; then
  pkill -TERM -f "${EXE_PATTERN}" || true
  for _ in $(seq 1 20); do pgrep -f "${EXE_PATTERN}" >/dev/null || break; sleep 0.5; done
fi

echo "Removing the app and its LaunchAgent..."
rm -rf "${APP}"
rm -f "${AGENT}"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -u "${APP}" >/dev/null 2>&1 || true

if [ "${PURGE_DATA:-0}" = 1 ]; then
  echo "PURGE_DATA=1: removing ~/.ai-aggregator and the app's saved settings..."
  rm -rf "${HOME}/.ai-aggregator"
  defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
fi

leftovers=()
pgrep -f "${EXE_PATTERN}" >/dev/null && leftovers+=("a learner-desktop process is still running (pid $(pgrep -f "${EXE_PATTERN}" | tr '\n' ' '))")
launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 && leftovers+=("launchd still has ${DOMAIN}/${LABEL}")
[ -e "${APP}" ] && leftovers+=("${APP} still exists")
[ -e "${AGENT}" ] && leftovers+=("${AGENT} still exists")
launchctl print "${DOMAIN}/${UPDATER_LABEL}" >/dev/null 2>&1 && leftovers+=("launchd still has ${DOMAIN}/${UPDATER_LABEL}")
[ -e "${UPDATER_AGENT}" ] && leftovers+=("${UPDATER_AGENT} still exists")
if [ "${PURGE_DATA:-0}" = 1 ]; then
  [ -e "${HOME}/.ai-aggregator" ] && leftovers+=("${HOME}/.ai-aggregator still exists")
  defaults read "${BUNDLE_ID}" >/dev/null 2>&1 && leftovers+=("UserDefaults for ${BUNDLE_ID} still exist")
fi

if [ ${#leftovers[@]} -gt 0 ]; then
  echo "UNINSTALL INCOMPLETE:" >&2
  printf '  - %s\n' "${leftovers[@]}" >&2
  exit 1
fi
echo "Uninstalled: no process, no launchd job, no app, no LaunchAgent$([ "${PURGE_DATA:-0}" = 1 ] && echo ", no data")."
