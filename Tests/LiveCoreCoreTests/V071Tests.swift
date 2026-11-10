import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.71.0: backup stream failover, safe slate, auto-director, macro additions, teleprompter,
/// AI summary command, Web Controller prompter routes.
final class V071Tests: XCTestCase {
    let a = InputID("a"), b = InputID("b"), c = InputID("c"), slate = InputID("slate")

    // MARK: Backup stream

    func testFailoverSwitchesAfterTwoFailuresAndBack() {
        var f = StreamFailover(hasBackup: true)
        XCTAssertFalse(f.connectionFailed())
        XCTAssertTrue(f.connectionFailed())
        XCTAssertTrue(f.onBackup)
        f.connected()
        XCTAssertFalse(f.connectionFailed())
        XCTAssertTrue(f.connectionFailed())
        XCTAssertFalse(f.onBackup)
    }

    func testFailoverWithoutBackupNeverSwitches() {
        var f = StreamFailover(hasBackup: false)
        for _ in 0..<5 { XCTAssertFalse(f.connectionFailed()) }
        XCTAssertFalse(f.initialFailure())
        XCTAssertFalse(f.onBackup)
    }

    func testInitialFailureTriesBackupOnce() {
        var f = StreamFailover(hasBackup: true)
        XCTAssertTrue(f.initialFailure())
        XCTAssertTrue(f.onBackup)
        XCTAssertFalse(f.initialFailure())
    }

    func testBackupURLSettingDecodesFromOldSettings() throws {
        let old = try JSONDecoder().decode(StreamSettings.self, from: Data("{\"serverURL\":\"rtmp://x/app\"}".utf8))
        XCTAssertEqual(old.primaryBackupURL, "")
        var s = StreamSettings()
        s.primaryBackupURL = "rtmp://b.example/live2?backup=1"
        let back = try JSONDecoder().decode(StreamSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.primaryBackupURL, s.primaryBackupURL)
    }

    // MARK: Safe slate

    private func slateConfig() -> SafeSlateConfig {
        var c = SafeSlateConfig()
        c.enabled = true; c.slate = slate; c.delaySeconds = 2; c.returnSeconds = 3
        return c
    }

    func testSlateCutsInAfterDelayAndReturns() {
        var w = SafeSlateWatch()
        let cfg = slateConfig()
        var healthy = Set([a, slate])
        let h: (InputID) -> Bool = { healthy.contains($0) }
        XCTAssertEqual(w.update(now: 0, config: cfg, program: a, healthy: h), .none)
        healthy.remove(a)
        XCTAssertEqual(w.update(now: 1, config: cfg, program: a, healthy: { healthy.contains($0) }), .none)
        XCTAssertEqual(w.update(now: 2.5, config: cfg, program: a, healthy: { healthy.contains($0) }), .none)
        XCTAssertEqual(w.update(now: 3.1, config: cfg, program: a, healthy: { healthy.contains($0) }), .cutToSlate(slate, replacing: a))
        XCTAssertEqual(w.replaced, a)
        // Still lost: stays on the slate.
        XCTAssertEqual(w.update(now: 5, config: cfg, program: slate, healthy: { healthy.contains($0) }), .none)
        healthy.insert(a)
        XCTAssertEqual(w.update(now: 6, config: cfg, program: slate, healthy: { healthy.contains($0) }), .none)
        XCTAssertEqual(w.update(now: 9.1, config: cfg, program: slate, healthy: { healthy.contains($0) }), .returnTo(a))
        XCTAssertNil(w.replaced)
    }

