#!/usr/bin/env python3
"""Unit tests for Read AI transcript turn-merging, duration capping and speaker matching."""

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
        for name in ["Ben Pollack", "ben", "Benjamin", "Benjamin Pollack"]:
            self.assertTrue(is_ben_speaker(name), name)

    def test_rejects_conference_room_labels(self):
        self.assertFalse(is_ben_speaker("Conference Room (Ben Pollack) - Speaker 1"))
        self.assertFalse(is_ben_speaker("Conference Room (ben) - Speaker 3"))

    def test_rejects_names_that_merely_contain_ben(self):
        self.assertFalse(is_ben_speaker("Ruben"))
        self.assertFalse(is_ben_speaker("Benhsain"))


class DuplicateExportOrderingTest(unittest.TestCase):
    """Colliding exports record the same meeting, so the fuller recording must win."""

    def order(self, counts):
        ordered = order_transcript_files(list(counts), line_counter=counts.get)
        return [os.path.basename(f) for f in ordered]

    def test_prefers_the_copy_with_more_transcript_lines(self):
        order = self.order({
            "/t/report discovery.docx": 2,
            "/t/report discovery(1).docx": 74,
        })

        self.assertEqual(order[0], "report discovery(1).docx")

    def test_keeps_the_original_first_when_it_is_the_fuller_recording(self):
        order = self.order({
            "/t/demo training.docx": 108,
            "/t/demo training(1).docx": 68,
        })

        self.assertEqual(order[0], "demo training.docx")

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

    def test_counts_whitespace_separated_words(self):
        self.assertEqual(count_words("one two three"), 3)

    def test_keeps_contractions_and_hyphenated_words_whole(self):
        self.assertEqual(count_words("don't stop"), 2)
        self.assertEqual(count_words("sign-ups dropped"), 2)

    def test_ignores_surrounding_and_repeated_whitespace(self):
        self.assertEqual(count_words("  one   two  "), 2)

    def test_counts_nothing_in_empty_text(self):
        self.assertEqual(count_words("   "), 0)


class TurnMergingTest(unittest.TestCase):
    def test_merges_consecutive_same_speaker_lines_into_one_turn(self):
        turns = merge_consecutive_lines([
            line(0, "Ben Pollack", "one"),
            line(5, "Ben Pollack", "two"),
            line(9, "Ben Pollack", "three"),
            line(20, "Rob", "your turn"),
        ])

        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0]["lines_merged"], 3)
        self.assertEqual(turns[0]["offset_sec"], 0)
        self.assertEqual(turns[0]["text"], "one two three")
        self.assertEqual(turns[1]["lines_merged"], 1)

    def test_does_not_merge_across_a_different_speaker(self):
        turns = merge_consecutive_lines([
            line(0, "Ben Pollack", "a"),
            line(5, "Rob", "b"),
            line(9, "Ben Pollack", "c"),
        ])

        self.assertEqual([t["lines_merged"] for t in turns], [1, 1, 1])


class DurationTest(unittest.TestCase):
    def test_uses_gap_to_next_line_when_under_the_word_cap(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "Ben Pollack", "text": words(48), "lines_merged": 2},
            {"offset_sec": 16, "speaker": "Rob", "text": words(4), "lines_merged": 1},
        ])

        self.assertEqual(turns[0]["duration_sec"], 16.0)
        self.assertEqual(turns[0]["gap_sec"], 16.0)
        self.assertEqual(turns[0]["duration_basis"], "gap")

    def test_caps_duration_at_half_the_word_count_when_gap_is_longer(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "Ben Pollack", "text": words(10), "lines_merged": 1},
            {"offset_sec": 120, "speaker": "Rob", "text": words(4), "lines_merged": 1},
        ])

        self.assertEqual(turns[0]["duration_sec"], 5.0)
        self.assertEqual(turns[0]["gap_sec"], 120.0)
        self.assertEqual(turns[0]["duration_basis"], "words_cap")

    def test_estimates_the_final_turn_from_words_over_two_point_five(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "Rob", "text": words(4), "lines_merged": 1},
            {"offset_sec": 10, "speaker": "Ben Pollack", "text": words(3402), "lines_merged": 3},
        ])

        self.assertEqual(turns[-1]["duration_sec"], 1360.8)
        self.assertIsNone(turns[-1]["gap_sec"])
        self.assertEqual(turns[-1]["duration_basis"], "words_last")

    def test_floors_duration_at_one_second(self):
        turns = assign_durations([
            {"offset_sec": 0, "speaker": "Ben Pollack", "text": "yeah", "lines_merged": 1},
            {"offset_sec": 0, "speaker": "Rob", "text": words(4), "lines_merged": 1},
        ])

        self.assertEqual(turns[0]["duration_sec"], 1.0)


class SyntheticTranscriptTest(unittest.TestCase):
    """Short synthetic transcript exercising merging and capping together."""

    def test_merged_monologue_is_one_capped_turn(self):
        turns = assign_durations(merge_consecutive_lines([
            line(0, "Rob", words(10)),
            line(30, "Ben Pollack", words(20)),
            line(60, "Ben Pollack", words(20)),
            line(90, "Ben Pollack", words(20)),
            line(300, "Rob", words(10)),
            line(320, "Ben Pollack", words(200)),
        ]))

        self.assertEqual([t["lines_merged"] for t in turns], [1, 3, 1, 1])

        monologue = turns[1]
        # 60 words over a 270 s gap -> capped at 60/2.0
        self.assertEqual(monologue["gap_sec"], 270.0)
        self.assertEqual(monologue["duration_sec"], 30.0)
        self.assertEqual(monologue["duration_basis"], "words_cap")

        # 30 s is not a breach: comparison is strictly greater than
        self.assertEqual(turns[-1]["duration_basis"], "words_last")
        self.assertEqual(turns[-1]["duration_sec"], 80.0)


if __name__ == "__main__":
    unittest.main()
