#if os(macOS)
import AppKit
import CoreText
import CoreVideo
import ImageIO
import LiveCoreCore

/// Still image (PNG/JPEG/HEIC/TIFF...) decoded once into an IOSurface-backed BGRA buffer.
/// PNG alpha is preserved (premultiplied), so logos work as overlays.
public final class ImageSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .image
    public var name: String
    public let url: URL
    public private(set) var status: SourceStatus = .starting { didSet { onStatusChange?(status) } }
    public var onStatusChange: ((SourceStatus) -> Void)?
    private var frame: CVPixelBuffer?

    public init(id: InputID, url: URL) {
        self.id = id; self.url = url; self.name = url.deletingPathExtension().lastPathComponent
    }

    public func start() {
        guard frame == nil else { return }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { status = .error("Cannot decode image"); return }
        // Cap at 4K to bound memory.
        let scale = min(1, 3840 / Double(max(img.width, img.height)))
        let w = max(2, Int(Double(img.width) * scale)), h = max(2, Int(Double(img.height) * scale))
        frame = PixelBufferFactory.draw(width: w, height: h) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        status = frame == nil ? .error("Out of memory creating image buffer") : .live
    }
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { frame }
}

/// Solid colour generator (bars/black/background). 16:9 buffer so .fit fills the canvas.
public final class ColorSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .color
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var color: NSColor
    private var frame: CVPixelBuffer?

    public init(id: InputID, color: NSColor, name: String? = nil) {
        self.id = id; self.color = color; self.name = name ?? "Colour"
        render()
    }
    public func setColor(_ c: NSColor) { color = c; render() }
    private func render() {
        let c = color.usingColorSpace(.sRGB) ?? color
        frame = PixelBufferFactory.draw(width: 160, height: 90) { ctx in
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
    }
    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { frame }
}

/// SMPTE-style colour bars (75 % bars, castellations, -I / white / +Q and a PLUGE), like the
/// "Colour Bars" input of vision mixers. Drawn once at the output size.
public final class ColorBarsSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .colorBars
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    private var frame: CVPixelBuffer?

    public init(id: InputID, size: PixelSize, name: String = "Colour Bars") {
        self.id = id; self.name = name
        frame = Self.render(width: max(2, size.width), height: max(2, size.height))
    }

    static func render(width w: Int, height h: Int) -> CVPixelBuffer? {
        PixelBufferFactory.draw(width: w, height: h) { ctx in
            func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
                CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            }
            let W = CGFloat(w), H = CGFloat(h)
            // CoreGraphics origin is bottom-left: draw the bands from the top down.
            func band(_ top: CGFloat, _ height: CGFloat, _ cells: [(CGFloat, CGColor)]) {
                var x: CGFloat = 0
                for (frac, color) in cells {
                    ctx.setFillColor(color)
                    let cw = (frac * W).rounded()
                    ctx.fill(CGRect(x: x, y: H - top - height, width: x + cw > W - 1 ? W - x : cw, height: height))
                    x += cw
                }
            }
            let seventh = 1.0 / 7.0
            let main = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191)]
            band(0, (H * 2 / 3).rounded(), main.map { (CGFloat(seventh), rgb($0.0, $0.1, $0.2)) })
            let castle = [(0, 0, 191), (19, 19, 19), (191, 0, 191), (19, 19, 19), (0, 191, 191), (19, 19, 19), (191, 191, 191)]
            band((H * 2 / 3).rounded(), (H / 12).rounded(), castle.map { (CGFloat(seventh), rgb($0.0, $0.1, $0.2)) })
            let top3 = (H * 2 / 3).rounded() + (H / 12).rounded()
            let q = 5.0 / 4.0 * seventh
            let pluge = seventh / 3
            band(top3, H - top3, [
                (CGFloat(q), rgb(0, 33, 76)), (CGFloat(q), rgb(255, 255, 255)), (CGFloat(q), rgb(50, 0, 106)),
                (CGFloat(q), rgb(19, 19, 19)),
                (CGFloat(pluge), rgb(9, 9, 9)), (CGFloat(pluge), rgb(19, 19, 19)), (CGFloat(pluge), rgb(29, 29, 29)),
                (CGFloat(seventh), rgb(19, 19, 19)),
            ])
        }
    }

    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { frame }
}

/// Empty, transparent canvas: a vMix-style scene whose picture is made of its layers only.
public final class SceneSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .scene
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    private let frame: CVPixelBuffer?

    public init(id: InputID, name: String) {
        self.id = id; self.name = name
        frame = PixelBufferFactory.draw(width: 32, height: 18) { _ in }   // cleared = transparent
    }
    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { frame }
}

