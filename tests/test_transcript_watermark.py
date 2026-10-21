#!/usr/bin/env python3
"""Fast lane: the coach must never replay transcription history as live speech.

Both transcript polls page forward with `id > watermark ORDER BY id ASC LIMIT 50`.
Until the watermark is set, that query returns the OLDEST rows. The background poll
used to initialise from `rows.last` of that page -- id 51 -- whenever screenpipe was not
answering when the coach started, then walked the coach through weeks of September
speech as if it were happening now (seen on 2026-10-21 after a screenpipe relaunch).
The live meeting poll already guarded against this by asking for MAX(id) first.
"""

import os
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def method(src, signature):
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]


class TranscriptWatermarkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        src = read(SWIFT)
        cls.tick = method(src, "func tick()")
        cls.live = method(src, "func checkLiveMeetingSegments()")

    def assert_initialises_from_max_id(self, body, table):
        self.assertIn(f"SELECT COALESCE(MAX(id), 0) AS id FROM {table} LIMIT 1;", body)
        # The ascending page is only requested once a watermark exists.
        page = body.index(f"FROM {table}")
        self.assertIn("Initialized", body[:page])
        self.assertNotIn("rows.last", body)

    def test_background_poll_initialises_from_max_id(self):
        self.assert_initialises_from_max_id(self.tick, "audio_transcriptions")

    def test_live_poll_initialises_from_max_id(self):
        self.assert_initialises_from_max_id(self.live, "meeting_transcript_segments")


if __name__ == "__main__":
    unittest.main()
