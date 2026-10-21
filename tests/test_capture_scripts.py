#!/usr/bin/env python3
"""Fast lane: scripts/stop-capture.sh and scripts/start-capture.sh.

SAFETY: these tests never touch the real capture stack. Every command that could
change system state -- launchctl, pkill, pgrep, curl, osascript, open, nc, sqlite3,
bun -- is replaced by a recording stub on a PATH that is searched first, and the
scripts run with HOME pointed at a throwaway directory (so $HOME/.bun/bin/bun and
the habit sqlite DB resolve inside the sandbox, not on the real machine).

Running the scripts for real belongs in tests/heavy/test_capture_scripts_live.py.
"""

import atexit
import os
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STOP = os.path.join(REPO, "scripts", "stop-capture.sh")
START = os.path.join(REPO, "scripts", "start-capture.sh")

# Everything either script shells out to that can mutate machine state. If a new one
# is added to a script and not listed here, test_no_unstubbed_state_changing_command
# fails rather than letting a real command escape the sandbox.
STUBBED = [
    "launchctl", "pkill", "pgrep", "curl", "osascript", "open", "nc", "sqlite3", "bun",
]

STUB = """#!/bin/sh
echo "{name} $*" >> "$STUB_LOG"
{body}
"""


_ROOT = tempfile.mkdtemp(prefix="capture-jail-")
_SANDBOXES = {}
atexit.register(shutil.rmtree, _ROOT, True)


def _stub(path, name, body):
    with open(path, "w") as fh:
        fh.write(STUB.format(name=name, body=body))
    os.chmod(path, 0o755)


class Jail:
    """A sandbox that runs a capture script with every dangerous command stubbed.

    Sandboxes are read-only once built (the scripts only exec the stubs and stat the
    fake HOME), so identical configurations share one on disk -- the first exec of a
    freshly written file on macOS costs ~1s, which would otherwise dominate the lane.
    Only the call log is per-instance, handed to the stubs as $STUB_LOG.
    """

    def __init__(self, launchctl_loaded=True, screenpipe_running=False,
                 health_ok=False, tunnel_up=False, unsynced="0", habit_db=False,
                 plists=()):
        bodies = {
            # `launchctl print` deciding whether a job is loaded drives both scripts.
            "launchctl": ('case "$1" in print) exit %d;; esac\nexit 0'
                          % (0 if launchctl_loaded else 1)),
            "pgrep": "exit %d" % (0 if screenpipe_running else 1),
            "curl": ("printf ''\nexit %d" % (0 if health_ok else 1)),
            "sqlite3": ('echo "%s"\nexit 0' % unsynced),
            "nc": "exit %d" % (0 if tunnel_up else 1),
            # Keep the lane fast: the scripts poll with `sleep 1` up to 60 times.
            "sleep": "exit 0",
        }
        key = (tuple(sorted(bodies.items())), habit_db, tuple(sorted(plists)))
        if key not in _SANDBOXES:
            _SANDBOXES[key] = self._build(bodies, habit_db, plists)
        self.bin, self.home = _SANDBOXES[key]
        fd, self.log = tempfile.mkstemp(dir=_ROOT, suffix=".calls")
        os.close(fd)

    @staticmethod
    def _build(bodies, habit_db, plists):
        base = tempfile.mkdtemp(dir=_ROOT)
        bin_dir = os.path.join(base, "bin")
        home = os.path.join(base, "home")
        os.makedirs(bin_dir)
        os.makedirs(os.path.join(home, "Library", "LaunchAgents"))
        # stop-capture.sh resolves bun by absolute path ($HOME/.bun/bin/bun), so PATH
        # alone would not stub it -- the sandboxed HOME is what neutralises it.
        os.makedirs(os.path.join(home, ".bun", "bin"))
        _stub(os.path.join(home, ".bun", "bin", "bun"), "bun", "exit 0")

        for name in STUBBED + ["sleep"]:
            _stub(os.path.join(bin_dir, name), name, bodies.get(name, "exit 0"))
        if habit_db:
            os.makedirs(os.path.join(home, ".ai-aggregator"))
            open(os.path.join(home, ".ai-aggregator",
                              "behavior_experiments.sqlite"), "w").close()
        for p in plists:
            open(os.path.join(home, "Library", "LaunchAgents", p), "w").close()
        return bin_dir, home

    def run(self, script, *args):
        proc = subprocess.run(
            ["/bin/bash", script, *args],
            cwd=REPO, capture_output=True, text=True, timeout=120,
            env={
                "HOME": self.home,
                "PATH": self.bin + ":/usr/bin:/bin:/usr/sbin:/sbin",
                "STUB_LOG": self.log,
                "TERM": "dumb",
            },
        )
        with open(self.log) as fh:
            calls = [ln.rstrip("\n") for ln in fh if ln.strip()]
        return proc, calls

    def close(self):
        # The shared sandbox outlives the instance; only the call log is ours.
        try:
            os.unlink(self.log)
        except OSError:
            pass


