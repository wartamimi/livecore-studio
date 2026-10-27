/// Sans-IO RTMP publishing client.
///
/// The session never touches sockets. A transport (Network.framework on macOS, POSIX sockets
/// in the CLI validation tool) feeds received bytes into `receive(_:)` and writes every
/// `.send` event to the wire, in order. This keeps protocol logic deterministic and testable.
///
/// Flow: C0+C1 -> (S0+S1) -> C2 -> (S2) -> SetChunkSize + connect -> _result
///       -> releaseStream, FCPublish, createStream -> _result(streamID)
///       -> publish(key, "live") -> onStatus NetStream.Publish.Start -> .publishing
public final class RTMPPublishSession {
    public enum State: Equatable, Sendable {
        case idle, handshaking, connecting, creatingStream, startingPublish, publishing, closed
        case failed(String)
    }

    public enum Event: Equatable, Sendable {
        case send([UInt8])
        case stateChanged(State)
        /// Informational server status (code, description) — already scrubbed of the stream key.
        case status(String)
    }

    public enum SessionError: Error, Equatable { case notPublishing, invalidState }

    // Chunk stream IDs
    static let csidControl: UInt32 = 2
    static let csidCommand: UInt32 = 3
    static let csidAudio: UInt32 = 4
    static let csidData: UInt32 = 5
    static let csidVideo: UInt32 = 6

    public let url: RTMPURL
    public let outgoingChunkSize: Int
    public private(set) var state: State = .idle
    public private(set) var streamID: UInt32 = 0
    public private(set) var bytesReceived: UInt64 = 0

    private var writer = RTMPChunkWriter()
    private var reader = RTMPChunkReader()
    private var handshakeBuffer: [UInt8] = []
    private var c1: [UInt8] = []
    private var handshakeStage = 0   // 0 = waiting S0+S1, 1 = waiting S2, 2 = done
    private var windowAckSize: UInt64 = 2_500_000
    private var lastAckSent: UInt64 = 0
    private var transactionID: Double = 0
    private var createStreamTx: Double = -1
    private var connectTx: Double = -1
    private let randomByte: () -> UInt8
    private let flashVer: String

    public init(url: RTMPURL, chunkSize: Int = 4096, flashVer: String = "FMLE/3.0 (compatible; LiveCoreStudio/0.1)",
                randomByte: @escaping () -> UInt8 = { UInt8.random(in: 0...255) }) {
        self.url = url
        self.outgoingChunkSize = chunkSize
        self.flashVer = flashVer
        self.randomByte = randomByte
    }

    // MARK: Outgoing

    /// Begins the handshake. Returns C0 + C1.
    public func start() -> [Event] {
        guard state == .idle else { return [] }
        var w = ByteWriter(reservingCapacity: 1537)
        w.u8(3)          // C0: RTMP version 3
        w.u32(0)         // C1 time
        w.u32(0)         // C1 zero
        c1 = (0..<1528).map { _ in randomByte() }
        w.append(c1)
        c1 = Array(w.bytes.dropFirst())
        return transition(.handshaking) + [.send(w.bytes)]
    }

    public func metadataPacket(_ metadata: FLV.Metadata) throws -> [UInt8] {
        guard state == .publishing else { throw SessionError.notPublishing }
        return writer.encode(RTMPMessage(type: .dataAMF0, streamID: streamID, timestamp: 0,
                                         payload: FLV.setDataFrameBody(metadata)), chunkStreamID: Self.csidData)
    }

    /// `body` is an FLV video tag body (see `FLV.avcVideoBody`). Timestamp in ms (DTS).
    public func videoPacket(body: [UInt8], timestampMs: UInt32) throws -> [UInt8] {
        guard state == .publishing else { throw SessionError.notPublishing }
        return writer.encode(RTMPMessage(type: .video, streamID: streamID, timestamp: timestampMs, payload: body),
                             chunkStreamID: Self.csidVideo)
    }

