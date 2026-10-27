"""Verify intervention records persist without becoming speaking trials."""
import json
import pathlib
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from tests.swift_source import swift_source


@unittest.skipUnless(shutil.which('swiftc'), 'requires Swift')
class InterventionPersistenceTest(unittest.TestCase):
    def test_request_and_ack_survive_close_with_same_operation_id(self):
        source = swift_source()
        logger = source.split('class HabitEventLogger {', 1)[1].split('\n// MARK: - learner-server API', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            logger = logger.replace('let dir = home + "/.ai-aggregator"',
                                    'let dir = ' + json.dumps(directory))
            harness = 'import Foundation\nimport SQLite3\nclass HabitEventLogger {' + logger + '''
let logger = HabitEventLogger()
for phase in ["requested", "transport_result"] {
    logger.logTurn(habitType: "pavlok_intervention", sessionId: "manual_test_fixture",
        callApp: "Manual device test", callCategory: "device_test", treatmentArm: "manual_test",
        turnDurationSec: 0, wordsSpoken: 0, warningFiredAt: nil, shockFiredAt: nil,
        latencyToYieldSec: nil, breached30s: false, breached60s: false, wasRewarded: false,
        metadata: ["operation_id": "fixture", "phase": phase, "modality": "beep",
                   "intensity_percent": 40, "device_acknowledged": phase == "transport_result"])
}
logger.waitUntilIdle()
assert(logger.getTotalTrialCount() == 0)
assert(logger.getUnsyncedCount() == 2)
logger.close()
'''
            src = pathlib.Path(directory) / 'main.swift'
            binary = pathlib.Path(directory) / 'audit'
            src.write_text(harness)
            build = subprocess.run(['swiftc', '-lsqlite3', str(src), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with sqlite3.connect(str(pathlib.Path(directory) / 'behavior_experiments.sqlite')) as db:
                rows = db.execute('select habit_type, metadata, synced_to_server from habit_events order by rowid').fetchall()
            self.assertEqual(len(rows), 2)
            self.assertTrue(all(row[0] == 'pavlok_intervention' and row[2] == 0 for row in rows))
            metadata = [json.loads(row[1]) for row in rows]
            self.assertEqual([m['operation_id'] for m in metadata], ['fixture', 'fixture'])
            self.assertEqual([m['device_acknowledged'] for m in metadata], [False, True])
            self.assertEqual(metadata[1]['intensity_percent'], 40)

if __name__ == '__main__':
    unittest.main()
