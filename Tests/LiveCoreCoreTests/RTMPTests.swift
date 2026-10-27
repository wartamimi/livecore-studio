import XCTest
@testable import LiveCoreCore

final class RTMPTests: XCTestCase {
    // MARK: URL
    func testURLParsing() throws {
        let yt = try RTMPURL.parse(serverURL: "rtmp://a.rtmp.youtube.com/live2", streamKey: " abcd-1234 ")
        XCTAssertEqual(yt.host, "a.rtmp.youtube.com"); XCTAssertEqual(yt.port, 1935)
        XCTAssertEqual(yt.app, "live2"); XCTAssertEqual(yt.streamKey, "abcd-1234")
        XCTAssertEqual(yt.tcUrl, "rtmp://a.rtmp.youtube.com/live2")

        let fb = try RTMPURL.parse(serverURL: "rtmps://live-api-s.facebook.com:443/rtmp/", streamKey: "FB-1")
        XCTAssertTrue(fb.useTLS); XCTAssertEqual(fb.port, 443); XCTAssertEqual(fb.app, "rtmp")
        XCTAssertEqual(fb.tcUrl, "rtmps://live-api-s.facebook.com/rtmp")

        let custom = try RTMPURL.parse(serverURL: "rtmp://10.0.0.5:1936/app/inst?token=x", streamKey: "k")
        XCTAssertEqual(custom.port, 1936); XCTAssertEqual(custom.app, "app/inst?token=x")
        XCTAssertEqual(custom.tcUrl, "rtmp://10.0.0.5:1936/app/inst?token=x")

        let embedded = try RTMPURL.parse(serverURL: "rtmp://host/live/mystream", streamKey: "")
        XCTAssertEqual(embedded.app, "live"); XCTAssertEqual(embedded.streamKey, "mystream")

        let v6 = try RTMPURL.parse(serverURL: "rtmp://[::1]:1940/live", streamKey: "k")
        XCTAssertEqual(v6.host, "::1"); XCTAssertEqual(v6.port, 1940)

        XCTAssertThrowsError(try RTMPURL.parse(serverURL: "http://x/live", streamKey: "k")) {
            XCTAssertEqual($0 as? RTMPURL.ParseError, .unsupportedScheme("http"))
        }
        XCTAssertThrowsError(try RTMPURL.parse(serverURL: "rtmp://host", streamKey: "k"))
        XCTAssertThrowsError(try RTMPURL.parse(serverURL: "rtmp://host:99999/live", streamKey: "k"))
        XCTAssertThrowsError(try RTMPURL.parse(serverURL: "rtmp://host/live", streamKey: ""))
    }

    // MARK: Chunking
    func testChunkRoundTripAcrossChunkSizesAndExtendedTimestamps() throws {
        for chunkSize in [1, 7, 128, 4096] {
            var w = RTMPChunkWriter(); w.setChunkSize(chunkSize)
            var r = RTMPChunkReader(); r.setChunkSize(chunkSize)
            let msgs = [
                RTMPMessage(type: .video, streamID: 1, timestamp: 33, payload: Array(repeating: 0xAB, count: 5000)),
                RTMPMessage(type: .audio, streamID: 1, timestamp: 0x0100_0000, payload: [1, 2, 3]),  // extended
                RTMPMessage(type: .commandAMF0, streamID: 0, timestamp: 0, payload: []),
                RTMPMessage(type: .video, streamID: 1, timestamp: 0xFF_FFFF, payload: Array(0..<255)), // boundary
            ]
            var wire: [UInt8] = []
            for (i, m) in msgs.enumerated() { wire += w.encode(m, chunkStreamID: UInt32(4 + i)) }
            // Feed in awkward slices to exercise partial-chunk handling.
            var out: [RTMPMessage] = []
            var i = 0
            while i < wire.count {
                let n = min(13, wire.count - i)
                r.feed(Array(wire[i..<i + n])); i += n
                while let m = try r.next() { out.append(m) }
            }
            XCTAssertEqual(out, msgs, "chunkSize \(chunkSize)")
        }
    }

