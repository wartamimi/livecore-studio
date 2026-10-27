import XCTest
@testable import LiveCoreCore

final class MediaTests: XCTestCase {
    func testAMF0RoundTrip() throws {
        let values: [AMF0Value] = [
            .string("connect"), .number(1),
            .object([("app", .string("live")), ("fpad", .boolean(false)), ("n", .null)]),
            .ecmaArray([("width", .number(1920))]), .strictArray([.number(1), .string("x")]), .undefined,
        ]
        let bytes = AMF0.encode(values)
        XCTAssertEqual(Array(bytes.prefix(10)), [0x02, 0x00, 0x07] + Array("connect".utf8))
        XCTAssertEqual(try AMF0.decodeAll(bytes), values)
        XCTAssertEqual(values[2]["app"]?.stringValue, "live")
    }

    func testAMF0KnownEncodingOfNumber() {
        XCTAssertEqual(AMF0.encode([.number(1)]), [0x00, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0])
    }

    func testAMF0RejectsTruncated() {
        XCTAssertThrowsError(try AMF0.decodeAll([0x02, 0x00, 0x05, 0x61]))
    }

    func testAnnexBSplitAndAVCC() throws {
        let stream: [UInt8] = [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F, 0xAA,  // SPS
                               0, 0, 1, 0x68, 0xEE,                      // PPS (3-byte start code)
                               0, 0, 0, 1, 0x65, 0x88, 0x00, 0x00]       // IDR with trailing zeros kept? (part of data)
        let nals = AVC.splitAnnexB(stream)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual(Array(nals[0]), [0x67, 0x64, 0x00, 0x1F, 0xAA])
        XCTAssertEqual(Array(nals[1]), [0x68, 0xEE])
        XCTAssertEqual(AVC.nalType(nals[2].first!), 5)
        let avcc = AVC.avcc(from: nals)
        XCTAssertEqual(Array(avcc.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(try AVC.splitAVCC(avcc).map(Array.init), nals.map(Array.init))
    }

    func testDecoderConfigurationRecord() {
        let sps: [UInt8] = [0x67, 0x4D, 0x40, 0x1F, 0x01]
        let pps: [UInt8] = [0x68, 0xEB]
        let rec = AVC.decoderConfigurationRecord(sps: sps, pps: pps)
        XCTAssertEqual(rec, [1, 0x4D, 0x40, 0x1F, 0xFF, 0xE1, 0, 5] + sps + [1, 0, 2] + pps)
        let high = AVC.decoderConfigurationRecord(sps: [0x67, 100, 0, 40], pps: pps)
        XCTAssertEqual(high.suffix(4), [0xFD, 0xF8, 0xF8, 0], "High profile extension")
    }

    func testSPSDimensions() {
        // SPS from x264 1280x720 High profile (generated with ffmpeg -c:v libx264 -s 1280x720).
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50, 0x05, 0xBB, 0x01, 0x10, 0x00,
                            0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x83, 0x19, 0x60]
        XCTAssertEqual(AVC.spsDimensions(sps), PixelSize(width: 1280, height: 720))
        // Main profile 1920x1080 (coded 1088, cropped by 8 lines) — exercises frame cropping.
        let sps1080: [UInt8] = [0x67, 0x4D, 0x40, 0x28, 0xEC, 0xA0, 0x3C, 0x01, 0x13, 0xF2, 0xE0, 0x22, 0x00, 0x00,
                                0x03, 0x00, 0x02, 0x00, 0x00, 0x03, 0x00, 0x78, 0x1E, 0x30, 0x63, 0x2C]
        XCTAssertEqual(AVC.spsDimensions(sps1080), PixelSize(width: 1920, height: 1080))
    }

    func testAACConfigAndADTS() throws {
        XCTAssertEqual(AAC.audioSpecificConfig(sampleRate: 48000, channels: 2), [0x11, 0x90])
        XCTAssertEqual(AAC.audioSpecificConfig(sampleRate: 44100, channels: 2), [0x12, 0x10])
        // Two ADTS frames: 48 kHz stereo LC, protection absent, payload 3 and 2 bytes.
        func adts(_ payload: [UInt8]) -> [UInt8] {
            let len = payload.count + 7
            return [0xFF, 0xF1, 0x4C, 0x80 | UInt8((len >> 11) & 0x3), UInt8((len >> 3) & 0xFF), UInt8((len & 7) << 5) | 0x1F, 0xFC] + payload
        }
        let frames = try AAC.parseADTS(adts([1, 2, 3]) + adts([4, 5]))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].sampleRate, 48000); XCTAssertEqual(frames[0].channels, 2); XCTAssertEqual(frames[0].objectType, 2)
        XCTAssertEqual(Array(frames[1].payload), [4, 5])
        XCTAssertThrowsError(try AAC.parseADTS([0x00, 0x11, 0, 0, 0, 0, 0]))
    }

    func testFLVBodiesAndFileWriter() {
        XCTAssertEqual(FLV.avcVideoBody(keyframe: true, sequenceHeader: true, data: [9]), [0x17, 0, 0, 0, 0, 9])
        XCTAssertEqual(FLV.avcVideoBody(keyframe: false, sequenceHeader: false, cts: 40, data: [9]), [0x27, 1, 0, 0, 40, 9])
        XCTAssertEqual(FLV.aacAudioBody(sequenceHeader: false, data: [7]), [0xAF, 1, 7])
        var w = FLVFileWriter()
        XCTAssertEqual(w.bytes, [0x46, 0x4C, 0x56, 1, 5, 0, 0, 0, 9, 0, 0, 0, 0])
        w.appendTag(type: .audio, timestampMs: 0x0102_0304, body: [0xAF, 1, 7])
        let tag = Array(w.bytes.dropFirst(13))
        XCTAssertEqual(tag, [8, 0, 0, 3, 0x02, 0x03, 0x04, 0x01, 0, 0, 0, 0xAF, 1, 7, 0, 0, 0, 14])
        let meta = FLV.setDataFrameBody(FLV.Metadata(width: 1280, height: 720, frameRate: 30, videoBitrateKbps: 2500,
                                                    audioBitrateKbps: 128, audioSampleRate: 48000, audioChannels: 2))
        let decoded = try? AMF0.decodeAll(meta)
        XCTAssertEqual(decoded?.first?.stringValue, "@setDataFrame")
        XCTAssertEqual(decoded?[2]["width"]?.numberValue, 1280)
    }
}
