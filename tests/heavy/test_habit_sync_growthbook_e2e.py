#!/usr/bin/env python3
"""Explicit opt-in: upload a real coach E2E row and verify GrowthBook's data source.

Requires AIAGG_HEAVY=1, AIAGG_REMOTE_E2E=1 and AIAGG_COACH_E2E_SOURCE_DB pointing
at a completed isolated meeting E2E database. Uses the real sync-habits.ts uploader,
the configured HABITS_PG_URL and SSH host ovh. Never reads/writes production SQLite.

One clearly marked demo row is retained remotely per run. The test fetches the
actual GrowthBook exposure/fact SQL and checks that both exclude the synthetic row.
Evidence includes its event ID, server row, local sync acknowledgement and query
results. A warehouse row is not claimed to be an included experiment observation.
"""

import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import uuid

REPO = Path(__file__).resolve().parents[2]
ENABLED = os.environ.get("AIAGG_HEAVY") == "1" and os.environ.get("AIAGG_REMOTE_E2E") == "1"


def ssh_script(script):
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                             "ovh", "bash", "-s"], input=script, text=True,
                            capture_output=True, timeout=30)
    if result.returncode:
        raise AssertionError(f"SSH verification failed: {result.stderr[-2000:]}")
    return result.stdout.strip()


