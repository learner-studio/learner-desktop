#!/usr/bin/env bun
/**
 * Re-import the Read AI historical baseline (data/historical_calls_export.json, written by
 * scripts/parse_readai_transcripts.py) through the learner-server RPCs:
 *
 *   recordCallTranscripts  ≤50 calls per batch
 *   recordHabitEvents      ≤500 events per batch
 *
 * Every row and every batch is validated against contract/desktop.ts.
 *
 *   bun scripts/import-baseline-via-rpc.ts            # --dry-run (default): build + validate, print counts
 *   bun scripts/import-baseline-via-rpc.ts --send     # needs LEARNER_API_URL and LEARNER_API_KEY
 *
 * Output is counts only; no transcript text, titles or names are printed.
 */
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { z } from 'zod'
import {
  DesktopCallTranscript,
  DesktopHabitEvent,
  RecordCallTranscriptsInput,
  RecordCallTranscriptsOutput,
  RecordHabitEventsInput,
  RecordHabitEventsOutput,
} from '../contract/desktop.js'
import { LearnerApiClient } from '../src/learner-api.js'

export const CLIENT_ID = 'ben-mbp'
export const CALLS_PER_BATCH = 50
export const EVENTS_PER_BATCH = 500
/** parse_readai_transcripts.py's NAMESPACE_UUID; call ids are uuid5(ns, "call:<session_id>"). */
export const NAMESPACE_UUID = 'e0b1e9e0-55d0-47c8-beb4-d791e36ffe8c'
const DEFAULT_EXPORT = join(import.meta.dir, '..', 'data', 'historical_calls_export.json')

type CallTranscript = z.infer<typeof DesktopCallTranscript>
type HabitEvent = z.infer<typeof DesktopHabitEvent>
type CallsInput = z.infer<typeof RecordCallTranscriptsInput>
type EventsInput = z.infer<typeof RecordHabitEventsInput>

