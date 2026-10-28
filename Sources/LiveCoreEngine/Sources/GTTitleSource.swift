#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore

/// Imported vMix GT title (.gtzip, 0.39.0): the template drawn at the output size with the
/// operator's texts. The "in" storyboard plays each time the input goes on air and the "out"
/// (the template's own, else the "in" backwards) when its overlay is taken off; otherwise
/// (Preview, multiview) the finished title is shown. Each element is drawn once into a sprite,
/// so animation frames are only cheap compositing at 60 fps (0.41.0).
public final class GTTitleSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .gtTitle
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public let url: URL
    /// The template as imported, and as drawn (with the editor's changes).
    public let original: GTTemplate
    public private(set) var template: GTTemplate
    public private(set) var fields: [String: String]
    public private(set) var overrides: [String: GTElementOverride] = [:]
    public private(set) var speed = 1.0
    private let outputSize: PixelSize
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?
    private var sprites: GTSprites?
    private var animTimer: DispatchSourceTimer?
    private var generation = 0
    private static let animQueue = DispatchQueue(label: "livecore.gt-animation", qos: .userInteractive)

    public init(id: InputID, url: URL, template: GTTemplate, fields: [String: String],
                overrides: [String: GTElementOverride] = [:], speed: Double = 1, outputSize: PixelSize) {
        self.id = id; self.url = url; self.original = template; self.outputSize = outputSize
        self.fields = fields; self.overrides = overrides; self.speed = speed
        self.template = template.applying(overrides, speed: speed, image: Self.loadImage)
        name = "GT – " + url.deletingPathExtension().lastPathComponent
        rebuild()
    }

    /// The text shown in a field: the operator's, else the template's.
    public func text(_ field: String) -> String {
        fields[field] ?? original.elements.first { $0.name == field }?.text ?? ""
    }

    public static func loadImage(_ r: ProjectMediaRef) -> Data? { try? Data(contentsOf: URL(fileURLWithPath: r.path)) }

    /// Draws again, e.g. after a missing font was installed.
    public func refresh() { setEdits(fields: fields, overrides: overrides, speed: speed) }

    /// New texts only (kept for callers that change just the fields).
    public func setFields(_ f: [String: String]) { setEdits(fields: f, overrides: overrides, speed: speed) }

    /// All editor changes at once: texts, element overrides and animation speed.
    public func setEdits(fields f: [String: String], overrides o: [String: GTElementOverride], speed sp: Double) {
        fields = f.filter { k, v in original.elements.first { $0.name == k }?.text != v }
        overrides = o.filter { !$0.value.isEmpty }
        speed = sp > 0 ? sp : 1
        template = original.applying(overrides, speed: speed, image: Self.loadImage)
        rebuild()
    }

    /// New sprites for the current template and texts; shows the finished title unless animating.
    private func rebuild() {
        let s = GTRenderer.makeSprites(template, fields: fields, unit: Double(outputSize.width) / max(template.width, 1))
        let idle: Bool = lock.withLock { sprites = s; return animTimer == nil }
        if idle { render(.shown) }
    }

    private func render(_ phase: GTPhase) {
        guard let s = lock.withLock({ sprites }) else { return }
        let tpl = template, w = outputSize.width, h = outputSize.height
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            GTRenderer.compose(tpl, sprites: s, in: ctx, width: Double(w), height: Double(h), phase: phase)
        }
        lock.withLock { frame = pb }
    }

    /// Runs `phase(t)` at 60 fps for `duration` seconds, then `done` on the animation queue.
    private func animate(_ duration: Double, _ phase: @escaping (Double) -> GTPhase, done: @escaping () -> Void) {
        let old: DispatchSourceTimer? = lock.withLock { let o = animTimer; animTimer = nil; generation += 1; return o }
        old?.cancel()
        let start = HostClock.now()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: Self.animQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .microseconds(500))
        t.setEventHandler { [weak self, weak t] in
            guard let self, let t, !t.isCancelled else { return }
            let e = HostClock.now() - start
            if e >= duration {
                t.cancel()
                self.lock.withLock { if self.animTimer === t { self.animTimer = nil } }
                done()
            } else {
                self.render(phase(e))
            }
        }
        lock.withLock { animTimer = t }
        t.resume()
    }

    /// Plays the "in" storyboard from the start (on air).
    public func playIn() {
        let total = template.inDuration
        guard total > 0 else { finishIn(); return }
        animate(total, { .entering($0) }) { [weak self] in self?.render(.shown) }
    }

    /// Plays the "out" storyboard (overlay taken off); afterwards the finished title returns for Preview.
    public func playOut() {
        let total = template.outDuration
        guard total > 0 else { return }
        animate(total, { .leaving($0) }) { [weak self] in
            guard let self else { return }
            self.render(.leaving(total))   // nothing drawn while the overlay finishes
            let gen = self.lock.withLock { self.generation }
            Self.animQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.lock.withLock({ self.generation == gen && self.animTimer == nil }) else { return }
                self.render(.shown)
            }
        }
    }

    /// Stops any animation and shows the finished title (off air).
    public func finishIn(render again: Bool = true) {
        let old: DispatchSourceTimer? = lock.withLock { let o = animTimer; animTimer = nil; generation += 1; return o }
        old?.cancel()
        if again { Self.animQueue.async { [weak self] in self?.render(.shown) } }
    }

    public func start() {}
    public func stop() { finishIn(render: false) }
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

