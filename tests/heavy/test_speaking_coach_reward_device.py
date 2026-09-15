"""Explicit live Pavlok vibration: real meeting poller → subthreshold turn → BLE ACK.
Uses isolated defaults/SQLite and synthetic transcript timestamps; no audio is played.
Never enables shocks. Requires explicit AIAGG_REWARD_DEVICE_E2E=1 opt-in.
"""
import os
import unittest
import test_speaking_coach_meeting_e2e as meeting

@unittest.skipUnless(os.environ.get("AIAGG_HEAVY") == "1" and os.environ.get("AIAGG_REWARD_DEVICE_E2E") == "1", "live reward device opt-in required")
class RewardDeviceE2E(unittest.TestCase):
    run_case = meeting.SpeakingCoachMeetingE2E.run_case

    def test_stopping_under_30_sends_one_positive_vibration(self):
        self.run_case("reward-device", has_meeting=True, offsets=[0, 4, 8, 12], reward_device=True)

if __name__ == "__main__":
    unittest.main()
