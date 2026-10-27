#if os(macOS)
import AppKit
import CoreVideo
import ImageIO
import LiveCoreCore

/// Scrolling text band (news ticker). The text is drawn once into a strip image; a 60 Hz timer on
/// its own queue copies the strip at the current offset into a small pooled buffer
/// (output width × band height), so the cost per frame is one image blit.
public final class TickerSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .ticker
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Current settings (state below is owned by `queue`).
    public var config: TickerConfig { queue.sync { cfg } }
    private var cfg: TickerConfig
    private let outputSize: PixelSize
    private let queue = DispatchQueue(label: "livecore.ticker", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    // Queue state.
    private var strip: CGImage?
    private var canvas = PixelSize(width: 2, height: 2)
    private var pool: CVPixelBufferPool?
    private var startTime = HostClock.now()
    private var pausedAt: Double?
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    public init(id: InputID, config: TickerConfig, outputSize: PixelSize) {
        self.id = id
        cfg = config.clamped
        self.outputSize = outputSize
        name = "Ticker"
        queue.sync { rebuild() }
    }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }
    public func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }

    public func update(_ c: TickerConfig) {
        let c = c.clamped
        queue.async { [weak self] in
            guard let self else { return }
            let restart = c.text != self.cfg.text
            self.cfg = c
            self.rebuild()
            if restart { self.startTime = HostClock.now(); self.pausedAt = nil }
        }
    }

    public var isPaused: Bool { queue.sync { pausedAt != nil } }
    public func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = HostClock.now()
            if paused, self.pausedAt == nil { self.pausedAt = now }
            if !paused, let p = self.pausedAt { self.startTime += now - p; self.pausedAt = nil }
        }
    }
    /// Starts the text again from the right edge.
    public func restart() { queue.async { [weak self] in self?.startTime = HostClock.now(); self?.pausedAt = nil } }

    private var scale: Double { Double(outputSize.height) / 1080 }

    private func rebuild() {
        let config = cfg
        let h = max(8, Int((Double(outputSize.height) * config.bandHeight).rounded()))
        canvas = PixelSize(width: max(16, outputSize.width), height: h)
        pool = PixelBufferFactory.makePool(width: canvas.width, height: canvas.height, minimumCount: 6)
        let font = NSFont.systemFont(ofSize: CGFloat(config.fontSize * scale), weight: .semibold)
        let text = config.text.replacingOccurrences(of: "\n", with: "   •   ")
        let s = NSAttributedString(string: text.isEmpty ? " " : text,
                                   attributes: [.font: font, .foregroundColor: config.textColor.nsColor])
        let size = s.size()
        let w = max(2, Int(size.width.rounded(.up)) + 2), sh = max(2, Int(size.height.rounded(.up)) + 2)
        guard let ctx = CGContext(data: nil, width: w, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { strip = nil; return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: NSPoint(x: 1, y: 1))
        NSGraphicsContext.restoreGraphicsState()
        strip = ctx.makeImage()
    }

    private func tick() {
        guard let pool else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        let config = cfg
        let elapsed = (pausedAt ?? HostClock.now()) - startTime
        let w = canvas.width, h = canvas.height
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            if config.showBar {
                ctx.setFillColor(config.barColor.nsColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            if let strip {
                let x = TickerMath.offset(elapsed: elapsed, speed: config.speed * scale,
                                          stripWidth: Double(strip.width), viewWidth: Double(w))
                let y = (Double(h) - Double(strip.height)) / 2
                ctx.interpolationQuality = .medium
                ctx.draw(strip, in: CGRect(x: x, y: y, width: Double(strip.width), height: Double(strip.height)))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        lock.withLock { frame = pb }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

/// Photo slideshow: images (aspect-fit on black at the output size) shown in turn with a
/// cross-fade. Images are decoded downscaled on the source's own queue, one ahead of the show.
public final class SlideshowSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .slideshow
    public var name: String
    public var status: SourceStatus { lock.withLock { st } }
    private var st: SourceStatus = .starting
    public var onStatusChange: ((SourceStatus) -> Void)?
    /// Current settings (owned by `queue`).
    public var urls: [URL] { queue.sync { list } }
    public var interval: Double { queue.sync { iv } }
    public var fade: Double { queue.sync { fd } }
    public var loop: Bool { queue.sync { lp } }
    private var list: [URL], iv: Double, fd: Double, lp: Bool
    private let outputSize: PixelSize
    private let queue = DispatchQueue(label: "livecore.slideshow", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    // Queue state.
    private var cache: [Int: CGImage] = [:]
    private var failed = Set<Int>()
    private var pool: CVPixelBufferPool?
    private var startTime = HostClock.now()
    private var pausedAt: Double?
    private var lastDrawn: (Int, Int?, Int)?
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?
    private var shownIndex = 0

    /// Image file types offered when a folder is picked.
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// Image files directly inside `folder`, sorted by name the way Finder sorts them.
    public static func images(inFolder folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public init(id: InputID, urls: [URL], interval: Double, fade: Double, loop: Bool, outputSize: PixelSize) {
        self.id = id; list = urls; iv = interval; fd = fade; lp = loop
        self.outputSize = outputSize
        name = urls.first?.deletingLastPathComponent().lastPathComponent ?? "Slideshow"
        pool = PixelBufferFactory.makePool(width: outputSize.width, height: outputSize.height, minimumCount: 4)
    }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }
    public func stop() { timer?.cancel(); timer = nil }
    deinit { timer?.cancel() }

    public func update(urls: [URL], interval: Double, fade: Double, loop: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = urls != self.list
            self.list = urls; self.iv = interval; self.fd = fade; self.lp = loop
            if changed { self.cache = [:]; self.failed = []; self.startTime = HostClock.now(); self.pausedAt = nil }
            self.lastDrawn = nil
        }
    }

    public var index: Int { lock.withLock { shownIndex } }
    public var isPaused: Bool { queue.sync { pausedAt != nil } }
    public func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = HostClock.now()
            if paused, self.pausedAt == nil { self.pausedAt = now }
            if !paused, let p = self.pausedAt { self.startTime += now - p; self.pausedAt = nil }
        }
    }
    /// Jumps to the start of image `index` (wrapped).
    public func go(to index: Int) {
        queue.async { [weak self] in
            guard let self, !self.list.isEmpty else { return }
            let n = self.list.count
            let i = ((index % n) + n) % n
            let now = HostClock.now()
            self.startTime = (self.pausedAt ?? now) - Double(i) * max(self.iv, 0.5) - 0.001
            self.lastDrawn = nil
        }
    }
    public func next() { go(to: index + 1) }
    public func previous() { go(to: index - 1) }

    private func image(_ i: Int) -> CGImage? {
        if let c = cache[i] { return c }
        guard !failed.contains(i), list.indices.contains(i),
              let src = CGImageSourceCreateWithURL(list[i] as CFURL, nil) else { failed.insert(i); return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(outputSize.width, outputSize.height)]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { failed.insert(i); return nil }
        cache[i] = img
        return img
    }

    private func tick() {
        guard !list.isEmpty else { setStatus(.noSignal("No images")); return }
        let elapsed = (pausedAt ?? HostClock.now()) - startTime
        let pos = SlideshowMath.position(elapsed: elapsed, count: list.count, interval: iv, fade: fd, loop: lp)
        let mixStep = Int((pos.mix * 30).rounded())
        if let l = lastDrawn, l.0 == pos.index, l.1 == pos.next, l.2 == mixStep { return }
        // Keep the shown, fading-in and following image decoded; drop the rest.
        let n = list.count
        let wanted: Set<Int> = [pos.index, (pos.index + 1) % n, pos.next ?? pos.index]
        for k in cache.keys where !wanted.contains(k) { cache[k] = nil }
        let a = image(pos.index)
        let b = pos.next.flatMap { image($0) }
        if pos.next == nil, n > 1 { _ = image((pos.index + 1) % n) }   // decode ahead while idle
        guard let pool else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        let w = outputSize.width, h = outputSize.height
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            func drawFit(_ img: CGImage, alpha: Double) {
                let s = min(Double(w) / Double(img.width), Double(h) / Double(img.height))
                let dw = Double(img.width) * s, dh = Double(img.height) * s
                ctx.setAlpha(CGFloat(alpha))
                ctx.draw(img, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
            }
            if let a { drawFit(a, alpha: 1) }
            if let b { drawFit(b, alpha: pos.mix) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        lastDrawn = (pos.index, pos.next, mixStep)
        lock.withLock { frame = pb; shownIndex = pos.index }
        setStatus(failed.count == n ? .error("Cannot decode the images") : .live)
    }

    private func setStatus(_ s: SourceStatus) {
        let changed: Bool = lock.withLock { let c = st != s; st = s; return c }
        if changed { DispatchQueue.main.async { [weak self] in self?.onStatusChange?(s) } }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}
#endif
