/**
 * ChatGPT voice chats reach the ai-vault export as audio links only. ai-vault keeps a
 * message's plain-string parts and drops the `audio_transcription` parts that hold what
 * was said, so the watcher finds no text and never archives them. This fetches those
 * conversations from ChatGPT through ai-vault's own signed-in browser and writes each
 * transcript into its `conversation.md` section, under the `*<timestamp>*` line. The
 * watcher then sees a changed file and archives it like any typed chat.
 *
 * Sections are matched to API messages by timestamp: ai-vault writes each message's
 * `create_time` as an ISO instant, so the two agree to the millisecond.
 */
import { existsSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { findSections, stripAttachments, trimSectionTail } from './parsers/ai-vault-messages.js'

export interface ChatGptConversation {
  mapping?: Record<string, { message?: { create_time?: number | null; content?: { parts?: unknown[] } } | null }>
}

const STAMP = /^[*_](\d{4}-\d{2}-\d{2}T[^*_\s]+)[*_]$/

interface Gap {
  at: string
  stampLine: number
}

/** Message sections that have audio attached but no text: the ones ai-vault left blank. */
function findGaps(lines: string[]): Gap[] {
  const sections = findSections(lines)
  const gaps: Gap[] = []
  for (let s = 0; s < sections.length; s++) {
    const sec = sections[s]
    if (sec.kind === 'metadata') continue
    const end = s + 1 < sections.length ? sections[s + 1].start : lines.length
    const body = trimSectionTail(lines.slice(sec.start + 1, end))
    const first = body.findIndex((l) => l.trim() !== '')
    const stamp = first >= 0 ? body[first].trim().match(STAMP) : null
    if (!stamp) continue
    const rest = body.slice(first + 1)
    if (stripAttachments(rest).lines.join('\n').trim() !== '') continue
    if (!rest.some((l) => l.includes('[audio:'))) continue
    gaps.push({ at: stamp[1], stampLine: sec.start + 1 + first })
  }
  return gaps
}

export function hasVoiceGaps(md: string): boolean {
  return findGaps(md.split('\n')).length > 0
}

/** Transcript text by message timestamp (ISO, as ai-vault writes it). */
export function transcriptsByTime(conversation: ChatGptConversation): Map<string, string> {
  const out = new Map<string, string>()
  for (const node of Object.values(conversation.mapping ?? {})) {
    const m = node.message
    if (!m?.create_time) continue
    const text = (m.content?.parts ?? [])
      .map((p) =>
        p && typeof p === 'object' && (p as { content_type?: string }).content_type === 'audio_transcription'
          ? ((p as { text?: string }).text ?? '').trim()
          : '',
      )
      .filter(Boolean)
      .join('\n')
    if (text) out.set(new Date(m.create_time * 1000).toISOString(), text)
  }
  return out
}

/** Writes each blank voice section's transcript under its timestamp line. */
export function fillTranscripts(md: string, transcripts: Map<string, string>): { md: string; filled: number; missing: number } {
  const lines = md.split('\n')
  const gaps = findGaps(lines)
  let filled = 0
  // Back to front, so earlier line numbers stay valid.
  for (const gap of [...gaps].reverse()) {
    const text = transcripts.get(gap.at)
    if (!text) continue
    lines.splice(gap.stampLine + 1, 0, '', ...text.split('\n'))
    filled++
  }
  return { md: lines.join('\n'), filled, missing: gaps.length - filled }
}

/** The newest ai-vault install under nvm (AI_VAULT_DIST overrides). */
function aiVaultDist(): string | null {
  if (process.env.AI_VAULT_DIST) return process.env.AI_VAULT_DIST
  const root = join(homedir(), '.nvm/versions/node')
  const versions = existsSync(root) ? readdirSync(root).sort().reverse() : []
  for (const v of versions) {
    const dist = join(root, v, 'lib/node_modules/ai-vault/dist')
    if (existsSync(join(dist, 'utils/scraper.js'))) return dist
  }
  return null
}

export interface ChatGptSession {
  fetchConversation(id: string): Promise<{ status: number; body?: ChatGptConversation }>
  close(): Promise<void>
}

/** A browser page signed in with ai-vault's saved ChatGPT cookies. */
export async function openChatGpt(): Promise<ChatGptSession> {
  const dist = aiVaultDist()
  if (!dist) throw new Error('ai-vault is not installed under ~/.nvm')
  const { BrowserScraper } = await import(join(dist, 'utils/scraper.js'))
  const config = JSON.parse(readFileSync(join(homedir(), '.ai-vault/config.json'), 'utf8'))
  const cookies = config?.providers?.chatgpt?.cookies
  if (!cookies) throw new Error('ai-vault has no ChatGPT login')
  const scraper = new BrowserScraper()
  await scraper.init()
  const page = await scraper.createPage({ cookies, domain: '.chatgpt.com' })
  await page.goto('https://chatgpt.com', { waitUntil: 'domcontentloaded', timeout: 30000 })
  const token: string | null = await page.evaluate(async () => {
    const res = await fetch('/api/auth/session', { credentials: 'include' })
    return res.ok ? ((await res.json())?.accessToken ?? null) : null
  })
  if (!token) {
    await scraper.close()
    throw new Error('ChatGPT login expired')
  }
  return {
    fetchConversation: (id) =>
      page.evaluate(
        async ({ id, token }: { id: string; token: string }) => {
          const res = await fetch(`/backend-api/conversation/${encodeURIComponent(id)}`, {
            credentials: 'include',
            headers: { Authorization: `Bearer ${token}` },
          })
          return { status: res.status, body: res.ok ? await res.json() : undefined }
        },
        { id, token },
      ),
    close: () => scraper.close(),
  }
}

export interface VoiceSummary {
  candidates: number
  updated: number
  filled: number
  missing: number
  failed: number
  stopped: 'rate-limited' | 'login-expired' | null
}

/** Fills every ChatGPT conversation that has blank voice sections. Stops at the first 429. */
export async function fillVoiceTranscripts(
  files: string[],
  opts: { delayMs: number; limit?: number; log: (line: string) => void; open?: () => Promise<ChatGptSession> },
): Promise<VoiceSummary> {
  const candidates = files.filter((f) => hasVoiceGaps(readFileSync(f, 'utf8'))).slice(0, opts.limit)
  const summary: VoiceSummary = { candidates: candidates.length, updated: 0, filled: 0, missing: 0, failed: 0, stopped: null }
  if (candidates.length === 0) return summary
  const session = await (opts.open ?? openChatGpt)()
  try {
    for (const [i, file] of candidates.entries()) {
      if (i > 0) await new Promise((r) => setTimeout(r, opts.delayMs))
      const id = file.split('/').at(-2)!
      const res = await session.fetchConversation(id)
      if (res.status === 429) {
        summary.stopped = 'rate-limited'
        break
      }
      if (res.status === 401 || res.status === 403) {
        summary.stopped = 'login-expired'
        break
      }
      if (!res.body) {
        summary.failed++
        opts.log(`[Voice] ${id}: HTTP ${res.status}`)
        continue
      }
      const md = readFileSync(file, 'utf8')
      const result = fillTranscripts(md, transcriptsByTime(res.body))
      summary.missing += result.missing
      if (result.filled === 0) continue
      writeFileSync(`${file}.tmp`, result.md, { mode: statSync(file).mode & 0o777 })
      renameSync(`${file}.tmp`, file)
      summary.updated++
      summary.filled += result.filled
    }
  } finally {
    await session.close()
  }
  return summary
}
