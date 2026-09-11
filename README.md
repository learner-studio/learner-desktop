# AI Aggregator — Monologue Habit Experiment

A self-experiment in interrupting monologues on calls. A macOS menu-bar app watches
[screenpipe](https://github.com/mediar-ai/screenpipe)'s live transcription, tracks how long
the owner has been talking without yielding, and delivers a stimulus at 30 s and 60 s under a
randomised treatment arm. Historical Read AI transcripts supply the pre-treatment baseline.

## Architecture

```
screenpipe (localhost:3030)          Read AI .docx exports
   audio_transcriptions                       │
        │ /raw_sql poll                       │ parse_readai_transcripts.py
        ▼                                     ▼
  menu-bar app (Swift)                data/historical_calls_export.json
   TalkTimeMonitor                            │ ingest_to_postgres.ts
        │ logTurn()                           │
        ▼                                     │
  ~/.ai-aggregator/behavior_experiments.sqlite│
        │ sync-habits.ts (SSH tunnel :15432)  │
        ▼                                     ▼
              Postgres `habits` — habit_events + call_transcripts
                            │
                       GrowthBook
```

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
cp .env.example .env   # then fill in HABITS_PG_URL
./scripts/tunnel.sh    # SSH tunnel to Postgres
```

Rebuild and install the menu-bar app:

```bash
./scripts/build-app.sh
```

Re-import the historical baseline (parse, then ingest):

```bash
python3 scripts/parse_readai_transcripts.py
bun scripts/ingest_to_postgres.ts
```

## Tests

Two lanes, stdlib `unittest` only — no pytest, no dependencies.

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
capture stack. Run this on every change.

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

Transcription comes from screenpipe, vendored in-tree at `vendor/screenpipe`
(mediar-ai/screenpipe `main` @ `a3eae78`, desktop app version 2.7.27).

- The app reads `audio_transcriptions` via `POST http://localhost:3030/raw_sql`.
- **Transcription latency drives warning latency.** screenpipe cannot write a transcription
  until its audio chunk completes, so `audioChunkDuration` sets a floor on how late the
  on-screen warning can fire. When lag is high, several segments land with one write
  `timestamp` and the app's wall-clock turn timing is distorted — turns merge or split
  wrongly. Every turn records `metadata.ingest_lag_sec_max`; anything above
  `maxTrustedIngestLagSec` (10 s) is tagged `metadata.data_quality = "suspect_ingest_lag"`.
  Filter those out of analysis.
- Settings this experiment depends on are captured in `config/screenpipe-settings.json`.

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

To re-sync the vendored copy:

```bash
rm -rf vendor/screenpipe
git clone --depth 1 https://github.com/mediar-ai/screenpipe.git vendor/screenpipe
rm -rf vendor/screenpipe/.git
```

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
3. Speakers match exactly against `{the owner, ben, the owner, the owner}`.
   Conference-room labels such as `Conference Room (the owner) - Speaker 1` are other
   people in the room and are **not** the owner.
4. Read AI exported some meetings twice (`X.docx` and `X(1).docx`). These are not identical
   re-exports — they are separate recordings of the same meeting, often on a different
   platform and frequently partial, colliding on a title-derived `session_id`. Only one can
   be kept, since keeping both would double-count the speech. The fuller recording wins.
5. `call_app` comes from the transcript's own platform — one source of truth.
6. A transcript with no other named speaker is `call_category = 'solo'`, so a lone 20-minute
   Desktop recording does not dominate the conversation metrics.

## Data notes

- `Past Call Transcripts/` and `data/` are gitignored: they hold real customer meeting
  transcripts and everything derived from them.
- Baseline rows are tagged `metadata.source = 'readai_docx_import_v2'`.
- An earlier server-side rebuild tagged `transcript_rebuild_20260908` has been replaced;
  a snapshot of it is kept locally at
  `data/baseline_snapshot_transcript_rebuild_20260908.json` (gitignored).
