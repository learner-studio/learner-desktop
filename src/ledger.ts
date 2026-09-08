import { Database } from 'bun:sqlite'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { config } from './config.js'
import type { LedgerRecord } from './types.js'

export class SyncLedger {
  private db: Database

  constructor(dbPath: string = config.paths.ledgerDb) {
    mkdirSync(dirname(dbPath), { recursive: true })
    this.db = new Database(dbPath, { create: true })
    this.init()
  }

  private init() {
    this.db.exec('PRAGMA journal_mode = WAL;')
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sync_ledger (
        file_path TEXT PRIMARY KEY,
        content_hash TEXT NOT NULL,
        document_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        title TEXT NOT NULL,
        message_count INTEGER NOT NULL,
        last_operation_id TEXT,
        last_synced_at TEXT NOT NULL,
        sync_status TEXT NOT NULL,
        error_message TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_sync_ledger_doc_id ON sync_ledger (document_id);
      CREATE INDEX IF NOT EXISTS idx_sync_ledger_hash ON sync_ledger (content_hash);
    `)
  }

  getRecord(filePath: string): LedgerRecord | null {
    const query = this.db.query('SELECT * FROM sync_ledger WHERE file_path = ?')
    return (query.get(filePath) as LedgerRecord) ?? null
  }

  isUpToDate(filePath: string, contentHash: string): boolean {
    const record = this.getRecord(filePath)
    if (!record) return false
    return record.content_hash === contentHash && record.sync_status === 'synced'
  }

  recordSuccess(record: Omit<LedgerRecord, 'sync_status' | 'error_message'>): void {
    const stmt = this.db.prepare(`
      INSERT INTO sync_ledger (
        file_path, content_hash, document_id, provider, conversation_id,
        title, message_count, last_operation_id, last_synced_at, sync_status, error_message
      ) VALUES (
        $file_path, $content_hash, $document_id, $provider, $conversation_id,
        $title, $message_count, $last_operation_id, $last_synced_at, 'synced', NULL
      )
      ON CONFLICT(file_path) DO UPDATE SET
        content_hash = excluded.content_hash,
        document_id = excluded.document_id,
        title = excluded.title,
        message_count = excluded.message_count,
        last_operation_id = excluded.last_operation_id,
        last_synced_at = excluded.last_synced_at,
        sync_status = 'synced',
        error_message = NULL
    `)

    stmt.run({
      $file_path: record.file_path,
      $content_hash: record.content_hash,
      $document_id: record.document_id,
      $provider: record.provider,
      $conversation_id: record.conversation_id,
      $title: record.title,
      $message_count: record.message_count,
      $last_operation_id: record.last_operation_id,
      $last_synced_at: record.last_synced_at,
    })
    this.updateStatusFile()
  }

  recordFailure(filePath: string, contentHash: string, documentId: string, error: string): void {
    const stmt = this.db.prepare(`
      INSERT INTO sync_ledger (
        file_path, content_hash, document_id, provider, conversation_id,
        title, message_count, last_operation_id, last_synced_at, sync_status, error_message
      ) VALUES (
        $file_path, $content_hash, $document_id, 'unknown', '',
        '', 0, NULL, datetime('now'), 'failed', $error
      )
      ON CONFLICT(file_path) DO UPDATE SET
        content_hash = excluded.content_hash,
        last_synced_at = datetime('now'),
        sync_status = 'failed',
        error_message = excluded.error_message
    `)

    stmt.run({
      $file_path: filePath,
      $content_hash: contentHash,
      $document_id: documentId,
      $error: error,
    })
    this.updateStatusFile()
  }

  getStats(): { total: number; synced: number; failed: number } {
    const totalRow = this.db.query('SELECT COUNT(*) as count FROM sync_ledger').get() as { count: number }
    const syncedRow = this.db.query("SELECT COUNT(*) as count FROM sync_ledger WHERE sync_status = 'synced'").get() as { count: number }
    const failedRow = this.db.query("SELECT COUNT(*) as count FROM sync_ledger WHERE sync_status = 'failed'").get() as { count: number }

    return {
      total: totalRow.count,
      synced: syncedRow.count,
      failed: failedRow.count,
    }
  }

  updateStatusFile(extra: Record<string, unknown> = {}): void {
    try {
      const stats = this.getStats()
      const statusPath = join(dirname(config.paths.ledgerDb), 'status.json')
      const payload = {
        status: 'active',
        synced: stats.synced,
        total: stats.total,
        failed: stats.failed,
        lastUpdated: new Date().toISOString(),
        bank: config.hindsight.bank,
        ...extra,
      }
      writeFileSync(statusPath, JSON.stringify(payload, null, 2))
    } catch {
      // ignore errors writing status file
    }
  }

  close() {
    this.db.close()
  }
}
