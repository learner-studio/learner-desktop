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

    def test_a_rate_limit_retries_soon_rather_than_in_six_hours(self):
        with open(SWIFT, encoding="utf-8") as fh:
            src = fh.read()
        self.assertIn('output.contains("API request failed: 429")', src)
        self.assertIn("Date().addingTimeInterval(VaultExport.rateLimitRetry)", src)
        # 429 is not an expired login.
        self.assertNotRegex("API request failed: 429", pattern("loginExpiredPattern"))

    def test_a_clean_run_is_ok(self):
        self.assertNotRegex(OK, pattern("loginExpiredPattern"))
        self.assertNotRegex(OK, pattern("failedPattern"))


class SignInTest(unittest.TestCase):
    """An expired login turns the tray red and the menu opens the sign-in wizard."""

    @classmethod
    def setUpClass(cls):
        with open(SWIFT, encoding="utf-8") as fh:
            cls.src = fh.read()

    def test_the_tray_shows_the_error(self):
        self.assertIn('!VaultExport.shared.expiredLogins.isEmpty {\n            baseTitle = "🧠 🔴 VAULT"', self.src)

    def test_each_expired_login_has_a_sign_in_item(self):
        self.assertIn('login expired — Sign In Again...", #selector(signInToVault(_:))).representedObject = provider', self.src)

    def test_sign_in_happens_in_the_app_not_in_terminal(self):
        self.assertIn("VaultSignIn.show(provider)", self.src)
        self.assertNotIn(".command", self.src)

    def test_cookies_go_to_ai_vault_through_a_private_file_that_is_removed(self):
        body = self.src[self.src.index("static func runSetup("):]
        body = body[:body.index("\n    }\n")]
        self.assertIn('["setup", provider, "--cookies-file", path]', body)
        self.assertIn(".posixPermissions: 0o600", body)
        self.assertIn("defer { try? FileManager.default.removeItem(atPath: path) }", body)
        self.assertLess(body.index("sites[provider] != nil"), body.index("p.arguments"))

    def test_a_refused_session_is_not_retried_in_a_loop(self):
        self.assertIn("session != self.triedSession", self.src)

    def test_success_exports_and_closes_the_window(self):
        body = self.src[self.src.index("private func save(_ cookies: [HTTPCookie])"):]
        body = body[:body.index("\n    }\n")]
        self.assertIn("VaultExport.shared.signedIn(provider)", body)
        self.assertIn("self.window.close()", body)

    def test_a_sign_in_during_an_export_is_not_dropped(self):
        self.assertIn("guard !running else { rerun = true; return }", self.src)
        self.assertIn("if self.rerun { self.rerun = false; self.runNow() }", self.src)

    def test_signing_in_clears_the_tray_error_at_once(self):
        body = self.src[self.src.index("func signedIn(_ provider: String) {"):]
        body = body[:body.index("\n    }\n")]
        self.assertIn("expiredLogins.remove(provider)", body)
        self.assertIn("onFinished?()", body)

    def test_sign_in_popups_open(self):
        self.assertIn("createWebViewWith configuration: WKWebViewConfiguration", self.src)
        self.assertIn("webView.uiDelegate = self", self.src)


if __name__ == "__main__":
    unittest.main()
