#if os(macOS)
import AudioToolbox
import Foundation
import LiveCoreCore
import OSLog

/// Online radio station (MP3 or AAC over HTTPS, from the Radio Browser directory) played into its
/// own mixer channel. The stream is read with URLSession, split into packets by an
/// AudioFileStream, decoded and resampled to 48 kHz by an AudioConverter, and queued in a jitter
/// buffer that a 5 ms timer drains into the channel in real time. ICY metadata gives the song title.
/// A dropped connection is retried with back-off while the station is meant to play.
///
/// Public API on the main thread; the stream work runs on its own queue.
public final class RadioInput: NSObject, URLSessionDataDelegate {
    public enum State: Equatable {
        case stopped, connecting, buffering, playing
        case reconnecting(inSeconds: Double)
        case failed(String)
    }

    public let id: String
    public let channel: MixerChannel
    public let station: RadioStation
    /// Main thread.
    public private(set) var state: State = .stopped
    public private(set) var nowPlaying: String?
    /// Playing or trying to (connecting, buffering, reconnecting).
    public var isActive: Bool {
        switch state {
        case .stopped, .failed: return false
        default: return true
        }
    }
    /// Main thread; state or song title changed.
    public var onChange: (() -> Void)?
    /// Frames decoded so far and the loudest sample (diagnostics and the CI check).
    public let decodedFrames = AtomicCounter()
    public let peak = AtomicFloat(0)

    private static let log = Logger(subsystem: "com.livecore.studio", category: "radio")
    private let queue = DispatchQueue(label: "livecore.radio", qos: .userInitiated)
    // Everything below is used on `queue` only.
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var wanted = false
    private var attempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var icy = ICYMetadataReader(metaInt: 0)
    private var parser: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var sourceChannels: UInt32 = 2
    private var outChannels: UInt32 = 2
    private var buffer = StreamAudioBuffer(capacity: 48_000 * 10, prebuffer: 48_000 * 3 / 2)
    private var feedTimer: DispatchSourceTimer?
    private var outL = [Float](repeating: 0, count: 4096)
    private var outR = [Float](repeating: 0, count: 4096)
    private var chunkL = [Float](repeating: 0, count: 480)
    private var chunkR = [Float](repeating: 0, count: 480)
    private var lastReported: State = .stopped
    private var receivedAudio = false
    private var parseErrors = 0

    /// Frames kept queued in the mixer channel (50 ms), like the test tone.
    private let channelTarget = 2400

    public init(id: String, station: RadioStation, channel: MixerChannel) {
        self.id = id; self.station = station; self.channel = channel
        super.init()
    }

    deinit {
        feedTimer?.cancel()
        session?.invalidateAndCancel()
        if let p = parser { AudioFileStreamClose(p) }
        if let c = converter { AudioConverterDispose(c) }
    }

    // MARK: Control (main thread)

