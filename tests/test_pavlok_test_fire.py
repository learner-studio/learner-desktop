#!/usr/bin/env python3
"""Fast lane: the manual Pavlok test-fire section of the menu.

Hermetic -- reads menu-bar-app/main.swift and asserts nothing else. The live fire is in
tests/heavy/test_pavlok_test_fire_live.py, which needs the wristband and is gated behind
AIAGG_HEAVY_DESTRUCTIVE=1.

What is worth guarding here is not the layout. It is that a button whose whole purpose is
to deliver an electric shock to a person stays (a) reachable only by a deliberate human
action, (b) separate from the experiment's own stimuli, and (c) honest about whether the
shock actually arrived.
"""

import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SWIFT = os.path.join(REPO, "menu-bar-app", "main.swift")

TYPES = ("vibe", "beep", "zap")


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def span(src, start_marker, end_marker):
    start = src.index(start_marker)
    return src[start:src.index(end_marker, start + len(start_marker))]


class Source:
    """Parsed once; every test reads these slices."""

    src = read(SWIFT)
    controller = span(src, "class PavlokController", "\n// MARK: - Habit Experiment Manager")
    test_fire_fn = span(src, "func testFire(type: String", "\n    // Backward-compatibility bridge")
    panel = span(src, "class PavlokTestFireSubmenuView", "\n// MARK: - Cute Dog Stick Figure")
    menu_section = span(src, "// 5. Manual Test Fire", "let scanItem = NSMenuItem")
    cli = span(src, "func runPavlokTestFireCLI()", "\n// MARK: - Application Entrypoint")
    menu_action = span(src, "@objc func testFirePavlokStimulus(", "\n    @objc func pullVaultChats")


class SeparateFromTheExperimentTest(unittest.TestCase):
    """The 30s/60s intensities are the trial's independent variable. A test button that
    wrote to them would silently change the treatment mid-experiment."""

    EXPERIMENT_KEYS = (
        "pavlok_warning_shock_intensity",
        "pavlok_warning_vibe_intensity",
        "pavlok_alert_shock_intensity",
        "pavlok_alert_vibe_intensity",
        "pavlok_warning_beep_enabled",
    )

    def test_each_modality_persists_its_own_test_intensity(self):
        for t in TYPES:
            self.assertIn(f'"pavlok_test_{t}_intensity"', Source.src,
                          f"no persisted UserDefaults key for the {t} test intensity")

    def test_the_test_keys_are_not_any_of_the_experiment_keys(self):
        test_keys = {f"pavlok_test_{t}_intensity" for t in TYPES}
        self.assertEqual(test_keys & set(self.EXPERIMENT_KEYS), set())

    def test_firing_a_test_never_reads_an_experiment_intensity(self):
        for name in ("warningShockIntensity", "warningVibeIntensity",
                     "alertShockIntensity", "alertVibeIntensity"):
            self.assertNotIn(name, Source.test_fire_fn,
                             f"testFire() reads {name}, which belongs to the trial")

    def test_the_panel_only_ever_writes_the_test_intensities(self):
        for name in ("warningShockIntensity", "warningVibeIntensity", "warningBeepEnabled",
                     "alertShockIntensity", "alertVibeIntensity"):
            self.assertNotIn(name, Source.panel,
                             f"the test-fire panel touches {name}, which belongs to the trial")


