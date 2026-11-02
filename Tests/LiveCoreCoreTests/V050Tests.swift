import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.50.0: Audio Monitor ring, ElevenLabs realtime protocol, advanced channel settings.
final class V050Tests: XCTestCase {
    func testAudioRingStartsNearLiveAndContinues() {
        var ring = RemoteAudioRing(sampleRate: 24_000, keepSeconds: 3, blockFrames: 512)
        for i in 0..<100 { ring.append([Int16](repeating: Int16(i), count: 1024)) }   // 512 frames each
        let first = ring.read(since: 0, startSeconds: 0.3)
        XCTAssertEqual(first.next, 100)
        // 0.3 s at 24 kHz = 7200 frames → 15 blocks of 512.
        XCTAssertEqual(first.pcm.count / 2, 15 * 512)
        XCTAssertEqual(first.pcm.last, 99)
        ring.append([Int16](repeating: 7, count: 1024))
        let next = ring.read(since: first.next)
        XCTAssertEqual(next.next, 101)
        XCTAssertEqual(next.pcm.count, 1024)
        XCTAssertEqual(ring.read(since: next.next).pcm.count, 0)
        // A listener far behind, or one from an older server, is moved to live.
        var small = RemoteAudioRing(sampleRate: 24_000, keepSeconds: 1, blockFrames: 512)   // 46 blocks
        for _ in 0..<100 { small.append([Int16](repeating: 1, count: 1024)) }
        XCTAssertEqual(small.read(since: 3).pcm.count / 2, 15 * 512)
        XCTAssertEqual(ring.read(since: 5000).next, 101)
        XCTAssertEqual(ring.read(since: UInt32.max).next, 101)
    }

    func testAudioRingBody() {
        let b = RemoteAudioRing.body(next: 258, sampleRate: 24_000, channels: 2, pcm: [1, -1])
        XCTAssertEqual(b.count, 16)
        XCTAssertEqual(Array(b[0..<4]), [2, 1, 0, 0])
        XCTAssertEqual(Array(b[12..<16]), [1, 0, 0xff, 0xff])
    }

    func testListenRoute() {
        func route(_ q: [String: String]) -> RemoteRoute { RemoteRouter.route(HTTPRequest(method: "GET", path: "/api/listen", query: q)) }
        XCTAssertEqual(route(["bus": "busB", "since": "12"]), .listen(bus: "busB", since: 12))
        XCTAssertEqual(route([:]), .listen(bus: "master", since: 0))
        XCTAssertEqual(route(["bus": "x"]), .badRequest("bus"))
        XCTAssertTrue(route([:]).needsPIN)
    }

    func testElevenLabsURLAndMessages() {
        let u = ElevenLabsRealtime.url(sampleRate: 16_000, languageCode: "id")!.absoluteString
        XCTAssertTrue(u.hasPrefix("wss://api.elevenlabs.io/v1/speech-to-text/realtime?"))
        XCTAssertTrue(u.contains("model_id=scribe_v2_realtime") && u.contains("audio_format=pcm_16000") && u.contains("language_code=id"))
        XCTAssertFalse(ElevenLabsRealtime.url(sampleRate: 16_000, languageCode: nil)!.absoluteString.contains("language_code"))
        XCTAssertEqual(ElevenLabsRealtime.sendRate(forMixRate: 48_000), 16_000)
        XCTAssertEqual(ElevenLabsRealtime.sendRate(forMixRate: 44_100), 44_100)
        XCTAssertNil(ElevenLabsRealtime.sendRate(forMixRate: 11_025))
        let msg = ElevenLabsRealtime.audioMessage(pcm: [1, -2], sampleRate: 16_000)
        let obj = try! JSONSerialization.jsonObject(with: Data(msg.utf8)) as! [String: Any]
        XCTAssertEqual(obj["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(obj["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(Data(base64Encoded: obj["audio_base_64"] as! String), Data([1, 0, 0xfe, 0xff]))
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"message_type":"partial_transcript","text":"halo"}"#), .partial("halo"))
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"message_type":"committed_transcript","text":"Halo semua."}"#), .committed("Halo semua."))
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"message_type":"auth_error","error":"bad key"}"#), .error(type: "auth_error", message: "bad key", fatal: true))
        XCTAssertEqual(ElevenLabsRealtime.parse(#"{"message_type":"rate_limited","error":"slow"}"#), .error(type: "rate_limited", message: "slow", fatal: false))
        XCTAssertEqual(ElevenLabsRealtime.parse("nope"), .other)
        XCTAssertEqual(ElevenLabsRealtime.downmix(left: [1, 1, 1, 0.5], right: [1, 1, 1, 0.5], factor: 3), [32767])
    }

    func testSubtitleStyleOldProjectsAndLanguage() throws {
        let old = try JSONDecoder().decode(SubtitleStyle.self, from: Data(#"{"locale":"en-US","allowServer":true,"fontSize":40,"maxLines":2,"boxOpacity":0.5,"bottomMargin":0.1}"#.utf8))
        XCTAssertEqual(old.provider, .apple)
        XCTAssertEqual(old.languageCode, "en")
        let e = SubtitleStyle.elevenLabs
        XCTAssertNil(e.languageCode)
        XCTAssertEqual(try JSONDecoder().decode(SubtitleStyle.self, from: JSONEncoder().encode(e)), e)
    }

    func testChannelLimiterAndLowPass() {
        let c = ChannelControls()
        c.limiterEnabled.value = true
        c.limiterCeilingDB.value = -6
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        var l = [Float](repeating: 0.9, count: 4800), r = l
        for _ in 0..<5 { l = [Float](repeating: 0.9, count: 4800); r = l; dsp.process(left: &l, right: &r, frames: 4800) }
        XCTAssertLessThanOrEqual(l.map(abs).max()!, AudioMath.dbToLinear(-6) + 0.001)
        XCTAssertGreaterThan(c.limiterReductionDB.value, 1)

        var p = ChannelEQ.Params()
        p.lowPassEnabled = true; p.lowPassHz = 2_000
        var eq = ChannelEQ(sampleRate: 48_000)
        eq.update(p)
        XCTAssertLessThan(eq.responseDB(at: 10_000), -20)
        XCTAssertGreaterThan(eq.responseDB(at: 200), -0.5)
    }

    func testAdvancedSettingsDecodeOptional() throws {
        let ch = try JSONDecoder().decode(ProjectAudioChannel.self, from: Data(#"{"name":"Mic","faderDB":0,"gainDB":0,"pan":0,"muted":false,"toProgram":true,"compressorEnabled":false,"compThresholdDB":-18,"compRatio":3,"gateEnabled":false,"gateThresholdDB":-50}"#.utf8))
        XCTAssertNil(ch.advanced)
    }
}
