# screenpipe update check

Learner Desktop starts a fresh, unattended Claude Code session with this runbook whenever
the installed screenpipe version changes (or when "Run screenpipe Update Check Now" is
chosen in its menu). Nobody is watching: check, fix only what is listed below, and report.

screenpipe updates itself and the vendor forces that on. Updates have broken this setup
before: 2.7.34 started requiring an account sign-in, and 2.7.116 converted the database
and came back with capture off. screenpipe is also the experiment's measuring instrument,
so a new version is a new phase of the experiment.

Use the commands as written: only these are permitted. Never read transcript or screen
text; ids, timestamps, versions and statuses are all you need.

## 1. Check

Record each as ✓ or ✗ with the evidence.

1. **Learner Desktop and its helpers.** `launchctl list | grep learner-desktop` shows a pid;
   `pgrep -fl learner-watcher.js` and `pgrep -fl autossh` each find one process.
2. **learner-server.** `curl -s -m 5 https://dev.biztoolz.app/learner-api/api/health` answers;
   `nc -z 127.0.0.1 3200` (GrowthBook, the tunnel's only forward) succeeds; and
   `grep '^\[Outbox\]' ~/.ai-aggregator/logs/menubar.log | tail -3` shows sends succeeding,
   not "device key refused" or "server unreachable".
3. **Sign-in flag.** `launchctl getenv SCREENPIPE_SKIP_ONBOARDING` prints `1`, and
   `ps -wwEAo command | grep screenpipe-app` shows `SCREENPIPE_SKIP_ONBOARDING=1` on the
   screenpipe-app process.
4. **screenpipe.** `curl -s -m 5 http://localhost:3030/health`: note `status`,
   `capture_status.status`, `frame_status`, `audio_status` and `version`. Then
   `ls -t ~/.screenpipe/screenpipe-app.*.log | head -1` and grep that log for
   `Skipping server auto-start`, `account_required`, `storage migration failed`,
   `Server started without capture` and `search-only`; report the latest of each.
5. **Transcripts.**
   `curl -s -m 10 -X POST http://localhost:3030/raw_sql -H 'Content-Type: application/json' -d '{"query":"SELECT max(id) AS id, max(timestamp) AS last FROM audio_transcriptions LIMIT 1"}'`.
   In `~/.ai-aggregator/logs/menubar.log`, the last
   `Connected to Screenpipe raw_sql (lastCheckedTranscriptionId: N)` must have N close to
   that max id. A small N means the coach is replaying history as live speech: report it.
6. **Preflight.** `"/Users/benpollack/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop" tool preflight`
7. **Tests.** `./scripts/test.sh`

## 2. Fix only these, then check again

- **Flag missing from launchd:** `launchctl setenv SCREENPIPE_SKIP_ONBOARDING 1`. Learner
  Desktop relaunches a signed-out screenpipe within about 8 seconds. If it has not after
  `sleep 30`, run `open -g -a /Applications/screenpipe.app`.
- **Capture off** (search-only, "Server started without capture", a storage migration
  error, or `frame_status` not ok while the server answers):
  `open -g -a /Applications/screenpipe.app` is screenpipe's own way to resume recording.
  `sleep 30`, then check again.
- **Preflight fails only on the two version lines** and every other check passes: start
  the new phase with the installed app's tool (run from this repository):
  `"/Users/benpollack/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop" tool start-capture-phase --dry-run`, then the same without `--dry-run`. That ends the current GrowthBook phase, starts
  one named `screenpipe <app> / engine <engine>`, and re-pins
  `config/screenpipe-settings.json`. Run the preflight again, then commit only that file
  to the current branch: `git add config/screenpipe-settings.json` and
  `git commit -m "Start capture phase: screenpipe <app> / engine <engine>"`.

## 3. Never

- Start a phase when any settings line drifted, health is not healthy, or `/raw_sql`
  lost columns. Report instead: a drifted setting such as `transcriptionMode` silently
  corrupts turn timing.
- Sign in to anything, push, delete or move files, or edit anything under `~/.screenpipe`.
- Signal screenpipe (`kill`, `pkill`): it handles no termination signals and its
  database can be left mid-write.
- Change any code. If something needs a code change, describe it in the report.

## 4. Report

Your final message is saved as this run's log. Start it with exactly one of
`STATUS: OK`, `STATUS: FIXED` or `STATUS: NEEDS ATTENTION`, then list the checks (✓/✗ with
evidence), what you changed, and anything the owner has to do.
