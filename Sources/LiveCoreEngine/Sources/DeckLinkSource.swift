#if os(macOS)
import Accelerate
import CDeckLink
import CoreVideo
import Foundation
import LiveCoreCore

/// Blackmagic DeckLink / UltraStudio / Intensity through the installed Desktop Video driver.
public enum DeckLinkRuntime {
    public static var isAvailable: Bool { lc_decklink_available() }
    public static let downloadURL = URL(string: LC_DECKLINK_DOWNLOAD_URL)!

    public static var version: String {
        var buf = [CChar](repeating: 0, count: 64)
        lc_decklink_api_version(&buf, Int32(buf.count))
        return String(cString: buf)
    }

    public struct Device: Equatable, Sendable, Identifiable {
        public var index: Int
        public var name: String
        public var connections: Int64
        public var formatDetection: Bool
        public var id: Int { index }
    }

    public struct Mode: Equatable, Sendable, Identifiable {
        public var code: UInt32
        public var width: Int, height: Int
        public var fps: Double
        public var interlaced: Bool
        public var name: String
        public var id: UInt32 { code }
    }

    /// Capture devices (slow-ish: call off the main thread or rarely).
    public static func devices() -> [Device] {
        guard isAvailable else { return [] }
        return (0..<Int(lc_decklink_device_count())).compactMap { i in
            var buf = [CChar](repeating: 0, count: 256)
            guard lc_decklink_device_name(Int32(i), &buf, Int32(buf.count)) else { return nil }
            var conn: Int64 = 0
            var detect = false
            _ = lc_decklink_device_caps(Int32(i), &conn, &detect)
            return Device(index: i, name: String(cString: buf), connections: conn, formatDetection: detect)
        }
    }

    public static func modes(device index: Int) -> [Mode] {
        guard isAvailable else { return [] }
        var raw = [lc_decklink_mode](repeating: lc_decklink_mode(), count: 128)
        let n = Int(lc_decklink_modes(Int32(index), &raw, Int32(raw.count)))
        return raw.prefix(n).map { m in
            var m = m
            let name = withUnsafeBytes(of: &m.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return Mode(code: m.mode, width: Int(m.width), height: Int(m.height), fps: m.fps, interlaced: m.interlaced, name: name)
        }
    }

    /// Index of the device saved in a project: same name first (cards can be re-ordered), then position.
    public static func resolve(_ c: ProjectDeckLink, in list: [Device]) -> Int? {
        let named = list.filter { $0.name == c.deviceName }
        if let exact = named.first(where: { $0.index == c.deviceIndex }) { return exact.index }
        if let first = named.first { return first.index }
        return nil
    }
}

/// A DeckLink capture input (0.54.0): 8-bit 4:2:2 (or RGB) frames from the card, converted to
/// BGRA with vImage; embedded audio (2 channels, 48 kHz) on its own mixer channel. The input
/// format is detected by the card when it can, else the chosen mode is used.
public final class DeckLinkSource: VideoSource, @unchecked Sendable {
    public let id: InputID
    public let kind: InputKind = .decklink
    public var name: String
    public private(set) var status: SourceStatus = .starting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    public var onStatusChange: ((SourceStatus) -> Void)?
    public var audioChannelProvider: (() -> MixerChannel)?
    public private(set) var config: ProjectDeckLink

    public struct Signal: Equatable, Sendable {
        public var width = 0, height = 0
        public var fps: Double = 0
        public var mode: UInt32 = 0
        public var rgb = false
        public var noSignal = false
        public var frames = 0
    }
    public var signal: Signal { sink.lock.withLock { sink.signal } }

    private let sink: DeckLinkSink
    private var capture: OpaquePointer?
    private var audioChannel: MixerChannel?
    private var watchdog: Timer?

    public init(id: InputID, config: ProjectDeckLink) {
        self.id = id
        self.config = config
        self.name = config.displayName
        self.sink = DeckLinkSink()
    }

    public func currentFrame() -> CVPixelBuffer? { sink.slot.get() }

    /// Main thread.
    public func start() {
        guard capture == nil else { return }
        guard DeckLinkRuntime.isAvailable else {
            status = .error("Blackmagic Desktop Video is not installed (\(DeckLinkRuntime.downloadURL.absoluteString))")
            return
        }
        guard let index = DeckLinkRuntime.resolve(config, in: DeckLinkRuntime.devices()) else {
            status = .noSignal("\(config.displayName) is not connected")
            scheduleRetry()
            return
        }
        if config.wantsAudio, audioChannel == nil, let provider = audioChannelProvider { audioChannel = provider() }
        sink.channel = config.wantsAudio ? audioChannel : nil
        var callbacks = lc_decklink_callbacks()
        callbacks.video = { ctx, bytes, w, h, rowBytes, fmt, noSignal in
            guard let ctx, let bytes else { return }
            Unmanaged<DeckLinkSink>.fromOpaque(ctx).takeUnretainedValue()
                .video(bytes, width: Int(w), height: Int(h), rowBytes: Int(rowBytes), format: fmt, noSignal: noSignal)
        }
        callbacks.audio = { ctx, samples, frames, channels in
            guard let ctx, let samples else { return }
            Unmanaged<DeckLinkSink>.fromOpaque(ctx).takeUnretainedValue().audio(samples, frames: Int(frames), channels: Int(channels))
        }
        callbacks.format = { ctx, mode, w, h, fps, rgb in
            guard let ctx else { return }
            Unmanaged<DeckLinkSink>.fromOpaque(ctx).takeUnretainedValue().format(mode: mode, width: Int(w), height: Int(h), fps: fps, rgb: rgb)
        }
        var err = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passUnretained(sink).toOpaque()
        let h = lc_decklink_open(Int32(index), config.mode ?? 0, ProjectDeckLink.connectionBit(config.connection),
                                 config.wantsAudio ? 2 : 0, callbacks, ctx, &err, Int32(err.count))
        guard let h else {
            status = .error(String(cString: err))
            scheduleRetry()
            return
        }
        capture = h
        status = .noSignal("waiting for video")
        // Status from the capture thread's counters, once a second.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    public func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let h = capture { lc_decklink_close(h) }
        capture = nil
    }