def indexes(calls, needle):
    return [i for i, c in enumerate(calls) if needle in c]


class StaticCheckTest(unittest.TestCase):
    """Cheap guards that catch the whole class of "script is broken before it runs"."""

    def test_scripts_parse(self):
        for script in (STOP, START):
            proc = subprocess.run(["/bin/bash", "-n", script],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0,
                             f"{os.path.basename(script)}: {proc.stderr}")

    def test_scripts_are_executable(self):
        for script in (STOP, START):
            self.assertTrue(os.access(script, os.X_OK), script)

    @unittest.skipIf(shutil.which("shellcheck") is None, "shellcheck not installed")
    def test_shellcheck_clean(self):
        for script in (STOP, START):
            proc = subprocess.run(["shellcheck", "-S", "warning", script],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0,
                             f"{os.path.basename(script)}:\n{proc.stdout}")

    def test_no_unstubbed_state_changing_command(self):
        """New state-changing commands must be added to STUBBED, or the sandbox leaks."""
        risky = {"launchctl", "pkill", "killall", "osascript", "open", "curl",
                 "sqlite3", "nc", "bun", "npm", "defaults", "systemsetup"}
        for script in (STOP, START):
            with open(script) as fh:
                words = set(fh.read().replace("(", " ").replace('"', " ").split())
            leaked = (words & risky) - set(STUBBED)
            self.assertEqual(leaked, set(),
                             f"{os.path.basename(script)} calls {leaked} unstubbed")


class HelpAndArgumentTest(unittest.TestCase):
    """Argument handling happens before any side effect, so it is safe to assert."""

    def setUp(self):
        self.jail = Jail()
        self.addCleanup(self.jail.close)

    def test_help_prints_usage_and_touches_nothing(self):
        for script, flag in ((STOP, "--help"), (START, "--help"),
                             (STOP, "-h"), (START, "-h")):
            proc, calls = self.jail.run(script, flag)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Usage:", proc.stdout)
            self.assertEqual(calls, [], "--help must not run any command")

    def test_help_documents_every_accepted_flag(self):
        # Flags come from the `case "$arg" in ... --foo) ...` arms, not from prose,
        # so a flag added to the parser without a usage line fails here.
        arm = re.compile(r"^\s*(--[a-z-]+)\)")
        for script in (STOP, START):
            proc, _ = self.jail.run(script, "--help")
            with open(script) as fh:
                flags = {m.group(1) for m in
                         (arm.match(ln) for ln in fh) if m} - {"--help"}
            self.assertTrue(flags, f"{os.path.basename(script)}: found no flags")
            for flag in sorted(flags):
                self.assertIn(flag, proc.stdout,
                              f"{os.path.basename(script)} accepts {flag} "
                              f"but --help does not mention it")

    def test_unknown_option_exits_two_without_acting(self):
        for script in (STOP, START):
            proc, calls = self.jail.run(script, "--wat")
            self.assertEqual(proc.returncode, 2)
            self.assertIn("unknown option", proc.stderr)
            self.assertEqual(calls, [])


