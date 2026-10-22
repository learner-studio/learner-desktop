import { describe, expect, test } from 'bun:test'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { DesktopConversationDocument } from '../../contract/desktop.js'
import {
  documentIdFor,
  findConversationFiles,
  parseConversationFile,
  parseConversationMarkdown,
} from '../../src/parsers/ai-vault-messages.js'

function vault(opts: {
  title?: string
  provider: string
  created?: string
  count?: number
  sections: { role: string; at?: string; body: string }[]
  metadata?: boolean
}): string {
  const head = [
    `# ${opts.title ?? 'A title'}`,
    '',
    `**Provider:** ${opts.provider}`,
    ...(opts.created === undefined ? ['**Created:** 2024-06-22T12:45:56.025Z'] : opts.created ? [`**Created:** ${opts.created}`] : []),
    '**Updated:** 2024-06-22T12:46:03.820Z',
    `**Messages:** ${opts.count ?? opts.sections.length}`,
    '',
    '---',
    '',
  ]
  const parts: string[] = []
  for (const s of opts.sections) {
    parts.push([`## ${s.role}`, ...(s.at ? [`*${s.at}*`] : []), '', s.body, '', '---', ''].join('\n'))
  }
  const tail =
    opts.metadata === false ? '' : ['## Metadata', '', '```json', '{', '  "messageCount": 2,', '  "characterCount": 10,', '  "mediaCount": 0', '}', '```'].join('\n')
  return head.join('\n') + '\n' + parts.join('\n') + tail
}

const path = (provider: string, id: string) => `/x/ai-vault-data/${provider}/conversations/${id}/conversation.md`

