#!/usr/bin/env python3
"""Heavy lane, DESTRUCTIVE: a real stop/start cycle of the capture stack.

!! This test tears down the owner's live capture stack: it boots out the three
!! KeepAlive LaunchAgents and quits screenpipe, then brings them back. While it
!! runs, nothing is being recorded. Do not run it during a call.

It is double-gated and never runs by default:
    AIAGG_HEAVY=1              -- set by scripts/test.sh heavy
    AIAGG_HEAVY_DESTRUCTIVE=1  -- you must set this yourself, deliberately

    AIAGG_HEAVY=1 AIAGG_HEAVY_DESTRUCTIVE=1 \
      python3 -m unittest discover -s tests/heavy -p 'test_capture_scripts_live.py'

Everything else about these scripts -- ordering, flags, flush behaviour, teardown
escalation -- is covered hermetically in the fast lane
(tests/test_capture_scripts.py), which stubs every state-changing command. Only the
one thing that cannot be faked lives here: that launchd actually lets go of a
KeepAlive job and that the stack comes back afterwards.
"""

import os
import subprocess
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STOP = os.path.join(REPO, "scripts", "stop-capture.sh")
START = os.path.join(REPO, "scripts", "start-capture.sh")

LABELS = ["com.benpollack.ai-aggregator-app",
          "com.benpollack.ai-aggregator-watcher",
          "com.benpollack.ai-aggregator-tunnel"]

GATED = (os.environ.get("AIAGG_HEAVY") == "1"
         and os.environ.get("AIAGG_HEAVY_DESTRUCTIVE") == "1")


def loaded(label):
    return subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{label}"],
                          capture_output=True).returncode == 0


def wait_for(predicate, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(2)
    return predicate()


@unittest.skipUnless(GATED, "destructive: set AIAGG_HEAVY=1 AIAGG_HEAVY_DESTRUCTIVE=1")
class CaptureStackCycleTest(unittest.TestCase):
    """Stop the stack, prove it is really down, start it, prove it is really back."""

    @classmethod
    def setUpClass(cls):
        cls.was_loaded = [l for l in LABELS if loaded(l)]
        if not cls.was_loaded:
            raise unittest.SkipTest(
                "capture stack is not running; nothing to stop. Start it first.")

    @classmethod
    def tearDownClass(cls):
        # Whatever happened above, put the machine back the way we found it.
        subprocess.run([START], cwd=REPO, capture_output=True, timeout=300)

    def test_stop_then_start_returns_the_stack_to_its_original_state(self):
        stop = subprocess.run([STOP, "--keep-screenpipe"], cwd=REPO,
                              capture_output=True, text=True, timeout=600)
        self.assertEqual(stop.returncode, 0, stop.stdout + stop.stderr)

        # KeepAlive=true means launchd respawns anything merely killed. Give it a
        # generous window to prove it does NOT come back on its own.
        time.sleep(10)
        still_up = [l for l in self.was_loaded if loaded(l)]
        self.assertEqual(still_up, [],
                         f"KeepAlive jobs survived stop-capture.sh: {still_up}")

        start = subprocess.run([START, "--no-screenpipe"], cwd=REPO,
                               capture_output=True, text=True, timeout=600)
        self.assertEqual(start.returncode, 0, start.stdout + start.stderr)

        missing = [l for l in self.was_loaded
                   if not wait_for(lambda l=l: loaded(l))]
        self.assertEqual(missing, [],
                         f"start-capture.sh did not bring back: {missing}")


if __name__ == "__main__":
    unittest.main()
