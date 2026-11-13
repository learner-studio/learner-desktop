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
private struct ProdDevice: CustomStringConvertible {
    let code: String, clientId: String, runId: String, conceptId: String, completedAt: Date, apiUrl: String
    /// Never the code (it carries the device key): a failed #expect prints its operands.
    var description: String { "ProdDevice(\(clientId), run \(runId))" }

    static let loaded: ProdDevice? = {
        guard TestEnvironment.isRunner, Live.env["GITHUB_ACTIONS"] == "true",
              let path = Live.env["LEARNER_PROD_DEVICE_FILE"], let data = FileManager.default.contents(atPath: path),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = o["pairingCode"] as? String, let id = o["clientId"] as? String,
              let run = o["runId"] as? String, let concept = o["conceptId"] as? String,
              let completed = (o["completedAt"] as? String).flatMap(ProdDevice.parseDate),
              let api = o["apiUrl"] as? String else { return nil }
        return ProdDevice(code: code, clientId: id, runId: run, conceptId: concept, completedAt: completed, apiUrl: api)
    }()

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
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
        let (pairedId, deviceId) = (p.clientId, device.clientId)
        #expect(pairedId == deviceId)
        let pinned = try #require(Pairing.pinned(defaults))
        // Production itself, not the runner's own local learner-server (which would pass the
        // same identity check): the code pins the URL prod-device created the device on.
        let (pinnedURL, prodURL) = (Pairing.normalized(pinned.apiUrl), Pairing.normalized(device.apiUrl))
        #expect(pinnedURL == prodURL)
        FileHandle.standardError.write(Data("PRODUCTION: paired with \(URL(string: pinnedURL)?.host ?? pinnedURL) as \(deviceId)\n".utf8))
        let dir = TempDir("prod-device")
        let rpc = LearnerRPC(baseURL: pinned.apiUrl, clientId: pinned.clientId, key: { _ in key.value })
        return (rpc, defaults, PairingLink(path: dir.file("endpoints.json")), dir)
    }

    @Test func theDevicePairsHeartbeatsAndIsConfinedToItself() throws {
        let (rpc, _, link, dir) = try paired()
        _ = dir   // keeps the scratch folder (endpoints.json) for the whole test
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

        // Confined: another device's endpoints, and a (read-only) RPC outside a test device's
        // allowance. (getBaselineStatus is inside it: the feed calls it.)
        #expect(rpc.call("getPairingEndpoints", ["clientId": "not-this-device"]).status == 403)
        let outside = rpc.call("getMasteryProgress", [:])
        #expect(outside.status == 403, "a test device's key reached getMasteryProgress: HTTP \(outside.status)")
    }

    @Test func theSeededGainIsAnnouncedAndItsFeedbackRecordedOnce() throws {
        let device = try #require(ProdDevice.loaded)
        let (rpc, defaults, _, dir) = try paired()
        // As if installed just before the gain was seeded: however long the lanes before this
        // took, the feed's first look reaches it (it keeps gains completed after install).
        defaults.set(device.completedAt.addingTimeInterval(-60), forKey: MasteryFeed.Key.installedAt)
        defaults.set(device.completedAt.addingTimeInterval(-60), forKey: MasteryFeed.Key.since)
        let feed = MasteryFeed(rpc: rpc, defaults: defaults, jobName: "prod-device-\(UUID().uuidString.prefix(8))",
                               stateDir: dir.file("jobs"), sendFeedbackAtOnce: false)
        let outcome = feed.runOnce()
        if case .ok = outcome {} else { Issue.record("the feed run did not succeed against production: \(outcome)") }
        #expect(feed.pending.map(\.runId) == [device.runId], "exactly the seeded gain")
        #expect(feed.pending.first?.conceptId == device.conceptId)

        // The server's idempotence (not the app's click path, which the local harness covers):
        // opened twice, one row.
        let first = rpc.call("recordNotificationFeedback", ["runId": device.runId, "action": "opened"])
        let r1 = try #require(first.body as? [String: Any], "feedback: \(first.describe)")
        #expect(r1["recorded"] as? Bool == true)
        let at = try #require(r1["at"] as? String)
        let again = rpc.call("recordNotificationFeedback", ["runId": device.runId, "action": "opened"]).body as? [String: Any]
        #expect(again?["at"] as? String == at, "a replay made a second row")
    }

    /// The confinement that matters: a test device cannot read the owner's mastery. Asked for
    /// everything since 1970, the server answers only this device's seeded run. Counts only
    /// in any message: a failure must not print the owner's rows into a public log.
    @Test func theDeviceCannotSeeTheOwnersMastery() throws {
        let device = try #require(ProdDevice.loaded)
        let (rpc, _, _, dir) = try paired()
        _ = dir
        let reply = rpc.call("getMasteryNotifications", ["since": "1970-01-01T00:00:00.000Z", "limit": 50])
        try #require(reply.kind == .ok, "getMasteryNotifications: HTTP \(reply.status)")
        let rows = (reply.body as? [String: Any])?["notifications"] as? [[String: Any]] ?? []
        let foreign = rows.filter { ($0["runId"] as? String) != device.runId }.count
        #expect(foreign == 0, "\(foreign) of \(rows.count) notification(s) since 1970 are not this test device's seed")
        #expect(rows.count == 1, "\(rows.count) notification(s) since 1970; want exactly the seed")
    }
}
