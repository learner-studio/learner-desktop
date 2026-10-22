#!/usr/bin/env python3
"""Opt-in visible meeting-poller E2E, isolated from the owner's recorder and data.

Runs the production Swift monitor, NSPanel and logger against a local HTTP fixture.
It never assigns a streak or bypasses canAlert. Timestamped
live input rows arrive on a controlled schedule, while background transcription is empty.
A two-word output backchannel ends the turn after the panel is inspected. Background
reconciliation then returns the same speech, which must not create another turn.

AIAGG_HEAVY=1 enables the test. AIAGG_COACH_E2E_DIR preserves evidence in that
directory. AIAGG_COACH_E2E_INTERACTIVE=1 holds the panel for human inspection until
<evidence dir>/live-warning/release exists (maximum three minutes). NSPanel.isVisible is checked
automatically; actual human visibility must be recorded separately.

Only a temporary source copy is changed: API URL, defaults suite, logger directory,
and application entrypoint. Production monitor/panel/logging logic is unchanged.
No production app restart, Screenpipe write, external stimulus or habit sync occurs.
"""

import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


REPO = Path(__file__).resolve().parents[2]
HEAVY = os.environ.get("AIAGG_HEAVY") == "1"


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()


HARNESS = r'''
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let evidence = ProcessInfo.processInfo.environment["AIAGG_COACH_E2E_DIR"]!
let interactive = ProcessInfo.processInfo.environment["AIAGG_COACH_E2E_INTERACTIVE"] == "1"
let holdSeconds = Double(ProcessInfo.processInfo.environment["AIAGG_COACH_E2E_HOLD"]!)!
let target = Double(ProcessInfo.processInfo.environment["AIAGG_COACH_E2E_TARGET"]!)!
let expectPanel = ProcessInfo.processInfo.environment["AIAGG_COACH_E2E_EXPECT_PANEL"] == "1"
HabitExperimentManager.shared.currentMode = .baseline
let rewardDevice = ProcessInfo.processInfo.environment["AIAGG_COACH_REWARD_DEVICE"] == "1"
let pavlok = PavlokController.shared
if rewardDevice {
    pavlok.warningShockIntensity = 0
    pavlok.alertShockIntensity = 0
    pavlok.warningVibeIntensity = 0
    pavlok.alertVibeIntensity = 0
    pavlok.warningBeepEnabled = false
    pavlok.rewardGoodBehavior = true
    pavlok.isEnabled = true
}
let connectionDeadline = Date().addingTimeInterval(60)
var finishing = false
let monitor = TalkTimeMonitor.shared
var readyAt: Date?
var firstVisibleStreak: Double?
var pollTimer: Timer?
pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    if finishing { return }
    if rewardDevice && !pavlok.isReadyForStimulus("vibe") && readyAt == nil {
        if Date() > connectionDeadline { print("[RewardE2E] FAILED: Bluetooth did not become ready"); exit(4) }
        return
    }
    if let ready = readyAt {
        monitor.tick()
        if !expectPanel && (monitor.currentStreak > target || monitor.isWarningActive ||
            app.windows.contains { $0 is NSPanel && $0.isVisible }) {
            print("[MeetingE2E] FAILED: trailing silence advanced the counter or showed a panel")
            exit(3)
        }
        let release = FileManager.default.fileExists(atPath: evidence + "/release")
        if release || (!interactive && Date().timeIntervalSince(ready) > holdSeconds)
            || Date().timeIntervalSince(ready) > 180 {
            try? Data().write(to: URL(fileURLWithPath: evidence + "/release"))
            monitor.tick()
            if monitor.currentStreak == 0 {
                if rewardDevice {
                    finishing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        HabitEventLogger.shared.waitUntilIdle()
                        HabitEventLogger.shared.close()
                        exit(0)
                    }
                    return
                }
                HabitEventLogger.shared.waitUntilIdle()
                HabitEventLogger.shared.close()
                print("[MeetingE2E] FINISHED after output backchannel")
                exit(0)
            }
        }
        return
    }
    let panels = app.windows.filter { $0 is NSPanel && $0.isVisible && $0.alphaValue > 0.99 }
    if !panels.isEmpty && firstVisibleStreak == nil { firstVisibleStreak = monitor.currentStreak }
    monitor.tick()
    if monitor.currentStreak >= target {
        if !expectPanel || !panels.isEmpty {
            let snapshot: [String: Any] = [
                "streak": monitor.currentStreak, "canAlert": monitor.canAlert,
                "armShowsToast": monitor.armShowsToast,
                "warning": monitor.isWarningActive,
                "firstVisibleStreak": firstVisibleStreak as Any? ?? NSNull(),
                "windows": panels.map { ["visible": $0.isVisible, "alpha": $0.alphaValue,
                    "frame": NSStringFromRect($0.frame), "windowNumber": $0.windowNumber] }
            ]
            let data = try! JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: evidence + "/panel.json"))
            readyAt = Date()
            print("[MeetingE2E] OBSERVATION_READY: streak=\(monitor.currentStreak), canAlert=\(monitor.canAlert), visible=\(!panels.isEmpty)")
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 250) {
    print("[MeetingE2E] FAILED: timed out before completing panel/turn verification")
    exit(2)
}
app.run()
'''


