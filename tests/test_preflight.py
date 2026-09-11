#!/usr/bin/env python3
"""Fast lane: scripts/preflight-capture.sh.

SAFETY: never touches the real capture stack. HOME points at a throwaway directory
holding a synthetic store.bin, the expectations file is redirected with
PREFLIGHT_EXPECTED, and curl is a stub on a PATH searched first. Running preflight
against the live stack belongs in tests/heavy/test_preflight_live.py.
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PREFLIGHT = os.path.join(REPO, "scripts", "preflight-capture.sh")

HEALTHY = '{"status":"healthy","version":"0.4.50"}'
ROW_OK = '[{"id":1,"audio_chunk_id":2,"timestamp":"2026-09-09T00:00:00-04:00","start_time":0.5,"end_time":1.5,"file_path":"/x.mp4"}]'

BASELINE = {
    "transcriptionMode": "realtime",
    "audioChunkDuration": 5,
    "audioTranscriptionEngine": "whisper-large-v3-turbo-quantized",
    "autoUpdate": False,
}


def run_preflight(settings, expected=None, health=HEALTHY, rows=ROW_OK, pins=None):
    """Run the real script against a synthetic store.bin and a stubbed curl."""
    sandbox = tempfile.mkdtemp(prefix="preflight-")
    try:
        os.makedirs(os.path.join(sandbox, ".screenpipe"))
        with open(os.path.join(sandbox, ".screenpipe", "store.bin"), "w") as fh:
            json.dump({"settings": settings}, fh)

        exp_path = os.path.join(sandbox, "expected.json")
        with open(exp_path, "w") as fh:
            json.dump(dict(pins or {}, settings=BASELINE if expected is None else expected), fh)

        stub_bin = os.path.join(sandbox, "bin")
        os.makedirs(stub_bin)
        with open(os.path.join(stub_bin, "curl"), "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                f'case "$*" in\n'
                f'  *raw_sql*) printf %s {json.dumps(rows)} ;;\n'
                f'  *) printf %s {json.dumps(health)} ;;\n'
                "esac\n"
            )
        os.chmod(os.path.join(stub_bin, "curl"), 0o755)

        env = dict(os.environ)
        env.update(HOME=sandbox, PREFLIGHT_EXPECTED=exp_path,
                   PATH=stub_bin + os.pathsep + env["PATH"])
        return subprocess.run([PREFLIGHT], capture_output=True, text=True, env=env, timeout=60)
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


class PreflightTest(unittest.TestCase):
    def test_passes_when_live_settings_match_the_committed_expectations(self):
        result = run_preflight(dict(BASELINE))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fails_when_transcription_silently_reverts_to_batch(self):
        # Batch is screenpipe's #[default]; a reset reintroduces deferred transcription.
        drifted = dict(BASELINE, transcriptionMode="batch")
        result = run_preflight(drifted)

        self.assertEqual(result.returncode, 1)
        self.assertIn("transcriptionMode", result.stdout)
        self.assertIn("batch", result.stdout)

    def test_fails_when_a_guarded_setting_disappears(self):
        missing = {k: v for k, v in BASELINE.items() if k != "audioChunkDuration"}
        result = run_preflight(missing)

        self.assertEqual(result.returncode, 1)
        self.assertIn("audioChunkDuration", result.stdout)

    def test_reports_unreachable_screenpipe_separately_from_drift(self):
        result = run_preflight(dict(BASELINE), health="")

        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("not answering", result.stdout)

    def test_fails_when_the_raw_sql_shape_the_app_polls_breaks(self):
        result = run_preflight(dict(BASELINE), rows='{"error":"no such column: start_time"}')

        self.assertEqual(result.returncode, 1)
        self.assertIn("raw_sql", result.stdout)

    def test_fails_when_the_engine_version_moves_off_the_pin(self):
        # The vendor force-enables auto-update via remote policy, so the flag cannot be
        # trusted; a version change is the instrument changing and must fail loudly.
        result = run_preflight(dict(BASELINE), pins={"_screenpipe_engine_version": "0.4.49"})

        self.assertEqual(result.returncode, 1)
        self.assertIn("version changed", result.stdout)
        self.assertIn("phase boundary", result.stdout)

    def test_passes_when_the_engine_version_matches_the_pin(self):
        result = run_preflight(dict(BASELINE), pins={"_screenpipe_engine_version": "0.4.50"})

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_ignores_redacted_expectations_rather_than_reporting_drift(self):
        expected = dict(BASELINE, deepgramApiKey="***REDACTED***")
        result = run_preflight(dict(BASELINE, deepgramApiKey="a-real-key"))

        self.assertEqual(run_preflight(dict(BASELINE), expected=expected).returncode, 0)
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
