#!/usr/bin/env bash
#
# start-capture.sh — bring Learner Desktop + the screenpipe capture suite back up.
# Exact reverse of scripts/stop-capture.sh.
#
# Order matters:
#   1. screenpipe — capture engine + local API on :3030
#   2. Learner Desktop — polls :3030 and flushes habit rows; start it last so it does
#      not spend its first 8s ticks reporting screenpipe down. It starts the SSH tunnel
#      (Postgres/Hindsight/GrowthBook forwards) and the transcript watcher itself.
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
  else
    warn "screenpipe API :3030 not responding after 60s — check ~/.screenpipe/screenpipe-app.*.log"
  fi
else
  say "Skipping screenpipe (--no-screenpipe)"
fi

say "Starting Learner Desktop (and its SSH tunnel and watcher)"
start_agent "$LABEL_APP" "com.benpollack.learner-desktop.plist"
for _ in $(seq 1 20); do
  nc -z 127.0.0.1 15432 >/dev/null 2>&1 && break
  sleep 1
done
if nc -z 127.0.0.1 15432 >/dev/null 2>&1; then
  info "Postgres forward :15432 is up"
else
  warn "Postgres forward :15432 did not come up — see ~/.ai-aggregator/logs/tunnel.log"
fi

say "Final state"
launchctl list | grep -E "learner-desktop|screenpipe" || warn "no learner-desktop/screenpipe launchd jobs loaded"
if [ -f "$HABIT_DB" ]; then
  info "unsynced habit rows: $(sqlite3 "$HABIT_DB" 'SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;' 2>/dev/null)"
  info "(Learner Desktop drains these automatically, 100 rows per 8s tick)"
fi
