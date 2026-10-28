#if os(macOS)
import CoreMedia
import Foundation
import LiveCoreCore
import Network
import OSLog

/// A stream destination the production engine feeds with encoded video and audio.
public protocol StreamOutput: AnyObject {
    var onStats: ((StreamingEngine.Stats) -> Void)? { get set }
    var onRequestKeyframe: (() -> Void)? { get set }
    var encoderStatsProvider: (() -> (hardware: Bool, dropped: UInt64))? { get set }
    func send(video frame: H264Encoder.EncodedFrame)
    func send(audio aac: [UInt8], pts: CMTime)
    func stop()
}

extension StreamingEngine: StreamOutput {}

/// SRT output (caller, MPEG-TS, no encryption) over a UDP NWConnection. Same life cycle and
/// statistics as the RTMP `StreamingEngine`: connect, live, reconnect with back-off after a drop.
public final class SRTStreamingEngine: StreamOutput {
    public typealias Stats = StreamingEngine.Stats
    public typealias State = StreamingEngine.State

    public var onStats: ((Stats) -> Void)?
    public var onRequestKeyframe: (() -> Void)?
    public var encoderStatsProvider: (() -> (hardware: Bool, dropped: UInt64))?

    private let queue = DispatchQueue(label: "livecore.srt", qos: .userInitiated)
    private var url: SRTURL?
    private var settings = ProductionSettings()
    private var connection: NWConnection?
    private var caller: SRTCaller?
    private var mux = MPEGTSMuxer()
    private var packer = SRTPayloadPacker()
    private var audioConfig: [UInt8] = []
    private var state: State = .idle
    private var wantRunning = false
    private var attempt = 0
    private var everLive = false
    private var baseTime: CMTime?
    private var timer: DispatchSourceTimer?
    private var reconnectWork: DispatchWorkItem?
    private var stats = Stats()
    private var bytesThisSecond = 0
    private var lastStats = 0.0
    private var liveSince = 0.0
    private var droppedFrames: UInt64 = 0
    private static let log = Logger(subsystem: "com.livecore.studio", category: "srt")

    public init() {}

    // MARK: Control

    public func start(url: SRTURL, settings: ProductionSettings, audioSpecificConfig: [UInt8]) {
        queue.async {
            self.url = url
            self.settings = settings
            self.audioConfig = audioSpecificConfig
            self.wantRunning = true
            self.attempt = 0
            self.everLive = false
            self.stats = Stats()
            self.startTimer()
            self.connect()
        }
    }

    public func stop() {
        queue.async {
            self.wantRunning = false
            self.reconnectWork?.cancel()
            if let c = self.caller, let bye = c.close(now: HostClock.now()) { self.write(bye) }
            // Let the shutdown packet leave before the socket closes.
            self.queue.asyncAfter(deadline: .now() + 0.1) { self.teardown(.idle) }
        }
    }

    public func send(video frame: H264Encoder.EncodedFrame) { queue.async { self.handleVideo(frame) } }
    public func send(audio aac: [UInt8], pts: CMTime) { queue.async { self.handleAudio(aac, pts: pts) } }

    // MARK: Connection

