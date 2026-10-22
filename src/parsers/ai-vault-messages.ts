/**
 * ai-vault `conversation.md` -> DesktopConversationDocument (contract/desktop.ts).
 *
 * Export layout: <root>/<provider>/conversations/<conversation-id>/conversation.md
 *
 *   # <title>
 *
 *   **Provider:** chatgpt
 *   **Created:** 2024-06-22T12:45:56.025Z
 *   **Updated:** 2024-06-22T12:46:03.820Z
 *   **Messages:** 2
 *
 *   ---
 *
 *   ## User
 *   *2024-06-22T12:45:56.033Z*
 *
 *   <markdown body, may itself contain `---` and `## ...` headings>
 *
 *   **Attachments:**
 *   - [audio: ...](...)
 *
 *   ---
 *
 *   ## Assistant
 *   ...
 *
 *   ---
 *
 *   ## Metadata
 *
 *   ```json
 *   { "messageCount": 2, "characterCount": 970, "mediaCount": 0 }
 *   ```
 *
 * A role heading only starts a message when it follows a `---` separator line, so
 * `## Summary`-style headings inside an answer are body text. ChatGPT, Claude.ai and
 * Gemini exports share this layout; the provider comes from the path, else the header.
 */
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import type { z } from 'zod'
import { DesktopConversationDocument } from '../../contract/desktop.js'

export type ConversationDocument = z.infer<typeof DesktopConversationDocument>
export type VaultProvider = 'chatgpt' | 'claude' | 'gemini' | 'unknown'
export type SkipReason = 'empty' | 'attachment-only'

export const MAX_MESSAGE_CHARS = 500_000
export const MAX_MESSAGES = 5_000
const MAX_TITLE_CHARS = 500

const SOURCE_BY_PROVIDER: Record<VaultProvider, ConversationDocument['source']> = {
  chatgpt: 'chatgpt',
  claude: 'claude-ai',
  gemini: 'gemini',
  unknown: 'other',
}

const ROLE_BY_HEADING: Record<string, 'user' | 'assistant'> = {
  user: 'user',
  human: 'user',
  you: 'user',
  assistant: 'assistant',
  chatgpt: 'assistant',
  claude: 'assistant',
  gemini: 'assistant',
  model: 'assistant',
}

export interface ParseStats {
  /** Role sections found, including skipped ones. */
  sections: number
  user: number
  assistant: number
  skipped: number
  skippedByReason: Partial<Record<SkipReason, number>>
  truncated: number
  attachments: number
}

export interface ParseResult {
  /** Null when the file yields no valid document; `problems` says why. */
  document: ConversationDocument | null
  provider: VaultProvider
  conversationId: string
  documentId: string
  contentSha256: string
  stats: ParseStats
  /** Non-fatal oddities (e.g. header count mismatch) and fatal ones (document null). */
  problems: string[]
}

export interface ParseInput {
  content: string
  /** Path of the conversation.md; supplies provider and conversation id. */
  filePath?: string
  provider?: VaultProvider
  conversationId?: string
}

export function sha256(content: string): string {
  return createHash('sha256').update(content, 'utf8').digest('hex')
}

export function providerFromPath(filePath: string): VaultProvider | null {
  // .../<provider>/conversations/<id>/conversation.md
  const providerDir = basename(dirname(dirname(dirname(filePath)))).toLowerCase()
  return normalizeProvider(providerDir)
}

function normalizeProvider(raw: string): VaultProvider | null {
  const v = raw.trim().toLowerCase()
  if (v === 'chatgpt' || v === 'openai') return 'chatgpt'
  if (v === 'claude' || v === 'claude-ai' || v === 'claude.ai' || v === 'anthropic') return 'claude'
  if (v === 'gemini' || v === 'bard') return 'gemini'
  return null
}

/** `ai-vault:<provider>:<id>`, with characters outside the contract's id alphabet replaced. */
export function documentIdFor(provider: VaultProvider, conversationId: string): string {
  const safe = conversationId.replace(/[^A-Za-z0-9._:-]/g, '_') || 'unnamed'
  return `ai-vault:${provider}:${safe}`.slice(0, 300)
}

