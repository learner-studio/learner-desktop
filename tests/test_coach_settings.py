"""Exercise the production settings snapshot against meaningful cue combinations."""
import pathlib, shutil, subprocess, tempfile, unittest
REPO=pathlib.Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('swiftc'),'Swift required')
class CoachSettings(unittest.TestCase):
    def test_effective_combinations_match_arm_and_switches(self):
        source=(REPO/'menu-bar-app/main.swift').read_text()
        method=source[source.index('    private func treatmentSettings()'):source.index('    private func settingsKey(')].replace('private func','func')
        swift='''import Foundation
class PavlokController {
 static let shared = PavlokController()
 var isEnabled=true, rewardGoodBehavior=true, warningBeepEnabled=false
 var warningShockIntensity=0, warningVibeIntensity=0, alertShockIntensity=0, alertVibeIntensity=0
 let rewardVibeIntensity=30
}
struct Mode { let rawValue="cluster_randomized" }
class HabitExperimentManager {
 static let shared = HabitExperimentManager()
 let currentMode=Mode()
 var arm="pavlok_shock"
 func resolveArm(for session: String) -> String { arm }
}
class Monitor {
 let activeSessionId="test", rewardMinSec=5.0, warningThreshold=30.0, alertThreshold=60.0
 let alertOnlyDuringCalls=true
'''+method+'''}
let m=Monitor(), p=PavlokController.shared, e=HabitExperimentManager.shared
assert(m.treatmentSettings()["cue_60"] as? String == "toast_only")
assert(m.treatmentSettings()["reward_enabled"] as? Bool == true)
p.rewardGoodBehavior=false
assert(m.treatmentSettings()["reward_enabled"] as? Bool == false)
p.alertVibeIntensity=60
assert(m.treatmentSettings()["cue_60"] as? String == "toast+vibe_60")
p.alertShockIntensity=35
assert(m.treatmentSettings()["cue_60"] as? String == "toast+zap_35+vibe_60")
p.isEnabled=false
assert(m.treatmentSettings()["cue_60"] as? String == "toast_only")
e.arm="haptic_vibe";p.isEnabled=true
assert(m.treatmentSettings()["cue_30"] as? String == "toast+vibe_35")
assert(m.treatmentSettings()["cue_60"] as? String == "toast+vibe_80")
e.arm="baseline"
assert(m.treatmentSettings()["cue_60"] as? String == "toast_only")
e.arm="caw_audio"
assert(m.treatmentSettings()["cue_30"] as? String == "toast+macos_Frog")
assert(m.treatmentSettings()["cue_60"] as? String == "toast+macos_Sosumi")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path=pathlib.Path(tmp);(path/'main.swift').write_text(swift)
            build=subprocess.run(['swiftc',str(path/'main.swift'),'-o',str(path/'check')],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run([str(path/'check')],capture_output=True,text=True)
            self.assertEqual(run.returncode,0,run.stderr)
