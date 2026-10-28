import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Pairing end to end against a real learner-server: learner-server's own harness
// (scripts/pairing-server.ts, on ovh, its TEST database and a throwaway gate-* device that
// its teardown revokes), reached through one `ssh -L 3019:127.0.0.1:3019 ovh` session.
// The app's real code does everything: the pairing import (health check first), the
// endpoints, and a heartbeat carrying the pairing report, after which the server must call
// the pairing `ok`. The test key is held in memory only: never the real Keychain, never the
// app's defaults; the pairing file's local copy is deleted as soon as it is imported.
//
// Opt-in (LEARNER_HEAVY=1 LEARNER_PAIRING_E2E=1): it starts a server on ovh. The remote
// variant also needs `127.0.0.1 learner-pairing.test` in /etc/hosts (the owner's to add).
@Suite("Pairing end to end (learner-server harness on ovh)", .tags(.heavy, .outbox), .quietLog, .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: Live.heavy && Live.env["LEARNER_PAIRING_E2E"] == "1", "opt-in: set LEARNER_HEAVY=1 LEARNER_PAIRING_E2E=1"))
struct PairingE2ETests {
    static let port = 3019
    static let remoteHost = "learner-pairing.test"

    /// The harness behind its tunnel, stopped through its own teardown (SIGTERM).
    final class Harness: @unchecked Sendable {
        let dir = "/tmp/learner-pairing-e2e-\(UUID().uuidString.prefix(8))"
        let ssh = Process()
        private let out = Pipe()
        private let lock = NSLock()
        private var text = ""

