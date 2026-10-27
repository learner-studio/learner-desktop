/**
 * Writes the parser parity fixtures: each <name>.md (fictional text) and <name>.expected.json,
 * the TypeScript parser's output for it. The Swift port (ConversationParser) must produce
 * the same document, byte for byte (Tests/LightTests/ParityTests.swift).
 *
 * The TypeScript parser was deleted with the bun watcher. To regenerate, check out
 * src/parsers/ai-vault-messages.ts and contract/desktop.ts from commit b591b40 next to
 * this script's imports (with zod installed) and run:  bun tests/Fixtures/parity/generate.ts
 */
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { parseConversationMarkdown } from '../../../src/parsers/ai-vault-messages.js'

const out = process.env.PARITY_OUT ?? dirname(new URL(import.meta.url).pathname)

const head = (o: { title?: string; provider?: string; created?: string; count?: string; nl?: string } = {}) =>
  [
    ...(o.title === undefined ? ['# A fictional chat'] : o.title === '' ? [] : [`# ${o.title}`]),
    '',
    `**Provider:** ${o.provider ?? 'chatgpt'}`,
    ...(o.created === '' ? [] : [`**Created:** ${o.created ?? '2024-06-22T12:45:56.025Z'}`]),
    '**Updated:** 2024-06-22T12:46:03.820Z',
    `**Messages:** ${o.count ?? '2'}`,
    '',
    '---',
    '',
  ].join('\n')

const sec = (role: string, body: string, at?: string) => [`## ${role}`, ...(at ? [`*${at}*`] : []), '', body, '', '---', ''].join('\n')
const meta = '## Metadata\n\n```json\n{\n  "messageCount": 2,\n  "characterCount": 1234,\n  "mediaCount": true\n}\n```\n'

/** Keeps the expected files small: long texts by hash, long conversations by their ends. */
function digest(doc: any): any {
  if (!doc) return doc
  const msg = (m: any) =>
    m.text.length > 10_000 ? { ...m, text: undefined, textLength: m.text.length, textSha256: createHash('sha256').update(m.text, 'utf8').digest('hex') } : m
  const messages = doc.messages.map(msg)
  return {
    ...doc,
    messages: messages.length > 50 ? { count: messages.length, head: messages.slice(0, 3), tail: messages.slice(-3) } : messages,
  }
}

