# Speaking Coach settings-aware experiment rollout

Updated and installed September 12, 2026. GrowthBook experiment:
`exp_speech_coach_settings_v1`, “Speaking Coach — settings combinations and positive feedback”.
Historical experiment `exp_3pqkl2kbmtry3gcv` is stopped with its phase ending at the
new phase start, 2026-09-12T21:30:32.190Z. Its definitions and snapshots remain.
The original affected configuration is backed up in the server's
`growthbook.codex_configuration_backups` collection.

## Actual design

All four assigned arms share the visual toast. Baseline adds no threshold stimulus;
audio adds macOS Frog at 30 and Sosumi at 60; configurable wearable adds the enabled
modalities/intensities; haptic adds 35% at 30 and 80% at 60, without five-second repeats.
Wearable feedback must be enabled for wearable cues.

Positive feedback applies across arms when enabled: a 30% vibration after a turn
ends with duration at least 5 but below 30 seconds and the existing reward guards
pass. The end can be another speaker or silence expiry. It does not promise vibration
at the instant the microphone becomes quiet.

Captured variables include effective 30/60 cues, wearable enabled, shock/vibration
intensities, warning beep, reward setting/effective enabled, reward intensity,
thresholds, call-only gate, and assignment mode. GrowthBook exposes the cue and
wearable/reward/intensity variables in the exposure query and fact columns. Thus
`cue_60=toast_only` with `reward_enabled=true` is distinguishable from reward-off,
or no shock with vibration still enabled. These are observational settings, not
additional randomized factorial arms. Only randomized-per-session mode enters the
experiment; manual overrides remain logged but excluded.

Only versioned, non-synthetic speech-turn events enter the new source. Intervention
audit events cannot pollute turn counts. Suspect timing and sessions with observed
settings changes are excluded. Old word-estimated timing is not pooled. The app
records treatment settings at turn start and detects changes while processing it.
Nonpositive yield latency is now missing rather than clamped to zero; the new
latency metric uses only observed positive values. Reward request share is explicitly
not a device-delivery metric; BLE acknowledgement remains in intervention audit rows.

GrowthBook uses the existing per-session arm assignment; it does not remotely toggle
the desktop configuration. The current app preferences were preserved during install.
The app was rebuilt, signed, installed and restarted; Screenpipe was not restarted
or reconfigured. Signed installed and build bundle binaries match.

## Verification

- Four meeting E2E cases passed with the new timing/settings metadata.
- A live-device E2E used synthetic transcript timestamps, the actual HTTP poller,
  normal short-turn reward logic, and real Bluetooth. One 12-second turn produced
  exactly one acknowledged 30% vibration from Pavlok-3-E2ED. No shock was sent.
  ACK took about 80 ms after the device operation request. This measures command
  acknowledgement, not subjective perception or full speech-to-reward latency.
- Production settings snapshot logic passed tests for toast-only, reward on/off,
  vibration-only, combined shock/vibration, wearable disabled, and every arm.
- Server E2E validated saved metric references/dimensions and query behavior for
  reward/toast combinations, manual overrides, synthetic rows, old timing and changed settings.
- The real uploader preserved all outcome fields and metadata; a second sync sent
  zero. Demo event `8ca3a02e-310c-45bc-bc6c-676247e9897e` was retained and excluded.
- The existing fast suite passed: 95 tests, one skipped. The additional settings
  contract test also passed separately.

Evidence directories: `data/verification/reward-device-settings-20260912/`,
`data/verification/growthbook-settings-rollout-20260912/`, and
`data/verification/growthbook-settings-upload-20260912/`.
No claim is made that a new real-call outcome or refreshed results snapshot exists
already; the new experiment starts collecting the revised installed telemetry.

## Repeatable tests

Live wristband test (explicitly sends one physical vibration; the reward path itself is
covered per arm by the light lane's coach workflow tests):

```sh
LEARNER_HEAVY=1 LEARNER_HEAVY_PAVLOK=1 scripts/test.sh heavy --filter "Coach, heavy"
```

Read-only server configuration/SQL test (`Tests/HeavyTests/GrowthBookRemoteTests.swift`;
the exposure query runs read-only against fictional rows built inside the query):

```sh
LEARNER_REMOTE_E2E=1 scripts/test.sh heavy --filter GrowthBookRemote
```

`learner-desktop tool growthbook-design` prints the design by default.
Its `--apply` command refuses to overwrite an existing revision; inspect current
configuration before adapting it for a future change.
