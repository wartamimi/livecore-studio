import XCTest
@testable import LiveCoreCore

final class Release045Tests: XCTestCase {
    func testStreamQualitySources() {
        var s = ProductionSettings()
        s.video.bitrateKbps = 4500
        s.recording.bitrateKbps = 12000
        XCTAssertEqual(s.streamVideo.bitrateKbps, 4500)
        s.stream.qualitySource = .recording
        XCTAssertEqual(s.streamVideo.bitrateKbps, 12000)
        XCTAssertEqual(s.streamAudioKbps, s.recording.audioKbps)
        s.stream.qualitySource = .custom
        s.stream.customVideoKbps = 8000
        s.stream.customAudioKbps = 192
        XCTAssertEqual(s.streamVideo.bitrateKbps, 8000)
        XCTAssertEqual(s.streamAudioKbps, 192)
        // Old settings without the new keys decode to "same as Output".
        let old = #"{"serverURL":"rtmp://x","keychainAccount":"default","primaryName":"P","primaryEnabled":true,"autoReconnect":true}"#
        let st = try? JSONDecoder().decode(StreamSettings.self, from: Data(old.utf8))
        XCTAssertEqual(st?.qualitySource, .output)
    }

    func testTimerDisplayStates() {
        var c = TimerConfig(mode: .countdown, durationSeconds: 120)
        var st = TimerStyle(); st.warnSeconds = 60
        c.style = st
        XCTAssertEqual(TimerMath.display(c, elapsed: 10, secondsOfDay: 0).state, .normal)
        XCTAssertEqual(TimerMath.display(c, elapsed: 70, secondsOfDay: 0).state, .warning)
        XCTAssertEqual(TimerMath.display(c, elapsed: 130, secondsOfDay: 0).state, .finished)
        st.overtime = true; c.style = st
        let over = TimerMath.display(c, elapsed: 132, secondsOfDay: 0)
        XCTAssertEqual(over.state, .overtime)
        XCTAssertEqual(over.text, "−00:12")
        st.overtime = false; st.finishedText = "TIME"; c.style = st
        XCTAssertEqual(TimerMath.display(c, elapsed: 200, secondsOfDay: 0).text, "TIME")
        XCTAssertEqual(TimerMath.display(c, elapsed: 60, secondsOfDay: 0).fraction ?? -1, 0.5, accuracy: 1e-9)
        // Until a time of day, across midnight.
        XCTAssertEqual(TimerMath.untilTime(target: 3600, now: 86_000), 4000, accuracy: 1e-9)
        XCTAssertEqual(TimerMath.clock12(secondsOfDay: 13 * 3600 + 5 * 60, showSeconds: false), "1:05 PM")
        XCTAssertEqual(ProjectColor(hex: "#FF8000")?.hex, "#FF8000")
    }

    func testPreviewOverlayAnimates() {
        var ch = OverlayChannel(index: 1, source: InputID("t"), preset: .lowerThird, fadeDuration: 1)
        ch.animation = .slideFromLeft
        ch.setPreview(true, now: 10)
        XCTAssertEqual(ch.previewProgress(at: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(ch.previewProgress(at: 11), 1, accuracy: 1e-9)
        ch.setPreview(false, now: 11)
        XCTAssertEqual(ch.previewProgress(at: 11.5), 0.5, accuracy: 1e-9)
        XCTAssertFalse(ch.onPreview)
    }

    func testNewTextAnimationsSettle() {
        for a in [TextAnimation.shrink, .bounce] {
            let r = TextReveal(animation: a, delay: 0.05)
            XCTAssertEqual(r.scale(1), 1, accuracy: 1e-9)
            XCTAssertEqual(r.offset(1), 0, accuracy: 1e-9)
        }
    }
}