/// Title / lower-third generator rendered with CoreText into a transparent buffer.
/// Re-rendered only when the text or style changes (never per frame).
public final class TextSource: VideoSource {
    /// Lower-third layouts. Raw values are stored in project files.
    public enum Layout: String, CaseIterable, Codable, Sendable {
        case barLeft      // coloured box behind left-aligned text (classic name/title strap)
        case fullWidth    // bar across the whole width, text left-aligned
        case centered     // no box, centred text with a drop shadow (captions, quotes)
    }

    public struct Style: Equatable {
        public var layout: Layout = .barLeft
        public var title: String
        public var subtitle: String
        public var titleSize: CGFloat = 54
        public var subtitleSize: CGFloat = 34
        public var textColor: NSColor = .white
        public var barColor: NSColor = NSColor(calibratedRed: 0.05, green: 0.27, blue: 0.62, alpha: 0.88)
        public var showBar = true
        /// Template-based title (0.34.0): full-output canvas, see `TitleDesign`. nil = the
        /// classic lower-third strip drawn from the fields above.
        public var design: TitleDesign?
        /// CSV / Google Sheets rows filling the text (0.37.0); applied by the app.
        public var dataSource: TitleDataSource?
        public init(title: String, subtitle: String = "") { self.title = title; self.subtitle = subtitle }
        public init(template: TitleTemplate, title: String? = nil, subtitle: String? = nil) {
            self.title = title ?? template.sample.title
            self.subtitle = subtitle ?? template.sample.subtitle
            design = template.defaultDesign
        }
    }

    public let id: InputID
    public let kind: InputKind = .text
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var style: Style
    private let canvasWidth: Int
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    private let outputSize: PixelSize
    private var canvasHeight: Int { isFullCanvas ? outputSize.height : max(64, outputSize.height / 4) }
    /// Template titles cover the whole output (placed full screen); classic titles are a strip
    /// of full width and 25% height (matches `LayoutPreset.lowerThird`).
    public var isFullCanvas: Bool { style.design != nil }

    public init(id: InputID, style: Style, outputSize: PixelSize) {
        self.id = id; self.style = style; self.name = style.title.isEmpty ? "Title" : style.title
        self.canvasWidth = outputSize.width
        self.outputSize = outputSize
        render()
    }

    public func update(_ s: Style) {
        if let t = animTimer { lock.withLock { t.cancel() }; animTimer = nil }
        style = s; name = s.title.isEmpty ? "Title" : s.title; render()
    }

    // Letter-by-letter animation: redrawn 30 times a second until every letter is in place. The
    // drawing runs on its own queue, so a busy main thread (menus, sheets) cannot make it stutter.
    private var animTimer: DispatchSourceTimer?
    private static let animQueue = DispatchQueue(label: "livecore.title-animation", qos: .userInteractive)

