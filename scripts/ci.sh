#!/usr/bin/env bash
#
# ci.sh -- the whole app on a clean Mac (a GitHub macOS runner), loudly:
#
#   fetch          Voice ID's model and sherpa-onnx (scripts/fetch-voice-id.sh)
#   virtual-mic    two BlackHole loopback devices; "BlackHole 2ch" becomes the default input
#   grant          microphone + speech-recognition grants for the app's bundle id (TCC.db)
#   install        release build, installed and started by scripts/build-app.sh
#   mic-e2e        speech played into the virtual mic is heard by the installed app; the
#                  default input is switched and the app follows it and hears again
#   light/medium/heavy   scripts/test.sh, with LEARNER_CI=1 (owner-only suites skip, by name)
#   uninstall      scripts/uninstall-app.sh with PURGE_DATA=1: nothing may be left behind
#
# Every phase runs even when an earlier one failed, so one run reports everything. The
# summary names each phase PASS/FAIL and every skipped test with its reason; it goes to
# stdout and, on GitHub, to the run's summary page. Exit 1 when any phase failed.
#
# Only for a throwaway machine: it installs audio drivers, writes TCC.db, and deletes
# ~/.ai-aggregator at the end. It refuses to run without CI=true.
#
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ "${CI:-}" != "true" ]; then
  echo "ci.sh is for CI runners only (it writes TCC.db and deletes ~/.ai-aggregator); set CI=true on a throwaway Mac" >&2
  exit 2
fi
export LEARNER_CI=1

OUT="${CI_OUT:-$PWD/ci-out}"
mkdir -p "$OUT"
APP_LOG="$HOME/.ai-aggregator/logs/menubar.log"
BUNDLE_ID="com.benpollack.ai-aggregator-menubar"
MIC_A="BlackHole 2ch"
MIC_B="BlackHole 16ch"

results=()   # "PASS|FAIL<TAB>phase<TAB>seconds<TAB>note"
failed=0

banner() { printf '\n\033[1;36m######## %s ########\033[0m\n' "$*"; }

# phase NAME COMMAND...: runs it, output to the console and $OUT/NAME.log, records the verdict.
phase() {
  local name="$1"; shift
  banner "$name"
  local start=$SECONDS
  "$@" 2>&1 | tee "$OUT/$name.log"
  local status=${PIPESTATUS[0]}
  local took=$((SECONDS - start))
  if [ "$status" -eq 0 ]; then
    results+=("PASS	$name	$took	")
  else
    results+=("FAIL	$name	$took	exit $status")
    failed=1
    echo "::error title=CI phase failed::$name failed (exit $status); see $name.log"
  fi
}

# wait_log PATTERN SECONDS FROM_LINE: the app's log, from line FROM_LINE on, matches PATTERN.
wait_log() {
  local pattern="$1" timeout="$2" from="$3" until=$((SECONDS + $2))
  while [ $SECONDS -lt $until ]; do
    if [ -f "$APP_LOG" ] && tail -n +"$from" "$APP_LOG" | grep -qE "$pattern"; then
      tail -n +"$from" "$APP_LOG" | grep -E "$pattern" | head -1 | sed 's/^/  log: /'
      return 0
    fi
    sleep 1
  done
  echo "  no log line matching /$pattern/ within ${timeout}s; the log since then:"
  [ -f "$APP_LOG" ] && tail -n +"$from" "$APP_LOG" | tail -40 | sed 's/^/  | /'
  return 1
}

log_lines() { [ -f "$APP_LOG" ] && wc -l < "$APP_LOG" | tr -d ' ' || echo 0; }

# ---- phases ---------------------------------------------------------------------------

fetch() { scripts/fetch-voice-id.sh; }

virtual_mic() {
  set -e
  command -v SwitchAudioSource >/dev/null || brew install switchaudio-osx
  # BlackHole is a CoreAudio driver (a HAL plug-in): coreaudiod loads it on restart.
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask blackhole-2ch blackhole-16ch
  sudo killall coreaudiod || true
  local until=$((SECONDS + 30))
  until SwitchAudioSource -a -t input | grep -qx "$MIC_B" && SwitchAudioSource -a -t input | grep -qx "$MIC_A"; do
    [ $SECONDS -lt $until ] || { echo "BlackHole devices did not appear:"; SwitchAudioSource -a -t input; return 1; }
    sleep 1
  done
  SwitchAudioSource -t input -s "$MIC_A"
  echo "inputs:"; SwitchAudioSource -a -t input | sed 's/^/  /'
  echo "default input: $(SwitchAudioSource -c -t input)"
  [ "$(SwitchAudioSource -c -t input)" = "$MIC_A" ]
}