    public func audioPacket(body: [UInt8], timestampMs: UInt32) throws -> [UInt8] {
        guard state == .publishing else { throw SessionError.notPublishing }
        return writer.encode(RTMPMessage(type: .audio, streamID: streamID, timestamp: timestampMs, payload: body),
                             chunkStreamID: Self.csidAudio)
    }

    /// Polite shutdown: FCUnpublish + deleteStream. Transport should flush then close.
    public func close() -> [Event] {
        var out: [UInt8] = []
        if state == .publishing || state == .startingPublish {
            out += command("FCUnpublish", tx: nextTx(), args: [.null, .string(url.streamKey)])
            out += command("deleteStream", tx: nextTx(), args: [.null, .number(Double(streamID))])
        }
        var events = transition(.closed)
        if !out.isEmpty { events.insert(.send(out), at: 0) }
        return events
    }

    // MARK: Incoming

    public func receive(_ bytes: [UInt8]) throws -> [Event] {
        bytesReceived &+= UInt64(bytes.count)
        var events: [Event] = []
        var data = bytes
        if handshakeStage < 2 {
            handshakeBuffer += data
            data = []
            if handshakeStage == 0, handshakeBuffer.count >= 1 + 1536 {
                guard handshakeBuffer[0] == 3 else {
                    return fail("Server answered with unsupported RTMP version \(handshakeBuffer[0]).")
                }
                let s1 = Array(handshakeBuffer[1..<1537])
                handshakeBuffer.removeFirst(1537)
                handshakeStage = 1
                events.append(.send(s1))   // C2 = echo of S1
            }
            if handshakeStage == 1, handshakeBuffer.count >= 1536 {
                // S2 should echo C1; many servers send zeros/time instead, so we do not enforce it.
                handshakeBuffer.removeFirst(1536)
                handshakeStage = 2
                data = handshakeBuffer
                handshakeBuffer = []
                events += onHandshakeComplete()
            }
            if handshakeStage < 2 { return events }
        }
        reader.feed(data)
        while let msg = try reader.next() {
            events += handle(msg)
            if case .failed = state { return events }
        }
        if bytesReceived - lastAckSent >= windowAckSize {
            lastAckSent = bytesReceived
            var w = ByteWriter(); w.u32(UInt32(truncatingIfNeeded: bytesReceived))
            events.append(.send(writer.encode(RTMPMessage(type: .acknowledgement, payload: w.bytes), chunkStreamID: Self.csidControl)))
        }
        return events
    }

    /// Transport-level failure (socket closed, TLS error...). Moves the session to `.failed`.
    public func transportFailed(_ reason: String) -> [Event] {
        if case .closed = state { return [] }
        if case .failed = state { return [] }
        return transition(.failed(scrub(reason)))
    }

    // MARK: Private

    private func onHandshakeComplete() -> [Event] {
        var out: [UInt8] = []
        var w = ByteWriter(); w.u32(UInt32(outgoingChunkSize))
        out += writer.encode(RTMPMessage(type: .setChunkSize, payload: w.bytes), chunkStreamID: Self.csidControl)
        writer.setChunkSize(outgoingChunkSize)
        connectTx = nextTx()
        out += command("connect", tx: connectTx, args: [.object([
            ("app", .string(url.app)),
            ("type", .string("nonprivate")),
            ("flashVer", .string(flashVer)),
            ("tcUrl", .string(url.tcUrl)),
        ])])
        return transition(.connecting) + [.send(out)]
    }

