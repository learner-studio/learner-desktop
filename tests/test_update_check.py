#!/usr/bin/env python3
"""Fast lane: a screenpipe update starts a logged, fenced-in Claude Code session.

screenpipe updates itself and has broken this setup on update before (2.7.34 added an
account sign-in; 2.7.116 converted the database and came back with capture off), and each
version is a new phase of the experiment. Learner Desktop therefore starts a fresh headless
session that follows docs/screenpipe-update-runbook.md whenever the installed version
changes, and logs every run.
"""

import json
import os
import re
import unittest
from tests.swift_source import swift_source

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
AGENT = os.path.join(REPO, "config", "screenpipe-update-agent.json")
RUNBOOK = os.path.join(REPO, "docs", "screenpipe-update-runbook.md")
PHASE = os.path.join(REPO, "scripts", "start-capture-phase.py")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def method(src, signature):
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]


class TriggerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = swift_source()
        start = cls.src.index("final class ScreenpipeUpdateCheck")
        cls.cls = cls.src[start:cls.src.index("\n}\n", start) + 3]
        cls.observe = method(cls.cls, "func observe(")

    def test_runs_on_the_status_poll(self):
        self.assertIn("ScreenpipeUpdateCheck.shared.observe(", method(self.src, "func updateAllStatuses("))

    def test_first_sighting_is_a_baseline_not_a_run(self):
        baseline = self.observe[:self.observe.index("guard appVersion != handled")]
        self.assertIn("saveHandled(appVersion)", baseline)
        self.assertNotIn("start(", baseline)

    def test_waits_for_the_version_to_settle(self):
        settle = float(re.search(r"static let settleSeconds: TimeInterval = (\d+)", self.cls).group(1))
        self.assertGreaterEqual(settle, 300)
        self.assertLess(self.observe.index("settleSeconds"), self.observe.index("start("))

    def test_runs_once_per_version_and_never_twice_at_once(self):
        self.assertLess(self.observe.index("saveHandled(appVersion)\n        start("),
                        len(self.observe))
        self.assertIn("guard running == nil", method(self.cls, "func start("))
        self.assertIn("guard running == nil", self.observe)

    def test_starts_a_fresh_fenced_headless_session_in_the_repo(self):
        start = method(self.cls, "func start(")
        for arg in ('"-p"', '"--settings"', "config/screenpipe-update-agent.json",
                    '"--max-budget-usd"', '"stream-json"', "docs/screenpipe-update-runbook.md"):
            self.assertIn(arg, start + self.cls[:self.cls.index("func start(")], arg)
        self.assertIn("currentDirectoryURL", start)
        self.assertNotIn('"--resume"', start)
        self.assertIn("timeoutSeconds", start)

    def test_uses_a_saved_long_lived_token_without_logging_it(self):
        # An interactive login lives in a keychain slot keyed by $USER and can expire
        # between updates (it had, by 2026-10-22). A `claude setup-token` token does not.
        start = method(self.cls, "func start(")
        self.assertIn("tokenPath", start)
        self.assertIn('env["CLAUDE_CODE_OAUTH_TOKEN"]', start)
        for line in start.splitlines():
            if "print(" in line:
                self.assertNotIn("token", line.lower(), line)

    def test_status_line_is_found_anywhere_in_the_report(self):
        # The first live run opened with a one-line summary and put STATUS: OK on line 3.
        finished = method(self.cls, "private func finished(")
        self.assertRegex(finished, r'first\(where: \{ \$0\.hasPrefix\("STATUS:"\) \}\)')

    def test_a_failed_run_says_why(self):
        finished = method(self.cls, "private func finished(")
        self.assertIn('"is_error"', finished)
        self.assertIn("STATUS: RUN FAILED", finished)

    def test_logs_every_run(self):
        start = method(self.cls, "func start(")
        finished = method(self.cls, "private func finished(")
        self.assertIn("logs/screenpipe-update-checks", self.cls)
        self.assertIn("index.log", self.cls)
        self.assertIn("[UpdateCheck]", start)
        for piece in ('.md"', "appendIndex(", "session_id", "total_cost_usd", "[UpdateCheck]"):
            self.assertIn(piece, finished, piece)


class PhaseTagTest(unittest.TestCase):
    def test_every_turn_carries_the_capture_phase(self):
        src = swift_source()
        self.assertIn('"capture_phase": CaptureEnvironment.capturePhase', src)
        self.assertIn('"screenpipe_app_version": CaptureEnvironment.screenpipeAppVersion', src)

    def test_turn_tag_matches_the_growthbook_phase_name(self):
        swift = re.search(r'return "(screenpipe \\\(app\) / engine \\\(engine\))"', swift_source())
        python = re.search(r'return f"(screenpipe \{app\} / engine \{engine\})"', read(PHASE))
        self.assertTrue(swift and python)
        self.assertEqual(swift.group(1).replace("\\(", "{").replace(")", "}"), python.group(1))


class AgentFenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.perms = json.loads(read(AGENT))["permissions"]
        cls.runbook = read(RUNBOOK)

    def test_no_blanket_shell_or_edit_access(self):
        for rule in ("Bash", "Bash(*)", "Bash(:*)", "Edit", "Write"):
            self.assertNotIn(rule, self.perms["allow"])
        for rule in ("Bash(kill:*)", "Bash(pkill:*)", "Bash(rm:*)", "Bash(git push:*)", "Edit", "Write"):
            self.assertIn(rule, self.perms["deny"])

    def test_every_fix_in_the_runbook_is_permitted(self):
        for command in ("launchctl setenv SCREENPIPE_SKIP_ONBOARDING 1",
                        "open -g -a /Applications/screenpipe.app",
                        "./scripts/preflight-capture.sh",
                        "git add config/screenpipe-settings.json"):
            self.assertIn(command, self.runbook)
            self.assertIn(f"Bash({command})", self.perms["allow"])
        self.assertIn("python3 scripts/start-capture-phase.py", self.runbook)
        self.assertIn("Bash(python3 scripts/start-capture-phase.py:*)", self.perms["allow"])

    def test_can_read_the_logs_it_is_told_to_check(self):
        dirs = self.perms["additionalDirectories"]
        self.assertTrue(any(d.endswith("/.screenpipe") for d in dirs))
        self.assertTrue(any(d.endswith("/.ai-aggregator") for d in dirs))

    def test_runbook_report_and_hard_limits(self):
        for status in ("STATUS: OK", "STATUS: FIXED", "STATUS: NEEDS ATTENTION"):
            self.assertIn(status, self.runbook)
        self.assertIn("Signal screenpipe", self.runbook)
        self.assertIn("Never read transcript or screen", self.runbook)


if __name__ == "__main__":
    unittest.main()
