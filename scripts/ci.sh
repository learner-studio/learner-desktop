#!/usr/bin/env bash
#
# ci.sh -- the whole app on a clean Mac (a GitHub macOS runner), loudly:
#
#   fetch          Voice ID's model and sherpa-onnx (scripts/fetch-voice-id.sh)
#   virtual-mic    two BlackHole loopback devices; "BlackHole 2ch" becomes the default input
#   grant          microphone + speech-recognition grants for the app's bundle id (TCC.db)
#   fixtures       the synthetic sample (Tests/Fixtures/sample) as ~/ai-vault-data + its ledger
#   screenpipe     screenpipe's engine (the pinned version, the owner's audio settings) on :3030
#   server         learner-server's pairing harness ready to run (Postgres 17, its test database, web build)
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
# The default output: its own device, so system-audio capture never hears what is played
# into the two microphones.
SPEAKER="BlackHole 64ch"

# What the server phase exported for later phases (each workflow step is its own shell).
if [ -f "$OUT/server.env" ]; then set -a; . "$OUT/server.env"; set +a; fi

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
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch
  sudo killall coreaudiod || true
  local until=$((SECONDS + 30))
  until SwitchAudioSource -a -t input | grep -qx "$MIC_B" && SwitchAudioSource -a -t input | grep -qx "$MIC_A" \
        && SwitchAudioSource -a -t output | grep -qx "$SPEAKER"; do
    [ $SECONDS -lt $until ] || { echo "BlackHole devices did not appear:"; SwitchAudioSource -a -t input; return 1; }
    sleep 1
  done
  SwitchAudioSource -t input -s "$MIC_A"
  # A real default output, so screenpipe's system-audio capture has something to tap (with
  # none, its device check times out and /health reports degraded). Not a microphone: what
  # the run plays into the mics must not also reach system audio as "someone else".
  SwitchAudioSource -t output -s "$SPEAKER"
  echo "default output: $(SwitchAudioSource -c -t output)"
  # Room tone on the virtual microphone: a real mic never delivers digital silence, and
  # screenpipe marks an input whose level stays under RMS 0.001 for 30 s as no data
  # ("active_no_data"). vol 0.025 measures about RMS 0.005 (-46 dBFS; vol 0.005 measured
  # RMS 0.0011, at the floor): a quiet room, far below speech. It plays for the whole run.
  command -v sox >/dev/null || HOMEBREW_NO_AUTO_UPDATE=1 brew install sox
  # Re-launched every 20 s: another program opening the device can reconfigure it under a
  # long-running sox, which then keeps running while the device hears zeros (run 5). A
  # fresh sox picks the device up again well inside screenpipe's 30 s window.
  nohup bash -c "while true; do sox -q -n -t coreaudio '$MIC_A' synth 20 pinknoise vol 0.025 || echo \"\$(date -u +%T) sox exited \$?\"; done" > "$OUT/room-tone.log" 2>&1 &
  echo $! > "$OUT/room-tone.pid"
  sleep 1
  kill -0 "$(cat "$OUT/room-tone.pid")" 2>/dev/null || { echo "room tone did not start:"; cat "$OUT/room-tone.log"; return 1; }
  echo "room tone playing into $MIC_A (pid $(cat "$OUT/room-tone.pid"))"
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

