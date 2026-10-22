#!/usr/bin/env bash
#
# stop-capture.sh — clean shutdown of Learner Desktop + the screenpipe capture suite.
#
# Why this exists: every component is supervised, so `pkill` never works.
#   * com.benpollack.learner-desktop       KeepAlive on crash -> launchd respawns it; it
#                                          runs the SSH tunnel and the transcript watcher
#                                          as child processes and stops them on quit
#   * screenpipe (LaunchAgent, RunAtLoad)  -> restarts at next login
#   * screenpipe's Tauri ExitRequested handler calls api.prevent_exit(), so closing
#     its windows never quits the process.
#
# The only thing that actually stops a KeepAlive job is removing it from the launchd
# domain (`launchctl bootout`). `launchctl stop` just triggers a respawn.
#
# Data safety: Learner Desktop writes habit trial rows to
# ~/.ai-aggregator/behavior_experiments.sqlite and pushes them to Postgres over its
# autossh tunnel by spawning `bun run src/sync-habits.ts`. sync-habits.ts syncs at most
# 100 rows per invocation, so we loop until the unsynced count reaches zero, and we do
# it BEFORE stopping the app (it takes the tunnel down with it). The app's own
# shutdown then flushes anything written in between, before stopping its tunnel.
#
# Usage:
#   ./scripts/stop-capture.sh                  # stop everything for this boot
#   ./scripts/stop-capture.sh --persist        # ...and keep it off across reboot/login
#   ./scripts/stop-capture.sh --keep-screenpipe
#   ./scripts/stop-capture.sh --no-flush       # skip the habit sync (not recommended)
#
set -uo pipefail

PROJECT_DIR="/Users/benpollack/Documents/AI aggregator logger project"
HABIT_DB="${HOME}/.ai-aggregator/behavior_experiments.sqlite"
BUN_BIN="${HOME}/.bun/bin/bun"
DOMAIN="gui/$(id -u)"

AGENT_DIR="${HOME}/Library/LaunchAgents"
LABEL_APP="com.benpollack.learner-desktop"
LABEL_SCREENPIPE="screenpipe"

PERSIST=0
FLUSH=1
STOP_SCREENPIPE=1