    /// Plays the title's text animation from the first letter (when it goes on air). Main thread.
    public func playTextAnimation() {
        guard let d = style.design, d.textAnimation != .off else { return }
        let title = style.title, subtitle = style.subtitle, size = outputSize
        let total = TextReveal(animation: d.textAnimation, delay: d.letterDelay)
            .totalDuration(letters: TitleRenderer.letterCount(title: title, subtitle: subtitle, design: d))
        if let old = animTimer { lock.withLock { old.cancel() } }
        let start = HostClock.now()
        let t = DispatchSource.makeTimerSource(queue: Self.animQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        t.setEventHandler { [weak self, weak t] in
            guard let self, let t, !t.isCancelled else { return }
            let e = HostClock.now() - start
            let pb = PixelBufferFactory.draw(width: size.width, height: size.height) { ctx in
                TitleRenderer.draw(d, title: title, subtitle: subtitle, in: ctx,
                                   width: Double(size.width), height: Double(size.height), elapsed: e >= total ? nil : e)
            }
            // A newer render (finish, text change) may have cancelled this animation meanwhile.
            self.lock.withLock { if !t.isCancelled { self.frame = pb } }
            if e >= total { t.cancel() }
        }
        animTimer = t
        t.resume()
    }

    /// Stops the animation and shows the finished title (when it leaves the air). Main thread.
    public func finishTextAnimation() {
        guard let t = animTimer else { return }
        animTimer = nil
        if t.isCancelled { return }   // already finished by itself
        lock.withLock { t.cancel() }
        render()
    }

    private func render(elapsed: Double? = nil) {
        if let design = style.design {
            let pb = PixelBufferFactory.draw(width: outputSize.width, height: outputSize.height) { ctx in
                TitleRenderer.draw(design, title: style.title, subtitle: style.subtitle, in: ctx,
                                   width: Double(outputSize.width), height: Double(outputSize.height), elapsed: elapsed)
            }
            lock.withLock { frame = pb }
            return
        }
        let w = canvasWidth, h = canvasHeight, st = style
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            let scale = CGFloat(w) / 1920
            let margin = 90 * scale
            if st.showBar && st.layout != .centered {
                ctx.setFillColor(st.barColor.cgColor)
                let barX = st.layout == .fullWidth ? 0 : margin * 0.6
                let barW = st.layout == .fullWidth ? CGFloat(w) : CGFloat(w) * 0.62
                ctx.fill(CGRect(x: barX, y: CGFloat(h) * 0.18, width: barW, height: CGFloat(h) * 0.64))
            }
            if st.layout == .centered {
                ctx.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 8 * scale,
                              color: NSColor.black.withAlphaComponent(0.8).cgColor)
            }
            let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: st.titleSize * scale, weight: .bold), .foregroundColor: st.textColor]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: st.subtitleSize * scale, weight: .regular), .foregroundColor: st.textColor.withAlphaComponent(0.9)]
            let title = NSAttributedString(string: st.title, attributes: titleAttrs)
            let sub = NSAttributedString(string: st.subtitle, attributes: subAttrs)
            let titleY = st.subtitle.isEmpty ? CGFloat(h) * 0.5 - title.size().height / 2 : CGFloat(h) * 0.48
            func x(_ s: NSAttributedString) -> CGFloat {
                st.layout == .centered ? (CGFloat(w) - s.size().width) / 2 : margin
            }
            title.draw(at: NSPoint(x: x(title), y: titleY))
            if !st.subtitle.isEmpty { sub.draw(at: NSPoint(x: x(sub), y: CGFloat(h) * 0.48 - sub.size().height - 4 * scale)) }
            NSGraphicsContext.restoreGraphicsState()
        }
        lock.withLock { frame = pb }
    }

    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

