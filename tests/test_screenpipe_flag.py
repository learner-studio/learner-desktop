#!/usr/bin/env python3
"""Fast lane: Learner Desktop keeps screenpipe from waiting on a sign-in.

screenpipe skips its account check when SCREENPIPE_SKIP_ONBOARDING is in its
environment. A separate com.screenpipe.env LaunchAgent used to set it with
`launchctl setenv` at login, until macOS switched that agent off in Login Items (it
showed as "launchctl"). After the 2026-10-11 reboot screenpipe started signed out and
recorded nothing for ten days. The app, whose own login item is allowed, sets the flag
now and relaunches a screenpipe that started without it.
"""

import os
import unittest
from tests.swift_source import swift_source

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def method(src, signature):
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]


class ScreenpipeSignInFlagTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = swift_source()
        cls.ensure = method(cls.src, "func ensureScreenpipeSkipsSignIn(")

    def test_sets_the_flag_in_launchd_at_launch(self):
        launch = method(self.src, "func applicationDidFinishLaunching(")
        self.assertIn("setScreenpipeSkipFlag()", launch)
        setter = method(self.src, "func setScreenpipeSkipFlag(")
        self.assertIn('"setenv", "SCREENPIPE_SKIP_ONBOARDING", "1"', setter)

    def test_checks_each_screenpipe_launch_on_the_status_poll(self):
        self.assertIn("ensureScreenpipeSkipsSignIn()", method(self.src, "func updateAllStatuses("))
        # Once per screenpipe process, not every 8s.
        self.assertIn("screenpipeFlagCheckedPid", self.ensure)

    def test_only_relaunches_a_screenpipe_missing_the_flag(self):
        self.assertIn("includeEnvironment: true", self.ensure)
        self.assertLess(self.ensure.index('"SCREENPIPE_SKIP_ONBOARDING=1"'),
                        self.ensure.index("terminate()"))

    def test_leaves_a_screenpipe_alone_while_its_server_answers(self):
        # Signed out, screenpipe never starts its server. If it answers it is (or can be)
        # recording, and in 2.7.116 a Quit then only drops it to search-only mode: capture
        # stops and the process stays.
        self.assertLess(self.ensure.index("screenpipeServerResponds()"),
                        self.ensure.index("terminate()"))

    def test_reopens_a_screenpipe_that_did_not_exit(self):
        # Reopening is screenpipe's own way out of search-only mode ("Open Screenpipe to
        # use this feature"); it resumes recording.
        after = self.ensure[self.ensure.index("Did not quit"):]
        self.assertIn("openApplication(", after)

    def test_relaunches_with_the_flag_in_its_environment(self):
        self.assertIn('config.environment = ["SCREENPIPE_SKIP_ONBOARDING": "1"]', self.ensure)
        self.assertLess(self.ensure.index("terminate()"),
                        self.ensure.index("openApplication("))

    def test_never_signals_screenpipe(self):
        # screenpipe installs no SIGTERM handler; a signal can leave its database mid-write.
        for sig in ("SIGTERM", "SIGKILL"):
            self.assertNotIn(sig, self.ensure)

    def test_nothing_loads_the_old_env_agent(self):
        self.assertNotIn("com.screenpipe.env.plist", self.src)


if __name__ == "__main__":
    unittest.main()
