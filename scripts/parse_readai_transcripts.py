#!/usr/bin/env python3
"""
parse_readai_transcripts.py

Parses 209 Read AI .docx meeting files from 'Past Call Transcripts/Read AI Meeting Notes/'.
1. Strips out summaries, action items, key questions, and chapters.
2. Extracts meeting title, event time, platform, participants.
3. Classifies demo calls based on title and summary.
4. Diarizes dialogue, merging consecutive same-speaker lines into a single turn.
5. Identifies the owner's speaking turns (exact name match; conference rooms excluded).
6. Derives turn duration from the gap to the next line, capped by word count.
7. Skips duplicate exports (same normalised transcript) so sessions are not imported twice.
8. Outputs structured JSON with both call-level records and habit-event records.
"""

import os
import sys
import glob
import hashlib
import json
import re
import zipfile
import uuid
import datetime
import xml.etree.ElementTree as ET

TRANSCRIPTS_DIR = "/Users/benpollack/code/learner-desktop/Past Call Transcripts/Read AI Meeting Notes"
OUTPUT_JSON = "/Users/benpollack/code/learner-desktop/data/historical_calls_export.json"

NAMESPACE_UUID = uuid.UUID("e0b1e9e0-55d0-47c8-beb4-d791e36ffe8c")

DOCX_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
DIALOGUE_LINE_RE = re.compile(r"^\((\d+:\d+(?::\d+)?)\)\s*([^:]+):\s*(.*)$")

# Written into habit_events.metadata.source so rows can be traced to this importer.
IMPORTER_SOURCE = "readai_docx_import_v2"

# the owner's turns are matched exactly against these names. A substring test also matched
# "Conference Room (the owner) - Speaker 1" (other people in the room) and would
# match unrelated names such as "Ruben" or "Benhsain".
BEN_SPEAKER_NAMES = {"ben pollack", "ben", "benjamin", "benjamin pollack"}

# Turn duration caps: a transcript-line gap credits silence and untranscribed audio to
# the speaker, so cap it at a plausible speaking rate.
WORDS_PER_SEC_CAP = 2.0
WORDS_PER_SEC_LAST_TURN = 2.5
MIN_TURN_SEC = 1.0

BREACH_WARNING_SEC = 30.0
BREACH_ALERT_SEC = 60.0
REWARD_MIN_SEC = 5.0

TZ_MAP = {
    "PST": -8, "PDT": -7,
    "EST": -5, "EDT": -4,
    "CST": -6, "CDT": -5,
    "MST": -7, "MDT": -6,
    "CET": 1,  "CEST": 2,
    "UTC": 0,  "GMT": 0
}

def parse_time_offset(s):
    parts = list(map(int, s.split(":")))
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    elif len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    return 0

def parse_event_time(event_str):
    # e.g. "2026-02-03 3:30 PM - 4:00 PM (PST)" or "2026-03-04 5:00 PM - 6:00 PM (CET)"
    m = re.search(r"(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2}\s+(?:AM|PM))\s*-\s*(\d{1,2}:\d{2}\s+(?:AM|PM))(?:\s*\(([A-Z]{3,4})\))?", event_str)
    if not m:
        return None, None
    date_part, start_str, end_str, tz_name = m.groups()
    tz_offset = TZ_MAP.get(tz_name, 0)
    tz = datetime.timezone(datetime.timedelta(hours=tz_offset))
    try:
        t_start = datetime.datetime.strptime(f"{date_part} {start_str}", "%Y-%m-%d %I:%M %p").replace(tzinfo=tz)
        t_end = datetime.datetime.strptime(f"{date_part} {end_str}", "%Y-%m-%d %I:%M %p").replace(tzinfo=tz)
        return t_start, t_end
    except Exception as e:
        return None, None

def is_ben_speaker(speaker_name):
    """True only for the owner's own transcript labels, never conference-room mics."""
    return (speaker_name or "").strip().lower() in BEN_SPEAKER_NAMES


def count_words(text):
    """Count whitespace-separated words.

    The live capture path was splitting on punctuation as well, which counted "don't" as
    two words and inflated its word counts relative to imported turns. Both paths now use
    this definition so the word-based duration cap means the same thing on either side.
    """
    return len((text or "").split())


