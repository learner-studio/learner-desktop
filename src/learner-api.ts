/**
 * learner-server RPC client: POST `${baseUrl}/rpc/<name>` with `{"data": input}` and the
 * device key in `x-api-key`. Inputs and outputs are checked against contract/desktop.ts.
 */
import { spawnSync } from 'node:child_process'
import type { z } from 'zod'
import { ArchiveConversationDocumentsInput, ArchiveConversationDocumentsOutput } from '../contract/desktop.js'
import { config } from './config.js'

export type ArchiveInput = z.infer<typeof ArchiveConversationDocumentsInput>
export type ArchiveOutput = z.infer<typeof ArchiveConversationDocumentsOutput>

/** Device key: LEARNER_API_KEY, else the macOS Keychain item `learner-server` / `ben-mbp`. Null when neither has one. */
export function resolveApiKey(env: Record<string, string | undefined> = process.env): string | null {
  const fromEnv = env.LEARNER_API_KEY?.trim()
  if (fromEnv) return fromEnv
  if (process.platform !== 'darwin') return null
  try {
    const r = spawnSync(
      '/usr/bin/security',
      ['find-generic-password', '-s', config.learnerApi.keychainService, '-a', config.learnerApi.keychainAccount, '-w'],
      { encoding: 'utf8', timeout: 10_000 },
    )
    const key = r.status === 0 ? r.stdout.trim() : ''
    return key || null
  } catch {
    return null
  }
}

/** Outcome of one RPC call; `kind` drives the caller's error handling. */
export type RpcResult<T> =
  | { kind: 'ok'; status: number; data: T | null }
  | { kind: 'rejected'; status: number } // 400 / 422: the payload itself is refused
  | { kind: 'auth'; status: number } // 401 / 403: key problem
  | { kind: 'too-large'; status: number } // 413
  | { kind: 'transient'; status: number | null; error?: string } // 429 / 5xx / network
  | { kind: 'unexpected'; status: number }

export function classifyStatus(status: number): RpcResult<never>['kind'] | 'ok' {
  if (status >= 200 && status < 300) return 'ok'
  if (status === 400 || status === 422) return 'rejected'
  if (status === 401 || status === 403) return 'auth'
  if (status === 413) return 'too-large'
  if (status === 408 || status === 429 || status >= 500) return 'transient'
  return 'unexpected'
}

export interface LearnerApiOptions {
  baseUrl?: string
  clientId?: string
  /** Called before every request so a key added to the Keychain later is picked up. */
  getKey?: () => string | null
  fetchImpl?: typeof fetch
  timeoutMs?: number
}

export class LearnerApiClient {
  readonly baseUrl: string
  readonly clientId: string
  private readonly getKey: () => string | null
  private readonly fetchImpl: typeof fetch
  private readonly timeoutMs: number

  constructor(opts: LearnerApiOptions = {}) {
    this.baseUrl = (opts.baseUrl ?? config.learnerApi.baseUrl).replace(/\/+$/, '')
    this.clientId = opts.clientId ?? config.learnerApi.clientId
    this.getKey = opts.getKey ?? (() => resolveApiKey())
    this.fetchImpl = opts.fetchImpl ?? fetch
    this.timeoutMs = opts.timeoutMs ?? config.learnerApi.requestTimeoutMs
  }

  hasKey(): boolean {
    return this.getKey() !== null
  }

  /** Raw call. Throws only when there is no key; HTTP and network failures come back as a result. */
  async call<T>(name: string, input: unknown, output?: z.ZodType<T>): Promise<RpcResult<T>> {
    const key = this.getKey()
    if (!key) throw new NoApiKeyError()
    let res: Response
    try {
      res = await this.fetchImpl(`${this.baseUrl}/rpc/${name}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json', 'x-api-key': key },
        body: JSON.stringify({ data: input }),
        signal: AbortSignal.timeout(this.timeoutMs),
      })
    } catch (err) {
      return { kind: 'transient', status: null, error: (err as Error).name }
    }
    const kind = classifyStatus(res.status)
    if (kind !== 'ok') {
      await res.body?.cancel().catch(() => {})
      return { kind, status: res.status } as RpcResult<T>
    }
    let data: T | null = null
    try {
      const body = (await res.json()) as unknown
      const payload = body && typeof body === 'object' && 'data' in body ? (body as { data: unknown }).data : body
      if (output) {
        const parsed = output.safeParse(payload)
        data = parsed.success ? parsed.data : null
      } else {
        data = payload as T
      }
    } catch {
      data = null
    }
    return { kind: 'ok', status: res.status, data }
  }

  async archiveConversationDocuments(documents: ArchiveInput['documents']): Promise<RpcResult<ArchiveOutput>> {
    const input = ArchiveConversationDocumentsInput.parse({ clientId: this.clientId, documents })
    return this.call('archiveConversationDocuments', input, ArchiveConversationDocumentsOutput)
  }
}

export class NoApiKeyError extends Error {
  constructor() {
    super('no learner-server device key (LEARNER_API_KEY or Keychain learner-server/ben-mbp)')
    this.name = 'NoApiKeyError'
  }
}