    func testReaderHandlesFmt1Fmt2Fmt3Headers() throws {
        // Hand-built: fmt0 (ts 1000, len 2, type 9, sid 1), fmt1 (delta 40, len 1, type 8),
        // fmt2 (delta 10), fmt3 new message (re-use delta 10), on csid 6.
        var b: [UInt8] = []
        b += [0x06, 0x00, 0x03, 0xE8, 0x00, 0x00, 0x02, 0x09, 0x01, 0, 0, 0, 0xAA, 0xBB]
        b += [0x46, 0x00, 0x00, 0x28, 0x00, 0x00, 0x01, 0x08, 0xCC]
        b += [0x86, 0x00, 0x00, 0x0A, 0xDD]
        b += [0xC6, 0xEE]
        var r = RTMPChunkReader()
        r.feed(b)
        var got: [RTMPMessage] = []
        while let m = try r.next() { got.append(m) }
        XCTAssertEqual(got.map(\.timestamp), [1000, 1040, 1050, 1060])
        XCTAssertEqual(got.map(\.typeID), [9, 8, 8, 8])
        XCTAssertEqual(got.map(\.streamID), [1, 1, 1, 1])
        XCTAssertEqual(got.map(\.payload), [[0xAA, 0xBB], [0xCC], [0xDD], [0xEE]])
    }

    func testTwoByteChunkStreamID() throws {
        let w = RTMPChunkWriter()
        let wire = w.encode(RTMPMessage(type: .audio, streamID: 1, timestamp: 5, payload: [1]), chunkStreamID: 100)
        XCTAssertEqual(Array(wire.prefix(2)), [0x00, 36])
        var r = RTMPChunkReader(); r.feed(wire)
        XCTAssertEqual(try r.next()?.payload, [1])
    }

    func testReaderAppliesServerSetChunkSize() throws {
        var serverWriter = RTMPChunkWriter()
        var w = ByteWriter(); w.u32(4096)
        var wire = serverWriter.encode(RTMPMessage(type: .setChunkSize, payload: w.bytes), chunkStreamID: 2)
        serverWriter.setChunkSize(4096)
        wire += serverWriter.encode(RTMPMessage(type: .commandAMF0, payload: Array(repeating: 1, count: 3000)), chunkStreamID: 3)
        var r = RTMPChunkReader(); r.feed(wire)
        _ = try r.next()
        XCTAssertEqual(r.chunkSize, 4096)
        XCTAssertEqual(try r.next()?.payload.count, 3000)
    }

    // MARK: Session against a scripted in-memory server

    /// Minimal server side used only in tests.
    final class FakeServer {
        var reader = RTMPChunkReader()
        var writer = RTMPChunkWriter()
        var handshakeDone = false
        var buffer: [UInt8] = []
        var received: [RTMPMessage] = []
        var publishReply: AMF0Value = .object([("level", .string("status")), ("code", .string("NetStream.Publish.Start")),
                                               ("description", .string("ok"))])
        var connectReply = "_result"

