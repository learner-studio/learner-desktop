"""Exercise the actual reward menu action with automatic feedback disabled."""
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'menu-bar-app/main.swift'

@unittest.skipUnless(shutil.which('swiftc'), 'requires Swift')
class RewardMenuTests(unittest.TestCase):
    def test_reward_menu_uses_manual_path_and_real_reward_intensity(self):
        source = SOURCE.read_text()
        action = source[source.index('    @objc func testPavlokVibe()'):source.index('    @objc func testPavlokZap()')]
        helper = source[source.index('    private func performPavlokManualTest('):source.index('    @objc func pullVaultChats()')]
        level = re.search(r'let rewardVibeIntensity = (\d+)', source).group(1)
        automatic = source.split('private func evaluateGoodBehaviorReward', 1)[1].split('private func handleTranscriptionRow', 1)[0]
        self.assertIn('value: PavlokController.shared.rewardVibeIntensity', automatic)
        harness = '''
import AppKit
class PavlokController {
    static let shared = PavlokController()
    let rewardVibeIntensity = LEVEL
    var isEnabled = false
    var calls: [(String, Int?)] = []
    var connectionStatusText = "Connected"
    static func testFireLabel(for type: String) -> String { type }
    func testFire(type: String, intensityOverride: Int?, completion: (Bool, String) -> Void) {
        calls.append((type, intensityOverride))
        completion(true, "BLE acknowledged by wristband")
    }
}
class Menu: NSObject {
    var refreshCount = 0
    func rebuildMenu() { refreshCount += 1 }
    func updateTrayButton() {}
''' .replace('LEVEL', level) + action + helper + '''
}
let menu = Menu()
menu.testPavlokVibe()
assert(PavlokController.shared.calls.count == 1)
assert(PavlokController.shared.calls[0].0 == "vibe")
assert(PavlokController.shared.calls[0].1 == PavlokController.shared.rewardVibeIntensity)
assert(!PavlokController.shared.isEnabled)
assert(menu.refreshCount == 1)
'''
        with tempfile.TemporaryDirectory() as directory:
            src = pathlib.Path(directory) / 'main.swift'
            binary = pathlib.Path(directory) / 'reward'
            src.write_text(harness)
            build = subprocess.run(['swiftc', str(src), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)

if __name__ == '__main__':
    unittest.main()