grant() {
  # The runner image writes TCC.db for its own tools the same way (actions/runner-images,
  # configure-tccdb-macos.sh). Microphone and speech recognition live in the user's database.
  local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db" now
  now=$(date +%s)
  for service in kTCCServiceMicrophone kTCCServiceSpeechRecognition; do
    sqlite3 "$db" "INSERT OR REPLACE INTO access VALUES('$service','$BUNDLE_ID',0,2,3,1,NULL,NULL,NULL,'UNUSED',NULL,0,$now,NULL,NULL,'UNUSED',$now);" || return 1
  done
  echo "granted in the user TCC.db:"
  sqlite3 "$db" "SELECT service, client, auth_value FROM access WHERE client='$BUNDLE_ID';" | sed 's/^/  /'
  [ "$(sqlite3 "$db" "SELECT count(*) FROM access WHERE client='$BUNDLE_ID' AND auth_value=2;")" = 2 ]
}

install() {
  set -e
  swift build -c release --product LearnerDesktop
  LEARNER_BINARY="$PWD/.build/release/LearnerDesktop" scripts/build-app.sh
  local until=$((SECONDS + 30))
  until pgrep -f "Learner Desktop.app/Contents/MacOS/learner-desktop" >/dev/null; do
    [ $SECONDS -lt $until ] || { echo "the installed app is not running 30 s after install"; launchctl print "gui/$(id -u)/com.benpollack.learner-desktop" | head -30; return 1; }
    sleep 1
  done
  echo "running: pid $(pgrep -f "Learner Desktop.app/Contents/MacOS/learner-desktop")"
}

# say TEXT into a device: BlackHole loops its output back to its input.
speak_into() { say -a "$1" "I would like to explain the plan for our next project in a little more detail. The first step is to understand what people need from the product and what gets in their way today."; }

mic_e2e() {
  local from ok=0
  from=1
  echo "1. the app listens on the default input ($MIC_A)"
  # The app names the input by its format; BlackHole 2ch and 16ch differ in channel count.
  wait_log "listening on .* 2-channel input" 90 "$from" || ok=1
  from=$(log_lines)
  echo "2. speech played into $MIC_A is heard"
  speak_into "$MIC_A"
  wait_log "\[Coach\] heard " 30 "$from" || ok=1
  from=$(log_lines)
  echo "3. the default input switches to $MIC_B; the app reopens the microphone on it"
  SwitchAudioSource -t input -s "$MIC_B"
  wait_log "the audio input changed; restarting the microphone" 30 "$from" || ok=1
  wait_log "listening on .* 16-channel input" 30 "$from" || ok=1
  from=$(log_lines)
  echo "4. speech played into $MIC_B is heard"
  sleep 15   # the previous turn ends after 14 s of silence, so this one is a new turn
  speak_into "$MIC_B"
  wait_log "\[Coach\] heard " 30 "$from" || ok=1
  SwitchAudioSource -t input -s "$MIC_A" >/dev/null
  return $ok
}

lane() { scripts/test.sh "$1"; }

uninstall() { PURGE_DATA=1 scripts/uninstall-app.sh; }

# ---- run --------------------------------------------------------------------------------

phase fetch fetch
phase virtual-mic virtual_mic
phase grant grant
phase install install
phase mic-e2e mic_e2e
phase light lane light
phase medium lane medium
phase heavy lane heavy
[ -f "$APP_LOG" ] && cp "$APP_LOG" "$OUT/menubar.log"
phase uninstall uninstall

# ---- report -----------------------------------------------------------------------------

# Swift Testing names every skip and cancellation: `➜ Test x() skipped: "why"`.
skips="$(cat "$OUT"/light.log "$OUT"/medium.log "$OUT"/heavy.log 2>/dev/null \
  | grep -E '^➜ (Test|Suite) .* (skipped|was cancelled)' | sed -E 's/^➜ //' | sort -u)"
nskips=$( [ -n "$skips" ] && wc -l <<< "$skips" | tr -d ' ' || echo 0)

report() {
  echo "## Learner Desktop CI: $([ $failed -eq 0 ] && echo '✅ PASSED' || echo '❌ FAILED')"
  echo
  echo "| | phase | time | note |"
  echo "|---|---|---|---|"
  for r in "${results[@]}"; do
    IFS=$'\t' read -r verdict name took note <<< "$r"
    echo "| $([ "$verdict" = PASS ] && echo ✅ || echo ❌) $verdict | $name | ${took}s | $note |"
  done
  echo
  echo "### $nskips test(s) skipped, not passed"
  if [ "$nskips" -gt 0 ]; then
    echo
    echo '```'
    echo "$skips"
    echo '```'
  fi
}

banner "SUMMARY"
report | tee "$OUT/summary.md"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && report >> "$GITHUB_STEP_SUMMARY"
if [ $failed -ne 0 ]; then
  printf '\n\033[1;31m!!!!!!!! CI FAILED: %s !!!!!!!!\033[0m\n' "$(printf '%s\n' "${results[@]}" | awk -F'\t' '$1=="FAIL"{print $2}' | paste -sd, -)"
  exit 1
fi
printf '\n\033[1;32m======== CI PASSED (%s skipped) ========\033[0m\n' "$nskips"
