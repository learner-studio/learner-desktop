"""Execute the production BLE encoders without initializing Bluetooth."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from tests.swift_source import swift_source


@unittest.skipUnless(shutil.which('swiftc'), 'requires Swift')
class PavlokPacketTests(unittest.TestCase):
    def test_selected_intensity_is_encoded_for_one_pulse(self):
        source = swift_source()
        encoders = source.split('    // MARK: - Binary BLE Stimulus Encoder', 1)[1].split('    // MARK: - Send Stimulus', 1)[0]
        harness = '''
import Foundation
struct Encoder {
''' + encoders + '''
}
for value in [1, 5, 10, 25, 40, 75, 100] {
    let pulse = Data([0x81, 0x0c, UInt8(value), 0x18, 0x18])
    assert(Encoder.encodeBleBeep(intensity: value) == pulse)
    assert(Encoder.encodeBleVibe(intensity: value) == pulse)
    assert(Encoder.encodeBleShock(intensity: value) == Data([0x81, UInt8(value)]))
}
assert(Encoder.encodeBleBeep(intensity: 150)[2] == 100)
assert(Encoder.encodeBleBeep(intensity: -10)[2] == 1)
print("packet assertions passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            src = pathlib.Path(directory) / 'main.swift'
            binary = pathlib.Path(directory) / 'packets'
            src.write_text(harness)
            build = subprocess.run(['swiftc', str(src), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == '__main__':
    unittest.main()
