import Foundation
import Testing
@testable import LearnerDesktop

// The live machine, read-only: the real ai-vault export, the real archive ledger, the
// real ChatGPT session (one GET) and learner-server's public health check. Nothing here
// writes a file, a ledger row or a server record. Runs only with LEARNER_HEAVY=1
// (scripts/test.sh heavy); every suite says why it skips.

private let heavy = ProcessInfo.processInfo.environment["LEARNER_HEAVY"] == "1"
private let home = NSHomeDirectory()
private let vaultRoot = home + "/ai-vault-data"
private let ledgerPath = home + "/.ai-aggregator/sync-ledger.sqlite"
private let aiVaultConfig = home + "/.ai-vault/config.json"

private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

@Suite("Live ai-vault export (read-only)",
       .enabled(if: heavy, "heavy lane only (LEARNER_HEAVY=1)"),
       .enabled(if: exists(vaultRoot), "no ~/ai-vault-data on this machine"))
struct VaultExportLiveTests {
    @Test func everyConversationParsesIntoAValidDocumentOrHasNoTextAtAll() throws {
        let files = ConversationParser.findConversationFiles(vaultRoot)
        #expect(files.count > 0)
        var unexpected: [String] = []
        var documents = 0
        for file in files {
            let r = try ConversationParser.parseFile(file)
            if let doc = r.document {
                documents += 1
                if !ConversationContract.issues(doc).isEmpty { unexpected.append("\(r.documentId):schema") }
                continue
            }
            // The only acceptable reason for no document: every section empty / audio-only, or none.
            let onlyNoMessages = r.problems == ["no-messages"]
            if !onlyNoMessages || r.stats.skipped != r.stats.sections { unexpected.append("\(r.documentId):\(r.problems.joined(separator: ","))") }
        }
        // Ids only: never message text.
        #expect(unexpected == [])
        #expect(documents > 0)
    }

    @Test(.enabled(if: exists(ledgerPath), "no archive ledger yet"))
    func theLedgerIsConsistentWithTheFiles() throws {
        let ledger = try ArchiveLedger(path: ledgerPath, readOnly: true)
        let rows = ledger.all()
        #expect(!rows.isEmpty)
        var mismatched: [String] = []
        var current = 0, pending = 0, gone = 0
        for (path, row) in rows {
            #expect(["synced", "failed", "skipped"].contains(row.status), "\(row.documentId): \(row.status)")
            guard exists(path) else { gone += 1; continue }
            let r = try ConversationParser.parseFile(path)
            if row.documentId != r.documentId { mismatched.append("\(row.documentId) != \(r.documentId)") }
            guard row.contentHash == r.contentSha256 else { pending += 1; continue }
            current += 1
            // Same content: the ledger's verdict must still be the parser's.
            if row.status == "skipped" && r.document != nil { mismatched.append("\(row.documentId): skipped but has text") }
            if row.status == "synced" && r.document == nil { mismatched.append("\(row.documentId): synced but has no text") }
            if row.status == "synced" && row.messageCount != r.document?.messages.count { mismatched.append("\(row.documentId): message count") }
        }
        #expect(mismatched == [])
        #expect(current > 0)
        Swift.print("ledger: \(rows.count) rows, \(current) current, \(pending) changed since sent (the next sweep sends them), \(gone) files gone")
    }
}

@Suite("Live ChatGPT session (one read)",
       .enabled(if: heavy, "heavy lane only (LEARNER_HEAVY=1)"),
       .enabled(if: VoiceTranscripts().savedCookieHeader() != nil, "ai-vault has no ChatGPT login"))
struct ChatGPTLiveTests {
    @Test func theSavedCookiesOpenASessionAndOneConversationLoads() throws {
        let voice = VoiceTranscripts()
        let cookie = try #require(voice.savedCookieHeader())
        let session = voice.openSession(cookie: cookie)
        guard let token = session.token else {
            // An expired login is the user's to renew (menu: Sign In Again), not a test failure.
            Swift.print("skipped: ChatGPT session not available (\(session.stop?.rawValue ?? "?"): \(session.detail ?? ""))")
            #expect(session.stop == .loginExpired || session.stop == .rateLimited, "unexpected: \(session.detail ?? "")")
            return
        }
        let id = try #require(ConversationParser.findConversationFiles(vaultRoot, provider: "chatgpt").last
            .map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent })
        let r = voice.fetchConversation(id, cookie: cookie, token: token)
        if r.status == 429 { Swift.print("skipped: ChatGPT rate limit"); return }
        #expect(r.status == 200 || r.status == 404, "HTTP \(r.status) \(r.error ?? "")")
        if r.status == 200 { #expect(r.body?["mapping"] is [String: Any]) }
    }
}

@Suite("Live learner-server (health only)", .enabled(if: heavy, "heavy lane only (LEARNER_HEAVY=1)"))
struct LearnerServerLiveTests {
    @Test func theServerAnswersItsHealthCheck() {
        let r = LearnerRPC.shared.health(timeout: 15)
        #expect(r.status == 200, "\(LearnerRPC.shared.baseURL)/api/health: \(r.error ?? "HTTP \(r.status)")")
    }

    @Test(.enabled(if: VaultExport.installedCLI() != nil, "ai-vault is not installed under nvm"))
    func theAiVaultCLIIsInstalledAndRuns() {
        // --help only prints: the export's `backup` command must be there.
        let r = ChildProcess.run(VaultExport.installedCLI()!, ["--help"], timeout: 30, env: ChildProcess.toolEnvironment, stderr: true)
        #expect(r.status == 0, "ai-vault --help: \(r.stopped ?? r.output)")
        #expect(r.output.contains("backup"))
    }
}
