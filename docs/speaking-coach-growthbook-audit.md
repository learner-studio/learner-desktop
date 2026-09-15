# Speaking Coach → GrowthBook audit, September 12, 2026

The event transport and active metric field mappings work. The revised measurement
is not yet isolated in GrowthBook, so the current experiment configuration is not
ready to compare the new timing method with historical measurements as one series.
No GrowthBook settings, production app, or recording settings were changed.

## Verified remotely

SSH host `ovh`; PostgreSQL database `habits`; GrowthBook datasource
`ds_3pqkl1j0mtry0hqo` (Habits Telemetry), fact table `ftb_habit_events`, experiment
`exp_3pqkl2kbmtry3gcv`, tracking key `monologue_streak`.

The production uploader sent an isolated, explicitly synthetic E2E turn. The server
preserved duration, words, warning/shock thresholds, yield latency, breach flags,
and the entire metadata object, including `timing_version=confirmed_speech_span_v1`.
Local acknowledgement was set, and a second sync sent zero rows. Retained demo
row: `076633e3-70cc-4e7c-815c-a029afda062a`. The saved exposure and fact queries both
exclude it, as required. This is not a real experimental observation.

All four local E2E records were also evaluated using the actual saved SQL in
read-only PostgreSQL CTEs that shadow the event table. No eligible fixture records
were inserted into production:

| Case | Duration | Breach >30 | Fact rows | Exposure rows |
|---|---:|---:|---:|---:|
| Live warning | 36 | 1 | 1 | 1 |
| Off-call | 36 | 1 | 0 | 0 |
| Speech ends at 27, followed by silence | 27 | 0 | 1 | 1 |
| Speech resumes after a short pause | 31 | 1 | 1 | 1 |

GrowthBook randomization/analysis unit is `session_id`, with variation keys
`baseline`, `caw_audio`, `pavlok_shock`, `haptic_vibe`, matching application values.
The active metrics are fact metrics, not the older standalone SQL metrics:

| Metric | Definition |
|---|---|
| `fact__mean_turn_sec` | Sum turn_duration_sec / count of turns |
| `fact__breach30_rate` | Sum breached_30s / count of turns |
| `fact__p90_turn_sec` | Event-level 90th percentile of turn_duration_sec |
| `fact__breach60_rate` | Sum breached_60s / count of turns |
| `fact__latency_to_yield` | Sum latency_to_yield_sec / count where non-null |

The latest saved snapshot was successful, created at 2026-09-12T20:09:39.181Z.
Its generated SQL uses these definitions and the correct arm keys. Results are
stored as chunked analyses (empty inline arrays do not imply no analysis).
That snapshot predates the later Slack verification and this audit; it does not
prove that new rows have appeared in a refreshed dashboard.

## Gaps to resolve before the timing rollout

1. **Measurement versions are mixed by the saved queries.** Neither exposure nor
   fact SQL filters or partitions by `timing_version`; the experiment has a single
   phase beginning September 8. Before the test upload, all warehouse rows lacked
   this new version. At rollout, establish a separate analysis cohort/phase and
   filter its input to the new version, preserving historical results separately.
   The metadata tag alone does not perform that separation.
2. **Yield latency has an unresolved interpretation.** The app clamps the interval
   between the last confirmed speech timestamp and the warning's wall-clock time
   to zero. Live timestamps are capture starts, so speech may have ended before a
   delayed warning; zero then does not establish an immediate response to the cue.
   The new 36-second E2E row actually has zero latency. Record this circumstance as
   missing/ambiguous response timing rather than evidence of an instant response,
   and make the metric's denominator reflect that distinction.
3. **Treatment descriptions are stale.** GrowthBook describes baseline as having
   no notifications, while the app shows its toast. Its haptic description promises
   repeats every five seconds; source fires at thresholds. The shock description
   also differs from the source's 30/60-second stimulus dispatch. Update descriptions
   against the final deployed delivery behavior before interpreting comparisons.
4. **Exposure and outcome quality filters differ.** The fact query excludes
   `suspect%` quality rows; the exposure query does not. This may be intentional
   assignment accounting, but exposed sessions can have no valid outcome rows.
   Make that policy explicit instead of treating exposure counts as valid-turn counts.

The source revision remains uninstalled. This audit does not assert that revised
real meeting measurements are already flowing in production.

Evidence: `data/verification/growthbook-timing-audit-20260912/` contains settings,
fact metric definitions, latest snapshot, generated analysis SQL, schema/counts,
and all four read-only fixture results. `data/verification/growthbook-timing-upload-20260912/`
contains the upload log and exact remote row. The remote E2E now compares the full
metadata and all outcome fields, rather than only checking toast and duration.
