import XCTest
@testable import LiveCoreCore

final class V051Tests: XCTestCase {
    func testMaskAndWaveMakeAdjustActiveAndRoundTrip() throws {
        var a = InputAdjust()
        XCTAssertTrue(a.isIdentity)
        a.wave.enabled = true
        XCTAssertFalse(a.isIdentity)
        a.wave.enabled = false
        a.mask.shape = .ellipse
        XCTAssertFalse(a.isIdentity)
        a.mask.shape = .imageLuma
        XCTAssertTrue(a.isIdentity, "image mask without a file is inactive")
        a.mask.imagePath = "/tmp/m.png"
        let back = try JSONDecoder().decode(InputAdjust.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        // Old projects without mask/wave still decode.
        let old = try JSONDecoder().decode(InputAdjust.self, from: Data("{\"brightness\":0.1}".utf8))
        XCTAssertEqual(old.mask, InputMask())
        XCTAssertFalse(old.wave.enabled)
    }

    func testMaskCoverage() {
        var m = InputMask()
        m.shape = .ellipse
        XCTAssertEqual(m.coverage(u: 0.5, v: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(m.coverage(u: 0.01, v: 0.01), 0, accuracy: 1e-9)
        m.invert = true
        XCTAssertEqual(m.coverage(u: 0.01, v: 0.01), 1, accuracy: 1e-9)
        var r = InputMask(); r.shape = .rectangle
        XCTAssertEqual(r.coverage(u: 0.12, v: 0.12), 1, accuracy: 1e-9)
        XCTAssertEqual(r.coverage(u: 0.05, v: 0.5), 0, accuracy: 1e-9)
    }

    func testTranscriptionAdvancedQuery() throws {
        var adv = TranscriptionAdvanced()
        let plain = ElevenLabsRealtime.url(sampleRate: 16_000, languageCode: nil)!.absoluteString
        XCTAssertEqual(ElevenLabsRealtime.url(sampleRate: 16_000, languageCode: nil, advanced: adv)!.absoluteString, plain)
        adv.commitStrategy = .turnPrediction
        adv.vadSilenceSecs = 1
        adv.noVerbatim = true
        adv.vocabulary = ["Munawar", " munawar ", "", "Tamimi"]
        adv.elevenKeyterms = true
        let u = ElevenLabsRealtime.url(sampleRate: 16_000, languageCode: "id", advanced: adv)!.absoluteString
        XCTAssertTrue(u.contains("commit_strategy=turn_prediction"))
        XCTAssertFalse(u.contains("commit_strategy=vad"))
        XCTAssertTrue(u.contains("vad_silence_threshold_secs=1.00"))
        XCTAssertTrue(u.contains("no_verbatim=true"))
        XCTAssertEqual(u.components(separatedBy: "keyterms=").count - 1, 2)
        var s = SubtitleStyle.elevenLabs
        s.advanced = adv
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data("{\"locale\":\"id-ID\"}".utf8))
        XCTAssertEqual(old.advanced, TranscriptionAdvanced())
    }
}
