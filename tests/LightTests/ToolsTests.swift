import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// `learner-desktop tool ...`: the owner's one-shot tools (Tools*.swift), on fixtures only.
// Every name, title and transcript here is fictional.

func toolIO(_ p: Printed, env: [String: String] = [:], cwd: String = NSTemporaryDirectory()) -> ToolIO {
    ToolIO(out: p.out, err: p.err, env: env, cwd: cwd)
}

@Suite("Tools: shared helpers") struct ToolsHelperTests {
    @Test func shellQuoteMatchesShlex() {
        #expect(Tools.shellQuote("plain-word") == "plain-word")
        #expect(Tools.shellQuote(#"it's "x""#) == #"'it'"'"'s "x"'"#)
    }

    @Test func unknownToolExitsTwoWithUsage() {
        let p = Printed()
        #expect(Tools.main(["nope"], io: toolIO(p)) == 2)
        #expect(p.stderr.contains("unknown tool") && p.stderr.contains("start-capture-phase"))
        #expect(Tools.main([], io: toolIO(p)) == 2)
    }

    @Test func repoRootIsFoundFromASubdirectory() {
        let root = toolsRepoRoot()
        #expect(Tools.repoRoot(from: root + "/menu-bar-app") == root)
        #expect(Tools.repoRoot(from: "/") == nil)
    }
}

@Suite("Tools: GrowthBook design") struct GrowthBookDesignTests {
    @Test func factSQLSelectsEveryDimensionFromTheTreatmentSettings() {
        for d in GrowthBookDesign.dimensions { #expect(GrowthBookDesign.sql.contains(" cfg->>'\(d)' AS \(d)")) }
        #expect(GrowthBookDesign.sql.hasPrefix("WITH tagged AS (\n SELECT *, metadata->'treatment_settings' AS cfg FROM habit_events\n"))
        #expect(GrowthBookDesign.sql.hasSuffix("WHERE COALESCE(metadata->>'data_quality','unknown')='ok'\n"))
        // Only versioned, real, eligible, stable sessions enter.
        for rule in ["metadata->>'design_version'='speech_coach_settings_v1'", "metadata->>'simulated'='false'",
                     "session_id NOT LIKE 'session-%'", "HAVING count(DISTINCT cfg::text)=1"] {
            #expect(GrowthBookDesign.sql.contains(rule))
        }
    }

    @Test func exposureSQLWrapsTheFactSQLAndKeepsOnlyRandomizedSessions() {
        let e = GrowthBookDesign.exposureSQL
        #expect(e.hasPrefix("SELECT session_id,treatment_arm AS variation_id,timestamp,habit_type AS experiment_id,call_category,cue_30,cue_60,"))
        #expect(e.contains(" FROM (" + GrowthBookDesign.sql + ") f "))
        #expect(e.hasSuffix("WHERE assignment_mode='cluster_randomized'"))
    }

    @Test func applyScriptCarriesTheDesignAsItsPayloadAndRunsInTheMongoContainer() throws {
        let script = OVHRemote.mongoScript(GrowthBookDesign.applyJS, marker: "COACH_JS")
        #expect(script.hasPrefix("set -e\ndocker exec -i biztools-growthbook-growthbook-mongo-1 sh -c 'exec mongosh --quiet --username \"$MONGO_INITDB_ROOT_USERNAME\""))
        #expect(script.contains(" --eval \"$(cat)\"' <<'COACH_JS'\nconst p={"))
        #expect(script.hasSuffix("legacyStatus:\"stopped\"}));\n\nCOACH_JS\n"))
        let payloadLine = GrowthBookDesign.applyJS.components(separatedBy: "\n")[0]
        let json = String(payloadLine.dropFirst("const p=".count).dropLast())
        let p = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(p["sql"] as? String == GrowthBookDesign.sql)
        #expect(p["exposureSQL"] as? String == GrowthBookDesign.exposureSQL)
        #expect(p["dimensions"] as? [String] == GrowthBookDesign.dimensions)
        #expect(p["description"] as? String == GrowthBookDesign.description)
        #expect(p["experiment"] as? String == "exp_speech_coach_settings_v1")
        // It refuses to apply twice and backs up before mutating.
        let js = GrowthBookDesign.applyJS
        let refuse = try #require(js.range(of: "Revision exists"))
        let backup = try #require(js.range(of: "codex_configuration_backups.insertOne"))
        let firstWrite = try #require(js.range(of: "g.facttables.insertOne"))
        #expect(refuse.lowerBound < backup.lowerBound && backup.lowerBound < firstWrite.lowerBound)
    }

    @Test func printModeShowsTheDesignAndTouchesNothing() throws {
        let p = Printed()
        let remote = OVHRemote(ssh: "/nonexistent/ssh")
        #expect(try GrowthBookDesign.main([], io: toolIO(p), remote: remote) == 0)
        let shown = try #require(try JSONSerialization.jsonObject(with: Data(p.stdout.utf8)) as? [String: String])
        #expect(shown == ["fact_sql": GrowthBookDesign.sql, "exposure_sql": GrowthBookDesign.exposureSQL,
                          "description": GrowthBookDesign.description])
    }
}

