#!/usr/bin/env python3
"""Heavy lane: run scripts/preflight-capture.sh against the real capture stack.

Read-only — preflight only reads settings and issues GET/SELECT. Skips when the
heavy lane is not requested or screenpipe is not listening.
"""

import json
import os
import subprocess
import unittest
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PREFLIGHT = os.path.join(REPO, "scripts", "preflight-capture.sh")
API = os.environ.get("SCREENPIPE_API", "http://localhost:3030")


def screenpipe_health():
    try:
        with urllib.request.urlopen(f"{API}/health", timeout=5) as resp:
            return json.load(resp)
    except Exception:
        return None


@unittest.skipUnless(os.environ.get("AIAGG_HEAVY") == "1", "heavy lane not requested")
class PreflightLiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.health = screenpipe_health()
        if cls.health is None:
            raise unittest.SkipTest(f"screenpipe is not listening on {API}")

    def test_live_capture_stack_matches_the_committed_expectations(self):
        result = subprocess.run([PREFLIGHT], capture_output=True, text=True, timeout=120)

        self.assertEqual(
            result.returncode, 0,
            "preflight reported drift against config/screenpipe-settings.json:\n"
            + result.stdout + result.stderr,
        )

    def test_engine_reports_the_version_stamped_onto_turns(self):
        # main.swift copies this into metadata.screenpipe_version for every turn.
        self.assertTrue(self.health.get("version"), "screenpipe /health reported no version")


if __name__ == "__main__":
    unittest.main()
