#!/usr/bin/env python3
import pathlib
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / 'menu-bar-app/main.swift'


class RewardTests(unittest.TestCase):
    def test_automatic_reward_uses_the_real_reward_intensity(self):
        source = SOURCE.read_text()
        automatic = source.split('private func evaluateGoodBehaviorReward', 1)[1].split('private func handleTranscriptionRow', 1)[0]
        self.assertIn('value: PavlokController.shared.rewardVibeIntensity', automatic)


if __name__ == '__main__':
    unittest.main()
