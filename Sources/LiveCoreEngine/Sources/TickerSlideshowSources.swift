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
    public var config: TickerConfig { lock.withLock { shownConfig } }
    private var cfg: TickerConfig
    private var shownConfig: TickerConfig
    private let outputSize: PixelSize
    private let queue = DispatchQueue(label: "livecore.ticker", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    // Queue state.
    /// The text drawn in tiles of at most `tileWidth` pixels (very long text exceeds CoreGraphics / IOSurface limits).
    private var tiles: [CGImage] = []
    private var stripWidth = 0
    private static let tileWidth = 4096
    private var canvas = PixelSize(width: 2, height: 2)
    private var pool: CVPixelBufferPool?
    private var startTime = HostClock.now()
    private var pausedAt: Double?
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    public init(id: InputID, config: TickerConfig, outputSize: PixelSize) {
        self.id = id
        cfg = config.clamped
        shownConfig = cfg
        self.outputSize = outputSize
        name = "Ticker"
        queue.sync { _ = reloadTextFile(); rebuild() }
    }

    // Text file (queue): modification date + size of the last read, and a tick counter for polling.
    private var fileStamp: (Date?, Int)?
    private var pollCount = 0

    /// Re-reads `textFilePath` when it changed. Returns true when the text changed.
    private func reloadTextFile() -> Bool {
        guard let path = cfg.textFilePath, !path.isEmpty else { fileStamp = nil; return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let stamp = (attrs?[.modificationDate] as? Date, (attrs?[.size] as? NSNumber)?.intValue ?? -1)
        if let f = fileStamp, f.0 == stamp.0, f.1 == stamp.1 { return false }
        fileStamp = stamp
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard text != cfg.text else { return false }
        cfg.text = text
        lock.withLock { shownConfig.text = text }
        return true
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
        lock.withLock { shownConfig = c }
        queue.async { [weak self] in
            guard let self else { return }
            let restart = c.text != self.cfg.text || c.textFilePath != self.cfg.textFilePath
            self.cfg = c
            self.fileStamp = nil
            _ = self.reloadTextFile()
            self.rebuild()
            if restart { self.startTime = HostClock.now(); self.pausedAt = nil; self.lock.withLock { self.paused = false } }
        }
    }

    /// Read from the UI (context menus) without waiting on the render queue.
    public var isPaused: Bool { lock.withLock { paused } }
    private var paused = false
    public func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
        queue.async { [weak self] in
            guard let self else { return }
            let now = HostClock.now()
            if paused, self.pausedAt == nil { self.pausedAt = now }
            if !paused, let p = self.pausedAt { self.startTime += now - p; self.pausedAt = nil }
        }
    }
    /// Starts the text again from the right edge.
    public func restart() {
        lock.withLock { paused = false }
        queue.async { [weak self] in self?.startTime = HostClock.now(); self?.pausedAt = nil }
    }

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
        var made: [CGImage] = []
        var x0 = 0
        while x0 < w {
            let tw = min(Self.tileWidth, w - x0)
            guard let ctx = CGContext(data: nil, width: tw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { break }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            s.draw(at: NSPoint(x: 1 - x0, y: 1))
            NSGraphicsContext.restoreGraphicsState()
            if let img = ctx.makeImage() { made.append(img) }
            x0 += tw
        }
        tiles = made
        stripWidth = w
    }

    private func tick() {
        pollCount += 1
        if pollCount >= 120 {   // every ~2 s
            pollCount = 0
            if reloadTextFile() { rebuild() }
        }
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
            if !tiles.isEmpty {
                var x = TickerMath.offset(elapsed: elapsed, speed: config.speed * scale,
                                          stripWidth: Double(stripWidth), viewWidth: Double(w))
                ctx.interpolationQuality = .medium
                for tile in tiles {
                    let tw = Double(tile.width)
                    if x < Double(w), x + tw > 0 {
                        let y = (Double(h) - Double(tile.height)) / 2
                        ctx.draw(tile, in: CGRect(x: x, y: y, width: tw, height: Double(tile.height)))
                    }
                    x += tw
                }
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
    public var kenBurns: Bool { queue.sync { kb } }
    /// Folder watched for added / removed photos (nil when photos were picked one by one).
    public var folder: URL? { queue.sync { dir } }
    private var list: [URL], iv: Double, fd: Double, lp: Bool, kb: Bool, dir: URL?
    private var pollCount = 0
    private let outputSize: PixelSize
    private let queue = DispatchQueue(label: "livecore.slideshow", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    // Queue state.
    private var cache: [Int: CGImage] = [:]
    private var failed = Set<Int>()
    private var pool: CVPixelBufferPool?
    private var startTime = HostClock.now()
    private var pausedAt: Double?
    private var lastDrawn: (Int, Int?, Int, Int)?
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

    public init(id: InputID, urls: [URL], interval: Double, fade: Double, loop: Bool, kenBurns: Bool = false,
                folder: URL? = nil, outputSize: PixelSize) {
        self.id = id; list = urls; iv = interval; fd = fade; lp = loop; kb = kenBurns; dir = folder
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

    public func update(urls: [URL], interval: Double, fade: Double, loop: Bool, kenBurns: Bool, folder: URL?) {
        queue.async { [weak self] in
            guard let self else { return }
            let changed = urls != self.list
            self.list = urls; self.iv = interval; self.fd = fade; self.lp = loop; self.kb = kenBurns; self.dir = folder
            if changed { self.cache = [:]; self.failed = []; self.startTime = HostClock.now(); self.pausedAt = nil; self.lock.withLock { self.paused = false } }
            self.lastDrawn = nil
        }
    }

    public var index: Int { lock.withLock { shownIndex } }
    /// Read from the UI (context menus) without waiting on the render queue.
    public var isPaused: Bool { lock.withLock { paused } }
    private var paused = false
    public func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
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

    /// Picks up photos added to or removed from the watched folder, staying on the photo shown.
    private func rescanFolder() {
        guard let dir else { return }
        let found = Self.images(inFolder: dir)
        guard !found.isEmpty, found != list else { return }
        let shown = list.indices.contains(index) ? list[index] : nil
        let oldIndex = index
        list = found
        cache = [:]; failed = []; lastDrawn = nil
        if let shown, let ni = found.firstIndex(of: shown) {
            startTime -= Double(ni - oldIndex) * max(iv, 0.5)
        }
    }

    private func tick() {
        pollCount += 1
        if pollCount >= 150 { pollCount = 0; rescanFolder() }   // every ~5 s
        guard !list.isEmpty else { setStatus(.noSignal("No images")); return }
        let elapsed = (pausedAt ?? HostClock.now()) - startTime
        let pos = SlideshowMath.position(elapsed: elapsed, count: list.count, interval: iv, fade: fd, loop: lp)
        let mixStep = Int((pos.mix * 30).rounded())
        // Ken Burns moves every frame (a paused or finished show stands still).
        let motion = kb && pausedAt == nil && !pos.finished
        let timeStep = motion ? Int(elapsed * 30) : 0
        if let l = lastDrawn, l.0 == pos.index, l.1 == pos.next, l.2 == mixStep, l.3 == timeStep { return }
        let ivc = max(iv, 0.5)
        let within = max(elapsed, 0) - (max(elapsed, 0) / ivc).rounded(.down) * ivc
        var prog = SlideshowMath.motionProgress(within: within, interval: iv, fade: fd)
        if pos.finished { prog = (1, 0) }
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
            ctx.interpolationQuality = kb ? .medium : .high
            func drawFit(_ img: CGImage, alpha: Double, index: Int, progress: Double) {
                let s = min(Double(w) / Double(img.width), Double(h) / Double(img.height))
                let dw = Double(img.width) * s, dh = Double(img.height) * s
                let fit = CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh)
                ctx.saveGState()
                ctx.setAlpha(CGFloat(alpha))
                if kb {
                    // Draw the whole photo enlarged so that the Ken Burns crop fills the fitted area.
                    let r = SlideshowMath.kenBurnsRect(progress: progress, index: index)
                    let fw = dw / r.width, fh = dh / r.height
                    ctx.clip(to: fit)
                    ctx.draw(img, in: CGRect(x: fit.minX - r.x * fw, y: fit.minY - (1 - r.y - r.height) * fh, width: fw, height: fh))
                } else {
                    ctx.draw(img, in: fit)
                }
                ctx.restoreGState()
            }
            if let a { drawFit(a, alpha: 1, index: pos.index, progress: prog.current) }
            if let b, let ni = pos.next { drawFit(b, alpha: pos.mix, index: ni, progress: prog.next) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        lastDrawn = (pos.index, pos.next, mixStep, timeStep)
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
