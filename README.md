# Learner Desktop — Monologue Habit Experiment

A self-experiment in interrupting monologues on calls. Learner Desktop, a macOS menu-bar app, watches
[screenpipe](https://github.com/mediar-ai/screenpipe)'s live transcription, tracks how long
Ben has been talking without yielding, and delivers a stimulus at 30 s and 60 s under a
randomised treatment arm. Historical Read AI transcripts supply the pre-treatment baseline.

## Architecture

```
screenpipe (localhost:3030)        Read AI .docx exports           ai-vault export
  audio_transcriptions                     │                       (~/ai-vault-data)
       │ /raw_sql poll                     │ parse_readai_transcripts.py    │
       ▼                                   ▼                                │
 Learner Desktop (Swift)        data/historical_calls_export.json          │
  TalkTimeMonitor                          │                                │
       │ logTurn()                         │ import-baseline-via-rpc.ts     │ learner-watcher.js
       ▼                                   │                                │ (src/cli.ts watch)
 behavior_experiments.sqlite               │                                │
       │ recordHabitEvents                 │ recordCallTranscripts,         │ archiveConversation-
       │                                   │ recordHabitEvents              │ Documents
       ▼                                   ▼                                ▼
          learner-server RPC: POST $LEARNER_API_URL/rpc/<name>, header x-api-key
```

Every write goes to learner-server over HTTPS as `POST ${LEARNER_API_URL}/rpc/<name>`
with body `{"data": <input>}` and the device key in `x-api-key`; the wire shapes are
pinned in `contract/desktop.ts` (zod) and `contract/contract.json` (see
`contract/PINNED_COMMIT`). `LEARNER_API_URL` defaults to
`https://dev.biztoolz.app/learner-api`; the key comes from `LEARNER_API_KEY`, else the
Keychain (`security find-generic-password -s learner-server -a ben-mbp -w`). The client
id is `ben-mbp`.

Two paths write `habit_events` and they measure different things, recorded in
`metadata.measurement`:

| | live (`voiced`) | import (`transcript_gap`) |
|---|---|---|
| A turn is | a run of voiced segments | consecutive same-speaker transcript lines |
| Duration | summed voiced audio | gap to the next line, capped at `words / 2.0` s |
| Median | ~7.5 s | ~13 s |

Live rows also carry `gap_duration_sec` (wall-clock span of the turn) so the two are
comparable on the same basis.

## Setup

```bash
bun install
security add-generic-password -s learner-server -a ben-mbp -w   # store the device key (prompts)
./scripts/build-app.sh # build and install Learner Desktop
```

`build-app.sh` installs `~/Applications/Learner Desktop.app` and its LaunchAgent
(`com.benpollack.learner-desktop`), then restarts it. Run it again after any change.

### One app, one login item

Learner Desktop runs the transcript watcher (`src/cli.ts watch`, compiled to one file,
`learner-watcher.js watch --no-initial-sync`) as a child process from its own bundle. It
restarts it if it exits and stops it on quit. Its output goes to
`~/.ai-aggregator/logs/watcher.log`; the app's own to `menubar.log`.

The watcher parses each changed `conversation.md` into messages
(`src/parsers/ai-vault-messages.ts`) and sends it with `archiveConversationDocuments`,
≤50 per call. A local ledger (`~/.ai-aggregator/sync-ledger.sqlite`, table
`archive_ledger`) resends a conversation only when its content hash changes. A 422 parks
that one document; 401/403 stops with "key problem"; 413 halves the batch; 429/5xx back
off 2 s → 5 min with jitter; with no key it logs once and retries later. Conversations
with no text messages (empty, or voice-mode audio only) are not sent. `bun src/cli.ts
sync` sweeps the whole export once; `bun src/cli.ts status` shows the endpoint, whether
a key is available and the ledger counts.

They used to be two separate `/bin/bash` LaunchAgents. macOS lists those in System
Settings → Login Items as "bash" from an unknown developer, and once they were switched
off there, launchd silently stopped starting them at login: both stayed down for ten days
after the 2026-10-11 reboot. Now the app's single entry is all that has to be allowed,
and the tray shows `🧠 🔴 LOGIN` if it is not.

The bundle identifier is still `com.benpollack.ai-aggregator-menubar`: the Bluetooth
permission and the saved Pavlok settings are keyed to it, so renaming it would reset both.

Re-import the historical baseline (parse, then send over RPC):

```bash
python3 scripts/parse_readai_transcripts.py
bun scripts/import-baseline-via-rpc.ts            # dry run: build + validate, counts only
LEARNER_API_URL=... LEARNER_API_KEY=... bun scripts/import-baseline-via-rpc.ts --send
```

## Tests

Two lanes, stdlib `unittest` only — no pytest, no dependencies — plus `bun test tests/ts`
in the fast lane when bun is installed.

```bash
./scripts/test.sh          # fast lane (default), ~11s
./scripts/test.sh heavy    # heavy lane, opt-in
./scripts/test.sh all
```

**Fast lane** (`tests/*.py`) is pure and hermetic: no network, no database, no
launchd, no `.docx` corpus, no Swift compile. It covers the Read AI transcript
functions and both capture scripts. The capture-script tests run the real
`stop-capture.sh` / `start-capture.sh`, but inside a sandbox where every
state-changing command (`launchctl`, `pkill`, `curl`, `osascript`, `open`, `nc`,
`sqlite3`, `bun`) is a recording stub on `PATH` and `HOME` points at a throwaway
directory — they assert the ordering and flag handling without touching the real
capture stack. `tests/ts/` covers the ai-vault message parser (and, read-only, every
file in `~/ai-vault-data` when it exists), the RPC client against a local mock server
(2xx, 422, 401, 413, 429), and the baseline RPC mapping. Run this on every change.

**Heavy lane** (`tests/heavy/*.py`) needs the real world: screenpipe on `:3030`,
the 209-file `.docx` corpus, `swiftc`. Each suite skips rather than fails when its
dependency is missing.

One heavy test really does stop and restart the capture stack, and stays skipped
even in the heavy lane unless you opt in a second time:

```bash
AIAGG_HEAVY=1 AIAGG_HEAVY_DESTRUCTIVE=1 \
  python3 -m unittest discover -s tests/heavy -p 'test_capture_scripts_live.py'
```

Nothing is recorded while it runs. Do not run it during a call.

## screenpipe

Transcription comes from the installed screenpipe desktop app (mediar-ai/screenpipe, tested
with 2.7.116 / engine 0.4.52). It is not vendored; the update-check agent re-verifies it
after each screenpipe update.

- The app reads `audio_transcriptions` via `POST http://localhost:3030/raw_sql`.
- **Transcription latency drives warning latency.** screenpipe cannot write a transcription
  until its audio chunk completes, so `audioChunkDuration` sets a floor on how late the
  on-screen warning can fire. When lag is high, several segments land with one write
  `timestamp` and the app's wall-clock turn timing is distorted — turns merge or split
  wrongly. Every turn records `metadata.ingest_lag_sec_max`; anything above
  `maxTrustedIngestLagSec` (10 s) is tagged `metadata.data_quality = "suspect_ingest_lag"`.
  Filter those out of analysis.
- Settings this experiment depends on are captured in `config/screenpipe-settings.json`.

### Sign-in check

Since 2.7.34 screenpipe will not start recording or its API until someone signs in to a
screenpipe account, unless `SCREENPIPE_SKIP_ONBOARDING=1` is in its environment.
Learner Desktop sets that in launchd's user environment at launch, and relaunches a
screenpipe that started without it (at login it can start first). This replaced the
separate `com.screenpipe.env` LaunchAgent, which macOS switched off in Login Items:
after the 2026-10-11 reboot screenpipe sat signed out and recorded nothing for ten days.

In 2.7.116, Quit does not exit screenpipe while its server is running: it stops capture
and keeps serving saved history ("search-only"). Opening the app again resumes recording.

### Update checks

When the installed screenpipe version changes and holds still for 10 minutes, Learner
Desktop starts a fresh headless Claude Code session (`claude -p`) in this repo. It follows
[`docs/screenpipe-update-runbook.md`](docs/screenpipe-update-runbook.md) with only the
commands allowed in `config/screenpipe-update-agent.json`: it checks the whole system,
re-applies the sign-in flag, resumes capture, and on a version-only change starts the new
phase with `scripts/start-capture-phase.py` (new GrowthBook phase, re-pinned config,
committed). Runs are capped at $5 and 30 minutes, once per version. The menu has "Run
screenpipe Update Check Now".

Every run is logged in `~/.ai-aggregator/logs/screenpipe-update-checks/`: the full session
(`.jsonl`), its report (`.md`, with the session id to resume it), and one line per run in
`index.log`.

Unattended runs need a Claude login that does not lapse. Create a long-lived token once and
save it where the app reads it (it is passed to each run, never logged):

```bash
claude setup-token
stty -echo; (umask 077 && cat > ~/.ai-aggregator/claude-oauth-token); stty echo; echo " saved"
```

The second line waits for the token: paste it (nothing is echoed), press Return, then
Ctrl-D. It reads what you paste rather than the clipboard (copying the command itself would
overwrite that), and accepts a token that wrapped onto several lines; the app strips the
line breaks. A run with a bad token logs `STATUS: RUN FAILED (… 401 …)`. Without a token, runs use the interactive
`claude auth login`, which is stored per `$USER` and has expired between updates before.

### Version pinning and the preflight check

screenpipe is the experiment's measuring instrument. Changing it mid-phase makes any shift
in turn counts or durations impossible to attribute to the intervention, so:

- **Auto-update cannot be turned off.** screenpipe pushes a remote control policy
  (`settings.remoteControlPolicy.autoUpdate.forceEnabled = true`) that re-enables it on
  every launch and greys out the toggle. Setting `autoUpdate: false` in `store.bin` is
  reverted within seconds. So the guard is detection, not prevention: the preflight pins
  both the app and engine versions and fails when either moves.
- **Every turn records `metadata.screenpipe_version`**, read from `/health` by the app. An
  instrument change therefore shows up as a column you can segment on rather than as an
  invisible confound.
- **Treat a version change as a phase boundary** in GrowthBook: end the phase, upgrade,
  re-run the preflight, start the next phase. Analyses should not span versions.

Run the preflight before a session that matters:

```bash
./scripts/preflight-capture.sh
```

It compares the live `~/.screenpipe/store.bin` against `config/screenpipe-settings.json` and
checks that `/raw_sql` still returns the columns the app polls. It exists because
`TranscriptionMode::Batch` is screenpipe's `#[default]`: a settings reset, migration or
reinstall silently reintroduces up to two minutes of deferred transcription — which is what
corrupted the 2026-09-08 data — and nothing errors when it happens. Exit codes: `0` fine,
`1` drift, `2` screenpipe unreachable.

When a settings change is deliberate, re-capture the expectations so it lands in git:

```bash
./scripts/preflight-capture.sh          # shows exactly what drifted
# ...then update config/screenpipe-settings.json and commit it
```

**Note:** screenpipe rewrites `store.bin` from memory while it is running, so editing that
file with the app up does not stick. Stop screenpipe first, or change the setting in its UI.

## Experiment design

Four arms, assigned per session (`treatment_arm`): `baseline`, `caw_audio`, `pavlok_shock`,
`haptic_vibe`. **The visual toast shows in every arm, including `baseline`.** The arms differ
only in the stimulus added on top of it, so the experiment measures what audio, shock or
vibration adds over the visual cue — and the coach keeps working in every meeting. Each
toast is recorded in `metadata.interventions[]` with `modality: "toast"`.

- Warning at 30 s, hard stop at 60 s.
- `breached_30s` / `breached_60s` are strict (`> 30`, `> 60`).
- `was_rewarded` is `5 <= duration < 30` — a turn short enough to be a clean yield but long
  enough not to be a grunt.
- `warning_fired_at` / `shock_fired_at` hold the streak length when the stimulus actually
  fired, not the threshold constant.
- `latency_to_yield_sec` is the time from the warning firing to the speaker yielding. This is
  the primary behavioural outcome.
- `metadata.interventions[]` records every stimulus attempt with the modality and whether the
  device or sound **confirmed** delivery, so a failed dispatch is distinguishable from a
  delivered one. `metadata.intervention_confirmed` summarises it.

Synthetic data never reaches production metrics: simulated turns are written with
`call_category = 'demo'` and `metadata.simulated = true`, which the server filters out.

## Historical baseline rules

`parse_readai_transcripts.py` turns Read AI `.docx` exports into `habit_events`:

1. Consecutive lines by one speaker merge into a single turn (`metadata.lines_merged`).
2. Duration is the gap to the next line, capped at `words / 2.0` s so silence and
   untranscribed audio are not credited as speech; the final turn of a call is estimated at
   `words / 2.5` s; floor 1 s. `metadata.gap_sec` and `metadata.duration_basis`
   (`gap` | `words_cap` | `words_last`) record which applied.
3. Speakers match exactly against `{Ben Pollack, ben, Benjamin, Benjamin Pollack}`.
   Conference-room labels such as `Conference Room (Ben Pollack) - Speaker 1` are other
   people in the room and are **not** Ben.
4. Read AI exported some meetings twice (`X.docx` and `X(1).docx`). These are not identical
   re-exports — they are separate recordings of the same meeting, often on a different
   platform and frequently partial, colliding on a title-derived `session_id`. Only one can
   be kept, since keeping both would double-count the speech. The fuller recording wins.
5. `call_app` comes from the transcript's own platform — one source of truth.
6. A transcript with no other named speaker is `call_category = 'solo'`, so a lone 20-minute
   Desktop recording does not dominate the conversation metrics.

## Data notes

- `Past Call Transcripts/` and `data/` are gitignored: they hold real customer meeting
  transcripts and everything derived from them. The baseline already lives on learner-server,
  so `data/` is normally absent; `parse_readai_transcripts.py` recreates it if a re-import is needed.
- Baseline rows are tagged `metadata.source = 'readai_docx_import_v2'`.
- An earlier server-side rebuild tagged `transcript_rebuild_20260908` has been replaced.

### Manual Pavlok Bluetooth test

Enable **Keep Bluetooth Connected** under the menu's **⚡ Pavlok** submenu, then run
`"~/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop" --pavlok-test-fire <vibe|beep|zap> [intensity]`.
Vibration, beep, and zap each keep an independent saved 0–100% test intensity; 0% disables
that test. These settings do not change the automatic 30s/60s coaching levels.

Each run sends one pulse over direct Bluetooth, waits for the selected
characteristic and its write acknowledgement, and prints the result.
Cloud backup is excluded from manual connection tests. An acknowledgement means
the device accepted the command; it does not measure the physical sensation.
For Pavlok 2/3, beep uses the same intensity field as vibration, as implemented
in [PyPav2](https://github.com/ztrayl3/PyPav2/blob/master/PyPav2.py).

If Bluetooth is not ready, charge/wake the band and choose **Scan & Connect via
Bluetooth**. For Pavlok 3, USB-C power turns it on automatically. Temporarily
disconnecting its phone Bluetooth connection can help isolate connection issues.

Validation: `python3 -m unittest discover -s tests -p 'test_pavlok*.py'` checks
menu wiring and executes the production packet encoders. The opt-in live test
in `tests/heavy/test_pavlok_test_fire_live.py` sends one 25% vibration and requires
a Bluetooth acknowledgement; it never tests zap automatically.

Pavlok requests and results are also persisted in the existing `habit_events`
behavior database as `habit_type=pavlok_intervention`, using the existing remote
sync path. Metadata links lifecycle records with `operation_id` and includes
modality, requested percentage, phase, result/error, device identity, battery,
transport, elapsed time, and explicit `device_acknowledged`. Manual tests use
`manual_test=true` and `treatment_arm=manual_test`; they are excluded from the
menu's speaking-trial count. Raw diagnostic output remains in
`~/.ai-aggregator/logs/menubar.log`. A cloud HTTP success is never marked as a
Bluetooth device acknowledgement.

The menu-bar app owns the persistent Bluetooth connection. **Keep Bluetooth
Connected** is independent of automatic wearable feedback; it can stay enabled
while automatic coaching stimuli remain off. The app remembers the last connected
band, reconnects after link loss, and retains the link between manual tests.
When the signed app is running, `--pavlok-test-fire` forwards a single validated
request to that app instead of opening another Bluetooth connection or changing
saved intensity/feedback settings. A forwarding timeout is an unknown outcome and
is not automatically retried.
