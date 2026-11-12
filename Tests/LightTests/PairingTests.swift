import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// Pairing with learner-server (contract/desktop.ts, pinned at the server's pairing commit):
// the payload is the trust anchor, the key goes only to a URL that answers as a
// learner-server, the endpoints the server advertises drive the tray's links and the
// uploader, and a server that moved is never followed without the owner.
@Suite("Pairing with learner-server", .tags(.light, .outbox), .quietLog, .timeLimit(.minutes(1)))
struct PairingTests {
    static let api = "https://learner.example.test/learner-api"
    /// A made-up device key (24 characters, as the contract needs 16+), built so it never reads as a real secret.
    static let key = String(repeating: "k", count: 24)

    static func payload(_ fields: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: fields) }
    static var good: [String: Any] { ["apiUrl": api + "/", "clientId": "test-mac", "apiKey": key] }

    /// A learner-server's /api/health (no key needed).
    static func health(product: String = "learner-server", contract: Int = 1) -> StubTransport {
        StubTransport { s in
            s.path.hasSuffix("/api/health")
                ? StubTransport.json(200, ["ok": true, "product": product, "contract": contract, "db": "ok", "role": "api", "uptime": 1])
                : StubTransport.status(404)
        }
    }

    /// getPairingEndpoints as the contract shapes it.
    static func endpoints(version: String = "v1", base: String = api, growthbook: String? = "https://learner.example.test/growthbook",
                          web: String? = nil, remote: Bool = true) -> [String: Any] {
        [
            "topology": remote ? "remote" : "same-machine", "contract": 1, "serverVersion": "test", "endpointsVersion": version,
            "api": ["base": base, "rpcBase": base + "/rpc", "health": base + "/api/health"],
            "web": web as Any? ?? NSNull(),
            "growthbook": growthbook.map { ["app": $0, "api": $0] } as Any? ?? NSNull(),
            "uploader": ["required": remote],
            "device": ["pairingState": "ok", "lastPairing": NSNull(), "lastPairingAt": NSNull()],
        ]
    }

    @Test func aPayloadIsCheckedFieldByField() throws {
        guard case .success(let p) = Pairing.parse(Self.payload(Self.good)) else { Issue.record("good payload refused"); return }
        #expect(p == Pairing.Payload(apiUrl: Self.api, clientId: "test-mac", apiKey: Self.key), "trailing slash dropped")
        let bad: [[String: Any]] = [
            Self.good.merging(["apiUrl": "ftp://learner.example.test"]) { $1 },
            Self.good.merging(["apiUrl": "https://user:pw@learner.example.test/api"]) { $1 },
            Self.good.merging(["apiUrl": "https://learner.example.test/api?x=1"]) { $1 },
            Self.good.merging(["clientId": "Not A Device"]) { $1 },
            Self.good.merging(["apiKey": "short"]) { $1 },
            Self.good.merging(["apiKey": "has a space in it 0123456789"]) { $1 },
            Self.good.merging(["apiKey": "has\"quote0123456789abc"]) { $1 },
        ]
        for b in bad {
            guard case .failure(.refused) = Pairing.parse(Self.payload(b)) else { Issue.record("accepted \(b)"); continue }
        }
        guard case .failure(.refused) = Pairing.parse(Data("not json".utf8)) else { Issue.record("accepted non-JSON"); return }
    }

    @Test func aURLMustAnswerAsALearnerServerOfThisContract() {
        if case .failure(let e) = Pairing.checkServer(Self.api, transport: Self.health()) { Issue.record("refused a learner-server: \(e)") }
        guard case .failure(.notLearnerServer) = Pairing.checkServer(Self.api, transport: Self.health(product: "something-else")) else {
            Issue.record("accepted another product"); return
        }
        guard case .failure(.notLearnerServer) = Pairing.checkServer(Self.api, transport: Self.health(contract: 2)) else {
            Issue.record("accepted another contract"); return
        }
        guard case .failure(.notLearnerServer) = Pairing.checkServer(Self.api, transport: StubTransport { _ in StubTransport.status(502) }) else {
            Issue.record("accepted a 502"); return
        }
    }

    @Test func importingPinsTheServerStoresTheKeyAndDeletesTheFile() throws {
        let dir = TempDir("pairing")
        let defaults = scratchDefaults()
        let file = dir.write("desktop-pairing.json", String(decoding: Self.payload(Self.good), as: UTF8.self))
        var stored: [(String, String)] = []
        let result = try #require(Pairing.importPayload(path: file, defaults: defaults, transport: Self.health(),
                                                        store: { stored.append(($0, $1)); return .success(()) }))
        guard case .success = result else { Issue.record("not imported: \(result)"); return }
        #expect(stored.count == 1 && stored[0] == ("test-mac", Self.key))
        let pinned = try #require(Pairing.pinned(defaults))
        #expect(pinned.apiUrl == Self.api && pinned.clientId == "test-mac")
        #expect(!FileManager.default.fileExists(atPath: file), "the key must not stay on disk")
        // No file: nothing to do, nothing asked of the network.
        let quiet = StubTransport { _ in StubTransport.status(500) }
        #expect(Pairing.importPayload(path: file, defaults: defaults, transport: quiet, store: { _, _ in .success(()) }) == nil)
        #expect(quiet.seen.isEmpty)
    }

    @Test func theKeyIsNeverStoredForAServerThatIsNotOne() throws {
        let dir = TempDir("pairing-refused")
        let defaults = scratchDefaults()
        let file = dir.write("desktop-pairing.json", String(decoding: Self.payload(Self.good), as: UTF8.self))
        var stored = 0
        let result = try #require(Pairing.importPayload(path: file, defaults: defaults, transport: Self.health(product: "impostor"),
                                                        store: { _, _ in stored += 1; return .success(()) }))
        guard case .failure(.notLearnerServer) = result else { Issue.record("imported: \(result)"); return }
        #expect(stored == 0)
        #expect(Pairing.pinned(defaults) == nil)
        #expect(FileManager.default.fileExists(atPath: file), "left for the owner (and the next launch)")
    }

    @Test func theEndpointsAreReadAsTheContractShapesThem() throws {
        let e = try #require(PairingEndpoints.parse(Self.endpoints(web: "https://learner.example.test/learner/")))
        #expect(e.topology == "remote" && e.uploaderRequired && e.endpointsVersion == "v1")
        #expect(e.growthbookApp == "https://learner.example.test/growthbook" && e.web == "https://learner.example.test/learner/")
        let none = try #require(PairingEndpoints.parse(Self.endpoints(growthbook: nil, remote: false)))
        #expect(none.growthbookApp == nil && none.web == nil && !none.uploaderRequired)
        #expect(PairingEndpoints.parse(["topology": "remote"]) == nil)
    }

    @Test func endpointsAreFetchedForThisDeviceKeptAndRefetchedWhenTheVersionChanges() throws {
        let dir = TempDir("endpoints")
        let version = Locked("v1")
        let stub = StubTransport { s in
            s.path.hasSuffix("/rpc/getPairingEndpoints") ? StubTransport.json(200, ["data": Self.endpoints(version: version.value)]) : StubTransport.status(404)
        }
        let rpc = LearnerRPC(baseURL: Self.api, clientId: "test-mac", transport: stub, key: { _ in Self.key })
        let link = PairingLink(path: dir.file("endpoints.json"))
        let changes = Locked(0)
        link.onChange = { _ in changes.withLock { $0 += 1 } }

        link.heartbeatReplied(["serverTime": "x", "endpointsVersion": "v1"], rpc: rpc)
        #expect(link.held?.endpointsVersion == "v1" && link.moved == nil)
        #expect(stub.seen.count == 1)
        #expect((stub.seen[0].body?["data"] as? [String: Any])?["clientId"] as? String == "test-mac")
        #expect(stub.seen[0].url.absoluteString == Self.api + "/rpc/getPairingEndpoints", "the key only goes to the pinned URL")
        // The same version: nothing fetched.
        link.heartbeatReplied(["serverTime": "x", "endpointsVersion": "v1"], rpc: rpc)
        #expect(stub.seen.count == 1)
        // A new one: fetched once, kept on disk for the next launch.
        version.value = "v2"
        link.heartbeatReplied(["serverTime": "x", "endpointsVersion": "v2"], rpc: rpc)
        #expect(stub.seen.count == 2 && link.held?.endpointsVersion == "v2" && changes.value == 2)
        #expect(PairingLink(path: dir.file("endpoints.json")).held?.endpointsVersion == "v2")
        // The heartbeat reports what is held.
        let report = link.report(apiUrlInUse: Self.api, services: [("screenpipe", "http://localhost:3030"), ("bad", "not a url")])
        #expect(report["endpointsVersionHeld"] as? String == "v2")
        #expect((report["services"] as? [[String: String]])?.map { $0["name"] } == ["screenpipe"])
    }

    @Test func aServerThatMovedIsOfferedButNeverFollowed() {
        let dir = TempDir("moved")
        let stub = StubTransport { _ in StubTransport.json(200, ["data": Self.endpoints(base: "https://elsewhere.example.test/learner-api")]) }
        let rpc = LearnerRPC(baseURL: Self.api, clientId: "test-mac", transport: stub, key: { _ in Self.key })
        let link = PairingLink(path: dir.file("endpoints.json"))
        link.refresh(rpc: rpc)
        #expect(link.moved == "https://elsewhere.example.test/learner-api")
        #expect(rpc.baseURL == Self.api)
        #expect(stub.seen.allSatisfy { $0.url.host == "learner.example.test" }, "the key went to another origin")
        // A trailing slash is not a move.
        let same = StubTransport { _ in StubTransport.json(200, ["data": Self.endpoints(base: Self.api + "/")]) }
        let link2 = PairingLink(path: dir.file("endpoints2.json"))
        link2.refresh(rpc: LearnerRPC(baseURL: Self.api, clientId: "test-mac", transport: same, key: { _ in Self.key }))
        #expect(link2.moved == nil)
    }

    @Test func theGrowthBookLinkIsWhatTheServerAdvertises() {
        let advertised = PairingEndpoints.parse(Self.endpoints(growthbook: "https://gb.example.test"))
        let none = PairingEndpoints.parse(Self.endpoints(growthbook: nil))
        #expect(GrowthBookLink.current(override: nil, advertised: advertised, serverBase: Self.api)?.absoluteString == "https://gb.example.test")
        // The server publishes none: no link (the line is hidden), even though one could be derived.
        #expect(GrowthBookLink.current(override: nil, advertised: none, serverBase: Self.api) == nil)
        // Before the server has answered: derived from the server's origin.
        #expect(GrowthBookLink.current(override: nil, advertised: nil, serverBase: Self.api)?.absoluteString == "https://learner.example.test/growthbook/")
        // An explicit URL always wins.
        #expect(GrowthBookLink.current(override: "https://mine.example.test", advertised: none, serverBase: Self.api)?.absoluteString == "https://mine.example.test")
    }

    /// The first launch's heartbeat goes out before any endpoints are held; its reply
    /// fetches them, and a second heartbeat follows at once with the version held (not a
    /// 5-minute beat later, as on 10-28). The same version again sends nothing more.
    @Test func aChangeOfEndpointsSendsAHeartbeatAtOnceWithTheVersionHeld() throws {
        let f = OutboxFixture(turns: 0) { s in
            s.path.hasSuffix("/rpc/getPairingEndpoints")
                ? StubTransport.json(200, ["data": Self.endpoints(version: "v1")])
                : StubTransport.json(200, ["data": ["serverTime": "2026-10-28T14:00:00Z", "endpointsVersion": "v1"]])
        }
        let rpc = LearnerRPC(baseURL: "http://stand-in.invalid", clientId: "test-mac", transport: f.stub, key: { _ in Self.key })
        let link = PairingLink(path: f.dir.file("endpoints.json"))
        f.sender.setHeartbeatInput { ["clientId": "test-mac", "pairing": link.report(apiUrlInUse: "http://stand-in.invalid", services: [])] }
        link.follow(f.sender, rpc: rpc)
        f.sender.heartbeatJob.kick("launch")
        let beats = { f.stub.seen.filter { $0.path.hasSuffix("/rpc/recordAppHeartbeat") } }
        #expect(eventually(5) { beats().count == 2 })
        let held = beats().map { (($0.body?["data"] as? [String: Any])?["pairing"] as? [String: Any])?["endpointsVersionHeld"] }
        #expect(held.first.map { $0 is NSNull } == true, "the launch heartbeat knows no version yet")
        #expect(held.last as? String == "v1", "the next heartbeat carries the version: \(held)")
        #expect(f.stub.seen.filter { $0.path.hasSuffix("/rpc/getPairingEndpoints") }.count == 1)
        usleep(300_000)
        #expect(beats().count == 2, "an unchanged version sends no more")
        withExtendedLifetime(link) {}
    }

    // MARK: One-paste pairing

    static var goodPayload: Pairing.Payload { Pairing.Payload(apiUrl: api, clientId: "test-mac", apiKey: key) }

    @Test func aPairingCodeCarriesThePayloadAndIsFoundInAnyText() throws {
        let code = Pairing.code(for: Self.goodPayload)
        #expect(code.hasPrefix("learner-pair-v1:"))
        #expect(!code.contains("+") && !code.contains("/") && !code.contains("="), "base64url, one word: \(code)")
        guard case .success(let p) = Pairing.payload(fromCode: code) else { Issue.record("not decoded"); return }
        #expect(p == Self.goodPayload)
        // A clipboard often holds more: the code is picked out, whitespace and all.
        #expect(Pairing.findCode(in: "Your code:\n  \(code)  \n(keep it private)") == code)
        #expect(Pairing.findCode(in: "nothing here") == nil)
    }

    @Test func aDamagedOrForeignCodeIsRefusedBeforeAnythingIsContacted() {
        let fields = Self.good.merging(["apiKey": "short"]) { $1 }
        let weak = "learner-pair-v1:" + Self.payload(fields).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        for bad in ["learner-pair-v2:abc", "learner-pair-v1:@@@@", weak, "learner-pair-v1:" + Data("not json".utf8).base64EncodedString()] {
            guard case .failure(.refused) = Pairing.payload(fromCode: bad) else { Issue.record("accepted: \(bad)"); continue }
        }
    }

    @Test func importingACodeChecksTheServerStoresTheKeyAndPins() throws {
        let defaults = scratchDefaults()
        var stored: [(String, String)] = []
        let result = Pairing.importCode(Pairing.code(for: Self.goodPayload), defaults: defaults, transport: Self.health(),
                                        store: { stored.append(($0, $1)); return .success(()) })
        guard case .success = result else { Issue.record("not imported: \(result)"); return }
        #expect(stored.count == 1 && stored[0] == ("test-mac", Self.key))
        #expect(Pairing.pinned(defaults)?.apiUrl == Self.api)
        // Not a learner-server: nothing stored, nothing pinned.
        let other = scratchDefaults()
        var none = 0
        let refused = Pairing.importCode(Pairing.code(for: Self.goodPayload), defaults: other, transport: Self.health(product: "something-else"),
                                         store: { _, _ in none += 1; return .success(()) })
        guard case .failure(.notLearnerServer) = refused else { Issue.record("imported from a stranger: \(refused)"); return }
        #expect(none == 0 && Pairing.pinned(other) == nil)
    }

    @Test func toolPairReadsTheCodeFromStdinNeverFromArguments() {
        var out: [String] = [], err: [String] = []
        let io = ToolIO(out: { out.append($0) }, err: { err.append($0) })
        let ok = PairTool.main(input: Data("\(Pairing.code(for: Self.goodPayload))\n".utf8), io: io, transport: Self.health(),
                               defaults: scratchDefaults(), store: { _, _ in .success(()) }, clean: false)
        #expect(ok == 0 && out.first?.hasPrefix("paired with \(Self.api) as test-mac") == true, "\(out) \(err)")
        #expect(!(out + err).joined().contains(Self.key), "the key is never printed")
        #expect(PairTool.main(input: Data(), io: io, transport: Self.health(), defaults: scratchDefaults(), store: { _, _ in .success(()) }, clean: false) == 2)
    }

    @Test func plainHttpToAnotherMachineIsCalledOutLocalAddressesAreNot() {
        for local in ["http://127.0.0.1:3010", "http://localhost:3010", "http://192.168.1.20/learner-api", "http://10.0.0.5", "http://172.20.1.1", "http://studio.local:3010"] {
            #expect(!Pairing.isUnencryptedRemote(local), "\(local)")
        }
        for remote in ["http://learner.example.test/learner-api", "http://172.32.0.1", "http://8.8.8.8"] {
            #expect(Pairing.isUnencryptedRemote(remote), "\(remote)")
        }
        #expect(!Pairing.isUnencryptedRemote("https://learner.example.test/learner-api"))
    }

    @Test func aNewPairingCleansUpTheOldKeyAndEndpointsOnlyWhenTheyChange() {
        let p = Self.goodPayload
        #expect(Pairing.leftovers(previous: nil, paired: p) == .init(keyFor: nil, endpoints: false))
        #expect(Pairing.leftovers(previous: (Self.api + "/", "test-mac"), paired: p) == .init(keyFor: nil, endpoints: false))
        #expect(Pairing.leftovers(previous: ("https://old.example.test/learner-api", "old-mac"), paired: p) == .init(keyFor: "old-mac", endpoints: true))
        #expect(Pairing.leftovers(previous: (Self.api, "old-mac"), paired: p) == .init(keyFor: "old-mac", endpoints: false))
    }
}