    public func play() {
        queue.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.attempt = 0
            self.startFeed()
            self.connect()
        }
        countPlay()
    }

    public func stop() {
        queue.async {
            self.wanted = false
            self.reconnectWork?.cancel()
            self.disconnect()
            self.feedTimer?.cancel()
            self.feedTimer = nil
            self.buffer.reset()
            self.report(.stopped)
        }
    }

    public func togglePlay() { isActive ? stop() : play() }

    /// The directory ranks stations by plays and asks players to report them (fire and forget).
    private func countPlay() {
        guard let u = RadioBrowser.clickURL(server: RadioBrowser.servers[0], stationID: station.id) else { return }
        var r = URLRequest(url: u, timeoutInterval: 10)
        r.setValue(RadioBrowser.userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r).resume()
    }

    // MARK: Connection (queue)

    private func connect() {
        guard wanted, let url = URL(string: station.streamURL), Self.allowed(url) else {
            fail("Not an HTTPS stream")
            return
        }
        disconnect()
        report(.connecting)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15            // no data for 15 s: the connection is lost
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: ops)
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        req.setValue(RadioBrowser.userAgent, forHTTPHeaderField: "User-Agent")
        let t = s.dataTask(with: req)
        session = s
        task = t
        receivedAudio = false
        parseErrors = 0
        t.resume()
    }

    /// HTTPS only; plain HTTP just to this Mac itself (local test servers).
    static func allowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    private func disconnect() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if let p = parser { AudioFileStreamClose(p) }
        parser = nil
        if let c = converter { AudioConverterDispose(c) }
        converter = nil
    }

    private func connectionLost(_ reason: String) {
        guard wanted else { return }
        disconnect()
        // A station that never sent audio after several tries is reported as failed.
        if attempt >= 5 && !receivedAudio { fail(reason); return }
        attempt += 1
        let delay = min(30, pow(2, Double(min(attempt, 5))))
        Self.log.info("radio \(self.station.name, privacy: .public): \(reason, privacy: .public); retry in \(delay) s")
        report(.reconnecting(inSeconds: delay))
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fail(_ reason: String) {
        wanted = false
        disconnect()
        feedTimer?.cancel()
        feedTimer = nil
        buffer.reset()
        Self.log.error("radio \(self.station.name, privacy: .public) failed: \(reason, privacy: .public)")
        report(.failed(reason))
    }

    private func report(_ s: State, title: String? = nil) {
        guard s != lastReported || title != nil else { return }
        lastReported = s
        DispatchQueue.main.async {
            self.state = s
            if let title { self.nowPlaying = title }
            if s == .stopped { self.nowPlaying = nil }
            self.onChange?()
        }
    }

    // MARK: URLSessionDataDelegate (queue)

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard session === self.session, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            connectionLost("HTTP \(http.statusCode)")
            return
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("text/") || type.contains("mpegurl") || type.contains("scpls") || type.contains("html") {
            completionHandler(.cancel)
            fail("Not an audio stream (\(type))")
            return
        }
        icy = ICYMetadataReader(metaInt: Int(http.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0)
        let aac = type.contains("aac") || (type.isEmpty || type == "application/octet-stream") && station.isAAC
        guard openParser(aac: aac) else { completionHandler(.cancel); fail("Cannot open the audio parser"); return }
        report(.buffering)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard session === self.session, let p = parser else { return }
        let r = icy.feed([UInt8](data))
        if let t = r.titles.last { report(lastReported, title: t) }
        guard !r.audio.isEmpty else { return }
        let st = r.audio.withUnsafeBytes { AudioFileStreamParseBytes(p, UInt32($0.count), $0.baseAddress!, []) }
        if st != noErr {
            // Junk between frames (some servers send it after a reconnect): skip it, but give up on
            // a stream that never parses.
            parseErrors += 1
            if parseErrors > 50 && !receivedAudio { fail("Unsupported audio format") }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session else { return }
        connectionLost(error?.localizedDescription ?? "Stream ended")
    }

    // MARK: Decoding (queue)

    private func openParser(aac: Bool) -> Bool {
        if let p = parser { AudioFileStreamClose(p); parser = nil }
        if let c = converter { AudioConverterDispose(c); converter = nil }
        var p: AudioFileStreamID?
        let me = Unmanaged.passUnretained(self).toOpaque()
        let st = AudioFileStreamOpen(me, { client, stream, property, _ in
            let radio = Unmanaged<RadioInput>.fromOpaque(client).takeUnretainedValue()
            if property == kAudioFileStreamProperty_ReadyToProducePackets { radio.makeConverter(stream) }
        }, { client, bytes, packets, data, descriptions in
            let radio = Unmanaged<RadioInput>.fromOpaque(client).takeUnretainedValue()
            let descs: UnsafeMutablePointer<AudioStreamPacketDescription>? = descriptions
            radio.decode(bytes: bytes, packets: packets, data: data, descriptions: descs)
        }, aac ? kAudioFileAAC_ADTSType : kAudioFileMP3Type, &p)
        guard st == noErr, let p else { return false }
        parser = p
        return true
    }

    private func makeConverter(_ stream: AudioFileStreamID) {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              asbd.mChannelsPerFrame > 0 else { return }
        sourceChannels = asbd.mChannelsPerFrame
        outChannels = min(asbd.mChannelsPerFrame, 2)
        var out = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: outChannels,
            mBitsPerChannel: 32, mReserved: 0)
        if let c = converter { AudioConverterDispose(c); converter = nil }
        var c: AudioConverterRef?
        guard AudioConverterNew(&asbd, &out, &c) == noErr, let c else { return }
        // Some AAC streams describe their codec setup in a magic cookie.
        var cookieSize: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr {
                AudioConverterSetProperty(c, kAudioConverterDecompressionMagicCookie, cookieSize, cookie)
            }
        }
        converter = c
    }

    /// Packets handed to the converter by `inputProc` (valid during one parser callback).
    private final class PacketFeed {
        let data: UnsafeRawPointer
        let bytes: UInt32
        let packets: UInt32
        let descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
        let channels: UInt32
        var consumed = false
        init(data: UnsafeRawPointer, bytes: UInt32, packets: UInt32,
             descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?, channels: UInt32) {
            self.data = data; self.bytes = bytes; self.packets = packets; self.descriptions = descriptions; self.channels = channels
        }
    }

    /// Status the input callback returns when this call's packets are used up (not an error).
    private static let noMoreInput: OSStatus = 0x6E6F6D6F   // 'nomo'

    private func decode(bytes: UInt32, packets: UInt32, data: UnsafeRawPointer,
                        descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let c = converter, packets > 0 else { return }
        let feed = PacketFeed(data: data, bytes: bytes, packets: packets, descriptions: descriptions, channels: sourceChannels)
        let feedPtr = Unmanaged.passUnretained(feed).toOpaque()
        let capacity = outL.count
        let abl = AudioBufferList.allocate(maximumBuffers: Int(outChannels))
        defer { free(abl.unsafeMutablePointer) }
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                while true {
                    abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity * 4), mData: l.baseAddress)
                    if outChannels > 1 { abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity * 4), mData: r.baseAddress) }
                    var frames = UInt32(capacity)
                    let st = AudioConverterFillComplexBuffer(c, { _, ioPackets, ioData, outDescriptions, user in
                        let feed = Unmanaged<PacketFeed>.fromOpaque(user!).takeUnretainedValue()
                        if feed.consumed {
                            ioPackets.pointee = 0
                            return RadioInput.noMoreInput
                        }
                        feed.consumed = true
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers = AudioBuffer(mNumberChannels: feed.channels, mDataByteSize: feed.bytes,
                                                              mData: UnsafeMutableRawPointer(mutating: feed.data))
                        ioPackets.pointee = feed.packets
                        outDescriptions?.pointee = feed.descriptions
                        return noErr
                    }, feedPtr, &frames, abl.unsafeMutablePointer, nil)
                    if frames > 0 {
                        receivedAudio = true
                        attempt = 0
                        if outChannels == 1 { r.baseAddress!.update(from: l.baseAddress!, count: Int(frames)) }
                        _ = decodedFrames.add(UInt64(frames))
                        var top = peak.value
                        for k in 0..<Int(frames) { top = max(top, abs(l[k]), abs(r[k])) }
                        peak.value = top
                        buffer.append(left: l.baseAddress!, right: r.baseAddress!, count: Int(frames))
                    }
                    // Done with this call's packets, or an error: wait for the next ones.
                    if st != noErr || frames == 0 { break }
                }
            }
        }
    }

    // MARK: Feeding the mixer (queue)

    private func startFeed() {
        guard feedTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.feedMixer() }
        t.resume()
        feedTimer = t
    }

    private func feedMixer() {
        let n = chunkL.count
        chunkL.withUnsafeMutableBufferPointer { l in
            chunkR.withUnsafeMutableBufferPointer { r in
                while channel.ringL.availableToRead < channelTarget {
                    let got = buffer.read(left: l.baseAddress!, right: r.baseAddress!, count: n)
                    if got == 0 { break }
                    _ = channel.ringL.write(l.baseAddress!, count: got)
                    _ = channel.ringR.write(r.baseAddress!, count: got)
                }
            }
        }
        switch lastReported {
        case .buffering, .playing:
            report(buffer.isBuffering ? .buffering : .playing)
        default:
            break
        }
    }
}
#endif