    private func handle(_ msg: RTMPMessage) -> [Event] {
        switch msg.type {
        case .setChunkSize:
            return [] // applied inside the reader
        case .windowAckSize:
            var r = ByteReader(msg.payload)
            if let v = try? r.u32() { windowAckSize = UInt64(max(v, 1)) }
            return []
        case .setPeerBandwidth:
            var r = ByteReader(msg.payload)
            guard let v = try? r.u32() else { return [] }
            var w = ByteWriter(); w.u32(v)
            return [.send(writer.encode(RTMPMessage(type: .windowAckSize, payload: w.bytes), chunkStreamID: Self.csidControl))]
        case .userControl:
            var r = ByteReader(msg.payload)
            guard let ev = try? r.u16(), ev == 6, let ts = try? r.u32() else { return [] }
            var w = ByteWriter(); w.u16(7); w.u32(ts)  // PingResponse
            return [.send(writer.encode(RTMPMessage(type: .userControl, payload: w.bytes), chunkStreamID: Self.csidControl))]
        case .commandAMF0:
            guard let values = try? AMF0.decodeAll(msg.payload) else { return [] }
            return handleCommand(values)
        case .commandAMF3:
            // AMF3 command messages start with a 0x00 byte followed by AMF0 data.
            guard let values = try? AMF0.decodeAll(Array(msg.payload.dropFirst())) else { return [] }
            return handleCommand(values)
        default:
            return []
        }
    }

    private func handleCommand(_ values: [AMF0Value]) -> [Event] {
        guard let name = values.first?.stringValue else { return [] }
        let tx = values.count > 1 ? values[1].numberValue ?? 0 : 0
        switch name {
        case "_result":
            if tx == connectTx, state == .connecting {
                var out: [UInt8] = []
                out += command("releaseStream", tx: nextTx(), args: [.null, .string(url.streamKey)])
                out += command("FCPublish", tx: nextTx(), args: [.null, .string(url.streamKey)])
                createStreamTx = nextTx()
                out += command("createStream", tx: createStreamTx, args: [.null])
                return transition(.creatingStream) + [.send(out)]
            }
            if tx == createStreamTx, state == .creatingStream {
                let id = values.count > 3 ? values[3].numberValue ?? 1 : 1
                streamID = UInt32(max(0, id))
                let publish = command("publish", tx: nextTx(), args: [.null, .string(url.streamKey), .string("live")],
                                      streamID: streamID)
                return transition(.startingPublish) + [.send(publish)]
            }
            return []
        case "_error":
            let desc = describe(values)
            if tx == connectTx { return fail("Server rejected connect: \(desc)") }
            if tx == createStreamTx { return fail("Server rejected createStream: \(desc)") }
            return [.status("Server error (ignored): \(desc)")]   // releaseStream/FCPublish may legitimately fail
        case "onStatus":
            let info = values.count > 3 ? values[3] : (values.last ?? .null)
            let code = info["code"]?.stringValue ?? ""
            let level = info["level"]?.stringValue ?? ""
            let desc = scrub(info["description"]?.stringValue ?? "")
            if code == "NetStream.Publish.Start" {
                return transition(.publishing) + [.status(code)]
            }
            if level == "error" || code.hasSuffix(".BadName") || code.hasSuffix(".Failed")
                || code.hasSuffix(".Rejected") || code.hasSuffix(".Denied") {
                return fail("\(code) \(desc)")
            }
            return [.status("\(code) \(desc)")]
        case "close":
            return transition(.closed)
        default:
            return [] // onBWDone, onFCPublish, |RtmpSampleAccess ...
        }
    }

    private func command(_ name: String, tx: Double, args: [AMF0Value], streamID: UInt32 = 0) -> [UInt8] {
        let payload = AMF0.encode([.string(name), .number(tx)] + args)
        return writer.encode(RTMPMessage(type: .commandAMF0, streamID: streamID, payload: payload),
                             chunkStreamID: Self.csidCommand)
    }

    private func nextTx() -> Double { transactionID += 1; return transactionID }

    private func describe(_ values: [AMF0Value]) -> String {
        for v in values.dropFirst(2) {
            if let d = v["description"]?.stringValue { return scrub(d) }
            if let c = v["code"]?.stringValue { return scrub(c) }
        }
        return "no description"
    }

    private func scrub(_ s: String) -> String { Redaction.scrub(s, secrets: [url.streamKey]) }

    private func fail(_ reason: String) -> [Event] { transition(.failed(scrub(reason))) }

    private func transition(_ s: State) -> [Event] {
        guard s != state else { return [] }
        state = s
        return [.stateChanged(s)]
    }
}
