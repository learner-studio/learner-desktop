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

    def test_voice_transcripts_are_filled_after_each_chatgpt_export(self):
        with open(SWIFT, encoding="utf-8") as fh:
            src = fh.read()
        run = src[src.index("    func runNow() {"):]
        run = run[:run.index("\n    }\n")]
        self.assertLess(run.index("self.backup(provider)"), run.index("self.fillVoiceTranscripts()"))
        self.assertIn('if !expired.contains("chatgpt")', run)
        self.assertIn('[script, "voice-transcripts"]', src)

    def test_a_crashed_browser_counts_as_a_failure(self):
        sample = "[1047/1239] ✗ Failed: A title - browser.newContext: Target page, context or browser has been closed"
        self.assertRegex(sample, pattern("failedPattern"))
        self.assertNotRegex(sample, pattern("loginExpiredPattern"))

    def test_a_clean_run_is_ok(self):
        self.assertNotRegex(OK, pattern("loginExpiredPattern"))
        self.assertNotRegex(OK, pattern("failedPattern"))


class DurabilityTest(unittest.TestCase):
    """The export run of 10-27 hung for 50 min: ai-vault's browser died, it ignored SIGTERM,
    and the app waited forever, so no export or sign-in rerun could start."""

    @classmethod
    def setUpClass(cls):
        with open(SWIFT, encoding="utf-8") as fh:
            src = fh.read()
        cls.cls = src[src.index("final class VaultExport {"):src.index("// MARK: - AI Vault sign-in")]
        cls.src = src

    def body(self, start):
        b = self.cls[self.cls.index(start):]
        return b[:b.index("\n    }\n")]

    def test_a_quiet_run_is_stopped_but_a_long_busy_one_is_not(self):
        self.assertIn("static let stallTimeout: TimeInterval = 10 * 60", self.cls)
        self.assertIn("static let maxRunTime: TimeInterval = 4 * 3600", self.cls)
        self.assertNotIn("perProviderTimeout", self.cls)
        run = self.body("private func runLogged(")
        self.assertIn("lastOutput = Date()", run)
        self.assertIn("> VaultExport.stallTimeout", run)

    def test_stopping_escalates_to_sigkill_for_the_whole_tree(self):
        stop = self.body("static func stop(_ p: Process")
        self.assertLess(stop.index("descendants(of: pid)"), stop.index("p.terminate()"))
        self.assertLess(stop.index("p.terminate()"), stop.index("kill(child, SIGKILL)"))

    def test_failures_retry_with_backoff_not_in_six_hours(self):
        self.assertIn("static let failureRetryBase: TimeInterval = 15 * 60", self.cls)
        self.assertIn("VaultExport.failureRetryBase * pow(2, Double(self.failures - 1))", self.cls)
        self.assertIn("self.failures = failed ? self.failures + 1 : 0", self.cls)

    def test_output_is_logged_as_it_arrives(self):
        self.assertIn("log?.write(chunk)", self.body("private func runLogged("))

    def test_no_export_outlives_the_app_or_runs_twice(self):
        self.assertIn("VaultExport.shared.stopForQuit()", self.src)
        run = self.body("    func runNow() {")
        self.assertIn("VaultExport.killOrphans()", run)


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

    def test_sign_in_uses_your_browser_where_1password_and_passkeys_work(self):
        self.assertIn("VaultSignIn.start(provider)", self.src)
        self.assertNotIn("WKWebView", self.src)
        self.assertNotIn(".command", self.src)
        self.assertIn("browser.open(site.url)", self.src)

    def test_brave_is_the_default_and_chrome_can_be_chosen_in_settings(self):
        body = self.src[self.src.index("struct ChromiumBrowser {"):]
        self.assertLess(body.index('id: "brave"'), body.index('id: "chrome"'))
        self.assertIn("?? all[0]", body)
        self.assertIn('"Brave Safe Storage"', body)
        self.assertIn('add("Sign AI Vault In From", to: settings).submenu = browserMenu', self.src)

    def test_an_existing_chrome_session_is_tried_before_opening_anything(self):
        body = self.src[self.src.index("private func checked(session:"):]
        body = body[:body.index("\n    }\n")]
        self.assertLess(body.index("VaultExport.shared.signedIn(provider)"), body.index("browser.open"))

    def test_browser_cookies_are_decrypted_with_the_safe_storage_key(self):
        body = self.src[self.src.index("enum BrowserCookies {"):]
        self.assertIn("browser.keychainService", body)
        self.assertIn('"saltysalt"', body)
        self.assertIn("1003", body)
        self.assertIn("version >= 24", body)
        self.assertIn("immutable=1", body)

    def test_cookies_go_to_ai_vault_through_a_private_file_that_is_removed(self):
        body = self.src[self.src.index("static func runSetup("):]
        body = body[:body.index("\n    }\n")]
        self.assertIn('["setup", provider, "--cookies-file", path]', body)
        self.assertIn(".posixPermissions: 0o600", body)
        self.assertIn("defer { try? FileManager.default.removeItem(atPath: path) }", body)
        self.assertLess(body.index("sites[provider] != nil"), body.index("runBounded(cli"))

    def test_a_refused_session_is_not_retried_in_a_loop(self):
        self.assertIn("$0 == tried ? nil", self.src)

    def test_the_expired_session_ai_vault_already_has_is_not_resaved(self):
        self.assertIn("triedSession = VaultSignIn.savedSession(provider, site: site)", self.src)

    def test_watching_chrome_stops_after_a_limit(self):
        self.assertIn("static let waitLimit: TimeInterval = 10 * 60", self.src)

    def test_a_sign_in_during_an_export_is_not_dropped(self):
        self.assertIn("guard !running else { rerun = true; return }", self.src)
        self.assertIn("if self.rerun { self.rerun = false; self.runNow() }", self.src)

    def test_signing_in_clears_the_tray_error_at_once(self):
        body = self.src[self.src.index("func signedIn(_ provider: String) {"):]
        body = body[:body.index("\n    }\n")]
        self.assertIn("expiredLogins.remove(provider)", body)
        self.assertIn("onFinished?()", body)


if __name__ == "__main__":
    unittest.main()