    /// Other device / mode / connection (main thread).
    public func reconfigure(_ c: ProjectDeckLink) {
        stop()
        config = c
        sink.slot.clear()
        start()
    }

    deinit {
        watchdog?.invalidate()
        if let h = capture { lc_decklink_close(h) }
    }

    private func scheduleRetry() {
        // A card plugged in later (Thunderbolt UltraStudio) or freed by another app.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, self.capture == nil else { return }
            self.watchdog = nil
            self.start()
        }
    }

    private func poll() {
        let s = signal
        let fresh = HostClock.now() - sink.slot.lastUpdate < 1
        if s.noSignal { status = .noSignal("no input signal on \(config.connection?.uppercased() ?? "the card")") }
        else if fresh { status = .live }
        else { status = .noSignal("no frames from the card") }
    }
}

/// Receives the DeckLink callbacks (capture thread).
final class DeckLinkSink: @unchecked Sendable {
    let slot = FrameSlot()
    let lock = UnfairLock()
    var signal = DeckLinkSource.Signal()
    var channel: MixerChannel?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var conversion709 = vImage_YpCbCrToARGB()
    private var conversion601 = vImage_YpCbCrToARGB()
    private var floatL = [Float](), floatR = [Float]()
    private var windowStart = HostClock.now(), windowFrames = 0

    init() {
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &conversion709,
                                                      kvImage422CbYpCrYp8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &conversion601,
                                                      kvImage422CbYpCrYp8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
    }

    func format(mode: UInt32, width: Int, height: Int, fps: Double, rgb: Bool) {
        lock.withLock { signal.mode = mode; signal.width = width; signal.height = height; signal.fps = fps; signal.rgb = rgb }
    }

    func video(_ bytes: UnsafePointer<UInt8>, width w: Int, height h: Int, rowBytes: Int, format: UInt32, noSignal: Bool) {
        let now = HostClock.now()
        windowFrames += 1
        if now - windowStart >= 1 {
            let fps = Double(windowFrames) / (now - windowStart)
            lock.withLock { signal.fps = fps }
            windowStart = now; windowFrames = 0
        }
        lock.withLock { signal.noSignal = noSignal; signal.width = w; signal.height = h; signal.frames += 1 }
        guard !noSignal, w > 0, h > 0 else { return }
        if pool == nil || poolSize != (w, h) {
            pool = PixelBufferFactory.makePool(width: w, height: h)
            poolSize = (w, h)
        }
        var out: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) }
        guard let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return }
        let dstRow = CVPixelBufferGetBytesPerRow(pb)
        if format == 0x4247_5241 {   // 'BGRA'
            for y in 0..<h { memcpy(dst + y * dstRow, bytes + y * rowBytes, min(w * 4, rowBytes, dstRow)) }
        } else {                     // '2vuy'
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: bytes), height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: rowBytes)
            var d = vImage_Buffer(data: dst, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dstRow)
            let permute: [UInt8] = [3, 2, 1, 0]   // ARGB → BGRA
            if h > 576 {
                vImageConvert_422CbYpCrYp8ToARGB8888(&src, &d, &conversion709, permute, 255, vImage_Flags(kvImageNoFlags))
            } else {
                vImageConvert_422CbYpCrYp8ToARGB8888(&src, &d, &conversion601, permute, 255, vImage_Flags(kvImageNoFlags))
            }
        }
        slot.put(pb)
    }

    func audio(_ samples: UnsafePointer<Int16>, frames n: Int, channels: Int) {
        guard let channel, n > 0, channels > 0 else { return }
        if floatL.count < n { floatL = [Float](repeating: 0, count: n); floatR = floatL }
        let scale: Float = 1 / 32768
        for i in 0..<n {
            floatL[i] = Float(samples[i * channels]) * scale
            floatR[i] = Float(samples[i * channels + (channels > 1 ? 1 : 0)]) * scale
        }
        floatL.withUnsafeBufferPointer { channel.ringL.write($0.baseAddress!, count: n) }
        floatR.withUnsafeBufferPointer { channel.ringR.write($0.baseAddress!, count: n) }
    }
}
#endif
