import Foundation
import SQLite3
import Testing
@testable import LearnerDesktop

// Ported from tests/ts/sync-rpc.test.ts: the archive sweep against a stand-in server.

private final class ArchiveFixture {
    let dir = TempDir("archive")
    let job = JobName("archive")
    let stub: StubTransport
    let archive: Archive
    let files: [String]
    let ledger: ArchiveLedger

    init(count: Int = 5, batchSize: Int = 50, key: String? = "test-key", handler: @escaping (StubTransport.Seen) -> HTTPReply) {
        stub = StubTransport(handler)
        let rpc = LearnerRPC(baseURL: "http://stand-in.invalid/learner-api/", transport: stub, key: { _ in key })
        var c = Archive.Config()
        c.jobName = job.name
        c.root = dir.file("vault")
        c.ledgerPath = dir.file("ledger.sqlite")
        c.batchSize = batchSize
        archive = Archive(rpc: rpc, config: c)
        let root = dir.file("vault")
        files = (0..<count).map { Vault.writeConversation(root, "conv-\($0)", "message \($0)") }
        ledger = try! archive.ledger()
    }

    func sweep() -> (Archive.Summary, String) {
        let (s, o) = archive.sweep(ledger: ledger)
        return (s, describe(o))
    }
}

private func ok(_ s: StubTransport.Seen) -> HTTPReply {
    StubTransport.json(200, ["data": ["accepted": s.documentIds.count, "updated": 0, "unchanged": 0]])
}