function headerField(lines: string[], name: string): string | undefined {
  const re = new RegExp(`^\\*\\*${name}:\\*\\*\\s*(.*)$`, 'i')
  for (const line of lines) {
    const m = line.match(re)
    if (m) return m[1].trim() || undefined
  }
  return undefined
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/

/** ISO-8601 with an offset, or undefined. Accepts any Date-parsable value and normalises it to UTC `Z`. */
export function toIsoInstant(raw: string | undefined): string | undefined {
  if (!raw) return undefined
  const v = raw.trim()
  if (ISO.test(v)) return v
  const t = Date.parse(v)
  return Number.isNaN(t) ? undefined : new Date(t).toISOString()
}

function isSeparator(line: string | undefined): boolean {
  return line !== undefined && /^\s*(---|\*\*\*|___)\s*$/.test(line)
}

/** A section heading counts only after a separator, optionally with one blank line between. */
function followsSeparator(lines: string[], i: number): boolean {
  if (isSeparator(lines[i - 1])) return true
  return lines[i - 1]?.trim() === '' && isSeparator(lines[i - 2])
}

interface Section {
  kind: 'user' | 'assistant' | 'metadata'
  start: number // heading line index
}

function findSections(lines: string[]): Section[] {
  const out: Section[] = []
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^##\s+(.+?)\s*$/)
    if (!m || !followsSeparator(lines, i)) continue
    const name = m[1].toLowerCase()
    if (name === 'metadata') out.push({ kind: 'metadata', start: i })
    else if (ROLE_BY_HEADING[name]) out.push({ kind: ROLE_BY_HEADING[name], start: i })
  }
  return out
}

/** Strips trailing blank lines and the `---` separator that closes a section. */
function trimSectionTail(body: string[]): string[] {
  let end = body.length
  while (end > 0 && body[end - 1].trim() === '') end--
  if (end > 0 && isSeparator(body[end - 1])) end--
  while (end > 0 && body[end - 1].trim() === '') end--
  return body.slice(0, end)
}

/** Removes `**Attachments:**` blocks (heading + `- ` list); returns the remaining lines and the item count. */
function stripAttachments(body: string[]): { lines: string[]; attachments: number } {
  const lines: string[] = []
  let attachments = 0
  for (let i = 0; i < body.length; i++) {
    if (/^\*\*Attachments:\*\*\s*$/.test(body[i])) {
      let j = i + 1
      while (j < body.length && /^\s*[-*]\s+/.test(body[j])) {
        attachments++
        j++
      }
      i = j - 1
      continue
    }
    lines.push(body[i])
  }
  return { lines, attachments }
}