# screenpipe's open-source engine, the version config/screenpipe-settings.json pins, with
# the owner's audio settings, recording BlackHole 2ch: the heavy lane's capture suites then
# run against a real screenpipe. The CLI, not the app: the app records only when signed in
# to a screenpipe account (checked in its source at app-v2.7.145). npm never changes a
# published version, and the tarball must match its pinned integrity hash.
SCREENPIPE_CLI_VERSION=0.4.58
SCREENPIPE_CLI_SHA512="EhpKXwvgNmIMNNBV6blOFlJqNdMFvAnn+fN9F2/1gOEM/lmaXtDBNYYFr1HoPlIjI8FTO0sBZognNcsNQuMsgg=="
screenpipe() {
  set -e
  local pinned; pinned="$(python3 -c "import json; print(json.load(open('config/screenpipe-settings.json'))['_screenpipe_engine_version'])")"
  [ "$pinned" = "$SCREENPIPE_CLI_VERSION" ] || { echo "config pins screenpipe engine $pinned but ci.sh installs $SCREENPIPE_CLI_VERSION: update SCREENPIPE_CLI_VERSION and its SHA512"; return 1; }
  local cache="$HOME/.cache/learner-screenpipe" dir="$HOME/.local/screenpipe-cli"
  mkdir -p "$cache" "$dir"
  local tgz="$cache/cli-darwin-arm64-$SCREENPIPE_CLI_VERSION.tgz"
  [ -f "$tgz" ] || curl -fsSL --retry 3 -o "$tgz" "https://registry.npmjs.org/@screenpipe/cli-darwin-arm64/-/cli-darwin-arm64-$SCREENPIPE_CLI_VERSION.tgz"
  [ "$(openssl dgst -sha512 -binary "$tgz" | base64)" = "$SCREENPIPE_CLI_SHA512" ] || { echo "screenpipe CLI tarball does not match its pinned SHA-512"; rm -f "$tgz"; return 1; }
  tar -xzf "$tgz" -C "$dir"
  local bin; bin="$(find "$dir/package" -type f -name screenpipe -perm +111 | head -1)"
  [ -x "$bin" ] || { echo "no screenpipe binary in the tarball:"; find "$dir/package" -maxdepth 3 | head -20; return 1; }
  echo "screenpipe: $bin ($("$bin" --version 2>/dev/null || echo "version unknown"))"
  # Screen and system-audio capture (system TCC.db) and the microphone (user TCC.db), for
  # the binary by path, as the runner image does for its own tools.
  local now; now=$(date +%s)
  for service in kTCCServiceScreenCapture kTCCServiceAudioCapture; do
    sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
      "INSERT OR REPLACE INTO access VALUES('$service','$bin',1,2,3,1,NULL,NULL,NULL,'UNUSED',NULL,0,$now,NULL,NULL,'UNUSED',$now);"
  done
  sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "INSERT OR REPLACE INTO access VALUES('kTCCServiceMicrophone','$bin',1,2,3,1,NULL,NULL,NULL,'UNUSED',NULL,0,$now,NULL,NULL,'UNUSED',$now);"
  sudo launchctl kickstart -k system/com.apple.tccd || true
  echo "audio devices:"; "$bin" audio list 2>&1 | sed 's/^/  /' | head -20
  local mic; mic="$("$bin" audio list 2>/dev/null | grep -o "${MIC_A} (input)" | head -1)"
  [ -n "$mic" ] || mic="${MIC_A} (input)"
  # The owner's settings: realtime transcription, 5 s chunks, whisper-tiny-quantized,
  # system audio through Core Audio, no PII removal, no API auth (the app's apiAuth: false;
  # the engine's own default is on, and every query the app makes then gets 403).
  SCREENPIPE_NO_REMINDERS=1 SCREENPIPE_NO_UPDATE_CHECK=1 nohup "$bin" record --port 3030 \
    -a whisper-tiny-quantized -d 5 --transcription-mode realtime \
    -i "$mic" -i "System Audio (output)" --experimental-coreaudio-system-audio \
    --use-pii-removal false --disable-telemetry --api-auth false > "$OUT/screenpipe.log" 2>&1 &
  echo $! > "$OUT/screenpipe.pid"
  local until=$((SECONDS + 240))
  until curl -sf -m 3 http://localhost:3030/health >/dev/null; do
    if ! kill -0 "$(cat "$OUT/screenpipe.pid")" 2>/dev/null; then echo "screenpipe exited:"; tail -40 "$OUT/screenpipe.log"; return 1; fi
    [ $SECONDS -lt $until ] || { echo "screenpipe did not answer /health in 240 s:"; tail -40 "$OUT/screenpipe.log"; return 1; }
    sleep 2
  done
  echo "health: $(curl -s -m 3 http://localhost:3030/health | head -c 400)"
  # One transcription row, so the live-SQL suites have something to read: spoken once
  # screenpipe records the mic (it starts that a while after /health answers), then seen.
  local until=$((SECONDS + 240))
  until grep -q "starting continuous recording for ${MIC_A}" "$OUT/screenpipe.log"; do
    [ $SECONDS -lt $until ] || { echo "screenpipe never started recording $MIC_A"; return 1; }
    sleep 2
  done
  local rows=0 n
  for attempt in 1 2 3; do
    say -a "$MIC_A" "This is the runner checking that screenpipe hears the virtual microphone."
    for _ in $(seq 1 20); do
      n="$(curl -s -m 5 -X POST http://localhost:3030/raw_sql -H 'content-type: application/json' \
        -d '{"query":"SELECT count(*) AS n FROM audio_transcriptions"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["n"])' 2>/dev/null || echo 0)"
      [ "${n:-0}" -gt 0 ] && { rows=$n; break 2; }
      sleep 3
    done
  done
  echo "audio_transcriptions rows: $rows"
  [ "$rows" -gt 0 ] || { echo "screenpipe stored no transcription of the spoken line"; return 1; }
}

