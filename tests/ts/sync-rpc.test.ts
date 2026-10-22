import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { ArchiveConversationDocumentsInput } from '../../contract/desktop.js'
import { classifyStatus, LearnerApiClient, resolveApiKey } from '../../src/learner-api.js'
import { SyncLedger } from '../../src/ledger.js'
import { SyncService } from '../../src/sync-service.js'

// --- A local stand-in for learner-server ------------------------------------------------

type Handler = (body: { data: { clientId: string; documents: { documentId: string }[] } }) => Response
interface Seen {
  path: string
  key: string | null
  ids: string[]
}
let handler: Handler
let seen: Seen[] = []
let server: ReturnType<typeof Bun.serve>
let baseUrl: string

beforeAll(() => {
  server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    async fetch(req) {
      const body = (await req.json()) as Parameters<Handler>[0]
      seen.push({ path: new URL(req.url).pathname, key: req.headers.get('x-api-key'), ids: body.data.documents.map((d) => d.documentId) })
      return handler(body)
    },
  })
  baseUrl = `http://127.0.0.1:${server.port}/learner-api`
})
afterAll(() => server.stop(true))

const ok = (n: number) => Response.json({ data: { accepted: n, updated: 0, unchanged: 0 } })

// --- Fixtures: a throwaway ai-vault export and ledger ----------------------------------

let dir: string
let files: string[]
let logs: string[]
let sleeps: number[]

function writeConversation(root: string, id: string, text: string): string {
  const d = join(root, 'chatgpt', 'conversations', id)
  mkdirSync(d, { recursive: true })
  const f = join(d, 'conversation.md')
  writeFileSync(
    f,
    `# t\n\n**Provider:** chatgpt\n**Created:** 2025-01-01T00:00:00Z\n**Messages:** 1\n\n---\n\n## User\n*2025-01-01T00:00:01Z*\n\n${text}\n\n---\n\n## Metadata\n`,
  )
  return f
}

function service(opts: { key?: string | null; batchSize?: number } = {}) {
  const ledger = new SyncLedger(join(dir, 'ledger.sqlite'))
  const api = new LearnerApiClient({ baseUrl, getKey: () => (opts.key === undefined ? 'test-key' : opts.key) })
  const svc = new SyncService(api, ledger, {
    batchSize: opts.batchSize,
    sleep: async (ms) => {
      sleeps.push(ms)
    },
    random: () => 0.5,
    retryLaterMs: 60_000,
    log: (l) => logs.push(l),
  })
  return { svc, ledger }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'learner-sync-'))
  files = Array.from({ length: 5 }, (_, i) => writeConversation(join(dir, 'vault'), `conv-${i}`, `message ${i}`))
  seen = []
  logs = []
  sleeps = []
})
afterEach(() => rmSync(dir, { recursive: true, force: true }))

describe('LearnerApiClient', () => {
  test('posts {"data": input} to /rpc/<name> with x-api-key; unwraps the data envelope', async () => {
    handler = () => ok(1)
    const api = new LearnerApiClient({ baseUrl: baseUrl + '/', getKey: () => 'k1' })
    const doc = { documentId: 'ai-vault:chatgpt:x', source: 'chatgpt' as const, occurredAt: '2025-01-01T00:00:00Z', messages: [{ role: 'user' as const, text: 'hi' }], metadata: {} }
    const res = await api.archiveConversationDocuments([doc])
    expect(res).toEqual({ kind: 'ok', status: 200, data: { accepted: 1, updated: 0, unchanged: 0 } })
    expect(seen).toEqual([{ path: '/learner-api/rpc/archiveConversationDocuments', key: 'k1', ids: ['ai-vault:chatgpt:x'] }])
  })

  test('the request body validates against ArchiveConversationDocumentsInput', async () => {
    let captured: unknown
    handler = (b) => {
      captured = b.data
      return ok(1)
    }
    const { svc } = service()
    await svc.syncFiles(files.slice(0, 1))
    const parsed = ArchiveConversationDocumentsInput.safeParse(captured)
    expect(parsed.success).toBe(true)
    expect((captured as { clientId: string }).clientId).toBe('ben-mbp')
  })

  test('status classification', () => {
    expect([200, 204, 400, 422, 401, 403, 413, 429, 500, 503, 404].map(classifyStatus)).toEqual([
      'ok', 'ok', 'rejected', 'rejected', 'auth', 'auth', 'too-large', 'transient', 'transient', 'transient', 'unexpected',
    ])
  })

  test('the env key wins over the Keychain', () => {
    expect(resolveApiKey({ LEARNER_API_KEY: ' abc ' })).toBe('abc')
  })
})

