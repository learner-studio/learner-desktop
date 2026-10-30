import AppKit
import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Mastery notifications end to end against a real learner-server: its pairing harness on ovh
// (scripts/pairing-server.ts --seed-mastery-gain: a throwaway learner on the TEST database
// holding exactly one qualifying gain, removed with the device at teardown), through the same
// `ssh -L 3019` tunnel as PairingE2ETests. The app's real code does everything: the pairing
// import, the feed job's run, the presenter and the real toast panel, Open, and the feedback
// sent back. Nothing touches the installed app, its Keychain item or its defaults.
//
// Opt-in (LEARNER_HEAVY=1 LEARNER_MASTERY_E2E=1): it starts a server on ovh and shows a toast.
/// The real transport, keeping each reply: what the app itself sent and got back.
private final class Recording: HTTPTransport, @unchecked Sendable {
    private let inner = URLSessionTransport()
    private let lock = NSLock()
    private var log: [(rpc: String, input: [String: Any]?, reply: HTTPReply)] = []

    func send(_ request: URLRequest, timeout: TimeInterval) -> HTTPReply {
        let reply = inner.send(request, timeout: timeout)
        let input = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["data"] as? [String: Any]
        lock.withLock { log.append((request.url?.lastPathComponent ?? "", input, reply)) }
        return reply
    }

    func raw(_ rpc: String) -> [String] {
        lock.withLock { log }.filter { $0.rpc == rpc }.map { "\($0.reply.status) " + String(decoding: $0.reply.body ?? Data(), as: UTF8.self) }
    }

    /// The `data` of each reply to `rpc`, in order.
    /// `cursorOnly`: only the feed's own queries (a `since` time), not the recent rows' (null).
    func replies(_ rpc: String, cursorOnly: Bool = false) -> [(status: Int, data: [String: Any]?)] {
        lock.withLock { log }.filter { $0.rpc == rpc && (!cursorOnly || $0.input?["since"] is String) }.map { r in
            // As LearnerRPC reads it: the `data` envelope when there is one, else the body itself.
            let o = r.reply.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (r.reply.status, (o?["data"] as? [String: Any]) ?? o)
        }
    }
}

@MainActor
@Suite("Mastery end to end (learner-server harness on ovh)", .tags(.heavy, .mastery), .quietLog, .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: Live.heavy && Live.env["LEARNER_MASTERY_E2E"] == "1", "opt-in: set LEARNER_HEAVY=1 LEARNER_MASTERY_E2E=1"))
struct MasteryE2ETests {
    @Test func aSeededGainIsToastedOpenedAndItsFeedbackRecorded() throws {
        let harness = try PairingE2ETests.Harness(["--topology", "same-machine", "--seed-mastery-gain"])
        defer { harness.stop() }
        let ready = try #require(harness.ready(), "the harness did not start: \(harness.output.suffix(1500))")
        let seeded = try #require(ready["seededGain"] as? [String: Any], "no seededGain in \(ready)")
        let runId = try #require(seeded["runId"] as? String)
        let conceptId = try #require(seeded["conceptId"] as? String)
        let remoteFile = try #require(ready["pairingFile"] as? String)
        let payload = try #require(harness.pairingFile(remoteFile), "could not read the pairing file")

        // Paired as the app pairs, into scratch defaults; the key kept in memory only.
        let local = TempDir("mastery-e2e")
        let file = local.file("desktop-pairing.json")
        FileManager.default.createFile(atPath: file, contents: payload, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: file) }
        let defaults = ScratchDefaults("mastery-e2e")
        let key = Locked<String?>(nil)
        let imported = try #require(Pairing.importPayload(path: file, defaults: defaults, transport: URLSessionTransport(),
                                                          store: { _, k in key.value = k; return .success(()) }))
        guard case .success = imported else { Issue.record("import refused: \(imported)"); return }
        let pinned = try #require(Pairing.pinned(defaults))
        let wire = Recording()
        let rpc = LearnerRPC(baseURL: pinned.apiUrl, clientId: pinned.clientId, transport: wire, key: { _ in key.value })
        let link = PairingLink(path: local.file("endpoints.json"))
        try #require(link.refresh(rpc: rpc).kind == .ok)
        let web = try #require(link.held?.web, "the harness publishes no web URL")

        // One run of the feed job: the seeded gain, and the live baseline.
        let feed = MasteryFeed(rpc: rpc, defaults: defaults, jobName: "mastery-e2e-\(UUID().uuidString.prefix(8))",
                               stateDir: local.file("jobs"), sendFeedbackAtOnce: false)
        if case let .ok(summary, _) = feed.runOnce() { #expect(summary == "1 new") } else { Issue.record("the feed run did not succeed") }
        let gain = try #require(feed.pending.first)
        #expect(feed.pending.map(\.runId) == [runId], "exactly the seeded gain")
        #expect(gain.conceptId == conceptId)
        #expect(gain.line == "▲ 50% → 65%")
        #expect(gain.quote != nil, "the learner's words travel with it")
        #expect(feed.baseline != nil, "getBaselineStatus answered")
        #expect(feed.reachable == .online)

        // The real toast, then Open, as a click would.
        let toast = MasteryToastController()
        var opened: [URL] = []
        let presenter = MasteryPresenter(feed: feed, toast: toast, inCall: { false },
                                         openURL: { opened.append($0); return true }, web: { web })
        presenter.tick()
        #expect(toast.isShowing)
        #expect(toast.panel?.sharingType == NSWindow.SharingType.none)
        toast.openClicked()
        toast.panel?.orderOut(nil)
        let expected = try #require(MasteryLink.url(web: web, conceptId: conceptId))
        #expect(opened == [expected])
        #expect(opened.first?.absoluteString.contains("osmosis?conceptId=") == true)
        #expect(feed.queuedFeedback == [.init(runId: runId, action: .opened)])

        // The next run sends it, and the server records the app's own call (not a replay's).
        _ = feed.runOnce()
        #expect(feed.queuedFeedback.isEmpty, "the server took the feedback")
        let sent = wire.replies("recordNotificationFeedback")
        try #require(sent.count == 1, "the app sent \(sent.count) feedback call(s)")
        #expect(sent[0].status == 200 && sent[0].data?["recorded"] as? Bool == true, "the app's own call: \(wire.raw("recordNotificationFeedback"))")
        let appAt = try #require(sent[0].data?["at"] as? String)
        let replay1 = rpc.call("recordNotificationFeedback", ["runId": runId, "action": "opened"])
        let replay2 = rpc.call("recordNotificationFeedback", ["runId": runId, "action": "opened"])
        let r1 = try #require(replay1.body as? [String: Any]), r2 = try #require(replay2.body as? [String: Any])
        #expect(r1["recorded"] as? Bool == true)
        #expect(r1["at"] as? String == appAt && r2["at"] as? String == appAt, "one row, made by the app's call: \(appAt) \(r1) \(r2)")

        // A restart: the same gain is never shown again.
        let again = MasteryFeed(rpc: rpc, defaults: defaults, jobName: "mastery-e2e-again-\(UUID().uuidString.prefix(8))",
                                stateDir: local.file("jobs"), sendFeedbackAtOnce: false)
        _ = again.runOnce()
        #expect(again.pending.isEmpty)
        // And it is the app's own dedupe that holds it back: the server still sent the run.
        let lastPage = try #require(wire.replies("getMasteryNotifications", cursorOnly: true).last?.data?["notifications"] as? [[String: Any]])
        #expect(lastPage.contains { $0["runId"] as? String == runId }, "the restart's query no longer returns the run, so dedupe went untested")
    }
}