def merge_consecutive_lines(lines):
    """Collapse consecutive lines by the same speaker into one turn (a monologue streak).

    The merged turn starts at the first line's offset and carries the combined text, so
    the gap to the next speaker spans the whole streak.
    """
    turns = []
    for ln in lines:
        if turns and turns[-1]["speaker"] == ln["speaker"]:
            prev = turns[-1]
            prev["text"] = (prev["text"] + " " + ln["text"]).strip()
            prev["lines_merged"] += 1
        else:
            turns.append({
                "time_str": ln["time_str"],
                "offset_sec": ln["offset_sec"],
                "speaker": ln["speaker"],
                "text": ln["text"],
                "lines_merged": 1,
            })
    return turns


def assign_durations(turns):
    """Annotate each turn with duration_sec, gap_sec and duration_basis.

    Duration is the gap to the next transcript line, capped at words / 2.0 s so that
    silence is not credited as speech. The final turn of a call has no following line,
    so it is estimated at words / 2.5 s. Everything is floored at 1 s.
    """
    for i, turn in enumerate(turns):
        word_count = count_words(turn["text"])
        is_last = i == len(turns) - 1

        if is_last:
            gap = None
            duration = word_count / WORDS_PER_SEC_LAST_TURN
            basis = "words_last"
        else:
            gap = float(turns[i + 1]["offset_sec"] - turn["offset_sec"])
            cap = word_count / WORDS_PER_SEC_CAP
            if gap > cap:
                duration = cap
                basis = "words_cap"
            else:
                duration = gap
                basis = "gap"

        turn["gap_sec"] = None if gap is None else round(gap, 1)
        turn["duration_sec"] = max(MIN_TURN_SEC, round(duration, 1))
        turn["duration_basis"] = basis
    return turns


def export_copy_index(filepath):
    """Copy number of a Read AI re-export: 0 for 'X.docx', 1 for 'X(1).docx'."""
    m = re.search(r"\((\d+)\)\.docx$", os.path.basename(filepath))
    return int(m.group(1)) if m else 0


def read_paragraphs(filepath):
    """Every paragraph of a .docx, in order."""
    with zipfile.ZipFile(filepath) as z:
        tree = ET.fromstring(z.read("word/document.xml"))
    return ["".join(el.text for el in p.iter(f"{{{DOCX_NS}}}t") if el.text)
            for p in tree.iter(f"{{{DOCX_NS}}}p")]


def transcript_line_count(filepath):
    """How many dialogue lines a transcript holds, used to rank colliding exports."""
    return sum(1 for p in read_paragraphs(filepath) if DIALOGUE_LINE_RE.match(p))


def order_transcript_files(files, line_counter=None):
    """Sort so that, among exports colliding on one meeting, the fuller recording is first.

    Read AI exported some meetings twice ('X.docx' and 'X(1).docx'). The copies are not
    identical re-exports: they are separate recordings of the same meeting, often on a
    different platform and frequently a partial capture. They collide on a title-derived
    session_id, so only one can be kept -- keeping both would double-count the speech.
    Rank by transcript length so the fuller recording wins, and fall back to the original
    export on a tie.
    """
    counter = line_counter or transcript_line_count
    def key(f):
        base = os.path.basename(f)
        stem = re.sub(r"\(\d+\)\.docx$", ".docx", base)
        return (stem, -(counter(f) or 0), export_copy_index(f))
    return sorted(files, key=key)


def normalised_transcript_key(lines):
    """Content fingerprint used to spot the same meeting exported twice (X.docx / X(1).docx)."""
    joined = "\n".join(
        f"{ln['offset_sec']}|{ln['speaker'].strip().lower()}|{' '.join(ln['text'].split()).lower()}"
        for ln in lines
    )
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()

def slugify(text):
    s = re.sub(r"[^\w\s-]", "", text.lower()).strip()
    return re.sub(r"[-\s]+", "_", s)[:60]

