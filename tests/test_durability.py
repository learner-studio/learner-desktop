#!/usr/bin/env python3
"""Fast lane: every operation in the app recovers on its own and never waits forever.

From the 10-27 audit: helper programs waited on with no deadline (a hung export blocked
every later one for 50 min), chats exported while the watcher was down never sent, a
lone oversized habit event retried in a tight loop, a failed screenpipe poll ended the
current call, and the tunnel script could kill a browser holding GrowthBook open.
"""

import os
import re
import unittest
from tests.swift_source import swift_source

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def read(*parts):
    with open(os.path.join(REPO, *parts), encoding="utf-8") as fh:
        return fh.read()


def body(src, start):
    b = src[src.index(start):]
    return b[:b.index("\n    }\n")]


class DurabilityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = swift_source()

    def test_no_helper_program_is_waited_on_without_a_deadline(self):
        # Only ChildProcess.run (deadline, stall watchdog, SIGKILL) and the export runner
        # may block on a child; everything else goes through ChildProcess.run.
        waits = [m.start() for m in re.finditer(r"waitUntilExit\(\)|readDataToEndOfFile\(\)", self.src)]
        allowed = [body(self.src, "    static func run(_ executable: String"), body(self.src, "private func runLogged(")]
        for pos in waits:
            line = self.src.count("\n", 0, pos) + 1
            self.assertTrue(any(self.src[pos - 40:pos + 20] in a for a in allowed), f"unbounded wait at main.swift:{line}")

    def test_keychain_and_setup_reads_are_bounded(self):
        self.assertIn('ChildProcess.run("/usr/bin/security", ["find-generic-password", "-s", "learner-server"', self.src)
        self.assertIn('ChildProcess.run("/usr/bin/security", ["find-generic-password", "-w", "-s", browser.keychainService', self.src)
        self.assertIn('ChildProcess.run(cli, ["setup", provider, "--cookies-file", path], timeout: 90', self.src)

    def test_update_check_escalates_to_sigkill(self):
        self.assertIn("if p.isRunning { kill(p.processIdentifier, SIGKILL) }", self.src)

    def test_a_helper_that_fails_to_start_is_retried(self):
        launch = body(self.src, "    private func launch() {")
        self.assertIn("self?.launch()", launch[launch.index("} catch {"):])

    def test_watcher_catches_up_on_start_and_problems_reach_the_tray(self):
        self.assertNotIn("--no-initial-sync", self.src)
        self.assertNotIn("--no-initial-sync", read("src", "cli.ts"))
        self.assertIn("sweep('startup')", read("src", "cli.ts"))
        self.assertIn("config.sync.sweepIntervalMs", read("src", "cli.ts"))
        self.assertIn('"/.ai-aggregator/status.json"', self.src)
        self.assertIn('baseTitle = "🧠 🔴 SYNC"', self.src)

    def test_a_lone_oversized_event_is_parked_not_retried_forever(self):
        send = self.src[self.src.index("        case 413:"):]
        send = send[:send.index("        default:")]
        self.assertIn("if ids.count > 1", send)
        self.assertIn("logger.mark(ids, as: 2)", send)

    def test_a_failed_outbox_update_backs_off(self):
        self.assertEqual(self.src.count("else { return markFailed() }"), 3)
        self.assertIn("func mark(_ eventIds: [String], as state: Int) -> Bool", self.src)

    def test_trials_are_kept_until_saved(self):
        log = body(self.src, "    func logTurn(")
        self.assertIn("self.unwritten.append(turn)", log)
        self.assertIn("guard self.openLocked() else { return }", log)
        self.assertIn("INSERT OR IGNORE INTO habit_events", self.src)
        self.assertIn('baseTitle = "🧠 🔴 DB"', self.src)

    def test_a_failed_call_poll_does_not_end_the_call(self):
        check = body(self.src, "    func checkActiveCall() {")
        self.assertIn("statusCode == 200", check)
        self.assertIn("TalkTimeMonitor.callPollOutageEndsCall", check)

    def test_an_unusable_pavlok_link_is_dropped_so_it_reconnects(self):
        self.assertEqual(self.src.count("            dropUnusable(peripheral, "), 2)
        self.assertIn('self.dropUnusable(peripheral, "no stimulus characteristics 15 s after connecting")', self.src)

    def test_tunnel_script_only_kills_the_listener(self):
        script = read("scripts", "tunnel.sh")
        self.assertNotIn("lsof -ti :$PORT |", script)
        self.assertIn("lsof -ti tcp:$PORT -sTCP:LISTEN | xargs kill -9", script)


if __name__ == "__main__":
    unittest.main()
