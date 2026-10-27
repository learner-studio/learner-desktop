import Foundation

// MARK: - tool preflight

/// Verifies the capture stack still measures what the experiment assumes. The settings it
/// depends on can revert silently: TranscriptionMode::Batch is screenpipe's #[default], so
/// a reset, migration or reinstall reintroduces up to 2 minutes of deferred transcription
/// (what corrupted the 2026-09-08 data). Live state is checked against
/// config/screenpipe-settings.json, so a deliberate change is recorded in git.
///
/// Exit: 0 all good, 1 drift, 2 screenpipe unreachable.
/// Env: PREFLIGHT_EXPECTED (expectations file), SCREENPIPE_API, SCREENPIPE_APP, HOME.
enum Preflight {
    static let redacted = "***REDACTED***"

    static func main(_ args: [String], io: ToolIO) throws -> Int32 {
        var quiet = false
        for a in args {
            switch a {
            case "--quiet": quiet = true
            case "-h", "--help": io.out("usage: learner-desktop tool preflight [--quiet]"); return 0
            default: io.err("unknown option: \(a)"); return 2
            }
        }
        let repo = Tools.repoRoot(from: io.cwd) ?? io.cwd
        let expected = io.env["PREFLIGHT_EXPECTED"] ?? repo + "/config/screenpipe-settings.json"
        let store = (io.env["HOME"] ?? NSHomeDirectory()) + "/.screenpipe/store.bin"
        let api = io.env["SCREENPIPE_API"] ?? "http://localhost:3030"
        let app = io.env["SCREENPIPE_APP"] ?? "/Applications/screenpipe.app"

        var problems = 0
        let ok = { (s: String) in if !quiet { io.out("    ✓ \(s)") } }
        let bad = { (s: String) in io.out("    ✗ \(s)"); problems += 1 }
        let say = { (s: String) in if !quiet { io.out("\n==> \(s)") } }

        say("Capture settings")
        let want = (readJSON(expected)?["settings"] as? [String: Any])
        if !FileManager.default.fileExists(atPath: store) {
            bad("screenpipe settings not found at \(store)")
        } else if let want = want {
            if let live = readJSON(store)?["settings"] as? [String: Any] {
                for key in want.keys.sorted() {
                    let w = want[key]!
                    if let s = w as? String, s == redacted { continue }
                    let got = live[key]
                    if let got = got, equal(got, w) { ok("\(key) = \(render(got))") }
                    else { bad("\(key): expected \(render(w)), found \(got.map(render) ?? "\"<missing>\"")") }
                }
            } else {
                bad("store.bin: unreadable")
            }
        } else {
            bad("expectations: unreadable (\(expected))")
        }

        say("Live pipeline")
        let health = HTTPProbe.get(api + "/health", timeout: 5)
        guard health.status != 0, let h = health.data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            bad("screenpipe is not answering on \(api) — nothing is being captured")
            say("Result")
            io.out("    \(problems) problem(s); capture stack is NOT ready")
            return 2
        }
        let version = h["version"] as? String ?? ""
        let status = h["status"] as? String ?? ""
        let pins = readJSON(expected)
        let pinnedEngine = pins?["_screenpipe_engine_version"] as? String ?? ""
        let pinnedApp = pins?["_screenpipe_app_version"] as? String ?? ""
        let appVersion = (NSDictionary(contentsOfFile: app + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String) ?? ""
        // A version change is a change of measuring instrument: a phase boundary.
        if !pinnedEngine.isEmpty && version != pinnedEngine {
            bad("screenpipe engine version changed: pinned \(pinnedEngine), running \(version.isEmpty ? "unknown" : version) — treat as a phase boundary")
        } else {
            ok("screenpipe engine version \(version) (pinned; stamped onto every turn as metadata.screenpipe_version)")
        }
        if !pinnedApp.isEmpty && !appVersion.isEmpty && appVersion != pinnedApp {
            bad("screenpipe app version changed: pinned \(pinnedApp), installed \(appVersion) — treat as a phase boundary")
        } else if !appVersion.isEmpty {
            ok("screenpipe app version \(appVersion) (pinned)")
        }
        if status == "healthy" { ok("health: \(status)") } else { bad("health: \(status.isEmpty ? "unknown" : status)") }

        // The coach polls these exact columns; a changed shape stops turn logging silently.
        let query = "SELECT t.id, t.audio_chunk_id, t.transcription, t.timestamp, t.start_time, t.end_time, c.file_path FROM audio_transcriptions t JOIN audio_chunks c ON t.audio_chunk_id=c.id ORDER BY t.id DESC LIMIT 1;"
        let rows = HTTPProbe.postJSON(api + "/raw_sql", ["query": query], timeout: 6)
        let text = rows.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if text.contains("\"error\"") { bad("the /raw_sql shape the app polls no longer works: \(text.prefix(160))") }
        else if text.contains("\"start_time\"") { ok("/raw_sql still returns the columns the app polls") }
        else if text.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" { if !quiet { io.out("    ! /raw_sql works but returned no rows yet (nothing transcribed since start)") } }
        else { bad("unexpected /raw_sql response: \(text.prefix(160))") }

        say("Result")
        if problems == 0 {
            if !quiet { io.out("    capture stack matches the experiment's assumptions") }
            return 0
        }
        io.out("    \(problems) problem(s) — turn timing may not mean what the experiment assumes")
        return 1
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// JSON equality (numbers by value, so 1 == 1.0 like Python's ==). In an expected array,
    /// a redacted entry (a device named after the owner, say) matches any one live entry:
    /// the other entries must all be present and the counts must agree.
    static func equal(_ live: Any, _ want: Any) -> Bool {
        if let w = want as? [Any], let l = live as? [Any], w.contains(where: { ($0 as? String) == redacted }) {
            let named = w.filter { ($0 as? String) != redacted }
            return l.count == w.count && named.allSatisfy { n in l.contains { equal($0, n) } }
        }
        return (live as AnyObject).isEqual(want)
    }

    static func render(_ v: Any) -> String {
        if let s = v as? String { return "\"\(s)\"" }
        if JSONSerialization.isValidJSONObject([v]),
           let d = try? JSONSerialization.data(withJSONObject: [v], options: [.sortedKeys, .fragmentsAllowed]) {
            return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
        }
        return "\(v)"
    }
}