        func receive(_ bytes: [UInt8]) throws -> [UInt8] {
            var out: [UInt8] = []
            if !handshakeDone {
                let before = buffer.count
                buffer += bytes
                if before < 1537 && buffer.count >= 1537 {
                    out += [3] + Array(repeating: 7, count: 1536) + Array(buffer[1..<1537]) // S0 S1 S2
                }
                if buffer.count >= 1537 + 1536 {             // C2 received
                    let rest = Array(buffer[(1537 + 1536)...])
                    handshakeDone = true
                    buffer = []
                    return out + (try receive(rest))
                }
                return out
            }
            reader.feed(bytes)
            while let m = try reader.next() {
                received.append(m)
                guard m.type == .commandAMF0, let v = try? AMF0.decodeAll(m.payload), let name = v.first?.stringValue else { continue }
                let tx = v[1]
                switch name {
                case "connect":
                    var ws = ByteWriter(); ws.u32(5_000_000)
                    out += writer.encode(RTMPMessage(type: .windowAckSize, payload: ws.bytes), chunkStreamID: 2)
                    var pb = ByteWriter(); pb.u32(5_000_000); pb.u8(2)
                    out += writer.encode(RTMPMessage(type: .setPeerBandwidth, payload: pb.bytes), chunkStreamID: 2)
                    var ping = ByteWriter(); ping.u16(6); ping.u32(1234)
                    out += writer.encode(RTMPMessage(type: .userControl, payload: ping.bytes), chunkStreamID: 2)
                    out += writer.encode(RTMPMessage(type: .commandAMF0, payload: AMF0.encode([.string(connectReply), tx, .null,
                        .object([("code", .string(connectReply == "_result" ? "NetConnection.Connect.Success" : "NetConnection.Connect.Rejected")),
                                 ("description", .string("Connection rejected for key sk_live_secret"))])])), chunkStreamID: 3)
                case "releaseStream":
                    out += writer.encode(RTMPMessage(type: .commandAMF0, payload: AMF0.encode([.string("_error"), tx, .null,
                        .object([("description", .string("not found"))])])), chunkStreamID: 3)
                case "createStream":
                    out += writer.encode(RTMPMessage(type: .commandAMF0, payload: AMF0.encode([.string("_result"), tx, .null, .number(7)])), chunkStreamID: 3)
                case "publish":
                    out += writer.encode(RTMPMessage(type: .commandAMF0, streamID: 7, payload: AMF0.encode([.string("onStatus"), .number(0), .null, publishReply])), chunkStreamID: 5)
                default: break
                }
            }
            return out
        }
    }

    private func run(_ session: RTMPPublishSession, _ server: FakeServer, initial: [RTMPPublishSession.Event]) throws -> [RTMPPublishSession.Event] {
        var all: [RTMPPublishSession.Event] = initial
        var pending = initial
        var guardCount = 0
        while !pending.isEmpty, guardCount < 50 {
            guardCount += 1
            var next: [RTMPPublishSession.Event] = []
            for case let .send(bytes) in pending {
                let reply = try server.receive(bytes)
                if !reply.isEmpty { next += try session.receive(reply) }
            }
            all += next; pending = next
        }
        return all
    }

    func testSessionReachesPublishingAndSendsMedia() throws {
        let url = try RTMPURL.parse(serverURL: "rtmp://localhost/live", streamKey: "sk_live_secret")
        let session = RTMPPublishSession(url: url, randomByte: { 0x5A })
        let server = FakeServer()
        let events = try run(session, server, initial: session.start())
        XCTAssertEqual(session.state, .publishing)
        XCTAssertEqual(session.streamID, 7)
        XCTAssertTrue(events.contains(.stateChanged(.publishing)))
        XCTAssertTrue(events.contains { if case let .status(s) = $0 { return s.contains("ignored") }; return false },
                      "releaseStream _error is tolerated")

        let cmds = server.received.compactMap { m -> String? in
            guard m.type == .commandAMF0 else { return nil }
            return (try? AMF0.decodeAll(m.payload))?.first?.stringValue
        }
        XCTAssertEqual(cmds, ["connect", "releaseStream", "FCPublish", "createStream", "publish"])
        let connect = try AMF0.decodeAll(server.received.first { $0.type == .commandAMF0 }!.payload)
        XCTAssertEqual(connect[2]["tcUrl"]?.stringValue, "rtmp://localhost/live")
        XCTAssertFalse(server.received.contains { $0.type == .commandAMF0 && String(decoding: $0.payload, as: UTF8.self).contains("tcUrl") && String(decoding: $0.payload, as: UTF8.self).contains("sk_live_secret") },
                       "stream key never in connect/tcUrl")
        XCTAssertTrue(server.received.contains { $0.type == .userControl && $0.payload == [0, 7, 0, 0, 0x04, 0xD2] }, "ping answered")
        XCTAssertTrue(server.received.contains { $0.type == .windowAckSize }, "peer bandwidth answered")
        XCTAssertEqual(server.received.first { $0.type == .commandAMF0 && (try? AMF0.decodeAll($0.payload))?.first?.stringValue == "publish" }?.streamID, 7)

        // Media after publishing is parsed by the server with the negotiated 4096 chunk size.
        server.reader.setChunkSize(4096)
        let body = FLV.avcVideoBody(keyframe: true, sequenceHeader: false, data: Array(repeating: 1, count: 10_000))
        _ = try server.receive(try session.videoPacket(body: body, timestampMs: 66))
        let last = server.received.last!
        XCTAssertEqual(last.type, .video); XCTAssertEqual(last.timestamp, 66); XCTAssertEqual(last.payload, body); XCTAssertEqual(last.streamID, 7)

        let closing = session.close()
        XCTAssertEqual(session.state, .closed)
        guard case let .send(bytes) = closing.first else { return XCTFail("expected FCUnpublish/deleteStream") }
        _ = try server.receive(bytes)
        XCTAssertEqual(server.received.suffix(2).compactMap { (try? AMF0.decodeAll($0.payload))?.first?.stringValue }, ["FCUnpublish", "deleteStream"])
    }

