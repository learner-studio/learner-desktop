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

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PLIST = os.path.join(REPO, "menu-bar-app", "com.benpollack.ai-aggregator-app.plist")
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")
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
            ["/Users/benpollack/Applications/AI Aggregator.app/Contents/MacOS/ai-aggregator-menubar"],
        )

    def test_label_matches_what_the_scripts_boot_out(self):
        label = self.plist["Label"]
        for script in ("stop-capture.sh", "start-capture.sh", "build-app.sh"):
            self.assertIn(label, read(os.path.join(REPO, "scripts", script)), script)


class AutomaticSyncStaysOutOfDocumentsTest(unittest.TestCase):
    """The habit sync runs unattended every 8s and at shutdown. If it reads anything
    under ~/Documents, macOS prompts for access -- and, because the binary is ad-hoc
    signed, prompts again after every rebuild."""

    def test_sync_process_runs_from_the_runtime_dir(self):
        src = read(SWIFT)
        start = src.index("func syncHabitsToServer(")
        body = src[start:src.index("\n}\n", start)]

        self.assertNotIn("/Documents/", body)
        self.assertIn(".ai-aggregator", body)

    def test_build_installs_the_sync_script_and_env_into_the_runtime_dir(self):
        build = read(BUILD)

        self.assertRegex(build, r'RUNTIME_DIR="\$\{HOME\}/\.ai-aggregator"')
        self.assertRegex(build, r'cp .*src/sync-habits\.ts" "\$\{RUNTIME_DIR\}/sync-habits\.ts"')
        self.assertRegex(build, r'cp .*\.env" "\$\{RUNTIME_DIR\}/\.env"')
        self.assertIn('chmod 600 "${RUNTIME_DIR}/.env"', build)

    def test_build_reregisters_the_agent_only_when_the_plist_changed(self):
        # Re-registering (bootstrap) is what triggers macOS's "App Background Activity"
        # notification; a plain restart (kickstart) does not.
        build = read(BUILD)
        self.assertIn("cmp -s", build)
        self.assertIn("kickstart -k", build)
        self.assertIn("launchctl bootstrap", build)


class ShutdownSequenceTest(unittest.TestCase):
    def test_every_exit_path_reaches_the_terminate_delegate(self):
        src = read(SWIFT)
        # SIGTERM (launchctl bootout / kickstart -k / stop-capture.sh) and SIGINT are
        # routed into NSApplication.terminate so they take the same path as menu Quit.
        self.assertRegex(src, r"for sig in \[SIGTERM, SIGINT\]")
        self.assertIn("DispatchSource.makeSignalSource", src)
        self.assertIn("func applicationShouldTerminate(", src)

    def test_shutdown_flushes_then_closes_in_that_order(self):
        src = read(SWIFT)
        body = src[src.index("func applicationShouldTerminate("):src.index("@objc func quitApp()")]
        finalise = body.index("resetStreak()")
        wait_idle = body.index("waitUntilIdle()")
        sync = body.index("syncHabitsToServer")
        close = body.index("logger.close()")

        self.assertLess(finalise, wait_idle)
        self.assertLess(wait_idle, sync)
        self.assertLess(sync, close)
        self.assertIn("return .terminateNow", body)

    def test_shutdown_is_bounded_so_quit_cannot_hang(self):
        src = read(SWIFT)
        body = src[src.index("func applicationShouldTerminate("):src.index("@objc func quitApp()")]
        self.assertIn("deadline", body)
        self.assertIn("attempts < 30", body)


if __name__ == "__main__":
    unittest.main()