# learner-server's own pairing harness on the runner, for the heavy lane's pairing and
# mastery end-to-end suites: the checkout at config/learner-server.ref (the workflow checks
# it out into ./learner-server; learner-server is public), Postgres 17 with its migrated
# TEST database, and its web build. Exported for the lanes through $OUT/server.env.
server() {
  set -e
  local dir="$PWD/learner-server"
  [ -d "$dir/scripts" ] || { echo "no learner-server checkout in $dir"; return 1; }
  echo "learner-server at $(git -C "$dir" rev-parse --short HEAD) (pinned: $(cut -c1-7 config/learner-server.ref))"
  command -v bun >/dev/null || { echo "bun is not on PATH"; return 1; }
  # nginx: the remote topology runs the SHIPPED deploy/nginx config in front of the API.
  # shellcheck: the light lane's script check. The hosts entry: remote pairing advertises a
  # non-loopback name that resolves here (PairingE2E's remote case).
  HOMEBREW_NO_AUTO_UPDATE=1 brew install postgresql@17 nginx shellcheck >/dev/null
  grep -q "learner-pairing.test" /etc/hosts || echo "127.0.0.1 learner-pairing.test" | sudo tee -a /etc/hosts >/dev/null
  local pg; pg="$(brew --prefix postgresql@17)/bin"
  rm -rf "$HOME/learner-pg"
  "$pg/initdb" -D "$HOME/learner-pg" -U learner --auth=trust >/dev/null
  "$pg/pg_ctl" -D "$HOME/learner-pg" -l "$OUT/postgres.log" -o "-p 5432 -k /tmp" -w start
  "$pg/createdb" -h 127.0.0.1 -U learner learner_test
  "$pg/createdb" -h 127.0.0.1 -U learner learner_dev
  {
    echo "TEST_DATABASE_URL=postgres://learner@127.0.0.1:5432/learner_test"
    echo "DATABASE_URL=postgres://learner@127.0.0.1:5432/learner_dev"
    echo "LEARNER_SERVER_DIR=$dir"
    echo "LEARNER_BUN=$(command -v bun)"
    echo "LEARNER_PAIRING_E2E=1"
    echo "LEARNER_MASTERY_E2E=1"
  } > "$OUT/server.env"
  # Throwaway secrets the server needs (on ovh they come from /etc/learner/learner.env): made
  # here, kept out of ci-out (its logs are a public artifact), gone with the runner.
  umask 077
  {
    echo "LEARNER_AUTH_SECRET=$(openssl rand -hex 32)"
    echo "LEARNER_BASE_URL=http://127.0.0.1:3019"
  } > "$HOME/.learner-ci-secrets.env"
  umask 022
  set -a; . "$OUT/server.env"; set +a
  # Each server start runs pikku's code generation first: done once here, so a start in the
  # heavy lane fits the harness's 180 s wait on 3 busy cores.
  ( cd "$dir" && bun install --frozen-lockfile && bun packages/server/src/db/migrate.ts --test && bun run build:web \
      && bun run prepare:runtime ) 2>&1 | tail -15
  [ -f "$dir/apps/web/dist/index.html" ] || { echo "learner-server's web build is missing"; return 1; }
  echo "ready: Postgres 17 (learner_test migrated), web built; the heavy lane runs the pairing harness locally"
}

