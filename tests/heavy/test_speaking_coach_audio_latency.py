#!/usr/bin/env python3
"""Audio→real Screenpipe STT→coach HTTP poller→visible NSPanel latency benchmark.

Opt in with AIAGG_HEAVY=1 AIAGG_AUDIO_E2E=1. Generates two local TTS WAV files,
streams 2.25s slices on a real-time schedule through the configured Screenpipe
/v1/audio/transcriptions engine, and feeds the returned text to the production
coach's live-meeting poller. No audio is played into the microphone or call.

This measures file-upload STT plus the coach, not Screenpipe's capture/event/DB
pipeline. The upload route adds decoding/session overhead. Live chunk size mirrors
the 2s minimum / 750ms flush cadence; no recorder settings are changed.
"""

import array
import datetime
import hashlib
import http.server
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
import uuid
import wave
from tests.swift_source import swift_source

REPO = Path(__file__).resolve().parents[2]
ENABLED = os.environ.get("AIAGG_HEAVY") == "1" and os.environ.get("AIAGG_AUDIO_E2E") == "1"
PASSAGE = """I would like to explain the plan for our next project in a little more detail.
The first step is to understand what people need from the product and what gets in
their way today. We can start with a few conversations and then compare the answers.
After that we should choose one small problem that we can solve and measure clearly.
I think the team will work better if everyone knows what a successful result looks
like before we begin. We also need time to check the details and make sure that the
changes do what we intended. When the first version is ready we can ask people to
try it and tell us where they get confused. We should listen carefully to those
comments instead of assuming that our original plan was right about everything.
Some improvements may be simple while others will need more thought and discussion.
The important thing is to keep a clear record of what we learned and what we changed.
At the end of each week we can review the results together and decide what to do
next. This gives us a practical way to make progress without losing sight of the
people who will use the product every day. I would also like to leave enough time
for questions so that everyone can share their concerns before we finish the plan.
"""

HARNESS = r'''
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let evidence = ProcessInfo.processInfo.environment["COACH_AUDIO_EVIDENCE"]!
let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Coach audio latency benchmark")
HabitExperimentManager.shared.currentMode = .baseline
let monitor = TalkTimeMonitor.shared
var gateAt: Double?
var visibleAt: Double?
var fullAt: Double?
var streakAtFire: Double?
monitor.onStreakUpdated = { streak in
    if monitor.canAlert && streak >= monitor.warningThreshold && gateAt == nil {
        gateAt = Date().timeIntervalSince1970
        streakAtFire = streak
    }
}
let poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in monitor.tick() }
let observe = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
    let panels = app.windows.filter { $0 is NSPanel && $0.isVisible }
    if visibleAt == nil && panels.contains(where: { $0.alphaValue > 0.05 }) {
        visibleAt = Date().timeIntervalSince1970
    }
    if fullAt == nil && panels.contains(where: { $0.alphaValue >= 0.99 }) {
        fullAt = Date().timeIntervalSince1970
        let values: [String: Any] = ["gate_unix": gateAt as Any? ?? NSNull(),
            "visible_unix": visibleAt as Any? ?? NSNull(), "fully_visible_unix": fullAt!,
            "streak_at_fire": streakAtFire as Any? ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted,.sortedKeys])
        try! data.write(to: URL(fileURLWithPath: evidence + "/panel-timing.json"))
        print("[AudioE2E] VISIBLE: \(values)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            poll.invalidate()
            monitor.resetStreak()
            HabitEventLogger.shared.waitUntilIdle()
            HabitEventLogger.shared.close()
            exit(0)
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
    print("[AudioE2E] FAILED: no visible warning within 180 seconds")
    exit(2)
}
app.run()
'''


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()


