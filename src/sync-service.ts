/**
 * ai-vault conversation.md files -> archiveConversationDocuments, ≤50 documents per call.
 *
 * Error handling per response:
 *   2xx        mark synced
 *   422 / 400  bisect the batch down to the refused document; park it (ledger `failed`,
 *              id logged, no retry until the file changes)
 *   413        halve the batch; a lone document that is still too large is parked
 *   401 / 403  stop: "key problem"; the pending work is retried later
 *   429 / 5xx  exponential backoff 2 s -> 5 min with jitter, then retry the same batch
 *   no key     log once, retry later; never throws
 *
 * Logs carry document ids and counts only, never titles or message text.
 */
import { config } from './config.js'
import { type LearnerApiClient, NoApiKeyError } from './learner-api.js'
import type { SyncLedger } from './ledger.js'
import { type ConversationDocument, findConversationFiles, parseConversationFile } from './parsers/ai-vault-messages.js'

export interface PendingDoc {
  filePath: string
  contentHash: string
  document: ConversationDocument
}

export type StopReason = 'no-key' | 'key-problem' | 'unexpected-status'

export interface SyncSummary {
  discovered: number
  alreadyUpToDate: number
  emptySkipped: number
  parseFailed: number
  synced: number
  parked: number
  requests: number
  /** Set when the run stopped early; `remaining` documents were not sent. */
  stopped: StopReason | null
  remaining: number
  durationMs: number
}

export interface SyncServiceOptions {
  batchSize?: number
  backoffInitialMs?: number
  backoffMaxMs?: number
  retryLaterMs?: number
  sleep?: (ms: number) => Promise<void>
  random?: () => number
  log?: (line: string) => void
}

export class SyncService {
  private readonly batchSize: number
  private readonly backoffInitialMs: number
  private readonly backoffMaxMs: number
  private readonly retryLaterMs: number
  private readonly sleep: (ms: number) => Promise<void>
  private readonly random: () => number
  private readonly log: (line: string) => void

  private noKeyLogged = false
  private queue = new Set<string>()
  private draining: Promise<void> | null = null
  private retryTimer: ReturnType<typeof setTimeout> | null = null
  /** Set while sending keeps failing; the menu-bar app turns red when it lasts. */
  private problemSince: string | null = null

