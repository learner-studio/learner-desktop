import AppKit
import Foundation
import ServiceManagement
import SQLite3
import CoreBluetooth
import CommonCrypto

// MARK: - Status

/// Everything the tray and the menu show about the app's health. The "Status" job
/// collects it off the main thread every 8 s; the main thread only swaps it in, so
/// opening the menu or redrawing the tray never waits on a socket, a disk or SQLite.
struct AppStatus: Equatable {
    enum Capture: Equatable {
        case unknown, recording
        case degraded(String)
        case stopped(String)
    }
    var capture: Capture = .unknown
    /// Assumed until checked, so a launch does not flash red.
    var serverReachable = true
    var loginItemBlocked = false
    var chatgptChats = 0
    var claudeChats = 0
    var outboxDepth = 0
    var trialCount = 0
    /// Chats the server refused (parked in the archive ledger).
    var archiveParked = 0
    /// Lasting problems from jobs, helpers and the trial database.
    var problems: [Problem] = []

    var chats: Int { chatgptChats + claudeChats }
}

struct Problem: Equatable {
    /// The job or helper it comes from: "Export", "Outbox", "Archive", "Helper:tunnel", "Trials".
    let source: String
    let text: String
}

/// The live speaking-coach numbers the tray shows; read on the main thread, no I/O.
struct CoachLive: Equatable {
    var alert = false
    var warning = false
    var duration = ""
    var call: String?
}

/// What the menu-bar button shows. `kind` changes only when the state does (not every
/// second of a monologue), and each change is logged.
struct TrayState: Equatable {
    let kind: String
    let title: String
    let tooltip: String

    /// Worst first. Problems are tagged by where they come from.
    static func make(_ s: AppStatus, coach: CoachLive) -> TrayState {
        let call = coach.call.map { " [\($0)]" } ?? ""
        if coach.alert {
            return TrayState(kind: "talk-alert", title: "🗣️ 🚨 \(coach.duration)",
                             tooltip: "Talk-time alert: continuous speech for \(coach.duration)\(call)")
        }
        if coach.warning {
            return TrayState(kind: "talk-warning", title: "🗣️ ⚠️ \(coach.duration)",
                             tooltip: "Talk-time warning: continuous speech for \(coach.duration)\(call)")
        }
        if s.loginItemBlocked {
            return TrayState(kind: "login-item", title: "🧠 🔴 LOGIN",
                             tooltip: "Learner Desktop\nSwitched off in Login Items: it will not start at login")
        }
        if let p = s.problems.first(where: { $0.source == "Outbox" }) {
            return TrayState(kind: "outbox", title: "🧠 🔑", tooltip: "Learner Desktop\nTrials are not reaching learner-server: \(p.text)")
        }
        if !s.serverReachable {
            return TrayState(kind: "server", title: "🧠 🔴 ERR", tooltip: "Learner Desktop\nlearner-server unreachable; trials queue locally")
        }
        if case let .stopped(why) = s.capture {
            return TrayState(kind: "screenpipe", title: "🧠 🔴 SP", tooltip: "Learner Desktop\nScreenpipe stopped: \(why)")
        }
        if let p = s.problems.first(where: { $0.source == "Export" }) {
            return TrayState(kind: "export", title: "🧠 🔴 VAULT",
                             tooltip: "Learner Desktop\nChat export: \(p.text)\nOpen the menu for details.")
        }
        if let p = s.problems.first(where: { $0.source == "Trials" }) {
            return TrayState(kind: "trials", title: "🧠 🔴 DB", tooltip: "Learner Desktop\nHabit trials are not being saved: \(p.text)")
        }
        if let p = s.problems.first {
            let tag = p.source == "Archive" ? "SYNC" : p.source.replacingOccurrences(of: "Helper:", with: "").uppercased()
            return TrayState(kind: "problem:\(p.source)", title: "🧠 🔴 \(tag)",
                             tooltip: "Learner Desktop\n\(p.source): \(p.text)\nSee Troubleshooting in the menu.")
        }
        if case let .degraded(why) = s.capture {
            return TrayState(kind: "screenpipe-degraded", title: "🧠 🟡 \(s.chats)", tooltip: "Learner Desktop\nScreenpipe: \(why)")
        }
        if let app = coach.call {
            return TrayState(kind: "call", title: "🗣️ 📞 \(s.chats)", tooltip: "Active call: \(app)\nSpeaking Coach monitoring talk-time limits")
        }
        return TrayState(kind: "ok", title: "🧠 🟢 \(s.chats)", tooltip: "Learner Desktop\nAll systems healthy (\(s.chats) chats vaulted)")
    }
}

// MARK: - Probing

/// Short HTTP checks with a hard timeout, for the status job (blocking; never on main).
enum HTTPProbe {
    struct Response { let status: Int; let data: Data?; let error: String? }

