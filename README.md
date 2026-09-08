# AI Aggregator — Monologue Habit Experiment

A self-experiment in interrupting monologues on calls. A macOS menu-bar app watches
[screenpipe](https://github.com/mediar-ai/screenpipe)'s live transcription, tracks how long
Ben has been talking without yielding, and delivers a stimulus at 30 s and 60 s under a
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

Run the parser tests:

```bash
python3 -m unittest discover -s tests -p 'test_transcript_parsing.py'
```

## Dependency: screenpipe

screenpipe is an upstream application, installed separately — it is not vendored here.

- Tested against **screenpipe 2.7.27** (`/Applications/screenpipe.app`).
- The app reads `audio_transcriptions` via `POST http://localhost:3030/raw_sql`.
- **Transcription must run in low-latency mode.** screenpipe batches transcription writes;
  when it does, several segments land with one write `timestamp` and the app's wall-clock
  turn timing is distorted — turns merge or split wrongly and the on-screen warning fires
  late. Each turn now records `metadata.ingest_lag_sec_max`, and any turn whose lag exceeds
  `maxTrustedIngestLagSec` (10 s) is tagged `metadata.data_quality = "suspect_ingest_lag"`.
  Filter those out of analysis.

## Experiment design

Four arms, assigned per session (`treatment_arm`): `baseline`, `caw_audio`, `pavlok_shock`,
`haptic_vibe`. `baseline` is silent and observational — it receives no stimulus **and no
visual toast**, so it is a true control.

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
  transcripts and everything derived from them.
- Baseline rows are tagged `metadata.source = 'readai_docx_import_v2'`.
- An earlier server-side rebuild tagged `transcript_rebuild_20260908` has been replaced;
  a snapshot of it is kept locally at
  `data/baseline_snapshot_transcript_rebuild_20260908.json` (gitignored).
