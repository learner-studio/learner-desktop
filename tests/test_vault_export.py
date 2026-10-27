#!/usr/bin/env python3
"""Fast lane: VaultExport recognises ai-vault's failures.

ai-vault exits 0 even when its summary lists errors. From 10-23 to 10-27 the menu said
"claude: ok" while every run failed with "Organization ID not available" or a 401, and
nothing new was exported. The samples below are from those runs' logs.
"""

import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")


def pattern(name):
    with open(SWIFT, encoding="utf-8") as fh:
        return re.search(rf'static let {name} = "([^"]+)"', fh.read()).group(1)


EXPIRED = [
    "Authentication failed\nYour session cookies appear to be expired or invalid.",
    "Errors: 1\n  • Archive process failed: Organization ID not available. Authentication may have failed.",
    "Errors: 1\n  • Archive process failed: page.evaluate: Error: API request failed: 401 ",
]
FAILED = "Errors: 2\n  • Archive process failed: net::ERR_INTERNET_DISCONNECTED\n\nCompleted with 2 errors"
OK = "Conversations:\n  Archived: 3\n\nErrors: 0\n\nCompleted in 40.2s"


class VaultExportOutcomeTest(unittest.TestCase):
    def test_expired_logins_are_recognised(self):
        for sample in EXPIRED:
            self.assertRegex(sample, pattern("loginExpiredPattern"))

    def test_other_errors_are_failures_not_ok(self):
        self.assertNotRegex(FAILED, pattern("loginExpiredPattern"))
        self.assertRegex(FAILED, pattern("failedPattern"))

    def test_a_clean_run_is_ok(self):
        self.assertNotRegex(OK, pattern("loginExpiredPattern"))
        self.assertNotRegex(OK, pattern("failedPattern"))


if __name__ == "__main__":
    unittest.main()
