#!/usr/bin/env python3
"""Heavy lane: the Pavlok stimulus wire protocol, end to end through the Swift app.

Opt-in. Needs AIAGG_HEAVY=1 (scripts/test.sh heavy sets it) and swiftc. Compiles
menu-bar-app/main.swift, runs it under --test-pavlok-e2e against a mock Pavlok v5
server on an ephemeral port, and checks what actually went over the wire.

This device delivers an electric shock to a person, so the assertions here are
safety invariants, not a snapshot: no stimulus without a verified token, no zap
above a hard intensity ceiling, and nothing at all sent when intensity is 0.

Rewritten from the old tests/test_pavlok_e2e.py, which was a probe:
  * it asserted `len(recorded_requests) == 13` and then indexed requests 0..12 by
    hand, so adding one stimulus anywhere in the Swift harness broke ~15 assertions;
  * its final "security audit" ran `defaults read com.benpollack.ai-aggregator
    pavlok_shock_enabled`, asserting the state of whoever's Mac ran the suite rather
    than anything about the code -- it would fail the moment the owner legitimately
    enabled the feature.
The behavioural assertions (streak flags, debouncing, reset) live in the Swift
harness itself and are enforced here by its exit code.

KNOWN FAILING as of 2026-09-09, in the Swift side, not here. runPavlokE2ETests()
reaches "[TEST 2] Verifying Live Stimulus Delivery over HTTP", prints the Cloud API
fallback line, and then aborts (SIGABRT) on
    assert(wait2 == .success, "FAIL: Timed out waiting for mock server response")
without a single request ever reaching the mock -- not the stimulus POST, and not
the GET /api/v5/user that PavlokController.updateConnectionStatus() should fire when
`isEnabled = true` is set at main.swift:3295. A minimal Cocoa binary doing the same
URLSession POST to the same mock succeeds, so it is not ATS, the port, or the
sandbox. Suspect the CBCentralManager started by the isEnabled setter
(main.swift:~186 -> startBleScan(force: true)) stalling the main thread that the
semaphore then waits on. The old test could not have passed either; it asserted
`len(recorded_requests) == 13` against the same zero-traffic run.

These tests are left failing on purpose: they encode the contract the Swift harness
is supposed to meet, and they will pass once it delivers over HTTP again.
"""

import http.server
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SWIFT_SRC = os.path.join(REPO, "menu-bar-app", "main.swift")

HEAVY = os.environ.get("AIAGG_HEAVY") == "1"

# A shock above this is a physical-harm bug regardless of what the app was
# configured to send. This is a ceiling, not the expected value.
MAX_SAFE_ZAP = 50

# UserDefaults keys the harness writes are scoped by the executable's name.
BINARY_NAME = "ai-aggregator-pavlok-e2e"


def _clear_defaults_domain():
    subprocess.run(["defaults", "delete", BINARY_NAME],
                   capture_output=True, text=True)