    func testVideoBeforePublishingThrows() throws {
        let session = RTMPPublishSession(url: try RTMPURL.parse(serverURL: "rtmp://h/live", streamKey: "k123"))
        XCTAssertThrowsError(try session.videoPacket(body: [1], timestampMs: 0))
    }

    func testPublishRejectedFailsWithScrubbedReason() throws {
        let url = try RTMPURL.parse(serverURL: "rtmp://localhost/live", streamKey: "sk_live_secret")
        let session = RTMPPublishSession(url: url)
        let server = FakeServer()
        server.publishReply = .object([("level", .string("error")), ("code", .string("NetStream.Publish.BadName")),
                                       ("description", .string("Stream sk_live_secret already publishing"))])
        _ = try run(session, server, initial: session.start())
        guard case let .failed(reason) = session.state else { return XCTFail("expected failure, got \(session.state)") }
        XCTAssertTrue(reason.contains("BadName"))
        XCTAssertFalse(reason.contains("sk_live_secret"), "stream key must be scrubbed: \(reason)")
    }

    func testConnectRejectedFails() throws {
        let session = RTMPPublishSession(url: try RTMPURL.parse(serverURL: "rtmp://localhost/live", streamKey: "sk_live_secret"))
        let server = FakeServer(); server.connectReply = "_error"
        _ = try run(session, server, initial: session.start())
        guard case let .failed(reason) = session.state else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix("Server rejected connect"))
        XCTAssertFalse(reason.contains("sk_live_secret"))
    }

    func testBadHandshakeVersionFails() throws {
        let session = RTMPPublishSession(url: try RTMPURL.parse(serverURL: "rtmp://h/live", streamKey: "k123"))
        _ = session.start()
        _ = try session.receive([6] + Array(repeating: 0, count: 1536))
        guard case .failed = session.state else { return XCTFail() }
    }

    // MARK: Output queue
    func testOutputQueueDropsNonKeyVideoUnderCongestion() {
        var q = StreamOutputQueue(maxQueuedMs: 1000)
        q.enqueue(.init(kind: .video(keyframe: true), timestampMs: 0, body: [1]))
        for i in 1...30 { q.enqueue(.init(kind: .video(keyframe: false), timestampMs: UInt32(i * 33), body: [2])) }
        q.enqueue(.init(kind: .audio, timestampMs: 500, body: [3]))
        XCTAssertEqual(q.droppedVideoFrames, 0)
        q.enqueue(.init(kind: .video(keyframe: false), timestampMs: 1100, body: [2]))   // exceeds 1000 ms
        XCTAssertEqual(q.droppedVideoFrames, 32, "all queued video discarded")
        q.enqueue(.init(kind: .video(keyframe: false), timestampMs: 1133, body: [2]))
        XCTAssertEqual(q.droppedVideoFrames, 33, "waits for keyframe")
        q.enqueue(.init(kind: .video(keyframe: true), timestampMs: 1166, body: [1]))
        q.enqueue(.init(kind: .video(keyframe: false), timestampMs: 1200, body: [2]))
        XCTAssertEqual(q.packets.filter { $0.kind == .audio }.count, 1, "audio kept")
        XCTAssertEqual(q.packets.map(\.timestampMs), [500, 1166, 1200])
        XCTAssertEqual(q.droppedVideoFrames, 33)
        XCTAssertEqual(q.dequeue()?.timestampMs, 500)
    }
}
