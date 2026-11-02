/// SRT receiving side (0.54.0): LiveCore takes an SRT stream in as an input. Sans-IO like
/// `SRTCaller`: datagrams and time go in, packets to send and in-order payloads come out.
///
/// Two roles:
/// - listener (default): LiveCore waits on a UDP port; the encoder (OBS, vMix, Larix, a hardware
///   encoder, ffmpeg) calls `srt://<this Mac>:<port>`.
/// - caller: LiveCore calls an encoder or server that is listening.
///
/// Implemented: handshake v5 both ways (HSREQ/HSRSP, Stream ID), ACK every 10 ms with ACKACK RTT,
/// immediate + periodic NAK for lost packets, TSBPD (each packet is released `latency` after the
/// sender's timestamp, so retransmissions have time to arrive), too-late packet drop, keep-alive,
/// shutdown, idle timeout. Not implemented: encryption (passphrase) — such callers are rejected.
public final class SRTReceiver {
    public enum Role: Equatable, Sendable { case listener, caller }
    public enum State: Equatable {
        case idle, listening, induction, conclusion, connected, closed(String)
    }

    public struct Stats: Equatable, Sendable {
        public var receivedPackets = 0
        public var lostPackets = 0          // gaps detected (NAK sent)
        public var recoveredPackets = 0     // lost packets that arrived later
        public var droppedPackets = 0       // never arrived in time, skipped
        public var receivedBytes = 0
        public var rttMs = 0.0
        public var latencyMs = 0
        public var peerStreamID = ""
    }

    public let role: Role
    public private(set) var state: State = .idle
    public private(set) var stats = Stats()
    public let socketID: UInt32
    public private(set) var peerSocketID: UInt32 = 0
    /// Latency agreed in the handshake (max of ours and the peer's).
    public private(set) var latencyMs: Int

    private let wantedLatencyMs: Int
    private let streamID: String?
    private var startTime = 0.0
    private var cookie: UInt32 = 0
    private var callerCookie: UInt32 = 0
    private let ourISN: UInt32
    private var handshakeStarted = 0.0
    private var lastHandshakeSent = -1.0
    private var lastReceived = 0.0
    private var lastSent = 0.0

    // Receive buffer.
    private var started = false
    private var deliverNext: UInt32 = 0          // next sequence to hand out
    private var maxSeq: UInt32 = 0               // highest sequence seen
    private var ackPoint: UInt32 = 0             // first sequence not received contiguously
    private var store: [UInt32: (payload: ArraySlice<UInt8>, time: Double)] = [:]
    private var losses: [UInt32: Double] = [:]   // missing sequence → last NAK time
    // Sender timestamp → local time: local = base + ts. `base` follows the smallest transit
    // seen in the last window so slow clock drift between the machines does not pile up.
    private var base = 0.0
    private var windowMin = Double.greatestFiniteMagnitude
    private var windowStart = 0.0
    private var tsInit = false
    private var lastUnwrapped = 0.0
    private var lastTs: UInt32 = 0

    // ACK / RTT.
    private var ackNumber: UInt32 = 1
    private var sentAcks: [UInt32: Double] = [:]
    private var lastAck = 0.0
    private var lastAckedPoint: UInt32 = 0
    private var lastNakSweep = 0.0
    private var rtt = 0.03, rttVar = 0.01
    private var rateWindowStart = 0.0, rateWindowPackets = 0, rateWindowBytes = 0
    private var packetRate: UInt32 = 0, byteRate: UInt32 = 0

    public static let handshakeTimeout = 5.0
    public static let peerIdleTimeout = 5.0
    public static let maxBufferedPackets = 8192

    public init(role: Role, latencyMs: Int = 120, streamID: String? = nil,
                socketID: UInt32 = UInt32.random(in: 1...0x3FFF_FFFF),
                initialSeq: UInt32 = UInt32.random(in: 0...0x3FFF_FFFF)) {
        self.role = role
        self.wantedLatencyMs = max(20, latencyMs)
        self.latencyMs = max(20, latencyMs)
        self.streamID = streamID
        self.socketID = socketID & 0x3FFF_FFFF | 1
        self.ourISN = initialSeq & SRTPacket.seqMask
        self.cookie = UInt32.random(in: 1...UInt32.max)
        stats.latencyMs = self.latencyMs
    }

    private func ts(_ now: Double) -> UInt32 { UInt32(truncatingIfNeeded: Int64(max(0, now - startTime) * 1_000_000)) }

