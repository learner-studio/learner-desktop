#!/usr/bin/env python3
"""Fast lane: Learner Desktop runs the SSH tunnel and the transcript watcher itself.

They used to be two /bin/bash LaunchAgents. macOS lists such agents in Login Items as
"bash" from an unknown developer; once they were switched off there, launchd stopped
starting them at login and both stayed down for ten days after the 2026-10-11 reboot.
As child processes of the app they share its one Login Items entry and start, stop and
restart with it.
"""

import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")
BUILD = os.path.join(REPO, "scripts", "build-app.sh")
TUNNEL = os.path.join(REPO, "scripts", "tunnel.sh")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def method(src, signature):
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]


def helper_class(src):
    start = src.index("final class ManagedHelper")
    return src[start:src.index("\n}\n", start) + 3]


class ManagedHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = read(SWIFT)
        cls.cls = helper_class(cls.src)

    def test_restarts_a_helper_that_exits_with_backoff(self):
        exited = method(self.cls, "private func exited(")
        self.assertIn("asyncAfter", exited)
        self.assertRegex(exited, r"min\(restartDelay \* 2, \d+\)")
        self.assertIn("terminationHandler", self.cls)

    def test_a_deliberate_stop_is_not_restarted(self):
        exited = method(self.cls, "private func exited(")
        self.assertLess(exited.index("stopping"), exited.index("asyncAfter"))

    def test_stop_escalates_to_sigkill_after_a_timeout(self):
        stop = method(self.cls, "func stop(")
        self.assertLess(stop.index("terminate()"), stop.index("SIGKILL"))
        self.assertIn("deadline", stop)

    def test_reaps_an_orphan_from_a_crashed_run_before_starting(self):
        # macOS has no parent-death signal: a crashed app leaves its helpers running,
        # holding the forwarded ports. The pid file lets the next launch stop them.
        start = method(self.cls, "func start(")
        self.assertLess(start.index("reapOrphan()"), start.index("launch()"))
        reap = method(self.cls, "private func reapOrphan(")
        # pids are reused: only kill a process whose command line is still ours.
        self.assertLess(reap.index("marker"), reap.index("kill("))

    def test_helper_output_goes_to_its_log_file(self):
        launch = method(self.cls, "private func launch(")
        self.assertIn("standardOutput", launch)
        self.assertIn("standardError", launch)


class AppOwnsHelpersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = read(SWIFT)

    def test_starts_tunnel_then_watcher_at_launch(self):
        body = method(self.src, "func applicationDidFinishLaunching(")
        self.assertLess(body.index("tunnel.start()"), body.index("watcher.start()"))

    def test_helpers_run_from_the_app_bundle_not_documents(self):
        for name in ("tunnel.sh", "learner-watcher.js"):
            line = next(ln for ln in self.src.splitlines() if f'"{name}"' in ln)
            self.assertIn("resourcePath", line, name)
            self.assertNotIn("/Documents/", line, name)

    def test_shutdown_stops_helpers_only_after_the_habit_flush(self):
        # The flush pushes rows over the tunnel; stopping it first strands them.
        body = self.src[self.src.index("func applicationShouldTerminate("):
                        self.src.index("@objc func quitApp()")]
        sync = body.index("syncHabitsToServer")
        watcher = body.index("watcher.stop(")
        tunnel = body.index("tunnel.stop(")
        self.assertLess(sync, watcher)
        self.assertLess(watcher, tunnel)
        # rindex: the first `return .terminateNow` is the re-entry guard at the top.
        self.assertLess(tunnel, body.rindex("return .terminateNow"))

    def test_restart_menu_item_restarts_the_helpers(self):
        body = method(self.src, "@objc func restartAggregatorServices(")
        self.assertIn("tunnel.restart()", body)
        self.assertIn("watcher.restart()", body)
        self.assertNotIn("launchctl", body)

    def test_nothing_refers_to_the_retired_agents(self):
        for label in ("ai-aggregator-tunnel", "ai-aggregator-watcher"):
            self.assertNotIn(label, self.src)


class BuildBundlesHelpersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = read(BUILD)

    def test_copies_the_tunnel_script_into_the_bundle(self):
        self.assertRegex(self.build,
                         r'cp .*scripts/tunnel\.sh" "\$\{BUNDLE_DIR\}/Contents/Resources/tunnel\.sh"')

    def test_compiles_the_watcher_into_one_file_in_the_bundle(self):
        # One self-contained file, so the app never runs code out of ~/Documents.
        self.assertRegex(self.build,
                         r'"\$\{BUN_BIN\}" build "\$\{PROJECT_DIR\}/src/cli\.ts" --target=bun '
                         r'--outfile "\$\{BUNDLE_DIR\}/Contents/Resources/learner-watcher\.js"')

    def test_signs_the_bundle_after_the_helpers_are_in_it(self):
        self.assertLess(self.build.index("learner-watcher.js"),
                        self.build.index('codesign --force --sign "${SIGN_IDENTITY}"'))

    def test_tunnel_forwards_hindsight_growthbook_and_postgres(self):
        tunnel = read(TUNNEL)
        for forward in ("18925:127.0.0.1:18925", "3200:127.0.0.1:3200", "15432:127.0.0.1:5432"):
            self.assertIn(forward, tunnel)


class LearnerDesktopNameTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = read(BUILD)
        cls.src = read(SWIFT)

    def test_bundle_is_named_learner_desktop(self):
        self.assertIn('APP_NAME="Learner Desktop.app"', self.build)
        self.assertRegex(self.build, r"<key>CFBundleName</key>\s*<string>Learner Desktop</string>")
        self.assertRegex(self.build, r"<key>CFBundleDisplayName</key>\s*<string>Learner Desktop</string>")
        self.assertRegex(self.build, r"<key>CFBundleExecutable</key>\s*<string>learner-desktop</string>")

    def test_bundle_identifier_is_unchanged(self):
        # TCC grants (Bluetooth) and the saved Pavlok settings in UserDefaults are keyed
        # to the bundle identifier; changing it would silently reset both.
        self.assertRegex(self.build,
                         r"<key>CFBundleIdentifier</key>\s*<string>com\.benpollack\.ai-aggregator-menubar</string>")

    def test_user_facing_text_uses_the_new_name(self):
        self.assertIn('"Quit Learner Desktop"', self.src)
        for old in ("AI Capture Suite", "AI Aggregator"):
            self.assertNotIn(old, self.src)
            self.assertNotIn(old, self.build)


if __name__ == "__main__":
    unittest.main()