class OnlyFiresWhenAHumanAsksTest(unittest.TestCase):
    def test_every_call_site_is_a_deliberate_human_action(self):
        """Three entry points, all of them a person doing something: the panel button,
        the plain menu item, and the --pavlok-test-fire command."""
        allowed = (Source.panel, Source.menu_action, Source.cli,
                   span(Source.src, "@objc func receivePavlokTest", "func applicationDidFinishLaunching"))
        calls = [m.start() for m in re.finditer(r"\.testFire\(type:", Source.src)]
        self.assertGreaterEqual(len(calls), 3, "test fire is not wired up at all")
        for pos in calls:
            line = Source.src[Source.src.rindex("\n", 0, pos) + 1:Source.src.index("\n", pos)].strip()
            self.assertTrue(any(line in region for region in allowed),
                            f"testFire() is called from outside the menu and CLI: {line}")

    def test_the_monologue_monitor_cannot_reach_it(self):
        monitor = span(Source.src, "// MARK: - Continuous Word Talk-Time Monitor",
                       "// MARK: - Interactive Non-Closing Multi-Select Submenu Views")
        self.assertNotIn("testFire(", monitor)
        self.assertNotIn("testIntensity(", monitor)

    def test_the_automatic_cues_cannot_reach_it(self):
        for fn in ("func trigger30sWarning(", "func trigger60sHardStop("):
            body = span(Source.src, fn, "\n    }\n")
            self.assertNotIn("testFire(", body)


class RefusesToFireBlindTest(unittest.TestCase):
    def test_a_disabled_wearable_is_refused_rather_than_silently_armed(self):
        self.assertIn("guard canTestFire else", Source.test_fire_fn,
                      "test fire does not check that the wearable feature is on")
        self.assertNotIn("isEnabled = true", Source.test_fire_fn,
                         "test fire switches the wearable on by itself")

    def test_zero_percent_means_off_and_never_reaches_the_device(self):
        # sendStimulus clamps value up to 1, so passing 0 through would buzz the wrist.
        self.assertIn("guard intensity > 0 else", Source.test_fire_fn)

    def test_the_zap_default_is_low(self):
        body = span(Source.controller, "var testZapIntensity: Int", "\n    }\n")
        match = re.search(r"== nil \{ return (\d+) \}", body)
        self.assertIsNotNone(match, "testZapIntensity has no first-run default")
        default = int(match.group(1))
        self.assertLessEqual(default, 15,
                             f"the out-of-the-box test shock is {default}%; first press should not hurt")

    def test_every_intensity_is_clamped_to_nought_through_one_hundred(self):
        for t in ("Vibe", "Beep", "Zap"):
            body = span(Source.controller, f"var test{t}Intensity: Int", "\n    }\n")
            self.assertIn("max(0, min(100,", body, f"test{t}Intensity is not clamped")


class ReportsTheOutcomeOnScreenTest(unittest.TestCase):
    """'Did it fire?' must be answerable without opening a log file."""

    def test_the_result_records_success_transport_and_time(self):
        result = span(Source.controller, "struct TestFireResult", "\n    private(set) var lastTestFire")
        for field in ("let success: Bool", "let detail: String", "let at: Date"):
            self.assertIn(field, result)
        self.assertIn("Direct Bluetooth", result)
        self.assertIn("Pavlok Cloud", result)
        # Success and failure have to look different at a glance.
        self.assertIn('success ? "✅" : "❌"', result)

    def test_the_panel_shows_the_outcome_without_closing_the_menu(self):
        self.assertIn("resultLabel", Source.panel)
        self.assertIn("lastTestFireSummary", Source.panel)

    def test_the_menu_carries_the_outcome_after_it_closes(self):
        self.assertIn("lastTestFireSummary", Source.menu_section)

    def test_a_failure_from_the_plain_menu_item_is_raised_not_just_logged(self):
        # The menu has closed by then and a failed stimulus is, by definition, silent.
        self.assertIn("NSAlert()", Source.menu_action)
        self.assertIn("guard !ok else { return }", Source.menu_action)

    def test_the_result_is_not_persisted_across_restarts(self):
        # A "delivered" line left over from three days ago is worse than no line.
        self.assertNotIn("lastTestFire", Source.src[Source.src.index("let kPavlokTestVibeIntensity"):
                                                    Source.src.index("var isEnabled: Bool")])


