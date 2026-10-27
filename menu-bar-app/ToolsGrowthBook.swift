import Foundation

// MARK: - tool growthbook-design

/// The versioned Speaking Coach design for self-hosted GrowthBook: a fact table over
/// habit_events, an exposure query, metrics and the experiment. `--apply` writes it over
/// the `ovh` ssh alias (mongosh in the GrowthBook container), preserving the legacy
/// definitions and results and backing up affected documents first; without it the
/// design is only printed. The deployed fact SQL must stay byte-identical to `sql`
/// (the heavy GrowthBookDesign test checks it).
enum GrowthBookDesign {
    static let fact = "ftb_speech_coach_settings_v1"
    static let exposure = "ex_speech_coach_settings_v1"
    static let experiment = "exp_speech_coach_settings_v1"
    static let legacyExperiment = "exp_3pqkl2kbmtry3gcv"
    static let variations = ["baseline", "caw_audio", "pavlok_shock", "haptic_vibe"]
    static let dimensions = ["cue_30", "cue_60", "reward_enabled", "wearable_enabled", "warning_shock_percent",
                             "warning_vibe_percent", "warning_beep_enabled", "hard_stop_shock_percent",
                             "hard_stop_vibe_percent", "reward_vibe_percent", "assignment_mode"]

    static let sql: String = #"""
        WITH tagged AS (
         SELECT *, metadata->'treatment_settings' AS cfg FROM habit_events
         WHERE habit_type='monologue_streak'
         AND metadata->>'design_version'='speech_coach_settings_v1'
         AND metadata->>'timing_version'='confirmed_speech_span_v1'
         AND metadata->>'simulated'='false'
         AND metadata->>'experiment_eligible'='true'
         AND call_category IN ('work','client','solo')
         AND session_id NOT LIKE 'session-%'
        ), stable_sessions AS (
         SELECT session_id FROM tagged GROUP BY session_id
         HAVING count(DISTINCT cfg::text)=1
         AND NOT bool_or(COALESCE((metadata->>'settings_changed_during_turn')::boolean,true))
        )
        SELECT t.*,

        """# + dimensions.map { " cfg->>'\($0)' AS \($0)" }.joined(separator: ",\n") + #"""
        ,
         CASE WHEN metadata->>'reward_eligible'='true' THEN 1 ELSE 0 END AS reward_eligible,
         CASE WHEN metadata->>'reward_requested'='true' THEN 1 ELSE 0 END AS reward_requested,
         CASE WHEN latency_to_yield_sec > 0 AND metadata->>'yield_latency_observed'='true'
         THEN latency_to_yield_sec ELSE NULL END AS observed_yield_latency_sec
        FROM tagged t JOIN stable_sessions s USING(session_id)
        WHERE COALESCE(metadata->>'data_quality','unknown')='ok'

        """#

    static let exposureSQL = "SELECT session_id,treatment_arm AS variation_id,timestamp,habit_type AS experiment_id,call_category,"
        + dimensions.joined(separator: ",") + " FROM (" + sql + ") f WHERE assignment_mode='cluster_randomized'"

    static let description = #"""
        ## Assignment and configurable settings
        The desktop app assigns one of four arms per meeting/session. All arms show the 30-second warning toast and 60-second hard-stop toast. Only cluster_randomized assignments enter this experiment; manual overrides are excluded. GrowthBook analyzes logged assignments; it does not control the desktop switches.

        | Assigned arm | 30-second cue | 60-second cue |
        |---|---|---|
        | baseline | Toast | Toast |
        | caw_audio | Toast + macOS Frog sound | Toast + macOS Sosumi sound |
        | pavlok_shock | Toast + selected wearable shock/vibration/beep | Toast + selected wearable shock/vibration |
        | haptic_vibe | Toast + 35% vibration | Toast + 80% vibration |

        Wearable cues require wearable feedback enabled and successful transport. In the configurable Pavlok arm, zero shock with zero vibration at 60 means toast only. Zero shock with vibration enabled means toast plus vibration, not toast only. There is no repeated five-second vibration loop.

        ## Positive feedback and combinations
        Reward vibration is a separate setting shared by all four arms: 30% vibration when a turn ends with duration >=5 and <30 seconds, feedback and reward enabled, canAlert true, and no 60-second trigger in that turn. It can occur after another speaker or silence expiry; it is not promised immediately at the last word. Below 5 seconds is ineligible. Enabled/requested is not proof the device acknowledged delivery.