describe('parseConversationMarkdown', () => {
  test('chatgpt: two messages with timestamps, valid against the contract', () => {
    const content = vault({
      provider: 'chatgpt',
      sections: [
        { role: 'User', at: '2024-06-22T12:45:56.033Z', body: 'Question?' },
        { role: 'Assistant', at: '2024-06-22T12:46:02.830Z', body: 'Answer.' },
      ],
    })
    const r = parseConversationMarkdown({ content, filePath: path('chatgpt', '67d5e570-3b94-8008-8dd3-dc1cdf6033c9') })
    expect(r.problems).toEqual([])
    const doc = r.document!
    expect(DesktopConversationDocument.safeParse(doc).success).toBe(true)
    expect(doc.documentId).toBe('ai-vault:chatgpt:67d5e570-3b94-8008-8dd3-dc1cdf6033c9')
    expect(doc.source).toBe('chatgpt')
    expect(doc.title).toBe('A title')
    expect(doc.occurredAt).toBe('2024-06-22T12:45:56.025Z')
    expect(doc.messages).toEqual([
      { role: 'user', text: 'Question?', at: '2024-06-22T12:45:56.033Z' },
      { role: 'assistant', text: 'Answer.', at: '2024-06-22T12:46:02.830Z' },
    ])
    expect(doc.metadata.userMessageCount).toBe(1)
    expect(doc.metadata.assistantMessageCount).toBe(1)
    expect(doc.metadata.contentSha256).toMatch(/^[0-9a-f]{64}$/)
    expect(doc.metadata.exportCharacterCount).toBe(10)
  })

  test('claude maps to claude-ai; gemini to gemini; unknown provider to other', () => {
    const sections = [{ role: 'User', body: 'hi' }]
    const claude = parseConversationMarkdown({ content: vault({ provider: 'claude', sections }), filePath: path('claude', 'abc') })
    expect(claude.document!.source).toBe('claude-ai')
    expect(claude.document!.documentId).toBe('ai-vault:claude:abc')

    const gemini = parseConversationMarkdown({ content: vault({ provider: 'gemini', sections }), filePath: path('gemini', 'g1') })
    expect(gemini.document!.source).toBe('gemini')
    expect(gemini.document!.documentId).toBe('ai-vault:gemini:g1')

    const other = parseConversationMarkdown({ content: vault({ provider: 'perplexity', sections }), filePath: path('perplexity', 'p1') })
    expect(other.document!.source).toBe('other')
    expect(other.document!.documentId).toBe('ai-vault:unknown:p1')
  })

  test('provider falls back to the header when the path does not say', () => {
    const r = parseConversationMarkdown({
      content: vault({ provider: 'claude', sections: [{ role: 'User', body: 'hi' }] }),
      conversationId: 'c-1',
    })
    expect(r.document!.source).toBe('claude-ai')
  })

  test('no per-message timestamp: `at` is omitted', () => {
    const r = parseConversationMarkdown({ content: vault({ provider: 'chatgpt', sections: [{ role: 'User', body: 'hi' }] }), filePath: path('chatgpt', 'a') })
    expect(r.document!.messages[0]).toEqual({ role: 'user', text: 'hi' })
  })

  test('empty and attachment-only messages are skipped and counted, not emitted', () => {
    const content = vault({
      provider: 'chatgpt',
      sections: [
        { role: 'User', at: '2024-06-22T12:45:56.033Z', body: '' },
        { role: 'User', at: '2024-06-22T12:45:57.000Z', body: '**Attachments:**\n- [audio: file_1](https://example.invalid/a)' },
        { role: 'Assistant', at: '2024-06-22T12:45:58.000Z', body: 'Real answer.\n\n**Attachments:**\n- ![image](x.png)' },
      ],
    })
    const r = parseConversationMarkdown({ content, filePath: path('chatgpt', 'a') })
    expect(r.document!.messages).toEqual([{ role: 'assistant', text: 'Real answer.', at: '2024-06-22T12:45:58.000Z' }])
    expect(r.stats.skipped).toBe(2)
    expect(r.stats.skippedByReason).toEqual({ empty: 1, 'attachment-only': 1 })
    expect(r.stats.attachments).toBe(2)
    expect(r.problems).toEqual([])
  })

  test('a conversation with nothing but empty messages yields no document', () => {
    const content = vault({ provider: 'chatgpt', sections: [{ role: 'User', body: '**Attachments:**\n- [audio: a](b)' }] })
    const r = parseConversationMarkdown({ content, filePath: path('chatgpt', 'a') })
    expect(r.document).toBeNull()
    expect(r.problems).toContain('no-messages')
  })

  test('a zero-message export (metadata only) yields no document', () => {
    const r = parseConversationMarkdown({ content: vault({ provider: 'chatgpt', sections: [] }), filePath: path('chatgpt', 'a') })
    expect(r.document).toBeNull()
    expect(r.problems).toEqual(['no-messages'])
  })

  test('`---` and `## User` inside a body are text unless they follow a separator', () => {
    const body = 'Intro\n## Summary\nSee below\n## User\nnot a heading (no separator)\n\n---\n\nafter a rule\n\n## Bottom line\nDone.'
    const content = vault({ provider: 'chatgpt', sections: [{ role: 'User', body: 'q' }, { role: 'Assistant', body }] })
    const r = parseConversationMarkdown({ content, filePath: path('chatgpt', 'a') })
    expect(r.document!.messages.length).toBe(2)
    expect(r.document!.messages[1].text).toBe(body)
  })

  test('odd headers: CRLF, missing Created, no title, header count mismatch, no metadata block', () => {
    const content = vault({
      provider: 'chatgpt',
      created: '',
      count: 7,
      metadata: false,
      sections: [
        { role: 'Human', at: '2025-01-01T10:00:00Z', body: 'hi' },
        { role: 'Claude', body: 'hello' },
      ],
    })
      .replace('# A title\n', '')
      .replace(/\n/g, '\r\n')
    const r = parseConversationMarkdown({ content, filePath: path('claude', 'id with spaces%') })
    const doc = r.document!
    expect(DesktopConversationDocument.safeParse(doc).success).toBe(true)
    expect(doc.title).toBeNull()
    expect(doc.occurredAt).toBe('2025-01-01T10:00:00Z') // first message time when Created is absent
    expect(doc.messages.map((m) => m.role)).toEqual(['user', 'assistant'])
    expect(doc.messages[1].text).toBe('hello')
    expect(r.problems).toEqual(['header-count-mismatch:7!=2'])
  })

  test('no timestamp anywhere: no document', () => {
    const content = vault({ provider: 'chatgpt', created: '', sections: [{ role: 'User', body: 'hi' }] }).replace(/\*\*Updated:\*\*.*\n/, '')
    const r = parseConversationMarkdown({ content, filePath: path('chatgpt', 'a') })
    expect(r.document).toBeNull()
    expect(r.problems).toContain('no-timestamp')
  })

  test('over-long message text is truncated to the contract limit', () => {
    const content = vault({ provider: 'chatgpt', sections: [{ role: 'User', body: 'x'.repeat(500_010) }] })
    const r = parseConversationMarkdown({ content, filePath: path('chatgpt', 'a') })
    expect(r.document!.messages[0].text.length).toBe(500_000)
    expect(r.stats.truncated).toBe(1)
  })

  test('documentIdFor keeps ids inside the contract alphabet', () => {
    expect(documentIdFor('chatgpt', 'a b/c')).toBe('ai-vault:chatgpt:a_b_c')
    expect(documentIdFor('unknown', '')).toBe('ai-vault:unknown:unnamed')
  })
})

const REAL_ROOT = process.env.AI_VAULT_DATA || join(homedir(), 'ai-vault-data')

describe.skipIf(!existsSync(REAL_ROOT))('real ai-vault export', () => {
  test('every conversation.md parses; each yields a valid document or has no text messages at all', () => {
    const files = findConversationFiles(REAL_ROOT)
    expect(files.length).toBeGreaterThan(0)
    const unexpected: string[] = []
    for (const file of files) {
      const r = parseConversationFile(file)
      if (r.document) {
        if (!DesktopConversationDocument.safeParse(r.document).success) unexpected.push(`${r.documentId}:schema`)
        continue
      }
      // The only acceptable reason for no document: every section was empty / audio-only, or there were none.
      const onlyNoMessages = r.problems.length === 1 && r.problems[0] === 'no-messages'
      if (!onlyNoMessages || r.stats.skipped !== r.stats.sections) unexpected.push(`${r.documentId}:${r.problems.join(',')}`)
    }
    // Ids only: never message text.
    expect(unexpected).toEqual([])
  })
})
