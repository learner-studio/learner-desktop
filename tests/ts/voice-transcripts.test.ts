import { describe, expect, test } from 'bun:test'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseConversationMarkdown } from '../../src/parsers/ai-vault-messages.js'
import {
  type ChatGptConversation,
  fillTranscripts,
  fillVoiceTranscripts,
  hasVoiceGaps,
  transcriptsByTime,
} from '../../src/voice-transcripts.js'

// Fictional voice chat in ai-vault's layout: audio links, no text.
const T1 = '2025-03-01T09:00:00.125Z'
const T2 = '2025-03-01T09:00:04.500Z'
const T3 = '2025-03-01T09:01:00.000Z'
const VOICE_MD = [
  '# Morning plan',
  '',
  '**Provider:** chatgpt',
  '**Created:** 2025-03-01T09:00:00.000Z',
  '**Updated:** 2025-03-01T09:01:00.000Z',
  '**Messages:** 3',
  '',
  '---',
  '',
  '## User',
  `*${T1}*`,
  '',
  '',
  '',
  '**Attachments:**',
  '- [audio: file_aaa](https://chatgpt.com/backend-api/files/download/file_aaa)',
  '',
  '---',
  '',
  '## Assistant',
  `*${T2}*`,
  '',
  '',
  '',
  '**Attachments:**',
  '- [audio: file_bbb](https://chatgpt.com/backend-api/files/download/file_bbb)',
  '',
  '---',
  '',
  '## User',
  `*${T3}*`,
  '',
  'A typed follow-up.',
  '',
  '---',
  '',
].join('\n')

const at = (iso: string) => Date.parse(iso) / 1000

const API: ChatGptConversation = {
  mapping: {
    a: {
      message: {
        create_time: at(T1),
        content: {
          parts: [
            { content_type: 'audio_transcription', text: 'What should I do first today?' },
            { content_type: 'real_time_user_audio_video_asset_pointer' },
          ],
        },
      },
    },
    b: {
      message: {
        create_time: at(T2),
        content: { parts: [{ content_type: 'audio_transcription', text: 'Start with the walk.\nThen email.' }, { content_type: 'audio_asset_pointer' }] },
      },
    },
    c: { message: { create_time: at(T3), content: { parts: ['A typed follow-up.'] } } },
    root: { message: null },
  },
}

describe('voice transcripts', () => {
  test('a voice chat without text is found; a typed one is not', () => {
    expect(hasVoiceGaps(VOICE_MD)).toBe(true)
    expect(hasVoiceGaps(VOICE_MD.replace(/\[audio: [^\]]+\]/g, '[image: x]'))).toBe(false)
  })

  test('transcripts are keyed by the timestamp ai-vault writes', () => {
    const t = transcriptsByTime(API)
    expect(t.get(T1)).toBe('What should I do first today?')
    expect(t.get(T2)).toBe('Start with the walk.\nThen email.')
    expect(t.has(T3)).toBe(false)
  })

  test('filled sections parse into messages the watcher archives', () => {
    const before = parseConversationMarkdown({ content: VOICE_MD, provider: 'chatgpt', conversationId: 'c1' })
    expect(before.document?.messages.length).toBe(1)

    const { md, filled, missing } = fillTranscripts(VOICE_MD, transcriptsByTime(API))
    expect([filled, missing]).toEqual([2, 0])
    expect(hasVoiceGaps(md)).toBe(false)
    const after = parseConversationMarkdown({ content: md, provider: 'chatgpt', conversationId: 'c1' })
    expect(after.problems).toEqual([])
    expect(after.document?.messages).toEqual([
      { role: 'user', text: 'What should I do first today?', at: T1 },
      { role: 'assistant', text: 'Start with the walk.\nThen email.', at: T2 },
      { role: 'user', text: 'A typed follow-up.', at: T3 },
    ])
  })

  test('filling twice changes nothing', () => {
    const once = fillTranscripts(VOICE_MD, transcriptsByTime(API)).md
    const twice = fillTranscripts(once, transcriptsByTime(API))
    expect(twice.md).toBe(once)
    expect(twice.filled).toBe(0)
  })

  test('a message with no transcript stays blank and is counted', () => {
    const partial: ChatGptConversation = { mapping: { a: API.mapping!.a } }
    const r = fillTranscripts(VOICE_MD, transcriptsByTime(partial))
    expect([r.filled, r.missing]).toEqual([1, 1])
  })

  test('the run stops at a rate limit and only rewrites files it filled', async () => {
    const root = mkdtempSync(join(tmpdir(), 'voice-'))
    const files = ['c1', 'c2', 'c3'].map((id) => {
      mkdirSync(join(root, id))
      const f = join(root, id, 'conversation.md')
      writeFileSync(f, VOICE_MD)
      return f
    })
    const statuses: Record<string, number> = { c1: 200, c2: 429, c3: 200 }
    const asked: string[] = []
    const s = await fillVoiceTranscripts(files, {
      delayMs: 0,
      log: () => {},
      open: async () => ({
        fetchConversation: async (id) => {
          asked.push(id)
          return statuses[id] === 200 ? { status: 200, body: API } : { status: statuses[id] }
        },
        close: async () => {},
      }),
    })
    expect(asked).toEqual(['c1', 'c2'])
    expect(s).toMatchObject({ candidates: 3, updated: 1, filled: 2, stopped: 'rate-limited' })
    expect(hasVoiceGaps(readFileSync(files[0], 'utf8'))).toBe(false)
    expect(readFileSync(files[2], 'utf8')).toBe(VOICE_MD)
  })
})
