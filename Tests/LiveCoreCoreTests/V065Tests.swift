import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.65.0: macros & triggers, gain-sharing auto mixer.
final class V065Tests: XCTestCase {
    // MARK: Auto mixer

    func testOneTalkerWinsQuietMicsGoDown() {
        let talk: Float = 0.01      // -20 dBFS power
        let room: Float = 1e-6      // -60 dBFS
        let g = AutoMixer.gains(powers: [talk, room, room, room])
        XCTAssertGreaterThan(AudioMath.linearToDB(g[0]), -0.1)
        for k in 1...3 { XCTAssertLessThan(AudioMath.linearToDB(g[k]), -19) }
    }

    func testEqualTalkersShareAndPowerIsConstant() {
        let g = AutoMixer.gains(powers: [0.01, 0.01])
        XCTAssertEqual(AudioMath.linearToDB(g[0]), -3.01, accuracy: 0.05)
        // Sum of power gains = 1 (one open microphone).
        let g4 = AutoMixer.gains(powers: [0.01, 0.002, 0.0005, 0])
        XCTAssertEqual(g4.map { $0 * $0 }.reduce(0, +), 1, accuracy: 0.001)
    }

    func testSilentGroupSharesEquallyAndSingleChannelUntouched() {
        let g = AutoMixer.gains(powers: [0, 0, 0, 0])
        for v in g { XCTAssertEqual(AudioMath.linearToDB(v), -6.02, accuracy: 0.05) }
        XCTAssertEqual(AutoMixer.gains(powers: [0.5]), [1])
    }

    func testWeightFavoursChannel() {
        let g = AutoMixer.gains(powers: [0.01, 0.01], weightsDB: [6, 0])
        XCTAssertGreaterThan(g[0], g[1])
        let clamped = AutoMixer.weighted(1, weightDB: 99)
        XCTAssertEqual(clamped, (1 + AutoMixer.floorPower) * powf(10, 1.2), accuracy: 0.01)
    }

    func testDetectorAttacksFastReleasesSlowly() {
        var env: Float = 0
        for _ in 0..<5 { env = AutoMixer.smooth(env, power: 1, seconds: 0.01) }
        XCTAssertGreaterThan(env, 0.99)
        env = AutoMixer.smooth(env, power: 0, seconds: 0.01)
        XCTAssertGreaterThan(env, 0.9)
        XCTAssertEqual(AutoMixer.smooth(0.5, power: .nan, seconds: 0.01), 0.5 * expf(-0.01 / 0.15), accuracy: 1e-4)
    }

    func testStripAppliesAutoMixTargetAndMeasuresPower() {
        let c = ChannelControls()
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        let n = 480
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        func block() { for i in 0..<n { l[i] = 0.5; r[i] = 0.5 } ; dsp.process(left: l, right: r, frames: n) }
        block()
        XCTAssertEqual(dsp.autoMixPower, 0.25, accuracy: 1e-4)
        dsp.autoMixTarget = 0.5
        block(); block()
        XCTAssertEqual(l[n - 1], 0.25, accuracy: 1e-3)
        c.muted.value = true
        block()
        XCTAssertEqual(dsp.autoMixPower, 0)
    }

    // MARK: Macros & triggers

    func testTriggerMatching() {
        let a = InputID("a"), b = InputID("b")
        let m1 = Macro(name: "On A", steps: [MacroStep(.audioOn, channel: "mic1")], triggers: [MacroTrigger(.programIn, input: a)])
        let m2 = Macro(name: "Any end", steps: [MacroStep(.transition, input: b)], triggers: [MacroTrigger(.videoEnded)])
        let m3 = Macro(name: "Off", triggers: [MacroTrigger(.programIn, input: a, enabled: false)])
        let book = MacroBook([m1, m2, m3])
        XCTAssertEqual(book.macros(for: MacroEvent(.programIn, input: a)).map(\.name), ["On A"])
        XCTAssertTrue(book.macros(for: MacroEvent(.programIn, input: b)).isEmpty)
        XCTAssertEqual(book.macros(for: MacroEvent(.videoEnded, input: a)).map(\.name), ["Any end"])
        XCTAssertEqual(book.macro(number: 2)?.name, "Any end")
        XCTAssertNil(book.macro(number: 4))
    }