class StopOrderingTest(unittest.TestCase):
    """The shutdown order is the whole point of the script: Learner Desktop re-arms
    screenpipe audio every 8s, so it must go down before screenpipe. It also owns the
    tunnel and watcher, which it stops itself after its own final habit flush."""

    def setUp(self):
        self.jail = Jail()
        self.addCleanup(self.jail.close)

    def test_boots_out_the_app_then_screenpipe(self):
        _, calls = self.jail.run(STOP)
        boots = [c for c in calls if c.startswith("launchctl bootout")]
        self.assertEqual(
            boots,
            ["launchctl bootout gui/%d/com.benpollack.learner-desktop" % os.getuid(),
             "launchctl bootout gui/%d/screenpipe" % os.getuid()],
        )

    def test_kills_helpers_a_crashed_app_left_behind(self):
        # A SIGKILLed app cannot stop its children; nothing else would.
        _, calls = self.jail.run(STOP)
        app = indexes(calls, "bootout gui/%d/com.benpollack.learner-desktop" % os.getuid())
        for helper in ("learner-watcher.js", "autossh"):
            killed = indexes(calls, helper)
            self.assertTrue(killed, f"never cleaned up a leftover {helper}")
            self.assertLess(app[0], killed[0])

    def test_does_not_disable_jobs_without_persist(self):
        _, calls = self.jail.run(STOP)
        self.assertEqual([c for c in calls if c.startswith("launchctl disable")], [])

    def test_persist_disables_every_job_it_boots_out(self):
        _, calls = self.jail.run(STOP, "--persist")
        booted = {c.split("/")[-1] for c in calls if c.startswith("launchctl bootout")}
        disabled = {c.split("/")[-1] for c in calls if c.startswith("launchctl disable")}
        self.assertEqual(booted, disabled)

    def test_keep_screenpipe_skips_the_whole_screenpipe_teardown(self):
        _, calls = self.jail.run(STOP, "--keep-screenpipe")
        self.assertEqual(indexes(calls, "screenpipe"), [])
        self.assertTrue(indexes(calls, "learner-desktop"))


class StopFlushTest(unittest.TestCase):
    """Habit rows must be pushed to Postgres while the tunnel is still up."""

    def test_flush_runs_before_the_app_takes_the_tunnel_down(self):
        jail = Jail(habit_db=True, unsynced="7")
        self.addCleanup(jail.close)
        _, calls = jail.run(STOP)

        counted = indexes(calls, "sqlite3")
        app = indexes(calls, "bootout gui/%d/com.benpollack.learner-desktop" % os.getuid())
        self.assertTrue(counted, "never checked the unsynced row count")
        self.assertTrue(app)
        self.assertLess(counted[0], app[0],
                        "flush must happen before the app stops its tunnel")

    def test_flush_loop_aborts_when_the_count_stops_dropping(self):
        # sqlite3 always reports 7, so no row ever drains. The loop must give up
        # rather than spin its 50 iterations (or forever).
        jail = Jail(habit_db=True, unsynced="7")
        self.addCleanup(jail.close)
        proc, calls = jail.run(STOP)
        self.assertIn("no progress", proc.stdout)
        self.assertLessEqual(len([c for c in calls if c.startswith("bun")]), 2)

    def test_no_flush_skips_the_sync_entirely(self):
        jail = Jail(habit_db=True, unsynced="7")
        self.addCleanup(jail.close)
        proc, calls = jail.run(STOP, "--no-flush")
        self.assertEqual([c for c in calls if c.startswith("bun")], [])
        self.assertNotIn("Flushing habit rows", proc.stdout)


class ScreenpipeTeardownTest(unittest.TestCase):
    """screenpipe installs no SIGTERM handler, so a bare kill can corrupt db.sqlite.
    The script must pause capture over the API and ask for a real quit first."""

    def test_pauses_capture_over_the_api_before_quitting(self):
        jail = Jail(health_ok=True, screenpipe_running=True)
        self.addCleanup(jail.close)
        _, calls = jail.run(STOP)

        audio_stop = indexes(calls, "/audio/stop")
        quit_call = indexes(calls, "osascript")
        self.assertTrue(audio_stop, "never paused audio capture")
        self.assertTrue(quit_call, "never sent a graceful quit")
        self.assertLess(audio_stop[0], quit_call[0])

    def test_escalates_to_sigterm_then_sigkill_only_after_the_quit(self):
        jail = Jail(health_ok=True, screenpipe_running=True)
        self.addCleanup(jail.close)
        _, calls = jail.run(STOP)

        term = indexes(calls, "pkill -TERM")
        kill = indexes(calls, "pkill -KILL")
        quit_call = indexes(calls, "osascript")
        self.assertTrue(term and kill)
        self.assertLess(quit_call[0], term[0])
        self.assertLess(term[0], kill[0])

    def test_does_not_kill_screenpipe_that_is_already_gone(self):
        jail = Jail(health_ok=False, screenpipe_running=False)
        self.addCleanup(jail.close)
        _, calls = jail.run(STOP)
        self.assertEqual(indexes(calls, "pkill -TERM"), [])
        self.assertEqual(indexes(calls, "osascript"), [])


