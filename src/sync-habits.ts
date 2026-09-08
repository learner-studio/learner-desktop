import { Database } from "bun:sqlite";
import { SQL } from "bun";
import { homedir } from "os";
import { join } from "path";

const LOCAL_DB_PATH = join(homedir(), ".ai-aggregator", "behavior_experiments.sqlite");
const REMOTE_PG_URL = process.env.HABITS_PG_URL ?? "";

export async function syncHabits() {
  if (!REMOTE_PG_URL) {
    // Fail loudly: a silent skip here strands rows in the local sqlite indefinitely.
    throw new Error("HABITS_PG_URL is not set (cwd must be the project root so .env loads). See .env.example.");
  }

  const localDb = new Database(LOCAL_DB_PATH);

  // Ensure local schema exists
  localDb.run(`
    CREATE TABLE IF NOT EXISTS habit_events (
      event_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      call_app TEXT,
      call_category TEXT DEFAULT 'work',
      timestamp TEXT NOT NULL,
      habit_type TEXT NOT NULL,
      treatment_arm TEXT NOT NULL,
      turn_duration_sec REAL NOT NULL,
      words_spoken INTEGER DEFAULT 0,
      warning_fired_at REAL,
      shock_fired_at REAL,
      latency_to_yield_sec REAL,
      breached_30s INTEGER DEFAULT 0,
      breached_60s INTEGER DEFAULT 0,
      was_rewarded INTEGER DEFAULT 0,
      metadata TEXT,
      synced_to_server INTEGER DEFAULT 0
    );
  `);

  const unsynced = localDb.query(`
    SELECT * FROM habit_events WHERE synced_to_server = 0 ORDER BY timestamp ASC LIMIT 100
  `).all() as any[];

  if (unsynced.length === 0) {
    console.log("[HabitSync] No pending habit events to sync.");
    localDb.close();
    return 0;
  }

  console.log(`[HabitSync] Pushing ${unsynced.length} habit events to PostgreSQL on OVH...`);

  let sql: SQL;
  try {
    sql = new SQL(REMOTE_PG_URL);
  } catch (err) {
    console.error("[HabitSync] Failed to connect to PostgreSQL (is the tunnel active?):", err);
    localDb.close();
    return 0;
  }

  let syncedCount = 0;
  for (const row of unsynced) {
    try {
      await sql`
        INSERT INTO habit_events (
          event_id, session_id, call_app, call_category, timestamp,
          habit_type, treatment_arm, turn_duration_sec, words_spoken,
          warning_fired_at, shock_fired_at, latency_to_yield_sec,
          breached_30s, breached_60s, was_rewarded, metadata
        ) VALUES (
          ${row.event_id}, ${row.session_id}, ${row.call_app}, ${row.call_category},
          ${row.timestamp}, ${row.habit_type}, ${row.treatment_arm},
          ${row.turn_duration_sec}, ${row.words_spoken}, ${row.warning_fired_at},
          ${row.shock_fired_at}, ${row.latency_to_yield_sec}, ${row.breached_30s},
          ${row.breached_60s}, ${row.was_rewarded}, ${row.metadata ? JSON.parse(row.metadata) : {}}
        )
        ON CONFLICT (event_id) DO NOTHING;
      `;

      localDb.run("UPDATE habit_events SET synced_to_server = 1 WHERE event_id = ?", [row.event_id]);
      syncedCount++;
    } catch (insertErr) {
      console.error(`[HabitSync] Failed to insert event ${row.event_id}:`, insertErr);
    }
  }

  await sql.close();
  localDb.close();
  console.log(`[HabitSync] Successfully synchronized ${syncedCount}/${unsynced.length} events to OVH.`);
  return syncedCount;
}

if (import.meta.main) {
  syncHabits()
    .then((count) => {
      process.exit(0);
    })
    .catch((err) => {
      console.error("[HabitSync] Error:", err);
      process.exit(1);
    });
}
