#!/usr/bin/env bash
#
# ci.sh -- the whole app on a clean Mac (a GitHub macOS runner), loudly:
#
#   fetch          Voice ID's model and sherpa-onnx (scripts/fetch-voice-id.sh)
#   virtual-mic    two BlackHole loopback devices; "BlackHole 2ch" becomes the default input
#   grant          microphone + speech-recognition grants for the app's bundle id (TCC.db)
#   fixtures       the synthetic sample (Tests/Fixtures/sample) as ~/ai-vault-data + its ledger
#   speech         Siri and Dictation on, which Apple's speech recognizer needs
#   install        release build, installed and started by scripts/build-app.sh
#   mic-e2e        speech played into the virtual mic is heard by the installed app; the
#                  default input is switched and the app follows it and hears again
#   light/medium/heavy   scripts/test.sh, with LEARNER_TEST_ENV=runner (owner-only suites skip, by name)
#   updater        scripts/install-updater.sh: the automatic updater's LaunchAgent loads
#   uninstall      scripts/uninstall-app.sh with PURGE_DATA=1: nothing may be left behind,
#                  the updater included
#
# Usage: scripts/ci.sh PHASE   one phase (the workflow runs each as its own step, so the
#                              Actions page shows them pass or fail live); exit = its verdict
#        scripts/ci.sh report  the PASS/FAIL table and every skipped test with its reason, to
#                              stdout and the run's summary page; exit 1 if any phase failed
#        scripts/ci.sh all     every phase, then the report
#
# Every phase runs even when an earlier one failed, so one run reports everything. Verdicts
# collect in $OUT/results.tsv across steps. The test lanes run with LEARNER_TEST_ENV=runner:
# every lane prints which environment it is in, and suites that need the owner's live
# machine say so when they skip.
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
export LEARNER_TEST_ENV=runner

OUT="${CI_OUT:-$PWD/ci-out}"
mkdir -p "$OUT"
APP_LOG="$HOME/.ai-aggregator/logs/menubar.log"
BUNDLE_ID="com.benpollack.ai-aggregator-menubar"
MIC_A="BlackHole 2ch"
MIC_B="BlackHole 16ch"

RESULTS="$OUT/results.tsv"   # PASS|FAIL <TAB> phase <TAB> seconds <TAB> note

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
    printf 'PASS\t%s\t%s\t\n' "$name" "$took" >> "$RESULTS"
  else
    printf 'FAIL\t%s\t%s\texit %s\n' "$name" "$took" "$status" >> "$RESULTS"
    echo "::error title=CI phase failed::$name failed (exit $status); see $name.log"
  fi
  return "$status"
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
  command -v SwitchAudioSource >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install switchaudio-osx
  command -v sox >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install sox   # diagnose_input
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

# The synthetic sample (Tests/Fixtures/sample) where the owner's real data lives, so the
# heavy lane's export and ledger suites run on the runner as they do on the owner's Mac.
fixtures() {
  set -e
  local sample="$PWD/Tests/Fixtures/sample"
  rm -rf "$HOME/ai-vault-data"
  cp -R "$sample/ai-vault-data" "$HOME/ai-vault-data"
  mkdir -p "$HOME/.ai-aggregator"
  rm -f "$HOME/.ai-aggregator/sync-ledger.sqlite"
  sed "s#@HOME@#$HOME#g" "$sample/sync-ledger.sql" | sqlite3 "$HOME/.ai-aggregator/sync-ledger.sqlite"
  echo "installed $(find "$HOME/ai-vault-data" -name conversation.md | wc -l | tr -d ' ') synthetic conversations into ~/ai-vault-data"
  echo "ledger: $(sqlite3 "$HOME/.ai-aggregator/sync-ledger.sqlite" "select sync_status || ' ' || count(*) from archive_ledger group by sync_status;" | paste -sd, -)"
}

speech() {
  # Apple's speech recognizer refuses with "Siri and Dictation are disabled" until one of
  # them is on; the owner's Mac has Siri on ("Assistant Enabled"). Both, for the runner.
  defaults write com.apple.assistant.support "Assistant Enabled" -bool true
  defaults write com.apple.assistant.support "Dictation Enabled" -bool true
  killall assistantd corespeechd 2>/dev/null || true   # they reread the settings on relaunch
  defaults read com.apple.assistant.support | grep -E '"(Assistant|Dictation) Enabled"' | sed 's/^ */  /'
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
  # The exact bundle under test, kept for scripts/install-latest.sh on the owner's Mac
  # (uploaded only when every phase passes).
  mkdir -p "$PWD/ci-app"
  ditto -c -k --keepParent "menu-bar-app/Learner Desktop.app" "$PWD/ci-app/Learner-Desktop.zip"
  printf 'commit %s\nrun %s\nbuilt %s\n' "$(git rev-parse HEAD)" "${GITHUB_RUN_ID:-local}" "$(date -u +%FT%TZ)" > "$PWD/ci-app/BUILD.txt"
  # The install kit: what installs this build on the owner's Mac comes with it.
  mkdir -p "$PWD/ci-app/kit/scripts" "$PWD/ci-app/kit/menu-bar-app"
  cp scripts/build-app.sh scripts/auto-update.sh "$PWD/ci-app/kit/scripts/"
  cp menu-bar-app/com.benpollack.learner-desktop.plist "$PWD/ci-app/kit/menu-bar-app/"
  echo "packaged ci-app/Learner-Desktop.zip"
}