        Captured variables: cue_30, cue_60, wearable_enabled, warning_shock_percent, warning_vibe_percent, warning_beep_enabled, hard_stop_shock_percent, hard_stop_vibe_percent, reward_enabled, reward_vibe_percent, assignment_mode. For example cue_60=toast_only + reward_enabled=true represents no hard-stop wearable cue with positive feedback. These settings are observational factors, not independently randomized factorial arms. Do not infer causal reward-on versus reward-off effects from those slices.

        ## Measurement and validity
        Only speech_coach_settings_v1 / confirmed_speech_span_v1 rows enter. Duration spans first to last confirmed speech; trailing silence is excluded. Live capture-start timestamps are conservative approximations, not exact word boundaries. Nonpositive/unobserved yield latency is missing, never an instant response. Synthetic/manual tests, intervention audit rows, suspect timing and sessions with settings changes are excluded. Randomization unit is the meeting/session, not each turn. Results describe this one user's meetings; do not treat them as independent people. Global-setting combinations must be reviewed when comparing assigned arms. Legacy data remains in the historical experiment.

        """#

    /// The payload the apply script reads as `p`.
    static var payload: [String: Any] {
        ["fact": fact, "exposure": exposure, "experiment": experiment, "sql": sql, "exposureSQL": exposureSQL,
         "dimensions": dimensions, "description": description]
    }

    /// The mongosh script `--apply` runs. It refuses to run twice (the revision exists).
    static var applyJS: String {
        "const p=" + Tools.json(payload, pretty: false) + ";\n" + #"""