/** `generated`: too big to commit; ParityTests.swift builds the same text itself. */
const fixtures: { name: string; provider: string; id: string; content: string | Buffer; generated?: boolean }[] = [
  {
    name: 'crlf-trailing-spaces',
    provider: 'chatgpt',
    id: 'conv-crlf',
    content: (head() + sec('User', 'Line one   \n\tindented line\t \nlast  ', '2024-06-22T12:45:56.033Z') +
      sec('Assistant', '  leading spaces kept inside?  \n\n\nAfter blank lines.   ', '2024-06-22T12:46:02.830Z') + meta).replace(/\n/g, '\r\n'),
  },
  {
    name: 'cr-only',
    provider: 'claude',
    id: 'conv-cr',
    content: (head({ provider: 'claude' }) + sec('Human', 'Old Mac endings', '2025-01-01T10:00:00Z') + sec('Claude', 'Reply')).replace(/\n/g, '\r'),
  },
  {
    name: 'unicode-whitespace',
    provider: 'chatgpt',
    id: 'conv-ws',
    content:
      head({ count: '4' }) +
      sec('User', '  Non-breaking spaces around  ', '2024-06-22T12:45:57.000Z') +
      sec('Assistant', 'Ends with a byte-order mark﻿', '2024-06-22T12:45:58.000Z') +
      sec('User', '\u0085Next-line characters\u0085', '2024-06-22T12:45:59.000Z') +
      sec('Assistant', 'Line separator and paragraph and　ideographic​zero-width', '2024-06-22T12:46:00.000Z'),
  },
  {
    name: 'combining-and-emoji',
    provider: 'chatgpt',
    id: 'conv 😀 cafe\u0301 ok',
    content:
      head({ title: 'Café vs Café 👨‍👩‍👧 🇩🇪 👍🏽' }) +
      sec('User', 'Decomposed: Café. Composed: Café. Family: 👨‍👩‍👧. Flag: 🇩🇪. Tone: 👍🏽. Ångström Å', '2024-06-22T12:45:57.000Z') +
      sec('Assistant', 'é́ double accent, Hangul 한국어 vs 한국어 (jamo), ﬁ ligature', '2024-06-22T12:45:58.000Z'),
  },
  {
    name: 'markdown-inside-bodies',
    provider: 'chatgpt',
    id: 'conv-md',
    content:
      head({ count: '3' }) +
      sec('User', 'q') +
      sec('Assistant', 'Intro\n## Summary\nSee below\n## User\nnot a heading (no separator)\n\n---\n\nafter a rule\n\n## Bottom line\nDone.\n***\n___\n\n## Notes\nend') +
      '##   ChatGPT   \n\nheading with extra spaces\n\n---\n\n\n## User\ntwo blank lines: still the previous section\n\n---\n\n' +
      meta,
  },
  {
    name: 'attachments',
    provider: 'chatgpt',
    id: 'conv-att',
    content:
      head({ count: '5' }) +
      sec('User', '', '2024-06-22T12:45:56.033Z') +
      sec('User', '**Attachments:**\n- [audio: file_1](https://example.invalid/a)\n* [image: x](https://example.invalid/b)', '2024-06-22T12:45:57.000Z') +
      sec('Assistant', 'Real answer.\n\n**Attachments:**\n- ![image](x.png)\nText after the list stays.', '2024-06-22T12:45:58.000Z') +
      sec('User', '**Attachments:**   \nNot a list item, kept.', '2024-06-22T12:45:59.000Z') +
      sec('Assistant', 'Inline **Attachments:** mention is text.', '_2024-06-22T12:46:00+02:00_'),
  },
  {
    name: 'long-message',
    provider: 'chatgpt',
    id: 'conv-long',
    generated: true,
    content: head({ count: '1' }) + sec('User', '😀 start ' + 'abcé'.repeat(125_010) + ' end', '2024-06-22T12:45:56.033Z'),
  },
  {
    name: 'too-many-messages',
    provider: 'gemini',
    id: 'conv-many',
    content: head({ provider: 'gemini', count: '5003' }) + Array.from({ length: 5003 }, (_, i) => sec(i % 2 ? 'Model' : 'You', `turn ${i}`)).join(''),
  },
  {
    name: 'odd-headers',
    provider: 'claude',
    id: 'conv-hdr',
    content:
      head({ title: '', provider: 'chatgpt', created: '2024-06-22', count: '٣' }) +
      sec('Human', 'Created is date-only; Messages has a non-ASCII digit') +
      sec('Assistant', 'ok', '٢٠٢٤-06-22T12:45:58.000Z'),
  },
  {
    name: 'bad-timestamp',
    provider: 'chatgpt',
    id: 'conv-badts',
    content: head({ count: '1' }) + sec('User', 'stamp is not a real date', '2024-13-45T99:99:99Z'),
  },
  {
    name: 'invalid-utf8',
    provider: 'chatgpt',
    id: 'conv-bytes',
    content: Buffer.concat([Buffer.from(head({ count: '1' }) + '## User\n\nbad byte: '), Buffer.from([0xff, 0xfe, 0xc3]), Buffer.from(' end\n\n---\n')]),
  },
  {
    name: 'unknown-provider',
    provider: 'perplexity',
    id: '',
    content: head({ provider: 'perplexity', count: '1' }) + sec('user', 'lower-case heading'),
  },
]

for (const f of fixtures) {
  const md = join(f.generated ? mkdtempSync(join(tmpdir(), 'parity-')) : out, `${f.name}.md`)
  writeFileSync(md, f.content)
  const filePath = `/x/ai-vault-data/${f.provider}/conversations/${f.id}/conversation.md`
  // As the watcher read it: the file decoded as UTF-8.
  const content = readFileSync(md, 'utf8')
  const r = parseConversationMarkdown({ content, filePath })
  const expected = {
    filePath,
    documentId: r.documentId,
    conversationId: r.conversationId,
    provider: r.provider,
    contentSha256: r.contentSha256,
    stats: r.stats,
    problems: r.problems,
    document: digest(r.document),
  }
  writeFileSync(join(out, `${f.name}.expected.json`), JSON.stringify(expected, null, 1) + '\n')
  console.log(f.name, r.document ? `${r.document.messages.length} messages` : `no document (${r.problems.join(',')})`)
}