@Suite("Tools: start-capture-phase") struct CapturePhaseTests {
    static let config = """
        {
          "_comment": "fixture",
          "_screenpipe_app_version": "2.7.100",
          "_screenpipe_engine_version": "0.4.40",
          "_captured": "2026-01-01",
          "settings": {"transcriptionMode": "realtime"}
        }
        """

    @Test func phaseNameIsTheOneTheAppStampsOnTurns() {
        #expect(CapturePhase.phaseName(app: "2.7.125", engine: "0.4.52") == "screenpipe 2.7.125 / engine 0.4.52")
    }

    @Test func phaseScriptEndsTheLastPhaseOnlyWhenTheNameChangesAndBacksUpFirst() throws {
        let js = CapturePhase.phaseJS(name: "screenpipe 1 / engine 2", dryRun: true)
        let first = js.components(separatedBy: "\n")[0]
        let p = try #require(try JSONSerialization.jsonObject(with: Data(first.dropFirst(8).dropLast().utf8)) as? [String: Any])
        #expect(p["experiment"] as? String == "exp_speech_coach_settings_v1")
        #expect(p["name"] as? String == "screenpipe 1 / engine 2")
        #expect(p["dryRun"] as? Bool == true)
        #expect(js.contains("if(last.name===p.name)"))
        let backup = try #require(js.range(of: "codex_configuration_backups.insertOne"))
        let update = try #require(js.range(of: "g.experiments.updateOne"))
        #expect(backup.lowerBound < update.lowerBound)
    }

    @Test func repinRewritesOnlyThePinsAndTheCaptureDate() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.write("settings.json", Self.config)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        let r = try CapturePhase.repin(app: "2.7.125", engine: "0.4.52", dryRun: false, configPath: path, today: day)
        #expect(r["changed"] as? Bool == true)
        #expect(r["was"] as? String == "2.7.100 / 0.4.40" && r["now"] as? String == "2.7.125 / 0.4.52")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text == Self.config.replacingOccurrences(of: "2.7.100", with: "2.7.125")
            .replacingOccurrences(of: "0.4.40", with: "0.4.52").replacingOccurrences(of: "2026-01-01", with: "2026-10-27"))
        // The same versions again: nothing to do.
        let again = try CapturePhase.repin(app: "2.7.125", engine: "0.4.52", dryRun: false, configPath: path, today: day)
        #expect(again["changed"] as? Bool == false && again["pinned"] as? String == "2.7.125 / 0.4.52")
    }

    @Test func dryRunRepinReportsButDoesNotWrite() throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = dir.write("settings.json", Self.config)
        let r = try CapturePhase.repin(app: "9.9.9", engine: "1.0.0", dryRun: true, configPath: path, today: Date())
        #expect(r["changed"] as? Bool == false && r["now"] as? String == "9.9.9 / 1.0.0")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == Self.config)
    }

    @Test func aMissingConfigIsAUsageErrorNotACrash() throws {
        let p = Printed()
        #expect(try CapturePhase.main(["--config", "/nonexistent/settings.json"], io: toolIO(p)) == 2)
        #expect(p.stderr.contains("not found"))
    }
}

