#!/usr/bin/env python3
"""Fast lane: the static contract behind clean shutdown.

The live quit/crash cycle is in tests/heavy/test_clean_shutdown_live.py (destructive,
opt-in). These guard the pieces that make it work and that are easy to regress by hand:
the committed LaunchAgent plist, and the app never touching ~/Documents on its automatic
sync path (which, with an ad-hoc-signed binary, re-prompts for access after every build).
"""

import os
import plistlib
import re
import unittest
from tests.swift_source import swift_source

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PLIST = os.path.join(REPO, "menu-bar-app", "com.benpollack.learner-desktop.plist")
BUILD = os.path.join(REPO, "scripts", "build-app.sh")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class LaunchAgentPlistTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(PLIST, "rb") as fh:
            cls.plist = plistlib.load(fh)

    def test_restarts_only_after_a_crash_not_after_a_clean_quit(self):
        # KeepAlive=true resurrects the app after ANY exit, turning Quit into a restart
        # button. SuccessfulExit=false restarts only on a non-zero exit.
        self.assertEqual(self.plist["KeepAlive"], {"SuccessfulExit": False})

    def test_starts_at_login(self):
        self.assertTrue(self.plist["RunAtLoad"])

    def test_launches_the_installed_bundle_binary(self):
        self.assertEqual(
            self.plist["ProgramArguments"],
            ["/Users/benpollack/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop"],
        )

    def test_label_matches_what_the_scripts_boot_out(self):
        label = self.plist["Label"]
        for script in ("stop-capture.sh", "start-capture.sh", "build-app.sh"):
            self.assertIn(label, read(os.path.join(REPO, "scripts", script)), script)


class AutomaticSyncStaysOutOfDocumentsTest(unittest.TestCase):
    """The habit sync runs unattended every 8s and at shutdown. If it reads anything
    under ~/Documents, macOS prompts for access -- and, because the binary is ad-hoc
    signed, prompts again after every rebuild."""

    def test_upload_never_touches_documents_or_a_database_credential(self):
        # Habit rows go out over HTTPS from the app itself (OutboxSender); no bun
        # script, no .env with a Postgres password, nothing read from ~/Documents.
        src = swift_source()
        start = src.index("enum LearnerAPI")
        body = src[start:src.index("// MARK: - Bundled Helpers")]
        self.assertNotIn("/Documents/", body)
        self.assertNotIn("bun", body)
        self.assertNotIn(".env", read(BUILD))

    def test_build_reregisters_the_agent_only_when_the_plist_changed(self):
        # Re-registering (bootstrap) is what triggers macOS's "App Background Activity"
        # notification; a plain restart (kickstart) does not.
        build = read(BUILD)
        self.assertIn("cmp -s", build)
        self.assertIn("kickstart -k", build)
        self.assertIn("launchctl bootstrap", build)


class NoUnrequestedPrivacyPromptsTest(unittest.TestCase):
    """Each TCC prompt (Bluetooth, Documents) is re-asked after every rebuild because the
    binary is ad-hoc signed. So the app must not touch a protected resource unless the
    feature that needs it is actually on."""

    def test_build_signs_with_a_stable_apple_identity_not_ad_hoc(self):
        # TCC keys its grants to the designated requirement, which for an ad-hoc
        # signature (-) is the code hash and changes every build.
        build = read(BUILD)
        self.assertRegex(build, r'SIGN_IDENTITY="Apple Development: [^"]+ \([A-Z0-9]{10}\)"')
        self.assertRegex(build, r'codesign --force --sign "\$\{SIGN_IDENTITY\}"')
        self.assertIn('codesign --verify --strict', build)

    def test_bluetooth_is_not_initialised_until_pavlok_is_enabled(self):
        src = swift_source()
        init_start = src.index("class PavlokController")
        init_body = src[init_start:src.index("func startBleScan(", init_start)]

        # Creating a CBCentralManager is the act that triggers the Bluetooth prompt.
        self.assertNotIn("CBCentralManager(", init_body,
                         "CBCentralManager is created in init, before Pavlok is known to be enabled")
        self.assertEqual(src.count("CBCentralManager(delegate:"), 1)
        scan = src[src.index("func startBleScan("):src.index("func disconnectBle(")]
        self.assertIn("CBCentralManager(delegate:", scan)


class ShutdownSequenceTest(unittest.TestCase):
    def test_every_exit_path_reaches_the_terminate_delegate(self):
        src = swift_source()
        # SIGTERM (launchctl bootout / kickstart -k / stop-capture.sh) and SIGINT are
        # routed into NSApplication.terminate so they take the same path as menu Quit.
        self.assertRegex(src, r"for sig in \[SIGTERM, SIGINT\]")
        self.assertIn("DispatchSource.makeSignalSource", src)
        self.assertIn("func applicationShouldTerminate(", src)

    def test_shutdown_flushes_then_closes_in_that_order(self):
        src = swift_source()
        body = src[src.index("func applicationShouldTerminate("):src.index("@objc func quitApp()")]
        finalise = body.index("resetStreak()")
        wait_idle = body.index("waitUntilIdle()")
        sync = body.index("OutboxSender.shared.drain(")
        close = body.index("logger.close()")

        self.assertLess(finalise, wait_idle)
        self.assertLess(wait_idle, sync)
        self.assertLess(sync, close)
        self.assertIn("return .terminateNow", body)

    def test_shutdown_is_bounded_so_quit_cannot_hang(self):
        src = swift_source()
        body = src[src.index("func applicationShouldTerminate("):src.index("@objc func quitApp()")]
        self.assertRegex(body, r"drain\(until: Date\(\)\.addingTimeInterval\((\d|1\d)\)\)")


if __name__ == "__main__":
    unittest.main()