# What reaches DEVICE's input while speech is played into it: per-channel peak and RMS.
# Run when the app hears nothing, to tell "no sound arrived" from "the app dropped it".
diagnose_input() {
  local dev="$1" wav="$OUT/diag-$(tr ' ' '-' <<< "$1").wav"
  echo "  diagnosis: recording 6 s from $dev while speech plays into it"
  ( sleep 0.5; speak_into "$dev" ) &
  sox -q -t coreaudio "$dev" "$wav" trim 0 6 2>&1 | sed 's/^/  sox: /'
  wait
  local n; n=$(soxi -c "$wav" 2>/dev/null || echo 0)
  echo "  $n channel(s) recorded"
  for ch in 1 2 3; do
    [ "$ch" -le "$n" ] || break
    echo "  channel $ch: $(sox "$wav" -n remix "$ch" stat 2>&1 | awk -F: '/Maximum amplitude|RMS +amplitude/{gsub(/ +/," ",$2); printf "%s=%s ", $1, $2}')"
  done
  echo "  all channels mixed: $(sox "$wav" -n remix - stat 2>&1 | awk -F: '/RMS +amplitude/{print $2}')"
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
  wait_log "\[Coach\] heard " 30 "$from" || { ok=1; diagnose_input "$MIC_B"; }
  SwitchAudioSource -t input -s "$MIC_A" >/dev/null
  return $ok
}

lane() { scripts/test.sh "$1"; }

# The automatic updater installs and loads (on the runner it finds no GitHub token and
# waits); uninstall must then remove it with everything else.
updater() {
  scripts/install-updater.sh || return 1
  launchctl print "gui/$(id -u)/com.benpollack.learner-desktop-updater" | grep -E "state|run interval" | sed 's/^\s*/  /'
  launchctl print "gui/$(id -u)/com.benpollack.learner-desktop-updater" >/dev/null
}

uninstall() { PURGE_DATA=1 scripts/uninstall-app.sh; }

# ---- report -----------------------------------------------------------------------------

report() {
  local failed=0 skips nskips
  [ -f "$RESULTS" ] && grep -q '^FAIL' "$RESULTS" && failed=1
  [ -f "$RESULTS" ] || failed=1
  # Swift Testing names every skip and cancellation: `➜ Test x() skipped: "why"`.
  skips="$(cat "$OUT"/light.log "$OUT"/medium.log "$OUT"/heavy.log 2>/dev/null \
    | grep -E '^➜ (Test|Suite) .* (skipped|was cancelled)' | sed -E 's/^➜ //' | sort -u)"
  nskips=$( [ -n "$skips" ] && wc -l <<< "$skips" | tr -d ' ' || echo 0)
  {
    echo "## Learner Desktop CI on the GitHub runner: $([ $failed -eq 0 ] && echo '✅ PASSED' || echo '❌ FAILED')"
    echo
    echo "Test environment: **runner** (a clean Mac; no owner accounts or live data)."
    echo
    echo "| | phase | time | note |"
    echo "|---|---|---|---|"
    [ -f "$RESULTS" ] && while IFS=$'\t' read -r verdict name took note; do
      echo "| $([ "$verdict" = PASS ] && echo ✅ || echo ❌) $verdict | $name | ${took}s | $note |"
    done < "$RESULTS"
    echo
    echo "### $nskips test(s) skipped, not passed"
    if [ "$nskips" -gt 0 ]; then echo; echo '```'; echo "$skips"; echo '```'; fi
  } > "$OUT/summary.md"
  banner "SUMMARY"
  cat "$OUT/summary.md"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"
  if [ $failed -ne 0 ]; then
    printf '\n\033[1;31m!!!!!!!! CI FAILED: %s !!!!!!!!\033[0m\n' "$(awk -F'\t' '$1=="FAIL"{print $2}' "$RESULTS" 2>/dev/null | paste -sd, -)"
    return 1
  fi
  printf '\n\033[1;32m======== CI PASSED (%s skipped) ========\033[0m\n' "$nskips"
}

# ---- run --------------------------------------------------------------------------------

keep_app_log() { [ -f "$APP_LOG" ] && cp "$APP_LOG" "$OUT/menubar.log"; return 0; }

run() {
  case "$1" in
    fetch) phase fetch fetch ;;
    virtual-mic) phase virtual-mic virtual_mic ;;
    grant) phase grant grant ;;
    fixtures) phase fixtures fixtures ;;
    speech) phase speech speech ;;
    install) phase install install ;;
    mic-e2e) phase mic-e2e mic_e2e ;;
    light|medium|heavy) phase "$1" lane "$1" ;;
    updater) phase updater updater ;;
    uninstall) keep_app_log; phase uninstall uninstall ;;
    report) report ;;
    all)
      rm -f "$RESULTS"
      for p in fetch virtual-mic grant fixtures speech install mic-e2e light medium heavy updater uninstall; do run "$p" || true; done
      report ;;
    *) echo "usage: scripts/ci.sh fetch|virtual-mic|grant|fixtures|speech|install|mic-e2e|light|medium|heavy|updater|uninstall|report|all" >&2; return 2 ;;
  esac
}

run "${1:-all}"