/// One element drawn once at output resolution, with room around its box for skew, strokes,
/// shadows and text that runs over.
public struct GTSprite {
    public let image: CGImage
    public let padX: Double, padY: Double   // template pixels
}

public final class GTSprites {
    public let items: [GTSprite?]   // same order as the template's elements
    init(_ items: [GTSprite?]) { self.items = items }
}

public enum GTRenderer {
    /// Draws the template filling `width` × `height` (CoreGraphics, y up) in `phase`.
    public static func draw(_ t: GTTemplate, fields: [String: String], in ctx: CGContext, width W: Double, height H: Double,
                            phase: GTPhase) {
        let s = makeSprites(t, fields: fields, unit: W / max(t.width, 1))
        compose(t, sprites: s, in: ctx, width: W, height: H, phase: phase)
    }

    /// `unit` = output pixels per template pixel.
    public static func makeSprites(_ t: GTTemplate, fields: [String: String], unit: Double) -> GTSprites {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return GTSprites(t.elements.map { e -> GTSprite? in
            guard e.width > 0, e.height > 0, e.opacity > 0 else { return nil }
            let k = abs(tan(e.skewX * .pi / 180))
            let sh = e.shadow.map { max(abs($0.x), abs($0.y)) + 6 } ?? 0
            let padX = k * e.height / 2 + e.strokeThickness + sh + (e.kind == .text ? e.width * 0.15 : 4)
            let padY = e.strokeThickness + sh + (e.kind == .text ? e.height * 0.3 : 4)
            let pw = Int(((e.width + 2 * padX) * unit).rounded(.up)), ph = Int(((e.height + 2 * padY) * unit).rounded(.up))
            guard pw > 0, ph > 0, pw < 16384, ph < 16384,
                  let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: CGFloat(ph))
            ctx.scaleBy(x: unit, y: -unit)
            ctx.translateBy(x: padX, y: padY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            drawElement(e, text: fields[e.name] ?? e.text, in: ctx, unit: unit)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage().map { GTSprite(image: $0, padX: padX, padY: padY) }
        })
    }

    /// Composites the sprites with each element's animation state.
    public static func compose(_ t: GTTemplate, sprites: GTSprites, in ctx: CGContext, width W: Double, height H: Double,
                               phase: GTPhase) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // Template pixels, y down.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: W / max(t.width, 1), y: -H / max(t.height, 1))
        for (i, e) in t.elements.enumerated() {
            guard i < sprites.items.count, let sp = sprites.items[i], let f = t.frame(for: e.name, phase),
                  f.opacity > 0, f.scale.x > 0.001, f.scale.y > 0.001 else { continue }
            ctx.saveGState()
            if let c = e.clip { ctx.clip(to: CGRect(x: c.x, y: c.y, width: c.width, height: c.height)) }
            ctx.setAlpha(CGFloat(f.opacity * e.opacity))
            // Local box coordinates: origin at the top left of the element.
            ctx.translateBy(x: e.x + e.width * f.anchor.x, y: e.y + e.height * f.anchor.y)
            ctx.scaleBy(x: f.scale.x, y: f.scale.y)
            ctx.translateBy(x: -e.width * f.anchor.x, y: -e.height * f.anchor.y)
            let skew = skewTransform(e)
            // The animation's clip follows the skew; uncut sides stay open (strokes, shadows, long texts).
            if f.clip.x0 > 0 || f.clip.x1 < 1 || f.clip.y0 > 0 || f.clip.y1 < 1 {
                ctx.concatenate(skew)
                let x0 = f.clip.x0 > 0 ? f.clip.x0 * e.width : -e.width, x1 = f.clip.x1 < 1 ? f.clip.x1 * e.width : 2 * e.width
                let y0 = f.clip.y0 > 0 ? f.clip.y0 * e.height : -e.height, y1 = f.clip.y1 < 1 ? f.clip.y1 * e.height : 2 * e.height
                ctx.clip(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                ctx.concatenate(skew.inverted())
            }
            // The sprite (drawn y up) into the y-down space.
            let r = CGRect(x: -sp.padX, y: -sp.padY, width: e.width + 2 * sp.padX, height: e.height + 2 * sp.padY)
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(sp.image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    static func skewTransform(_ e: GTElement) -> CGAffineTransform {
        guard e.skewX != 0 else { return .identity }
        let k = tan(e.skewX * .pi / 180)
        return CGAffineTransform(a: 1, b: 0, c: k, d: 1, tx: -k * e.height / 2, ty: 0)
    }

    /// One element in its local box (origin top left, y down, template pixels), skew and shadow included.
    static func drawElement(_ e: GTElement, text: String, in ctx: CGContext, unit: Double) {
        ctx.saveGState()
        ctx.concatenate(skewTransform(e))
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
            drawText(text, e, box: box)
        case .image:
            if let d = e.imageData, let img = NSImage(data: d) {
                img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
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
        var f = NSFontManager.shared.font(withFamily: e.fontFamily, traits: [], weight: 5, size: e.fontSize)
            ?? NSFont(name: e.fontFamily, size: e.fontSize) ?? NSFont.systemFont(ofSize: e.fontSize)
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
