#if os(macOS)
import AppKit
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
        public init(title: String, subtitle: String = "") { self.title = title; self.subtitle = subtitle }
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

    /// Canvas: full program width, 25% of program height (matches `LayoutPreset.lowerThird`).
    public init(id: InputID, style: Style, outputSize: PixelSize) {
        self.id = id; self.style = style; self.name = style.title.isEmpty ? "Title" : style.title
        self.canvasWidth = outputSize.width
        self.canvasHeight = max(64, outputSize.height / 4)
        render()
    }
    private let canvasHeight: Int

    public func update(_ s: Style) { style = s; name = s.title.isEmpty ? "Title" : s.title; render() }

    private func render() {
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
#endif
