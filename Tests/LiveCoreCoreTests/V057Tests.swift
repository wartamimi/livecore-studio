import XCTest
@testable import LiveCoreCore

final class V057Tests: XCTestCase {
    func testGroqProviderAndAdvancedRoundTrip() throws {
        var s = SubtitleStyle.elevenLabs
        s.provider = .groq
        s.advanced.groqModel = "whisper-large-v3-turbo"
        s.advanced.groqMaxChunk = 12
        let back = try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.provider, .groq)
        XCTAssertEqual(back.advanced.groqModel, "whisper-large-v3-turbo")
        XCTAssertEqual(back.advanced.groqMaxChunk, 12)
        // Older projects have no Groq fields.
        let old = try JSONDecoder().decode(TranscriptionAdvanced.self, from: Data("{}".utf8))
        XCTAssertEqual(old.groqModel, "whisper-large-v3")
        XCTAssertEqual(old.groqMaxChunk, 8)
    }

    func testWavHeaderAndMultipart() {
        let wav = GroqTranscription.wav(pcm: [0, 1, -1, 32767], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav[24], 0x80); XCTAssertEqual(wav[25], 0x3e)   // 16000 little-endian
        let f = GroqTranscription.fields(model: "whisper-large-v3", languageCode: "id", vocabulary: ["LiveCore", "Jakarta"])
        XCTAssertTrue(f.contains { $0 == ("language", "id") })
        XCTAssertTrue(f.contains { $0 == ("prompt", "LiveCore, Jakarta") })
        XCTAssertFalse(GroqTranscription.fields(model: "m", languageCode: nil, vocabulary: []).contains { $0.0 == "language" || $0.0 == "prompt" })
        let body = String(decoding: GroqTranscription.multipart(boundary: "B", fields: f, wav: Data("W".utf8)), as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n"))
        XCTAssertTrue(body.contains("filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\nW\r\n--B--\r\n"))
    }

    func testParseAnswerErrorsAndHallucinations() {
        XCTAssertEqual(GroqTranscription.parseText(Data(#"{"text":" Selamat pagi","x_groq":{}}"#.utf8)), " Selamat pagi")
        XCTAssertEqual(GroqTranscription.errorText(Data(#"{"error":{"message":"Invalid API Key","type":"invalid_request_error"}}"#.utf8)), "Invalid API Key")
        XCTAssertTrue(GroqTranscription.isHallucination(" Terima kasih."))
        XCTAssertTrue(GroqTranscription.isHallucination("Thank you!"))
        XCTAssertFalse(GroqTranscription.isHallucination("Terima kasih atas kehadirannya"))
    }

    func testSegmenterCutsAtPauseDropsSilenceAndCapsLength() {
        let rate = 1_000
        var seg = GroqSegmenter(sampleRate: rate, minSecs: 2, maxSecs: 8, pauseSecs: 0.5)
        let loud = [Float](repeating: 0.2, count: rate), quiet = [Float](repeating: 0, count: rate)
        XCTAssertTrue(seg.append(quiet + quiet + quiet).isEmpty, "silence alone is never sent")
        XCTAssertLessThanOrEqual(seg.bufferedSeconds, 0.31)
        var pieces = seg.append(loud + loud)
        XCTAssertTrue(pieces.isEmpty)
        pieces = seg.append(quiet)
        XCTAssertEqual(pieces.count, 1, "cut at the first pause after 2 s")
        XCTAssertLessThan(Double(pieces[0].count) / Double(rate), 3.0)
        XCTAssertNil(seg.flush())
        // Speech without pauses is cut at maxSecs.
        pieces = seg.append([Float](repeating: 0.2, count: rate * 10))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].count, rate * 8)
        XCTAssertNotNil(seg.flush())
    }

    func testTranscriptJoin() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let t = Date(timeIntervalSince1970: 3_723)   // 01:02:03
        let lines = [TranscriptLine(time: t, text: "Halo"), TranscriptLine(time: t, text: "semua")]
        XCTAssertEqual(TranscriptLine.join(lines, timestamps: false), "Halo\nsemua")
        XCTAssertEqual(TranscriptLine.join(lines, timestamps: true, calendar: cal), "[01:02:03] Halo\n[01:02:03] semua")
    }
}
