#!/usr/bin/env python3
"""Fast lane: the app must say so when macOS will not start it at login.

A LaunchAgent switched off in System Settings -> Login Items is skipped by launchd at
login, with no error anywhere. That is how the old tunnel and watcher agents stayed down
for ten days after the 2026-10-11 reboot while the tray only said "Hindsight tunnel
disconnected". They now run inside the app, so the app's own entry is the one that
matters: if it is switched off, a manual start works but does not survive the next
reboot, and only the owner can re-allow it.
"""

import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def body_of(src, signature):
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]


class LoginItemsApprovalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = read(SWIFT)

    def test_checks_the_apps_own_agent_with_the_legacy_plist_api(self):
        body = body_of(self.src, "func updateLoginItemApproval(")
        self.assertIn("SMAppService.statusForLegacyPlist", body)
        self.assertIn(".requiresApproval", body)
        self.assertIn("appAgentPlist", body)
        self.assertIn('"/Library/LaunchAgents/com.benpollack.learner-desktop.plist"', self.src)

    def test_check_runs_on_the_status_poll(self):
        self.assertIn("updateLoginItemApproval()", body_of(self.src, "func updateAllStatuses("))

    def test_check_stays_off_the_main_thread(self):
        # statusForLegacyPlist is a synchronous XPC call; the poll runs every 8s.
        body = body_of(self.src, "func updateLoginItemApproval(")
        self.assertRegex(body, r"DispatchQueue\.global\(")

    def test_tray_names_the_block_before_the_generic_tunnel_error(self):
        body = body_of(self.src, "func updateTrayButton(")
        blocked = body.index("needsLoginApproval")
        tunnel = body.index("!isServerReachable")
        self.assertLess(blocked, tunnel)
        self.assertIn("Login Items", body[blocked:tunnel])

    def test_menu_opens_login_items_when_blocked(self):
        menu = body_of(self.src, "func rebuildMenu(")
        self.assertIn("needsLoginApproval", menu)
        self.assertIn("#selector(openLoginItemsSettings)", menu)
        action = body_of(self.src, "@objc func openLoginItemsSettings(")
        self.assertIn("SMAppService.openSystemSettingsLoginItems()", action)

    def test_logs_each_change_in_approval(self):
        body = body_of(self.src, "func updateLoginItemApproval(")
        self.assertTrue(re.search(r'print\("\[LoginItem\][^"]*Login Items', body))

    def test_imports_service_management(self):
        self.assertIn("import ServiceManagement", self.src)


if __name__ == "__main__":
    unittest.main()