@unittest.skipUnless(HEAVY, "heavy lane: set AIAGG_HEAVY=1")
@unittest.skipUnless(shutil.which("swiftc"), "swiftc not installed")
class SpeakingCoachMeetingE2E(unittest.TestCase):
    def test_live_rows_reach_visible_panel_and_persist_turn(self):
        self.run_case("live-warning", has_meeting=True, offsets=list(range(0, 37, 4)))

    def test_long_off_call_speech_cannot_show_panel(self):
        self.run_case("off-call", has_meeting=False, offsets=list(range(0, 37, 4)))

    def test_subthreshold_turn_and_backchannel_cannot_show_panel(self):
        self.run_case("short-turn", has_meeting=True, offsets=list(range(0, 25, 4)) + [27], hold=5)

    def test_resuming_after_a_brief_pause_keeps_the_same_turn(self):
        self.run_case("resumed-turn", has_meeting=True,
                      offsets=list(range(0, 25, 4)) + [27, 31])

    def run_case(self, name, *, has_meeting, offsets, hold=2, reward_device=False):
        row_count = len(offsets)
        duration = offsets[-1] - offsets[0]
        expect_panel = has_meeting and duration >= 30
        root = Path(os.environ.get("AIAGG_COACH_E2E_DIR") or
                    tempfile.mkdtemp(prefix="coach-meeting-e2e-"))
        evidence = root / name
        evidence.mkdir(parents=True, exist_ok=True)
        self.assertFalse((evidence / "panel.json").exists(), "use a fresh evidence directory")
        self.assertFalse((evidence / "release").exists(), "use a fresh evidence directory")
        suite = "ai-aggregator-meeting-e2e-" + uuid.uuid4().hex
        started = [None]
        requests = []
        replayed = []

        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                requests.append({"at": iso(time.time()), "path": self.path})
                if self.path == "/meetings":
                    self.reply([{"id": 1, "meeting_app": "Simulated Meeting (E2E)",
                                 "title": "Synthetic speech fixture", "meeting_end": None}]
                               if has_meeting else [])
                else:
                    self.reply({})

            def do_POST(self):
                sql = json.loads(self.rfile.read(int(self.headers["Content-Length"])))['query']
                if "meeting_transcript_segments" not in sql:
                    if "MAX(id)" in sql:
                        self.reply([{"max_id": 0}])
                        return
                    watermark = int(re.search(r"t.id > (\d+)", sql).group(1))
                    rows = []
                    if (evidence / "release").exists():
                        rows = [{"id": 100 + i, "audio_chunk_id": i,
                                 "transcription": "This synthetic meeting sentence provides twelve words for the speaking coach test",
                                 "timestamp": iso(started[0] + offsets[i - 1]),
                                 "start_time": 0, "end_time": 4,
                                 "file_path": "/synthetic/input.wav"}
                                for i in range(1, row_count + 1) if 100 + i > watermark]
                        replayed.extend(r["id"] for r in rows)
                    self.reply(rows)
                    return
                if "MAX(id)" in sql:
                    if started[0] is None:
                        started[0] = time.time()
                    self.reply([{"id": 0}])
                    return
                watermark = int(re.search(r"id > (\d+)", sql).group(1))
                count = sum(time.time() - started[0] >= offset + 4 for offset in offsets)
                rows = [{"id": i, "device_type": "input",
                         "transcript": "This synthetic meeting sentence provides twelve words for the speaking coach test",
                         "captured_at": iso(started[0] + offsets[i - 1])}
                        for i in range(watermark + 1, count + 1)]
                if (evidence / "release").exists() and watermark < row_count + 1:
                    rows.append({"id": row_count + 1, "device_type": "output", "transcript": "mm hmm",
                                 "captured_at": iso(time.time())})
                if rows:
                    requests.append({"at": iso(time.time()), "rows": rows})
                self.reply(rows)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        source = (REPO / "menu-bar-app/main.swift").read_text()
        marker = "// MARK: - Application Entrypoint"
        self.assertEqual(source.count(marker), 1)
        original_hash = hashlib.sha256(source.encode()).hexdigest()
        source = source.split(marker)[0]
        source = source.replace("http://localhost:3030", f"http://127.0.0.1:{server.server_port}")
        source = source.replace("UserDefaults.standard", f'UserDefaults(suiteName: "{suite}")!')
        logger_dir = 'let dir = home + "/.ai-aggregator"'
        self.assertEqual(source.count(logger_dir), 1)
        source = source.replace(logger_dir, 'let dir = ProcessInfo.processInfo.environment["AIAGG_COACH_E2E_DIR"]!')
        swift_file = evidence / "main.swift"
        swift_file.write_text(source + HARNESS)
        binary = evidence / "ai-aggregator-meeting-e2e"
        build = subprocess.run(["swiftc", "-O", "-lsqlite3", str(swift_file), "-o", str(binary)],
                               capture_output=True, text=True, timeout=120)
        (evidence / "build.log").write_text(build.stdout + build.stderr)
        self.assertEqual(build.returncode, 0, build.stderr[-3000:])
        (evidence / "manifest.json").write_text(json.dumps({
            "simulation": True, "source_sha256": original_hash,
            "source": str(REPO / "menu-bar-app/main.swift"),
            "isolation": "fixture HTTP server, unique defaults suite, separate habit database",
            "boundary": "HTTP meeting/live transcript responses through production NSPanel and logger",
            "excluded": "real meeting detection, audio capture, speech recognition and production process",
        }, indent=2))
        self.addCleanup(lambda: subprocess.run(["defaults", "delete", suite], capture_output=True))
        print(f"Meeting E2E evidence: {evidence}", flush=True)
        env = dict(os.environ, AIAGG_COACH_E2E_DIR=str(evidence),
                   AIAGG_COACH_E2E_TARGET=str(duration),
                   AIAGG_COACH_E2E_HOLD=str(hold),
                   AIAGG_COACH_REWARD_DEVICE="1" if reward_device else "0",
                   AIAGG_COACH_E2E_EXPECT_PANEL="1" if expect_panel else "0")
        if not expect_panel:
            env["AIAGG_COACH_E2E_INTERACTIVE"] = "0"
        with (evidence / "menubar.log").open("w") as log:
            result = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT,
                                    env=env, timeout=270)
        (evidence / "fixture.json").write_text(json.dumps(requests, indent=2))
        self.assertEqual(result.returncode, 0, (evidence / "menubar.log").read_text()[-3000:])
        panel = json.loads((evidence / "panel.json").read_text())
        self.assertEqual(panel["canAlert"], has_meeting)
        self.assertTrue(panel["armShowsToast"], "baseline must receive the visual cue")
        self.assertEqual(panel["warning"], expect_panel)
        self.assertEqual(bool(panel["windows"]), expect_panel)
        self.assertEqual(panel["firstVisibleStreak"], next((offset for offset in offsets if offset >= 30), None) if expect_panel else None)
        with sqlite3.connect(f"file:{evidence}/behavior_experiments.sqlite?mode=ro", uri=True) as db:
            db.row_factory = sqlite3.Row
            rows = [dict(r) for r in db.execute("SELECT rowid,* FROM habit_events WHERE habit_type='monologue_streak' ORDER BY rowid LIMIT 10")]
        (evidence / "habit_events.json").write_text(json.dumps(rows, indent=2))
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(set(replayed), set(range(101, 101 + row_count)),
                         "must actually deliver background backfill to exercise deduplication")
        row = rows[0]
        self.assertEqual(row["turn_duration_sec"], duration)
        self.assertEqual(row["treatment_arm"], "baseline")
        meta = json.loads(row["metadata"])
        self.assertEqual(meta["timing_version"], "confirmed_speech_span_v1")
        self.assertEqual(meta["toast_shown"], expect_panel)
        self.assertEqual(meta["experiment_eligible"], has_meeting)
        self.assertEqual(meta["transcription_path"], "live_meeting")
        self.assertLess(meta["ingest_lag_sec_max"], 10)
        self.assertEqual(meta["design_version"], "speech_coach_settings_v1")
        if reward_device:
            self.assertTrue(meta["reward_requested"])
            with sqlite3.connect(f"file:{evidence}/behavior_experiments.sqlite?mode=ro", uri=True) as db:
                audit = [json.loads(r[0]) for r in db.execute("SELECT metadata FROM habit_events WHERE habit_type='pavlok_intervention'")]
            (evidence / "reward-device-audit.json").write_text(json.dumps(audit, indent=2))
            self.assertTrue(audit, "reward must reach actual device path")
            self.assertTrue(all(r["modality"] == "vibe" and r["intensity_percent"] == 30 for r in audit), audit)
            acks = [r for r in audit if r.get("device_acknowledged")]
            self.assertEqual(len(acks), 1, audit)
            self.assertIn("Good behavior reward", acks[0]["reason"])



if __name__ == "__main__":
    unittest.main()
