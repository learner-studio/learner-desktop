# Speaking Coach E2E verification

The acceptance boundary is meeting detection response → live transcript HTTP poll →
accumulated streak → native warning panel → saved habit row → PostgreSQL upload →
GrowthBook source queries. A call to `startSimulation(seconds: 35)` skips most of
that boundary and is only a panel preview, not a meeting-pipeline test.

## Local integration suite

```sh
AIAGG_HEAVY=1 \
AIAGG_COACH_E2E_DIR="$PWD/data/verification/coach-$(date +%Y%m%d-%H%M%S)" \
python3 tests/heavy/test_speaking_coach_meeting_e2e.py -v
```

The four cases use the production Swift monitor, panel and logger:

| Fixture | Expected result |
|---|---|
| Detected meeting; ten live input segments, no background speech | 36-second turn; first visible panel at 32 seconds; baseline arm still gets a toast |
| Same speech with no active meeting | `canAlert=false`; no panel or toast intervention |
| Speech timestamps span 27 seconds, followed by silence beyond 30 seconds and a backchannel | Counter stays at 27; no warning; saved duration excludes trailing silence |
| Speech resumes at 31 seconds after the last segment at 27 seconds | Same turn reaches 31 seconds and shows the warning |

Each fixture also returns background reconciliation rows for speech already read
through the live path. Exactly one habit row must remain, proving the backfill
did not create a duplicate turn. The counter uses the first and latest confirmed speech timestamps. This suite
does not measure speech recognition accuracy or exact word boundaries.

The source is copied into an evidence directory and compiled. Only the HTTP URL,
defaults suite, logger directory and application entrypoint are substituted. The
monitor and NSPanel code are not mocked. `isSimulating` stays false to exercise the
real meeting gate. No production recorder, running app, user settings, habit
database, wearable or habit sync is touched. The original source hash is recorded.
Do not upload this raw local fixture database: it deliberately uses the normal
logging path. The remote test below marks its upload copy as synthetic first.

Build failures, child-process failures, missing panels, missing rows, wrong flags,
wrong thresholds, missing backfill traffic and duplicate turns fail the test.
Only missing explicit opt-in or missing Swift skips it.

For human visibility confirmation, add `AIAGG_COACH_E2E_INTERACTIVE=1`. The test
holds the visible warning until `<evidence>/live-warning/release` exists, with a
three-minute maximum. Confirm the text on the actual display, then create that
file. `panel.json` records AppKit visibility and opacity; it is not a substitute
for the owner's visual confirmation. The negative cases do not hold a panel.

## Remote upload and GrowthBook check

Run only when deliberately testing the real server. This writes one retained demo
row and requires the normal `HABITS_PG_URL`, database tunnel and SSH access to `ovh`.

```sh
AIAGG_HEAVY=1 AIAGG_REMOTE_E2E=1 \
AIAGG_COACH_E2E_SOURCE_DB="/absolute/path/to/local-evidence/live-warning/behavior_experiments.sqlite" \
AIAGG_REMOTE_E2E_DIR="$PWD/data/verification/growthbook-$(date +%Y%m%d-%H%M%S)" \
python3 tests/heavy/test_habit_sync_growthbook_e2e.py -v
```

The test copies the one verified local turn, assigns a unique event/session ID and
sets `call_category=demo`, `metadata.simulated=true` and
`metadata.experiment_eligible=false`. It retains the source event ID for correlation.
It calls the actual `syncHabits` uploader with the isolated database path, verifies
one upload followed by zero on a second sync, and checks the local acknowledgement.

Over SSH it reads GrowthBook's configured Habits Telemetry exposure query and Habit
Speech Events fact query, then queries Postgres `habits` for the exact uploaded ID
and executes those actual GrowthBook queries. The row must exist in `habit_events`
with the same toast/path/duration, and be excluded from both experiment queries.
This proves source delivery and exclusion; it does not claim a synthetic turn was
included in a refreshed GrowthBook experiment report.

Remote opt-in is separate from `AIAGG_HEAVY=1`, so the ordinary heavy suite never
uploads test telemetry implicitly. Evidence retains the server row and query
results without exporting connection credentials.

## Verified on September 12, 2026

The owner confirmed: **“Yes, I can see it.”** The first isolated run logged:

```text
Active call detected: Simulated Meeting (E2E)
User speaking streak now: 0:28 (warn: false, alert: false)
User speaking streak now: 0:32 (warn: true, alert: false)
User speaking streak now: 0:36 (warn: true, alert: false)
Logged trial: arm=baseline, dur=36.0s
```

- Local event: `f8dcf94d-3bd4-4377-a96d-dabed693c2a5`.
- Local row: `toast_shown=true`, `transcription_path=live_meeting`, 36 seconds.
- Synthetic arrival lag: maximum 5.505 seconds, produced by the fixture timing.
- Remote demo event: `13980c77-0c35-414e-8f81-1543c274e67d`.
- Remote verification: row present; local sync acknowledged; second sync sent zero;
  GrowthBook exposure and fact queries each included zero synthetic rows.
- Human-confirmed evidence: `data/verification/coach-meeting-20260912/`.
- Remote evidence: `data/verification/coach-growthbook-20260912/`.

This is a simulated HTTP meeting, not a real call or an acoustic end-to-end test.
Real meeting detection, live recognition timing, and panel behavior within an
actual call still require a meeting. A brief output backchannel currently resets
the streak; the test documents that behavior rather than changing the policy.

Preflight was already failing because the installed Screenpipe app was 2.7.30 and
the experiment pins 2.7.28. Engine 0.4.50, `whisper-tiny-quantized`, five-second
chunks and realtime transcription matched. The version pin was not relaxed and
Screenpipe was not restarted or reconfigured.

## Real Slack call verified later on September 12, 2026

The owner joined Slack and spoke continuously. Screenpipe detected meeting 29 at
16:52:44 EDT, and the production coach tracked session `call_slack_c338b723` through
the live meeting transcript path. At 16:53:19 the streak reached 31.1 seconds,
`warn` became true, and the owner confirmed **“Yes, I can see it.”** This confirms
the actual on-screen warning during a real call, beyond the isolated fixture.

Production `habit_events` row **2756**, event
`4d2fdf59-8fca-421a-8116-a364636792da`, contains:

- 41.9 voiced seconds; warning fired at 31.1 seconds.
- `toast_shown=true`, `transcription_path=live_meeting`, `simulated=false`.
- `data_quality=ok`, maximum ingest lag 3.427 seconds.
- `experiment_eligible=true`, `call_category=work`, arm `haptic_vibe`.
- `synced_to_server=1`; the exact event was independently read from Postgres over SSH.

The visual cue was delivered. The separate vibration intervention records
`delivered=false`, with reason `Pavlok is disabled in settings`; this does not
invalidate the visual result and must not be reported as successful haptic delivery.

Evidence is in `data/verification/slack-live-20260912/`: observed logs, human
confirmation, local rows, and remote verification. Observer log timestamps reflect
when a line was read; the recorded intervention timestamp is the actual fire time.