describe('SyncService against the mock server', () => {
  test('2xx: all documents archived in one batch, then nothing resent until a file changes', async () => {
    handler = (b) => ok(b.data.documents.length)
    const { svc, ledger } = service()
    const s1 = await svc.syncFiles(files)
    expect(s1).toMatchObject({ synced: 5, parked: 0, requests: 1, stopped: null })
    expect(ledger.getStats()).toMatchObject({ synced: 5, failed: 0 })

    const s2 = await svc.syncFiles(files)
    expect(s2).toMatchObject({ alreadyUpToDate: 5, synced: 0, requests: 0 })

    writeConversation(join(dir, 'vault'), 'conv-2', 'message 2, edited')
    const s3 = await svc.syncFiles(files)
    expect(s3).toMatchObject({ alreadyUpToDate: 4, synced: 1, requests: 1 })
    expect(seen.at(-1)!.ids).toEqual(['ai-vault:chatgpt:conv-2'])
  })

  test('batches are at most batchSize documents', async () => {
    handler = (b) => ok(b.data.documents.length)
    const { svc } = service({ batchSize: 2 })
    await svc.syncFiles(files)
    expect(seen.map((s) => s.ids.length)).toEqual([2, 2, 1])
  })

  test('422: the refused document is isolated and parked; the rest are archived; no retry', async () => {
    handler = (b) => (b.data.documents.some((d) => d.documentId.endsWith('conv-3')) ? new Response('{}', { status: 422 }) : ok(b.data.documents.length))
    const { svc, ledger } = service()
    const s = await svc.syncFiles(files)
    expect(s).toMatchObject({ synced: 4, parked: 1, stopped: null })
    expect(ledger.getStats()).toMatchObject({ synced: 4, failed: 1 })
    expect(logs.some((l) => l.includes('parked ai-vault:chatgpt:conv-3'))).toBe(true)
    expect(sleeps).toEqual([])

    const before = seen.length
    const again = await svc.syncFiles(files)
    expect(again).toMatchObject({ alreadyUpToDate: 5, requests: 0 })
    expect(seen.length).toBe(before)
  })

  test('401: stops with "key problem", marks nothing, sends nothing more', async () => {
    handler = () => new Response('', { status: 401 })
    const { svc, ledger } = service({ batchSize: 2 })
    const s = await svc.syncFiles(files)
    expect(s).toMatchObject({ synced: 0, stopped: 'key-problem', remaining: 5, requests: 1 })
    expect(ledger.getStats().total).toBe(0)
    expect(logs.some((l) => l.includes('key problem'))).toBe(true)
  })

  test('413: the batch is halved until it fits', async () => {
    handler = (b) => (b.data.documents.length > 2 ? new Response('', { status: 413 }) : ok(b.data.documents.length))
    const { svc } = service()
    const s = await svc.syncFiles(files)
    expect(s).toMatchObject({ synced: 5, parked: 0, stopped: null })
    expect(seen.map((x) => x.ids.length)).toEqual([5, 3, 2, 1, 2])
  })

  test('413 on a single document parks it', async () => {
    handler = () => new Response('', { status: 413 })
    const { svc, ledger } = service()
    const s = await svc.syncFiles(files.slice(0, 1))
    expect(s).toMatchObject({ synced: 0, parked: 1 })
    expect(ledger.getStats().failed).toBe(1)
  })

  test('429 then 503: exponential backoff from 2 s with jitter, then success', async () => {
    let n = 0
    handler = (b) => {
      n++
      if (n === 1) return new Response('', { status: 429 })
      if (n === 2) return new Response('', { status: 503 })
      return ok(b.data.documents.length)
    }
    const { svc } = service()
    const s = await svc.syncFiles(files)
    expect(s).toMatchObject({ synced: 5, requests: 3 })
    // random() = 0.5 is the middle of the ±20% jitter band.
    expect(sleeps).toEqual([2000, 4000])
  })

  test('backoff is capped at 5 minutes', () => {
    const { svc } = service()
    expect(svc.backoffMs(0)).toBe(2000)
    expect(svc.backoffMs(20)).toBe(300_000)
  })

  test('no key: logs once, sends nothing, does not throw', async () => {
    handler = () => ok(0)
    const { svc, ledger } = service({ key: null })
    const s1 = await svc.syncFiles(files)
    const s2 = await svc.syncFiles(files)
    expect(s1).toMatchObject({ stopped: 'no-key', remaining: 5 })
    expect(s2).toMatchObject({ stopped: 'no-key' })
    expect(seen).toEqual([])
    expect(ledger.getStats().total).toBe(0)
    expect(logs.filter((l) => l.includes('no device key')).length).toBe(1)
    svc.stop()
  })

  test('a file without text messages is recorded as skipped and never sent', async () => {
    handler = () => ok(1)
    const empty = writeConversation(join(dir, 'vault'), 'conv-empty', '**Attachments:**\n- [audio: a](b)')
    const { svc, ledger } = service()
    const s = await svc.syncFiles([empty])
    expect(s).toMatchObject({ emptySkipped: 1, requests: 0 })
    expect(ledger.getStats().skipped).toBe(1)
  })

  test('the watch queue retries pending files after a stop', async () => {
    handler = () => new Response('', { status: 403 })
    const { svc } = service()
    await svc.enqueue(files)
    expect(seen.length).toBe(1)
    svc.stop() // clears the retry timer
  })
})
