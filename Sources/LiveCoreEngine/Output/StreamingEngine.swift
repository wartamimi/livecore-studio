#if os(macOS)
import CoreMedia
import Foundation
import Network
import LiveCoreCore

/// RTMP/RTMPS publisher.
///
///   encoders --(FLV bodies)--> StreamOutputQueue --(RTMP chunks)--> NWConnection (TCP or TLS)
///
/// All state lives on `queue` (serial). The protocol itself is `RTMPPublishSession` from
/// LiveCoreCore (unit-tested and validated end-to-end against an RTMP server); this class only
/// adds the Network.framework transport, pacing/backpressure, statistics and reconnection.
public final class StreamingEngine {
    public enum State: Equatable {
        case idle
        case connecting
        case live
        case reconnecting(attempt: Int, inSeconds: Double)
        case failed(String)
        case stopping
    }

    public struct Stats: Equatable {
        public var state: State = .idle
        public var bitrateKbps: Double = 0
        public var droppedVideoFrames: UInt64 = 0
        public var queuedMs: UInt32 = 0
        public var uptime: Double = 0
        public var reconnects: Int = 0
        public var encoderHardware: Bool = false
        public var encoderDropped: UInt64 = 0
        public init() {}
    }

    public var onStats: ((Stats) -> Void)?          // delivered on main
    public var onRequestKeyframe: (() -> Void)?     // ask the H.264 encoder for an IDR

    private let queue = DispatchQueue(label: "livecore.stream", qos: .userInitiated)
    private var url: RTMPURL?
    private var settings = ProductionSettings()
    private var connection: NWConnection?
    private var session: RTMPPublishSession?
    private var outQueue = StreamOutputQueue(maxQueuedMs: 3000)
    private var inFlightBytes = 0
    private let maxInFlightBytes = 256 * 1024
    private var state: State = .idle
    private var wantRunning = false
    private var attempt = 0
    private var everPublished = false
    private var baseTime: CMTime?                 // PTS that maps to RTMP timestamp 0
    private var sentConfig = false
    private var lastSPS: [UInt8] = []
    private var lastPPS: [UInt8] = []
    private var audioConfig: [UInt8] = []
    private var bytesThisSecond = 0
    private var stats = Stats()
    private var statsTimer: DispatchSourceTimer?
    private var handshakeTimer: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var liveSince: Double = 0
    public var encoderStatsProvider: (() -> (hardware: Bool, dropped: UInt64))?

    public init() {}

    // MARK: Control (any thread)

    public func start(url: RTMPURL, settings: ProductionSettings, audioSpecificConfig: [UInt8]) {
        queue.async {
            self.url = url
            self.settings = settings
            self.audioConfig = audioSpecificConfig
            self.wantRunning = true
            self.attempt = 0
            self.everPublished = false
            self.stats = Stats()
            self.startStatsTimer()
            self.connect()
        }
    }

    public func stop() {
        queue.async {
            self.wantRunning = false
            self.reconnectWork?.cancel()
            guard let session = self.session, let conn = self.connection else { self.teardown(.idle); return }
            self.setState(.stopping)
            var bytes: [UInt8] = []
            for case let .send(b) in session.close() { bytes += b }
            // Send FCUnpublish/deleteStream, then close after it is flushed (or 2 s at most).
            conn.send(content: Data(bytes), completion: .contentProcessed { _ in
                self.queue.async { self.teardown(.idle) }
            })
            self.queue.asyncAfter(deadline: .now() + 2) { if self.state == .stopping { self.teardown(.idle) } }
        }
    }

    // MARK: Media input (encoder threads)

    public func send(video frame: H264Encoder.EncodedFrame) {
        queue.async { self.handleVideo(frame) }
    }

    public func send(audio aac: [UInt8], pts: CMTime) {
        queue.async { self.handleAudio(aac, pts: pts) }
    }

    // MARK: Connection

