import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The Claude Code hook job with a stand-in bun (a shell script that records what it was
// asked and answers like learner-server's installer): when it runs the installer, what it
// passes, and what each answer does to the job.
private final class HookFixture {
    static let wired = #"{"ok":true,"installed":true,"permissions":true,"config":"ok","server":"ok","catalogParts":5,"catalogPartsNeeded":5}"#
    let dir = TempDir("claude-hook")
    let name = "test-claude-hook-\(UUID().uuidString.prefix(8))"
    let hook: ClaudeHook

    /// `checks`: what successive --check runs print, the last one repeating.
    init(checkout: Bool = true, installer: Bool = true, paired: Bool = true, installExit: Int = 0, checks: [String] = [HookFixture.wired]) {
        if checkout { dir.write("repo/clients/uploader/src/index.ts", "") }
        if installer { dir.write("repo/clients/hook/src/install.ts", "") }
        for (n, text) in checks.enumerated() { dir.write("check.\(n)", text + "\n") }
        let bun = dir.write("bin/bun", """
            #!/bin/bash
            here="\(dir.path)"
            printf '%s\\n' "$*" >> "$here/calls"
            env | grep -c '^LEARNER_API_KEY=' >> "$here/key-in-env"
            case "$*" in
              *--check*)
                n=$(cat "$here/checked" 2>/dev/null || echo 0)
                echo $((n + 1)) > "$here/checked"
                [ -f "$here/check.$n" ] || n=\(checks.count - 1)
                cat "$here/check.$n" ;;
              *) echo '{"installed":true}'; echo "learner hook install failed: settings are not a JSON object" >&2; exit \(installExit) ;;
            esac
            """, executable: true)
        var c = ClaudeHook.Config()
        c.jobName = name
        c.repo = dir.file("repo")
        c.bun = bun
        c.git = "/usr/bin/false"
        c.serverURL = { "https://learner.example/learner-api" }
        c.clientId = { "a-mac" }
        c.paired = { paired }
        c.timeout = 20
        c.updateCheckout = false
        hook = ClaudeHook(config: c)
    }

    deinit { try? FileManager.default.removeItem(atPath: Job.stateDir + "/\(name).json") }

    var calls: [String] { dir.read("calls").split(separator: "\n").map(String.init) }
}

@Suite("Claude Code hook job (stand-in bun, real processes)", .tags(.medium, .sessions), .quietLog, .serialized, .timeLimit(.minutes(1))) struct ClaudeHookJobTests {
    @Test func itInstallsThenChecksAndNamesOnlyTheKeychainLookup() {
        let f = HookFixture()
        #expect(describe(f.hook.runOnce()) == "ok: wired into Claude Code (5 catalog parts)")
        #expect(f.calls.count == 2)
        let install = f.calls.first ?? ""
        #expect(install.hasPrefix(f.dir.file("repo/clients/hook/src/install.ts") + " --bun " + f.dir.file("bin/bun") + " --server-url https://learner.example/learner-api --key-command-json "))
        #expect(install.contains(#"["/usr/bin/security","find-generic-password","-s","learner-server","-a","a-mac","-w"]"#))
        #expect(f.calls.last == f.dir.file("repo/clients/hook/src/install.ts") + " --check")
    }

    @Test func nothingRunsWithoutACheckoutOrAPairing() {
        let none = HookFixture(checkout: false, installer: false)
        #expect(describe(none.hook.runOnce()) == "idle")
        let unpaired = HookFixture(paired: false)
        #expect(describe(unpaired.hook.runOnce()) == "idle")
        #expect(none.calls.isEmpty && unpaired.calls.isEmpty)
    }

    @Test func aCheckoutFromBeforeTheInstallerIsBlockedWithWhatToDo() {
        let f = HookFixture(installer: false)
        let said = describe(f.hook.runOnce())
        #expect(said.hasPrefix("blocked: the learner-server checkout") && said.hasSuffix("update it with git pull"))
        #expect(f.calls.isEmpty)
    }

    @Test func aFailedInstallIsRetriedAndSaysWhy() {
        let f = HookFixture(installExit: 1)
        #expect(describe(f.hook.runOnce()) == "failed: the hook installer failed: learner hook install failed: settings are not a JSON object")
        #expect(f.calls.count == 1, "no check after a failed install")
    }

    @Test func aRefusedKeyBlocksAndAnUnreachableServerIsRetried() {
        let refused = HookFixture(checks: [#"{"ok":false,"installed":true,"permissions":true,"config":"ok","server":"refused (HTTP 403)","catalogParts":5}"#])
        #expect(describe(refused.hook.runOnce()).hasPrefix("blocked: learner-server refused the device key"))
        let down = HookFixture(checks: [#"{"ok":false,"installed":true,"permissions":true,"config":"ok","server":"unreachable","catalogParts":5}"#])
        #expect(describe(down.hook.runOnce()).hasPrefix("failed: the Claude Code hook cannot reach learner-server"))
    }

    @Test func aBiggerCatalogGetsAsManyCompanionsAsItNeeds() {
        let f = HookFixture(checks: [
            #"{"ok":false,"installed":true,"permissions":true,"config":"ok","server":"ok","catalogParts":5,"catalogPartsNeeded":7}"#,
            #"{"ok":true,"installed":true,"permissions":true,"config":"ok","server":"ok","catalogParts":7,"catalogPartsNeeded":7}"#,
        ])
        #expect(describe(f.hook.runOnce()) == "ok: wired into Claude Code (7 catalog parts)")
        #expect(f.calls.count == 4)
        #expect(f.calls[2].hasSuffix(" --catalog-parts 7"))
    }

    @Test func theInstallerNeverGetsTheKeyInItsEnvironment() {
        let f = HookFixture()
        _ = f.hook.runOnce()
        // Unless the test process itself was started with one (it is not, in any lane).
        let leaked = f.dir.read("key-in-env").split(separator: "\n").contains { $0 != "0" }
        #expect(leaked == (ProcessInfo.processInfo.environment["LEARNER_API_KEY"] != nil))
    }
}