@unittest.skipUnless(ENABLED, "audio benchmark: set AIAGG_HEAVY=1 and AIAGG_AUDIO_E2E=1")
class CoachAudioLatency(unittest.TestCase):
    def test_two_speaking_rates_through_real_stt(self):
        for tool in ("say", "ffmpeg", "swiftc"):
            self.assertIsNotNone(shutil.which(tool), f"missing required tool: {tool}")
        settings = json.loads((Path.home() / ".screenpipe/store.bin").read_text())["settings"]
        self.assertEqual((settings["audioTranscriptionEngine"], settings["audioChunkDuration"], settings["transcriptionMode"]),
                         ("whisper-tiny-quantized", 5, "realtime"))
        root = Path(os.environ.get("AIAGG_AUDIO_E2E_DIR") or tempfile.mkdtemp(prefix="coach-audio-e2e-"))
        root.mkdir(parents=True, exist_ok=True)
        source = swift_source()
        results = []
        for rate in (120, 200):
            results.append(self.run_sample(root, rate, source))
            (root / "results.json").write_text(json.dumps(results, indent=2))
        self.assert_rate_independent_results(results)
        after = json.loads((Path.home() / ".screenpipe/store.bin").read_text())["settings"]
        for key in ("audioTranscriptionEngine", "audioChunkDuration", "transcriptionMode"):
            self.assertEqual(settings[key], after[key])

    def assert_rate_independent_results(self, results):
        self.assertEqual(len(results), 2)
        # These controlled fixtures should cross on the same capture timestamp,
        # regardless of how many words the recognizer emitted at either rate.
        self.assertEqual([r["coach_streak_at_fire"] for r in results], [31.5, 31.5])
        self.assertEqual([r["trigger_chunk_id"] for r in results], [15, 15])
        for result in results:
            self.assertGreaterEqual(result["delay_after_30s_sec"], 0, "must not warn early")
            self.assertLess(result["delay_after_30s_sec"], 6, "controlled replay latency exceeded budget")
        self.assertLess(abs(results[0]["delay_after_30s_sec"] - results[1]["delay_after_30s_sec"]), 2)

    def run_sample(self, root, rate, original):
        evidence = root / f"speech-{rate}wpm"
        evidence.mkdir()
        text = evidence / "passage.txt"
        text.write_text(PASSAGE)
        subprocess.run(["say", "-v", "Samantha", "-r", "180", "-f", str(text),
                        "-o", str(evidence / "speech.aiff")], check=True, timeout=45)
        # Voice rate is not reliably literal WPM. Normalize the measured waveform
        # duration so both samples have an independently verifiable speaking rate.
        probe = subprocess.run(["ffmpeg", "-v", "error", "-i", str(evidence / "speech.aiff"),
                                "-ac", "1", "-ar", "16000", "-f", "s16le", "pipe:1"],
                               check=True, capture_output=True, timeout=30)
        base_duration = len(probe.stdout) / 32000
        target_duration = len(PASSAGE.split()) * 60 / rate
        tempo = base_duration / target_duration
        wav = evidence / "speech.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(evidence / "speech.aiff"),
                        "-af", f"atempo={tempo:.9f}", "-ac", "1", "-ar", "16000",
                        "-c:a", "pcm_s16le", str(wav)], check=True, timeout=30)
        with wave.open(str(wav)) as audio:
            pcm = audio.readframes(audio.getnframes())
        samples = array.array("h", pcm)
        duration = len(samples) / 16000
        # A transparent secondary reference, not a claim of phonetic/VAD truth:
        # cumulative 20ms frames with RMS >= .003 (-50.5 dBFS).
        active = []
        for i in range(0, len(samples), 320):
            frame = samples[i:i+320]
            rms = math.sqrt(sum(x*x for x in frame) / len(frame)) / 32768
            if rms >= .003:
                active.append(i / 16000)
        onset = active[0]
        energy_30 = active[1499] + .02 if len(active) >= 1500 else None
        self.assertGreater(duration, 35)
        suite = "coach-audio-e2e-" + uuid.uuid4().hex
        origin = [None]
        rows = []
        timings = []
        failures = []
        stop = threading.Event()

        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def reply(self, value):
                data = json.dumps(value).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                self.reply([{"meeting_app": f"Audio benchmark {rate} wpm", "meeting_end": None}])
            def do_POST(self):
                query = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["query"]
                if "meeting_transcript_segments" not in query:
                    self.reply([{"max_id": 0}] if "MAX(id)" in query else []); return
                if "MAX(id)" in query:
                    if origin[0] is None: origin[0] = time.time() + 1
                    self.reply([{"id": 0}]); return
                watermark = int(re.search(r"id > (\d+)", query).group(1))
                self.reply([r for r in list(rows) if r["id"] > watermark])

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        self.addCleanup(stop.set)
        self.addCleanup(lambda: subprocess.run(["defaults", "delete", suite], capture_output=True))
        source = original.split("// MARK: - Application Entrypoint")[0]
        source = source.replace("http://localhost:3030", f"http://127.0.0.1:{server.server_port}")
        source = source.replace("UserDefaults.standard", f'UserDefaults(suiteName: "{suite}")!')
        needle = 'let dir = home + "/.ai-aggregator"'
        self.assertEqual(source.count(needle), 1)
        source = source.replace(needle, 'let dir = ProcessInfo.processInfo.environment["COACH_AUDIO_EVIDENCE"]!')
        swift = evidence / "main.swift"; swift.write_text(source + HARNESS)
        binary = evidence / "coach-audio-e2e"
        built = subprocess.run(["swiftc", "-O", "-lsqlite3", str(swift), "-o", str(binary)], capture_output=True, text=True, timeout=120)
        (evidence / "build.log").write_text(built.stdout + built.stderr)
        self.assertEqual(built.returncode, 0, built.stderr[-2000:])

        def transcribe():
            try:
                while origin[0] is None and not stop.wait(.02): pass
                for i, start in enumerate(range(0, len(samples), 36000), 1):
                    if stop.is_set(): break
                    end = min(start + 36000, len(samples))
                    due = origin[0] + end / 16000
                    if stop.wait(max(0, due - time.time())): break
                    content = io.BytesIO()
                    with wave.open(content, "wb") as chunk:
                        chunk.setnchannels(1); chunk.setsampwidth(2); chunk.setframerate(16000)
                        chunk.writeframes(pcm[start*2:end*2])
                    boundary = "coach" + uuid.uuid4().hex
                    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="chunk.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()
                            + content.getvalue() + f'\r\n--{boundary}--\r\n'.encode())
                    req = urllib.request.Request(os.environ.get("SCREENPIPE_LOCAL_API_URL", "http://localhost:3030") + "/v1/audio/transcriptions",
                        data=body, headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
                    if os.environ.get("SCREENPIPE_LOCAL_API_KEY"):
                        req.add_header("Authorization", "Bearer " + os.environ["SCREENPIPE_LOCAL_API_KEY"])
                    sent = time.time()
                    with urllib.request.urlopen(req, timeout=25) as response: transcript = json.load(response)["text"]
                    received = time.time()
                    timings.append({"id": i, "audio_start": start/16000, "audio_end": end/16000,
                        "request_unix": sent, "response_unix": received, "stt_seconds": received-sent,
                        "queue_seconds": sent-due, "transcript": transcript})
                    rows.append({"id": i, "device_type": "input", "transcript": transcript,
                                 "captured_at": iso(origin[0] + start/16000)})
                    (evidence / "chunks.json").write_text(json.dumps(timings, indent=2))
            except Exception as exc:
                failures.append(repr(exc))

        worker = threading.Thread(target=transcribe, daemon=True); worker.start()
        print(f"Audio benchmark starting: {rate} wpm, {duration:.1f}s waveform", flush=True)
        try:
            with (evidence / "menubar.log").open("w") as log:
                result = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT,
                    env=dict(os.environ, COACH_AUDIO_EVIDENCE=str(evidence)), timeout=190)
        finally:
            stop.set(); worker.join(timeout=30)
        self.assertFalse(failures, failures)
        self.assertEqual(result.returncode, 0, (evidence / "menubar.log").read_text()[-2000:])
        panel = json.loads((evidence / "panel-timing.json").read_text())
        # Find the last ingested row preceding the first threshold crossing in logs.
        before = (evidence / "menubar.log").read_text().split("Stimulus trigger (30s warning)")[0]
        trigger_id = int(re.findall(r"Transcription \[(\d+)\]", before)[-1])
        trigger = next(t for t in timings if t["id"] == trigger_id)
        visible = panel["visible_unix"] - origin[0]
        threshold = onset + 30
        summary = {"requested_wpm": rate, "measured_script_wpm": len(PASSAGE.split())*60/duration,
            "sample": str(wav), "duration_sec": duration,
            "source_sha256": hashlib.sha256(original.encode()).hexdigest(),
            "speech_onset_sec": onset, "audio_30s_threshold_sec": threshold,
            "energy_active_30s_threshold_sec": energy_30,
            "visible_at_audio_sec": visible, "delay_after_30s_sec": visible-threshold,
            "delay_after_energy_active_30s_sec": visible-energy_30 if energy_30 else None,
            "coach_streak_at_fire": panel["streak_at_fire"], "trigger_chunk_id": trigger_id,
            "counting_and_chunking_sec": trigger["audio_end"]-threshold,
            "stt_and_queue_sec": trigger["response_unix"]-(origin[0]+trigger["audio_end"]),
            "poll_and_render_sec": panel["visible_unix"]-trigger["response_unix"],
            "median_stt_request_sec": statistics.median(t["stt_seconds"] for t in timings),
            "max_stt_queue_sec": max(t["queue_seconds"] for t in timings),
            "engine": "whisper-tiny-quantized", "chunk_sec": 2.25, "poll_sec": 1,
            "boundary": "real configured file-upload STT; simulated live HTTP rows; production coach and NSPanel"}
        (evidence / "timing.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary), flush=True)
        return summary


if __name__ == "__main__": unittest.main()