    private func connect() {
        guard wantRunning, let url else { return }
        setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt, inSeconds: 0))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        tcp.enableKeepalive = true
        let params = url.useTLS ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp) : NWParameters(tls: nil, tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port)) else { fail("Invalid port"); return }
        let conn = NWConnection(host: NWEndpoint.Host(url.host), port: port, using: params)
        let sess = RTMPPublishSession(url: url)
        connection = conn
        session = sess
        outQueue = StreamOutputQueue(maxQueuedMs: 3000)
        inFlightBytes = 0
        sentConfig = false
        baseTime = nil

        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn, conn === self.connection else { return }
            switch st {
            case .ready:
                Log.stream.info("TCP\(url.useTLS ? "+TLS" : "", privacy: .public) connected to \(url.tcUrl, privacy: .public)")
                self.process(sess.start())
                self.receive(on: conn)
            case let .waiting(err), let .failed(err):
                self.connectionLost("Network: \(err.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session === sess, sess.state != .publishing else { return }
            self.connectionLost("Timed out waiting for the server to accept the stream")
        }
        handshakeTimer = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection, let session = self.session else { return }
            if let data, !data.isEmpty {
                do { self.process(try session.receive([UInt8](data))) } catch {
                    self.connectionLost("Protocol error: \(error)")
                    return
                }
            }
            if isComplete { self.connectionLost("Server closed the connection"); return }
            if let error { self.connectionLost("Network: \(error.localizedDescription)"); return }
            self.receive(on: conn)
        }
    }

    private func process(_ events: [RTMPPublishSession.Event]) {
        for e in events {
            switch e {
            case let .send(bytes):
                write(bytes)
            case let .stateChanged(s):
                switch s {
                case .publishing:
                    handshakeTimer?.cancel()
                    everPublished = true
                    attempt = 0
                    liveSince = HostClock.now()
                    setState(.live)
                    sendMetadata()
                    onRequestKeyframe?()
                case let .failed(reason):
                    connectionLost(reason)
                case .closed:
                    if wantRunning && state != .stopping { connectionLost("Server closed the stream") }
                default: break
                }
            case let .status(s):
                Log.stream.info("server: \(s, privacy: .public)")
            }
        }
    }

    private func sendMetadata() {
        guard let session else { return }
        let o = settings.output
        let meta = FLV.Metadata(width: o.size.width, height: o.size.height, frameRate: Double(o.frameRate),
                                videoBitrateKbps: settings.streamVideo.bitrateKbps, audioBitrateKbps: settings.streamAudioKbps,
                                audioSampleRate: settings.audio.sampleRate, audioChannels: settings.audio.channels)
        if let bytes = try? session.metadataPacket(meta) { write(bytes) }
    }

    private func write(_ bytes: [UInt8]) {
        guard let conn = connection else { return }
        inFlightBytes += bytes.count
        conn.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.inFlightBytes -= bytes.count
            self.bytesThisSecond += bytes.count
            if let error { self.connectionLost("Send failed: \(error.localizedDescription)"); return }
            self.pump()
        })
    }

    /// Moves packets from the congestion queue to the socket while in-flight data is bounded.
    private func pump() {
        guard state == .live, let session else { return }
        while inFlightBytes < maxInFlightBytes, let p = outQueue.dequeue() {
            let bytes: [UInt8]?
            switch p.kind {
            case .audio: bytes = try? session.audioPacket(body: p.body, timestampMs: p.timestampMs)
            case .video: bytes = try? session.videoPacket(body: p.body, timestampMs: p.timestampMs)
            case .config:
                bytes = p.body.first == 0xAF ? try? session.audioPacket(body: p.body, timestampMs: p.timestampMs)
                                             : try? session.videoPacket(body: p.body, timestampMs: p.timestampMs)
            case .metadata: bytes = nil
            }
            if let bytes { write(bytes) }
        }
    }

    // MARK: Media

    private func handleVideo(_ f: H264Encoder.EncodedFrame) {
        guard state == .live else { return }
        if baseTime == nil {
            guard f.keyframe else { return }   // start on a keyframe so the stream is decodable
            baseTime = f.pts
        }
        guard let base = baseTime else { return }
        let ts = timestampMs(f.pts, base: base)
        if !sentConfig || f.sps != lastSPS || f.pps != lastPPS {
            lastSPS = f.sps; lastPPS = f.pps
            let cfg = FLV.avcVideoBody(keyframe: true, sequenceHeader: true, data: AVC.decoderConfigurationRecord(sps: f.sps, pps: f.pps))
            outQueue.enqueue(OutgoingPacket(kind: .config, timestampMs: ts, body: cfg))
            if !sentConfig {
                outQueue.enqueue(OutgoingPacket(kind: .config, timestampMs: ts, body: FLV.aacAudioBody(sequenceHeader: true, data: audioConfig)))
            }
            sentConfig = true
        }
        let droppedBefore = outQueue.droppedVideoFrames
        outQueue.enqueue(OutgoingPacket(kind: .video(keyframe: f.keyframe), timestampMs: ts,
                                        body: FLV.avcVideoBody(keyframe: f.keyframe, sequenceHeader: false, data: f.avcc)))
        // Congestion drop started: ask for an IDR so the stream recovers without waiting a full GOP.
        if outQueue.droppedVideoFrames > droppedBefore, !f.keyframe { onRequestKeyframe?() }
        pump()
    }

    private func handleAudio(_ aac: [UInt8], pts: CMTime) {
        guard state == .live, sentConfig, let base = baseTime, CMTimeCompare(pts, base) >= 0 else { return }
        outQueue.enqueue(OutgoingPacket(kind: .audio, timestampMs: timestampMs(pts, base: base),
                                        body: FLV.aacAudioBody(sequenceHeader: false, data: aac)))
        pump()
    }

    private func timestampMs(_ pts: CMTime, base: CMTime) -> UInt32 {
        let ms = CMTimeGetSeconds(CMTimeSubtract(pts, base)) * 1000
        return UInt32(max(0, ms.rounded()))
    }

    // MARK: Failure & reconnect

    private func connectionLost(_ reason: String) {
        guard state != .stopping, state != .idle else { return }
        if case .failed = state { return }
        handshakeTimer?.cancel()
        let safeReason = Redaction.scrub(reason, secrets: [url?.streamKey ?? ""])
        Log.stream.error("stream connection lost: \(safeReason, privacy: .public)")
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        session = nil
        // Reconnect only after we were live once (a bad URL/key on first connect is reported instead).
        guard wantRunning, settings.stream.autoReconnect, everPublished,
              let delay = settings.stream.reconnect.delay(forAttempt: attempt, random01: Double.random(in: 0...1)) else {
            fail(safeReason)
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
        handshakeTimer?.cancel()
        reconnectWork?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        session = nil
        statsTimer?.cancel()
        statsTimer = nil
        setState(final)
    }

    private func setState(_ s: State) {
        state = s
        stats.state = s
        publishStats()
    }

    private func startStatsTimer() {
        statsTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.stats.bitrateKbps = Double(self.bytesThisSecond) * 8 / 1000
            self.bytesThisSecond = 0
            self.stats.droppedVideoFrames = self.outQueue.droppedVideoFrames
            self.stats.queuedMs = self.outQueue.queuedDurationMs
            self.stats.uptime = self.state == .live ? HostClock.now() - self.liveSince : 0
            if let e = self.encoderStatsProvider?() { self.stats.encoderHardware = e.hardware; self.stats.encoderDropped = e.dropped }
            self.publishStats()
        }
        t.resume()
        statsTimer = t
    }

    private func publishStats() {
        let s = stats
        DispatchQueue.main.async { self.onStats?(s) }
    }
}
#endif