class MockPavlok(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *args):
        pass

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.requests.append({"method": "GET", "path": self.path,
                              "auth": self.headers.get("Authorization", "")})
        if self.path.startswith("/api/v5/user"):
            self._json(200, {"user": {"id": "usr_test", "device": {"name": "Pavlok 3"}}})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = json.loads(raw.decode())
        except ValueError:
            body = None
        self.requests.append({"method": "POST", "path": self.path,
                              "auth": self.headers.get("Authorization", ""),
                              "content_type": self.headers.get("Content-Type", ""),
                              "body": body})
        if self.path == "/api/v5/stimulus/send":
            self._json(200, {"status": "success",
                             "stimulus": (body or {}).get("stimulus", {})})
        else:
            self.send_response(404)
            self.end_headers()


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(shutil.which("swiftc"), "swiftc not installed")
class PavlokWireProtocolTest(unittest.TestCase):
    """One compile + one run; every test reads the captured traffic."""

    @classmethod
    def setUpClass(cls):
        MockPavlok.requests = []
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MockPavlok)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

        cls.tmp = tempfile.mkdtemp(prefix="pavlok-e2e-")
        binary = os.path.join(cls.tmp, BINARY_NAME)
        # The harness writes its Pavlok config (including pavlok_shock_enabled=1 and
        # a mock URL with last run's port) into UserDefaults, keyed by the binary
        # name and persisted across runs. Wipe it so each run starts clean and so we
        # do not leave the shock feature armed in a stray domain.
        _clear_defaults_domain()
        build = subprocess.run(
            ["swiftc", "-o", binary, SWIFT_SRC,
             "-framework", "Cocoa", "-framework", "ScreenCaptureKit",
             "-framework", "CoreBluetooth"],
            capture_output=True, text=True, timeout=600, cwd=REPO)
        if build.returncode != 0:
            raise unittest.SkipTest(
                "menu-bar-app/main.swift does not compile:\n" + build.stderr[-2000:])

        endpoint = f"http://127.0.0.1:{cls.port}/api/v5/stimulus/send"
        cls.proc = subprocess.run([binary, "--test-pavlok-e2e", endpoint],
                                 capture_output=True, text=True, timeout=120)
        cls.server.shutdown()
        cls.traffic = list(MockPavlok.requests)

    @classmethod
    def tearDownClass(cls):
        cls.server.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)
        # Never leave pavlok_shock_enabled=1 behind in a stray defaults domain.
        _clear_defaults_domain()

    def stimuli(self):
        return [r["body"]["stimulus"] for r in self.traffic
                if r["method"] == "POST" and r.get("body", {}).get("stimulus")]

    def test_the_swift_harness_own_assertions_pass(self):
        self.assertEqual(self.proc.returncode, 0,
                         f"--test-pavlok-e2e failed:\n{self.proc.stdout[-3000:]}"
                         f"\n{self.proc.stderr[-2000:]}")

    def test_the_run_actually_delivered_stimuli(self):
        """Guards against a silent no-op run making every check below vacuous."""
        self.assertGreater(len(self.stimuli()), 0, "no stimulus reached the mock")

    def test_the_token_is_verified_before_any_stimulus_is_sent(self):
        posts = [i for i, r in enumerate(self.traffic) if r["method"] == "POST"]
        verified = [i for i, r in enumerate(self.traffic)
                    if r["method"] == "GET" and r["path"].startswith("/api/v5/user")]
        self.assertTrue(posts, "no stimulus was sent at all")
        self.assertTrue(verified, "never verified the API token")
        self.assertLess(verified[0], posts[0],
                        "sent a stimulus before validating the token")

    def test_every_request_carries_the_same_non_empty_auth_token(self):
        self.assertTrue(self.traffic, "no request reached the mock")
        tokens = {r["auth"] for r in self.traffic}
        self.assertEqual(len(tokens), 1, f"inconsistent Authorization headers: {tokens}")
        self.assertTrue(tokens.pop().strip(), "Authorization header was empty")

    def test_every_stimulus_post_is_well_formed_json_on_the_v5_path(self):
        posts = [r for r in self.traffic if r["method"] == "POST"]
        for r in posts:
            self.assertEqual(r["path"], "/api/v5/stimulus/send")
            self.assertEqual(r["content_type"], "application/json")
            self.assertIsInstance(r["body"], dict)
            self.assertIn("stimulus", r["body"])

    def test_stimulus_payloads_stay_inside_the_documented_v5_schema(self):
        for s in self.stimuli():
            self.assertIn(s.get("stimulusType"), ("zap", "vibe"), s)
            value = s.get("stimulusValue")
            self.assertIsInstance(value, int, s)
            self.assertGreaterEqual(value, 0, s)
            self.assertLessEqual(value, 100, s)
            self.assertTrue(str(s.get("reason", "")).strip(),
                            f"stimulus with no reason: {s}")

    def test_no_zap_exceeds_the_safe_intensity_ceiling(self):
        zaps = [s["stimulusValue"] for s in self.stimuli()
                if s.get("stimulusType") == "zap"]
        self.assertTrue(zaps, "no zap was exercised")
        self.assertLessEqual(max(zaps), MAX_SAFE_ZAP,
                             f"zap intensities {sorted(set(zaps))} exceed the "
                             f"{MAX_SAFE_ZAP}% physical-safety ceiling")

    def test_zero_intensity_never_reaches_the_wire(self):
        """0% means 'off'. Sending a 0-value stimulus would still buzz the device."""
        zero = [s for s in self.stimuli() if s.get("stimulusValue") == 0]
        self.assertEqual(zero, [], f"0%-intensity stimuli were dispatched: {zero}")


if __name__ == "__main__":
    unittest.main()
