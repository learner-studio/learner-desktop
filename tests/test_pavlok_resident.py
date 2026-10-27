"""Execute resident request validation without a Bluetooth device."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from tests.swift_source import swift_source


@unittest.skipUnless(shutil.which('swiftc'), 'requires Swift')
class ResidentRequestTests(unittest.TestCase):
    def test_only_fresh_valid_requests_fire_once_at_requested_level(self):
        source = swift_source()
        handler = source.split('    @objc func receivePavlokTest', 1)[1].split('    func applicationDidFinishLaunching', 1)[0]
        handler = '    @objc func receivePavlokTest' + handler
        handler = handler.replace('DistributedNotificationCenter.default()', 'ResultSink.shared')
        harness = '''
import Foundation
class ResultSink {
    static let shared = ResultSink()
    var replies = 0
    func postNotificationName(_ name: Notification.Name, object: String, userInfo: [String: Any], deliverImmediately: Bool) { replies += 1 }
}
class PavlokController {
    static let shared = PavlokController()
    var calls: [(String, String, Int)] = []
    func testFire(type: String, operationID: String, intensityOverride: Int, completion: (Bool, String) -> Void) {
        calls.append((type, operationID, intensityOverride))
        completion(true, "BLE acknowledged by wristband")
    }
}
class Receiver: NSObject {
    var handledPavlokRequests = Set<String>()
''' + handler + '''
}
let receiver = Receiver()
let id = UUID().uuidString
func request(_ id: String, _ type: String = "beep", _ level: Int = 40, _ age: Double = 0, _ target: String? = nil) {
    receiver.receivePavlokTest(Notification(name: Notification.Name("test"),
        object: target ?? String(ProcessInfo.processInfo.processIdentifier),
        userInfo: ["id": id, "type": type, "intensity": level, "sent_at": Date().timeIntervalSince1970 - age]))
}
request(id)
request(id)
request(UUID().uuidString, "zap", 101)
request(UUID().uuidString, "zap", 0)
request(UUID().uuidString, "beep", 40, 60)
request(UUID().uuidString, "invalid")
request(UUID().uuidString, "zap", 40, 0, "another-process")
assert(PavlokController.shared.calls.count == 1)
assert(PavlokController.shared.calls[0].0 == "beep")
assert(PavlokController.shared.calls[0].2 == 40)
request(UUID().uuidString, "zap", 40)
assert(PavlokController.shared.calls.count == 2)
assert(PavlokController.shared.calls[1].0 == "zap")
assert(PavlokController.shared.calls[1].2 == 40)
assert(ResultSink.shared.replies == 2)
'''
        with tempfile.TemporaryDirectory() as directory:
            src = pathlib.Path(directory) / 'main.swift'
            binary = pathlib.Path(directory) / 'resident'
            src.write_text(harness)
            build = subprocess.run(['swiftc', str(src), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)

if __name__ == '__main__':
    unittest.main()
