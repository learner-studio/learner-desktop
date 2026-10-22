import { Database } from 'bun:sqlite'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { config } from './config.js'

/**
 * One row per conversation.md: what was last sent (or refused) for it. A file is resent
 * only when its content hash changes.
 *
 *   synced   archived by archiveConversationDocuments
 *   failed   refused by the server (422 / 400, or 413 on its own): parked, not retried
 *            until the file changes
 *   skipped  no messages with text (empty or audio-only export): nothing to send
 */
export type LedgerStatus = 'synced' | 'failed' | 'skipped'

export interface LedgerRecord {
  file_path: string
  content_hash: string
  document_id: string
  message_count: number
  sync_status: LedgerStatus
  error_message: string | null
  updated_at: string
}

export class SyncLedger {
  private db: Database

  constructor(private readonly dbPath: string = config.paths.ledgerDb) {
    mkdirSync(dirname(dbPath), { recursive: true })
    this.db = new Database(dbPath, { create: true })
    this.db.exec('PRAGMA journal_mode = WAL;')
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS archive_ledger (
        file_path TEXT PRIMARY KEY,
        content_hash TEXT NOT NULL,
        document_id TEXT NOT NULL,
        message_count INTEGER NOT NULL,
        sync_status TEXT NOT NULL,
        error_message TEXT,
        updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_archive_ledger_doc_id ON archive_ledger (document_id);
    `)
  }

  getRecord(filePath: string): LedgerRecord | null {
    return (this.db.query('SELECT * FROM archive_ledger WHERE file_path = ?').get(filePath) as LedgerRecord) ?? null
  }

  /** True when this exact content was already archived, parked or found empty. */
  isUpToDate(filePath: string, contentHash: string): boolean {
    const record = this.getRecord(filePath)
    return record !== null && record.content_hash === contentHash
  }

  record(entry: { filePath: string; contentHash: string; documentId: string; messageCount: number; status: LedgerStatus; error?: string }): void {
    this.db
      .prepare(
        `INSERT INTO archive_ledger (file_path, content_hash, document_id, message_count, sync_status, error_message, updated_at)
         VALUES ($file_path, $content_hash, $document_id, $message_count, $status, $error, $updated_at)
         ON CONFLICT(file_path) DO UPDATE SET
           content_hash = excluded.content_hash,
           document_id = excluded.document_id,
           message_count = excluded.message_count,
           sync_status = excluded.sync_status,
           error_message = excluded.error_message,
           updated_at = excluded.updated_at`,
      )
      .run({
        $file_path: entry.filePath,
        $content_hash: entry.contentHash,
        $document_id: entry.documentId,
        $message_count: entry.messageCount,
        $status: entry.status,
        $error: entry.error ?? null,
        $updated_at: new Date().toISOString(),
      })
  }

  getStats(): { total: number; synced: number; failed: number; skipped: number } {
    const rows = this.db.query('SELECT sync_status AS s, COUNT(*) AS n FROM archive_ledger GROUP BY sync_status').all() as {
      s: string
      n: number
    }[]
    const by = Object.fromEntries(rows.map((r) => [r.s, r.n])) as Record<string, number>
    return {
      total: rows.reduce((a, r) => a + r.n, 0),
      synced: by.synced ?? 0,
      failed: by.failed ?? 0,
      skipped: by.skipped ?? 0,
    }
  }

  /** ~/.ai-aggregator/status.json, read by the menu-bar app. */
  updateStatusFile(extra: Record<string, unknown> = {}): void {
    try {
      const payload = {
        status: 'active',
        ...this.getStats(),
        endpoint: config.learnerApi.baseUrl,
        lastUpdated: new Date().toISOString(),
        ...extra,
      }
      writeFileSync(join(dirname(this.dbPath), 'status.json'), JSON.stringify(payload, null, 2))
    } catch {
      // status file is best-effort
    }
  }

  close() {
    this.db.close()
  }
}
