import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The synthetic chat-export sample (Tests/Fixtures/sample, made by
// scripts/fixtures/make-sample.py from the real export's SHAPES only). The runner installs
// it as ~/ai-vault-data for the heavy lane; these checks keep it honest and synthetic.
@Suite("Synthetic export sample", .tags(.light, .chats))
struct FixtureSampleTests {
    static let root = toolsRepoRoot() + "/Tests/Fixtures/sample"
    static var files: [String] { ConversationParser.findConversationFiles(root + "/ai-vault-data") }

    /// Every word comes from the generator's made-up vocabulary: no real word can slip in
    /// on a refresh. File ids are hex, so letter runs of a-f only are ids, not words.
    @Test func everyWordIsFromTheSyntheticVocabulary() throws {
        let vocabulary = Set(try String(contentsOfFile: Self.root + "/vocabulary.txt", encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.lowercased() })
        #expect(vocabulary.count > 100)
        var strangers: [String: String] = [:]
        for file in Self.files {
            let text = try String(contentsOfFile: file, encoding: .utf8)
            for word in text.split(whereSeparator: { !$0.isLetter }).map(String.init) where word.count > 1 {
                if word.allSatisfy({ "abcdef".contains($0) }) { continue }
                if !vocabulary.contains(word.lowercased()) { strangers[word] = (file as NSString).lastPathComponent }
            }
        }
        #expect(strangers.isEmpty, "words not in vocabulary.txt: \(strangers.keys.sorted().prefix(20))")
    }

    /// Each conversation parses into a valid document, or has no text at all (the same rule
    /// the heavy lane applies to the live export).
    @Test func everyConversationParsesLikeTheLiveExport() throws {
        let files = Self.files
        #expect(files.count >= 20, "the sample has \(files.count) conversations")
        var unexpected: [String] = []
        for file in files {
            let r = try ConversationParser.parseFile(file)
            if let doc = r.document {
                if !ConversationContract.issues(doc).isEmpty { unexpected.append("\(r.documentId):schema") }
            } else if r.problems != ["no-messages"] || r.stats.skipped != r.stats.sections {
                unexpected.append("\(r.documentId):\(r.problems.joined(separator: ","))")
            }
        }
        #expect(unexpected == [])
    }

    /// The ledger the runner installs matches the sample file for file (sync-ledger.sql).
    @Test func theSampleLedgerNamesEveryConversationWithItsCurrentHash() throws {
        let sql = try String(contentsOfFile: Self.root + "/sync-ledger.sql", encoding: .utf8)
        for file in Self.files {
            let r = try ConversationParser.parseFile(file)
            let path = "@HOME@/ai-vault-data/" + file.components(separatedBy: "/ai-vault-data/")[1]
            #expect(sql.contains("'\(path)','\(r.contentSha256)','\(r.documentId)'"), "\(path) is not in the ledger with its hash")
        }
    }
}
