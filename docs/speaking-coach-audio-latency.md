# Speaking Coach audio-to-toast latency — September 12, 2026

Before the timing revision, the warning's dominant error came from the live path's duration estimator:
`max(1, min(words * 0.35, 4))` seconds per transcript segment. It assumes roughly
171 words per minute before segment floors/caps and recognition errors. Speech
rate therefore changes when the nominal 30-second warning fires.

## Controlled audio measurements

Two recordings use the same 229-word passage and Samantha voice. The generated
waveform was time-scaled with pitch preservation and its duration measured, giving
120.03 and 200.04 script words per minute. TTS rate flags alone were not accurate
enough; earlier calibration runs are not the controlled comparison below.

The primary threshold is 30 seconds from the first audible speech in the waveform.
Natural brief inter-word pauses are included in this monologue elapsed-time measure.

| Sample | Waveform duration | Native panel first visible | Difference from 30-second audio mark | Coach's claimed seconds at fire |
|---|---:|---:|---:|---:|
| 120 wpm | 114.47 s | 37.12 s | **7.12 s late** | 31.15 s |
| 200 wpm | 68.69 s | 25.13 s | **4.87 s early** | 31.50 s |

Breakdown, relative to the primary threshold:

| Component | 120 wpm | 200 wpm |
|---|---:|---:|
| End of the audio chunk that finally pushed the word counter over 30 | +6.00 s | −5.25 s |
| STT request and queue after that chunk completed | +0.206 s | +0.226 s |
| Coach polling and rendering after transcript arrival | +0.910 s | +0.149 s |
| Total | **+7.117 s** | **−4.874 s** |

The slower sample needed an audio chunk ending at 36 seconds before the counter
crossed 30. The faster sample crossed on a chunk ending at 24.75 seconds. Median
file transcription requests took 0.208 and 0.229 seconds, with less than 8 ms of
request scheduling backlog. This run does not support transcription load as the
main cause of the difference.

As a separate reference, accumulating 20 ms waveform frames with RMS >= 0.003
reaches 30 seconds of energy-active audio at 32.20 and 31.90 seconds. Relative to
that reference the popups are **4.92 seconds late** and **6.77 seconds early**.
This is an explicit energy threshold, not ground-truth phonetic speech or the
Screenpipe VAD algorithm. Both references show the same direction of bias.

## What the test actually runs

1. Generate full local speech recordings; do not play them into the call.
2. Release 16 kHz mono PCM slices at their real-time audio boundaries, 2.25 seconds
   apart. This mirrors the live engine's two-second minimum and 750 ms flush tick,
   rather than the five-second background recording setting.
3. Submit each slice to the running Screenpipe `/v1/audio/transcriptions` endpoint,
   reusing its configured `whisper-tiny-quantized` engine without an override.
4. Return the actual recognized text and known capture timestamps from an isolated
   live-meeting HTTP fixture to the production coach code.
5. Run the actual NSPanel, observing it every 10 ms. Record threshold eligibility,
   first `isVisible` panel with alpha > 0.05, and full-opacity timestamps separately.
   The coach polls at its production one-second interval.

The test does not assign a streak. The source copy only
substitutes endpoints, defaults, logger location, and the application entrypoint.
Local test rows remain isolated and are not uploaded. No recorder settings or
production app files are changed. The source SHA-256 is in each result.

Limits: the file-upload endpoint adds decode/session/HTTP overhead and omits the
live capture, event delivery and Screenpipe database path. Chunk boundaries are
controlled rather than captured from actual device callbacks. Native window
timestamps are AppKit observations, not a measurement of physical display pixels.
These are two measured runs, not latency percentiles across many trials.

## Actual Slack call comparison

For the owner-confirmed real toast, the first transcript capture time was
16:52:44.304 EDT. The triggering segment began at 16:53:15.920; its text became
available at 16:53:18.420. The toast intervention was logged at 16:53:19, about
**34.70 seconds** after the first captured speech (the fire log has second precision).
The prior segment left the estimate at 29.7 seconds; the next moved it to 31.1.
The finalized 41.9-second turn had maximum ingestion lag 3.427 seconds.

The exact real event `4d2fdf59-8fca-421a-8116-a364636792da` was verified in Postgres
and included once in each of the saved GrowthBook fact and exposure queries.

## Rerun and evidence

```sh
AIAGG_HEAVY=1 AIAGG_AUDIO_E2E=1 \
AIAGG_AUDIO_E2E_DIR="$PWD/data/verification/audio-$(date +%Y%m%d-%H%M%S)" \
python3 tests/heavy/test_speaking_coach_audio_latency.py -v
```

Requires the running configured Screenpipe engine, `say`, `ffmpeg`, and `swiftc`.
Normal heavy-test opt-in alone does not run this workload. Errors in generation,
compilation, transcription, or failure to display a panel fail the benchmark.
The measured latency is reported; a functional test pass does not mean the timing
is accurate.

Controlled evidence: `data/verification/audio-latency-measured-20260912/`.
Each sample folder contains `speech.wav`, `passage.txt`, per-chunk real transcripts
and request times, native panel times, coach logs, isolated habit database, and
the source snapshot. `results.json` contains the comparison above.

The appropriate correction is to base the threshold on audio timing under an
explicit definition of speaking time. Lowering the threshold to compensate for a
slow speaker would make the fast-speaker warning even earlier. No threshold or
duration-estimation change was made during this measurement.

Validation: the calibrated two-sample benchmark passed; the fast suite ran 95
tests with one skip. The post-run preflight remained non-green: the existing app
version mismatch, plus Screenpipe reporting background transcription writes stalled
for 2,638 seconds and 71,627 pending segments. That reported stall predates these
audio benchmarks. Frame and audio capture statuses were `ok`, and this benchmark's
file transcription requests completed normally. The health response is retained
as `post-health.json`; the background backlog was not altered or treated as a reason
to restart the recorder.

## Confirmed speech timing revision

The counter now measures from the first speech timestamp to the latest confirmed
microphone speech timestamp. Timer ticks alone cannot advance it. If speech stops
at 27 seconds, silence through 30 seconds leaves the counter at 27 and cannot
trigger a warning. A short internal pause remains part of the turn if speech
resumes; another participant's speech ends it, excluding the trailing wait.
Long silence still expires the turn.

Live Screenpipe rows expose segment capture starts, not word-end timestamps.
For this path the counter conservatively uses those starts without inventing
word duration from text length. This removes the words-per-minute estimator but
still leaves chunk and recognition latency, and does not promise exact word-level
timing. Background rows use their available segment start/end offsets.
New telemetry carries `timing_version=confirmed_speech_span_v1` and
`duration_basis=first_to_last_confirmed_speech`; it no longer claims that turn
length is accumulated voiced duration. Previous measurements above describe the
old estimator, not the revised implementation.

Replaying the same generated waveforms with the revision produced:

| Sample | Panel first visible | Delay after 30 seconds | Confirmed span at fire |
|---|---:|---:|---:|
| 120 wpm | 34.096 s | 4.096 s | 31.5 s |
| 200 wpm | 34.125 s | 4.125 s | 31.5 s |

Both crossed on chunk 15 (capture start 31.5 s, chunk end 33.75 s).
The 0.030-second difference replaces the previous roughly 12-second rate bias.
The remaining delay was 3.75 s of chunk timing, 0.186–0.208 s of STT/queue,
and 0.160–0.168 s of polling/rendering. These remain controlled file-STT replays,
not fresh measurements of a real call. Evidence: `data/verification/audio-confirmed-span-20260912/`.