speech() {
  # Apple's speech recognizer refuses with "Siri and Dictation are disabled" until one of
  # them is on; the owner's Mac has Siri on ("Assistant Enabled"). Both, for the runner.
  defaults write com.apple.assistant.support "Assistant Enabled" -bool true
  defaults write com.apple.assistant.support "Dictation Enabled" -bool true
  killall assistantd corespeechd 2>/dev/null || true   # they reread the settings on relaunch
  defaults read com.apple.assistant.support | grep -E '"(Assistant|Dictation) Enabled"' | sed 's/^ */  /'
  # Many checks speak with `say` (the mic end to end, the speech model, screenpipe's rows,
  # the audio benchmark). Run 8's machine synthesized silence (85 samples for a sentence):
  # check it here, restart the synthesizer if needed, and fail plainly if it stays broken.
  local wav="$OUT/say-check.wav" n=0
  for attempt in 1 2 3; do
    rm -f "$wav"
    say -o "$wav" --file-format=WAVE --data-format=LEI16@16000 "The quick brown fox checks the speech synthesizer." 2>&1 | tail -2
    n=$(( ( $(stat -f %z "$wav" 2>/dev/null || echo 0) - 44 ) / 2 ))
    echo "say attempt $attempt: $n samples"
    [ "$n" -gt 16000 ] && break
    killall speechsynthesisd SpeechSynthesisServer com.apple.speech.speechsynthesisd 2>/dev/null || true
    sleep 3
  done
  rm -f "$wav"
  [ "$n" -gt 16000 ] || { echo "the runner's speech synthesizer is broken (say makes silence); every check that speaks would fail"; return 1; }
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
  echo "2. speech played into $MIC_A is heard, as the owner's own turn with its words"
  speak_into "$MIC_A"
  wait_log "\[Coach\] heard " 30 "$from" || ok=1
  # The turn ends on silence (not "someone else spoke"), with the words screenpipe heard.
  wait_log "turn [0-9]+ ended \(silent[^)]*\): [0-9.]+ s, [1-9][0-9]* words" 60 "$from" || ok=1
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
  # Its own turn too (screenpipe records only $MIC_A, so no word count here).
  wait_log "turn [0-9]+ ended \(silent" 60 "$from" || ok=1
  SwitchAudioSource -t input -s "$MIC_A" >/dev/null
  return $ok
}

# What the virtual mic carries right now (diagnosis for screenpipe's audio health).
audio_check() {
  echo "room tone: $(pgrep -f "synth 20 pinknoise" >/dev/null && echo "playing" || echo "NOT PLAYING") (loop $(kill -0 "$(cat "$OUT/room-tone.pid" 2>/dev/null)" 2>/dev/null && echo alive || echo dead))"
  echo "default input: $(SwitchAudioSource -c -t input 2>/dev/null), output: $(SwitchAudioSource -c -t output 2>/dev/null)"
  echo "level on $MIC_A over 2 s: $(sox -q -t coreaudio "$MIC_A" -n trim 0 2 stat 2>&1 | awk -F: '/RMS +amplitude/{gsub(/ /,"",$2); print "RMS " $2}')"
  echo "screenpipe audio: $(curl -s -m 3 http://localhost:3030/health | python3 -c 'import json,sys; h=json.load(sys.stdin); print(h.get("status"), h.get("audio_status"))' 2>/dev/null)"
  tail -3 "$OUT/room-tone.log" 2>/dev/null
}

