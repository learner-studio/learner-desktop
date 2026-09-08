import { SQL } from "bun";
import { readFileSync, existsSync } from "fs";
import { join } from "path";

const EXPORT_FILE = join(import.meta.dir, "..", "data", "historical_calls_export.json");
const REMOTE_PG_URL = process.env.HABITS_PG_URL ?? "";

async function main() {
  if (!REMOTE_PG_URL) {
    console.error("HABITS_PG_URL is not set. Copy .env.example to .env and fill in the connection string.");
    process.exit(1);
  }

  if (!existsSync(EXPORT_FILE)) {
    console.error(`Export file not found at ${EXPORT_FILE}. Run parser first.`);
    process.exit(1);
  }

  console.log(`[Ingest] Reading parsed historical data from ${EXPORT_FILE}...`);
  const data = JSON.parse(readFileSync(EXPORT_FILE, "utf8"));
  const calls = data.calls || [];
  const events = data.habit_events || [];

  console.log(`[Ingest] Found ${calls.length} calls and ${events.length} habit events to ingest.`);

  // One source of truth for which app a call happened on: the transcript's platform.
  const platformBySession = new Map<string, string>(calls.map((c: any) => [c.session_id, c.platform]));
  console.log(`[Ingest] Connecting to PostgreSQL on OVH (${REMOTE_PG_URL.split("@")[1]})...`);

  const sql = new SQL(REMOTE_PG_URL);

  // 1. Ingest call transcripts
  console.log(`[Ingest] Ingesting ${calls.length} calls into call_transcripts...`);
  let callsInserted = 0;
  for (const c of calls) {
    try {
      await sql`
        INSERT INTO call_transcripts (
          session_id, filename, meeting_title, platform, event_time,
          participants, ben_present, ben_spoke, is_demo, call_category,
          total_turns, ben_turns, ben_total_speech_sec, clean_transcript, metadata
        ) VALUES (
          ${c.session_id}, ${c.filename}, ${c.meeting_title}, ${c.platform}, ${c.event_time},
          ${c.participants}, ${c.ben_present}, ${c.ben_spoke}, ${c.is_demo}, ${c.call_category},
          ${c.total_turns}, ${c.ben_turns}, ${c.ben_total_speech_sec}, ${c.clean_transcript}, ${c.metadata}
        )
        ON CONFLICT (session_id) DO UPDATE SET
          filename = EXCLUDED.filename,
          meeting_title = EXCLUDED.meeting_title,
          platform = EXCLUDED.platform,
          event_time = EXCLUDED.event_time,
          participants = EXCLUDED.participants,
          ben_present = EXCLUDED.ben_present,
          ben_spoke = EXCLUDED.ben_spoke,
          is_demo = EXCLUDED.is_demo,
          call_category = EXCLUDED.call_category,
          total_turns = EXCLUDED.total_turns,
          ben_turns = EXCLUDED.ben_turns,
          ben_total_speech_sec = EXCLUDED.ben_total_speech_sec,
          clean_transcript = EXCLUDED.clean_transcript,
          metadata = EXCLUDED.metadata;
      `;
      callsInserted++;
      if (callsInserted % 50 === 0 || callsInserted === calls.length) {
        console.log(`  Processed ${callsInserted}/${calls.length} calls...`);
      }
    } catch (err: any) {
      console.error(`  ❌ Failed inserting call ${c.session_id}:`, err.message);
    }
  }

  // 2. Ingest habit events in batches
  console.log(`[Ingest] Ingesting ${events.length} habit events into habit_events...`);
  let eventsInserted = 0;
  const batchSize = 100;
  for (let i = 0; i < events.length; i += batchSize) {
    const batch = events.slice(i, i + batchSize);
    for (const e of batch) {
      const callApp = platformBySession.get(e.session_id) ?? e.call_app;
      try {
        await sql`
          INSERT INTO habit_events (
            event_id, session_id, call_app, call_category, timestamp,
            habit_type, treatment_arm, turn_duration_sec, words_spoken,
            warning_fired_at, shock_fired_at, latency_to_yield_sec,
            breached_30s, breached_60s, was_rewarded, metadata
          ) VALUES (
            ${e.event_id}, ${e.session_id}, ${callApp}, ${e.call_category}, ${e.timestamp},
            ${e.habit_type}, ${e.treatment_arm}, ${e.turn_duration_sec}, ${e.words_spoken},
            ${e.warning_fired_at}, ${e.shock_fired_at}, ${e.latency_to_yield_sec},
            ${e.breached_30s}, ${e.breached_60s}, ${e.was_rewarded}, ${e.metadata}
          )
          ON CONFLICT (event_id) DO UPDATE SET
            session_id = EXCLUDED.session_id,
            call_app = EXCLUDED.call_app,
            call_category = EXCLUDED.call_category,
            timestamp = EXCLUDED.timestamp,
            habit_type = EXCLUDED.habit_type,
            treatment_arm = EXCLUDED.treatment_arm,
            turn_duration_sec = EXCLUDED.turn_duration_sec,
            words_spoken = EXCLUDED.words_spoken,
            breached_30s = EXCLUDED.breached_30s,
            breached_60s = EXCLUDED.breached_60s,
            was_rewarded = EXCLUDED.was_rewarded,
            metadata = EXCLUDED.metadata;
        `;
        eventsInserted++;
      } catch (err: any) {
        console.error(`  ❌ Failed inserting event ${e.event_id}:`, err.message);
      }
    }
    if ((i + batchSize) % 500 === 0 || i + batchSize >= events.length) {
      console.log(`  Processed ${Math.min(i + batchSize, events.length)}/${events.length} habit events...`);
    }
  }

  console.log(`\n[Ingest] ✅ Successfully ingested ${callsInserted}/${calls.length} calls into call_transcripts.`);
  console.log(`[Ingest] ✅ Successfully ingested ${eventsInserted}/${events.length} habit events into habit_events.`);
}

main().catch(err => {
  console.error("[Ingest] Fatal error:", err);
  process.exit(1);
});