    func testSwitchingEvents() {
        let a = InputID("a"), b = InputID("b")
        let e = MacroEvent.switching(oldProgram: a, newProgram: b, oldPreview: b, newPreview: a)
        XCTAssertEqual(e, [MacroEvent(.programOut, input: a), MacroEvent(.programIn, input: b), MacroEvent(.previewIn, input: a)])
        XCTAssertTrue(MacroEvent.switching(oldProgram: a, newProgram: a, oldPreview: b, newPreview: b).isEmpty)
    }

    func testStepCompletenessAndWaitClamp() {
        XCTAssertFalse(MacroStep(.transition).isComplete)
        XCTAssertTrue(MacroStep(.transition, input: InputID("x")).isComplete)
        XCTAssertFalse(MacroStep(.overlayOn, overlay: 7).isComplete)
        XCTAssertFalse(MacroStep(.audioOff, channel: "").isComplete)
        XCTAssertEqual(MacroStep(.wait, seconds: -3).waitSeconds, 0)
        XCTAssertEqual(MacroStep(.wait, seconds: 1e9).waitSeconds, MacroStep.maxWait)
        XCTAssertTrue(MacroStepKind.auto.runsTransition)
    }

    func testProjectRoundTripDropsUnknownStepsAndPrunes() throws {
        let a = InputID("a")
        var doc = ProjectDocument()
        doc.inputs = [ProjectInput(id: a, name: "A", source: .colorBars)]
        doc.macros = MacroBook([Macro(name: "M", steps: [MacroStep(.program, input: InputID("gone")), MacroStep(.cut)],
                                      triggers: [MacroTrigger(.programIn, input: InputID("gone"))])])
        let data = try JSONEncoder().encode(doc)
        var json = String(decoding: data, as: UTF8.self)
        json = json.replacingOccurrences(of: "\"kind\":\"cut\"", with: "\"kind\":\"teleport\"")
        let back = try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8)).sanitized()
        let m = try XCTUnwrap(back.macros?.macros.first)
        XCTAssertEqual(m.steps.count, 1)
        XCTAssertNil(m.steps[0].input)
        XCTAssertFalse(m.triggers[0].enabled)
    }

    func testTriggerGuardStopsLoops() {
        var g = MacroTriggerGuard()
        var allowed = 0
        for k in 0..<50 where g.allow(now: Double(k) * 0.05) { allowed += 1 }
        XCTAssertEqual(allowed, g.limit)
        XCTAssertTrue(g.tripped)
        XCTAssertFalse(g.allow(now: 100))
        g.rearm()
        XCTAssertTrue(g.allow(now: 100))
    }

    func testControlSurfacesReachMacros() {
        XCTAssertTrue(ControlAction.catalog.contains(.macro(16)))
        XCTAssertEqual(ShortcutAction(id: "macro.3"), .macro(3))
        XCTAssertEqual(ShortcutAction.macro(3).group, .macros)
        if case let .command(.action(a)) = RemoteRouter.route(HTTPRequest(method: "POST", path: "/api/macro", query: ["n": "2"])) {
            XCTAssertEqual(a, .macro(2))
        } else { XCTFail("route") }
        if case .badRequest = RemoteRouter.route(HTTPRequest(method: "POST", path: "/api/macro", query: ["n": "99"])) {} else { XCTFail("range") }
        var s = RemoteState()
        s.macros = [.init(number: 1, name: "Open", running: true)]
        XCTAssertTrue(s.json.contains("\"macros\":[{\"n\":1,\"name\":\"Open\",\"running\":true}]"))
        XCTAssertTrue(RemotePage.html.contains("/api/macro?n="))
    }
}
