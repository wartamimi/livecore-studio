import XCTest
@testable import LiveCoreCore

/// 0.54.0: SRT input (receiver + TS demuxer) and the DeckLink / SRT project model.
final class V054Tests: XCTestCase {
    /// LiveCore's own SRT caller sends to the SRT receiver (listener) in memory, with 10 % of the
    /// data packets lost on the way (deterministic, so the test is stable): every payload must come out once, in order.
    func testReceiverRecoversLossInOrder() {
        let rx = SRTReceiver(role: .listener, latencyMs: 120)
        let tx = SRTCaller(url: try! SRTURL.parse("srt://h:1?streamid=cam1&latency=80"), socketID: 7, initialSeq: 1000)
        var t = 0.0
        XCTAssertEqual(rx.start(now: t), [])
        var toRx = tx.connect(now: t)
        var toTx: [[UInt8]] = []
        var dataSeen = 0
        var sent: [[UInt8]] = [], got: [[UInt8]] = []
        var n = 0
        while t < 3 {
            for d in toRx {
                // Lose every 10th first transmission (retransmissions get through).
                if d[0] & 0x80 == 0, d[4] & 0x04 == 0 { dataSeen += 1; if dataSeen % 10 == 3 { continue } }
                toTx += rx.receive(d, now: t)
            }
            toRx = []
            for d in toTx { toRx += tx.receive(d, now: t) }
            toTx = []
            if tx.state == .connected, t < 2.5 {
                let p = [UInt8](repeating: UInt8(n & 0xFF), count: 1316) + [UInt8(n >> 8), UInt8(n & 0xFF)]
                if let d = tx.send(p, now: t) { toRx.append(d); sent.append(p); n += 1 }
            }
            toTx += rx.tick(now: t)
            toRx += tx.tick(now: t)
            got += rx.deliver(now: t).map(Array.init)
            t += 0.005
        }
        XCTAssertEqual(rx.state, .connected)
        XCTAssertEqual(rx.stats.peerStreamID, "cam1")
        XCTAssertEqual(rx.latencyMs, 120)
        XCTAssertGreaterThan(rx.stats.lostPackets, 0)
        XCTAssertEqual(rx.stats.droppedPackets, 0)
        XCTAssertEqual(got.count, sent.count)
        XCTAssertEqual(got, sent)
    }

    func testReceiverRejectsEncryptedCaller() {
        let rx = SRTReceiver(role: .listener)
        _ = rx.start(now: 0)
        let induction = SRTPacket.Handshake(version: 4, extensionField: 2, initialSeq: 5, type: SRTPacket.Handshake.induction, socketID: 9, cookie: 0)
        let r1 = rx.receive(SRTPacket.control(.handshake, timestamp: 0, dest: 0, cif: induction.encode()), now: 0)
        let cookie = SRTPacket.Handshake.decode(r1[0][16...])!.cookie
        var concl = SRTPacket.Handshake(version: 5, extensionField: 1, initialSeq: 5, type: SRTPacket.Handshake.conclusion, socketID: 9, cookie: cookie)
        concl.encryption = 2
        let r2 = rx.receive(SRTPacket.control(.handshake, timestamp: 0, dest: 0, cif: concl.encode()), now: 0.01)
        XCTAssertEqual(SRTPacket.Handshake.decode(r2[0][16...])!.type, 1011)
        if case .closed = rx.state {} else { XCTFail("should close") }
        rx.relisten(now: 1)
        XCTAssertEqual(rx.state, .listening)
    }

