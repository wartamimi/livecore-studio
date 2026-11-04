import XCTest
@testable import LiveCoreCore

/// 0.37.0: SRT caller (handshake, ACK/NAK, timeouts) and the MPEG-TS muxer it carries.
final class SRTTests: XCTestCase {
    func testSRTURLParsing() throws {
        var u = try SRTURL.parse("srt://live.example.com:9000?streamid=%23!::r=live/abc,m=publish&latency=200")
        XCTAssertEqual(u.host, "live.example.com")
        XCTAssertEqual(u.port, 9000)
        XCTAssertEqual(u.streamID, "#!::r=live/abc,m=publish")
        XCTAssertEqual(u.latencyMs, 200)
        XCTAssertFalse(u.redacted.contains("abc"))
        u = try SRTURL.parse(" srt://10.0.0.2:7001 ", key: "secret-id")
        XCTAssertEqual(u.streamID, "secret-id")
        XCTAssertEqual(u.latencyMs, 120)
        XCTAssertEqual(try SRTURL.parse("srt://h:1?latency=2000000").latencyMs, 2000)   // ffmpeg µs
        XCTAssertEqual(try SRTURL.parse("srt://[::1]:9000").host, "::1")
        XCTAssertThrowsError(try SRTURL.parse("srt://host")) { XCTAssertEqual($0 as? SRTURL.ParseError, .missingPort) }
        XCTAssertThrowsError(try SRTURL.parse("srt://host:9000?passphrase=abcdefghij")) {
            XCTAssertEqual($0 as? SRTURL.ParseError, .encryptionNotSupported)
        }
        XCTAssertThrowsError(try SRTURL.parse("srt://host:9000?mode=listener"))
        XCTAssertThrowsError(try SRTURL.parse("rtmp://host/live"))
        XCTAssertTrue(SRTURL.isSRT("SRT://x:1"))
    }

    func testStreamIDBlockLayoutAndLossList() {
        let block = SRTPacket.streamIDBlock("abcde")
        XCTAssertEqual(block, [0x64, 0x63, 0x62, 0x61, 0, 0, 0, 0x65])
        XCTAssertEqual(SRTPacket.decodeStreamID(block), "abcde")
        let list = SRTPacket.encodeLossList([5, 6, 7, 9, 0x7FFF_FFFF, 0])
        XCTAssertEqual(SRTPacket.lossList(list[...]), [5, 6, 7, 9, 0x7FFF_FFFF, 0])
        XCTAssertTrue(SRTPacket.seqLess(0x7FFF_FFFE, 1))
        XCTAssertFalse(SRTPacket.seqLess(3, 3))
    }

    /// A minimal listener answering like libsrt.
    private func listenerReply(to d: [UInt8], cookie: UInt32 = 0xC0FFEE, hsrspLatency: UInt32 = 0) -> [UInt8]? {
        guard let hs = SRTPacket.Handshake.decode(d[16...]) else { return nil }
        let caller = hs.socketID
        if hs.type == SRTPacket.Handshake.induction {
            XCTAssertEqual(hs.version, 4)
            XCTAssertEqual(hs.extensionField, 2)
            let r = SRTPacket.Handshake(version: 5, extensionField: SRTPacket.Handshake.srtMagic, initialSeq: hs.initialSeq,
                                        type: SRTPacket.Handshake.induction, socketID: 777, cookie: cookie)
            return SRTPacket.control(.handshake, timestamp: 0, dest: caller, cif: r.encode())
        }
        XCTAssertEqual(hs.type, SRTPacket.Handshake.conclusion)
        XCTAssertEqual(hs.cookie, cookie)
        var r = SRTPacket.Handshake(version: 5, extensionField: 1, initialSeq: hs.initialSeq,
                                    type: SRTPacket.Handshake.conclusion, socketID: 777, cookie: 0)
        r.extensions = [(SRTPacket.Handshake.extHSRSP, SRTPacket.be32(0x0001_0500) + SRTPacket.be32(0x3B) + SRTPacket.be32(hsrspLatency))]
        return SRTPacket.control(.handshake, timestamp: 0, dest: caller, cif: r.encode())
    }

