import Foundation
import Testing
@testable import LearnerDesktop
import TestSupport

/// The whole coach, end to end on fixtures: speech spans -> streak -> 30 s / 60 s ->
/// the arm's stimulus -> the trial row in SQLite.
@Suite("Coach workflow") struct CoachWorkflowTests {
    @Test func pavlokArmFiresEveryConfiguredModalityAndRecordsEachResult() {
        let rig = CoachRig(mode: .pavlokShock)
        rig.settings.setLevel(.vibe, 30, for: .warning)
        rig.settings.setLevel(.beep, 1, for: .warning)
        // The wristband takes the zap and the beep but drops the vibration.
        rig.wearable.answers[.vibe] = StimulusResult(delivered: false, transport: .ble, detail: "BLE acknowledgement timed out")
        rig.monologue(0, 64)
        #expect(rig.wearable.sent == [
            .init(modality: .zap, intensity: 15, arm: "pavlok_shock"),
            .init(modality: .vibe, intensity: 30, arm: "pavlok_shock"),
            .init(modality: .beep, intensity: 1, arm: "pavlok_shock"),
            .init(modality: .zap, intensity: 35, arm: "pavlok_shock"),
        ])
        #expect(rig.toast.visible)
        #expect(rig.coach.isAlertActive)
        rig.say(70, 72, speaker: .other)
        #expect(!rig.toast.visible)
        #expect(rig.coach.currentStreak == 0)

        let rows = rig.rows
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row["treatment_arm"] as? String == "pavlok_shock")
        #expect((row["session_id"] as? String)?.hasPrefix("call_zoom_") == true)
        #expect(row["call_category"] as? String == "work")
        #expect(row["turn_duration_sec"] as? Double == 64)
        #expect(row["warning_fired_at"] as? Double == 32)
        #expect(row["shock_fired_at"] as? Double == 60)
        #expect(row["breached_30s"] as? Int == 1 && row["breached_60s"] as? Int == 1)
        #expect(row["was_rewarded"] as? Int == 0)
        let m = meta(row)
        #expect(m["experiment_eligible"] as? Bool == true)
        #expect(m["toast_shown"] as? Bool == true)
        #expect(m["end_reason"] as? String == "someone else spoke")
        let settings = m["treatment_settings"] as? [String: Any]
        #expect(settings?["cue_30"] as? String == "toast+zap_15+vibe_30+beep")
        #expect(settings?["cue_60"] as? String == "toast+zap_35")

        let fired = rig.interventions.map { "\($0["threshold"]!)/\($0["modality"]!)/\($0["transport"]!)/\($0["delivered"]!)" }
        #expect(fired == ["30s_warning/toast/screen/1", "30s_warning/pavlok_zap/ble/1", "30s_warning/pavlok_vibe/ble/0",
                          "30s_warning/pavlok_beep/ble/1", "60s_hard_stop/pavlok_zap/ble/1"])
    }

    @Test func baselineGetsTheToastButNoStimulusAndNoReward() {
        let rig = CoachRig(mode: .baseline)
        rig.monologue(0, 12)
        rig.say(13, 14, speaker: .other)
        rig.monologue(20, 56)
        rig.say(57, 58, speaker: .other)
        #expect(rig.wearable.sent.isEmpty)
        let rows = rig.rows
        #expect(rows.count == 2)
        let short = meta(rows[0])
        #expect(rows[0]["was_rewarded"] as? Int == 0)
        #expect(short["reward_eligible"] as? Bool == true)
        #expect(short["reward_requested"] as? Bool == false)
        #expect(short["toast_shown"] as? Bool == false)
        let long = meta(rows[1])
        #expect(long["toast_shown"] as? Bool == true)
        let modalities = (long["interventions"] as? [[String: Any]])?.map { $0["modality"] as? String }
        #expect(modalities == ["toast", "none"])
        #expect((long["treatment_settings"] as? [String: Any])?["cue_30"] as? String == "toast_only")
    }

    @Test func hapticArmRewardsAConciseTurnAndRecordsWhetherItArrived() {
        let rig = CoachRig(mode: .hapticVibe)
        rig.monologue(0, 12)
        rig.say(13, 14, speaker: .other)
        #expect(rig.wearable.sent == [.init(modality: .vibe, intensity: 30, arm: "haptic_vibe")])
        #expect(rig.wearable.reasons.last?.contains("Good behavior reward") == true)
        // The next reward fails at the device: the row must say it was not rewarded.
        rig.wearable.answers[.vibe] = .notSent("Bluetooth disconnected and no cloud token")
        rig.monologue(20, 32)
        rig.say(33, 34, speaker: .other)
        let rows = rig.rows
        #expect(rows.map { $0["was_rewarded"] as? Int } == [1, 0])
        #expect((meta(rows[0])["reward_result"] as? [String: Any])?["transport"] as? String == "ble")
        #expect(meta(rows[1])["reward_requested"] as? Bool == true)
    }

    @Test func hapticArmVibratesAtFixedLevels() {
        let rig = CoachRig(mode: .hapticVibe)
        rig.monologue(0, 64)
        #expect(rig.wearable.sent.map(\.intensity) == [35, 80])
        #expect(rig.wearable.sent.allSatisfy { $0.modality == .vibe })
    }

    @Test func audioArmPlaysTheMacSoundsAndNeverTouchesTheWristband() {
        let rig = CoachRig(mode: .cawAudio)
        rig.monologue(0, 64)
        rig.say(65, 66, speaker: .other)
        #expect(rig.sounds == ["Frog", "Sosumi"])
        #expect(rig.wearable.sent.isEmpty)
        #expect(rig.interventions.map { $0["modality"] as? String } == ["toast", "caw_audio", "caw_audio"])
    }

    @Test func noCueFiresOffCallAndTheTurnIsNotAnExperimentalUnit() {
        let rig = CoachRig(mode: .pavlokShock, call: nil)
        rig.monologue(0, 40)
        #expect(rig.toast.shows == 0)
        #expect(rig.wearable.sent.isEmpty)
        rig.wait(20)
        let row = rig.rows.first
        #expect(row?["call_category"] as? String == "solo")
        #expect((row?["session_id"] as? String)?.hasPrefix("solo_") == true)
        #expect(meta(row)["experiment_eligible"] as? Bool == false)
        #expect(meta(row)["end_reason"] as? String == "silent for 20 s")
    }

    @Test func aDisabledWristbandMeansTheShockArmIsToastOnly() {
        let rig = CoachRig(mode: .pavlokShock)
        rig.wearable.isEnabled = false
        rig.monologue(0, 34)
        rig.wait(20)
        #expect(rig.wearable.sent.isEmpty)
        let m = meta(rig.rows.first)
        #expect((m["treatment_settings"] as? [String: Any])?["cue_30"] as? String == "toast_only")
        #expect(rig.interventions.last?["detail"] as? String == "wristband feedback is off")
    }

    @Test func pausesStayInTheTurnAndLongGapsSplitIt() {
        let rig = CoachRig(mode: .baseline)
        rig.say(0, 4)
        rig.say(10, 14)            // 6 s breath: same turn
        rig.say(40, 44)            // 26 s gap: a new turn
        rig.wait(30)
        let rows = rig.rows
        #expect(rows.map { $0["turn_duration_sec"] as? Double } == [14, 4])
        #expect(rows.map { $0["words_spoken"] as? Int } == [20, 10])
    }

    @Test func lateRowsFromBeforeAHandoffDoNotReopenTheTurn() {
        let rig = CoachRig(mode: .baseline)
        rig.monologue(0, 8)
        rig.say(9, 10, speaker: .other)
        rig.say(6, 8)              // arrives late, spoken before the other person
        #expect(rig.coach.currentStreak == 0)
        rig.wait(30)
        #expect(rig.rows.count == 1)
    }

    @Test func resettingByHandWritesTheRowAtOnceWithoutAReward() {
        let rig = CoachRig(mode: .hapticVibe)
        rig.monologue(0, 12)
        rig.coach.resetStreak()
        #expect(rig.wearable.sent.isEmpty)
        let m = meta(rig.rows.first)
        #expect(m["reward_eligible"] as? Bool == true)
        #expect(m["reward_requested"] as? Bool == false)
    }

    @Test func aSettingsChangeDuringATurnIsFlagged() {
        let rig = CoachRig(mode: .pavlokShock)
        rig.monologue(0, 8)
        rig.settings.apply(CuePreset.all.first { $0.key == "both_vibe" }!)
        rig.monologue(8, 12)
        rig.say(13, 14, speaker: .other)
        #expect(meta(rig.rows.first)["settings_changed_during_turn"] as? Bool == true)
    }

    @Test func aShortCallPollOutageKeepsTheCallAndALongOneEndsIt() {
        let rig = CoachRig(mode: .clusterRandomized)
        let session = rig.coach.activeSessionId
        #expect(rig.coach.activeCallApp == "Zoom")
        rig.calls.next = .failed("timed out")
        rig.wait(60)
        #expect(rig.coach.activeCallApp == "Zoom")
        #expect(rig.coach.activeSessionId == session)
        rig.wait(61)
        #expect(rig.coach.activeCallApp == nil)
        #expect(rig.coach.activeSessionId.hasPrefix("solo_"))
    }

    @Test func theSessionAndItsArmSurviveARestart() {
        let rig = CoachRig(mode: .clusterRandomized)
        let session = rig.coach.activeSessionId
        let arm = rig.coach.arm
        let relaunched = rig.makeCoach()
        #expect(relaunched.activeSessionId == session)
        #expect(relaunched.activeCallApp == "Zoom")
        #expect(relaunched.arm == arm)
        relaunched.tick()   // the same call is still on: same session
        #expect(relaunched.activeSessionId == session)
        rig.settings.alertOnlyDuringCalls = false
        #expect(CoachSettings(defaults: rig.settings.defaults).alertOnlyDuringCalls == false)
    }
}
