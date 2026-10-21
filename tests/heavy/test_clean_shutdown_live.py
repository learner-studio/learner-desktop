#!/usr/bin/env python3
"""Heavy lane, DESTRUCTIVE: the real quit / crash cycle of the installed menu-bar app.

Stops and restarts the owner's live logger, so it is double-gated like the capture-stack
cycle:

    AIAGG_HEAVY=1 AIAGG_HEAVY_DESTRUCTIVE=1 python3 -m unittest tests.heavy.test_clean_shutdown_live

Verifies, against launchd, that a clean quit exits 0 and STAYS down (KeepAlive no longer
resurrects it), that pending habit rows are flushed before exit, and that a crash
(SIGKILL) IS still resurrected. Restores the app at the end.
"""

import os
import sqlite3
import subprocess
import time
import unittest

LABEL = "com.benpollack.learner-desktop"
DOMAIN = f"gui/{os.getuid()}"
BINARY = "learner-desktop"
LOG = os.path.expanduser("~/.ai-aggregator/logs/menubar.log")
DB = os.path.expanduser("~/.ai-aggregator/behavior_experiments.sqlite")

GATED = (os.environ.get("AIAGG_HEAVY") == "1"
         and os.environ.get("AIAGG_HEAVY_DESTRUCTIVE") == "1")


def pid():
    out = subprocess.run(["pgrep", "-f", BINARY], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def wait_until(pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(1)
    return pred()


def launchd_last_exit():
    out = subprocess.run(["launchctl", "print", f"{DOMAIN}/{LABEL}"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "last exit code" in line:
            return line.split("=", 1)[1].strip()
    return None


def unsynced():
    with sqlite3.connect(DB) as con:
        return con.execute("SELECT COUNT(*) FROM habit_events WHERE synced_to_server = 0").fetchone()[0]


def restart():
    subprocess.run(["launchctl", "kickstart", f"{DOMAIN}/{LABEL}"], check=False)
    return wait_until(lambda: pid() is not None, 20) and settled()


def settled():
    """Block until the app has been up for 5s (past applicationDidFinishLaunching)."""
    p = pid()
    if p is None:
        return False
    out = subprocess.run(["ps", "-o", "etime=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
    parts = out.replace("-", ":").split(":")  # [[dd-]hh:]mm:ss
    uptime = sum(int(x) * 60 ** i for i, x in enumerate(reversed(parts)))
    if uptime < 5:
        time.sleep(5 - uptime)
    return pid() == p


@unittest.skipUnless(GATED, "destructive: set AIAGG_HEAVY=1 AIAGG_HEAVY_DESTRUCTIVE=1")
class CleanShutdownLiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if pid() is None and not restart():
            raise unittest.SkipTest("menu-bar app is not running and could not be started")

    @classmethod
    def tearDownClass(cls):
        if pid() is None:
            restart()

    def _log_since(self, offset):
        with open(LOG, encoding="utf-8", errors="replace") as fh:
            fh.seek(offset)
            return fh.read()

    def test_1_sigterm_flushes_closes_exits_zero_and_stays_down(self):
        self.assertTrue(settled())
        # Seed pending rows from already-synced ones; the server inserts with
        # ON CONFLICT DO NOTHING, so re-pushing them is harmless.
        with sqlite3.connect(DB) as con:
            con.execute("""UPDATE habit_events SET synced_to_server = 0 WHERE event_id IN
                           (SELECT event_id FROM habit_events WHERE synced_to_server = 1
                            ORDER BY rowid DESC LIMIT 2)""")
        self.assertGreater(unsynced(), 0)

        old = pid()
        offset = os.path.getsize(LOG)
        os.kill(old, 15)  # what launchctl bootout / kickstart -k / stop-capture.sh send

        self.assertTrue(wait_until(lambda: pid() is None, 60), "app did not exit on SIGTERM")
        log = self._log_since(offset)
        self.assertIn("[Shutdown] Finalising in-flight turn", log)
        self.assertIn("[Shutdown] Syncing", log)
        self.assertIn("[HabitLogger] SQLite closed cleanly", log)
        self.assertIn("[Shutdown] Clean shutdown complete", log)
        self.assertEqual(unsynced(), 0, "pending rows were not flushed before exit")

        time.sleep(10)
        self.assertIsNone(pid(), "launchd resurrected the app after a clean quit")
        self.assertEqual(launchd_last_exit(), "0")

        self.assertTrue(restart())

    def test_2_a_crash_is_still_resurrected(self):
        self.assertTrue(settled())
        old = pid()
        os.kill(old, 9)

        self.assertTrue(wait_until(lambda: pid() not in (None, old), 30),
                        "launchd did not restart the app after SIGKILL")


if __name__ == "__main__":
    unittest.main()
