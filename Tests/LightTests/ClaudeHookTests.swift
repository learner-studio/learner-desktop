import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The Claude Code hook job's pure parts: what it asks learner-server's installer to do, and
// what the installer's --check report means for the tray.
@Suite("Claude Code hook", .tags(.light, .sessions), .timeLimit(.minutes(1)), .quietLog) struct ClaudeHookTests {
    @Test func theInstallerIsToldHowToReadTheKeyNeverTheKey() throws {
        let args = ClaudeHook.installArguments(installer: "/r/clients/hook/src/install.ts", bun: "/h/.bun/bin/bun",
                                               serverURL: "https://learner.example/learner-api", clientId: "a-mac")
        #expect(args.prefix(5) == ["/r/clients/hook/src/install.ts", "--bun", "/h/.bun/bin/bun", "--server-url", "https://learner.example/learner-api"])
        #expect(args[5] == "--key-command-json" && args.count == 7)
        let command = try #require(try? JSONSerialization.jsonObject(with: Data(args[6].utf8)) as? [String])
        #expect(command == ["/usr/bin/security", "find-generic-password", "-s", "learner-server", "-a", "a-mac", "-w"])
        // The same lookup the app itself uses for its own calls.
        #expect(command == ClaudeHook.keyCommand(clientId: "a-mac"))
        #expect(!args[6].contains("\\"), "plain slashes, as a person would write it")
        let more = ClaudeHook.installArguments(installer: "i", bun: "b", serverURL: "u", clientId: "c", catalogParts: 7)
        #expect(more.suffix(2) == ["--catalog-parts", "7"])
    }

    @Test func theCheckReportIsTheLastJSONLine() throws {
        let text = """
            bun: a notice that is not the report
            {"ok":true,"settings":"/h/.claude/settings.json","events":{"Stop":true},"catalogParts":5,"installed":true,"permissions":true,"config":"ok","server":"ok","catalogPartsNeeded":5}

            """
        let c = try #require(ClaudeHook.parseCheck(text))
        #expect(c == ClaudeHook.Check(ok: true, installed: true, permissions: true, config: "ok", server: "ok", catalogParts: 5, catalogPartsNeeded: 5))
        #expect(ClaudeHook.parseCheck("not json\n{\"installed\":true}\n") == nil, "an install report is not a check report")
        #expect(ClaudeHook.parseCheck("") == nil)
    }

    @Test func eachReportBecomesTheRightOutcome() {
        func outcome(_ change: (inout ClaudeHook.Check) -> Void) -> String {
            var c = ClaudeHook.Check(ok: false, installed: true, permissions: true, config: "ok", server: "ok", catalogParts: 5, catalogPartsNeeded: 5)
            change(&c)
            return describe(ClaudeHook.outcome(c))
        }
        #expect(outcome { $0.ok = true } == "ok: wired into Claude Code (5 catalog parts)")
        // Needs the owner: blocked, not retried in a loop.
        #expect(outcome { $0.server = "refused (HTTP 403)" }.hasPrefix("blocked: learner-server refused the device key"))
        #expect(outcome { $0.server = "no credential" }.hasPrefix("blocked: the Claude Code hook cannot read the device key"))
        // Passing trouble: retried.
        #expect(outcome { $0.server = "unreachable" } == "failed: the Claude Code hook cannot reach learner-server (unreachable)")
        #expect(outcome { $0.server = "error (HTTP 500)" }.hasPrefix("failed: the Claude Code hook cannot reach learner-server"))
        #expect(outcome { $0.installed = false }.hasPrefix("failed: the hook is not fully wired"))
        #expect(outcome { $0.permissions = false }.hasPrefix("failed: the hook is not fully wired"))
        #expect(outcome { $0.config = "invalid" }.contains("learning-hook.json) is invalid"))
        #expect(outcome { $0.catalogPartsNeeded = 9 } == "failed: the hook carries 5 catalog parts; the server needs 9")
        #expect(describe(ClaudeHook.outcome(nil)) == "failed: the hook check printed no report")
    }
}
