import { config } from './config.js'
import type { MemoryItem, OperationStatus, RetainResponse } from './types.js'

export class HindsightClient {
  private baseUrl: string
  private bank: string

  constructor(
    baseUrl: string = config.hindsight.baseUrl,
    bank: string = config.hindsight.bank,
  ) {
    this.baseUrl = baseUrl.replace(/\/$/, '')
    this.bank = bank
  }

  async checkHealth(): Promise<{ healthy: boolean; details?: unknown; error?: string }> {
    try {
      const res = await fetch(`${this.baseUrl}/health`, {
        signal: AbortSignal.timeout(5_000),
      })
      if (!res.ok) {
        return { healthy: false, error: `HTTP ${res.status}: ${res.statusText}` }
      }
      const data = await res.json()
      return { healthy: true, details: data }
    } catch (err) {
      return { healthy: false, error: (err as Error).message }
    }
  }

  async retainAsync(items: MemoryItem[]): Promise<RetainResponse> {
    if (items.length === 0) {
      return { success: true, bank_id: this.bank, items_count: 0, async: true }
    }

    const url = `${this.baseUrl}/v1/default/banks/${encodeURIComponent(this.bank)}/memories`
    const body = {
      items,
      async: true,
    }

    let lastError: Error | null = null
    for (let attempt = 1; attempt <= config.hindsight.maxRetries; attempt++) {
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(config.hindsight.requestTimeoutMs),
        })

        if (!res.ok) {
          const text = await res.text()
          throw new Error(`Hindsight retain failed [${res.status}]: ${text}`)
        }

        const data = (await res.json()) as RetainResponse
        return data
      } catch (err) {
        lastError = err as Error
        if (attempt < config.hindsight.maxRetries) {
          await new Promise((r) => setTimeout(r, 500 * Math.pow(2, attempt - 1)))
        }
      }
    }

    throw lastError || new Error('Unknown error during retainAsync')
  }

  async getOperation(operationId: string): Promise<OperationStatus | null> {
    try {
      const url = `${this.baseUrl}/v1/default/banks/${encodeURIComponent(this.bank)}/operations/${encodeURIComponent(operationId)}`
      const res = await fetch(url, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(5_000),
      })
      if (!res.ok) return null
      return (await res.json()) as OperationStatus
    } catch {
      return null
    }
  }

  async getDocument(documentId: string): Promise<Record<string, unknown> | null> {
    try {
      const url = `${this.baseUrl}/v1/default/banks/${encodeURIComponent(this.bank)}/documents/${encodeURIComponent(documentId)}`
      const res = await fetch(url, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(5_000),
      })
      if (!res.ok) return null
      return (await res.json()) as Record<string, unknown>
    } catch {
      return null
    }
  }
}
