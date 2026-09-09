#!/usr/bin/env python3
"""Heavy lane: the screenpipe surface main.swift depends on.

Read-only. These guard silent breakage: when screenpipe changes shape, the menu-bar
app does not error -- it just stops seeing rows, or drops to the arrival clock, and
turn timing quietly becomes wrong.
"""

import json
import os
import re
import unittest
import urllib.request

API = os.environ.get("SCREENPIPE_API", "http://localhost:3030")

# The two shapes ISO8601DateFormatter is configured for in main.swift
# (TalkTimeMonitor.parseScreenpipeDate). Anything else parses as nil and silently
# demotes the turn to metadata.turn_clock = "arrival".
PLAIN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$")
FRACTIONAL = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(Z|[+-]\d{2}:\d{2})$")


def api_post(path, payload, timeout=8):
    req = urllib.request.Request(
        f"{API}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


@unittest.skipUnless(os.environ.get("AIAGG_HEAVY") == "1", "heavy lane not requested")
class ScreenpipeContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            with urllib.request.urlopen(f"{API}/health", timeout=5) as resp:
                cls.health = json.load(resp)
        except Exception as exc:
            raise unittest.SkipTest(f"screenpipe not listening on {API}: {exc}")

    def test_raw_sql_returns_every_column_the_app_polls(self):
        rows = api_post("/raw_sql", {"query":
            "SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, t.start_time, "
            "t.end_time, c.file_path FROM audio_transcriptions t "
            "JOIN audio_chunks c ON t.audio_chunk_id=c.id ORDER BY t.id DESC LIMIT 1;"})

        if not rows:
            self.skipTest("no transcriptions recorded yet")
        self.assertIsInstance(rows, list, f"raw_sql returned an error: {rows}")
        for column in ("id", "audio_chunk_id", "transcription", "timestamp",
                       "start_time", "end_time", "file_path"):
            self.assertIn(column, rows[0])

    def test_every_timestamp_matches_a_format_the_app_can_parse(self):
        rows = api_post("/raw_sql", {"query":
            "SELECT timestamp FROM audio_transcriptions ORDER BY id DESC LIMIT 200;"})

        if not rows:
            self.skipTest("no transcriptions recorded yet")
        unparseable = [r["timestamp"] for r in rows
                       if not (PLAIN.match(r["timestamp"]) or FRACTIONAL.match(r["timestamp"]))]
        self.assertEqual(unparseable, [], "timestamps the app would silently fail to parse")

    def test_health_reports_a_version_to_stamp_onto_turns(self):
        self.assertTrue(self.health.get("version"))

    def test_chunk_timestamp_is_the_chunk_start_not_the_write_time(self):
        # main.swift derives absolute audio time as chunk timestamp + start_time offset.
        # If screenpipe ever changed this to a write time, every turn boundary would shift.
        rows = api_post("/raw_sql", {"query":
            "SELECT t.timestamp t_ts, c.timestamp c_ts FROM audio_transcriptions t "
            "JOIN audio_chunks c ON t.audio_chunk_id=c.id ORDER BY t.id DESC LIMIT 20;"})

        if not rows:
            self.skipTest("no transcriptions recorded yet")
        mismatched = [r for r in rows if r["t_ts"] != r["c_ts"]]
        self.assertEqual(mismatched, [], "transcription timestamp no longer equals its chunk's")


if __name__ == "__main__":
    unittest.main()