// MARK: - Vault report

@Suite("Tools: vault-report") struct VaultReportTests {
    static let secret = "SECRET-CONVERSATION-TEXT"

    static func conversation(messages: Int, created: Bool = true) -> String {
        var s = "# A fictional chat\n\n" + (created ? "**Created:** 2026-02-01T10:00:00Z\n" : "") + "**Messages:** \(messages)\n"
        for i in 0..<messages {
            s += "\n---\n\n## \(i % 2 == 0 ? "User" : "Assistant")\n\n\(secret) number \(i)\n"
        }
        return s + "\n---\n\n## User\n\n**Attachments:**\n- picture.png\n"
    }

    @Test func countsMessagesAndFlagsProblemsButNeverPrintsText() {
        let dir = TempDir()
        defer { dir.cleanup() }
        dir.write("chatgpt/conversations/c1/conversation.md", Self.conversation(messages: 3))
        dir.write("claude/conversations/c2/conversation.md", Self.conversation(messages: 2, created: false))
        dir.write("gemini/conversations/c3/notes.md", "ignored")
        let p = Printed()
        let status = VaultReport.report(root: dir.path, io: toolIO(p), parse: VaultReport.defaultParser)
        #expect(status == 1)   // c2 has no timestamp
        #expect(p.stdout.contains("chatgpt\tc1\t3\t2\t1\t1\tvalid,flagged"))
        #expect(p.stdout.contains("claude\tc2\t2\t1\t1\t1\tINVALID"))
        #expect(p.stdout.contains("files: 2 (chatgpt=1, claude=1)"))
        #expect(p.stdout.contains("messages: total=5 user=3 assistant=2"))
        #expect(p.stdout.contains("skipped messages: 2 (attachment-only=2)"))
        #expect(p.stdout.contains("header-count-mismatch:3!=4"))
        #expect(p.stdout.contains("no-timestamp"))
        #expect(!p.stdout.contains(Self.secret) && !p.stderr.contains(Self.secret))
    }

    @Test func theParserIsAParameter() {
        let dir = TempDir()
        defer { dir.cleanup() }
        dir.write("chatgpt/conversations/c1/conversation.md", "x")
        let p = Printed()
        let status = VaultReport.report(root: dir.path, io: toolIO(p)) { path in
            VaultReport.Summary(provider: "chatgpt", conversationId: "c1", valid: true, messages: 7, user: 4, assistant: 3)
        }
        #expect(status == 0)
        #expect(p.stdout.contains("messages: total=7 user=4 assistant=3"))
    }
}

// MARK: - Policy

@Suite("Tools: retired routes") struct ToolsPolicyTests {
    /// The app used to write habit rows straight into Postgres over an SSH tunnel
    /// (:15432, a habits_writer role) and conversations into Hindsight (:18925). Since
    /// 2026-10-22 everything goes through learner-server's HTTPS RPC API.
    @Test func noSwiftSourceUsesTheOldTunnelDatabaseRoute() throws {
        let dir = toolsRepoRoot() + "/menu-bar-app"
        let forbidden = #"15432|18925|HABITS_PG_URL|HINDSIGHT_URL|HINDSIGHT_BANK|postgres://|habits_writer|sync-habits|hindsight-client"#
        var hits: [String] = []
        for f in try FileManager.default.contentsOfDirectory(atPath: dir) where f.hasSuffix(".swift") {
            let text = try String(contentsOfFile: dir + "/" + f, encoding: .utf8)
            for (n, l) in text.components(separatedBy: "\n").enumerated() where l.range(of: forbidden, options: .regularExpression) != nil {
                hits.append("\(f):\(n + 1)")
            }
        }
        #expect(hits.isEmpty, "old SSH-tunnel route referenced: \(hits)")
    }
}