    func testShortDropoutDoesNotTriggerAndOperatorTakeoverEndsSlate() {
        var w = SafeSlateWatch()
        let cfg = slateConfig()
        XCTAssertEqual(w.update(now: 0, config: cfg, program: a, healthy: { $0 != self.a }), .none)
        XCTAssertEqual(w.update(now: 1, config: cfg, program: a, healthy: { _ in true }), .none)
        XCTAssertEqual(w.update(now: 2.5, config: cfg, program: a, healthy: { $0 != self.a }), .none)   // timer restarted
        XCTAssertEqual(w.update(now: 4.6, config: cfg, program: a, healthy: { $0 != self.a }), .cutToSlate(slate, replacing: a))
        // The operator cuts to camera b: the slate watch lets go.
        XCTAssertEqual(w.update(now: 5, config: cfg, program: b, healthy: { $0 != self.a }), .none)
        XCTAssertNil(w.replaced)
    }

    func testNoSlateWhenSlateItselfIsDownOrDisabled() {
        var w = SafeSlateWatch()
        XCTAssertEqual(w.update(now: 0, config: slateConfig(), program: a, healthy: { _ in false }), .none)
        XCTAssertEqual(w.update(now: 10, config: slateConfig(), program: a, healthy: { _ in false }), .none)
        var off = slateConfig(); off.enabled = false
        XCTAssertEqual(w.update(now: 20, config: off, program: a, healthy: { _ in false }), .none)
    }

    // MARK: Auto-director

    private func directorConfig(wide: InputID? = nil) -> AutoDirectorConfig {
        var c = AutoDirectorConfig()
        c.enabled = true
        c.pairs = [.init(channel: "m1", input: a), .init(channel: "m2", input: b)]
        c.wideInput = wide
        c.thresholdDB = -40; c.talkSeconds = 0.8; c.minHoldSeconds = 4; c.silenceToWideSeconds = 8
        return c
    }

    func testDirectorCutsToSpeakerAfterTalkTimeAndHolds() {
        var d = AutoDirector()
        let cfg = directorConfig()
        var t = 10.0
        var cut: InputID?
        while t < 10.7 { cut = d.update(now: t, levelsDB: ["m2": -20, "m1": -70], program: a, config: cfg); XCTAssertNil(cut); t += 0.1 }
        cut = d.update(now: 10.9, levelsDB: ["m2": -20, "m1": -70], program: a, config: cfg)
        XCTAssertEqual(cut, b)
        // Speaker 1 starts at once: the shot is held for minHold.
        t = 11
        while t < 14.8 { XCTAssertNil(d.update(now: t, levelsDB: ["m1": -20], program: b, config: cfg)); t += 0.1 }
        XCTAssertEqual(d.update(now: 15, levelsDB: ["m1": -20], program: b, config: cfg), a)
    }

    func testDirectorIgnoresCoughsAndWaitsWhenOperatorTakesOver() {
        var d = AutoDirector()
        let cfg = directorConfig()
        XCTAssertNil(d.update(now: 10, levelsDB: ["m2": -20], program: a, config: cfg))
        XCTAssertNil(d.update(now: 10.3, levelsDB: ["m2": -20], program: a, config: cfg))
        XCTAssertNil(d.update(now: 10.8, levelsDB: [:], program: a, config: cfg))   // gap > hangover: talk ends
        XCTAssertNil(d.update(now: 11.0, levelsDB: ["m2": -20], program: a, config: cfg))
        XCTAssertNil(d.update(now: 11.5, levelsDB: ["m2": -20], program: a, config: cfg))
        // A video (input c) on Program: the director does nothing.
        XCTAssertNil(d.update(now: 13, levelsDB: ["m2": -20], program: c, config: cfg))
        XCTAssertEqual(d.update(now: 13.1, levelsDB: ["m2": -20], program: a, config: cfg), b)
    }

    func testDirectorWideShotForCrosstalkAndSilence() {
        var d = AutoDirector()
        let cfg = directorConfig(wide: c)
        XCTAssertNil(d.update(now: 10, levelsDB: ["m1": -20, "m2": -25], program: a, config: cfg))
        XCTAssertEqual(d.update(now: 11, levelsDB: ["m1": -20, "m2": -25], program: a, config: cfg), c)
        var d2 = AutoDirector()
        XCTAssertNil(d2.update(now: 100, levelsDB: [:], program: a, config: cfg))
        XCTAssertNil(d2.update(now: 107, levelsDB: [:], program: a, config: cfg))
        XCTAssertEqual(d2.update(now: 108.1, levelsDB: [:], program: a, config: cfg), c)
    }