/** RFC 4122 version-5 UUID (SHA-1), matching Python's uuid.uuid5. */
export function uuidv5(namespace: string, name: string): string {
  const ns = Buffer.from(namespace.replace(/-/g, ''), 'hex')
  const hash = createHash('sha1').update(ns).update(name, 'utf8').digest()
  hash[6] = (hash[6] & 0x0f) | 0x50
  hash[8] = (hash[8] & 0x3f) | 0x80
  const h = hash.subarray(0, 16).toString('hex')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`
}

export function callIdFor(sessionId: string): string {
  return uuidv5(NAMESPACE_UUID, `call:${sessionId}`)
}

/** SQLite/Python 0/1 (or "true"/"1") -> boolean; null/undefined -> false. */
export function toBool(v: unknown): boolean {
  if (typeof v === 'boolean') return v
  if (typeof v === 'number') return v !== 0
  if (typeof v === 'string') return ['1', 'true', 't', 'yes'].includes(v.trim().toLowerCase())
  return false
}

const WITH_OFFSET = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/

/** ISO-8601 with an offset; Python's `2026-02-05 20:01:25+01:00` gets its `T`. Naive times are refused, not guessed. */
export function toIsoWithOffset(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const s = v.trim().replace(/^(\d{4}-\d{2}-\d{2}) (\d)/, '$1T$2')
  return WITH_OFFSET.test(s) ? s : null
}

const numOrNull = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : v == null ? null : Number.isFinite(Number(v)) ? Number(v) : null)
const strOrNull = (v: unknown): string | null => (typeof v === 'string' ? v : v == null ? null : String(v))

/** Lines of `clean_transcript` that are not `(MM:SS) Speaker: text` (or `(H:MM:SS)`). */
export function nonConformingTranscriptLines(t: string): number {
  return t.split('\n').filter((l) => l.trim() !== '' && !/^\(\d+:\d{2}(:\d{2})?\) [^:]+: /.test(l)).length
}

// biome-ignore lint: rows come from JSON
type Row = Record<string, any>

export function mapCall(c: Row, importerSource?: string): unknown {
  return {
    callId: callIdFor(String(c.session_id)),
    sessionId: c.session_id,
    filename: strOrNull(c.filename),
    meetingTitle: strOrNull(c.meeting_title),
    platform: strOrNull(c.platform),
    eventTime: toIsoWithOffset(c.event_time),
    participants: Array.isArray(c.participants) ? c.participants : [],
    benPresent: c.ben_present == null ? null : toBool(c.ben_present),
    benSpoke: c.ben_spoke == null ? null : toBool(c.ben_spoke),
    isDemo: toBool(c.is_demo),
    callCategory: strOrNull(c.call_category),
    totalTurns: numOrNull(c.total_turns),
    benTurns: numOrNull(c.ben_turns),
    benTotalSpeechSec: numOrNull(c.ben_total_speech_sec),
    cleanTranscript: c.clean_transcript ?? '',
    metadata: { ...(c.metadata ?? {}), ...(importerSource && !c.metadata?.source ? { source: importerSource } : {}) },
  }
}

/** `callApp` comes from the call's own platform (one source of truth), as ingest did. */
export function mapEvent(e: Row, platformBySession: Map<string, string | null>): unknown {
  return {
    eventId: e.event_id,
    sessionId: e.session_id,
    callApp: platformBySession.get(e.session_id) ?? strOrNull(e.call_app),
    callCategory: strOrNull(e.call_category),
    timestamp: toIsoWithOffset(e.timestamp),
    habitType: e.habit_type,
    treatmentArm: strOrNull(e.treatment_arm),
    turnDurationSec: numOrNull(e.turn_duration_sec),
    wordsSpoken: numOrNull(e.words_spoken),
    // The old warning_fired_at / shock_fired_at columns already hold streak seconds.
    warningFiredAtSec: numOrNull(e.warning_fired_at),
    shockFiredAtSec: numOrNull(e.shock_fired_at),
    latencyToYieldSec: numOrNull(e.latency_to_yield_sec),
    breached30s: toBool(e.breached_30s),
    breached60s: toBool(e.breached_60s),
    wasRewarded: toBool(e.was_rewarded),
    metadata: e.metadata ?? {},
  }
}

export interface BuildResult {
  callBatches: CallsInput[]
  eventBatches: EventsInput[]
  calls: number
  events: number
  /** `<kind>:<field>:<zod code>` -> rows refused. */
  failures: Map<string, number>
  transcriptLinesNonConforming: number
}

function chunk<T>(xs: T[], n: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n))
  return out
}

export function buildBatches(exportData: Row, clientId = CLIENT_ID): BuildResult {
  const rawCalls: Row[] = exportData.calls ?? []
  const rawEvents: Row[] = exportData.habit_events ?? []
  const failures = new Map<string, number>()
  const fail = (key: string) => failures.set(key, (failures.get(key) ?? 0) + 1)
  const note = (kind: string, err: z.ZodError) => {
    const first = err.issues[0]
    fail(`${kind}:${first.path.join('.') || '(root)'}:${first.code}`)
  }

  const calls: CallTranscript[] = []
  let transcriptLinesNonConforming = 0
  for (const c of rawCalls) {
    const r = DesktopCallTranscript.safeParse(mapCall(c, exportData.importer_source))
    if (!r.success) {
      note('call', r.error)
      continue
    }
    transcriptLinesNonConforming += nonConformingTranscriptLines(r.data.cleanTranscript)
    calls.push(r.data)
  }

  const platformBySession = new Map<string, string | null>(rawCalls.map((c) => [c.session_id, c.platform ?? null]))
  const knownSessions = new Set(calls.map((c) => c.sessionId))
  const events: HabitEvent[] = []
  for (const e of rawEvents) {
    const r = DesktopHabitEvent.safeParse(mapEvent(e, platformBySession))
    if (!r.success) {
      note('event', r.error)
      continue
    }
    if (!knownSessions.has(r.data.sessionId)) fail('event:sessionId:no-matching-call')
    events.push(r.data)
  }

  const callBatches: CallsInput[] = []
  for (const part of chunk(calls, CALLS_PER_BATCH)) {
    const r = RecordCallTranscriptsInput.safeParse({ clientId, calls: part })
    if (r.success) callBatches.push(r.data)
    else note('callBatch', r.error)
  }
  const eventBatches: EventsInput[] = []
  for (const part of chunk(events, EVENTS_PER_BATCH)) {
    const r = RecordHabitEventsInput.safeParse({ clientId, events: part })
    if (r.success) eventBatches.push(r.data)
    else note('eventBatch', r.error)
  }

  return { callBatches, eventBatches, calls: calls.length, events: events.length, failures, transcriptLinesNonConforming }
}

async function send(built: BuildResult): Promise<number> {
  const url = process.env.LEARNER_API_URL
  const key = process.env.LEARNER_API_KEY
  if (!url || !key) {
    console.error('--send refuses to run without both LEARNER_API_URL and LEARNER_API_KEY set.')
    return 2
  }
  const api = new LearnerApiClient({ baseUrl: url, getKey: () => key })
  const jobs: [string, unknown, z.ZodTypeAny][] = [
    ...built.callBatches.map((b) => ['recordCallTranscripts', b, RecordCallTranscriptsOutput] as [string, unknown, z.ZodTypeAny]),
    ...built.eventBatches.map((b) => ['recordHabitEvents', b, RecordHabitEventsOutput] as [string, unknown, z.ZodTypeAny]),
  ]
  for (let i = 0; i < jobs.length; i++) {
    const [name, input, output] = jobs[i]
    for (let attempt = 0; ; attempt++) {
      const res = await api.call(name, input, output)
      if (res.kind === 'ok') {
        console.log(`[${i + 1}/${jobs.length}] ${name}: ${JSON.stringify(res.data)}`)
        break
      }
      if (res.kind === 'transient' && attempt < 6) {
        const wait = Math.min(300_000, 2_000 * 2 ** attempt) * (0.8 + 0.4 * Math.random())
        console.log(`[${i + 1}/${jobs.length}] ${name}: ${res.status ?? 'network error'}; retrying in ${Math.round(wait / 1000)}s`)
        await new Promise((r) => setTimeout(r, wait))
        continue
      }
      console.error(`[${i + 1}/${jobs.length}] ${name}: ${res.kind} (HTTP ${res.status}); stopping. Batches are idempotent, so rerunning is safe.`)
      return 1
    }
  }
  return 0
}

async function main(argv: string[]): Promise<number> {
  const sendMode = argv.includes('--send')
  const fileArg = argv.find((a) => !a.startsWith('--'))
  const exportFile = fileArg ?? DEFAULT_EXPORT
  if (!existsSync(exportFile)) {
    console.error(`Export not found: ${exportFile}. Run scripts/parse_readai_transcripts.py first.`)
    return 1
  }
  const data = JSON.parse(readFileSync(exportFile, 'utf8'))
  const built = buildBatches(data)

  console.log(`mode: ${sendMode ? 'send' : 'dry-run'}`)
  console.log(`source rows: calls=${(data.calls ?? []).length} events=${(data.habit_events ?? []).length}`)
  console.log(`valid rows:  calls=${built.calls} events=${built.events}`)
  console.log(
    `batches:     recordCallTranscripts=${built.callBatches.length} (≤${CALLS_PER_BATCH}) recordHabitEvents=${built.eventBatches.length} (≤${EVENTS_PER_BATCH})`,
  )
  console.log(`transcript lines not in "(MM:SS) Speaker: text" form: ${built.transcriptLinesNonConforming}`)
  console.log(`validation failures: ${[...built.failures.values()].reduce((a, b) => a + b, 0)}`)
  for (const [reason, n] of [...built.failures].sort()) console.log(`  ${reason}: ${n}`)

  if (!sendMode) return built.failures.size > 0 ? 1 : 0
  if (built.failures.size > 0) {
    console.error('Refusing to send while any row fails validation.')
    return 1
  }
  return send(built)
}

if (import.meta.main) {
  process.exit(await main(process.argv.slice(2)))
}
