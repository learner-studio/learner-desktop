import { describe, expect, test } from 'bun:test'
import { RecordCallTranscriptsInput, RecordHabitEventsInput } from '../../contract/desktop.js'
import {
  buildBatches,
  callIdFor,
  mapCall,
  mapEvent,
  nonConformingTranscriptLines,
  toBool,
  toIsoWithOffset,
  uuidv5,
} from '../../scripts/import-baseline-via-rpc.js'

function call(i: number, over: Record<string, unknown> = {}) {
  return {
    session_id: `readai_20260205_call_${i}`,
    filename: `call ${i}.docx`,
    meeting_title: `Call ${i}`,
    platform: 'Zoom',
    event_time: '2026-02-05T20:00:00+01:00',
    participants: ['the owner', 'Other Person'],
    ben_present: true,
    ben_spoke: true,
    is_demo: false,
    call_category: 'work',
    total_turns: 2,
    ben_turns: 1,
    ben_total_speech_sec: 12.5,
    clean_transcript: '(00:01) the owner: Hello.\n(00:05) Other Person: Hi.',
    metadata: { is_solo: false, transcript_sha256: 'abc' },
    ...over,
  }
}

function event(i: number, session: string, over: Record<string, unknown> = {}) {
  return {
    event_id: uuidv5('e0b1e9e0-55d0-47c8-beb4-d791e36ffe8c', `${session}:${i}`),
    session_id: session,
    call_app: 'Meet',
    call_category: 'work',
    timestamp: '2026-02-05T20:01:25+01:00',
    habit_type: 'monologue_streak',
    treatment_arm: 'baseline',
    turn_duration_sec: 41.0,
    words_spoken: 90,
    warning_fired_at: 30,
    shock_fired_at: null,
    latency_to_yield_sec: null,
    breached_30s: 1,
    breached_60s: 0,
    was_rewarded: 0,
    metadata: { source: 'readai_docx_import_v2' },
    ...over,
  }
}

describe('helpers', () => {
  test('uuidv5 matches Python uuid.uuid5', () => {
    // python3 -c "import uuid; print(uuid.uuid5(uuid.UUID('e0b1e9e0-55d0-47c8-beb4-d791e36ffe8c'), 'call:abc'))"
    expect(callIdFor('abc')).toBe('346d04eb-3221-5bc8-80b7-411f145752e9')
    expect(callIdFor('abc')).toBe(callIdFor('abc'))
  })

  test('toBool handles 0/1, strings and null', () => {
    expect([1, 0, true, false, '1', 'true', '0', null, undefined].map(toBool)).toEqual([true, false, true, false, true, true, false, false, false])
  })

  test('timestamps keep their offset; a space separator gets a T; naive times are refused', () => {
    expect(toIsoWithOffset('2026-02-05T20:01:25+01:00')).toBe('2026-02-05T20:01:25+01:00')
    expect(toIsoWithOffset('2026-02-05 20:01:25.123456-08:00')).toBe('2026-02-05T20:01:25.123456-08:00')
    expect(toIsoWithOffset('2026-02-05T20:01:25Z')).toBe('2026-02-05T20:01:25Z')
    expect(toIsoWithOffset('2026-02-05T20:01:25')).toBeNull()
    expect(toIsoWithOffset(null)).toBeNull()
  })

  test('transcript line format check', () => {
    expect(nonConformingTranscriptLines('(00:01) A: x\n(1:02:03) B: y\n\n')).toBe(0)
    expect(nonConformingTranscriptLines('(00:01) A: x\nstray line')).toBe(1)
  })
})