# The server phase's exports, read again here (in `ci.sh all` it ran in a subshell). Its
# secrets are not: only the harness reads them (LEARNER_SERVER_SECRETS), so no test
# process carries them.
lane() {
  [ "$1" = heavy ] && audio_check
  if [ -f "$OUT/server.env" ]; then set -a; . "$OUT/server.env"; set +a; fi
  export LEARNER_SERVER_SECRETS="$HOME/.learner-ci-secrets.env"
  scripts/test.sh "$1"
}

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
  # A phase that never reported (its step skipped or killed) is a failure, not a gap.
  local p missing=""
  for p in fetch virtual-mic grant fixtures screenpipe server speech install mic-e2e light medium heavy updater uninstall; do
    grep -q "	$p	" "$RESULTS" 2>/dev/null || { missing="$missing $p"; failed=1; }
  done
  # Swift Testing names every skip and cancellation: `➜ Test x() skipped: "why"`.
  skips="$(cat "$OUT"/light.log "$OUT"/medium.log "$OUT"/heavy.log 2>/dev/null \
    | grep -E '^➜ (Test|Suite) .* (skipped|was cancelled)' | sed -E 's/^➜ //' | sort -u)"
  nskips=$( [ -n "$skips" ] && wc -l <<< "$skips" | tr -d ' ' || echo 0)
  {
    echo "## Learner Desktop CI on the GitHub runner: $([ $failed -eq 0 ] && echo '✅ PASSED' || echo '❌ FAILED')"
    echo
    echo "Test environment: **runner** (a clean Mac; no owner accounts or live data)."
    echo
    [ -n "$missing" ] && { echo "❌ phases that never reported:$missing"; echo; }
    echo "| | phase | time | note |"
    echo "|---|---|---|---|"
    [ -f "$RESULTS" ] && while IFS=$'\t' read -r verdict name took note; do
      echo "| $([ "$verdict" = PASS ] && echo ✅ || echo ❌) $verdict | $name | ${took}s | $note |"
    done < "$RESULTS"
    echo
    # Known issues: a test marked with withKnownIssue (and why), never counted as a pass.
    local known
    known="$(cat "$OUT"/light.log "$OUT"/medium.log "$OUT"/heavy.log 2>/dev/null | grep -E 'recorded a known issue|^.? ?Test .* with [0-9]+ known issue' | sed -E 's/^[^A-Za-z]*//' | sort -u)"
    if [ -n "$known" ]; then
      echo "### ⚠️ Known issues (expected failures, not passes)"; echo; echo '```'; echo "$known"; echo '```'; echo
    fi
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
    screenpipe) phase screenpipe screenpipe ;;
    server) phase server server ;;
    speech) phase speech speech ;;
    install) phase install install ;;
    mic-e2e) phase mic-e2e mic_e2e ;;
    light|medium|heavy) phase "$1" lane "$1" ;;
    updater) phase updater updater ;;
    uninstall) keep_app_log; phase uninstall uninstall ;;
    report) report ;;
    all)
      rm -f "$RESULTS"
      for p in fetch virtual-mic grant fixtures screenpipe server speech install mic-e2e light medium heavy updater uninstall; do run "$p" || true; done
      report ;;
    *) echo "usage: scripts/ci.sh fetch|virtual-mic|grant|fixtures|screenpipe|server|speech|install|mic-e2e|light|medium|heavy|updater|uninstall|report|all" >&2; return 2 ;;
  esac
}

run "${1:-all}"
