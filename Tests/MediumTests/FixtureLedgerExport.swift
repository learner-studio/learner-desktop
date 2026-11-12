import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Writes Tests/Fixtures/sample/sync-ledger.sql: the archive ledger for the synthetic
// sample, made with the app's own parser (hash, document id, message count, synced or
// skipped), paths under @HOME@ (scripts/ci.sh fills in the runner's home). Run after
// scripts/fixtures/make-sample.py:  LEARNER_WRITE_SAMPLE_LEDGER=1 swift test --filter FixtureLedgerExport
@Suite("Synthetic sample: write its ledger", .tags(.medium, .chats),
       .enabled(if: ProcessInfo.processInfo.environment["LEARNER_WRITE_SAMPLE_LEDGER"] == "1", "set LEARNER_WRITE_SAMPLE_LEDGER=1 to rewrite it"))
struct FixtureLedgerExport {
    @Test func writeTheSampleLedger() throws {
        let root = toolsRepoRoot() + "/Tests/Fixtures/sample"
        var rows: [String] = []
        for file in ConversationParser.findConversationFiles(root + "/ai-vault-data").sorted() {
            let r = try ConversationParser.parseFile(file)
            let path = "@HOME@/ai-vault-data/" + file.components(separatedBy: "/ai-vault-data/")[1]
            let status = r.document == nil ? "skipped" : "synced"
            rows.append("INSERT INTO archive_ledger VALUES('\(path)','\(r.contentSha256)','\(r.documentId)',\(r.document?.messages.count ?? 0),'\(status)',NULL,'2026-11-12T00:00:00.000Z');")
        }
        let sql = """
            -- The archive ledger for the synthetic sample (Tests/MediumTests/FixtureLedgerExport.swift).
            CREATE TABLE archive_ledger (
              file_path TEXT PRIMARY KEY, content_hash TEXT NOT NULL, document_id TEXT NOT NULL,
              message_count INTEGER NOT NULL, sync_status TEXT NOT NULL, error_message TEXT, updated_at TEXT NOT NULL);
            CREATE INDEX idx_archive_ledger_doc_id ON archive_ledger (document_id);
            \(rows.joined(separator: "\n"))

            """
        try sql.write(toFile: root + "/sync-ledger.sql", atomically: true, encoding: .utf8)
        #expect(rows.count >= 20)
    }
}