class StartOrderingTest(unittest.TestCase):
    """Startup is the exact reverse: screenpipe first, then Learner Desktop (so it does
    not spend its first ticks reporting screenpipe down), which brings up the tunnel."""

    PLISTS = ("com.benpollack.learner-desktop.plist",
              "screenpipe.plist")

    def start_jail(self, **kw):
        # tunnel_up/health_ok short-circuit the 20x nc and 60x curl readiness polls.
        kw.setdefault("tunnel_up", True)
        kw.setdefault("health_ok", True)
        kw.setdefault("launchctl_loaded", False)
        jail = Jail(**kw)
        self.addCleanup(jail.close)
        return jail

    def test_starts_screenpipe_then_the_app(self):
        jail = self.start_jail(plists=self.PLISTS)
        self.addCleanup(jail.close)
        _, calls = jail.run(START)

        order = [c.split("/")[-1].replace(".plist", "")
                 for c in calls if c.startswith("launchctl bootstrap")]
        self.assertEqual(order, ["screenpipe", "com.benpollack.learner-desktop"])

    def test_waits_for_the_apps_tunnel_after_starting_the_app(self):
        jail = self.start_jail(plists=self.PLISTS)
        _, calls = jail.run(START)
        app = indexes(calls, "bootstrap gui/%d" % os.getuid())[-1]
        probe = indexes(calls, "nc -z 127.0.0.1 15432")
        self.assertTrue(probe, "never checked the Postgres forward")
        self.assertLess(app, probe[0])

    def test_enables_each_job_before_bootstrapping_it(self):
        """stop-capture.sh --persist leaves jobs launchctl-disabled; without a
        matching `enable`, bootstrap silently refuses."""
        jail = self.start_jail(plists=self.PLISTS)
        _, calls = jail.run(START)

        for label in ("learner-desktop", "screenpipe"):
            enable = [i for i, c in enumerate(calls)
                      if c.startswith("launchctl enable") and label in c]
            boot = [i for i, c in enumerate(calls)
                    if c.startswith("launchctl bootstrap") and label in c]
            self.assertTrue(enable, f"never enabled {label}")
            self.assertTrue(boot, f"never bootstrapped {label}")
            self.assertLess(enable[0], boot[0], f"{label}: enable must precede bootstrap")

    def test_kickstarts_instead_of_bootstrapping_a_loaded_job(self):
        jail = self.start_jail(launchctl_loaded=True, plists=self.PLISTS)
        _, calls = jail.run(START)
        self.assertTrue([c for c in calls if c.startswith("launchctl kickstart -k")])

    def test_no_screenpipe_skips_screenpipe_but_starts_the_rest(self):
        jail = self.start_jail(plists=self.PLISTS)
        _, calls = jail.run(START, "--no-screenpipe")
        self.assertEqual(indexes(calls, "screenpipe"), [])
        self.assertTrue(indexes(calls, "learner-desktop"))

    def test_a_missing_plist_warns_and_falls_back_instead_of_crashing(self):
        jail = self.start_jail(plists=())
        proc, calls = jail.run(START)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("missing plist", proc.stdout)
        self.assertTrue([c for c in calls if c.startswith("open ")],
                        "screenpipe should fall back to `open -g -a screenpipe.app`")


class ReversibilityTest(unittest.TestCase):
    """Whatever stop-capture.sh takes down, start-capture.sh must bring back."""

    def test_every_stopped_label_has_a_start_path(self):
        with open(STOP) as fh:
            stop_src = fh.read()
        with open(START) as fh:
            start_src = fh.read()
        labels = {ln.split("=", 1)[1].strip().strip('"')
                  for ln in stop_src.splitlines() if ln.startswith("LABEL_")}
        self.assertTrue(labels)
        for label in labels:
            self.assertIn(label, start_src, f"stop-capture.sh stops {label}, "
                                            f"start-capture.sh never starts it")


if __name__ == "__main__":
    unittest.main()