def parse_docx_file(filepath, seen_transcript_keys=None, seen_session_ids=None):
    filename = os.path.basename(filepath)
    paragraphs = read_paragraphs(filepath)

    # Extract metadata from header
    meeting_title = filename.replace(".docx", "")
    event_time_str = ""
    platform = "Meet"
    participants = []
    summary_text = ""

    t_start_idx = -1
    for i, p in enumerate(paragraphs):
        p_clean = p.strip()
        if p_clean in ["🗣 Transcript", "Transcript"]:
            t_start_idx = i + 1
            break
        
        if p.startswith("Meeting:"):
            meeting_title = p.replace("Meeting:", "").strip()
        elif p.startswith("Event time:"):
            event_time_str = p.replace("Event time:", "").strip()
        elif p.startswith("Platform:"):
            platform = p.replace("Platform:", "").strip()
        elif p.startswith("Participants:"):
            participants = [part.strip() for part in p.replace("Participants:", "").split(",") if part.strip()]
        else:
            summary_text += " " + p

    t_start, t_end = parse_event_time(event_time_str)
    if not t_start:
        # Fallback date from filename YYYY-MM-DD
        date_match = re.search(r"(\d{4}-\d{2}-\d{2})", filename)
        if date_match:
            t_start = datetime.datetime.strptime(date_match.group(1), "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc)
        else:
            t_start = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)

    # Demo classification heuristic
    is_demo_title = bool(re.search(r"\b(demo|demonstrat|walkthrough)\b", meeting_title, re.I)) or bool(re.search(r"\b(demo|demonstrat|walkthrough)\b", filename, re.I))
    is_demo_summary = bool(re.search(r"\bben (?:pollack )?(?:demonstrated|demoed|showcased|presented a demo|gave a demo|walked through)\b", summary_text, re.I))
    is_demo = is_demo_title or is_demo_summary
    call_category = "demo" if is_demo else "work"

    # Parse transcript dialogue into raw lines
    raw_lines = []
    if t_start_idx != -1:
        for p in paragraphs[t_start_idx:]:
            m = DIALOGUE_LINE_RE.match(p)
            if m:
                time_str, spk, txt = m.groups()
                raw_lines.append({
                    "time_str": time_str,
                    "offset_sec": parse_time_offset(time_str),
                    "speaker": spk.strip(),
                    "text": txt.strip()
                })
            elif raw_lines:
                raw_lines[-1]["text"] += " " + p.strip()

    # Read AI exported some meetings twice (X.docx and X(1).docx). The session_id is
    # derived from the title alone, so both copies landed on the same session. Skip a
    # file whose normalised transcript has already been seen.
    session_slug = f"readai_{t_start.strftime('%Y%m%d')}_{slugify(meeting_title)}"
    transcript_key = normalised_transcript_key(raw_lines)

    # Two guards: an identical re-export, and a different recording that would collide on
    # the title-derived session_id (see order_transcript_files).
    if raw_lines and seen_transcript_keys is not None and transcript_key in seen_transcript_keys:
        return None, [], transcript_key
    if seen_session_ids is not None and session_slug in seen_session_ids:
        return None, [], transcript_key
    if seen_transcript_keys is not None and raw_lines:
        seen_transcript_keys.add(transcript_key)
    if seen_session_ids is not None:
        seen_session_ids.add(session_slug)

    # Consecutive lines by one speaker are a single turn, not one turn per line.
    turns = assign_durations(merge_consecutive_lines(raw_lines))

    # A recording with no other named speaker is the owner alone (typically a Desktop capture
    # of a single very long turn); keep it out of the conversation metrics.
    other_speakers = {t["speaker"] for t in turns if not is_ben_speaker(t["speaker"])}
    is_solo = bool(turns) and not other_speakers
    if is_solo:
        call_category = "solo"

    total_turns = len(turns)
    ben_turns = 0
    ben_total_speech_sec = 0.0
    ben_present = any(is_ben_speaker(p) for p in participants) or any(is_ben_speaker(t["speaker"]) for t in turns)
    ben_spoke = False

    cleaned_dialogue = []
    habit_events = []

    for i, turn in enumerate(turns):
        dur = turn["duration_sec"]
        turn_words = count_words(turn["text"])
        cleaned_dialogue.append(f"({turn['time_str']}) {turn['speaker']}: {turn['text']}")

        if is_ben_speaker(turn["speaker"]):
            ben_spoke = True
            ben_turns += 1
            ben_total_speech_sec += dur

            turn_timestamp = t_start + datetime.timedelta(seconds=turn["offset_sec"])
            event_id = str(uuid.uuid5(NAMESPACE_UUID, f"{session_slug}:{i}:{turn['offset_sec']}"))

            habit_events.append({
                "event_id": event_id,
                "session_id": session_slug,
                # One source of truth for the app: the transcript's own platform.
                "call_app": platform,
                "call_category": call_category,
                "timestamp": turn_timestamp.isoformat(),
                "habit_type": "monologue_streak",
                "treatment_arm": "baseline",
                "turn_duration_sec": dur,
                "words_spoken": turn_words,
                "warning_fired_at": None,
                "shock_fired_at": None,
                "latency_to_yield_sec": None,
                "breached_30s": 1 if dur > BREACH_WARNING_SEC else 0,
                "breached_60s": 1 if dur > BREACH_ALERT_SEC else 0,
                "was_rewarded": 1 if REWARD_MIN_SEC <= dur < BREACH_WARNING_SEC else 0,
                "metadata": {
                    "simulated": False,
                    "source": IMPORTER_SOURCE,
                    "measurement": "transcript_gap",
                    "call_title": meeting_title,
                    "speaker": turn["speaker"],
                    "is_demo": is_demo,
                    "turn_index": i,
                    "offset_str": turn["time_str"],
                    "gap_sec": turn["gap_sec"],
                    "duration_basis": turn["duration_basis"],
                    "lines_merged": turn["lines_merged"],
                    "snippet": turn["text"][:140],
                    "filename": filename
                }
            })

    call_record = {
        "session_id": session_slug,
        "filename": filename,
        "meeting_title": meeting_title,
        "platform": platform,
        "event_time": t_start.isoformat(),
        "participants": participants,
        "ben_present": ben_present,
        "ben_spoke": ben_spoke,
        "is_demo": is_demo,
        "call_category": call_category,
        "total_turns": total_turns,
        "ben_turns": ben_turns,
        "ben_total_speech_sec": round(ben_total_speech_sec, 2),
        "clean_transcript": "\n".join(cleaned_dialogue),
        "metadata": {
            "demo_title_signal": is_demo_title,
            "demo_summary_signal": is_demo_summary,
            "raw_event_time_str": event_time_str,
            "is_solo": is_solo,
            "transcript_sha256": transcript_key
        }
    }

    return call_record, habit_events, transcript_key

