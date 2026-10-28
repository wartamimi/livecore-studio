/// SRT (Secure Reliable Transport) caller for live publishing, without encryption: handshake v5
/// (induction + conclusion with HSREQ and Stream ID), data packets carrying MPEG-TS, ACK/ACKACK,
/// NAK retransmission, keep-alive and shutdown. Sans-IO: the caller feeds datagrams and time in
/// and sends what comes out, so the same code runs over Network.framework (app) and POSIX
/// sockets (CLI test tool). Spec: draft-sharabayko-srt (IETF), libsrt 1.5 behaviour.

/// srt://host:port?streamid=...&latency=ms
public struct SRTURL: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var streamID: String?
    public var latencyMs: Int

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notSRT, missingHost, invalidPort, missingPort, encryptionNotSupported, unsupportedMode(String)
        public var description: String {
            switch self {
            case .notSRT: return "The address must start with srt://."
            case .missingHost: return "The SRT address has no host name."
            case .invalidPort: return "The port in the SRT address is not valid."
            case .missingPort: return "The SRT address needs a port, e.g. srt://host:9000."
            case .encryptionNotSupported: return "SRT with a passphrase (encryption) is not supported yet."
            case let .unsupportedMode(m): return "SRT mode '\(m)' is not supported; LiveCore Studio connects as caller."
            }
        }
    }

    public init(host: String, port: Int, streamID: String? = nil, latencyMs: Int = 120) {
        self.host = host; self.port = port; self.streamID = streamID; self.latencyMs = latencyMs
    }

    public static func isSRT(_ s: String) -> Bool { s.trimmed.lowercased().hasPrefix("srt://") }

    /// `key` (the field kept in the Keychain) becomes the Stream ID when the address has none.
    public static func parse(_ raw: String, key: String = "") throws -> SRTURL {
        let s = raw.trimmed
        guard s.lowercased().hasPrefix("srt://") else { throw ParseError.notSRT }
        var rest = Substring(s.dropFirst(6))
        var query = ""
        if let q = rest.firstIndex(of: "?") { query = String(rest[rest.index(after: q)...]); rest = rest[..<q] }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        var host = String(rest), port: Int?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw ParseError.missingHost }
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") { guard let p = Int(after.dropFirst()) else { throw ParseError.invalidPort }; port = p }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            guard let p = Int(host[host.index(after: colon)...]) else { throw ParseError.invalidPort }
            port = p
            host = String(host[..<colon])
        }
        guard !host.isEmpty else { throw ParseError.missingHost }
        guard let port else { throw ParseError.missingPort }
        guard (1...65_535).contains(port) else { throw ParseError.invalidPort }
        var url = SRTURL(host: host, port: port)
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).lowercased(), v = kv.count > 1 ? percentDecode(String(kv[1])) : ""
            switch k {
            case "streamid": url.streamID = v
            case "latency":
                // libsrt takes ms in the URL; ffmpeg takes µs. Values above 10 000 are taken as µs.
                if let n = Int(v) { url.latencyMs = n > 10_000 ? n / 1000 : n }
            case "passphrase", "pbkeylen": if !v.isEmpty { throw ParseError.encryptionNotSupported }
            case "mode": if v.lowercased() != "caller" { throw ParseError.unsupportedMode(v) }
            default: break
            }
        }
        if url.streamID == nil, !key.trimmed.isEmpty { url.streamID = key.trimmed }
        url.latencyMs = min(max(url.latencyMs, 20), 8_000)
        return url
    }

    /// Address for logs and the UI, without the Stream ID (it can hold a key).
    public var redacted: String { "srt://\(host):\(port)" + (streamID == nil ? "" : "?streamid=•••") }

    static func percentDecode(_ s: String) -> String {
        var bytes: [UInt8] = []
        var u = Array(s.utf8)[...]
        while let c = u.first {
            u = u.dropFirst()
            if c == UInt8(ascii: "%"), u.count >= 2, let h = UInt8(String(decoding: u.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(h); u = u.dropFirst(2)
            } else if c == UInt8(ascii: "+") { bytes.append(UInt8(ascii: " ")) } else { bytes.append(c) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// SRT packet layout (all fields big-endian).
public enum SRTPacket {
    public enum ControlType: UInt16 {
        case handshake = 0, keepalive = 1, ack = 2, nak = 3, congestion = 4, shutdown = 5, ackack = 6, dropreq = 7, peerError = 8
    }

    public static let headerSize = 16
    /// 7 TS packets per datagram (the usual SRT payload).
    public static let payloadSize = 7 * 188
    public static let seqMask: UInt32 = 0x7FFF_FFFF
    public static let msgMask: UInt32 = 0x03FF_FFFF

    public static func control(_ type: ControlType, subtype: UInt16 = 0, info: UInt32 = 0, timestamp: UInt32,
                               dest: UInt32, cif: [UInt8] = []) -> [UInt8] {
        var p: [UInt8] = []
        p.reserveCapacity(16 + cif.count)
        p += be32(0x8000_0000 | UInt32(type.rawValue) << 16 | UInt32(subtype))
        p += be32(info)
        p += be32(timestamp)
        p += be32(dest)
        p += cif
        return p
    }

    public static func data(seq: UInt32, msg: UInt32, retransmitted: Bool, timestamp: UInt32, dest: UInt32,
                            payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = []
        p.reserveCapacity(16 + payload.count)
        p += be32(seq & seqMask)
        // PP = 11 (whole message in one packet), O = 0, KK = 00 (not encrypted), R.
        p += be32(0xC000_0000 | (retransmitted ? 0x0400_0000 : 0) | (msg & msgMask))
        p += be32(timestamp)
        p += be32(dest)
        p += payload
        return p
    }

    public struct Handshake: Equatable {
        public var version: UInt32
        public var encryption: UInt16 = 0
        public var extensionField: UInt16
        public var initialSeq: UInt32
        public var mtu: UInt32 = 1500
        public var flowWindow: UInt32 = 8192
        public var type: UInt32
        public var socketID: UInt32
        public var cookie: UInt32
        public var peerIP: [UInt8] = [UInt8](repeating: 0, count: 16)
        /// Extension blocks: (type, content).
        public var extensions: [(UInt16, [UInt8])] = []

        public static let induction: UInt32 = 1
        public static let conclusion: UInt32 = 0xFFFF_FFFF
        public static let srtMagic: UInt16 = 0x4A17
        public static let extHSREQ: UInt16 = 1, extHSRSP: UInt16 = 2, extSID: UInt16 = 5
        public static let flagHSREQ: UInt16 = 0x1, flagCONFIG: UInt16 = 0x4

        public init(version: UInt32, extensionField: UInt16, initialSeq: UInt32, type: UInt32, socketID: UInt32, cookie: UInt32) {
            self.version = version; self.extensionField = extensionField; self.initialSeq = initialSeq
            self.type = type; self.socketID = socketID; self.cookie = cookie
        }

        public static func == (a: Handshake, b: Handshake) -> Bool {
            a.version == b.version && a.encryption == b.encryption && a.extensionField == b.extensionField
                && a.initialSeq == b.initialSeq && a.type == b.type && a.socketID == b.socketID && a.cookie == b.cookie
                && a.extensions.map(\.0) == b.extensions.map(\.0) && a.extensions.map(\.1) == b.extensions.map(\.1)
        }

        public func encode() -> [UInt8] {
            var c: [UInt8] = []
            c += be32(version)
            c += be16(encryption) + be16(extensionField)
            c += be32(initialSeq) + be32(mtu) + be32(flowWindow) + be32(type) + be32(socketID) + be32(cookie)
            c += peerIP
            for (t, content) in extensions {
                c += be16(t) + be16(UInt16(content.count / 4))
                c += content
            }
            return c
        }

        public static func decode(_ cif: ArraySlice<UInt8>) -> Handshake? {
            guard cif.count >= 48 else { return nil }
            let b = Array(cif)
            var h = Handshake(version: u32(b, 0), extensionField: u16(b, 6), initialSeq: u32(b, 8), type: u32(b, 20),
                              socketID: u32(b, 24), cookie: u32(b, 28))
            h.encryption = u16(b, 4)
            h.mtu = u32(b, 12)
            h.flowWindow = u32(b, 16)
            h.peerIP = Array(b[32..<48])
            var o = 48
            while o + 4 <= b.count {
                let t = u16(b, o), words = Int(u16(b, o + 2))
                let end = o + 4 + words * 4
                guard end <= b.count else { break }
                h.extensions.append((t, Array(b[(o + 4)..<end])))
                o = end
            }
            return h
        }
    }

    /// HSREQ content: SRT version, flags, receiver / sender TSBPD delay.
    public static func hsreq(latencyMs: Int) -> [UInt8] {
        // TSBPDSND | TSBPDRCV | TLPKTDROP | PERIODICNAK | REXMITFLG
        let flags: UInt32 = 0x01 | 0x02 | 0x08 | 0x10 | 0x20
        let d = UInt32(min(max(latencyMs, 0), 0xFFFF))
        return be32(0x0001_0500) + be32(flags) + be32(d << 16 | d)
    }

    /// Stream ID extension: UTF-8 padded to 4 bytes, each 32-bit word byte-swapped (libsrt layout).
    public static func streamIDBlock(_ s: String) -> [UInt8] {
        var bytes = Array(s.utf8.prefix(512))
        while bytes.count % 4 != 0 { bytes.append(0) }
        var out: [UInt8] = []
        for i in stride(from: 0, to: bytes.count, by: 4) { out += bytes[i..<(i + 4)].reversed() }
        return out
    }

    public static func decodeStreamID(_ block: [UInt8]) -> String {
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: block.count - block.count % 4, by: 4) { bytes += block[i..<(i + 4)].reversed() }
        while bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// NAK loss list → sequence numbers (ranges have the top bit set on their first number).
    public static func lossList(_ cif: ArraySlice<UInt8>) -> [UInt32] {
        let b = Array(cif)
        var out: [UInt32] = []
        var i = 0
        while i + 4 <= b.count {
            let v = u32(b, i)
            if v & 0x8000_0000 != 0, i + 8 <= b.count {
                let from = v & seqMask, to = u32(b, i + 4) & seqMask
                var s = from
                var n = 0
                while n < 4096 { out.append(s); if s == to { break }; s = (s + 1) & seqMask; n += 1 }
                i += 8
            } else {
                out.append(v & seqMask)
                i += 4
            }
        }
        return out
    }

    public static func encodeLossList(_ seqs: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < seqs.count {
            var j = i
            while j + 1 < seqs.count, seqs[j + 1] == (seqs[j] + 1) & seqMask { j += 1 }
            if j > i { out += be32(seqs[i] | 0x8000_0000) + be32(seqs[j]) } else { out += be32(seqs[i]) }
            i = j + 1
        }
        return out
    }

    @inline(__always) public static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    @inline(__always) static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    @inline(__always) public static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    @inline(__always) static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }

    /// a < b in 31-bit sequence space.
    public static func seqLess(_ a: UInt32, _ b: UInt32) -> Bool {
        let d = (b &- a) & seqMask
        return d != 0 && d < 0x4000_0000
    }
}

/// The SRT caller connection (sans-IO). `now` is seconds on any monotonic clock.
public final class SRTCaller {
    public enum State: Equatable {
        case idle, induction, conclusion, connected, closed(String)
    }

    public struct Stats: Equatable {
        public var sentPackets = 0
        public var retransmitted = 0
        public var dropped = 0
        public var unacknowledged = 0
        public var rttMs = 0.0
        public init() {}
    }

    public private(set) var state: State = .idle
    public private(set) var stats = Stats()
    public let url: SRTURL
    public let socketID: UInt32
    public private(set) var peerSocketID: UInt32 = 0
    /// Latency agreed with the receiver (ms).
    public private(set) var latencyMs: Int

    private let initialSeq: UInt32
    private var nextSeq: UInt32
    private var nextMsg: UInt32 = 1
    private var startTime = 0.0
    private var cookie: UInt32 = 0
    private var lastHandshakeSent = -1.0
    private var handshakeStarted = 0.0
    private var lastSent = 0.0
    private var lastReceived = 0.0
    /// Sent, not yet acknowledged: sequence → (packet bytes with R flag off, first send time).
    private var buffer: [UInt32: (payload: [UInt8], timestamp: UInt32, msg: UInt32, sentAt: Double)] = [:]
    private var bufferOrder: [UInt32] = []

    public static let handshakeTimeout = 5.0
    public static let peerIdleTimeout = 5.0

    public init(url: SRTURL, socketID: UInt32, initialSeq: UInt32) {
        self.url = url
        self.socketID = socketID & 0x3FFF_FFFF | 1
        self.initialSeq = initialSeq & SRTPacket.seqMask
        self.nextSeq = self.initialSeq
        self.latencyMs = url.latencyMs
    }

    private func ts(_ now: Double) -> UInt32 { UInt32(truncatingIfNeeded: Int64(max(0, now - startTime) * 1_000_000)) }

    // MARK: Handshake

    public func connect(now: Double) -> [[UInt8]] {
        startTime = now
        handshakeStarted = now
        lastReceived = now
        state = .induction
        return [inductionRequest(now)]
    }

    private func inductionRequest(_ now: Double) -> [UInt8] {
        lastHandshakeSent = now
        let hs = SRTPacket.Handshake(version: 4, extensionField: 2, initialSeq: initialSeq,
                                     type: SRTPacket.Handshake.induction, socketID: socketID, cookie: 0)
        return SRTPacket.control(.handshake, timestamp: ts(now), dest: 0, cif: hs.encode())
    }

    private func conclusionRequest(_ now: Double) -> [UInt8] {
        lastHandshakeSent = now
        var flags = SRTPacket.Handshake.flagHSREQ
        var hs = SRTPacket.Handshake(version: 5, extensionField: 0, initialSeq: initialSeq,
                                     type: SRTPacket.Handshake.conclusion, socketID: socketID, cookie: cookie)
        hs.extensions.append((SRTPacket.Handshake.extHSREQ, SRTPacket.hsreq(latencyMs: url.latencyMs)))
        if let sid = url.streamID, !sid.isEmpty {
            flags |= SRTPacket.Handshake.flagCONFIG
            hs.extensions.append((SRTPacket.Handshake.extSID, SRTPacket.streamIDBlock(sid)))
        }
        hs.extensionField = flags
        return SRTPacket.control(.handshake, timestamp: ts(now), dest: 0, cif: hs.encode())
    }

    // MARK: Receive

    public func receive(_ d: [UInt8], now: Double) -> [[UInt8]] {
        guard d.count >= SRTPacket.headerSize, d[0] & 0x80 != 0 else { return [] }   // only control packets matter to a sender
        lastReceived = now
        let w0 = SRTPacket.u32(d, 0)
        guard let type = SRTPacket.ControlType(rawValue: UInt16((w0 >> 16) & 0x7FFF)) else { return [] }
        let info = SRTPacket.u32(d, 4)
        let cif = d[SRTPacket.headerSize...]
        switch type {
        case .handshake:
            guard let hs = SRTPacket.Handshake.decode(cif) else { return [] }
            if hs.type >= 1000 && hs.type < 1100 || hs.type >= 2000 && hs.type < 3000 {
                state = .closed(Self.rejectReason(hs.type))
                return []
            }
            if state == .induction, hs.type == SRTPacket.Handshake.induction {
                guard hs.version >= 5, hs.extensionField == SRTPacket.Handshake.srtMagic else {
                    state = .closed("The server does not speak SRT v5")
                    return []
                }
                cookie = hs.cookie
                state = .conclusion
                return [conclusionRequest(now)]
            }
            if state == .conclusion, hs.type == SRTPacket.Handshake.conclusion {
                peerSocketID = hs.socketID
                if let rsp = hs.extensions.first(where: { $0.0 == SRTPacket.Handshake.extHSRSP })?.1, rsp.count >= 12 {
                    // The receiver may raise the latency; use the larger.
                    let rcv = Int(SRTPacket.u32(rsp, 8) >> 16), snd = Int(SRTPacket.u32(rsp, 8) & 0xFFFF)
                    latencyMs = max(url.latencyMs, rcv, snd)
                }
                state = .connected
                lastSent = now
            }
            return []
        case .ack:
            guard state == .connected, cif.count >= 4 else { return [] }
            let ackSeq = SRTPacket.u32(Array(cif), 0) & SRTPacket.seqMask
            release(upTo: ackSeq)
            if cif.count >= 8 { stats.rttMs = Double(SRTPacket.u32(Array(cif), 4)) / 1000 }
            // Full ACKs carry an ACK number and want an ACKACK (RTT measurement).
            if cif.count >= 16 && info != 0 {
                lastSent = now
                return [SRTPacket.control(.ackack, info: info, timestamp: ts(now), dest: peerSocketID, cif: [0, 0, 0, 0])]
            }
            return []
        case .nak:
            guard state == .connected else { return [] }
            var out: [[UInt8]] = []
            for s in SRTPacket.lossList(cif).prefix(1024) {
                if let p = buffer[s] {
                    out.append(SRTPacket.data(seq: s, msg: p.msg, retransmitted: true, timestamp: p.timestamp,
                                              dest: peerSocketID, payload: p.payload))
                    stats.retransmitted += 1
                }
            }
            if !out.isEmpty { lastSent = now }
            return out
        case .shutdown:
            state = .closed("The server closed the connection")
            return []
        case .keepalive, .ackack, .congestion, .dropreq, .peerError:
            return []
        }
    }

    private func release(upTo ackSeq: UInt32) {
        var removed = 0
        for s in bufferOrder {
            guard SRTPacket.seqLess(s, ackSeq) else { break }
            buffer[s] = nil
            removed += 1
        }
        if removed > 0 { bufferOrder.removeFirst(removed) }
        stats.unacknowledged = bufferOrder.count
    }

    // MARK: Send

    /// One data packet with `payload` (≤ 1316 bytes of TS), nil while not connected.
    public func send(_ payload: [UInt8], now: Double) -> [UInt8]? {
        guard state == .connected else { return nil }
        let seq = nextSeq, msg = nextMsg
        nextSeq = (nextSeq + 1) & SRTPacket.seqMask
        nextMsg = nextMsg & SRTPacket.msgMask == SRTPacket.msgMask ? 1 : nextMsg + 1
        let t = ts(now)
        buffer[seq] = (payload, t, msg, now)
        bufferOrder.append(seq)
        stats.sentPackets += 1
        stats.unacknowledged = bufferOrder.count
        lastSent = now
        return SRTPacket.data(seq: seq, msg: msg, retransmitted: false, timestamp: t, dest: peerSocketID, payload: payload)
    }

    // MARK: Timers

    /// Call every ~10 ms: handshake retries, keep-alive, timeouts, dropping packets too late to matter.
    public func tick(now: Double) -> [[UInt8]] {
        switch state {
        case .induction, .conclusion:
            if now - handshakeStarted > Self.handshakeTimeout {
                state = .closed("No answer from the SRT server")
                return []
            }
            if now - lastHandshakeSent >= 0.25 {
                return [state == .induction ? inductionRequest(now) : conclusionRequest(now)]
            }
            return []
        case .connected:
            if now - lastReceived > Self.peerIdleTimeout {
                state = .closed("The SRT server stopped answering")
                return []
            }
            // Too late for the receiver (TLPKTDROP): forget packets older than latency + 1 s.
            let limit = Double(latencyMs) / 1000 + 1
            var dropped = 0
            for s in bufferOrder {
                guard let p = buffer[s], now - p.sentAt > limit else { break }
                buffer[s] = nil
                dropped += 1
            }
            if dropped > 0 { bufferOrder.removeFirst(dropped); stats.dropped += dropped; stats.unacknowledged = bufferOrder.count }
            if now - lastSent >= 1 {
                lastSent = now
                return [SRTPacket.control(.keepalive, timestamp: ts(now), dest: peerSocketID, cif: [0, 0, 0, 0])]
            }
            return []
        case .idle, .closed:
            return []
        }
    }

    /// Shutdown packet to send before closing the socket.
    public func close(now: Double) -> [UInt8]? {
        defer { state = .closed("closed") }
        guard state == .connected else { return nil }
        return SRTPacket.control(.shutdown, timestamp: ts(now), dest: peerSocketID, cif: [0, 0, 0, 0])
    }

    static func rejectReason(_ code: UInt32) -> String {
        switch code {
        case 1002: return "The SRT server rejected the connection (system error)"
        case 1003: return "The SRT server rejected the connection (peer)"
        case 1008: return "The SRT server is overloaded"
        case 1012: return "The SRT server rejected the connection: version mismatch"
        case 1015: return "The SRT server requires a different Stream ID"
        case 1016: return "The SRT server requires encryption (passphrase)"
        case 1017: return "The SRT server rejected the stream (congestion setting)"
        case 2000..<3000: return "The SRT server rejected the Stream ID (code \(code))"
        default: return "The SRT server rejected the connection (code \(code))"
        }
    }
}

/// Groups TS packets into SRT payloads of up to 7 × 188 bytes.
public struct SRTPayloadPacker {
    private var pending: [UInt8] = []
    public init() {}

    /// Full payloads ready to send; the rest waits for more data or `flush()`.
    public mutating func add(_ ts: [UInt8]) -> [[UInt8]] {
        pending += ts
        var out: [[UInt8]] = []
        while pending.count >= SRTPacket.payloadSize {
            out.append(Array(pending[0..<SRTPacket.payloadSize]))
            pending.removeFirst(SRTPacket.payloadSize)
        }
        return out
    }

    /// The partial payload at the end of a frame (keeps latency low).
    public mutating func flush() -> [UInt8]? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