    static func send(_ request: URLRequest) -> Response {
        let done = DispatchSemaphore(value: 0)
        var result = Response(status: 0, data: nil, error: "no response")
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data,
                              error: error?.localizedDescription)
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + request.timeoutInterval + 1) == .timedOut {
            return Response(status: 0, data: nil, error: "timed out")
        }
        return result
    }

    static func get(_ url: String, timeout: TimeInterval = 2) -> Response {
        guard let u = URL(string: url) else { return Response(status: 0, data: nil, error: "bad URL") }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        return send(req)
    }

    static func postJSON(_ url: String, _ body: [String: Any], timeout: TimeInterval = 2) -> Response {
        guard let u = URL(string: url) else { return Response(status: 0, data: nil, error: "bad URL") }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return send(req)
    }
}

/// Collects AppStatus. Every change between two collections is logged under [Status].
enum StatusProbe {
    static let log = Log("Status")
    static var screenpipeURL = "http://localhost:3030"
    static var serverHealthURL = LearnerAPI.baseURL + "/api/health"
    static var vaultRoot = Paths.vault
    static let audioDevices = ["MacBook Pro Microphone (input)", "System Audio (output)"]

    /// Blocking; run by the Status job.
    static func collect(previous: AppStatus, helpers: [ManagedHelper], appAgentPlist: String) -> AppStatus {
        var s = AppStatus()
        s.capture = screenpipe()
        let server = HTTPProbe.get(serverHealthURL)
        s.serverReachable = server.status == 200
        s.loginItemBlocked = SMAppService.statusForLegacyPlist(at: URL(fileURLWithPath: appAgentPlist)) == .requiresApproval
        s.chatgptChats = count("\(vaultRoot)/chatgpt/conversations")
        s.claudeChats = count("\(vaultRoot)/claude/conversations")
        s.outboxDepth = HabitEventLogger.shared.getUnsyncedCount()
        s.trialCount = HabitEventLogger.shared.getTotalTrialCount()
        s.archiveParked = Archive.shared.parkedCount
        s.problems = Job.all.compactMap { j in j.problem.map { Problem(source: j.name, text: $0) } }
            + helpers.compactMap { h in h.problem.map { Problem(source: "Helper:\(h.name)", text: $0) } }
            + (HabitEventLogger.shared.problem.map { [Problem(source: "Trials", text: $0)] } ?? [])
        logChanges(from: previous, to: s, serverError: server.error)
        return s
    }

    private static func count(_ dir: String) -> Int {
        do { return try FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }.count }
        catch { return 0 }
    }

    /// screenpipe's /health. Restarts its audio devices when it reports none active.
    static func screenpipe() -> AppStatus.Capture {
        let r = HTTPProbe.get(screenpipeURL + "/health")
        guard r.status == 200, let data = r.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .stopped(r.status == 0 ? "port 3030 closed" : "health returned \(r.status)")
        }
        if let v = json["version"] as? String { CaptureEnvironment.screenpipeVersion = v }
        if let capture = json["capture_status"] as? [String: Any], capture["active_audio_devices"] as? Int == 0 {
            log.warn("screenpipe reports no active audio devices; starting \(audioDevices.joined(separator: ", "))")
            for device in audioDevices {
                let start = HTTPProbe.postJSON(screenpipeURL + "/audio/device/start", ["device_name": device])
                if start.status != 200 { log.warn("could not start \(device): \(start.error ?? "HTTP \(start.status)")") }
            }
        }
        let status = json["status"] as? String ?? "unknown"
        let frames = json["frame_status"] as? String ?? "unknown"
        let audio = json["audio_status"] as? String ?? "unknown"
        if status == "healthy" || (frames == "ok" && audio == "ok") { return .recording }
        return .degraded("vision \(frames), audio \(audio)")
    }

    static func logChanges(from a: AppStatus, to b: AppStatus, serverError: String?) {
        if a.capture != b.capture { log.info("screenpipe: \(describe(a.capture)) -> \(describe(b.capture))") }
        if a.serverReachable != b.serverReachable {
            if b.serverReachable { log.info("learner-server reachable again") }
            else { log.warn("learner-server unreachable (\(serverError ?? "no detail"))") }
        }
        if a.loginItemBlocked != b.loginItemBlocked {
            if b.loginItemBlocked { log.warn("switched off in Login Items: will not start at login") }
            else { log.info("allowed in Login Items again") }
        }
        for p in b.problems where !a.problems.contains(p) { log.warn("problem: \(p.source): \(p.text)") }
        for p in a.problems where !b.problems.contains(where: { $0.source == p.source }) { log.info("cleared: \(p.source)") }
    }

    static func describe(_ c: AppStatus.Capture) -> String {
        switch c {
        case .unknown: return "unknown"
        case .recording: return "recording"
        case let .degraded(why): return "degraded (\(why))"
        case let .stopped(why): return "stopped (\(why))"
        }
    }
}