        init(_ topologyArgs: [String]) throws {
            let command = "mkdir -p \(dir) && cd /root/learner && exec bun --env-file=/etc/learner/db.env --env-file=/etc/learner/learner.env "
                + "scripts/pairing-server.ts --port \(PairingE2ETests.port) --pairing-dir \(dir) " + topologyArgs.joined(separator: " ")
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ExitOnForwardFailure=yes",
                             "-L", "\(PairingE2ETests.port):127.0.0.1:\(PairingE2ETests.port)", "ovh", command]
            ssh.standardOutput = out
            ssh.standardError = out
            ssh.standardInput = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = String(decoding: h.availableData, as: UTF8.self)
                self?.lock.withLock { self?.text += chunk }
            }
            try ssh.run()
        }

        /// The harness's `{"event":"pairing-server",...}` line, once it is ready.
        func ready(within seconds: TimeInterval = 120) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, ssh.isRunning {
                let lines = lock.withLock { text }.split(separator: "\n")
                for line in lines where line.contains("\"pairing-server\"") {
                    if let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { return o }
                }
                usleep(200_000)
            }
            return nil
        }

        var output: String { lock.withLock { text } }

        /// The pairing file, read over ssh into memory.
        func pairingFile(_ path: String) -> Data? {
            let r = ChildProcess.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "ovh", "cat", path], timeout: 30)
            return r.ok ? Data(r.output.utf8) : nil
        }

        /// SIGTERM to the harness (its teardown revokes the device and checks nothing is
        /// left), then the tunnel ends with it; the remote dir goes.
        func stop() {
            // Bracketed, so the pattern does not match the remote shell running this very
            // command (pkill would kill that shell first). One TERM; teardown takes ~5 s
            // (revoke, check the old key gets 401, check the database, stop nginx and the API),
            // and runs even mid-startup.
            _ = ChildProcess.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "ovh", "pkill -TERM -f '[p]airing-server.ts.*\(dir)'"], timeout: 30)
            let deadline = Date().addingTimeInterval(60)
            while ssh.isRunning && Date() < deadline { usleep(200_000) }
            if ssh.isRunning { ssh.terminate() }
            _ = ChildProcess.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "ovh", "rm -rf \(dir)"], timeout: 30)
        }
    }

    /// Whether `host` resolves to loopback here (the remote variant's /etc/hosts entry).
    static func resolvesToLoopback(_ host: String) -> Bool {
        let r = ChildProcess.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host], timeout: 5)
        return r.output.contains("ip_address: 127.0.0.1")
    }

    /// One pairing, start to finish, against a harness started with `topologyArgs`.
    func pairs(_ topologyArgs: [String], expectRemote: Bool) throws {
        let harness = try Harness(topologyArgs)
        defer { harness.stop() }
        let ready = try #require(harness.ready(), "the harness did not start: \(harness.output.suffix(1500))")
        let remotePairingFile = try #require(ready["pairingFile"] as? String)
        let payload = try #require(harness.pairingFile(remotePairingFile), "could not read the pairing file")

        // The app's import, into scratch defaults; the key kept in memory, not the Keychain.
        let local = TempDir("pairing-e2e")
        let file = local.file("desktop-pairing.json")
        FileManager.default.createFile(atPath: file, contents: payload, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: file) }
        let defaults = ScratchDefaults("pairing-e2e")
        let key = Locked<String?>(nil)
        let imported = try #require(Pairing.importPayload(path: file, defaults: defaults, transport: URLSessionTransport(),
                                                          store: { _, k in key.value = k; return .success(()) }))
        guard case .success(let p) = imported else { Issue.record("import refused: \(imported)"); return }
        #expect(!FileManager.default.fileExists(atPath: file), "the pairing file is deleted once imported")
        let pinned = try #require(Pairing.pinned(defaults))
        #expect(pinned.clientId == p.clientId && pinned.apiUrl == p.apiUrl)

        // The endpoints, for this device, from the pinned URL only.
        let rpc = LearnerRPC(baseURL: pinned.apiUrl, clientId: pinned.clientId, key: { _ in key.value })
        let link = PairingLink(path: local.file("endpoints.json"))
        let first = link.refresh(rpc: rpc)
        try #require(first.kind == .ok, "getPairingEndpoints: \(first.describe) \(first.message ?? "")")
        let e = try #require(link.held)
        #expect(e.topology == (expectRemote ? "remote" : "same-machine"))
        #expect(e.uploaderRequired == expectRemote)
        #expect(link.moved == nil, "advertised \(e.apiBase), pinned \(pinned.apiUrl)")

        // A heartbeat with the pairing report; the server then calls this device's pairing ok.
        let beat = TrayAppManager.heartbeat(AppStatus(capture: .recording), appVersion: "e2e", screenpipeVersion: nil, capturePhase: nil,
                                            lastSentAt: nil, lastExport: nil, outboxStatus: "e2e",
                                            pairing: link.report(apiUrlInUse: rpc.baseURL, services: [("screenpipe", "http://localhost:3030")]),
                                            clientId: pinned.clientId)
        let reply = rpc.call("recordAppHeartbeat", beat)
        try #require(reply.kind == .ok, "heartbeat: \(reply.describe) \(reply.message ?? "")")
        #expect((reply.body as? [String: Any])?["endpointsVersion"] as? String == e.endpointsVersion)
        link.refresh(rpc: rpc)
        #expect(link.held?.pairingState == "ok", "pairing state \(link.held?.pairingState ?? "?")")
        // Another device's endpoints are refused for this key.
        let other = rpc.call("getPairingEndpoints", ["clientId": "not-this-device"])
        #expect(other.status == 403)
    }

    @Test func pairsWithAServerOnTheSameMachine() throws {
        try pairs(["--topology", "same-machine"], expectRemote: false)
    }

    @Test(.enabled(if: PairingE2ETests.resolvesToLoopback(PairingE2ETests.remoteHost),
                   "needs `127.0.0.1 learner-pairing.test` in /etc/hosts (the owner's to add)"))
    func pairsWithAServerOnAnotherMachine() throws {
        try pairs(["--topology", "remote", "--public-host", "127.0.0.1", "--advertise-host", Self.remoteHost], expectRemote: true)
    }
}