describe('mapping', () => {
  test('a call maps to camelCase with a stable uuid callId', () => {
    const m = mapCall(call(1), 'readai_docx_import_v2') as Record<string, unknown>
    expect(m).toMatchObject({
      callId: callIdFor('readai_20260205_call_1'),
      sessionId: 'readai_20260205_call_1',
      meetingTitle: 'Call 1',
      eventTime: '2026-02-05T20:00:00+01:00',
      benPresent: true,
      isDemo: false,
      totalTurns: 2,
      benTotalSpeechSec: 12.5,
      cleanTranscript: '(00:01) the owner: Hello.\n(00:05) Other Person: Hi.',
      metadata: { is_solo: false, transcript_sha256: 'abc', source: 'readai_docx_import_v2' },
    })
  })

  test('an event maps booleans, streak seconds, and callApp from the call platform', () => {
    const m = mapEvent(event(1, 's1'), new Map([['s1', 'Zoom']])) as Record<string, unknown>
    expect(m).toMatchObject({
      sessionId: 's1',
      callApp: 'Zoom',
      breached30s: true,
      breached60s: false,
      wasRewarded: false,
      warningFiredAtSec: 30,
      shockFiredAtSec: null,
      turnDurationSec: 41,
      wordsSpoken: 90,
    })
    const noCall = mapEvent(event(2, 's2'), new Map()) as Record<string, unknown>
    expect(noCall.callApp).toBe('Meet')
  })
})

describe('buildBatches', () => {
  test('splits into ≤50 calls and ≤500 events, all valid against the Input schemas', () => {
    const calls = Array.from({ length: 120 }, (_, i) => call(i))
    const events = calls.flatMap((c, i) => Array.from({ length: 10 }, (_, j) => event(j, c.session_id, { event_id: uuidv5('e0b1e9e0-55d0-47c8-beb4-d791e36ffe8c', `${i}:${j}`) })))
    const r = buildBatches({ importer_source: 'readai_docx_import_v2', calls, habit_events: events })
    expect(r.calls).toBe(120)
    expect(r.events).toBe(1200)
    expect(r.callBatches.map((b) => b.calls.length)).toEqual([50, 50, 20])
    expect(r.eventBatches.map((b) => b.events.length)).toEqual([500, 500, 200])
    expect(r.failures.size).toBe(0)
    for (const b of r.callBatches) {
      expect(b.clientId).toBe('ben-mbp')
      expect(RecordCallTranscriptsInput.safeParse(b).success).toBe(true)
    }
    for (const b of r.eventBatches) expect(RecordHabitEventsInput.safeParse(b).success).toBe(true)
    // Contract defaults are filled in.
    expect(r.callBatches[0].calls[0].learnerSpeakers).toEqual(['the owner', 'the owner', 'the owner', 'the owner'])
  })

  test('invalid rows are dropped and counted by reason', () => {
    const r = buildBatches({
      calls: [call(1), call(2, { event_time: '2026-02-05T20:00:00' })],
      habit_events: [event(1, 'readai_20260205_call_1'), event(2, 'readai_20260205_call_1', { event_id: 'not-a-uuid' }), event(3, 'nope')],
    })
    expect(r.calls).toBe(1)
    expect(r.events).toBe(2)
    expect(Object.fromEntries(r.failures)).toEqual({
      'call:eventTime:invalid_type': 1,
      'event:eventId:invalid_format': 1,
      'event:sessionId:no-matching-call': 1,
    })
  })
})

describe('--send', () => {
  test('refuses without LEARNER_API_URL and LEARNER_API_KEY', async () => {
    const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs')
    const { join } = await import('node:path')
    const { tmpdir } = await import('node:os')
    const dir = mkdtempSync(join(tmpdir(), 'baseline-'))
    const file = join(dir, 'export.json')
    writeFileSync(file, JSON.stringify({ calls: [call(1)], habit_events: [event(1, 'readai_20260205_call_1')] }))
    const env = { ...process.env }
    delete env.LEARNER_API_URL
    delete env.LEARNER_API_KEY
    const p = Bun.spawnSync(['bun', join(import.meta.dir, '../../scripts/import-baseline-via-rpc.ts'), '--send', file], { env })
    rmSync(dir, { recursive: true, force: true })
    expect(p.exitCode).toBe(2)
    expect(p.stderr.toString()).toContain('refuses to run')
  })
})
