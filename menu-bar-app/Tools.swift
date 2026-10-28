import Foundation

// MARK: - Owner tools (`learner-desktop tool <name> ...`)

// The one-shot maintenance tools that used to be Python and TypeScript scripts. They run
// from the app binary, print to the terminal (not menubar.log) and exit:
//
//   learner-desktop tool start-capture-phase [--dry-run] [--config PATH]
//   learner-desktop tool growthbook-design [--apply]
//   learner-desktop tool vault-report [ROOT]
//   learner-desktop tool preflight [--quiet]
//
// Run them from the repository (paths default relative to it), e.g.
//   swift run LearnerDesktop tool growthbook-design
//   "$HOME/Applications/Learner Desktop.app/Contents/MacOS/learner-desktop" tool start-capture-phase --dry-run

/// Where a tool writes: the terminal by default, a buffer in tests.
// @unchecked: a one-shot CLI tool uses it on the main thread only.
struct ToolIO: @unchecked Sendable {
    var out: (String) -> Void = { s in FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
    var err: (String) -> Void = { s in FileHandle.standardError.write(Data((s + "\n").utf8)) }
    var env: [String: String] = ProcessInfo.processInfo.environment
    var cwd: String = FileManager.default.currentDirectoryPath
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

enum Tools {
    static let usage = """
        usage: learner-desktop tool <name> [options]
          start-capture-phase [--dry-run] [--config PATH]   new experiment phase after a screenpipe version change
          growthbook-design [--apply]                        print (or apply over ssh ovh) the Speaking Coach GrowthBook design
          vault-report [ROOT]                                ai-vault conversation counts (never text)
          preflight [--quiet]                                the capture stack still matches config/screenpipe-settings.json
          speech-selftest                                    start the microphone + Silero as the app does, for 3 s
        """

    /// Dispatches `args` (what follows `tool`) and returns the exit status.
    static func main(_ args: [String], io: ToolIO = ToolIO()) -> Int32 {
        guard let name = args.first else { io.err(usage); return 2 }
        let rest = Array(args.dropFirst())
        do {
            switch name {
            case "start-capture-phase": return try CapturePhase.main(rest, io: io)
            case "growthbook-design": return try GrowthBookDesign.main(rest, io: io)
            case "vault-report": return VaultReport.main(rest, io: io, parse: VaultReport.defaultParser)
            case "preflight": return try Preflight.main(rest, io: io)
            case "speech-selftest": return MainActor.assumeIsolated { SpeechSelfTest.main(io: io) }
            case "-h", "--help", "help": io.out(usage); return 0
            default: io.err("unknown tool: \(name)\n\(usage)"); return 2
            }
        } catch {
            io.err("\(name): \(error)")
            return 1
        }
    }

    /// The repository holding `start` (or one of its parents): the directory with
    /// Package.swift and menu-bar-app/. Tools resolve their default paths against it.
    static func repoRoot(from start: String) -> String? {
        // Resolved, so a path through a symlink (/tmp -> /private/tmp) gives the real root.
        var dir = URL(fileURLWithPath: start).standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<12 {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path),
               fm.fileExists(atPath: dir.appendingPathComponent("menu-bar-app").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// The value after `flag` in `args`, if present.
    static func option(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// POSIX single-quoting, as Python's shlex.quote.
    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: #"[^\w@%+=:,./-]"#, options: .regularExpression) == nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Stable, readable JSON for tool output and export files.
    static func json(_ object: Any, pretty: Bool = true) -> String {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: opts) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One bounded HTTP request; status 0 means no answer at all.
    static func http(_ url: String, method: String = "GET", json body: Any? = nil, headers: [String: String] = [:],
                     timeout: TimeInterval = 10) -> (status: Int, data: Data?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let result = Locked<(Int, Data?)>((0, nil))
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { data, response, _ in
            result.value = ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel() }
        return result.value
    }
}

/// `learner-desktop tool ...` from main.swift.
func runToolCLI(_ args: [String]) -> Int32 { Tools.main(args) }

// MARK: - The OVH box over ssh

/// Runs bash scripts on the OVH box over the `ovh` ssh alias (BatchMode: never prompts),
/// bounded by `timeout`. The script goes to `bash -s` on stdin, as the Python tools did.
struct OVHRemote {
    var ssh = "/usr/bin/ssh"
    var host = "ovh"
    var timeout: TimeInterval = 30
    var log = Log("Tools:ovh")

    static let growthbookMongo = "biztools-growthbook-growthbook-mongo-1"

    func run(_ script: String) throws -> String {
        let dir = NSTemporaryDirectory() + "learner-ssh-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let input = dir + "/script.sh", errors = dir + "/stderr"
        try script.write(toFile: input, atomically: true, encoding: .utf8)
        // One shared connection for a burst of calls (the heavy lane makes about a dozen):
        // the first opens it, the rest reuse it for a minute.
        let control = NSTemporaryDirectory() + "learner-ssh-%C"
        let r = ChildProcess.run("/bin/sh", ["-c", #"exec "$0" -o BatchMode=yes -o ConnectTimeout=8 -o ControlMaster=auto -o "ControlPath=$4" -o ControlPersist=60 "$1" bash -s < "$2" 2> "$3""#,
                                             ssh, host, input, errors, control], timeout: timeout)
        let stderr = (try? String(contentsOfFile: errors, encoding: .utf8)) ?? ""
        guard r.ok else {
            let why = r.stopped ?? "exit \(r.status ?? -1)"
            log.error("ssh to \(host) failed (\(why))")
            throw ToolError("ssh to \(host) failed (\(why)): \(String(stderr.suffix(2000)))")
        }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bash that feeds `js` to mongosh inside the GrowthBook mongo container.
    static func mongoScript(_ js: String, marker: String) -> String {
        let command = #"exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$(cat)""#
        return "set -e\ndocker exec -i \(growthbookMongo) sh -c " + Tools.shellQuote(command)
            + " <<'\(marker)'\n" + js + "\n" + marker + "\n"
    }

    func mongo(_ js: String, marker: String = "COACH_JS") throws -> String {
        try run(OVHRemote.mongoScript(js, marker: marker))
    }

    /// Runs one `sql` statement read-only against the `habits` database. Two guards, since
    /// the statement can come from production data (GrowthBook's stored exposure query):
    /// one statement only (a `;` inside could end the read-only transaction and run more),
    /// and every transaction of the session read-only (default_transaction_read_only).
    func readOnlySQL(_ sql: String) throws -> String {
        let one = try OVHRemote.singleStatement(sql)
        return try run("sudo -u postgres env PGOPTIONS='-c default_transaction_read_only=on' psql -X -qAt -v ON_ERROR_STOP=1 -d habits <<'SQL'\nBEGIN READ ONLY;\n"
                       + one + ";\nROLLBACK;\nSQL\n")
    }

    /// `sql` without a trailing `;`, or an error when it holds more than one statement.
    static func singleStatement(_ sql: String) throws -> String {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !s.isEmpty, !s.contains(";") else { throw ToolError("read-only SQL must be one statement: \(String(s.prefix(200)))") }
        return s
    }

    /// The last line of mongosh output, parsed as a JSON object.
    static func lastJSON(_ output: String) throws -> [String: Any] {
        guard let last = output.split(separator: "\n").last,
              let obj = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
            throw ToolError("unexpected mongosh output: \(String(output.suffix(300)))")
        }
        return obj
    }
}


// MARK: - tool speech-selftest

/// Starts the speech detector exactly as the app does (the real microphone, the real
/// callback on AVAudio's thread, Silero) for 3 s and reports how many frames were scored.
/// The heavy lane runs it from the signed bundle, which shares the app's microphone grant.
@MainActor
enum SpeechSelfTest {
    final class NoSpeech: SpeechSource {
        func poll(now: Date, deliver: @escaping @MainActor ([SpeechSpan]) -> Void) {}
    }

    static func main(io: ToolIO) -> Int32 {
        let source = MicSpeechSource(screenpipe: NoSpeech())
        guard source.start() else {
            io.err("speech-selftest: \(source.problem ?? "could not start")")
            return 2
        }
        // The engine starts on its own queue (a Bluetooth input takes seconds): wait for it.
        let deadline = Date().addingTimeInterval(15)
        while !source.isListening, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard source.isListening else {
            io.err("speech-selftest: \(source.problem ?? "the microphone did not start in 15 s")")
            return 2
        }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let frames = source.framesScored
        source.stop()
        io.out("speech-selftest: \(frames) frames scored in 3 s")
        return frames > 50 ? 0 : 1
    }
}
