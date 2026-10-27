import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

// The deployed Speaking Coach GrowthBook design, READ-ONLY over the `ovh` ssh alias:
// mongosh reads the GrowthBook documents, and the exposure query runs inside
// `BEGIN READ ONLY ... ROLLBACK` against a fictional row built in the query itself
// (json_populate_recordset), so no table is read or written.
// Needs LEARNER_HEAVY=1 and LEARNER_REMOTE_E2E=1.

@Suite("GrowthBook design on the server (read-only)", .serialized,
       .enabled(if: Live.remote, "remote opt-in: set LEARNER_HEAVY=1 LEARNER_REMOTE_E2E=1"))
struct GrowthBookRemoteTests {
    let remote = OVHRemote(timeout: 60)

    func deployed() throws -> [String: Any] {
        try OVHRemote.lastJSON(try remote.mongo(GrowthBookDesign.deployedStateJS))
    }

    @Test func deployedVariablesMetricsAndVariationsMatchTheDesign() throws {
        let s = try deployed()
        let fact = try #require(s["fact"] as? [String: Any], "fact table \(GrowthBookDesign.fact) not deployed")
        let exposure = try #require(s["exposure"] as? [String: Any])
        let exp = try #require(s["experiment"] as? [String: Any])
        #expect(fact["sql"] as? String == GrowthBookDesign.sql)
        #expect(exposure["query"] as? String == GrowthBookDesign.exposureSQL)
        #expect(Set(GrowthBookDesign.dimensions).isSubset(of: Set(exposure["dimensions"] as? [String] ?? [])))
        #expect((exp["variations"] as? [[String: Any]])?.map { $0["key"] as? String } == GrowthBookDesign.variations)
        #expect(exp["exposureQueryId"] as? String == GrowthBookDesign.exposure)
        let ids = Set((s["metrics"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let used = (exp["goalMetrics"] as? [String] ?? []) + (exp["secondaryMetrics"] as? [String] ?? [])
        #expect(Set(used).isSubset(of: ids))
    }

    /// A fictional turn that should enter the experiment, as a habit_events row.
    static func row(settings: [String: Any] = [:], metadata: [String: Any] = [:]) -> [String: Any] {
        var ts: [String: Any] = ["cue_30": "toast_only", "cue_60": "toast_only", "reward_enabled": true, "wearable_enabled": false,
                                 "warning_shock_percent": 0, "warning_vibe_percent": 0, "warning_beep_enabled": false,
                                 "hard_stop_shock_percent": 0, "hard_stop_vibe_percent": 0, "reward_vibe_percent": 30,
                                 "assignment_mode": "cluster_randomized"]
        ts.merge(settings) { $1 }
        var m: [String: Any] = ["design_version": "speech_coach_settings_v1", "timing_version": "confirmed_speech_span_v1",
                                "simulated": false, "experiment_eligible": true, "settings_changed_during_turn": false,
                                "data_quality": "ok", "treatment_settings": ts]
        m.merge(metadata) { $1 }
        return ["session_id": "fixture-meeting-1", "habit_type": "monologue_streak", "call_category": "work",
                "timestamp": "2026-10-01T10:00:00Z", "treatment_arm": "baseline", "turn_duration_sec": 12,
                "metadata": m]
    }

    static let cases: [String: ([String: Any], Int)] = [
        "reward with toast only": (row(), 1),
        "reward off": (row(settings: ["reward_enabled": false]), 1),
        "manual override": (row(settings: ["assignment_mode": "baseline"]), 0),
        "synthetic": (row(metadata: ["simulated": true]), 0),
        "legacy design": (row(metadata: ["design_version": "legacy"]), 0),
        "settings changed mid-turn": (row(metadata: ["settings_changed_during_turn": true]), 0),
    ]

    @Test(arguments: ["reward with toast only", "reward off", "manual override", "synthetic", "legacy design", "settings changed mid-turn"])
    func exposureEligibility(_ name: String) throws {
        let (row, want) = Self.cases[name]!
        let s = try deployed()
        let query = try #require((s["exposure"] as? [String: Any])?["query"] as? String)
        let literal = Tools.json([row], pretty: false).replacingOccurrences(of: "'", with: "''")
        let sql = "WITH habit_events AS (SELECT * FROM json_populate_recordset(NULL::public.habit_events,'\(literal)'::json)) "
            + "SELECT json_build_object('count',count(*),'cue_60',max(cue_60),'reward_enabled',max(reward_enabled)) FROM (\(query)) e;"
        let out = try remote.readOnlySQL(sql)
        let got = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], "\(name): \(out)")
        #expect(got["count"] as? Int == want, "\(name)")
        if want > 0 {
            #expect(got["cue_60"] as? String == "toast_only")
            #expect(got["reward_enabled"] as? String == (name == "reward off" ? "false" : "true"))
        }
    }
}
