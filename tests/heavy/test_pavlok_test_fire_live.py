#!/usr/bin/env python3
"""Heavy lane: the manual test-fire command, against a compiler and against the wristband.

Two classes, two gates:

  AIAGG_HEAVY=1               compiles menu-bar-app/main.swift and checks that a
                              malformed `--pavlok-test-fire` is rejected before anything
                              touches the radio. Nothing fires.

  AIAGG_HEAVY=1 and
  AIAGG_HEAVY_DESTRUCTIVE=1   actually buzzes the owner's wristband, through the installed
                              app bundle, and reads the outcome back out of the app log.

The destructive class fires VIBRATION ONLY, and asserts as much. A test suite must never
be able to shock a person, so the zap path is deliberately not exercised here even under
the destructive gate -- fire that one by hand, from the menu, at a level you chose.

The live fire goes through the installed bundle rather than a freshly compiled binary
because macOS attributes a Bluetooth request to the *responsible* process: a binary run
straight from a shell inherits the terminal's TCC context, has no Bluetooth usage string,
and is killed by TCC on the spot. Launching the signed bundle with `open` makes it
responsible for itself, and the grant on the bundle applies.
"""

import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SWIFT_SRC = os.path.join(REPO, "menu-bar-app", "main.swift")
INSTALLED_APP = os.path.expanduser("~/Applications/Learner Desktop.app")
APP_LOG = os.path.expanduser("~/.ai-aggregator/logs/menubar.log")

HEAVY = os.environ.get("AIAGG_HEAVY") == "1"
DESTRUCTIVE = os.environ.get("AIAGG_HEAVY_DESTRUCTIVE") == "1"

DEFAULTS_DOMAIN = "com.benpollack.ai-aggregator-menubar"
ENABLED_KEY = "pavlok_shock_enabled"

# The level this suite is allowed to send. Vibration is harmless; this is here so that a
# careless edit to the constant below still cannot turn the suite into a shock.
LIVE_TEST_TYPE = "vibe"
LIVE_TEST_INTENSITY = 25


def read_default(key):
    r = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, key],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(shutil.which("swiftc"), "swiftc not installed")
