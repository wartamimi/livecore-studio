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
    private var labelImage: CGImage?
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

    // Feed (queue): next fetch time and whether a request is running.
    private var nextFeedFetch = 0.0
    private var feedInFlight = false
    private var feedState = ""
    /// Last feed result for the UI ("12 items, 14:05" or the error).
    public var feedStatus: String { lock.withLock { feedState } }

    private var hasFeed: Bool { !(cfg.feedURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    private func setFeedStatus(_ s: String) { lock.withLock { feedState = s } }

    /// Starts a feed request when one is due (queue).
    private func pollFeed() {
        guard hasFeed, !feedInFlight, HostClock.now() >= nextFeedFetch else { return }
        let raw = (cfg.feedURL ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else {
            setFeedStatus("Invalid feed address (use https://…)")
            nextFeedFetch = HostClock.now() + cfg.feedRefreshSeconds
            return
        }
        feedInFlight = true
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("LiveCore Studio", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async { self.feedArrived(url: raw, data: data, code: code, error: error) }
        }.resume()
    }

    private func feedArrived(url: String, data: Data?, code: Int, error: Error?) {
        feedInFlight = false
        guard url == (cfg.feedURL ?? "").trimmingCharacters(in: .whitespaces) else { nextFeedFetch = 0; return }   // changed meanwhile
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let error {
            setFeedStatus("Feed error: \(error.localizedDescription)")
            nextFeedFetch = HostClock.now() + 60   // retry sooner than the normal refresh
            return
        }
        guard (200..<300).contains(code), let data else {
            setFeedStatus("Feed error: HTTP \(code)")
            nextFeedFetch = HostClock.now() + 60
            return
        }
        nextFeedFetch = HostClock.now() + cfg.feedRefreshSeconds
        guard data.count <= 5_000_000 else { setFeedStatus("Feed error: larger than 5 MB"); return }
        let xml = String(decoding: data, as: UTF8.self)
        let titles = FeedTitles.parse(xml)
        guard !titles.isEmpty else { setFeedStatus("Feed has no items (\(f.string(from: Date())))"); return }
        setFeedStatus("\(titles.count) items, \(f.string(from: Date()))")
        let text = titles.joined(separator: "\n")
        guard text != cfg.text else { return }
        cfg.text = text
        lock.withLock { shownConfig.text = text }
        rebuild()
    }

    /// Re-reads `textFilePath` when it changed. Returns true when the text changed.
    private func reloadTextFile() -> Bool {
        guard !hasFeed, let path = cfg.textFilePath, !path.isEmpty else { fileStamp = nil; return false }
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
            let restart = c.text != self.cfg.text || c.textFilePath != self.cfg.textFilePath || c.feedURL != self.cfg.feedURL
            if c.feedURL != self.cfg.feedURL || c.feedRefreshMinutes != self.cfg.feedRefreshMinutes {
                self.nextFeedFetch = 0
                self.setFeedStatus("")
            }
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
        let s = TickerRenderer.attributedText(config, scale: scale)
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
        labelImage = TickerRenderer.labelImage(config, scale: scale, bandHeight: h)
    }

    private func tick() {
        pollCount += 1
        if pollCount >= 120 {   // every ~2 s
            pollCount = 0
            if reloadTextFile() { rebuild() }
        }
        pollFeed()
        guard let pool else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return }
        let elapsed = (pausedAt ?? HostClock.now()) - startTime
        let w = canvas.width, h = canvas.height
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            TickerRenderer.drawBand(ctx, cfg, width: w, height: h, scale: scale, tiles: tiles, stripWidth: stripWidth,
                                    label: labelImage, elapsed: elapsed)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        lock.withLock { frame = pb }
    }

    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

/// Running-text drawing shared by `TickerSource` (every frame) and the Title Designer preview.
public enum TickerRenderer {
    /// The scrolled text: items joined with the (coloured) separator, in the chosen font.
    public static func attributedText(_ c: TickerConfig, scale: Double) -> NSAttributedString {
        let font = TitleRenderer.font(family: c.fontFamily, size: c.fontSize * scale, weight: c.textWeight, italic: c.italic ?? false)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c.textColor.nsColor]
        if c.shadow == true {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.8)
            sh.shadowBlurRadius = 6 * scale
            sh.shadowOffset = NSSize(width: 2 * scale, height: -2 * scale)
            attrs[.shadow] = sh
        }
        let text = c.scrollText
        let out = NSMutableAttributedString(string: text.isEmpty ? " " : text, attributes: attrs)
        if let sc = c.separatorColor, !c.separatorText.isEmpty {
            let ns = out.string as NSString
            var r = ns.range(of: c.separatorText)
            while r.location != NSNotFound {
                out.addAttribute(.foregroundColor, value: sc.nsColor, range: r)
                let next = r.location + r.length
                r = ns.range(of: c.separatorText, options: [], range: NSRange(location: next, length: ns.length - next))
            }
        }
        return out
    }

    /// Label box (BREAKING, NEWS…) as tall as the band, or nil.
    public static func labelImage(_ c: TickerConfig, scale: Double, bandHeight h: Int) -> CGImage? {
        let text = c.labelText
        guard !text.isEmpty, h > 0 else { return nil }
        let font = TitleRenderer.font(family: c.fontFamily, size: c.fontSize * scale * 0.8, weight: .heavy, italic: false)
        let s = NSAttributedString(string: text.uppercased(), attributes: [
            .font: font, .foregroundColor: (c.labelTextColor ?? ProjectColor(r: 1, g: 1, b: 1)).nsColor, .kern: 1.5 * scale])
        let size = s.size()
        let pad = 22 * scale
        let w = max(2, Int((size.width + 2 * pad).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor((c.labelColor ?? ProjectColor(r: 1, g: 1, b: 1)).nsColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        s.draw(at: NSPoint(x: pad, y: (Double(h) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// One frame of the band (`width` × `height` pixels, CoreGraphics y-up): bar, scrolling text
    /// in the area right of the label, then the label.
    public static func drawBand(_ ctx: CGContext, _ c: TickerConfig, width w: Int, height h: Int, scale: Double,
                                tiles: [CGImage], stripWidth: Int, label: CGImage?, elapsed: Double) {
        if c.showBar {
            ctx.setFillColor(c.barColor.nsColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let lw = label.map { Double($0.width) } ?? 0
        let view = max(Double(w) - lw, 1)
        if !tiles.isEmpty {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: lw, y: 0, width: view, height: Double(h)))
            var x = lw + TickerMath.offset(elapsed: elapsed, speed: c.speed * scale, stripWidth: Double(stripWidth),
                                           viewWidth: view, direction: c.scrollDirection)
            ctx.interpolationQuality = .medium
            for tile in tiles {
                let tw = Double(tile.width)
                if x < Double(w), x + tw > lw {
                    let y = (Double(h) - Double(tile.height)) / 2
                    ctx.draw(tile, in: CGRect(x: x, y: y, width: tw, height: Double(tile.height)))
                }
                x += tw
            }
            ctx.restoreGState()
        }
        if let label { ctx.draw(label, in: CGRect(x: 0, y: 0, width: label.width, height: h)) }
    }

    /// Whole-picture preview (transparent, band at its position) for the Title Designer.
    public static func preview(_ c0: TickerConfig, width W: Int, height H: Int, elapsed: Double? = nil) -> CGImage? {
        let c = c0.clamped
        let scale = Double(H) / 1080
        let bandH = max(4, Int((Double(H) * c.bandHeight).rounded()))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        let s = attributedText(c, scale: scale)
        let size = s.size()
        let sw = max(2, Int(size.width.rounded(.up)) + 2), sh = max(2, Int(size.height.rounded(.up)) + 2)
        guard let tctx = CGContext(data: nil, width: min(sw, 16_384), height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: tctx, flipped: false)
        s.draw(at: NSPoint(x: 1, y: 1))
        NSGraphicsContext.restoreGraphicsState()
        let tiles = tctx.makeImage().map { [$0] } ?? []
        let label = labelImage(c, scale: scale, bandHeight: bandH)
        // Default: the text has just come in from the edge, so the start of it is readable.
        let lw = Double(label?.width ?? 0)
        let t = elapsed ?? (Double(W) - lw) * 0.8 / max(c.speed * scale, 1)
        let rect = c.layerRect
        ctx.saveGState()
        ctx.translateBy(x: 0, y: Double(H) * (1 - rect.y - rect.height))
        drawBand(ctx, c, width: W, height: bandH, scale: scale, tiles: tiles, stripWidth: sw, label: label, elapsed: t)
        ctx.restoreGState()
        return ctx.makeImage()
    }
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