    public var isConnected: Bool { state == .connected }

    // MARK: Start

    /// Listener: wait for a caller. Caller: returns the first handshake packet to send.
    public func start(now: Double) -> [[UInt8]] {
        startTime = now
        handshakeStarted = now
        lastReceived = now
        switch role {
        case .listener:
            state = .listening
            return []
        case .caller:
            state = .induction
            return [inductionRequest(now)]
        }
    }

    private func inductionRequest(_ now: Double) -> [UInt8] {
        lastHandshakeSent = now
        let hs = SRTPacket.Handshake(version: 4, extensionField: 2, initialSeq: ourISN,
                                     type: SRTPacket.Handshake.induction, socketID: socketID, cookie: 0)
        return SRTPacket.control(.handshake, timestamp: ts(now), dest: 0, cif: hs.encode())
    }

    private func conclusionRequest(_ now: Double) -> [UInt8] {
        lastHandshakeSent = now
        var flags = SRTPacket.Handshake.flagHSREQ
        var hs = SRTPacket.Handshake(version: 5, extensionField: 0, initialSeq: ourISN,
                                     type: SRTPacket.Handshake.conclusion, socketID: socketID, cookie: callerCookie)
        hs.extensions.append((SRTPacket.Handshake.extHSREQ, SRTPacket.hsreq(latencyMs: wantedLatencyMs)))
        if let sid = streamID, !sid.isEmpty {
            flags |= SRTPacket.Handshake.flagCONFIG
            hs.extensions.append((SRTPacket.Handshake.extSID, SRTPacket.streamIDBlock(sid)))
        }
        hs.extensionField = flags
        return SRTPacket.control(.handshake, timestamp: ts(now), dest: 0, cif: hs.encode())
    }

    // MARK: Receive

    /// Feeds one datagram. Returns packets to send back. In-order payloads are collected with
    /// `deliver(now:)`.
    public func receive(_ d: [UInt8], now: Double) -> [[UInt8]] {
        guard d.count >= SRTPacket.headerSize else { return [] }
        if d[0] & 0x80 == 0 { return receiveData(d, now: now) }
        let w0 = SRTPacket.u32(d, 0)
        guard let type = SRTPacket.ControlType(rawValue: UInt16((w0 >> 16) & 0x7FFF)) else { return [] }
        let info = SRTPacket.u32(d, 4)
        let cif = d[SRTPacket.headerSize...]
        if type == .handshake { return handshake(cif, now: now) }
        guard state == .connected else { return [] }
        lastReceived = now
        switch type {
        case .ackack:
            if let sent = sentAcks.removeValue(forKey: info) {
                let sample = max(0, now - sent)
                rttVar = rttVar * 0.75 + abs(rtt - sample) * 0.25
                rtt = rtt * 0.875 + sample * 0.125
                stats.rttMs = rtt * 1000
            }
            return []
        case .shutdown:
            state = .closed("The sender closed the connection")
            return []
        case .dropreq:
            // The sender gave up on a range: stop asking for it.
            if cif.count >= 8 {
                let b = Array(cif)
                let from = SRTPacket.u32(b, 0) & SRTPacket.seqMask, to = SRTPacket.u32(b, 4) & SRTPacket.seqMask
                var s = from, n = 0
                while n < 4096 { losses[s] = nil; if s == to { break }; s = (s + 1) & SRTPacket.seqMask; n += 1 }
            }
            return []
        case .keepalive, .ack, .nak, .congestion, .peerError, .handshake:
            return []
        }
    }