/// Draws a template title (`TitleDesign`) with CoreText: measures the text, asks `TitleLayout`
/// where boxes and text go, then fills the boxes and draws the text with outline and shadow.
public enum TitleRenderer {
    /// Draws into a bitmap context of `width` × `height` pixels (CoreGraphics y-up).
    /// `elapsed`: seconds since the title went on air, for the letter-by-letter animation (nil =
    /// every letter in place).
    public static func draw(_ design: TitleDesign, title: String, subtitle: String, in ctx: CGContext,
                            width W: Double, height H: Double, elapsed: Double? = nil) {
        let d = design.clamped()
        let u = TitleLayout.unit(d, canvasWidth: W, canvasHeight: H)
        let t = attributed(d.uppercase ? title.uppercased() : title, size: d.titleSize * u, weight: d.titleWeight, color: d.titleColor, d, u)
        let s = attributed(d.uppercase ? subtitle.uppercased() : subtitle, size: d.subtitleSize * u, weight: d.subtitleWeight, color: d.subtitleColor, d, u)
        let showTag = d.template.usesTag && !d.tag.isEmpty
        let g = attributed(d.tag.uppercased(), size: d.titleSize * u * 0.62, weight: .heavy, color: d.tagColor, d, u)
        func size(_ a: NSAttributedString, _ on: Bool) -> TitleSize {
            guard on, a.length > 0 else { return .zero }
            let r = a.size()
            return TitleSize(ceil(r.width), ceil(r.height))
        }
        let result = TitleLayout.layout(d, canvasWidth: W, canvasHeight: H,
                                        title: size(t, !title.isEmpty), subtitle: size(s, !subtitle.isEmpty), tag: size(g, showTag))
        func flip(_ r: TitleRect) -> CGRect { CGRect(x: r.x, y: H - r.y - r.height, width: r.width, height: r.height) }
        for b in result.boxes {
            let c: ProjectColor
            switch b.fill {
            case .box: c = d.boxColor
            case .box2: c = d.box2Color
            case .accent: c = d.accentColor
            }
            ctx.setFillColor(c.nsColor.cgColor)
            let rect = flip(b.rect)
            let rad = min(b.radius, rect.height / 2, rect.width / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.fillPath()
        }
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let reveal = elapsed.map { _ in TextReveal(animation: d.textAnimation, delay: d.letterDelay) }
        // Letters are counted title first, then subtitle, then tag.
        let order: [TitleTextRole] = [.title, .subtitle, .tag]
        var first = 0
        for role in order {
            for item in result.texts where item.role == role {
                let a: NSAttributedString, letterSize: Double
                switch item.role {
                case .title: a = t; letterSize = d.titleSize * u
                case .subtitle: a = s; letterSize = d.subtitleSize * u
                case .tag: a = g; letterSize = d.titleSize * u * 0.62
                }
                let r = flip(item.rect)
                if let reveal, let elapsed, reveal.animation != .off {
                    first = drawLetters(a, at: CGPoint(x: r.minX, y: r.minY), in: ctx, first: first,
                                        reveal: reveal, elapsed: elapsed, fontSize: letterSize)
                } else {
                    a.draw(at: NSPoint(x: r.minX, y: r.minY))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Letters of the three texts together (the animation's length).
    public static func letterCount(title: String, subtitle: String, design: TitleDesign) -> Int {
        let tag = design.template.usesTag ? design.tag : ""
        return [title, subtitle, tag].reduce(0) { $0 + $1.count }
    }

    /// Draws `a` one letter at a time with each letter's opacity, shift and size; returns the
    /// index of the next letter. Positions come from one CoreText line, so spacing and kerning
    /// match the finished title exactly.
    private static func drawLetters(_ a: NSAttributedString, at origin: CGPoint, in ctx: CGContext, first: Int,
                                    reveal: TextReveal, elapsed: Double, fontSize: Double) -> Int {
        let text = a.string
        let line = CTLineCreateWithAttributedString(a)
        let height = a.size().height
        var letter = first
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byComposedCharacterSequences) { _, range, _, _ in
            let ns = NSRange(range, in: text)
            let p = reveal.progress(letter: letter, at: elapsed)
            letter += 1
            guard p > 0 else { return }
            let x0 = CTLineGetOffsetForStringIndex(line, ns.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(line, ns.location + ns.length, nil)
            let cx = origin.x + (x0 + x1) / 2, cy = origin.y + height / 2
            let k = CGFloat(reveal.scale(p))
            ctx.saveGState()
            ctx.setAlpha(CGFloat(reveal.opacity(p)))
            ctx.translateBy(x: cx, y: cy + CGFloat(reveal.offset(p) * fontSize))
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -cx, y: -cy)
            a.attributedSubstring(from: ns).draw(at: NSPoint(x: origin.x + x0, y: origin.y))
            ctx.restoreGState()
        }
        return letter
    }

    /// Picture of a design (gallery thumbnails and the editor preview).
    public static func image(_ design: TitleDesign, title: String, subtitle: String, width: Int, height: Int,
                             elapsed: Double? = nil) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(design, title: title, subtitle: subtitle, in: ctx, width: Double(width), height: Double(height), elapsed: elapsed)
        return ctx.makeImage()
    }

    /// Font families offered in the editor (installed fonts).
    public static var fontFamilies: [String] { NSFontManager.shared.availableFontFamilies }

    static func font(family: String?, size: Double, weight: TitleWeight, italic: Bool) -> NSFont {
        let w: NSFont.Weight
        let managerWeight: Int   // NSFontManager scale: 5 = regular, 9 = bold
        switch weight {
        case .light: w = .light; managerWeight = 3
        case .regular: w = .regular; managerWeight = 5
        case .medium: w = .medium; managerWeight = 6
        case .semibold: w = .semibold; managerWeight = 8
        case .bold: w = .bold; managerWeight = 9
        case .heavy: w = .heavy; managerWeight = 11
        }
        let sz = CGFloat(max(size, 1))
        if let family, let f = NSFontManager.shared.font(withFamily: family, traits: italic ? .italicFontMask : [],
                                                          weight: managerWeight, size: sz) {
            return f
        }
        let base = NSFont.systemFont(ofSize: sz, weight: w)
        return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }

    static func attributed(_ text: String, size: Double, weight: TitleWeight, color: ProjectColor,
                           _ d: TitleDesign, _ u: Double) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(family: d.fontFamily, size: size, weight: weight, italic: d.italic),
            .foregroundColor: color.nsColor,
            .kern: d.tracking * u,
        ]
        if d.outlineWidth > 0, size > 0 {
            // Negative stroke width = fill and outline; the value is a percentage of the font size.
            attrs[.strokeWidth] = -(d.outlineWidth * u) / size * 100
            attrs[.strokeColor] = d.outlineColor.nsColor
        }
        if d.shadow {
            let sh = NSShadow()
            sh.shadowColor = d.shadowColor.nsColor
            sh.shadowBlurRadius = d.shadowBlur * u
            sh.shadowOffset = NSSize(width: d.shadowOffset * u, height: -d.shadowOffset * u)
            attrs[.shadow] = sh
        }
        return NSAttributedString(string: text, attributes: attrs)
    }
}
#endif