    private func connect() {
        guard wantRunning, let url else { return }
        setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt, inSeconds: 0))
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port)) else { fail("Invalid port"); return }
        let conn = NWConnection(host: NWEndpoint.Host(url.host), port: port, using: .udp)
        let c = SRTCaller(url: url, socketID: UInt32.random(in: 1...0x3FFF_FFFF), initialSeq: UInt32.random(in: 0...0x3FFF_FFFF))
        connection = conn
        caller = c
        mux = MPEGTSMuxer(hasAudio: !audioConfig.isEmpty)
        packer = SRTPayloadPacker()
        baseTime = nil
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn, conn === self.connection else { return }
            switch st {
            case .ready:
                for d in c.connect(now: HostClock.now()) { self.write(d) }
                self.receive(on: conn)
            case let .failed(err):
                self.connectionLost("Network: \(err.localizedDescription)")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, conn === self.connection, let c = self.caller else { return }
            if let data, !data.isEmpty {
                let wasLive = c.state == .connected
                for r in c.receive([UInt8](data), now: HostClock.now()) { self.write(r) }
                if !wasLive, c.state == .connected { self.didConnect() }
            }
            if let error {
                // ICMP "port unreachable" while the server is down: keep listening, the handshake
                // timeout decides when to give up.
                if case .posix(.ECONNREFUSED) = error {
                    self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self, weak conn] in
                        if let self, let conn, conn === self.connection { self.receive(on: conn) }
                    }
                } else {
                    self.connectionLost("Network: \(error.localizedDescription)")
                }
                return
            }
            self.receive(on: conn)
        }
    }

    private func didConnect() {
        everLive = true
        attempt = 0
        liveSince = HostClock.now()
        Self.log.info("SRT connected to \(self.url?.redacted ?? "", privacy: .public), latency \(self.caller?.latencyMs ?? 0) ms")
        setState(.live)
        onRequestKeyframe?()
    }

    private func write(_ d: [UInt8]) {
        connection?.send(content: Data(d), completion: .idempotent)
        bytesThisSecond += d.count
    }

    // MARK: Media

    private func handleVideo(_ f: H264Encoder.EncodedFrame) {
        guard state == .live, let c = caller else { return }
        if baseTime == nil {
            guard f.keyframe else { return }
            baseTime = f.pts
        }
        guard let base = baseTime else { return }
        // Far behind (no ACKs for a long time): drop non-keyframes rather than queue.
        if c.stats.unacknowledged > 8000, !f.keyframe { droppedFrames += 1; onRequestKeyframe?(); return }
        let ts = mux.video(avcc: f.avcc, sps: f.sps, pps: f.pps, keyframe: f.keyframe, pts90k: pts90k(f.pts, base))
        push(ts, c)
    }

    private func handleAudio(_ aac: [UInt8], pts: CMTime) {
        guard state == .live, let c = caller, let base = baseTime, CMTimeCompare(pts, base) >= 0 else { return }
        push(mux.audio(aac: aac, audioSpecificConfig: audioConfig, pts90k: pts90k(pts, base)), c)
    }

    private func push(_ ts: [UInt8], _ c: SRTCaller) {
        var payloads = packer.add(ts)
        if let rest = packer.flush() { payloads.append(rest) }
        let now = HostClock.now()
        for p in payloads { if let d = c.send(p, now: now) { write(d) } }
    }

    private func pts90k(_ pts: CMTime, _ base: CMTime) -> UInt64 {
        // Start at 1 s so the PCR (PTS − offset) never goes negative.
        UInt64(max(0, CMTimeGetSeconds(CMTimeSubtract(pts, base))) * 90_000) + 90_000
    }

    // MARK: Timer, failure and reconnect

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = HostClock.now()
        if let c = caller {
            let wasLive = c.state == .connected
            for d in c.tick(now: now) { write(d) }
            if !wasLive, c.state == .connected { didConnect() }
            if case let .closed(reason) = c.state, state != .stopping, state != .idle { connectionLost(reason) }
        }
        if now - lastStats >= 1 {
            lastStats = now
            stats.bitrateKbps = Double(bytesThisSecond) * 8 / 1000
            bytesThisSecond = 0
            stats.droppedVideoFrames = droppedFrames + UInt64(caller?.stats.dropped ?? 0)
            stats.queuedMs = UInt32(min(Double(caller?.stats.unacknowledged ?? 0) * 1316 * 8 / Double(max(settings.video.bitrateKbps, 1)), 60_000))
            stats.uptime = state == .live ? now - liveSince : 0
            if let e = encoderStatsProvider?() { stats.encoderHardware = e.hardware; stats.encoderDropped = e.dropped }
            publishStats()
        }
    }

    private func connectionLost(_ reason: String) {
        guard state != .stopping, state != .idle else { return }
        if case .failed = state { return }
        let safe = Redaction.scrub(reason, secrets: [url?.streamID ?? ""])
        Self.log.error("SRT connection lost: \(safe, privacy: .public)")
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        caller = nil
        guard wantRunning, settings.stream.autoReconnect, everLive,
              let delay = settings.stream.reconnect.delay(forAttempt: attempt, random01: Double.random(in: 0...1)) else {
            fail(safe)
            return
        }
        attempt += 1
        stats.reconnects += 1
        setState(.reconnecting(attempt: attempt, inSeconds: delay))
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fail(_ reason: String) {
        wantRunning = false
        teardown(.failed(reason))
    }

    private func teardown(_ final: State) {
        reconnectWork?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        caller = nil
        timer?.cancel()
        timer = nil
        setState(final)
    }

    private func setState(_ s: State) {
        state = s
        stats.state = s
        publishStats()
    }

    private func publishStats() {
        let s = stats
        DispatchQueue.main.async { self.onStats?(s) }
    }
}
#endif