        const g=db.getSiblingDB("growthbook"), now=new Date();
        const ds=g.datasources.findOne({name:"Habits Telemetry (PostgreSQL)"});
        const old=g.experiments.findOne({id:"exp_3pqkl2kbmtry3gcv"});
        if(!ds || !old) throw Error("Missing expected source/experiment");
        if(g.experiments.findOne({id:p.experiment})) throw Error("Revision exists; inspect before updating");
        g.codex_configuration_backups.insertOne({date:now,reason:"Speaking Coach settings v1 rollout",datasource:ds,experiment:old});
        const base=g.facttables.findOne({id:"ftb_habit_events"}); delete base._id;
        base.id=p.fact; base.name="Speaking Coach — versioned settings and outcomes"; base.sql=p.sql;
        base.description="Confirmed speech timing; stable per-session settings. Excludes synthetic, intervention audit, and suspect data.";
        base.dateCreated=now; base.dateUpdated=now;
        for(const col of [...p.dimensions,"reward_eligible","reward_requested","observed_yield_latency_sec"]){
         base.columns.push({name:col,column:col,datatype:p.dimensions.includes(col)?"string":"number",description:"Captured at turn start; reward_requested is not delivery confirmation",dateCreated:now,dateUpdated:now,deleted:false,topValues:[],autoSlices:[],lockedAutoSlices:[]});
        }
        g.facttables.insertOne(base);
        const metricIds={};
        for(const m of g.factmetrics.find({"numerator.factTableId":"ftb_habit_events"}).toArray()){
         delete m._id; const original=m.id; m.id=original.replace("fact__","fact__scv1_"); metricIds[original]=m.id;
         m.name="Settings v1: "+m.name; m.numerator.factTableId=p.fact;
         if(m.denominator) m.denominator.factTableId=p.fact;
         if(original==="fact__latency_to_yield"){
          m.numerator.column="observed_yield_latency_sec";
          m.numerator.rowFilters=[{column:"observed_yield_latency_sec",operator:"not_null"}];
          m.denominator.rowFilters=m.numerator.rowFilters;
          m.description="Observed positive time from warning to latest confirmed speech; ambiguous/nonpositive times excluded.";
         }
         m.dateCreated=now;m.dateUpdated=now;g.factmetrics.insertOne(m);
        }
        const reward=g.factmetrics.findOne({id:metricIds.fact__breach30_rate}); delete reward._id;
        reward.id="fact__scv1_reward_requested";reward.name="Settings v1: reward request share";
        reward.description="Share of turns requesting positive vibration; not confirmed physical delivery or a randomized reward effect.";
        reward.numerator.column="reward_requested";reward.inverse=false;g.factmetrics.insertOne(reward);
        const exposure={id:p.exposure,name:"Speaking Coach settings v1 — randomized sessions",description:"Versioned measurement and stable settings; manual overrides excluded",userIdType:"session_id",dimensions:["call_category",...p.dimensions],hasNameCol:false,query:p.exposureSQL};
        g.datasources.updateOne({id:ds.id},{$push:{"settings.queries.exposure":exposure},$set:{dateUpdated:now}});
        const exp={...old}; delete exp._id;
        exp.id=p.experiment;exp.uid="speech-coach-settings-v1";exp.name="Speaking Coach — settings combinations and positive feedback";
        exp.exposureQueryId=p.exposure;exp.description=p.description;
        exp.hypothesis="Compare added audio/configurable wearable/haptic cues over a common toast, conditional on recorded global settings. Reward on/off is observational unless separately randomized.";
        exp.status="running";exp.dateCreated=now;exp.dateUpdated=now;
        exp.phases=[{...old.phases[0],dateStarted:now,name:"Confirmed speech timing + captured settings v1"}];
        exp.metrics=old.metrics.map(x=>metricIds[x]);exp.goalMetrics=exp.metrics;
        exp.secondaryMetrics=old.secondaryMetrics.map(x=>metricIds[x]).concat([reward.id]);
        exp.variations=old.variations.map(v=>({...v,name:({baseline:"Toast control",caw_audio:"Toast + macOS sounds",pavlok_shock:"Toast + configurable wearable cues",haptic_vibe:"Toast + threshold vibration"})[v.key],description:({baseline:"Toast at 30/60; optional concise-turn reward still applies.",caw_audio:"Toast plus Frog at 30 and Sosumi at 60; optional reward applies.",pavlok_shock:"Toast plus enabled shock/vibration/beep settings at 30, shock/vibration at 60. All zero means toast only. Optional reward applies.",haptic_vibe:"Toast plus 35% vibration at 30 and 80% at 60 if wearable feedback enabled. No five-second repeats. Optional reward applies."})[v.key]}));
        for(const key of ["analysisSummary","lastSnapshotAttempt","nextSnapshotAttempt","pastNotifications"]) delete exp[key];
        exp.nextSnapshotAttempt=now;exp.autoSnapshots=true;g.experiments.insertOne(exp);
        g.experiments.updateOne({id:old.id},{$set:{status:"stopped",autoSnapshots:false,"phases.0.dateEnded":now,dateUpdated:now,name:old.name+" — historical timing",description:old.description+"\n\nHistorical protocol preserved. Superseded by exp_speech_coach_settings_v1; do not pool measurement versions."}});
        print(JSON.stringify({experiment:exp.id,fact:p.fact,exposure:p.exposure,metrics:exp.metrics,secondaryMetrics:exp.secondaryMetrics,dimensions:exposure.dimensions,legacyStatus:"stopped"}));

        """#
    }

    /// Read-only: what is deployed (exposure query, fact table, experiment, metrics).
    static let deployedStateJS = #"""
        const g=db.getSiblingDB("growthbook");
        const ds=g.datasources.findOne({name:"Habits Telemetry (PostgreSQL)"});
        print(JSON.stringify({exposure:ds.settings.queries.exposure.find(x=>x.id==="ex_speech_coach_settings_v1"),fact:g.facttables.findOne({id:"ftb_speech_coach_settings_v1"}),experiment:g.experiments.findOne({id:"exp_speech_coach_settings_v1"}),metrics:g.factmetrics.find({"numerator.factTableId":"ftb_speech_coach_settings_v1"}).toArray()}));
        """#

    static func main(_ args: [String], io: ToolIO, remote: OVHRemote = OVHRemote(timeout: 60)) throws -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            io.out("usage: learner-desktop tool growthbook-design [--apply]\n"
                   + "  Prints the fact SQL, exposure SQL and description; --apply writes the design to GrowthBook over ssh ovh.")
            return 0
        }
        if args.contains("--apply") {
            Log("Tools:growthbook").info("applying the Speaking Coach settings v1 design")
            io.out(try remote.mongo(applyJS))
        } else {
            io.out(Tools.json(["fact_sql": sql, "exposure_sql": exposureSQL, "description": description]))
        }
        return 0
    }
}
