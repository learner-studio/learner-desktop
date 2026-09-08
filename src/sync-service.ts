import { readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { config } from './config.js'
import { HindsightClient } from './hindsight-client.js'
import { SyncLedger } from './ledger.js'
import { conversationToMemoryItem, parseAiVaultConversation, sha256 } from './parsers/ai-vault-parser.js'
import type { MemoryItem, ParsedConversation } from './types.js'

export interface SyncOptions {
  limit?: number
  force?: boolean
  verbose?: boolean
  provider?: string
}

export interface SyncSummary {
  discovered: number
  alreadyUpToDate: number
  synced: number
  failed: number
  operations: string[]
  durationMs: number
}

export class SyncService {
  constructor(
    private readonly client: HindsightClient,
    private readonly ledger: SyncLedger,
  ) {}

  findConversationFiles(rootPath: string = config.paths.aiVaultData, providerFilter?: string): string[] {
    const files: string[] = []

    const recurse = (dir: string, depth = 0) => {
      if (depth > 6) return
      try {
        const entries = readdirSync(dir, { withFileTypes: true })
        for (const entry of entries) {
          const fullPath = join(dir, entry.name)
          if (entry.isDirectory()) {
            recurse(fullPath, depth + 1)
          } else if (entry.isFile() && entry.name === 'conversation.md') {
            if (!providerFilter || fullPath.includes(`/${providerFilter}/`)) {
              files.push(fullPath)
            }
          }
        }
      } catch {
        // Ignore unreadable dirs
      }
    }

    recurse(rootPath)
    return files
  }

  async syncSingleFile(filePath: string, force = false): Promise<{ status: 'synced' | 'skipped' | 'failed'; error?: string }> {
    try {
      const parsed = parseAiVaultConversation(filePath)
      if (!force && this.ledger.isUpToDate(filePath, parsed.contentHash)) {
        return { status: 'skipped' }
      }

      const memoryItem = conversationToMemoryItem(parsed)
      const res = await this.client.retainAsync([memoryItem])

      this.ledger.recordSuccess({
        file_path: filePath,
        content_hash: parsed.contentHash,
        document_id: parsed.documentId,
        provider: parsed.provider,
        conversation_id: parsed.conversationId,
        title: parsed.title,
        message_count: parsed.messageCount,
        last_operation_id: res.operation_id || null,
        last_synced_at: new Date().toISOString(),
      })

      return { status: 'synced' }
    } catch (err) {
      const errorMsg = (err as Error).message
      const parsed = parseAiVaultConversation(filePath)
      this.ledger.recordFailure(filePath, parsed.contentHash, parsed.documentId, errorMsg)
      return { status: 'failed', error: errorMsg }
    }
  }

  async runSync(options: SyncOptions = {}): Promise<SyncSummary> {
    const startTime = Date.now()
    const allFiles = this.findConversationFiles(config.paths.aiVaultData, options.provider)
    const filesToConsider = options.limit ? allFiles.slice(0, options.limit) : allFiles

    const summary: SyncSummary = {
      discovered: filesToConsider.length,
      alreadyUpToDate: 0,
      synced: 0,
      failed: 0,
      operations: [],
      durationMs: 0,
    }

    const pendingBatch: { parsed: ParsedConversation; item: MemoryItem }[] = []

    const flushBatch = async () => {
      if (pendingBatch.length === 0) return
      const batchItems = pendingBatch.map((b) => b.item)
      try {
        const res = await this.client.retainAsync(batchItems)
        if (res.operation_id) {
          summary.operations.push(res.operation_id)
        }

        const now = new Date().toISOString()
        for (const { parsed } of pendingBatch) {
          this.ledger.recordSuccess({
            file_path: parsed.sourcePath,
            content_hash: parsed.contentHash,
            document_id: parsed.documentId,
            provider: parsed.provider,
            conversation_id: parsed.conversationId,
            title: parsed.title,
            message_count: parsed.messageCount,
            last_operation_id: res.operation_id || null,
            last_synced_at: now,
          })
          summary.synced++
        }
      } catch (err) {
        const errorMsg = (err as Error).message
        for (const { parsed } of pendingBatch) {
          this.ledger.recordFailure(parsed.sourcePath, parsed.contentHash, parsed.documentId, errorMsg)
          summary.failed++
        }
      } finally {
        pendingBatch.length = 0
      }
    }

    for (let i = 0; i < filesToConsider.length; i++) {
      const file = filesToConsider[i]
      try {
        const parsed = parseAiVaultConversation(file)

        if (!options.force && this.ledger.isUpToDate(file, parsed.contentHash)) {
          summary.alreadyUpToDate++
          continue
        }

        const memoryItem = conversationToMemoryItem(parsed)
        pendingBatch.push({ parsed, item: memoryItem })

        if (pendingBatch.length >= config.sync.batchSize) {
          await flushBatch()
          await new Promise((r) => setTimeout(r, config.sync.batchDelayMs))
        }
      } catch (err) {
        summary.failed++
        if (options.verbose) {
          console.error(`Error parsing ${file}: ${(err as Error).message}`)
        }
      }
    }

    if (pendingBatch.length > 0) {
      await flushBatch()
    }

    summary.durationMs = Date.now() - startTime
    return summary
  }
}