for arg in "$@"; do
  case "$arg" in
    --persist)          PERSIST=1 ;;
    --no-flush)         FLUSH=0 ;;
    --keep-screenpipe)  STOP_SCREENPIPE=0 ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33m! %s\033[0m\n' "$*"; }

# "on" if screenpipe's API reports any active capture, "off" if it reports none,
# "unknown" if the API does not answer.
capture_state() {
  curl -s --max-time 3 http://127.0.0.1:3030/health 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("unknown")
    sys.exit()
audio = (d.get("capture_status") or {}).get("active_audio_devices") or 0
print("on" if audio > 0 or d.get("frame_status") == "ok" else "off")'
}

unsynced_count() {
  [ -f "$HABIT_DB" ] || { echo 0; return; }
  sqlite3 "$HABIT_DB" \
    "SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0;" 2>/dev/null || echo "?"
}

# bootout removes the job from the launchd domain. KeepAlive cannot resurrect a job
# that is no longer in the domain. Exit 3 = "No such process" (already gone) = fine.
stop_agent() {
  local label="$1"
  if launchctl print "${DOMAIN}/${label}" >/dev/null 2>&1; then
    launchctl bootout "${DOMAIN}/${label}" 2>/dev/null
    local rc=$?
    if [ $rc -eq 0 ] || [ $rc -eq 3 ]; then
      info "booted out ${label}"
    else
      warn "bootout ${label} returned ${rc}"
    fi
  else
    info "${label} not loaded"
  fi
  if [ "$PERSIST" -eq 1 ]; then
    # `disable` is persisted in /var/db/com.apple.xpc.launchd/disabled.<uid>.plist and
    # survives reboot, so launchd will NOT re-bootstrap the plist at next login.
    # start-capture.sh reverses this with `launchctl enable`.
    launchctl disable "${DOMAIN}/${label}" 2>/dev/null && info "disabled ${label} (persists across reboot)"
  fi
}

########################################################################
# 1. Flush pending habit rows to Postgres (tunnel and app still running)
########################################################################
if [ "$FLUSH" -eq 1 ]; then
  say "Flushing habit rows to Postgres"
  before="$(unsynced_count)"
  info "unsynced rows: ${before}"

  if [ "$before" = "0" ]; then
    info "nothing to flush"
  elif [ ! -x "$BUN_BIN" ]; then
    warn "bun not found at ${BUN_BIN} — cannot flush. Rows stay local until next start."
  else
    if ! nc -z 127.0.0.1 15432 >/dev/null 2>&1; then
      warn "Postgres tunnel (127.0.0.1:15432) is not up — flush will fail."
    fi
    # sync-habits.ts pushes at most 100 rows per run; loop until drained or stuck.
    for _ in $(seq 1 50); do
      remaining="$(unsynced_count)"
      [ "$remaining" = "0" ] && break
      ( cd "$PROJECT_DIR" && "$BUN_BIN" run src/sync-habits.ts ) 2>&1 | sed 's/^/    /'
      after="$(unsynced_count)"
      if [ "$after" = "$remaining" ]; then
        warn "no progress (still ${after} unsynced) — aborting flush loop"
        break
      fi
    done
    final="$(unsynced_count)"
    if [ "$final" = "0" ]; then
      info "all habit rows synced"
    else
      warn "${final} rows still unsynced — they are safe in ${HABIT_DB} and will sync on next start"
    fi
  fi
fi

########################################################################
# 2. Learner Desktop before screenpipe — it re-arms screenpipe audio every
#    8 seconds (updateAllStatuses -> ensureAudioDevicesActive ->
#    POST /audio/device/start). Its clean shutdown flushes late habit rows,
#    then stops its watcher and tunnel.
########################################################################
say "Stopping Learner Desktop"
stop_agent "$LABEL_APP"
# bootout returns before the app's clean shutdown is done, and that shutdown still
# needs its tunnel to flush habit rows. Wait for it, so what is killed below really
# is left over (launchd SIGKILLs a job that has not exited after 20s anyway).
for _ in $(seq 1 30); do
  pgrep -f "MacOS/learner-desktop" >/dev/null 2>&1 || break
  sleep 1
done
# Any stragglers (a hand-launched copy outside launchd) can now be killed for real.
pkill -f "MacOS/learner-desktop" 2>/dev/null && info "killed leftover learner-desktop process"
# A crashed or SIGKILLed app cannot stop its helpers; nothing else would.
pkill -f "learner-watcher.js" 2>/dev/null && info "killed leftover watcher process"
pkill -f "autossh.*18925" 2>/dev/null && info "killed leftover autossh process"

########################################################################
# 3. screenpipe — stop capture over the API; quit and escalate only if that fails
#    screenpipe installs NO SIGTERM handler, so a bare SIGTERM skips
#    process_exit::run_blocking_pre_exit_teardown and can leave the 6 GB
#    db.sqlite mid-write. Pause capture over the local API first. If that stops
#    it, leave the process be: with a capture session active, Quit pops "Quit
#    screenpipe? All recording will stop" and waits for a click, and since
#    2.7.116 it does not exit anyway (it stays up serving saved history). Only
#    when capture is still on, or the API cannot say, send a real quit
#    (routed through applicationShouldTerminate -> quit teardown).
########################################################################
if [ "$STOP_SCREENPIPE" -eq 1 ]; then
  say "Stopping screenpipe"

  if curl -s --max-time 2 http://127.0.0.1:3030/health >/dev/null 2>&1; then
    info "pausing capture via local API"
    curl -s --max-time 3 -X POST http://127.0.0.1:3030/audio/stop >/dev/null 2>&1 || true
    for mid in $(curl -s --max-time 3 http://127.0.0.1:3030/vision/list 2>/dev/null \
                 | grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$'); do
      curl -s --max-time 3 -X POST http://127.0.0.1:3030/vision/device/stop \
        -H 'Content-Type: application/json' -d "{\"monitor_id\": ${mid}}" >/dev/null 2>&1 || true
    done
    sleep 2
  else
    info "local API on :3030 not responding (screenpipe may already be down)"
  fi

  quit_sent=0
  if pgrep -f "screenpipe.app/Contents/MacOS/screenpipe-app" >/dev/null 2>&1; then
    if [ "$(capture_state)" = "off" ]; then
      info "capture stopped over the API; screenpipe stays up serving saved history (no Quit, so no dialog)"
      info "(./scripts/start-capture.sh resumes recording)"
    else
      info "sending quit (runs pre-exit teardown; confirm the dialog if one appears)"
      osascript -e 'tell application "screenpipe" to quit' >/dev/null 2>&1 || true
      quit_sent=1
      for _ in $(seq 1 30); do
        pgrep -f "screenpipe.app/Contents/MacOS/screenpipe-app" >/dev/null 2>&1 || break
        sleep 1
      done
    fi
  fi

  # Since 2.7.116 a Quit while the server runs does not exit: capture stops and the
  # process stays to serve saved history ("search-only"). That is stopped as far as
  # this script is concerned, so it is left alone. Signals are only for a quit that
  # did not take: capture still on, or an API that cannot say.
  if ! pgrep -f "screenpipe.app/Contents/MacOS/screenpipe-app" >/dev/null 2>&1; then
    info "screenpipe-app is stopped"
  elif [ "$quit_sent" -eq 1 ]; then
    state="$(capture_state)"
    if [ "$state" = "off" ]; then
      info "screenpipe stayed open in search-only mode: capture is off, it only serves saved history"
      info "(it exits at logout; opening it, or ./scripts/start-capture.sh, resumes recording)"
    else
      warn "still running after 30s with capture ${state} — escalating to SIGTERM"
      pkill -TERM -f "screenpipe.app/Contents/MacOS/screenpipe-app" 2>/dev/null
      sleep 5
      pkill -KILL -f "screenpipe.app/Contents/MacOS/screenpipe-app" 2>/dev/null && warn "SIGKILLed screenpipe-app"
    fi
  fi

  # The Tauri autostart plugin (tauri-plugin-autostart, MacosLauncher::LaunchAgent)
  # rewrites ~/Library/LaunchAgents/screenpipe.plist on every launch while
  # ~/.screenpipe/store.bin has "autoStartEnabled": true. Booting the job out only
  # helps for this boot; --persist adds the launchd disable that survives login.
  stop_agent "$LABEL_SCREENPIPE"

  # Sidecar CLI, if one was started outside the app bundle.
  pkill -f "${HOME}/.screenpipe/cli/.*/screenpipe" 2>/dev/null && info "killed screenpipe sidecar CLI"

  if [ "$PERSIST" -eq 0 ]; then
    warn "screenpipe will start again at next login (screenpipe.plist RunAtLoad=true)."
    warn "Re-run with --persist, or untick 'start on login' in screenpipe settings."
  fi
else
  say "Leaving screenpipe running (--keep-screenpipe)"
fi

########################################################################
# Report
########################################################################
say "Final state"
launchctl list | grep -E "learner-desktop|screenpipe" || info "no learner-desktop/screenpipe launchd jobs loaded"
info "unsynced habit rows: $(unsynced_count)"
echo
info "screenpipe-mcp node processes are MCP servers owned by Claude Desktop / Claude Code."
info "They hold no capture state; quit those clients if you want them gone."
echo
info "Restart everything with: ./scripts/start-capture.sh"
