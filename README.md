**WARNING THIS IS A VIBE-CODED PROTOTYPE**

# Learner Desktop

A macOS menu-bar app (Swift) that runs on the owner's Mac and feeds
[learner-server](https://github.com/learner-studio/learner-server), which parses, dedupes and
stores everything and hosts the Learner web app. The desktop app:

- **Coaches talk time on calls.** An on-device speech detector (Silero VAD on Core ML,
  `menu-bar-app/Speech.swift`, ~1 % of a core) hears the owner start talking on the
  microphone within about a third of a second; [screenpipe](https://github.com/mediar-ai/screenpipe)'s
  transcripts still supply other speakers and word counts. It tracks how long the owner has
  talked without yielding, and at 30 s and 60 s gives a cue for the session's randomised treatment arm
  (a screen toast in every arm, plus sound, a Pavlok vibration or shock). Every turn is a
  trial row sent to the server.
- **Archives ChatGPT and Claude web chats.** The [ai-vault](https://www.npmjs.com/package/ai-vault)
  CLI exports them hourly; the app fills in ChatGPT voice-chat transcripts that ai-vault
  leaves out and sends every changed conversation to the server.
- **Reports its health.** A heartbeat every 5 minutes, and a tray icon that turns red, with
  the reason, when anything is stuck: screenpipe, the server, the device key, an expired
  ai-vault login, the trial database, the tunnel.

Codex CLI and Claude Code sessions are captured by learner-server's `clients/uploader`
(learner-upload), not by this app (yet): it tails `~/.codex/sessions` and
`~/.claude/projects` and uploads the raw session files with the same device key and client id.

## Pairing with learner-server

Everything goes to learner-server over HTTPS as `POST ${LEARNER_API_URL}/rpc/<name>` with body
`{"data": <input>}` and the device key in `x-api-key`. The wire shapes are pinned in
`contract/desktop.ts` and `contract/contract.json` (see `contract/PINNED_COMMIT`).

- **Server:** `LEARNER_API_URL`, default `https://dev.biztoolz.app/learner-api`.
- **Client id:** `ben-mbp`. It must not change: the server keys every thread on it.
- **Device key:** issued by learner-server for that client id. The app reads it from the
  Keychain (service `learner-server`, account `ben-mbp`) or `LEARNER_API_KEY`.
- **What it sends:** `recordHabitEvents` (trial rows), `archiveConversationDocuments` (chats,
  always the full conversation; the server dedupes), `recordAppHeartbeat`.

## Architecture

One Swift app (`menu-bar-app/*.swift`, built with SwiftPM) running a few workflows, all on
the shared primitives in `Core.swift` — `Log` (levels and a prefix per workflow), `Job`
(recurring work: one run at a time, backoff, schedule and outcome kept across restarts,
problems shown in the tray), `ChildProcess` (every program the app runs has a deadline and
a SIGKILL fallback), `Scheduler` (one 1 s clock) and `Shutdown` (bounded, logged quit):

```
screenpipe :3030 ──poll──▶ Speaking coach (Coach*.swift) ──▶ Pavlok / sound / toast
                                   │ trial rows
                                   ▼
                     behavior_experiments.sqlite ──Outbox job (8 s)──▶ recordHabitEvents
ai-vault CLI ──Export job (hourly)──▶ ~/ai-vault-data ──Voice──▶ ──Archive job──▶ archiveConversationDocuments
Status job (8 s) ──▶ one AppStatus ──▶ tray + menu          Heartbeat job (5 min) ──▶ recordAppHeartbeat
```

Live trial rows are `metadata.measurement = "voiced"`: a turn is a run of voiced segments and
its duration the summed voiced audio (median ~7.5 s). They also carry `gap_duration_sec`, the
wall-clock span of the turn. Historical baseline rows on learner-server were measured
differently; see the server repo.

## Build and run

Requires macOS 14+, Xcode (Swift 6), screenpipe, and for chats the `ai-vault` CLI (`npm i -g ai-vault`).

```bash
security add-generic-password -s learner-server -a ben-mbp -w   # store the device key (prompts)
scripts/install-hooks.sh                                        # test lanes on commit and push
scripts/build-app.sh                                            # build and install Learner Desktop
```

`build-app.sh` builds with `swift build -c release`, installs `~/Applications/Learner
Desktop.app` and its LaunchAgent (`com.benpollack.learner-desktop`), then restarts it.
`BUNDLE_ONLY=1 OUT_DIR=<dir>` builds and signs the bundle without installing it.

### One app, one login item

Everything runs inside the app; the only helper process is the SSH tunnel for GrowthBook's
UI (supervised by `ManagedHelper`: restarted with backoff, stopped with its children at
quit, an orphan from a crash reaped on the next launch).

Chats: the Export job runs `ai-vault backup` hourly (and on demand), stopping a run that
prints nothing for 10 minutes; ChatGPT voice transcripts that ai-vault leaves out are
filled in (`Voice.swift`); the Archive job sends every changed `conversation.md` with
`archiveConversationDocuments`, ≤50 per call. A local ledger
(`~/.ai-aggregator/sync-ledger.sqlite`, table `archive_ledger`) resends a conversation only
when its content hash changes. A 422 parks that one document; 401/403 blocks until the key
is fixed; 413 halves the batch; 429/5xx back off. The parser matches the earlier TypeScript
parser byte for byte (`Tests/Fixtures/parity`), so the server's deduplication keys stay stable.

Helpers used to be separate `/bin/bash` LaunchAgents. macOS lists those in System
Settings → Login Items as "bash" from an unknown developer, and once they were switched
off there, launchd silently stopped starting them at login: they stayed down for ten days
after the 2026-10-11 reboot. Now the app's single entry is all that has to be allowed,
and the tray shows `🧠 🔴 LOGIN` if it is not.

The bundle identifier is still `com.benpollack.ai-aggregator-menubar`: the Bluetooth
permission and the saved Pavlok settings are keyed to it, so renaming it would reset both.

### Owner tools

One-shot maintenance tools are subcommands of the app binary (`menu-bar-app/Tools*.swift`).
They print to the terminal and exit; run them from this repository:

```bash
swift run LearnerDesktop tool start-capture-phase --dry-run   # new experiment phase after a screenpipe update
swift run LearnerDesktop tool growthbook-design               # print the Speaking Coach GrowthBook design
swift run LearnerDesktop tool growthbook-design --apply       # ...or write it over `ssh ovh` (refuses to overwrite)
swift run LearnerDesktop tool vault-report [root]             # ai-vault conversation counts, never text
```

The installed app answers the same (`".../Learner Desktop.app/Contents/MacOS/learner-desktop" tool ...`).

## Tests

Everything is Swift (Swift Testing, `swift test`). Every workflow — the speaking coach,
the trial outbox, the chat export → voice transcripts → archive, the helpers, status and
shutdown, the owner tools — has end-to-end tests in three lanes:

```bash
scripts/test.sh light     # fixtures and stand-ins only; under 60 s (pre-commit hook)
scripts/test.sh medium    # real child processes, the built binary, local HTTP stand-ins; 60-180 s
scripts/test.sh heavy     # the live machine (screenpipe, ai-vault, learner-server); read-only
scripts/test.sh all
scripts/install-hooks.sh  # pre-commit runs light (+ gitleaks); pre-push runs medium + heavy
```

- **Light** (`Tests/LightTests`) runs in parallel against fixtures, injected clocks and
  in-process fakes. No network, no real processes beyond `/bin` helpers.
- **Medium** (`Tests/MediumTests`) runs one test at a time: fake `ai-vault` and `claude`
  scripts (including ones that hang and ignore SIGTERM), the real capture scripts in a
  stubbed sandbox, `tool preflight` and the coach poller against `HTTPStandIn` servers.
- Light and medium point the app's data folders at a throwaway directory
  (`LEARNER_DATA_DIR`, `AI_VAULT_DATA`), so they never touch `~/.ai-aggregator` or
  `~/ai-vault-data`. No test waits on a real schedule; each finishes within 2 minutes.
- **Heavy** (`Tests/HeavyTests`, `LEARNER_HEAVY=1`) needs the real world: screenpipe on
  `:3030` (read-only queries), the real export and ledger, one ChatGPT read, learner-server
  health, and with `LEARNER_REMOTE_E2E=1` the deployed GrowthBook design over `ssh ovh`
  (read-only). It also builds the release binary and checks the signed bundle as it ships,
  and runs the audio benchmark: synthesized speech through screenpipe's speech-to-text
  endpoint into the coach, timing the 30 s warning (it checks that screenpipe stored none of
  it; any row left behind is tagged `learner-heavy-test` and fails the test;
  `LEARNER_HEAVY_AUDIO=0` skips it). Each suite skips, with the reason, when its dependency
  is missing. The live wristband test needs `LEARNER_HEAVY_PAVLOK=1`. About 3–4 minutes.

Two heavy suites really do stop and restart the capture stack and the installed app,
and stay skipped even in the heavy lane unless you opt in a second time:

```bash
LEARNER_HEAVY_DESTRUCTIVE=1 scripts/test.sh heavy --filter Destructive
```

Nothing is recorded while they run. Do not run them during a call.

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
phase with `learner-desktop tool start-capture-phase` (new GrowthBook phase, re-pinned config,
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
swift run LearnerDesktop tool preflight
```

It compares the live `~/.screenpipe/store.bin` against `config/screenpipe-settings.json` and
checks that `/raw_sql` still returns the columns the app polls. It exists because
`TranscriptionMode::Batch` is screenpipe's `#[default]`: a settings reset, migration or
reinstall silently reintroduces up to two minutes of deferred transcription — which is what
corrupted the 2026-09-08 data — and nothing errors when it happens. Exit codes: `0` fine,
`1` drift, `2` screenpipe unreachable.

When a settings change is deliberate, re-capture the expectations so it lands in git:

```bash
swift run LearnerDesktop tool preflight   # shows exactly what drifted
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
- A turn of 5–30 s (a clean yield) earns a reward vibration only in the wristband arms;
  `was_rewarded` records whether one was actually delivered.
- `warning_fired_at` / `shock_fired_at` hold the streak length when the stimulus actually
  fired, not the threshold constant.
- `latency_to_yield_sec` is the time from the warning firing to the speaker yielding. This is
  the primary behavioural outcome.
- `metadata.interventions[]` records every stimulus attempt with the modality and whether the
  device or sound **confirmed** delivery, so a failed dispatch is distinguishable from a
  delivered one. `metadata.intervention_confirmed` summarises it.

Synthetic data never reaches production metrics: simulated turns are written with
`call_category = 'demo'` and `metadata.simulated = true`, which the server filters out.

## Data notes

- `Past Call Transcripts/` and `data/` are gitignored: they would hold real meeting
  transcripts. Nothing in them is used by the app.
- App data lives in `~/.ai-aggregator` (logs, job state, the trial database, the archive
  ledger); ai-vault's export in `~/ai-vault-data`.

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

Validation: `scripts/test.sh light` (the Pavlok suites) checks
menu wiring and executes the production packet encoders. The opt-in live test
in `Tests/HeavyTests` (Pavlok live suite) sends one 25% vibration and requires
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