    func testDirectorConfigPrunedAndSavedInProject() throws {
        var doc = ProjectDocument()
        doc.autoDirector = directorConfig(wide: c)
        doc.safeSlate = slateConfig()
        doc.teleprompter = TeleprompterScript(text: "Hello")
        let s = doc.sanitized()   // no inputs: every reference is dropped
        XCTAssertNil(s.autoDirector?.wideInput)
        XCTAssertTrue(s.autoDirector?.pairs.allSatisfy { $0.input == nil } ?? false)
        XCTAssertNil(s.safeSlate?.slate)
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.autoDirector, doc.autoDirector)
        XCTAssertEqual(back.teleprompter?.text, "Hello")
    }

    // MARK: Macros

    func testNestedMacrosExpandWithoutLoops() {
        var book = MacroBook()
        book.macros = [
            Macro(name: "one", steps: [MacroStep(.cut), MacroStep(.runMacro, macro: 2)]),
            Macro(name: "two", steps: [MacroStep(.auto), MacroStep(.runMacro, macro: 1), MacroStep(.runMacro, macro: 3)]),
            Macro(name: "three", steps: [MacroStep(.snapshot)]),
        ]
        let kinds = book.expandedSteps(of: book.macros[0]).map(\.kind)
        XCTAssertEqual(kinds, [.cut, .auto, .snapshot])   // 2 → 1 is a loop and is dropped
    }

    func testRunMacroConditionIsInheritedAndConditionsHold() {
        var book = MacroBook()
        let cond = MacroCondition(.programIs, input: a)
        book.macros = [
            Macro(name: "outer", steps: [MacroStep(.runMacro, macro: 2, condition: cond)]),
            Macro(name: "inner", steps: [MacroStep(.cut), MacroStep(.auto, condition: MacroCondition(.streaming))]),
        ]
        let steps = book.expandedSteps(of: book.macros[0])
        XCTAssertEqual(steps[0].condition, cond)
        XCTAssertEqual(steps[1].condition?.kind, .streaming)
        XCTAssertTrue(cond.holds(program: a, preview: nil, streaming: false, recording: false))
        XCTAssertFalse(cond.holds(program: b, preview: nil, streaming: false, recording: false))
        XCTAssertTrue(MacroCondition(.notRecording).holds(program: nil, preview: nil, streaming: false, recording: false))
        XCTAssertFalse(MacroStep(.cut, condition: MacroCondition(.programIs)).isComplete)
        XCTAssertFalse(MacroStep(.runMacro).isComplete)
        XCTAssertTrue(MacroStep(.runMacro, macro: 3).isComplete)
    }

    func testTimeTriggerMatchesNormalizedTime() {
        XCTAssertEqual(MacroTrigger.normalizedTime("7:5"), "07:05")
        XCTAssertEqual(MacroTrigger.normalizedTime("1900"), "19:00")
        XCTAssertEqual(MacroTrigger.normalizedTime("19.30"), "19:30")
        XCTAssertNil(MacroTrigger.normalizedTime("25:00"))
        XCTAssertNil(MacroTrigger.normalizedTime("abc"))
        let t = MacroTrigger(.timeOfDay, time: "7:00")
        XCTAssertTrue(t.matches(MacroEvent(.timeOfDay, time: "07:00")))
        XCTAssertFalse(t.matches(MacroEvent(.timeOfDay, time: "07:01")))
        XCTAssertFalse(MacroTrigger(.timeOfDay).matches(MacroEvent(.timeOfDay, time: "07:00")))
    }

    func testAudioFadeClampsAndDecodesOldMacros() throws {
        let s = MacroStep(.audioFade, channel: "m1", seconds: 500, level: -200)
        XCTAssertEqual(s.fadeSeconds, MacroStep.maxFade)
        XCTAssertEqual(s.fadeLevelDB, -90)
        XCTAssertFalse(MacroStep(.audioFade).isComplete)
        let old = try JSONDecoder().decode(MacroStep.self, from: Data("{\"id\":\"x\",\"kind\":\"cut\"}".utf8))
        XCTAssertNil(old.condition)
        XCTAssertNil(old.macro)
    }

    func testAIStepsAcceptFadeAndRunMacro() {
        let show = AIAgent.Show(inputs: [(1, a)], channels: [(id: "mic:1", name: "Mic 1")])
        let r = AIAgent.steps(from: ["steps": [["kind": "audioFade", "channel": "Mic 1", "level": -90, "seconds": 4],
                                               ["kind": "runMacro", "macro": 2]]], show: show, allowOutputs: false)
        guard case let .success(steps) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(steps[0].level, -90)
        XCTAssertEqual(steps[0].seconds, 4)
        XCTAssertEqual(steps[1].macro, 2)
        if case .success = AIAgent.steps(from: ["steps": [["kind": "runMacro"]]], show: show, allowOutputs: false) {
            XCTFail("runMacro without a number must fail")
        }
    }

    // MARK: Teleprompter

    func testTeleprompterSpeedFollowsWordsPerMinute() {
        var p = TeleprompterScript(text: Array(repeating: "kata", count: 280).joined(separator: " "))
        p.wpm = 140
        XCTAssertEqual(p.wordCount, 280)
        XCTAssertEqual(p.readingSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(p.advanced(0, by: 60), 0.5, accuracy: 0.0001)
        XCTAssertEqual(p.advanced(0.99, by: 60), 1)
        XCTAssertEqual(p.jumped(0.01, seconds: -5), 0)
        p.wpm = 10_000
        XCTAssertEqual(p.clampedWPM, TeleprompterScript.wpmRange.upperBound)
        XCTAssertEqual(TeleprompterScript().readingSeconds, 5)
    }

    func testRemotePrompterRoutesAndState() {
        func req(_ m: String, _ path: String, _ q: [String: String] = [:]) -> HTTPRequest {
            HTTPRequest(method: m, path: path, query: q, headers: [:], body: [])
        }
        XCTAssertEqual(RemoteRouter.route(req("GET", "/api/prompter")), .prompterText)
        XCTAssertTrue(RemoteRoute.prompterText.needsPIN)
        XCTAssertEqual(RemoteRouter.route(req("POST", "/api/prompter/cmd", ["do": "toggle"])), .command(.prompter(.toggle)))
        XCTAssertEqual(RemoteRouter.route(req("POST", "/api/prompter/cmd", ["do": "explode"])), .badRequest("do"))
        var s = RemoteState()
        s.prompterRev = 3; s.prompterPos = 0.25; s.prompterRunning = true
        XCTAssertTrue(s.json.contains("\"prompter\":{"))
        XCTAssertTrue(s.json.contains("\"rev\":3"))
        XCTAssertTrue(RemotePage.html.contains("/api/prompter/cmd"))
    }

    // MARK: AI summary

    func testSummaryCommandClipsLongTranscripts() {
        let long = String(repeating: "a", count: 100_000)
        let clipped = AIAgent.clippedTranscript(long)
        XCTAssertLessThanOrEqual(clipped.count, AIAgent.summaryMaxCharacters + 60)
        XCTAssertTrue(clipped.contains("left out"))
        XCTAssertEqual(AIAgent.clippedTranscript("short"), "short")
        let cmd = AIAgent.summaryCommand(.chapters, transcript: "[10:00:00] Halo")
        XCTAssertTrue(cmd.contains("YouTube chapters"))
        XCTAssertTrue(cmd.contains("[10:00:00] Halo"))
    }
}
