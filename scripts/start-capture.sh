#!/usr/bin/env bash
#
# start-capture.sh — bring Learner Desktop + the screenpipe capture suite back up.
# Exact reverse of scripts/stop-capture.sh.
#
# Order matters:
#   1. screenpipe — capture engine + local API on :3030
#   2. Learner Desktop — polls :3030 and flushes habit rows; start it last so it does
#      not spend its first 8s ticks reporting screenpipe down. It starts the SSH tunnel
#      (GrowthBook forward) and the transcript watcher itself.
#
# `launchctl enable` undoes the persistent `launchctl disable` that
# stop-capture.sh --persist applies; without it, bootstrap silently refuses.
#
# Usage:
#   ./scripts/start-capture.sh
#   ./scripts/start-capture.sh --no-screenpipe
#
set -uo pipefail

DOMAIN="gui/$(id -u)"
AGENT_DIR="${HOME}/Library/LaunchAgents"
HABIT_DB="${HOME}/.ai-aggregator/behavior_experiments.sqlite"

LABEL_APP="com.benpollack.learner-desktop"
LABEL_SCREENPIPE="screenpipe"

START_SCREENPIPE=1
for arg in "$@"; do
  case "$arg" in
    --no-screenpipe) START_SCREENPIPE=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# "on" if screenpipe's API reports any active capture, "off" if it reports none,
# "unknown" if the API does not answer. (Same check as stop-capture.sh.)
capture_state() {
  local health audio frames
  health="$(curl -s --max-time 3 http://127.0.0.1:3030/health 2>/dev/null)"
  if ! printf '%s' "$health" | plutil -convert json -o /dev/null - 2>/dev/null; then echo unknown; return; fi
  audio="$(printf '%s' "$health" | plutil -extract capture_status.active_audio_devices raw -o - - 2>/dev/null)"
  frames="$(printf '%s' "$health" | plutil -extract frame_status raw -o - - 2>/dev/null)"
  if [ "${audio:-0}" -gt 0 ] 2>/dev/null || [ "$frames" = ok ]; then echo on; else echo off; fi
}

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }

start_agent() {
  local label="$1" plist="${AGENT_DIR}/$2"
  if [ ! -f "$plist" ]; then
    warn "missing plist: ${plist}"
    return 1
  fi
  launchctl enable "${DOMAIN}/${label}" 2>/dev/null
  if launchctl print "${DOMAIN}/${label}" >/dev/null 2>&1; then
    launchctl kickstart -k "${DOMAIN}/${label}" >/dev/null 2>&1 && info "restarted ${label}"
  else
    if launchctl bootstrap "$DOMAIN" "$plist" 2>/dev/null; then
      info "bootstrapped ${label}"
    else
      warn "bootstrap ${label} failed — check ${plist}"
      return 1
    fi
  fi
}

if [ "$START_SCREENPIPE" -eq 1 ]; then
  say "Starting screenpipe"
  launchctl enable "${DOMAIN}/${LABEL_SCREENPIPE}" 2>/dev/null
  if pgrep -f "screenpipe.app/Contents/MacOS/screenpipe-app" >/dev/null 2>&1; then
    # stop-capture.sh leaves 2.7.116+ running in search-only mode (capture off);
    # reopening it is screenpipe's own way to resume recording.
    info "screenpipe-app already running — reopening it to resume capture"
    open -g -a /Applications/screenpipe.app || warn "could not reopen screenpipe.app"
  elif [ -f "${AGENT_DIR}/screenpipe.plist" ] && launchctl bootstrap "$DOMAIN" "${AGENT_DIR}/screenpipe.plist" 2>/dev/null; then
    info "bootstrapped screenpipe LaunchAgent (RunAtLoad starts it)"
  else
    info "launching /Applications/screenpipe.app directly"
    open -g -a /Applications/screenpipe.app || warn "could not open screenpipe.app"
  fi
  for _ in $(seq 1 60); do
    curl -s --max-time 2 http://127.0.0.1:3030/health >/dev/null 2>&1 && break
    sleep 1
  done
  if curl -s --max-time 2 http://127.0.0.1:3030/health >/dev/null 2>&1; then
    info "screenpipe API :3030 is up"
    # Reopening only leaves search-only mode. Capture that stop-capture.sh paused over
    # the API (without quitting, to avoid the "Quit screenpipe?" dialog) has to be
    # started over the API again.
    sleep 3
    if [ "$(capture_state)" = "off" ]; then
      info "capture is paused — resuming it over the local API"
      curl -s --max-time 5 -X POST http://127.0.0.1:3030/audio/start >/dev/null 2>&1 || true
      for mid in $(curl -s --max-time 3 http://127.0.0.1:3030/vision/list 2>/dev/null \
                   | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$'); do
        curl -s --max-time 5 -X POST http://127.0.0.1:3030/vision/device/start \
          -H 'Content-Type: application/json' -d "{\"monitor_id\": ${mid}}" >/dev/null 2>&1 || true
      done
    fi
  else
    warn "screenpipe API :3030 not responding after 60s — check ~/.screenpipe/screenpipe-app.*.log"
  fi
else
  say "Skipping screenpipe (--no-screenpipe)"
fi

say "Starting Learner Desktop (and its SSH tunnel and watcher)"
start_agent "$LABEL_APP" "com.benpollack.learner-desktop.plist"
if curl -s --max-time 5 https://dev.biztoolz.app/learner-api/api/health >/dev/null 2>&1; then
  info "learner-server API is reachable (queued rows will send)"
else
  warn "learner-server API not reachable — rows queue locally until it is"
fi

say "Final state"
launchctl list | grep -E "learner-desktop|screenpipe" || warn "no learner-desktop/screenpipe launchd jobs loaded"
if [ -f "$HABIT_DB" ]; then
  info "unsynced habit rows: $(sqlite3 "$HABIT_DB" 'SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;' 2>/dev/null)"
  info "(Learner Desktop drains these automatically, 100 rows per 8s tick)"
fi