    private func handshake(_ cif: ArraySlice<UInt8>, now: Double) -> [[UInt8]] {
        guard let hs = SRTPacket.Handshake.decode(cif) else { return [] }
        switch role {
        case .listener:
            if hs.type == SRTPacket.Handshake.induction {
                // A caller starts (again). A new socket replaces a dead or finished session.
                if state == .connected, hs.socketID == peerSocketID { return [] }
                if state == .connected { reset(now: now) }
                state = .listening
                lastReceived = now
                var rsp = SRTPacket.Handshake(version: 5, extensionField: SRTPacket.Handshake.srtMagic,
                                              initialSeq: hs.initialSeq, type: SRTPacket.Handshake.induction,
                                              socketID: socketID, cookie: cookie)
                rsp.mtu = hs.mtu; rsp.flowWindow = hs.flowWindow
                return [SRTPacket.control(.handshake, timestamp: ts(now), dest: hs.socketID, cif: rsp.encode())]
            }
            guard hs.type == SRTPacket.Handshake.conclusion else { return [] }
            if state == .connected, hs.socketID == peerSocketID {
                return [conclusionResponse(hs, now: now)]   // our answer was lost: repeat it
            }
            guard hs.cookie == cookie, hs.version >= 5 else { return [] }
            if hs.encryption != 0 || hs.extensions.contains(where: { $0.0 == 3 }) {
                // KMREQ: the caller wants encryption, which this receiver does not do.
                var rej = SRTPacket.Handshake(version: 5, extensionField: 0, initialSeq: hs.initialSeq,
                                              type: 1011, socketID: socketID, cookie: cookie)
                rej.mtu = hs.mtu
                state = .closed("The sender uses an SRT passphrase (encryption is not supported)")
                return [SRTPacket.control(.handshake, timestamp: ts(now), dest: hs.socketID, cif: rej.encode())]
            }
            peerSocketID = hs.socketID
            if let req = hs.extensions.first(where: { $0.0 == SRTPacket.Handshake.extHSREQ })?.1, req.count >= 12 {
                let w = SRTPacket.u32(req, 8)
                latencyMs = max(wantedLatencyMs, Int(w & 0xFFFF), Int(w >> 16))
            }
            if let sid = hs.extensions.first(where: { $0.0 == SRTPacket.Handshake.extSID })?.1 {
                stats.peerStreamID = SRTPacket.decodeStreamID(sid)
            }
            stats.latencyMs = latencyMs
            beginData(isn: hs.initialSeq, now: now)
            return [conclusionResponse(hs, now: now)]
        case .caller:
            if hs.type >= 1000 && hs.type < 1100 || hs.type >= 2000 && hs.type < 3000 {
                state = .closed(SRTCaller.rejectReason(hs.type))
                return []
            }
            if state == .induction, hs.type == SRTPacket.Handshake.induction {
                guard hs.version >= 5, hs.extensionField == SRTPacket.Handshake.srtMagic else {
                    state = .closed("The SRT sender does not speak SRT v5")
                    return []
                }
                callerCookie = hs.cookie
                state = .conclusion
                lastReceived = now
                return [conclusionRequest(now)]
            }
            if state == .conclusion, hs.type == SRTPacket.Handshake.conclusion {
                peerSocketID = hs.socketID
                if let rsp = hs.extensions.first(where: { $0.0 == SRTPacket.Handshake.extHSRSP })?.1, rsp.count >= 12 {
                    let w = SRTPacket.u32(rsp, 8)
                    latencyMs = max(wantedLatencyMs, Int(w & 0xFFFF), Int(w >> 16))
                }
                stats.latencyMs = latencyMs
                beginData(isn: hs.initialSeq, now: now)
            }
            return []
        }
    }

    private func conclusionResponse(_ req: SRTPacket.Handshake, now: Double) -> [UInt8] {
        var rsp = SRTPacket.Handshake(version: 5, extensionField: SRTPacket.Handshake.flagHSREQ,
                                      initialSeq: req.initialSeq, type: SRTPacket.Handshake.conclusion,
                                      socketID: socketID, cookie: cookie)
        rsp.mtu = req.mtu; rsp.flowWindow = req.flowWindow
        rsp.extensions.append((SRTPacket.Handshake.extHSRSP, SRTPacket.hsreq(latencyMs: latencyMs)))
        lastSent = now
        return SRTPacket.control(.handshake, timestamp: ts(now), dest: peerSocketID, cif: rsp.encode())
    }

    private func beginData(isn: UInt32, now: Double) {
        state = .connected
        lastReceived = now
        lastSent = now
        lastAck = now
        started = false
        deliverNext = isn & SRTPacket.seqMask
        ackPoint = deliverNext
        lastAckedPoint = deliverNext
        maxSeq = (deliverNext &- 1) & SRTPacket.seqMask
        store.removeAll(); losses.removeAll(); sentAcks.removeAll()
        rateWindowStart = now
    }

    private func reset(now: Double) {
        store.removeAll(); losses.removeAll(); sentAcks.removeAll()
        peerSocketID = 0
        started = false
        tsInit = false
        stats = Stats()
        latencyMs = wantedLatencyMs
        stats.latencyMs = latencyMs
        cookie = UInt32.random(in: 1...UInt32.max)
    }

