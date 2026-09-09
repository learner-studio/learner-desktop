#!/usr/bin/env python3
"""Heavy lane: the Read AI importer over the real 209-file .docx corpus.

Opt-in. Needs AIAGG_HEAVY=1 (scripts/test.sh heavy sets it) and the corpus under
'Past Call Transcripts/Read AI Meeting Notes/'. Writes only to a temp file --
data/historical_calls_export.json is never touched, and nothing reaches Postgres.

The fast lane covers the pure functions. This covers the parts they cannot: .docx
unpacking, header parsing, duplicate-export suppression, and the invariants the
downstream habit-event import depends on. It asserts corpus-level *invariants*,
not per-file expected values, so re-exporting or adding transcripts does not
break it.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IMPORTER = os.path.join(REPO, "scripts", "parse_readai_transcripts.py")
CORPUS = os.path.join(REPO, "Past Call Transcripts", "Read AI Meeting Notes")

HEAVY = os.environ.get("AIAGG_HEAVY") == "1"
HAS_CORPUS = os.path.isdir(CORPUS) and any(f.endswith(".docx") for f in
                                           os.listdir(CORPUS) if os.path.isdir(CORPUS))


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(HAS_CORPUS, f"no .docx corpus at {CORPUS}")
class CorpusImportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="corpus-import-")
        out = os.path.join(cls.tmp, "export.json")
        proc = subprocess.run([sys.executable, IMPORTER, "--out", out],
                              capture_output=True, text=True, timeout=900, cwd=REPO)
        if proc.returncode != 0:
            raise AssertionError(f"importer failed:\n{proc.stdout}\n{proc.stderr}")
        with open(out, encoding="utf-8") as fh:
            cls.export = json.load(fh)

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_imports_the_whole_corpus(self):
        on_disk = len([f for f in os.listdir(CORPUS) if f.endswith(".docx")])
        self.assertEqual(self.export["total_files"], on_disk)
        self.assertGreater(len(self.export["calls"]), 0)

    def test_no_meeting_is_imported_twice(self):
        """Duplicate Read AI exports collide on the title-derived session_id;
        importing both would double-count the owner's speech in the baseline."""
        ids = [c["session_id"] for c in self.export["calls"]]
        self.assertEqual(len(ids), len(set(ids)), "duplicate session_id in export")

        fingerprints = [c["metadata"]["transcript_sha256"]
                        for c in self.export["calls"] if c["total_turns"]]
        self.assertEqual(len(fingerprints), len(set(fingerprints)),
                         "two calls carry an identical transcript")

    def test_habit_events_are_unique_and_belong_to_an_imported_call(self):
        events = self.export["habit_events"]
        self.assertGreater(len(events), 0)
        ids = [e["event_id"] for e in events]
        self.assertEqual(len(ids), len(set(ids)), "duplicate event_id")
        sessions = {c["session_id"] for c in self.export["calls"]}
        orphans = {e["session_id"] for e in events} - sessions
        self.assertEqual(orphans, set(), f"events with no call record: {orphans}")

    def test_every_habit_event_is_one_of_bens_turns(self):
        for e in self.export["habit_events"]:
            self.assertEqual(e["habit_type"], "monologue_streak")
            self.assertEqual(e["treatment_arm"], "baseline")
            self.assertFalse(e["metadata"]["simulated"])

    def test_turn_durations_stay_inside_the_capping_rules(self):
        """Every duration must be >= the 1s floor, <= words/2.0 (or words/2.5 for
        a call's final turn), and never longer than the gap it was derived from."""
        for e in self.export["habit_events"]:
            dur, words = e["turn_duration_sec"], e["words_spoken"]
            basis, gap = e["metadata"]["duration_basis"], e["metadata"]["gap_sec"]
            with self.subTest(event=e["event_id"], basis=basis):
                self.assertGreaterEqual(dur, 1.0)
                self.assertIn(basis, ("gap", "words_cap", "words_last"))
                if basis == "gap":
                    self.assertEqual(dur, max(1.0, gap))
                elif basis == "words_cap":
                    self.assertLessEqual(dur, max(1.0, round(words / 2.0, 1)))
                    # <= not <: the 1s floor can lift a capped duration back up to
                    # the gap when both are sub-second.
                    self.assertLessEqual(dur, max(1.0, gap))
                else:
                    self.assertIsNone(gap)
                    self.assertLessEqual(dur, max(1.0, round(words / 2.5, 1)))

    def test_breach_flags_match_the_durations_they_were_derived_from(self):
        for e in self.export["habit_events"]:
            dur = e["turn_duration_sec"]
            with self.subTest(event=e["event_id"]):
                self.assertEqual(e["breached_30s"], 1 if dur > 30.0 else 0)
                self.assertEqual(e["breached_60s"], 1 if dur > 60.0 else 0)
                self.assertEqual(e["was_rewarded"], 1 if 5.0 <= dur < 30.0 else 0)

    def test_conference_room_mics_are_never_counted_as_ben(self):
        for e in self.export["habit_events"]:
            self.assertNotIn("conference room",
                             e["metadata"]["speaker"].lower(), e["metadata"])

    def test_the_import_is_deterministic(self):
        """The baseline is re-imported periodically; a shifting event_id would
        duplicate every row in Postgres."""
        out = os.path.join(self.tmp, "again.json")
        subprocess.run([sys.executable, IMPORTER, "--out", out],
                       capture_output=True, text=True, timeout=900, cwd=REPO, check=True)
        with open(out, encoding="utf-8") as fh:
            again = json.load(fh)
        self.assertEqual([e["event_id"] for e in again["habit_events"]],
                         [e["event_id"] for e in self.export["habit_events"]])


if __name__ == "__main__":
    unittest.main()
