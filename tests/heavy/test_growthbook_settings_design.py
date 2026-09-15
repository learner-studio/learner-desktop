"""Read-only remote contract for the deployed settings-aware GrowthBook design."""
import importlib.util
import json
import os
from pathlib import Path
import unittest

REPO=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('settings_design',REPO/'scripts/configure-speaking-coach-growthbook.py')
cfg=importlib.util.module_from_spec(spec);spec.loader.exec_module(cfg)

@unittest.skipUnless(os.environ.get('AIAGG_HEAVY')=='1' and os.environ.get('AIAGG_REMOTE_E2E')=='1','remote opt-in required')
class GrowthBookSettingsDesign(unittest.TestCase):
    def test_deployed_variables_metrics_and_eligibility(self):
        state=json.loads(cfg.mongo('''const g=db.getSiblingDB("growthbook");
const ds=g.datasources.findOne({name:"Habits Telemetry (PostgreSQL)"});
print(JSON.stringify({exposure:ds.settings.queries.exposure.find(x=>x.id==="ex_speech_coach_settings_v1"),fact:g.facttables.findOne({id:"ftb_speech_coach_settings_v1"}),experiment:g.experiments.findOne({id:"exp_speech_coach_settings_v1"}),metrics:g.factmetrics.find({"numerator.factTableId":"ftb_speech_coach_settings_v1"}).toArray()}));'''))
        self.assertEqual(state['fact']['sql'],cfg.SQL)
        self.assertEqual(state['exposure']['query'],cfg.EXPOSURE_SQL)
        self.assertTrue(set(cfg.DIMENSIONS)<=set(state['exposure']['dimensions']))
        self.assertEqual([v['key'] for v in state['experiment']['variations']],['baseline','caw_audio','pavlok_shock','haptic_vibe'])
        self.assertEqual(state['experiment']['exposureQueryId'],cfg.EXPOSURE)
        ids={m['id'] for m in state['metrics']}
        self.assertTrue(set(state['experiment']['goalMetrics']+state['experiment']['secondaryMetrics'])<=ids)
        source=Path(os.environ['AIAGG_SETTINGS_E2E_FIXTURE'])
        row=json.loads(source.read_text())[0];row['metadata']=json.loads(row['metadata'])
        row['metadata']['treatment_settings']['assignment_mode']='cluster_randomized'
        for name,field,value,want in [('reward_toast_only',None,None,1),('reward_off','reward_enabled',False,1),('manual','assignment_mode','baseline',0),('synthetic','simulated',True,0),('legacy','design_version','legacy',0),('mixed','settings_changed_during_turn',True,0)]:
            with self.subTest(case=name):
                item=json.loads(json.dumps(row))
                if field in ('reward_enabled','assignment_mode'): item['metadata']['treatment_settings'][field]=value
                elif field:item['metadata'][field]=value
                literal=json.dumps([item]).replace("'","''")
                sql="WITH habit_events AS (SELECT * FROM json_populate_recordset(NULL::public.habit_events,'"+literal+"'::json)) SELECT json_build_object('count',count(*),'cue_60',max(cue_60),'reward_enabled',max(reward_enabled)) FROM ("+state['exposure']['query']+") e;"
                out=cfg.r.ssh_script("sudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1 -d habits <<'SQL'\nBEGIN READ ONLY;\n"+sql+'\nROLLBACK;\nSQL\n')
                got=json.loads(out);self.assertEqual(got['count'],want)
                if want:
                    self.assertEqual(got['cue_60'],'toast_only')
                    self.assertEqual(got['reward_enabled'],'false' if name=='reward_off' else 'true')

if __name__=='__main__': unittest.main()