def main():
    out_path = OUTPUT_JSON
    if "--out" in sys.argv:
        out_path = sys.argv[sys.argv.index("--out") + 1]

    files = order_transcript_files(glob.glob(os.path.join(TRANSCRIPTS_DIR, "*.docx")))
    print(f"Found {len(files)} Read AI meeting transcripts to parse.")

    all_calls = []
    all_events = []
    seen_transcript_keys = set()
    seen_session_ids = set()
    skipped_duplicates = []

    for f in files:
        call_rec, events, _ = parse_docx_file(f, seen_transcript_keys, seen_session_ids)
        if call_rec is None:
            skipped_duplicates.append(os.path.basename(f))
            continue
        all_calls.append(call_rec)
        all_events.extend(events)

    if skipped_duplicates:
        print(f"Skipped {len(skipped_duplicates)} duplicate export(s) colliding with an already-imported session:")
        for name in skipped_duplicates:
            print(f"  - {name}")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    export_payload = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "importer_source": IMPORTER_SOURCE,
        "total_files": len(files),
        "skipped_duplicate_files": skipped_duplicates,
        "total_calls_with_ben": sum(1 for c in all_calls if c["ben_spoke"]),
        "total_demo_calls": sum(1 for c in all_calls if c["is_demo"]),
        "total_solo_calls": sum(1 for c in all_calls if c["call_category"] == "solo"),
        "total_ben_habit_events": len(all_events),
        "calls": all_calls,
        "habit_events": all_events
    }

    with open(out_path, "w", encoding="utf-8") as out_f:
        json.dump(export_payload, out_f, indent=2)

    print(f"Successfully parsed {len(all_calls)} calls and generated {len(all_events)} habit events.")
    print(f"Saved structured export to: {out_path}")

if __name__ == "__main__":
    main()