  constructor(
    private readonly api: LearnerApiClient,
    private readonly ledger: SyncLedger,
    opts: SyncServiceOptions = {},
  ) {
    this.batchSize = Math.max(1, Math.min(50, opts.batchSize ?? config.sync.batchSize))
    this.backoffInitialMs = opts.backoffInitialMs ?? config.sync.backoffInitialMs
    this.backoffMaxMs = opts.backoffMaxMs ?? config.sync.backoffMaxMs
    this.retryLaterMs = opts.retryLaterMs ?? config.sync.retryLaterMs
    this.sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)))
    this.random = opts.random ?? Math.random
    this.log = opts.log ?? ((line) => console.log(line))
  }

  findConversationFiles(rootPath: string = config.paths.aiVaultData, providerFilter?: string): string[] {
    return findConversationFiles(rootPath, providerFilter)
  }

  /** Delay before retry number `attempt` (0-based): 2 s, 4 s, 8 s ... capped at 5 min, with ±20% jitter (never above the cap). */
  backoffMs(attempt: number): number {
    const base = Math.min(this.backoffMaxMs, this.backoffInitialMs * 2 ** attempt)
    return Math.round(Math.min(this.backoffMaxMs, base * (0.8 + 0.4 * this.random())))
  }

  /** Parse files; return the documents whose content changed since the last send. */
  collect(files: string[], force = false): { pending: PendingDoc[]; upToDate: number; empty: number; parseFailed: number } {
    const pending: PendingDoc[] = []
    let upToDate = 0
    let empty = 0
    let parseFailed = 0
    for (const filePath of files) {
      try {
        const r = parseConversationFile(filePath)
        if (!force && this.ledger.isUpToDate(filePath, r.contentSha256)) {
          upToDate++
          continue
        }
        if (!r.document) {
          empty++
          this.ledger.record({
            filePath,
            contentHash: r.contentSha256,
            documentId: r.documentId,
            messageCount: 0,
            status: 'skipped',
            error: r.problems.join(' ').slice(0, 500),
          })
          continue
        }
        pending.push({ filePath, contentHash: r.contentSha256, document: r.document })
      } catch (err) {
        parseFailed++
        this.log(`[Sync] could not read ${filePath}: ${(err as Error).name}`)
      }
    }
    return { pending, upToDate, empty, parseFailed }
  }

  /** Send documents in batches. Returns the counts and, when stopped early, what is left. */
  async send(docs: PendingDoc[]): Promise<{ synced: number; parked: number; requests: number; stopped: StopReason | null; remaining: PendingDoc[] }> {
    const work: PendingDoc[][] = []
    for (let i = 0; i < docs.length; i += this.batchSize) work.push(docs.slice(i, i + this.batchSize))
    let synced = 0
    let parked = 0
    let requests = 0
    let attempt = 0

    while (work.length > 0) {
      const batch = work[0]
      let res
      try {
        requests++
        res = await this.api.archiveConversationDocuments(batch.map((d) => d.document))
      } catch (err) {
        if (err instanceof NoApiKeyError) {
          this.noteProblem('no device key')
          if (!this.noKeyLogged) {
            this.log('[Sync] no device key (LEARNER_API_KEY or Keychain learner-server/ben-mbp); will retry later')
            this.noKeyLogged = true
          }
          return { synced, parked, requests, stopped: 'no-key', remaining: work.flat() }
        }
        throw err
      }
      this.noKeyLogged = false

      switch (res.kind) {
        case 'ok': {
          work.shift()
          attempt = 0
          this.clearProblem()
          for (const d of batch) {
            this.ledger.record({
              filePath: d.filePath,
              contentHash: d.contentHash,
              documentId: d.document.documentId,
              messageCount: d.document.messages.length,
              status: 'synced',
            })
          }
          synced += batch.length
          const out = res.data ? ` (accepted ${res.data.accepted}, updated ${res.data.updated}, unchanged ${res.data.unchanged})` : ''
          this.log(`[Sync] archived ${batch.length} document(s)${out}`)
          break
        }
        case 'rejected':
        case 'too-large': {
          work.shift()
          if (batch.length > 1) {
            const mid = Math.ceil(batch.length / 2)
            work.unshift(batch.slice(0, mid), batch.slice(mid))
            if (res.kind === 'too-large') this.log(`[Sync] HTTP 413 for ${batch.length} documents; halving the batch`)
            break
          }
          const d = batch[0]
          this.ledger.record({
            filePath: d.filePath,
            contentHash: d.contentHash,
            documentId: d.document.documentId,
            messageCount: d.document.messages.length,
            status: 'failed',
            error: `HTTP ${res.status}`,
          })
          parked++
          this.log(`[Sync] HTTP ${res.status}: parked ${d.document.documentId} (not retried until the file changes)`)
          break
        }
        case 'auth':
          this.noteProblem(`device key refused (HTTP ${res.status})`)
          this.log(`[Sync] key problem: HTTP ${res.status} from ${this.api.baseUrl}; stopping, will retry later`)
          return { synced, parked, requests, stopped: 'key-problem', remaining: work.flat() }
        case 'transient': {
          const wait = this.backoffMs(attempt++)
          this.noteProblem(res.status === null ? `network error (${res.error ?? 'unknown'})` : `HTTP ${res.status}`)
          this.log(`[Sync] ${res.status === null ? `network error (${res.error ?? 'unknown'})` : `HTTP ${res.status}`}; retrying in ${Math.round(wait / 1000)}s`)
          await this.sleep(wait)
          break
        }
        case 'unexpected':
          this.noteProblem(`unexpected HTTP ${res.status}`)
          this.log(`[Sync] unexpected HTTP ${res.status} from ${this.api.baseUrl}; stopping, will retry later`)
          return { synced, parked, requests, stopped: 'unexpected-status', remaining: work.flat() }
      }
    }
    return { synced, parked, requests, stopped: null, remaining: [] }
  }

  private noteProblem(problem: string): void {
    this.problemSince ??= new Date().toISOString()
    this.ledger.updateStatusFile({ problem, problemSince: this.problemSince })
  }

  private clearProblem(): void {
    if (this.problemSince === null) return
    this.problemSince = null
    this.ledger.updateStatusFile({ problem: null, problemSince: null })
  }

  /** One sweep over the given files (default: the whole export). */
  async syncFiles(files: string[], options: { force?: boolean } = {}): Promise<SyncSummary> {
    const start = Date.now()
    const c = this.collect(files, options.force)
    const sent = await this.send(c.pending)
    this.ledger.updateStatusFile({
      lastRunAt: new Date().toISOString(),
      stopped: sent.stopped,
      pending: sent.remaining.length,
      problem: sent.stopped ? `stopped: ${sent.stopped}` : null,
      problemSince: sent.stopped ? this.problemSince : null,
    })
    if (!sent.stopped) this.problemSince = null
    return {
      discovered: files.length,
      alreadyUpToDate: c.upToDate,
      emptySkipped: c.empty,
      parseFailed: c.parseFailed,
      synced: sent.synced,
      parked: sent.parked,
      requests: sent.requests,
      stopped: sent.stopped,
      remaining: sent.remaining.length,
      durationMs: Date.now() - start,
    }
  }

  async runSync(options: { limit?: number; force?: boolean; provider?: string } = {}): Promise<SyncSummary> {
    const all = this.findConversationFiles(config.paths.aiVaultData, options.provider)
    return this.syncFiles(options.limit ? all.slice(0, options.limit) : all, options)
  }

  // --- Watch mode: a single-flight queue of changed files ---------------------------

  /** Queue files for sending; coalesces with any sweep already running. */
  enqueue(files: string[]): Promise<void> {
    for (const f of files) this.queue.add(f)
    if (!this.draining) {
      this.draining = this.drain().finally(() => {
        this.draining = null
      })
    }
    return this.draining
  }

  private async drain(): Promise<void> {
    while (this.queue.size > 0) {
      const files = [...this.queue]
      this.queue.clear()
      let summary: SyncSummary
      try {
        summary = await this.syncFiles(files)
      } catch (err) {
        this.log(`[Sync] sweep failed: ${(err as Error).message}`)
        this.scheduleRetry(files)
        return
      }
      if (summary.stopped) {
        // Everything not yet settled in this sweep goes back in the queue for later.
        this.scheduleRetry(files)
        return
      }
    }
  }

  private scheduleRetry(files: string[]): void {
    for (const f of files) this.queue.add(f)
    if (this.retryTimer) return
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      const again = [...this.queue]
      this.queue.clear()
      void this.enqueue(again)
    }, this.retryLaterMs)
  }

  stop(): void {
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.retryTimer = null
  }
}