    /// What LiveCore's own TS muxer writes comes back out of the demuxer, split at random.
    func testDemuxerRoundTrip() {
        var mux = MPEGTSMuxer()
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F, 0xAB], pps: [UInt8] = [0x68, 0xCE, 0x3C, 0x80]
        let asc = AAC.audioSpecificConfig(sampleRate: 48_000, channels: 2)
        var stream: [UInt8] = []
        for i in 0..<10 {
            let slice: [UInt8] = [0x65] + [UInt8](repeating: UInt8(i), count: 3000)
            stream += mux.video(avcc: [0, 0, 0x0B, 0xB9] + slice, sps: sps, pps: pps, keyframe: i % 5 == 0, pts90k: UInt64(i * 3000))
            stream += mux.audio(aac: [UInt8](repeating: 0x21, count: 300), audioSpecificConfig: asc, pts90k: UInt64(i * 3000))
        }
        let d = MPEGTSDemuxer()
        var aus: [MPEGTSDemuxer.AccessUnit] = []
        var o = 0
        while o < stream.count {
            let k = min(stream.count - o, Int.random(in: 1...1500))
            aus += d.feed(stream[o..<(o + k)])
            o += k
        }
        aus += d.flush()
        XCTAssertEqual(d.videoCodec, .h264)
        XCTAssertEqual(d.audioCodec, .aac)
        let video = aus.filter { $0.codec == .h264 }, audio = aus.filter { $0.codec == .aac }
        XCTAssertEqual(video.count, 10)
        XCTAssertEqual(audio.count, 10)
        XCTAssertEqual(video.map { $0.pts! - Int64(MPEGTSMuxer.ptsOffset90k) }, (0..<10).map { Int64($0 * 3000) })
        let nals = AVC.splitAnnexB(video[0].data).map { AVC.nalType($0.first!) }
        XCTAssertEqual(nals, [9, 7, 8, 5])
        XCTAssertEqual(AVC.splitAnnexB(video[3].data).last.map(Array.init)?.count, 3001)
        let f = ADTS.frames(audio[0].data)
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].sampleRate, 48_000)
        XCTAssertEqual(f[0].channels, 2)
        XCTAssertEqual(f[0].payload.count, 300)
        XCTAssertEqual(f[0].audioSpecificConfig, asc)
        XCTAssertEqual(d.continuityErrors, 0)
        XCTAssertFalse(aus.contains { $0.damaged })
    }

    func testSRTInputConfig() throws {
        let l = ProjectSRTInput.parse("srt://0.0.0.0:9001?mode=listener&latency=300000")!
        XCTAssertEqual(l.mode, .listener)
        XCTAssertEqual(l.port, 9001)
        XCTAssertEqual(l.latencyMs, 300)
        XCTAssertEqual(l.displayName, "SRT :9001")
        let c = ProjectSRTInput.parse("srt://10.0.0.5:7000?streamid=cam%201")!
        XCTAssertEqual(c.mode, .caller)
        XCTAssertEqual(c.host, "10.0.0.5")
        XCTAssertEqual(c.streamID, "cam 1")
        XCTAssertNil(ProjectSRTInput.parse("rtmp://x"))
        XCTAssertEqual(ProjectSRTInput(mode: .caller, port: 9000).problem, .missingHost)
        XCTAssertEqual(ProjectSRTInput(port: 0).problem, .badPort)
        XCTAssertEqual(ProjectSRTInput(port: 9000).callerURL(host: "192.168.1.2"), "srt://192.168.1.2:9000?mode=caller&latency=200000")

        // Project files keep both new input kinds.
        let sources: [ProjectSource] = [.srt(c), .decklink(ProjectDeckLink(deviceName: "DeckLink Mini Recorder 4K", deviceIndex: 1,
                                                                             mode: 0x4870_3530, connection: "sdi"))]
        let data = try JSONEncoder().encode(sources)
        XCTAssertEqual(try JSONDecoder().decode([ProjectSource].self, from: data), sources)
        XCTAssertEqual(ProjectDeckLink.fourCC(0x4870_3530), "Hp50")
        XCTAssertEqual(ProjectDeckLink.connectionBit("hdmi"), 2)
        XCTAssertEqual(ProjectDeckLink.connectionBit(nil), 0)
    }
}