    func testHandshakeAckNakAndTimeouts() throws {
        let url = try SRTURL.parse("srt://h:9000?streamid=room1&latency=120")
        let c = SRTCaller(url: url, socketID: 42, initialSeq: 0x7FFF_FFFE)
        let induction = c.connect(now: 0)
        XCTAssertEqual(c.state, .induction)
        // Lost induction: resent after 250 ms.
        XCTAssertTrue(c.tick(now: 0.1).isEmpty)
        XCTAssertEqual(c.tick(now: 0.3).count, 1)
        let conclusion = c.receive(listenerReply(to: induction[0])!, now: 0.31)
        XCTAssertEqual(c.state, .conclusion)
        let hs = try XCTUnwrap(SRTPacket.Handshake.decode(conclusion[0][16...]))
        XCTAssertEqual(hs.extensionField, SRTPacket.Handshake.flagHSREQ | SRTPacket.Handshake.flagCONFIG)
        XCTAssertEqual(SRTPacket.decodeStreamID(hs.extensions.first { $0.0 == SRTPacket.Handshake.extSID }!.1), "room1")
        XCTAssertNil(c.send([1, 2, 3], now: 0.32))   // not connected yet
        _ = c.receive(listenerReply(to: conclusion[0], hsrspLatency: 400 << 16 | 400)!, now: 0.33)
        XCTAssertEqual(c.state, .connected)
        XCTAssertEqual(c.latencyMs, 400)
        XCTAssertEqual(c.peerSocketID, 777)

        // Three packets across the sequence wrap.
        let p = (0..<3).map { c.send([UInt8($0)], now: 0.4 + Double($0) / 100)! }
        XCTAssertEqual(p.map { SRTPacket.u32($0, 0) }, [0x7FFF_FFFE, 0x7FFF_FFFF, 0])
        XCTAssertEqual(SRTPacket.u32(p[0], 12), 777)
        XCTAssertEqual(SRTPacket.u32(p[1], 4) >> 30, 3)            // PP = single packet
        XCTAssertEqual(c.stats.unacknowledged, 3)
        // NAK for the middle one → retransmitted with R set.
        let nak = SRTPacket.control(.nak, timestamp: 0, dest: 42, cif: SRTPacket.encodeLossList([0x7FFF_FFFF]))
        let re = c.receive(nak, now: 0.5)
        XCTAssertEqual(re.count, 1)
        XCTAssertEqual(SRTPacket.u32(re[0], 0), 0x7FFF_FFFF)
        XCTAssertNotEqual(SRTPacket.u32(re[0], 4) & 0x0400_0000, 0)
        XCTAssertEqual(Array(re[0][16...]), [1])
        // Full ACK up to seq 0 (exclusive) → ACKACK with the same ACK number.
        let ack = SRTPacket.control(.ack, info: 9, timestamp: 0, dest: 42,
                                    cif: SRTPacket.be32(0) + SRTPacket.be32(2500) + [UInt8](repeating: 0, count: 20))
        let ackack = c.receive(ack, now: 0.6)
        XCTAssertEqual(ackack.count, 1)
        XCTAssertEqual(SRTPacket.u32(ackack[0], 0), 0x8006_0000)
        XCTAssertEqual(SRTPacket.u32(ackack[0], 4), 9)
        XCTAssertEqual(c.stats.unacknowledged, 1)
        XCTAssertEqual(c.stats.rttMs, 2.5)
        // Keep-alive after a second of silence; packets older than latency + 1 s are dropped.
        XCTAssertEqual(c.tick(now: 1.7).count, 1)
        XCTAssertEqual(c.tick(now: 1.9).count, 0)
        XCTAssertEqual(c.stats.dropped, 1)
        // Peer silent for 5 s → closed.
        _ = c.tick(now: 5.7)
        XCTAssertEqual(c.state, .closed("The SRT server stopped answering"))
    }

    func testRejectionAndNoAnswer() throws {
        let c = SRTCaller(url: SRTURL(host: "h", port: 1), socketID: 1, initialSeq: 0)
        let ind = c.connect(now: 0)
        _ = c.receive(listenerReply(to: ind[0])!, now: 0.01)
        var rej = SRTPacket.Handshake(version: 5, extensionField: 0, initialSeq: 0, type: 1016, socketID: 5, cookie: 0)
        rej.extensions = []
        _ = c.receive(SRTPacket.control(.handshake, timestamp: 0, dest: c.socketID, cif: rej.encode()), now: 0.02)
        XCTAssertEqual(c.state, .closed("The SRT server requires encryption (passphrase)"))
        let silent = SRTCaller(url: SRTURL(host: "h", port: 1), socketID: 2, initialSeq: 0)
        _ = silent.connect(now: 10)
        _ = silent.tick(now: 16)
        XCTAssertEqual(silent.state, .closed("No answer from the SRT server"))
    }

    func testTransportStreamPackets() {
        var m = MPEGTSMuxer()
        let asc = AAC.audioSpecificConfig(sampleRate: 48_000, channels: 2)
        let idr: [UInt8] = [0, 0, 0, 5, 0x65, 1, 2, 3, 4]
        let v = m.video(avcc: idr, sps: [0x67, 1], pps: [0x68, 2], keyframe: true, pts90k: 90_000)
        let a = m.audio(aac: [UInt8](repeating: 7, count: 400), audioSpecificConfig: asc, pts90k: 90_000)
        for out in [v, a] {
            XCTAssertEqual(out.count % 188, 0)
            for i in stride(from: 0, to: out.count, by: 188) { XCTAssertEqual(out[i], 0x47) }
        }
        // PAT, PMT, then video with PCR + random access.
        XCTAssertEqual(v.count, 3 * 188)
        let pat = Array(v[5..<17])
        XCTAssertEqual(SRTPacket.u32(Array(v[17..<21]), 0), MPEGTSMuxer.crc32(pat))
        XCTAssertEqual(UInt16(v[377] & 0x1F) << 8 | UInt16(v[378]), MPEGTSMuxer.videoPID)
        XCTAssertEqual(v[379] & 0x30, 0x30)               // adaptation + payload
        XCTAssertEqual(v[381] & 0x50, 0x50)               // random access + PCR
        let es = Array(v[(376 + 4 + Int(v[380]) + 1)...])
        XCTAssertEqual(Array(es.prefix(4)), [0, 0, 1, 0xE0])
        XCTAssertTrue(es.contains(0x67) && es.contains(0x65))
        // Audio PES: 2 packets for 400 + 7 + 14 bytes, ADTS sync inside.
        XCTAssertEqual(a.count, 3 * 188)
        XCTAssertEqual(MPEGTSMuxer.adtsHeader(asc: asc, payloadLength: 400), [0xFF, 0xF1, 0x4C, 0x80, 0x32, 0xFF, 0xFC])
        XCTAssertEqual(MPEGTSMuxer.crc32(Array("123456789".utf8)), 0x0376_E6E7)
        // Packing: full 1316-byte payloads, the rest on flush.
        var packer = SRTPayloadPacker()
        XCTAssertEqual(packer.add(v + a + v).map(\.count), [1316])
        XCTAssertEqual(packer.flush()?.count, 9 * 188 - 1316)
        XCTAssertNil(packer.flush())
    }
}
