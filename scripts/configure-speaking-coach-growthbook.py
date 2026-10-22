#!/usr/bin/env python3
"""Apply the versioned Speaking Coach design to self-hosted GrowthBook via SSH.
Preserves legacy definitions/results; backs up affected documents before mutation.
"""
import argparse, json, shlex, subprocess
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]
def ssh_script(script):
    """Run a bash script on the OVH box over the `ovh` ssh alias; return its stdout."""
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "ovh", "bash", "-s"],
                            input=script, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise SystemExit(f"ssh to ovh failed: {result.stderr[-2000:]}")
    return result.stdout.strip()
FACT='ftb_speech_coach_settings_v1'
EXPOSURE='ex_speech_coach_settings_v1'
EXPERIMENT='exp_speech_coach_settings_v1'
DIMENSIONS=['cue_30','cue_60','reward_enabled','wearable_enabled','warning_shock_percent','warning_vibe_percent','warning_beep_enabled','hard_stop_shock_percent','hard_stop_vibe_percent','reward_vibe_percent','assignment_mode']
SQL="""WITH tagged AS (
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
""" + ',\n'.join(" cfg->>'%s' AS %s"%(d,d) for d in DIMENSIONS) + """,
 CASE WHEN metadata->>'reward_eligible'='true' THEN 1 ELSE 0 END AS reward_eligible,
 CASE WHEN metadata->>'reward_requested'='true' THEN 1 ELSE 0 END AS reward_requested,
 CASE WHEN latency_to_yield_sec > 0 AND metadata->>'yield_latency_observed'='true'
 THEN latency_to_yield_sec ELSE NULL END AS observed_yield_latency_sec
FROM tagged t JOIN stable_sessions s USING(session_id)
WHERE COALESCE(metadata->>'data_quality','unknown')='ok'
"""
EXPOSURE_SQL='SELECT session_id,treatment_arm AS variation_id,timestamp,habit_type AS experiment_id,call_category,'+','.join(DIMENSIONS)+' FROM ('+SQL+") f WHERE assignment_mode='cluster_randomized'"
DESCRIPTION='''## Assignment and configurable settings
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
'''

def mongo(js):
 command='exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$(cat)"'
 return ssh_script('set -e\ndocker exec -i biztools-growthbook-growthbook-mongo-1 sh -c '+shlex.quote(command)+" <<'COACH_JS'\n"+js+'\nCOACH_JS\n')

def apply():
 payload=dict(fact=FACT,exposure=EXPOSURE,experiment=EXPERIMENT,sql=SQL,exposureSQL=EXPOSURE_SQL,dimensions=DIMENSIONS,description=DESCRIPTION)
 js='const p='+json.dumps(payload)+';\n'+'''
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
g.experiments.updateOne({id:old.id},{$set:{status:"stopped",autoSnapshots:false,"phases.0.dateEnded":now,dateUpdated:now,name:old.name+" — historical timing",description:old.description+"\\n\\nHistorical protocol preserved. Superseded by exp_speech_coach_settings_v1; do not pool measurement versions."}});
print(JSON.stringify({experiment:exp.id,fact:p.fact,exposure:p.exposure,metrics:exp.metrics,secondaryMetrics:exp.secondaryMetrics,dimensions:exposure.dimensions,legacyStatus:"stopped"}));
'''
 print(mongo(js))
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--apply',action='store_true');args=parser.parse_args()
 if args.apply: apply()
 else: print(json.dumps({'fact_sql':SQL,'exposure_sql':EXPOSURE_SQL,'description':DESCRIPTION},indent=2))
