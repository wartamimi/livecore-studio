#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore

/// Imported vMix GT title (.gtzip, 0.39.0): the template drawn at the output size with the
/// operator's texts. The storyboard's "in" animations play each time the input goes on air;
/// otherwise (Preview, multiview) the finished title is shown.
public final class GTTitleSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .gtTitle
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public let url: URL
    public let template: GTTemplate
    public private(set) var fields: [String: String]
    private let outputSize: PixelSize
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?
    private var animTimer: DispatchSourceTimer?
    private static let animQueue = DispatchQueue(label: "livecore.gt-animation", qos: .userInitiated)

    public init(id: InputID, url: URL, template: GTTemplate, fields: [String: String], outputSize: PixelSize) {
        self.id = id; self.url = url; self.template = template; self.outputSize = outputSize
        self.fields = fields
        name = "GT – " + url.deletingPathExtension().lastPathComponent
        render(at: nil)
    }

    /// The text shown in a field: the operator's, else the template's.
    public func text(_ field: String) -> String {
        fields[field] ?? template.elements.first { $0.name == field }?.text ?? ""
    }

    public func setFields(_ f: [String: String]) {
        fields = f.filter { k, v in template.elements.first { $0.name == k }?.text != v }
        if lock.withLock({ animTimer }) == nil { render(at: nil) }
    }

    private func render(at t: Double?) {
        let tpl = template, f = fields, w = outputSize.width, h = outputSize.height
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            GTRenderer.draw(tpl, fields: f, in: ctx, width: Double(w), height: Double(h), elapsed: t)
        }
        lock.withLock { frame = pb }
    }

    /// Plays the "in" storyboard from the start (on air).
    public func playIn() {
        let total = template.inDuration
        guard total > 0 else { return }
        finishIn(render: false)
        let start = HostClock.now()
        let t = DispatchSource.makeTimerSource(queue: Self.animQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        t.setEventHandler { [weak self, weak t] in
            guard let self, let t, !t.isCancelled else { return }
            let e = HostClock.now() - start
            self.render(at: e >= total ? nil : e)
            if e >= total { self.lock.withLock { if self.animTimer === t { self.animTimer = nil } }; t.cancel() }
        }
        lock.withLock { animTimer = t }
        t.resume()
    }

    /// Stops the animation and shows the finished title (off air).
    public func finishIn(render again: Bool = true) {
        let old: DispatchSourceTimer? = lock.withLock { let o = animTimer; animTimer = nil; return o }
        old?.cancel()
        if again && old != nil { Self.animQueue.async { [weak self] in self?.render(at: nil) } }
    }

    public func start() {}
    public func stop() { finishIn(render: false) }
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

public enum GTRenderer {
    /// Draws the template filling `width` × `height` (CoreGraphics, y up). `elapsed` is the time
    /// since the title went on air; nil draws the finished title.
    public static func draw(_ t: GTTemplate, fields: [String: String], in ctx: CGContext, width W: Double, height H: Double,
                            elapsed: Double?) {
        ctx.saveGState()
        // Template pixels, y down.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: W / max(t.width, 1), y: -H / max(t.height, 1))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let unit = W / max(t.width, 1)
        for e in t.elements {
            var f = GTAnimation.Frame()
            if let a = t.animation(for: e.name), let el = elapsed {
                let p = a.progress(at: el)
                if p <= 0 { continue }
                f = a.frame(progress: p)
            }
            guard f.opacity > 0, f.scale.x > 0, f.scale.y > 0 else { continue }
            ctx.saveGState()
            if let c = e.clip { ctx.clip(to: CGRect(x: c.x, y: c.y, width: c.width, height: c.height)) }
            ctx.setAlpha(CGFloat(f.opacity))
            // Local box coordinates: origin at the top left of the element.
            ctx.translateBy(x: e.x + e.width * f.anchor.x, y: e.y + e.height * f.anchor.y)
            ctx.scaleBy(x: f.scale.x, y: f.scale.y)
            ctx.translateBy(x: -e.width * f.anchor.x, y: -e.height * f.anchor.y)
            if e.skewX != 0 {
                let k = tan(e.skewX * .pi / 180)
                ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: k, d: 1, tx: -k * e.height / 2, ty: 0))
            }
            // The animation's clip; uncut sides stay open so strokes, shadows and long texts show.
            let x0 = f.clip.x0 > 0 ? f.clip.x0 * e.width : -e.width, x1 = f.clip.x1 < 1 ? f.clip.x1 * e.width : 2 * e.width
            let y0 = f.clip.y0 > 0 ? f.clip.y0 * e.height : -e.height, y1 = f.clip.y1 < 1 ? f.clip.y1 * e.height : 2 * e.height
            ctx.clip(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            if let s = e.shadow {
                // Shadow offsets are in device pixels, y up.
                ctx.setShadow(offset: CGSize(width: s.x * unit, height: -s.y * unit), blur: 3 * unit,
                              color: CGColor(gray: 0, alpha: 0.6))
            }
            let box = CGRect(x: 0, y: 0, width: e.width, height: e.height)
            switch e.kind {
            case .rectangle, .ellipse:
                let r = min(e.cornerRadius, e.width / 2, e.height / 2)
                let path = e.kind == .ellipse ? CGPath(ellipseIn: box, transform: nil)
                    : CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
                fill(path, e.fill, box: box, in: ctx)
                if let s = e.stroke, e.strokeThickness > 0, s.a > 0 {
                    ctx.setShadow(offset: .zero, blur: 0, color: nil)
                    ctx.addPath(path)
                    ctx.setStrokeColor(cg(s))
                    ctx.setLineWidth(e.strokeThickness)
                    ctx.strokePath()
                }
            case .text:
                drawText(fields[e.name] ?? e.text, e, box: box)
            case .image:
                if let d = e.imageData, let img = NSImage(data: d) {
                    img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    static func cg(_ c: GTColor) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }

    static func fill(_ path: CGPath, _ b: GTBrush, box: CGRect, in ctx: CGContext) {
        let stops = b.stops.isEmpty ? [(0.0, b.color), (1.0, b.color)] : b.stops.sorted { $0.position < $1.position }
        guard b.kind != .solid, let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                   colors: stops.map { cg($0.1) } as CFArray,
                                                   locations: stops.map { CGFloat($0.0) }) else {
            ctx.addPath(path)
            ctx.setFillColor(cg(b.color))
            ctx.fillPath()
            return
        }
        // A gradient does not cast a shadow by itself: draw the shape's shadow first.
        ctx.addPath(path)
        ctx.setFillColor(cg(stops[0].1))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let s = CGPoint(x: b.start.x * box.width, y: b.start.y * box.height)
        let e = CGPoint(x: b.end.x * box.width, y: b.end.y * box.height)
        if b.kind == .radial {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: box.midX, y: box.midY), startRadius: 0,
                                   endCenter: CGPoint(x: box.midX, y: box.midY), endRadius: max(box.width, box.height) / 2,
                                   options: [.drawsAfterEndLocation])
        } else {
            ctx.drawLinearGradient(g, start: s, end: e, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    static func font(_ e: GTElement) -> NSFont {
        var f = NSFont(name: e.fontFamily, size: e.fontSize) ?? NSFont.systemFont(ofSize: e.fontSize)
        let fm = NSFontManager.shared
        if e.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if e.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func drawText(_ s: String, _ e: GTElement, box: CGRect) {
        let p = NSMutableParagraphStyle()
        p.alignment = e.alignment == "Center" ? .center : e.alignment == "Right" ? .right : .left
        p.lineBreakMode = .byWordWrapping
        let color = e.fill.kind == .solid || e.fill.stops.isEmpty ? e.fill.color
            : e.fill.stops.sorted { $0.position < $1.position }.first!.color
        var fnt = font(e)
        var attrs: [NSAttributedString.Key: Any] = [.font: fnt, .foregroundColor: NSColor(cgColor: cg(color)) ?? .white,
                                                    .paragraphStyle: p]
        // Shrink to fit the box, as GT does for long texts.
        var size = (s as NSString).boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: attrs).size
        while size.height > box.height * 1.05, fnt.pointSize > 6 {
            fnt = NSFont(descriptor: fnt.fontDescriptor, size: fnt.pointSize * 0.9) ?? fnt
            attrs[.font] = fnt
            size = (s as NSString).boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: attrs).size
        }
        var y = 0.0
        switch e.verticalAlignment {
        case "Center": y = (box.height - size.height) / 2
        case "Bottom": y = box.height - size.height
        default: break
        }
        (s as NSString).draw(with: CGRect(x: 0, y: y, width: box.width, height: size.height + 2),
                             options: [.usesLineFragmentOrigin], attributes: attrs)
    }
}
#endif
