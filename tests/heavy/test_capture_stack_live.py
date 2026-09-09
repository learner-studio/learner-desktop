#!/usr/bin/env python3
"""Heavy lane: the live screenpipe capture stack on :3030.

Opt-in. Needs AIAGG_HEAVY=1 (scripts/test.sh heavy sets it) and a running screenpipe.
Read-only: queries /health and reads ~/.screenpipe/store.bin. Nothing is started,
stopped or written.

Distilled from the old tests/test_realtime_audio_e2e.py, which was a diagnostic probe:
its "backlog" and "canary matching" tests asserted only `len(rows) > 0` (twice, in two
different tests) and its CPU profiler asserted a machine-specific `avg_cpu < 60`. What
survives here is what the aggregator actually depends on -- realtime mode, both audio
directions being captured, and the settings not having drifted from the capture in
config/screenpipe-settings.json.
"""

import json
import os
import unittest
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCREENPIPE_URL = "http://localhost:3030"
STORE_PATH = os.path.expanduser("~/.screenpipe/store.bin")
EXPECTED_SETTINGS = os.path.join(REPO, "config", "screenpipe-settings.json")

HEAVY = os.environ.get("AIAGG_HEAVY") == "1"


def get_health():
    with urllib.request.urlopen(f"{SCREENPIPE_URL}/health", timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))


def screenpipe_up():
    try:
        get_health()
        return True
    except Exception:
        return False


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(screenpipe_up(), "screenpipe is not answering on :3030")
class ScreenpipeLiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.health = get_health()

    def test_audio_pipeline_is_healthy_and_in_realtime_mode(self):
        self.assertEqual(self.health.get("status"), "healthy")
        self.assertEqual(self.health.get("audio_status"), "ok")
        # Chunked mode reintroduces the transcription backlog the aggregator was
        # built to avoid; the menu-bar app assumes turns land within a few seconds.
        self.assertEqual(
            self.health.get("audio_pipeline", {}).get("transcription_mode"),
            "realtime",
        )

    def test_captures_both_microphone_and_system_audio(self):
        """A call needs both sides: the owner's mic and the meeting tap."""
        devices = self.health.get("audio_pipeline", {}).get("audio_devices", [])
        low = [d.lower() for d in devices]
        self.assertTrue(
            any("output" in d or "system audio" in d or "tap" in d for d in low),
            f"no system-audio/meeting-tap device in {devices}")
        self.assertTrue(
            any("input" in d or "mic" in d or "airpods" in d for d in low),
            f"no microphone device in {devices}")


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(os.path.exists(STORE_PATH), f"no store.bin at {STORE_PATH}")
@unittest.skipUnless(os.path.exists(EXPECTED_SETTINGS),
                     f"no checked-in settings at {EXPECTED_SETTINGS}")
class ScreenpipeSettingsDriftTest(unittest.TestCase):
    """The live settings must still match config/screenpipe-settings.json.

    The old probe hardcoded literals ('whisper-tiny-quantized') that had already
    drifted from reality. Diffing against the checked-in capture instead means a
    deliberate config change is recorded in git rather than breaking the suite,
    while an accidental change -- a screenpipe update resetting the engine, someone
    toggling a switch in the UI mid-experiment -- shows up as a failure.
    """

    def test_live_settings_match_the_checked_in_capture(self):
        with open(STORE_PATH, encoding="utf-8") as fh:
            live = json.load(fh).get("settings", {})
        with open(EXPECTED_SETTINGS, encoding="utf-8") as fh:
            expected = json.load(fh).get("settings", {})

        drift = {k: (v, live.get(k)) for k, v in expected.items()
                 if v != "***REDACTED***" and live.get(k) != v}
        self.assertEqual(drift, {},
                         "screenpipe settings drifted from "
                         "config/screenpipe-settings.json (expected, actual); "
                         "if the change was deliberate, update that file")


if __name__ == "__main__":
    unittest.main()