@unittest.skipUnless(ENABLED, "remote E2E: set AIAGG_HEAVY=1 and AIAGG_REMOTE_E2E=1")
@unittest.skipUnless(shutil.which("bun"), "bun not installed")
class HabitSyncGrowthBookE2E(unittest.TestCase):
    def test_verified_toast_row_reaches_growthbook_source_but_not_real_metrics(self):
        source = Path(os.environ["AIAGG_COACH_E2E_SOURCE_DB"]).resolve()
        production = Path.home() / ".ai-aggregator/behavior_experiments.sqlite"
        self.assertNotEqual(source, production, "source must be an isolated meeting E2E database")
        evidence = Path(os.environ.get("AIAGG_REMOTE_E2E_DIR") or
                        tempfile.mkdtemp(prefix="coach-growthbook-e2e-"))
        evidence.mkdir(parents=True, exist_ok=True)
        local = evidence / "upload.sqlite"
        self.assertFalse(local.exists(), "use a fresh evidence directory")
        with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as original:
            with sqlite3.connect(local) as copied:
                original.backup(copied)
        event_id = str(uuid.uuid4())
        session_id = "coach-e2e-" + uuid.uuid4().hex
        with sqlite3.connect(local) as db:
            rows = db.execute("SELECT event_id,metadata FROM habit_events LIMIT 10").fetchall()
            self.assertEqual(len(rows), 1, "expected the one verified meeting turn")
            source_event_id, raw = rows[0]
            db.row_factory = sqlite3.Row
            expected = dict(db.execute("SELECT * FROM habit_events").fetchone())
            meta = json.loads(raw)
            self.assertTrue(meta["toast_shown"])
            self.assertEqual(meta["transcription_path"], "live_meeting")
            meta.update(simulated=True, experiment_eligible=False,
                        e2e_run_id=session_id, source_e2e_event_id=source_event_id)
            db.execute("UPDATE habit_events SET event_id=?, session_id=?, call_category='demo', "
                       "metadata=?, synced_to_server=0", (event_id, session_id, json.dumps(meta)))

        # Import the production function. Its sole test seam is the local DB path;
        # credentials and all PostgreSQL insertion/acknowledgement logic are real.
        code = f'''
import {{ syncHabits }} from {json.dumps(str(REPO / "src/sync-habits.ts"))};
const first = await syncHabits({{localDbPath: {json.dumps(str(local))}}});
const second = await syncHabits({{localDbPath: {json.dumps(str(local))}}});
if (first !== 1 || second !== 0) throw new Error(`Unexpected sync counts: ${{first}}, ${{second}}`);
'''
        result = subprocess.run(["bun", "--eval", code], cwd=REPO,
                                capture_output=True, text=True, timeout=45)
        (evidence / "sync.log").write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout[-1000:] + result.stderr[-1000:])
        with sqlite3.connect(f"file:{local}?mode=ro", uri=True) as db:
            self.assertEqual(db.execute("SELECT synced_to_server FROM habit_events WHERE event_id=?",
                                        (event_id,)).fetchone(), (1,))

        # Read only the source identity and SQL; never export encrypted credentials.
        mongo_js = '''
const g=db.getSiblingDB("growthbook");
const ds=g.datasources.findOne({name:"Habits Telemetry (PostgreSQL)"});
const fact=g.facttables.findOne({id:"ftb_habit_events",datasource:ds.id});
print(JSON.stringify({id:ds.id,name:ds.name,type:ds.type,
 exposure:ds.settings.queries.exposure[0].query,fact:fact.sql}));
'''
        mongo_command = ('exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" '
                         '--password "$MONGO_INITDB_ROOT_PASSWORD" '
                         '--authenticationDatabase admin --eval "$(cat)"')
        config = json.loads(ssh_script(
            "set -e\ndocker exec -i biztools-growthbook-growthbook-mongo-1 sh -c " +
            shlex.quote(mongo_command) + " <<'COACH_MONGO_JS'\n" + mongo_js + "\nCOACH_MONGO_JS\n"))
        (evidence / "growthbook-source.json").write_text(json.dumps(config, indent=2))
        self.assertEqual(config["type"], "postgres")
        fact = config["fact"].rstrip("; \n")
        exposure = config["exposure"].rstrip("; \n")
        sql = f'''
BEGIN READ ONLY;
SELECT row_to_json(t) FROM (
 SELECT event_id,session_id,call_category,turn_duration_sec,treatment_arm,
        metadata->>'toast_shown' AS toast_shown,
        metadata->>'transcription_path' AS transcription_path,
        metadata->>'simulated' AS simulated,metadata->>'e2e_run_id' AS e2e_run_id,
        metadata, words_spoken, warning_fired_at, shock_fired_at, latency_to_yield_sec,
        breached_30s, breached_60s, was_rewarded
 FROM habit_events WHERE event_id='{event_id}'
) t;
SELECT json_build_object(
 'fact_count',(SELECT count(*) FROM ({fact}) f WHERE event_id='{event_id}'),
 'exposure_count',(SELECT count(*) FROM ({exposure}) e WHERE session_id='{session_id}')
);
ROLLBACK;
'''
        output = ssh_script("set -e\nsudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1 -d habits <<'COACH_SQL'\n" +
                            sql + "\nCOACH_SQL\n")
        results = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
        self.assertEqual(len(results), 2, output)
        row, counts = results
        (evidence / "remote-verification.json").write_text(json.dumps({
            "source_event_id": source_event_id, "remote_row": row,
            "growthbook_query_results": counts, "local_synced_to_server": 1,
            "second_sync_count": 0, "remote_demo_row_retained": True,
        }, indent=2))
        self.assertEqual(row["event_id"], event_id)
        self.assertEqual(row["e2e_run_id"], session_id)
        self.assertEqual(row["toast_shown"], "true")
        self.assertEqual(row["transcription_path"], "live_meeting")
        self.assertEqual(row["turn_duration_sec"], expected["turn_duration_sec"])
        for field in ("words_spoken", "warning_fired_at", "shock_fired_at", "latency_to_yield_sec",
                      "breached_30s", "breached_60s", "was_rewarded"):
            if isinstance(expected[field], float):
                self.assertAlmostEqual(row[field], expected[field], places=4, msg=field)
            else:
                self.assertEqual(row[field], expected[field], field)
        self.assertEqual(row["metadata"], meta, "all timing and intervention metadata must survive upload")
        self.assertEqual(row["simulated"], "true")
        self.assertEqual(row["call_category"], "demo")
        self.assertEqual(counts, {"fact_count": 0, "exposure_count": 0})
        print(f"GrowthBook E2E evidence: {evidence}; event_id={event_id}", flush=True)


if __name__ == "__main__":
    unittest.main()
