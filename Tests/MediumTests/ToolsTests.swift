import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The owner's tools end to end: real child processes (a stub `ssh` that records the
// script it was fed), a stand-in screenpipe, and the built app binary's `tool` dispatch.
// Never the real OVH box, GrowthBook or learner-server.

/// An executable standing in for /usr/bin/ssh: saves its arguments and stdin, prints
/// `reply` and exits with `status`.
private func stubSSH(_ dir: TempDir, reply: String, status: Int = 0) -> String {
    dir.write("ssh", """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(dir.file("ssh.args"))"
        cat > "\(dir.file("ssh.stdin"))"
        cat <<'REPLY'
        \(reply)
        REPLY
        [ \(status) -eq 0 ] || echo "Permission denied (publickey)." >&2
        exit \(status)
        """, executable: true)
}

private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

private let fixtureConfig = """
    {
      "_screenpipe_app_version": "2.7.100",
      "_screenpipe_engine_version": "0.4.40",
      "_captured": "2026-01-01",
      "settings": {}
    }
    """

@Suite("Tools end to end", .tags(.medium, .tools), .timeLimit(.minutes(1)), .quietLog, .serialized) struct ToolsEndToEndTests {

    func phaseFixture(_ dir: TempDir) throws -> (CapturePhase.Options, HTTPStandIn) {
        let screenpipe = try HTTPStandIn { _ in HTTPStandIn.Response.json(200, ["status": "healthy", "version": "0.4.52"]) }
        let plist = dir.file("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.7.125"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: plist))
        var o = CapturePhase.Options(config: dir.write("settings.json", fixtureConfig))
        o.healthURL = screenpipe.baseURL + "/health"
        o.appPlist = plist
        return (o, screenpipe)
    }

    @Test func startCapturePhaseEndsTheGrowthBookPhaseThenRepins() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        var (o, screenpipe) = try phaseFixture(dir)
        defer { screenpipe.stop() }
        o.remote = OVHRemote(ssh: stubSSH(dir, reply: #"{"changed":true,"ended":"old","started":"screenpipe 2.7.125 / engine 0.4.52","phases":3}"#))
        let result = try CapturePhase.run(o)
        #expect(result["phase"] as? String == "screenpipe 2.7.125 / engine 0.4.52")
        #expect((result["growthbook"] as? [String: Any])?["changed"] as? Bool == true)
        #expect((result["config"] as? [String: Any])?["now"] as? String == "2.7.125 / 0.4.52")
        #expect(read(o.config).contains(#""_screenpipe_engine_version": "0.4.52""#))
        // The ssh side: BatchMode to the ovh alias, the phase script on stdin.
        // (and one shared connection for a burst of calls).
        let args = read(dir.file("ssh.args")).components(separatedBy: "\n")
        #expect(Array(args.prefix(6)) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ControlMaster=auto"])
        #expect(args.contains { $0.hasPrefix("ControlPath=") } && args.contains("ControlPersist=60"))
        let host = try #require(args.firstIndex(of: "ovh"))
        #expect(args[host + 1] == "bash" && args[host - 1] == "ControlPersist=60")
        #expect(read(dir.file("ssh.stdin")) == OVHRemote.mongoScript(CapturePhase.phaseJS(name: "screenpipe 2.7.125 / engine 0.4.52", dryRun: false), marker: "PHASE_JS"))
        #expect(screenpipe.requests.map(\.path) == ["/health"])
    }

    @Test func whenGrowthBookIsUnreachableThePinsStayPut() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        var (o, screenpipe) = try phaseFixture(dir)
        defer { screenpipe.stop() }
        o.remote = OVHRemote(ssh: stubSSH(dir, reply: "", status: 255))
        var thrown: Error?
        let lines = capturingLog { do { _ = try CapturePhase.run(o) } catch { thrown = error } }
        #expect("\(thrown.map { "\($0)" } ?? "")".contains("Permission denied"))
        #expect(read(o.config) == fixtureConfig)
        #expect(lines.contains { $0.contains("ERROR [Tools:ovh] ssh to ovh failed") })
    }

    @Test func dryRunChangesNothing() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        var (o, screenpipe) = try phaseFixture(dir)
        defer { screenpipe.stop() }
        o.dryRun = true
        o.remote = OVHRemote(ssh: stubSSH(dir, reply: #"{"changed":false,"wouldEnd":"old","wouldStart":"x","phases":2}"#))
        let result = try CapturePhase.run(o)
        #expect((result["config"] as? [String: Any])?["changed"] as? Bool == false)
        #expect(read(o.config) == fixtureConfig)
        #expect(read(dir.file("ssh.stdin")).contains(#""dryRun":true"#))
    }

    @Test func aScreenpipeThatDoesNotAnswerStopsBeforeGrowthBook() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        var (o, screenpipe) = try phaseFixture(dir)
        screenpipe.stop()
        o.healthURL = "http://127.0.0.1:9/health"
        o.remote = OVHRemote(ssh: stubSSH(dir, reply: "{}"))
        #expect(throws: ToolError.self) { try CapturePhase.run(o) }
        #expect(!FileManager.default.fileExists(atPath: dir.file("ssh.stdin")))
    }

    @Test func sshThatHangsIsStoppedAtItsTimeout() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let ssh = dir.write("ssh", "#!/bin/sh\nsleep 30\n", executable: true)
        let started = Date()
        #expect(throws: ToolError.self) { try OVHRemote(ssh: ssh, timeout: 1).run("true") }
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func growthBookApplySendsTheWholeDesignOverSSH() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let p = Printed()
        let remote = OVHRemote(ssh: stubSSH(dir, reply: #"{"experiment":"exp_speech_coach_settings_v1"}"#), timeout: 60)
        #expect(try GrowthBookDesign.main(["--apply"], io: toolIO(p), remote: remote) == 0)
        #expect(read(dir.file("ssh.stdin")) == OVHRemote.mongoScript(GrowthBookDesign.applyJS, marker: "COACH_JS"))
        #expect(p.stdout.contains("exp_speech_coach_settings_v1"))
    }

    // MARK: The app binary


    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: appBinary), "build the app first (swift build)"))
    func theAppBinaryDispatchesToolsAndExits() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let design = ChildProcess.run(appBinary, ["tool", "growthbook-design"], timeout: 30, env: appEnv())
        #expect(design.status == 0)
        let shown = try #require(try JSONSerialization.jsonObject(with: Data(design.output.utf8)) as? [String: String])
        #expect(shown["fact_sql"] == GrowthBookDesign.sql)

        dir.write("vault/chatgpt/conversations/c1/conversation.md",
                  "# Chat\n**Created:** 2026-02-01T10:00:00Z\n\n---\n\n## User\n\nprivate words\n\n---\n\n## Assistant\n\nmore private words\n")
        let report = ChildProcess.run(appBinary, ["tool", "vault-report", dir.file("vault")], timeout: 30, env: appEnv())
        #expect(report.status == 0 && report.output.contains("messages: total=2 user=1 assistant=1"))
        #expect(!report.output.contains("private words"))

        let unknown = ChildProcess.run(appBinary, ["tool", "nope"], timeout: 30, env: appEnv(), stderr: true)
        #expect(unknown.status == 2 && unknown.output.contains("unknown tool"))
    }
}

private func toolIO(_ p: Printed) -> ToolIO { ToolIO(out: p.out, err: p.err, env: [:], cwd: NSTemporaryDirectory()) }
