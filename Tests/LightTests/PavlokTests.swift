import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

@Suite("Pavlok", .quietLog) struct PavlokTests {
    @Test func eachStimulusIsOnePulseAtTheChosenLevel() {
        for v in [1, 5, 10, 25, 40, 75, 100] {
            let pulse = Data([0x81, 0x0C, UInt8(v), 0x18, 0x18])
            #expect(PavlokPacket.encode(.vibe, intensity: v) == pulse)
            #expect(PavlokPacket.encode(.beep, intensity: v) == pulse)
            #expect(PavlokPacket.encode(.zap, intensity: v) == Data([0x81, UInt8(v)]))
        }
        #expect(PavlokPacket.encode(.beep, intensity: 150)[2] == 100)
        #expect(PavlokPacket.encode(.beep, intensity: -10)[2] == 1)
        #expect(PavlokPacket.encode(.zap, intensity: 100, pavlok2: false) == Data([0x01, 255, 0x32, 0x32]))
    }

    @Test func characteristicsAndAdvertisementsAreRecognised() {
        #expect(PavlokPacket.modality(of: "156E1003-A300-4FEA-897B-86F698D74461") == .zap)
        #expect(PavlokPacket.modality(of: "156e1001-a300-4fea-897b-86f698d74461") == .vibe)
        #expect(PavlokPacket.modality(of: "156E1002-A300-4FEA-897B-86F698D74461") == .beep)
        #expect(PavlokPacket.modality(of: "2A19") == nil)
        #expect(PavlokPacket.isBattery("2A19"))
        #expect(PavlokPacket.isPavlok2("156E1003-A300", .zap))
        #expect(!PavlokPacket.isPavlok2("6E9D7A34-0000", .zap))
        #expect(PavlokPacket.looksLikePavlok(name: "Pavlok-3", services: []))
        #expect(PavlokPacket.looksLikePavlok(name: "", services: ["156E1000-A300-4FEA-897B-86F698D74461"]))
        #expect(!PavlokPacket.looksLikePavlok(name: "AirPods", services: ["180F"]))
    }

    @Test func testFireArgumentsAreValidatedBeforeAnythingElse() {
        func parse(_ a: String...) -> PavlokTestFireArgs? { PavlokTestFireArgs.parse(["app", "--pavlok-test-fire"] + a) }
        #expect(parse("vibe") == PavlokTestFireArgs(modality: .vibe))
        #expect(parse("ZAP", "20", "--wait", "5", "--trace-ble") == PavlokTestFireArgs(modality: .zap, intensity: 20, wait: 5, traceBle: true))
        #expect(parse("beep", "--wait", "300")?.wait == 300)
        for bad in [[], ["punch"], ["shock"], [""], ["vibe", "0"], ["vibe", "101"], ["vibe", "banana"],
                    ["vibe", "20", "--wait"], ["vibe", "20", "--wait", "0"], ["vibe", "--wait", "999999"], ["vibe", "--wait", "soon"]] {
            #expect(PavlokTestFireArgs.parse(["app", "--pavlok-test-fire"] + bad) == nil, "accepted \(bad)")
        }
        for m in Modality.allCases { #expect(PavlokTestFireArgs.usage.contains(m.rawValue)) }
    }

    @Test func onlyFreshWellFormedRequestsForThisProcessAreAccepted() {
        let pid: Int32 = 4242
        let now = Date()
        func request(_ type: Any = "beep", _ level: Any = 40, age: Double = 0, to target: String = "4242",
                     id: String = UUID().uuidString) -> PavlokTestRequest? {
            PavlokTestRequest(object: target, userInfo: ["id": id, "type": type, "intensity": level,
                                                         "sent_at": now.timeIntervalSince1970 - age], pid: pid, now: now)
        }
        let ok = request()
        #expect(ok?.modality == .beep && ok?.intensity == 40)
        #expect(request("zap", 40)?.modality == .zap)
        #expect(request("zap", 101) == nil)
        #expect(request("zap", 0) == nil)
        #expect(request("zap", "40") == nil)
        #expect(request(age: 60) == nil)
        #expect(request("invalid") == nil)
        #expect(request(to: "another-process") == nil)
        #expect(request(id: "not-a-uuid") == nil)
    }

    @Test func aCloudAnswerThatIsNotHTTPStillCompletes() async {
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "pavlok-cloud-\(UUID().uuidString).json")
        try? Data("{}".utf8).write(to: file)
        let cloud = PavlokCloud(endpoint: file)
        let result: StimulusResult = await withCheckedContinuation { done in
            cloud.send(.vibe, intensity: 30, reason: "test", token: "t") { done.resume(returning: $0) }
        }
        #expect(!result.delivered)
        #expect(result.transport == .cloud)
        #expect(!result.acknowledged)
    }

    /// The controller with the feature off never touches Bluetooth, so it runs here.
    @Test func everySendLeavesARequestedAndAResultAuditRowButNoTrial() {
        let (logger, path) = scratchLogger()
        let pavlok = PavlokController(settings: CoachSettings(defaults: scratchDefaults()), logger: logger)
        var results: [StimulusResult] = []
        pavlok.send(.beep, intensity: 40, reason: "fixture",
                    context: StimulusContext(sessionId: "call_zoom_x", arm: "pavlok_shock", callApp: "Zoom", manual: false,
                                             operationId: "op-1")) { results.append($0) }
        pavlok.testFire(.vibe, intensity: 25) { results.append($0.result) }
        #expect(results.map(\.detail) == ["Pavlok is disabled in settings", "Bluetooth connection is switched off"])
        #expect(results.allSatisfy { !$0.delivered && $0.transport == .none })
        logger.waitUntilIdle()
        let audit = trialRows(path, type: "pavlok_intervention").map(meta)
        #expect(audit.map { $0["phase"] as? String } == ["requested", "result"])
        #expect(audit.allSatisfy { $0["operation_id"] as? String == "op-1" && $0["intensity_percent"] as? Int == 40 })
        #expect(audit.map { $0["device_acknowledged"] as? Bool } == [false, false])
        #expect(audit.last?["transport"] as? String == "none")
        #expect(trialRows(path).isEmpty)
    }

    @Test func onlyTheWristbandsOwnAckCountsAsAcknowledged() {
        #expect(StimulusResult(delivered: true, transport: .ble, detail: "").acknowledged)
        #expect(!StimulusResult(delivered: true, transport: .cloud, detail: "HTTP 200").acknowledged)
        #expect(!StimulusResult.notSent("off").acknowledged)
    }
}