class TestFireCommandRejectsBadInputTest(unittest.TestCase):
    """Every one of these invocations must die on the argument check. None of them
    reaches CoreBluetooth, which is why this class is safe without the destructive gate."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="pavlok-testfire-")
        cls.binary = os.path.join(cls.tmp, "ai-aggregator-testfire-heavy")
        build = subprocess.run(
            ["swiftc", "-o", cls.binary, SWIFT_SRC,
             "-framework", "Cocoa", "-framework", "ScreenCaptureKit",
             "-framework", "CoreBluetooth", "-lsqlite3"],
            capture_output=True, text=True, timeout=900, cwd=REPO)
        if build.returncode != 0:
            raise AssertionError(
                "menu-bar-app/main.swift does not compile:\n" + build.stderr[-2000:])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)
        # The standalone binary keys UserDefaults by its own name; do not leave a stray
        # domain behind with the shock feature armed in it.
        subprocess.run(["defaults", "delete", "ai-aggregator-testfire-heavy"],
                       capture_output=True, text=True)

    def run_cli(self, *args):
        return subprocess.run([self.binary, "--pavlok-test-fire", *args],
                              capture_output=True, text=True, timeout=60)

    def test_no_stimulus_type_is_refused(self):
        r = self.run_cli()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("usage:", r.stderr)

    def test_an_unknown_stimulus_type_is_refused(self):
        for bad in ("punch", "ZAPP", "shock", ""):
            r = self.run_cli(bad)
            self.assertEqual(r.returncode, 2, f"{bad!r} was accepted: {r.stderr}")

    def test_an_out_of_range_intensity_is_refused(self):
        for bad in ("0", "-5", "101", "1000", "banana"):
            r = self.run_cli("vibe", bad)
            self.assertEqual(r.returncode, 2, f"intensity {bad!r} was accepted")

    def test_a_bad_wait_is_refused(self):
        for bad in ("0", "-1", "999999", "soon"):
            r = self.run_cli("vibe", "20", "--wait", bad)
            self.assertEqual(r.returncode, 2, f"wait {bad!r} was accepted")

    def test_a_refused_invocation_never_reaches_the_radio(self):
        r = self.run_cli("punch")
        self.assertNotIn("Radio state", r.stdout)
        self.assertNotIn("Scanning", r.stdout)

    def test_the_usage_text_names_all_three_modalities(self):
        r = self.run_cli()
        for t in ("vibe", "beep", "zap"):
            self.assertIn(t, r.stderr)


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(DESTRUCTIVE,
                     "fires the owner's wristband: set AIAGG_HEAVY_DESTRUCTIVE=1")
@unittest.skipUnless(os.path.isdir(INSTALLED_APP),
                     "run scripts/build-app.sh first: no installed app bundle")
class TestFireReachesTheWristbandTest(unittest.TestCase):
    """One vibration, through the real transport, verified from the app's own log."""

    @classmethod
    def setUpClass(cls):
        cls.assertIsVibration()
        cls.enabled_before = read_default(ENABLED_KEY)
        cls.intensity_before = read_default(f"pavlok_test_{LIVE_TEST_TYPE}_intensity")
        cls.mark = os.path.getsize(APP_LOG) if os.path.exists(APP_LOG) else 0

        subprocess.run(
            ["open", "-n", "-a", INSTALLED_APP, "--args",
             "--pavlok-test-fire", LIVE_TEST_TYPE, str(LIVE_TEST_INTENSITY),
             "--wait", "20"],
            check=True, capture_output=True, text=True, timeout=60)

        cls.lines = cls.wait_for_verdict(timeout=75)

    @classmethod
    def assertIsVibration(cls):
        if LIVE_TEST_TYPE != "vibe":
            raise AssertionError(
                f"this suite may only fire vibration, not {LIVE_TEST_TYPE!r}")

    @classmethod
    def new_log_lines(cls):
        if not os.path.exists(APP_LOG):
            return []
        with open(APP_LOG, "rb") as fh:
            fh.seek(cls.mark)
            text = fh.read().decode("utf-8", "replace")
        return [ln for ln in text.splitlines() if "Pavlok" in ln]

    @classmethod
    def wait_for_verdict(cls, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            lines = cls.new_log_lines()
            if any("TestFire] DELIVERED" in ln or "TestFire] FAILED" in ln for ln in lines):
                return lines
            time.sleep(1.0)
        return cls.new_log_lines()

    def verdict_line(self):
        for ln in self.lines:
            if "TestFire] DELIVERED" in ln or "TestFire] FAILED" in ln:
                return ln
        self.fail("the test fire never reported a verdict:\n" + "\n".join(self.lines))

    def test_the_app_logged_the_request(self):
        self.assertTrue(any("TestFire] requested" in ln for ln in self.lines),
                        "the headless fire produced no log at all:\n" + "\n".join(self.lines))

    def test_only_a_vibration_was_sent(self):
        for ln in self.lines:
            self.assertNotIn("SHOCK DISPATCHED", ln)
            self.assertNotIn("Zap", ln)

    def test_the_stimulus_reached_the_wristband(self):
        line = self.verdict_line()
        self.assertIn("DELIVERED", line,
                      "the wristband did not take the stimulus. Wake the band, keep it in "
                      "range and discoverable, then re-run.\n"
                      + "\n".join(self.lines))

    def test_the_log_names_the_transport_that_carried_it(self):
        line = self.verdict_line()
        self.assertIn("BLE acknowledged by wristband", line)

    def test_it_fired_at_the_intensity_asked_for(self):
        line = self.verdict_line()
        self.assertRegex(line, rf"\b{LIVE_TEST_INTENSITY}%")

    def test_the_wearable_feature_is_left_as_it_was_found(self):
        self.assertEqual(read_default(ENABLED_KEY), self.enabled_before,
                         "the headless fire left pavlok_shock_enabled changed")

    def test_the_saved_test_intensity_is_left_as_it_was_found(self):
        self.assertEqual(read_default(f"pavlok_test_{LIVE_TEST_TYPE}_intensity"),
                         self.intensity_before)



@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
class InstalledBundleCanAskForBluetoothTest(unittest.TestCase):
    """Non-destructive: the bundle the live fire runs from must carry the usage strings,
    or macOS kills it the moment it creates a CBCentralManager."""

    def test_the_installed_bundle_declares_the_bluetooth_usage_strings(self):
        plist_path = os.path.join(INSTALLED_APP, "Contents", "Info.plist")
        if not os.path.exists(plist_path):
            self.skipTest("run scripts/build-app.sh first: no installed app bundle")
        with open(plist_path, "rb") as fh:
            info = plistlib.load(fh)
        for key in ("NSBluetoothAlwaysUsageDescription",
                    "NSBluetoothPeripheralUsageDescription"):
            self.assertTrue(str(info.get(key, "")).strip(), f"{key} is missing or empty")

    def test_the_build_script_still_produces_those_strings(self):
        with open(os.path.join(REPO, "scripts", "build-app.sh"), encoding="utf-8") as fh:
            build = fh.read()
        self.assertIn("NSBluetoothAlwaysUsageDescription", build)


if __name__ == "__main__":
    unittest.main()
