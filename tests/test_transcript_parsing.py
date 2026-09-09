#!/usr/bin/env python3
"""Fast lane: Read AI transcript turn-merging, duration capping and speaker matching.

Pure functions only -- no docx files, no network, no database. The .docx corpus is
exercised separately in tests/heavy/test_transcript_corpus.py.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

from parse_readai_transcripts import (  # noqa: E402
    assign_durations,
    count_words,
    export_copy_index,
    is_ben_speaker,
    merge_consecutive_lines,
    order_transcript_files,
)


def line(offset, speaker, text):
    return {"offset_sec": offset, "speaker": speaker, "text": text, "time_str": "0:00"}


def words(n):
    return " ".join(["word"] * n)


class SpeakerMatchingTest(unittest.TestCase):
    def test_matches_the_four_canonical_ben_names(self):
        for name in ["the owner", "ben", "the owner", "the owner"]:
            self.assertTrue(is_ben_speaker(name), name)

    def test_rejects_conference_room_labels(self):
        self.assertFalse(is_ben_speaker("Conference Room (the owner) - Speaker 1"))
        self.assertFalse(is_ben_speaker("Conference Room (ben) - Speaker 3"))

    def test_rejects_names_that_merely_contain_ben(self):
        self.assertFalse(is_ben_speaker("Ruben"))
        self.assertFalse(is_ben_speaker("Benhsain"))


class DuplicateExportOrderingTest(unittest.TestCase):
    """Colliding exports record the same meeting, so the fuller recording must win."""

    def order(self, counts):
        ordered = order_transcript_files(list(counts), line_counter=counts.get)
        return [os.path.basename(f) for f in ordered]

    def test_ranks_colliding_exports_by_transcript_length(self):
        # The winner must be chosen on line count, not on which name came first --
        # assert both directions so a "always prefer the (1) copy" or "always prefer
        # the original" implementation cannot pass.
        self.assertEqual(
            self.order({"/t/report discovery.docx": 2, "/t/report discovery(1).docx": 74})[0],
            "report discovery(1).docx",
        )
        self.assertEqual(
            self.order({"/t/demo training.docx": 108, "/t/demo training(1).docx": 68})[0],
            "demo training.docx",
        )

    def test_breaks_a_tie_in_favour_of_the_original_export(self):
        order = self.order({
            "/t/weekly sync(1).docx": 40,
            "/t/weekly sync.docx": 40,
        })

        self.assertEqual(order[0], "weekly sync.docx")

    def test_keeps_unrelated_meetings_in_filename_order(self):
        order = self.order({
            "/t/2026-07-16 - b.docx": 5,
            "/t/2026-07-14 - a.docx": 900,
        })

        self.assertEqual(order, ["2026-07-14 - a.docx", "2026-07-16 - b.docx"])

    def test_numbers_the_copies_of_a_read_ai_re_export(self):
        self.assertEqual(export_copy_index("/t/report discovery.docx"), 0)
        self.assertEqual(export_copy_index("/t/report discovery(1).docx"), 1)
        self.assertEqual(export_copy_index("/t/report discovery(2).docx"), 2)


class WordCountTest(unittest.TestCase):
    """Words are whitespace-separated tokens, matching the server transcript rebuild."""

    def test_keeps_contractions_and_hyphenated_words_whole(self):
        # The live capture path used to split on punctuation too, counting "don't" as
        # two words and inflating its counts relative to imported turns.
        self.assertEqual(count_words("don't stop"), 2)
        self.assertEqual(count_words("sign-ups dropped"), 2)

    def test_ignores_surrounding_and_repeated_whitespace(self):
        self.assertEqual(count_words("  one   two  "), 2)
        self.assertEqual(count_words("   "), 0)


class TurnMergingTest(unittest.TestCase):
    def test_merges_consecutive_same_speaker_lines_into_one_turn(self):
        turns = merge_consecutive_lines([
            line(0, "the owner", "one"),
            line(5, "the owner", "two"),
            line(9, "the owner", "three"),
            line(20, "Rob", "your turn"),
        ])

        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0]["lines_merged"], 3)
        self.assertEqual(turns[0]["offset_sec"], 0)
        self.assertEqual(turns[0]["text"], "one two three")
        self.assertEqual(turns[1]["lines_merged"], 1)

    def test_does_not_merge_across_a_different_speaker(self):
        turns = merge_consecutive_lines([
            line(0, "the owner", "a"),
            line(5, "Rob", "b"),
            line(9, "the owner", "c"),
        ])

        self.assertEqual([t["lines_merged"] for t in turns], [1, 1, 1])


class DurationTest(unittest.TestCase):
    def test_uses_gap_to_next_line_when_under_the_word_cap(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "the owner", "text": words(48), "lines_merged": 2},
            {"offset_sec": 16, "speaker": "Rob", "text": words(4), "lines_merged": 1},
        ])

        self.assertEqual(turns[0]["duration_sec"], 16.0)
        self.assertEqual(turns[0]["gap_sec"], 16.0)
        self.assertEqual(turns[0]["duration_basis"], "gap")

    def test_caps_duration_at_half_the_word_count_when_gap_is_longer(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "the owner", "text": words(10), "lines_merged": 1},
            {"offset_sec": 120, "speaker": "Rob", "text": words(4), "lines_merged": 1},
        ])

        self.assertEqual(turns[0]["duration_sec"], 5.0)
        self.assertEqual(turns[0]["gap_sec"], 120.0)
        self.assertEqual(turns[0]["duration_basis"], "words_cap")

    def test_estimates_the_final_turn_from_words_over_two_point_five(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "Rob", "text": words(4), "lines_merged": 1},
            {"offset_sec": 10, "speaker": "the owner", "text": words(3402), "lines_merged": 3},
        ])

        self.assertEqual(turns[-1]["duration_sec"], 1360.8)
        self.assertIsNone(turns[-1]["gap_sec"])
        self.assertEqual(turns[-1]["duration_basis"], "words_last")

    def test_floors_duration_at_one_second(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "the owner", "text": "yeah", "lines_merged": 1},
            {"offset_sec": 0, "speaker": "Rob", "text": words(4), "lines_merged": 1},
        ])

        self.assertEqual(turns[0]["duration_sec"], 1.0)


class MergeThenDurationTest(unittest.TestCase):
    """The one thing the unit tests above cannot see: the cap is applied to the
    COMBINED word count of a merged streak, over the gap spanning the whole streak."""

    def test_cap_uses_the_whole_merged_streak_not_its_last_line(self):
        turns = assign_durations(merge_consecutive_lines([
            line(0, "Rob", words(10)),
            line(30, "the owner", words(20)),
            line(60, "the owner", words(20)),
            line(90, "the owner", words(20)),
            line(300, "Rob", words(10)),
        ]))

        monologue = turns[1]
        self.assertEqual(monologue["lines_merged"], 3)
        # gap runs from the FIRST line of the streak (30s) to the next speaker (300s)
        self.assertEqual(monologue["gap_sec"], 270.0)
        # 60 merged words / 2.0, not the final line's 20 words / 2.0
        self.assertEqual(monologue["duration_sec"], 30.0)
        self.assertEqual(monologue["duration_basis"], "words_cap")


if __name__ == "__main__":
    unittest.main()