    /// Sender time in seconds of a packet stamped `t` (µs since the sender started). 32-bit µs
    /// timestamps wrap every ~71 minutes, so they are unwrapped against the newest one seen.
    private func unwrap(_ t: UInt32) -> Double {
        if !tsInit { tsInit = true; lastTs = t; lastUnwrapped = Double(t) }
        let diff = Int64(Int32(bitPattern: t &- lastTs))
        let v = lastUnwrapped + Double(diff)
        if diff > 0 { lastUnwrapped = v; lastTs = t }
        return v / 1_000_000
    }

    private func receiveData(_ d: [UInt8], now: Double) -> [[UInt8]] {
        guard state == .connected else { return [] }
        lastReceived = now
        let seq = SRTPacket.u32(d, 0) & SRTPacket.seqMask
        let w1 = SRTPacket.u32(d, 4)
        if (w1 >> 27) & 0x3 != 0 {
            state = .closed("The SRT stream is encrypted (passphrase), which is not supported")
            return []
        }
        let t = unwrap(SRTPacket.u32(d, 8))
        // Transit estimate for TSBPD (retransmissions arrive late on purpose: skip them).
        let retransmitted = w1 & 0x0400_0000 != 0
        if !retransmitted {
            let transit = now - t
            if !started { base = transit; windowMin = transit; windowStart = now }
            windowMin = min(windowMin, transit)
            if transit < base { base = transit }
            if now - windowStart > 10 { base = windowMin; windowMin = .greatestFiniteMagnitude; windowStart = now }
        }
        stats.receivedPackets += 1
        stats.receivedBytes += d.count - SRTPacket.headerSize
        rateWindowPackets += 1; rateWindowBytes += d.count

        if !started {
            // Start from the first packet seen (robust when the peer's ISN differs).
            started = true
            deliverNext = seq; ackPoint = seq; lastAckedPoint = seq
            maxSeq = (seq &- 1) & SRTPacket.seqMask
        }
        // Already delivered or dropped, or absurdly far ahead.
        guard !SRTPacket.seqLess(seq, deliverNext) else { return [] }
        let ahead = (seq &- deliverNext) & SRTPacket.seqMask
        guard ahead < UInt32(Self.maxBufferedPackets) else {
            // The stream jumped (sender restarted its sequence): start over from here.
            store.removeAll(); losses.removeAll()
            deliverNext = seq; ackPoint = seq; maxSeq = (seq &- 1) & SRTPacket.seqMask
            return receiveData(d, now: now)
        }
        if store[seq] != nil { return [] }
        store[seq] = (d[SRTPacket.headerSize...], t)
        var out: [[UInt8]] = []
        if losses.removeValue(forKey: seq) != nil { stats.recoveredPackets += 1 }
        let next = (maxSeq &+ 1) & SRTPacket.seqMask
        if SRTPacket.seqLess(maxSeq, seq) {
            if seq != next {
                // Gap: everything between maxSeq and seq is missing. Report it now.
                var missing: [UInt32] = []
                var s = next
                while s != seq && missing.count < 4096 { missing.append(s); losses[s] = now; s = (s + 1) & SRTPacket.seqMask }
                stats.lostPackets += missing.count
                out.append(SRTPacket.control(.nak, timestamp: ts(now), dest: peerSocketID,
                                             cif: SRTPacket.encodeLossList(missing)))
                lastSent = now
            }
            maxSeq = seq
        }
        while store[ackPoint] != nil { ackPoint = (ackPoint + 1) & SRTPacket.seqMask }
        return out
    }

    // MARK: Delivery

    /// In-order payloads whose release time has come. Missing packets that are too late are
    /// skipped (counted as dropped).
    public func deliver(now: Double) -> [ArraySlice<UInt8>] {
        guard state == .connected, started else { return [] }
        var out: [ArraySlice<UInt8>] = []
        let latency = Double(latencyMs) / 1000
        while true {
            if let p = store[deliverNext] {
                guard base + p.time + latency <= now else { break }
                out.append(p.payload)
                store[deliverNext] = nil
                deliverNext = (deliverNext + 1) & SRTPacket.seqMask
                continue
            }
            // A hole: give up on it once a later packet is due.
            guard !store.isEmpty else { break }
            var s = deliverNext, skipped = 0
            while store[s] == nil && skipped < Self.maxBufferedPackets {
                s = (s + 1) & SRTPacket.seqMask; skipped += 1
            }
            guard let p = store[s], base + p.time + latency <= now else { break }
            var k = deliverNext
            while k != s { losses[k] = nil; k = (k + 1) & SRTPacket.seqMask }
            stats.droppedPackets += skipped
            deliverNext = s
        }
        if SRTPacket.seqLess(ackPoint, deliverNext) {
            ackPoint = deliverNext
            while store[ackPoint] != nil { ackPoint = (ackPoint + 1) & SRTPacket.seqMask }
        }
        return out
    }