@Suite("Archive sweep", .timeLimit(.minutes(1))) struct ArchiveTests {
    @Test func postsTheDataEnvelopeWithTheDeviceKey() {
        let f = ArchiveFixture(count: 1, handler: ok)
        _ = f.sweep()
        let r = f.stub.seen[0]
        #expect(r.path == "/learner-api/rpc/archiveConversationDocuments")
        #expect(r.headers["x-api-key"] == "test-key")
        #expect(r.header("content-type") == "application/json")
        #expect((r.body?["data"] as? [String: Any])?["clientId"] as? String == "ben-mbp")
        #expect(r.documentIds == ["ai-vault:chatgpt:conv-0"])
    }

    @Test func sendsOnceThenNothingUntilAFileChanges() {
        let f = ArchiveFixture(handler: ok)
        let (s1, o1) = f.sweep()
        #expect(s1.synced == 5 && s1.parked == 0 && s1.requests == 1 && s1.stopped == nil)
        #expect(o1.hasPrefix("ok:"))
        #expect(f.ledger.stats() == ArchiveLedger.Stats(total: 5, synced: 5, failed: 0, skipped: 0))

        let (s2, o2) = f.sweep()
        #expect(s2.upToDate == 5 && s2.synced == 0 && s2.requests == 0)
        #expect(o2 == "idle")

        Vault.writeConversation(f.dir.file("vault"), "conv-2", "message 2, edited")
        let (s3, _) = f.sweep()
        #expect(s3.upToDate == 4 && s3.synced == 1 && s3.requests == 1)
        #expect(f.stub.seen.last?.documentIds == ["ai-vault:chatgpt:conv-2"])
    }

    @Test func batchesAreAtMostBatchSizeAndTheContractsFifty() {
        let small = ArchiveFixture(batchSize: 2, handler: ok)
        _ = small.sweep()
        #expect(small.stub.seen.map(\.documentIds.count) == [2, 2, 1])

        let big = ArchiveFixture(count: 60, handler: ok)
        _ = big.sweep()
        #expect(big.stub.seen.map(\.documentIds.count) == [50, 10])
    }

    @Test(arguments: [422, 400])
    func aRefusedDocumentIsIsolatedAndParkedTheRestArchived(status: Int) {
        let f = ArchiveFixture { s in s.documentIds.contains("ai-vault:chatgpt:conv-3") ? StubTransport.json(status, ["message": "bad"]) : ok(s) }
        let (s, o) = f.sweep()
        #expect(s.synced == 4 && s.parked == 1 && s.stopped == nil)
        #expect(o.hasPrefix("ok:"))
        #expect(f.ledger.stats() == ArchiveLedger.Stats(total: 5, synced: 4, failed: 1, skipped: 0))
        #expect(f.ledger.row(f.files[3])?.error == "HTTP \(status): bad")

        let before = f.stub.seen.count
        let (again, _) = f.sweep()
        #expect(again.upToDate == 5 && again.requests == 0)
        #expect(f.stub.seen.count == before)
    }

    @Test func authFailureBlocksMarksNothingSendsNothingMore() {
        let f = ArchiveFixture(batchSize: 2) { _ in StubTransport.status(401) }
        let (s, o) = f.sweep()
        #expect(s.synced == 0 && s.stopped == "device key refused" && s.remaining == 5 && s.requests == 1)
        #expect(o.hasPrefix("blocked: device key refused (HTTP 401)"))
        #expect(f.ledger.stats().total == 0)
    }

    @Test func tooLargeHalvesTheBatchUntilItFits() {
        let f = ArchiveFixture { s in s.documentIds.count > 2 ? StubTransport.status(413) : ok(s) }
        let (s, _) = f.sweep()
        #expect(s.synced == 5 && s.parked == 0 && s.stopped == nil)
        #expect(f.stub.seen.map(\.documentIds.count) == [5, 3, 2, 1, 2])
    }

    @Test func tooLargeOnASingleDocumentParksIt() {
        let f = ArchiveFixture(count: 1) { _ in StubTransport.status(413) }
        let (s, _) = f.sweep()
        #expect(s.synced == 0 && s.parked == 1)
        #expect(f.ledger.stats().failed == 1)
        #expect(f.archive.parkedCount == 1)
    }

    @Test func serverErrorsFailTheRunAndTheNextRunSendsTheRest() {
        var calls = 0
        let f = ArchiveFixture(batchSize: 2) { s in
            calls += 1
            return calls == 2 ? StubTransport.status(503) : ok(s)
        }
        let (s1, o1) = f.sweep()
        #expect(s1.synced == 2 && s1.remaining == 3 && s1.stopped == "server error 503")
        #expect(o1 == "failed: server error 503")
        #expect(f.ledger.stats().synced == 2)
        let (s2, _) = f.sweep()
        #expect(s2.upToDate == 2 && s2.synced == 3)
    }

    @Test func noAnswerIsAFailureThatSaysWhy() {
        let f = ArchiveFixture(count: 1) { _ in HTTPReply(status: 0, body: nil, error: "Could not connect (NSURLErrorDomain -1004)") }
        let (_, o) = f.sweep()
        #expect(o == "failed: server unreachable: Could not connect (NSURLErrorDomain -1004)")
    }

    @Test func noKeyBlocksAndSendsNothing() {
        let f = ArchiveFixture(key: nil, handler: ok)
        let (s, o) = f.sweep()
        #expect(s.stopped == "no device key" && s.remaining == 5)
        #expect(o.hasPrefix("blocked: no device key"))
        #expect(f.stub.seen.isEmpty)
        #expect(f.ledger.stats().total == 0)
    }

    @Test func aFileWithoutTextIsRecordedAsSkippedAndNeverSent() {
        let f = ArchiveFixture(count: 0, handler: ok)
        Vault.writeConversation(f.dir.file("vault"), "conv-empty", "**Attachments:**\n- [audio: a](b)")
        let (s, _) = f.sweep()
        #expect(s.empty == 1 && s.requests == 0)
        #expect(f.ledger.stats().skipped == 1)
        let (again, _) = f.sweep()
        #expect(again.upToDate == 1)
    }

    @Test func theStatusCountsFilesPerProvider() {
        let f = ArchiveFixture(count: 2, handler: ok)
        Vault.writeConversation(f.dir.file("vault"), "c-1", "hi", provider: "claude")
        _ = f.archive.runOnce()
        let st = f.archive.status
        #expect(st.filesByProvider == ["chatgpt": 2, "claude": 1])
        #expect(st.ledger.synced == 3)
        #expect(st.lastSweep != nil && st.lastSummary.contains("3 archived"))
    }

    /// The bun watcher's ledger: what it sent is not sent again, and its unused table goes.
    @Test func keepsTheWatchersLedgerAndDropsTheOldTable() throws {
        let dir = TempDir("ledger")
        let path = dir.file("sync-ledger.sqlite")
        let file = Vault.writeConversation(dir.file("vault"), "old", "sent by the watcher")
        let hash = ConversationParser.sha256(try Data(contentsOf: URL(fileURLWithPath: file)))
        var db: OpaquePointer?
        sqlite3_open(path, &db)
        let sql = """
            CREATE TABLE sync_ledger (file_path TEXT PRIMARY KEY, content_hash TEXT NOT NULL, document_id TEXT NOT NULL,
              provider TEXT NOT NULL, conversation_id TEXT NOT NULL, title TEXT NOT NULL, message_count INTEGER NOT NULL,
              last_operation_id TEXT, last_synced_at TEXT NOT NULL, sync_status TEXT NOT NULL, error_message TEXT);
            CREATE TABLE archive_ledger (file_path TEXT PRIMARY KEY, content_hash TEXT NOT NULL, document_id TEXT NOT NULL,
              message_count INTEGER NOT NULL, sync_status TEXT NOT NULL, error_message TEXT, updated_at TEXT NOT NULL);
            INSERT INTO archive_ledger VALUES ('\(file)', '\(hash)', 'ai-vault:chatgpt:old', 1, 'synced', NULL, '2026-10-22T19:23:50.466Z');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let stub = StubTransport(ok)
        let job = JobName("ledger")
        var c = Archive.Config()
        c.jobName = job.name
        c.root = dir.file("vault")
        c.ledgerPath = path
        let archive = Archive(rpc: LearnerRPC(baseURL: "http://x.invalid", transport: stub, key: { _ in "k" }), config: c)
        let ledger = try archive.ledger()
        #expect(ledger.tableNames() == ["archive_ledger"])
        let (s, _) = archive.sweep(ledger: ledger)
        #expect(s.upToDate == 1 && s.requests == 0)
        #expect(stub.seen.isEmpty)
    }

    @Test func aReadOnlyLedgerChangesNothing() throws {
        let dir = TempDir("ro")
        let path = dir.file("l.sqlite")
        _ = try ArchiveLedger(path: path).record("/a", hash: "h", documentId: "d", messageCount: 1, status: "synced")
        let ro = try ArchiveLedger(path: path, readOnly: true)
        #expect(ro.all()["/a"]?.status == "synced")
        #expect(!ro.record("/b", hash: "h", documentId: "d", messageCount: 1, status: "synced"))
        #expect(throws: (any Error).self) { try ArchiveLedger(path: dir.file("missing.sqlite"), readOnly: true) }
    }
}
