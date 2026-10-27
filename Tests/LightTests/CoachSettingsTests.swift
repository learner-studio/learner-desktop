import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

@MainActor
@Suite("Coach settings and arms", .quietLog) struct CoachSettingsTests {
    @Test func armAssignmentIsAStableHashOfTheSession() {
        // Pinned: the same session must land in the same arm in every process and release.
        #expect(TreatmentArm.assigned(to: "call_zoom_1a2b3c4d") == .cawAudio)
        #expect(TreatmentArm.assigned(to: "call_google_meet_00000000") == .cawAudio)
        #expect(TreatmentArm.assigned(to: "solo_deadbeef") == .hapticVibe)
        #expect(TreatmentArm.assigned(to: "call_slack_cafebabe") == .hapticVibe)
        var counts: [TreatmentArm: Int] = [:]
        for i in 0..<4000 { counts[TreatmentArm.assigned(to: "call_zoom_\(i)"), default: 0] += 1 }
        #expect(counts.count == 4)
        #expect(counts.values.allSatisfy { (850...1150).contains($0) })
    }

    @Test func scratchSettingsNeverWriteToTheOwnersPreferences() throws {
        var plist = ""
        do {
            let defaults = ScratchDefaults("learner-coach-test")
            plist = defaults.plistPath
            let s = CoachSettings(defaults: defaults)
            s.setLevel(.zap, 20, for: .warning)
            s.defaults.synchronize()
            // The values are stored in the suite's own temp folder, not ~/Library/Preferences.
            let named = NSHomeDirectory() + "/Library/Preferences/\((defaults.suite as NSString).lastPathComponent).plist"
            #expect(!FileManager.default.fileExists(atPath: named))
            #expect(!plist.hasPrefix(NSHomeDirectory() + "/Library/Preferences"))
            let saved = try #require(NSDictionary(contentsOfFile: plist))
            #expect(saved.count > 0)
        }
        #expect(!FileManager.default.fileExists(atPath: (plist as NSString).deletingLastPathComponent))
    }

    @Test func aFixedModeOverridesRandomization() {
        let settings = CoachSettings(defaults: scratchDefaults())
        let experiment = HabitExperimentManager(settings: settings)
        #expect(experiment.currentMode == .clusterRandomized)
        #expect(experiment.resolveArm(for: "solo_deadbeef") == .hapticVibe)
        for mode in AssignmentMode.allCases where mode != .clusterRandomized {
            experiment.currentMode = mode
            #expect(experiment.resolveArm(for: "solo_deadbeef").rawValue == mode.rawValue)
        }
        #expect(CoachSettings(defaults: settings.defaults).assignmentMode == .hapticVibe)
    }

    @Test func outOfTheBoxIsBothShockAtDefaultLevels() {
        let s = CoachSettings(defaults: scratchDefaults())
        #expect(s.levels(.warning) == CueLevels(zap: 15, vibe: 0, beep: false))
        #expect(s.levels(.hardStop) == CueLevels(zap: 35, vibe: 0, beep: false))
        #expect(s.presetName == "Both Shock (Default)")
        #expect(!s.wearableEnabled)
        #expect(s.rewardGoodBehavior && s.alertOnlyDuringCalls)
    }

    @Test func everyPresetAppliesAndIsRecognised() {
        let s = CoachSettings(defaults: scratchDefaults())
        for p in CuePreset.all {
            s.setLevel(.beep, 1, for: .warning)      // a leftover beep must not survive a preset
            s.apply(p)
            #expect(s.matchingPreset?.key == p.key)
            #expect(!s.levels(.warning).beep)
            for phase in CuePhase.allCases { #expect(s.levels(phase).active == p.modalities(phase)) }
        }
        s.setLevel(.beep, 1, for: .warning)
        #expect(s.presetName == CuePreset.customName)
    }

    @Test func switchingAModalityOffAndOnKeepsItsLevel() {
        let s = CoachSettings(defaults: scratchDefaults())
        s.setLevel(.zap, 25, for: .hardStop)
        s.toggle(.zap, for: .hardStop)
        #expect(s.levels(.hardStop).zap == 0)
        s.toggle(.zap, for: .hardStop)
        #expect(s.levels(.hardStop).zap == 25)
        s.toggle(.vibe, for: .warning)
        #expect(s.levels(.warning).vibe == 30)
        s.setLevel(.vibe, 250, for: .warning)
        #expect(s.levels(.warning).vibe == 100)
        s.setLevel(.beep, 1, for: .hardStop)       // the hard stop has no beep
        #expect(!s.levels(.hardStop).beep)
        #expect(s.levels(.warning).summary == "⚡ Shock 15% + 📳 Vibe 100%")
    }

    @Test func everyChangeIsAnnouncedOnceAndNoOpsAreNot() {
        let s = CoachSettings(defaults: scratchDefaults())
        var seen: [CoachSettings.Key] = []
        s.observe { seen.append($0) }
        s.wearableEnabled = true
        s.wearableEnabled = true
        s.setLevel(.zap, 15, for: .warning)      // already 15
        s.setLevel(.zap, 20, for: .warning)
        s.apiToken = "t"
        #expect(seen == [.wearableEnabled, .cueLevels, .apiToken])
    }

    @Test func benchTestLevelsAreSeparateFromTheTreatment() {
        let s = CoachSettings(defaults: scratchDefaults())
        #expect(s.testLevel(.zap) <= 15)
        #expect(s.testLevel(.vibe) == 40)
        s.defaults.set(80, forKey: "pavlok_test_zap_intensity")
        #expect(s.testLevel(.zap) == 80)
        #expect(s.levels(.warning).zap == 15 && s.levels(.hardStop).zap == 35)
    }

    @Test func treatmentDescribesWhatEachArmFires() {
        let rig = CoachRig(mode: .pavlokShock)
        func cues() -> (String, String) { let t = rig.coach.treatmentSettings(); return (t.cue30, t.cue60) }
        rig.settings.setLevel(.vibe, 60, for: .hardStop)
        #expect(cues() == ("toast+zap_15", "toast+zap_35+vibe_60"))
        #expect(rig.coach.treatmentSettings().rewardEnabled)
        rig.settings.rewardGoodBehavior = false
        #expect(!rig.coach.treatmentSettings().rewardEnabled)
        rig.wearable.isEnabled = false
        #expect(cues() == ("toast_only", "toast_only"))
        rig.wearable.isEnabled = true
        rig.settings.assignmentMode = .hapticVibe
        #expect(cues() == ("toast+vibe_35", "toast+vibe_80"))
        rig.settings.assignmentMode = .cawAudio
        #expect(cues() == ("toast+macos_Frog", "toast+macos_Sosumi"))
        rig.settings.rewardGoodBehavior = true
        #expect(!rig.coach.treatmentSettings().rewardEnabled)   // no reward outside the wristband arms
        rig.settings.assignmentMode = .baseline
        #expect(cues() == ("toast_only", "toast_only"))
    }
}