    // MARK: Timers

    /// Call every ~5–10 ms: handshake retries, ACK, periodic NAK, keep-alive, timeouts.
    public func tick(now: Double) -> [[UInt8]] {
        switch state {
        case .induction, .conclusion:
            if now - handshakeStarted > Self.handshakeTimeout {
                state = .closed("No answer from the SRT sender")
                return []
            }
            if now - lastHandshakeSent >= 0.25 {
                return [state == .induction ? inductionRequest(now) : conclusionRequest(now)]
            }
            return []
        case .connected:
            if now - lastReceived > Self.peerIdleTimeout {
                state = .closed("The SRT sender stopped sending")
                return []
            }
            var out: [[UInt8]] = []
            if now - rateWindowStart >= 1 {
                packetRate = UInt32(Double(rateWindowPackets) / (now - rateWindowStart))
                byteRate = UInt32(Double(rateWindowBytes) / (now - rateWindowStart))
                rateWindowStart = now; rateWindowPackets = 0; rateWindowBytes = 0
            }
            if now - lastAck >= 0.01, started, ackPoint != lastAckedPoint || now - lastAck >= 0.1 {
                lastAck = now
                lastAckedPoint = ackPoint
                let n = ackNumber
                ackNumber = ackNumber == 0x7FFF_FFFF ? 1 : ackNumber + 1
                sentAcks[n] = now
                if sentAcks.count > 64, let oldest = sentAcks.min(by: { $0.value < $1.value })?.key { sentAcks[oldest] = nil }
                let avail = UInt32(max(2, Self.maxBufferedPackets - store.count))
                var cif = SRTPacket.be32(ackPoint)
                cif += SRTPacket.be32(UInt32(rtt * 1_000_000)) + SRTPacket.be32(UInt32(rttVar * 1_000_000))
                cif += SRTPacket.be32(avail) + SRTPacket.be32(packetRate) + SRTPacket.be32(max(packetRate, 1000))
                cif += SRTPacket.be32(byteRate)
                out.append(SRTPacket.control(.ack, info: n, timestamp: ts(now), dest: peerSocketID, cif: cif))
                lastSent = now
            }
            if now - lastNakSweep >= 0.02, !losses.isEmpty {
                lastNakSweep = now
                // Ask again after about one round trip, and at least 3 times within the latency.
                let wait = min(max(0.02, rtt + 4 * rttVar), Double(latencyMs) / 1000 / 4)
                var again: [UInt32] = []
                for (s, at) in losses where now - at >= wait {
                    if SRTPacket.seqLess(s, deliverNext) { continue }
                    again.append(s)
                    if again.count >= 1024 { break }
                }
                // Drop stale entries behind the delivery point.
                for s in losses.keys where SRTPacket.seqLess(s, deliverNext) { losses[s] = nil }
                if !again.isEmpty {
                    again.sort { SRTPacket.seqLess($0, $1) }
                    for s in again { losses[s] = now }
                    out.append(SRTPacket.control(.nak, timestamp: ts(now), dest: peerSocketID,
                                                 cif: SRTPacket.encodeLossList(again)))
                    lastSent = now
                }
            }
            if now - lastSent >= 1 {
                lastSent = now
                out.append(SRTPacket.control(.keepalive, timestamp: ts(now), dest: peerSocketID, cif: [0, 0, 0, 0]))
            }
            return out
        case .listening:
            return []
        case .idle, .closed:
            return []
        }
    }

    /// Shutdown packet to send before closing.
    public func close(now: Double) -> [UInt8]? {
        defer { state = .closed("closed") }
        guard state == .connected else { return nil }
        return SRTPacket.control(.shutdown, timestamp: ts(now), dest: peerSocketID, cif: [0, 0, 0, 0])
    }

    /// Listener after a closed session: wait for the next caller.
    public func relisten(now: Double) {
        guard role == .listener else { return }
        reset(now: now)
        startTime = now
        lastReceived = now
        state = .listening
    }
}
