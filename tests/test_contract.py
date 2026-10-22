#!/usr/bin/env python3
"""Fast lane: the Swift app's wire payloads match the pinned learner-server contract.

contract/contract.json is copied from learner-server (commit in contract/PINNED_COMMIT).
The app builds recordHabitEvents events in HabitEventLogger.unsentEvents and the
heartbeat in TrayAppManager.heartbeatInput; a renamed or missing field would get every
batch a 422.
"""

import json
import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")
CONTRACT = os.path.join(REPO, "contract", "contract.json")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def method(src, signature):
    start = src.index(signature)
    return src[start:src.index("\n    }\n", start)]


def swift_keys(body):
    return set(re.findall(r'^\s*"(\w+)":', body, re.M))


class ContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rpc = json.loads(read(CONTRACT))["rpc"]
        cls.src = read(SWIFT)

    def schema(self, rpc):
        return self.rpc[rpc]["input"]

    def test_habit_event_fields_match_the_contract(self):
        item = self.schema("recordHabitEvents")["properties"]["events"]["items"]
        sent = swift_keys(method(self.src, "func unsentEvents("))
        self.assertEqual(sent, set(item["properties"]))
        self.assertLessEqual(set(item.get("required", [])), sent)

    def test_heartbeat_fields_match_the_contract(self):
        schema = self.schema("recordAppHeartbeat")
        body = method(self.src, "func heartbeatInput(")
        top = body[:body.index('"detail":') + len('"detail":')]
        self.assertEqual(swift_keys(top), set(schema["properties"]))

    def test_batches_respect_the_contract_limits(self):
        events = self.schema("recordHabitEvents")["properties"]["events"]
        self.assertIn("static let maxBatch = %d" % events["maxItems"], self.src)

    def test_client_id_is_valid(self):
        pattern = self.schema("recordHabitEvents")["properties"]["clientId"]["pattern"]
        client = re.search(r'static let clientId = "([^"]+)"', self.src).group(1)
        self.assertRegex(client, pattern)

    def test_capture_states_are_in_the_enum(self):
        allowed = set(self.schema("recordAppHeartbeat")["properties"]["captureState"]["enum"])
        body = method(self.src, "func heartbeatInput(")
        line = next(ln for ln in body.splitlines() if "let captureState" in ln)
        self.assertLessEqual(set(re.findall(r'"(\w+)"', line)), allowed)


if __name__ == "__main__":
    unittest.main()
