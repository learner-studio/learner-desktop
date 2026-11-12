import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The owner's REAL learner-server, through one throwaway test device per CI run (scripts/ci.sh
// prod-device: createTestDevice + seedMasteryGain with the CI minter's key; prod-revoke
// removes the device and everything it wrote, and it dies at its TTL regardless). The app's
// own code pairs from the device's pairing code, heartbeats, and runs the mastery feed
// against production. The device key is kept in memory and never printed or asserted on: a
// failed #expect prints its operands, and these logs are public.
//
// GitHub runner only, and only when prod-device made a device (no secret on forks).
private struct ProdDevice {
    let code: String, clientId: String, runId: String, conceptId: String

    static let loaded: ProdDevice? = {
        guard TestEnvironment.isRunner, Live.env["GITHUB_ACTIONS"] == "true",
              let path = Live.env["LEARNER_PROD_DEVICE_FILE"], let data = FileManager.default.contents(atPath: path),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = o["pairingCode"] as? String, let id = o["clientId"] as? String,
              let run = o["runId"] as? String, let concept = o["conceptId"] as? String else { return nil }
        return ProdDevice(code: code, clientId: id, runId: run, conceptId: concept)
    }()
}

@Suite("Production learner-server (a throwaway test device)", .tags(.heavy, .outbox), .quietLog, .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: Live.heavy, "heavy lane only (LEARNER_HEAVY=1)"),
       .enabled(if: ProdDevice.loaded != nil, "no production test device (GitHub runner with LEARNER_CI_MINT_KEY only)"))
struct ProductionServerTests {
    /// Paired as the app pairs (from the code, its health and identity checked), into scratch
    /// defaults; the key in memory only.
    func paired() throws -> (rpc: LearnerRPC, defaults: UserDefaults, link: PairingLink, dir: TempDir) {
        let device = try #require(ProdDevice.loaded)
        let defaults = ScratchDefaults("prod-device")
        let key = Locked<String?>(nil)
        let result = Pairing.importCode(device.code, defaults: defaults, transport: URLSessionTransport(),
                                        store: { _, k in key.value = k; return .success(()) })
        guard case .success(let p) = result else { throw ToolError("the pairing code did not import: \(result)") }
        #expect(p.clientId == device.clientId)
        let pinned = try #require(Pairing.pinned(defaults))
        let dir = TempDir("prod-device")
        let rpc = LearnerRPC(baseURL: pinned.apiUrl, clientId: pinned.clientId, key: { _ in key.value })
        return (rpc, defaults, PairingLink(path: dir.file("endpoints.json")), dir)
    }

    @Test func theDevicePairsHeartbeatsAndIsConfinedToItself() throws {
        let (rpc, _, link, _) = try paired()
        let first = link.refresh(rpc: rpc)
        try #require(first.kind == .ok, "getPairingEndpoints: \(first.describe) \(first.message ?? "")")
        let e = try #require(link.held)
        #expect(e.topology == "remote", "production is another machine")
        #expect(link.moved == nil, "production advertises \(e.apiBase), the code pinned \(rpc.baseURL)")

        let beat = TrayAppManager.heartbeat(AppStatus(capture: .recording), appVersion: "ci-prod", screenpipeVersion: nil, capturePhase: nil,
                                            lastSentAt: nil, lastExport: nil, outboxStatus: "ci-prod",
                                            pairing: link.report(apiUrlInUse: rpc.baseURL, services: [("screenpipe", "http://localhost:3030")]),
                                            clientId: rpc.clientId)
        let reply = rpc.call("recordAppHeartbeat", beat)
        try #require(reply.kind == .ok, "heartbeat: \(reply.describe) \(reply.message ?? "")")
        link.refresh(rpc: rpc)
        #expect(link.held?.pairingState == "ok", "pairing state \(link.held?.pairingState ?? "?")")

        // Confined: another device's endpoints, and a call outside a test device's allowance.
        #expect(rpc.call("getPairingEndpoints", ["clientId": "not-this-device"]).status == 403)
        let outside = rpc.call("getBaselineStatus", [:])
        #expect(outside.status == 403, "a test device's key reached getBaselineStatus: HTTP \(outside.status)")
    }

    @Test func theSeededGainIsAnnouncedAndItsFeedbackRecordedOnce() throws {
        let device = try #require(ProdDevice.loaded)
        let (rpc, defaults, _, dir) = try paired()
        let feed = MasteryFeed(rpc: rpc, defaults: defaults, jobName: "prod-device-\(UUID().uuidString.prefix(8))",
                               stateDir: dir.file("jobs"), sendFeedbackAtOnce: false)
        let outcome = feed.runOnce()
        if case .ok = outcome {} else { Issue.record("the feed run did not succeed against production: \(outcome)") }
        #expect(feed.pending.map(\.runId) == [device.runId], "exactly the seeded gain")
        #expect(feed.pending.first?.conceptId == device.conceptId)

        // Opened, as a click records it; then twice more by hand: one row, the app's own.
        let first = rpc.call("recordNotificationFeedback", ["runId": device.runId, "action": "opened"])
        let r1 = try #require(first.body as? [String: Any], "feedback: \(first.describe)")
        #expect(r1["recorded"] as? Bool == true)
        let at = try #require(r1["at"] as? String)
        let again = rpc.call("recordNotificationFeedback", ["runId": device.runId, "action": "opened"]).body as? [String: Any]
        #expect(again?["at"] as? String == at, "a replay made a second row")
    }
}