class PanelControlsTest(unittest.TestCase):
    def test_each_modality_has_its_own_slider_over_the_full_range(self):
        self.assertIn("NSSlider(value: 0, minValue: 0, maxValue: 100", Source.panel)
        for t in TYPES:
            self.assertIn(f'("{t}"', Source.panel, f"no {t} row in the test-fire panel")

    def test_each_modality_has_its_own_fire_button(self):
        self.assertIn('NSButton(title: "Test fire"', Source.panel)
        self.assertIn("fireButtons[row.type] = button", Source.panel)

    def test_a_zero_or_disabled_row_cannot_be_fired(self):
        self.assertIn("isEnabled = p.canTestFire && value > 0", Source.panel)
        self.assertIn("item.isEnabled = PavlokController.shared.canTestFire && level > 0",
                      Source.menu_section)
        # AppKit re-enables items whose target responds to the action unless told not to.
        self.assertIn("testFireMenu.autoenablesItems = false", Source.menu_section)

    def test_the_section_is_reachable_from_the_status_menu(self):
        self.assertIn("PavlokTestFireSubmenuView()", Source.menu_section)
        self.assertIn("statusMenu.addItem(testFireParentItem)", Source.menu_section)
        for t in TYPES:
            self.assertIn(f'"{t}"', Source.menu_section)


class HeadlessCommandTest(unittest.TestCase):
    def test_it_validates_the_stimulus_type_before_anything_else(self):
        self.assertIn('guard ["vibe", "beep", "zap"].contains(type)', Source.cli)
        self.assertLess(Source.cli.index("contains(type)"), Source.cli.index("isEnabled = true"),
                        "the radio is touched before the arguments are checked")

    def test_it_rejects_an_out_of_range_intensity(self):
        self.assertIn("parsed >= 1, parsed <= 100", Source.cli)

    def test_it_leaves_the_wearable_exactly_as_armed_as_it_found_it(self):
        self.assertIn("let wasEnabled = pavlok.isEnabled", Source.cli)
        self.assertIn("if !wasEnabled { pavlok.isEnabled = false }", Source.cli)

    def test_it_leaves_the_saved_intensity_alone(self):
        self.assertIn("let savedIntensity = pavlok.testIntensity(for: type)", Source.cli)
        self.assertIn("pavlok.setTestIntensity(savedIntensity, for: type)", Source.cli)

    def test_it_cannot_hang_a_script_forever(self):
        self.assertIn("let watchdog = connectWait + 20.0", Source.cli)
        self.assertIn("restoreAndExit(1)", Source.cli)

    def test_it_writes_its_evidence_to_the_app_log(self):
        self.assertIn(".ai-aggregator/logs", Source.cli)
        self.assertIn('freopen(logDir + "/menubar.log", "a", stdout)', Source.cli)

    def test_it_is_opt_in_from_the_entrypoint(self):
        entry = Source.src[Source.src.index("// MARK: - Application Entrypoint"):]
        self.assertIn('if CommandLine.arguments.contains("--pavlok-test-fire")', entry)


class StillLazyAboutBluetoothTest(unittest.TestCase):
    """tests/test_clean_shutdown.py owns this invariant; repeated here because the
    test-fire feature is the most likely thing to break it."""

    def test_the_test_fire_path_does_not_create_its_own_central_manager(self):
        self.assertEqual(Source.src.count("CBCentralManager(delegate:"), 1)
        for region in (Source.test_fire_fn, Source.panel, Source.cli, Source.menu_action):
            self.assertNotIn("CBCentralManager(", region)

    def test_it_reaches_the_radio_through_the_existing_lazy_scan(self):
        self.assertIn("startBleScan(force: true)", Source.test_fire_fn)


class DiscoveryTraceTest(unittest.TestCase):
    def test_the_trace_is_off_unless_asked_for(self):
        self.assertIn("static var traceBleDiscovery = false", Source.controller)
        self.assertIn('args.contains("--trace-ble")', Source.cli)

    def test_the_trace_does_not_repeat_a_peripheral(self):
        self.assertIn("tracedPeripherals.insert(peripheral.identifier)", Source.controller)


if __name__ == "__main__":
    unittest.main()