function parseMetadataBlock(body: string[]): Record<string, unknown> {
  const text = body.join('\n')
  const m = text.match(/```(?:json)?\s*\n([\s\S]*?)\n```/)
  if (!m) return {}
  try {
    const parsed = JSON.parse(m[1])
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

export function parseConversationMarkdown(input: ParseInput): ParseResult {
  const raw = input.content
  const contentSha256 = sha256(raw)
  const content = raw.replace(/\r\n?/g, '\n')
  const lines = content.split('\n')
  const problems: string[] = []

  const sections = findSections(lines)
  const firstSection = sections.length ? sections[0].start : lines.length
  const head = lines.slice(0, firstSection)

  const conversationId =
    input.conversationId ?? (input.filePath ? basename(dirname(input.filePath)) : undefined) ?? 'unnamed'
  const headerProvider = headerField(head, 'Provider')
  const provider: VaultProvider =
    input.provider ??
    (input.filePath ? providerFromPath(input.filePath) : null) ??
    (headerProvider ? normalizeProvider(headerProvider) : null) ??
    'unknown'
  const documentId = documentIdFor(provider, conversationId)

  const titleLine = head.find((l) => /^#\s+\S/.test(l))
  const title = titleLine ? titleLine.replace(/^#\s+/, '').trim().slice(0, MAX_TITLE_CHARS) : null
  const createdAt = toIsoInstant(headerField(head, 'Created'))
  const updatedAt = toIsoInstant(headerField(head, 'Updated'))
  const headerCountRaw = headerField(head, 'Messages')
  const headerMessageCount = headerCountRaw && /^\d+$/.test(headerCountRaw) ? Number(headerCountRaw) : undefined

  const stats: ParseStats = {
    sections: 0,
    user: 0,
    assistant: 0,
    skipped: 0,
    skippedByReason: {},
    truncated: 0,
    attachments: 0,
  }
  const messages: ConversationDocument['messages'] = []
  let exportMeta: Record<string, unknown> = {}

  for (let s = 0; s < sections.length; s++) {
    const sec = sections[s]
    const end = s + 1 < sections.length ? sections[s + 1].start : lines.length
    let body = trimSectionTail(lines.slice(sec.start + 1, end))

    if (sec.kind === 'metadata') {
      exportMeta = parseMetadataBlock(body)
      continue
    }
    stats.sections++

    // Optional `*<timestamp>*` line right under the heading.
    let at: string | undefined
    const firstIdx = body.findIndex((l) => l.trim() !== '')
    if (firstIdx >= 0) {
      const tm = body[firstIdx].trim().match(/^[*_](\d{4}-\d{2}-\d{2}T[^*_\s]+)[*_]$/)
      if (tm) {
        at = toIsoInstant(tm[1])
        body = body.slice(firstIdx + 1)
      }
    }

    const { lines: textLines, attachments } = stripAttachments(body)
    stats.attachments += attachments
    let text = textLines.join('\n').trim()

    if (text === '') {
      const reason: SkipReason = attachments > 0 ? 'attachment-only' : 'empty'
      stats.skipped++
      stats.skippedByReason[reason] = (stats.skippedByReason[reason] ?? 0) + 1
      continue
    }
    if (text.length > MAX_MESSAGE_CHARS) {
      text = text.slice(0, MAX_MESSAGE_CHARS)
      stats.truncated++
    }

    stats[sec.kind]++
    messages.push(at ? { role: sec.kind, text, at } : { role: sec.kind, text })
  }

  if (headerMessageCount !== undefined && headerMessageCount !== stats.sections) {
    problems.push(`header-count-mismatch:${headerMessageCount}!=${stats.sections}`)
  }
  if (messages.length > MAX_MESSAGES) {
    problems.push(`too-many-messages:${messages.length}`)
    messages.length = MAX_MESSAGES
  }

  const occurredAt = createdAt ?? messages.find((m) => m.at)?.at ?? updatedAt
  if (!occurredAt) problems.push('no-timestamp')
  if (messages.length === 0) problems.push('no-messages')

  const metadata: Record<string, unknown> = {
    exporter: 'ai-vault',
    provider,
    conversationId,
    contentSha256,
    createdAt: createdAt ?? null,
    updatedAt: updatedAt ?? null,
    headerMessageCount: headerMessageCount ?? null,
    sectionCount: stats.sections,
    messageCount: messages.length,
    userMessageCount: stats.user,
    assistantMessageCount: stats.assistant,
    skippedMessageCount: stats.skipped,
    skippedByReason: stats.skippedByReason,
    truncatedMessageCount: stats.truncated,
    attachmentCount: stats.attachments,
  }
  for (const key of ['characterCount', 'mediaCount'] as const) {
    if (typeof exportMeta[key] === 'number') metadata[`export${key[0].toUpperCase()}${key.slice(1)}`] = exportMeta[key]
  }

  let document: ConversationDocument | null = null
  if (occurredAt && messages.length > 0) {
    const candidate = {
      documentId,
      source: SOURCE_BY_PROVIDER[provider],
      title,
      occurredAt,
      messages,
      metadata,
    }
    const checked = DesktopConversationDocument.safeParse(candidate)
    if (checked.success) document = checked.data
    else problems.push(...checked.error.issues.map((i) => `invalid:${i.path.join('.')}:${i.code}`))
  }

  return { document, provider, conversationId, documentId, contentSha256, stats, problems }
}

export function parseConversationFile(filePath: string): ParseResult {
  return parseConversationMarkdown({ content: readFileSync(filePath, 'utf8'), filePath })
}

/** Every `conversation.md` under the export root, sorted; optionally only one provider's directory. */
export function findConversationFiles(rootPath: string, providerFilter?: string): string[] {
  const files: string[] = []
  const recurse = (dir: string, depth: number) => {
    if (depth > 6) return
    let entries
    try {
      entries = readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const fullPath = join(dir, entry.name)
      if (entry.isDirectory()) recurse(fullPath, depth + 1)
      else if (entry.isFile() && entry.name === 'conversation.md') {
        if (!providerFilter || fullPath.includes(`/${providerFilter}/`)) files.push(fullPath)
      }
    }
  }
  recurse(rootPath, 0)
  return files.sort()
}
