#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore

/// Virtual Set input (0.59.0): the studio picture at the output size. The talents and the screen
/// input are the input's further layers (see `VirtualSetPlacement`), keyed by their own chroma key.
public final class VirtualSetSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .virtualSet
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var design: VirtualSetDesign
    private let outputSize: PixelSize
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    public init(id: InputID, design: VirtualSetDesign, outputSize: PixelSize) {
        self.id = id; self.design = design.clamped; self.outputSize = outputSize
        name = Self.name(for: design)
        render()
    }

    static func name(for d: VirtualSetDesign) -> String {
        d.text.isEmpty ? "Virtual Set" : "Virtual Set – \(d.text)"
    }

    public func update(_ d: VirtualSetDesign) {
        design = d.clamped
        name = Self.name(for: design)
        render()
    }

    public var placement: VirtualSetPlacement { VirtualSetPlacement.place(design, aspect: outputSize.aspect) }

    private func render() {
        let d = design, w = outputSize.width, h = outputSize.height
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            VirtualSetRenderer.draw(d, in: ctx, width: Double(w), height: Double(h), placeholder: false)
        }
        lock.withLock { frame = pb }
    }

    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

/// Draws the 12 studios. All artwork is original and generated here (no bitmap assets): wall,
/// floor in perspective, lights, screens, desks and props, in the template's accent colour.
public enum VirtualSetRenderer {
    /// Picture of a set (gallery). With `placeholder`, grey talent silhouettes show where people go.
    public static func image(_ d: VirtualSetDesign, width: Int, height: Int, placeholder: Bool = true) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        draw(d, in: ctx, width: Double(width), height: Double(height), placeholder: placeholder)
        return ctx.makeImage()
    }

    /// Draws into a `W` × `H` CoreGraphics context (y up). Inside, drawing is y-down in pixels of
    /// the wide shot; the shot's zoom is a transform around it.
    public static func draw(_ d0: VirtualSetDesign, in ctx: CGContext, width W: Double, height H: Double, placeholder: Bool) {
        let d = d0.clamped
        let p = VirtualSetPlacement.place(d, aspect: W / max(H, 1))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: p.zoom, y: p.zoom)
        ctx.translateBy(x: -p.originX * W, y: -p.originY * H)
        let k = Kit(ctx: ctx, W: W, H: H, accent: d.accent.nsColor)
        studio(d, k)
        if placeholder {
            // Talent silhouettes in the wide-shot coordinates (undo the zoom mapping).
            for t in p.talents {
                let r = NormRect(x: t.rect.x / p.zoom + p.originX, y: t.rect.y / p.zoom + p.originY,
                                 width: t.rect.width / p.zoom, height: t.rect.height / p.zoom)
                k.silhouette(r, cropBottom: t.cropBottom)
            }
        }
        ctx.restoreGState()
    }

    // MARK: Studios

    private static func studio(_ d: VirtualSetDesign, _ k: Kit) {
        let a = d.accent
        let text = d.text
        let screen = d.template.screen
        switch d.template {
        case .newsDesk:
            k.vGradient(0, 0, 1, 0.62, [k.rgb(0.02, 0.05, 0.14), k.rgb(0.05, 0.13, 0.32)])
            k.panels(y: 0.06, h: 0.56, count: 9, color: k.rgb(0.07, 0.16, 0.38), line: k.mix(a, 0.6))
            k.ledBand(y: 0.48, h: 0.06, accent: a)
            k.floor(horizon: 0.62, top: k.rgb(0.05, 0.1, 0.22), bottom: k.rgb(0.01, 0.02, 0.06), lines: k.mix(a, 0.25), vx: 0.56)
            if let s = screen { k.screen(s, accent: a, text: text) }
            k.text(text, x: 0.62, y: 0.12, w: 0.34, size: 0.06, color: .white, weight: .heavy, align: .right)
            k.glow(0.56, 0.4, 0.35, k.mix(a, 0.25))
            k.desk(x0: 0.26, x1: 0.88, top: 0.70, body: k.rgb(0.08, 0.1, 0.16), surface: k.rgb(0.75, 0.8, 0.88), accent: a, text: text)
        case .talkShow:
            k.vGradient(0, 0, 1, 0.6, [k.rgb(0.22, 0.1, 0.05), k.rgb(0.45, 0.22, 0.1)])
            k.slats(y: 0.0, h: 0.6, count: 26, color: k.rgb(0.35, 0.18, 0.08))
            k.bokeh(count: 26, seed: 7, y0: 0.05, y1: 0.5, color: k.mix(a, 0.5))
            k.floor(horizon: 0.6, top: k.rgb(0.38, 0.24, 0.14), bottom: k.rgb(0.16, 0.09, 0.05), lines: k.rgb(0.25, 0.14, 0.07), vx: 0.5)
            if let s = screen { k.screen(s, accent: a, text: text) }
            k.text(text, x: 0.3, y: 0.38, w: 0.4, size: 0.035, color: k.mix(a, 1), weight: .bold, align: .center)
            k.chair(cx: 0.30, seat: 0.78, color: k.rgb(0.55, 0.12, 0.1))
            k.chair(cx: 0.70, seat: 0.78, color: k.rgb(0.55, 0.12, 0.1))
            k.table(cx: 0.5, top: 0.84, w: 0.14, color: k.rgb(0.2, 0.12, 0.08), accent: a)
        case .corporateStage:
            k.vGradient(0, 0, 1, 0.72, [k.rgb(0.01, 0.02, 0.06), k.rgb(0.04, 0.08, 0.2)])
            k.beams(count: 6, accent: a)
            k.truss(y: 0.05)
            k.floor(horizon: 0.72, top: k.rgb(0.06, 0.08, 0.14), bottom: k.rgb(0.01, 0.01, 0.03), lines: nil, vx: 0.5)
            k.stageEdge(y: 0.9, accent: a)
            if let s = screen { k.screen(s, accent: a, text: text) }
        case .weddingHall:
            k.vGradient(0, 0, 1, 0.66, [k.rgb(0.98, 0.94, 0.9), k.rgb(0.93, 0.84, 0.8)])
            k.drapes(color: k.rgb(1, 1, 1, 0.55), y: 0, h: 0.66)
            k.chandelier(cx: 0.5, y: 0.02, accent: a)
            k.floor(horizon: 0.66, top: k.rgb(0.92, 0.88, 0.84), bottom: k.rgb(0.75, 0.68, 0.64), lines: k.rgb(1, 1, 1, 0.25), vx: 0.5)
            k.aisle(color: k.rgb(0.95, 0.95, 0.95))
            k.arch(cx: 0.5, base: 0.92, r: 0.36, accent: a)
            k.text(text, x: 0.2, y: 0.03, w: 0.6, size: 0.07, color: k.mix(a, 0.95), weight: .regular, align: .center, family: "Snell Roundhand")
        case .techNeon:
            k.vGradient(0, 0, 1, 0.64, [k.rgb(0.0, 0.01, 0.04), k.rgb(0.02, 0.04, 0.1)])
            k.hexes(accent: a)
            k.neonFrame(0.05, 0.12, 0.22, 0.4, a)
            k.floor(horizon: 0.64, top: k.rgb(0.02, 0.05, 0.1), bottom: k.rgb(0, 0, 0.02), lines: k.mix(a, 0.6), vx: 0.4)
            if let s = screen { k.screen(s, accent: a, text: text) }
            k.text(text, x: 0.05, y: 0.06, w: 0.5, size: 0.05, color: k.mix(a, 1), weight: .heavy, align: .left)
            k.desk(x0: 0.12, x1: 0.68, top: 0.72, body: k.rgb(0.02, 0.03, 0.06), surface: k.rgb(0.12, 0.16, 0.22), accent: a, text: "", neon: true)
        case .sportsCenter:
            k.vGradient(0, 0, 1, 0.62, [k.rgb(0.03, 0.03, 0.05), k.rgb(0.1, 0.08, 0.1)])
            k.bokeh(count: 40, seed: 3, y0: 0.02, y1: 0.3, color: k.rgb(1, 0.95, 0.85, 0.5))
            k.stripes(accent: a)
            k.floor(horizon: 0.62, top: k.rgb(0.1, 0.1, 0.12), bottom: k.rgb(0.02, 0.02, 0.03), lines: k.mix(a, 0.2), vx: 0.34)
            if let s = screen { k.screen(s, accent: a, text: text) }
            k.text(text, x: 0.04, y: 0.08, w: 0.5, size: 0.06, color: .white, weight: .heavy, align: .left, italic: true)
            k.desk(x0: 0.06, x1: 0.62, top: 0.70, body: k.rgb(0.1, 0.1, 0.12), surface: k.rgb(0.85, 0.85, 0.88), accent: a, text: text)
        case .seminarPodium:
            k.vGradient(0, 0, 1, 0.7, [k.rgb(0.05, 0.12, 0.3), k.rgb(0.1, 0.25, 0.5)])
            k.dots(accent: a)
            k.floor(horizon: 0.7, top: k.rgb(0.1, 0.12, 0.2), bottom: k.rgb(0.03, 0.04, 0.08), lines: nil, vx: 0.5)
            k.stageEdge(y: 0.93, accent: a)
            if let s = screen { k.screen(s, accent: a, text: text) }
            k.text(text, x: 0.56, y: 0.12, w: 0.4, size: 0.045, color: .white, weight: .bold, align: .center)
            k.lectern(cx: 0.72, top: 0.66, w: 0.17, accent: a, text: "")
        case .minimalWhite:
            k.cyclorama()
            k.shadow(cx: 0.5, y: 0.97, w: 0.3)
            if !text.isEmpty { k.text(text, x: 0.05, y: 0.06, w: 0.9, size: 0.04, color: k.rgb(0.35, 0.37, 0.4), weight: .light, align: .center) }
        case .citySkyline:
            k.vGradient(0, 0, 1, 0.64, [k.rgb(0.03, 0.02, 0.1), k.rgb(0.16, 0.08, 0.28)])
            k.skyline(accent: a)
            k.windowFrames()
            k.floor(horizon: 0.64, top: k.rgb(0.08, 0.06, 0.12), bottom: k.rgb(0.02, 0.01, 0.04), lines: k.mix(a, 0.2), vx: 0.5)
            k.text(text, x: 0.05, y: 0.06, w: 0.9, size: 0.05, color: .white, weight: .heavy, align: .center)
            k.desk(x0: 0.22, x1: 0.78, top: 0.72, body: k.rgb(0.06, 0.05, 0.1), surface: k.rgb(0.3, 0.28, 0.36), accent: a, text: text)
        case .debateStage:
            k.split(left: k.rgb(0.05, 0.12, 0.38), right: k.rgb(0.38, 0.05, 0.08), h: 0.68)
            k.stars(accent: a)
            k.floor(horizon: 0.68, top: k.rgb(0.08, 0.08, 0.12), bottom: k.rgb(0.01, 0.01, 0.03), lines: nil, vx: 0.5)
            if let s = screen { k.screen(s, accent: a, text: text) }
            k.text(text, x: 0.25, y: 0.38, w: 0.5, size: 0.05, color: .white, weight: .heavy, align: .center)
            k.lectern(cx: 0.24, top: 0.68, w: 0.18, accent: k.rgb(0.2, 0.4, 0.95), text: "")
            k.lectern(cx: 0.76, top: 0.68, w: 0.18, accent: k.rgb(0.95, 0.2, 0.2), text: "")
        case .podcastStudio:
            k.vGradient(0, 0, 1, 0.66, [k.rgb(0.08, 0.08, 0.1), k.rgb(0.14, 0.13, 0.16)])
            k.foam()
            k.neonText(text, x: 0.35, y: 0.1, w: 0.3, accent: a)
            k.floor(horizon: 0.66, top: k.rgb(0.2, 0.15, 0.12), bottom: k.rgb(0.07, 0.05, 0.04), lines: k.rgb(0.12, 0.09, 0.07), vx: 0.5)
            k.desk(x0: 0.06, x1: 0.94, top: 0.74, body: k.rgb(0.25, 0.16, 0.1), surface: k.rgb(0.45, 0.3, 0.2), accent: a, text: "")
            k.mic(x: 0.46, top: 0.74)
            k.mic(x: 0.54, top: 0.74)
        case .goldGala:
            k.vGradient(0, 0, 1, 0.7, [k.rgb(0.08, 0.01, 0.02), k.rgb(0.2, 0.03, 0.05)])
            k.curtains(color: k.rgb(0.45, 0.05, 0.08), gold: a)
            k.sparkles(accent: a)
            k.floor(horizon: 0.7, top: k.rgb(0.15, 0.08, 0.04), bottom: k.rgb(0.03, 0.01, 0.01), lines: nil, vx: 0.5)
            k.stageEdge(y: 0.92, accent: a)
            k.spot(cx: 0.5, accent: k.rgb(1, 0.95, 0.8, 0.22))
            k.text(text, x: 0.2, y: 0.05, w: 0.6, size: 0.065, color: k.mix(a, 1), weight: .bold, align: .center, family: "Didot")
        }
    }

    // MARK: Drawing kit

    /// Small drawing helpers in wide-shot pixels, y down.
    struct Kit {
        let ctx: CGContext
        let W: Double, H: Double
        let accent: NSColor
        var u: Double { H / 1080 }

        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        func mix(_ c: ProjectColor, _ a: Double) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a) }
        func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * W, y: y * H, width: w * W, height: h * H) }
        func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * W, y: y * H) }

        func gradient(_ colors: [NSColor], _ locs: [CGFloat]? = nil) -> CGGradient? {
            CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: colors.map { ($0.usingColorSpace(.sRGB) ?? $0).cgColor } as CFArray, locations: locs)
        }

        func vGradient(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ colors: [NSColor]) {
            guard let g = gradient(colors) else { return }
            ctx.saveGState()
            ctx.clip(to: R(x, y, w, h))
            ctx.drawLinearGradient(g, start: P(0, y), end: P(0, y + h), options: [])
            ctx.restoreGState()
        }

        func fill(_ path: CGPath, _ c: NSColor) {
            ctx.addPath(path); ctx.setFillColor(c.cgColor); ctx.fillPath()
        }

        func poly(_ pts: [(Double, Double)]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map { P($0.0, $0.1) })
            p.closeSubpath()
            return p
        }

        func fillGradient(_ path: CGPath, _ colors: [NSColor], from: CGPoint, to: CGPoint) {
            guard let g = gradient(colors) else { return }
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }

        func glow(_ cx: Double, _ cy: Double, _ r: Double, _ c: NSColor) {
            guard let g = gradient([c, c.withAlphaComponent(0)]) else { return }
            ctx.drawRadialGradient(g, startCenter: P(cx, cy), startRadius: 0, endCenter: P(cx, cy), endRadius: r * H, options: [])
        }

        /// Floor from the horizon down with perspective lines towards (vx, horizon).
        func floor(horizon: Double, top: NSColor, bottom: NSColor, lines: NSColor?, vx: Double) {
            vGradient(-0.5, horizon, 2, 1.2 - horizon, [top, bottom])
            // Reflection of the wall light.
            vGradient(-0.5, horizon, 2, 0.08, [NSColor(white: 1, alpha: 0.08), NSColor(white: 1, alpha: 0)])
            guard let lines else { return }
            ctx.saveGState()
            ctx.clip(to: R(-0.5, horizon, 2, 1.2 - horizon))
            ctx.setStrokeColor(lines.cgColor)
            ctx.setLineWidth(1.5 * u)
            for i in -12...12 {
                ctx.move(to: P(vx, horizon))
                ctx.addLine(to: P(vx + Double(i) * 0.16, 1.2))
            }
            var y = 0.012
            while horizon + y < 1.2 {
                ctx.move(to: P(-0.5, horizon + y)); ctx.addLine(to: P(1.5, horizon + y))
                y *= 1.45
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        func panels(y: Double, h: Double, count: Int, color: NSColor, line: NSColor) {
            let w = 1.0 / Double(count)
            for i in 0..<count {
                let x = Double(i) * w
                vGradient(x + 0.004, y, w - 0.008, h, [color.blended(withFraction: 0.25, of: .white) ?? color, color])
                ctx.setFillColor(line.cgColor)
                ctx.fill(R(x + w / 2 - 0.0015, y + 0.03, 0.003, h - 0.06))
            }
        }

        func ledBand(y: Double, h: Double, accent a: ProjectColor) {
            vGradient(0, y, 1, h, [mix(a, 0.15), mix(a, 0.85), mix(a, 0.15)])
        }

        func screen(_ s: NormRect, accent a: ProjectColor, text: String) {
            let r = R(s.x, s.y, s.width, s.height)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40 * u, color: mix(a, 0.6).cgColor)
            ctx.setFillColor(rgb(0.02, 0.02, 0.03).cgColor)
            ctx.fill(r.insetBy(dx: -8 * u, dy: -8 * u))
            ctx.restoreGState()
            fillGradient(CGPath(rect: r, transform: nil), [mix(a, 1), rgb(0.02, 0.04, 0.12)], from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
            // Abstract motion graphic on the idle screen.
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
            ctx.setLineWidth(3 * u)
            for i in 0..<6 {
                let o = Double(i) * r.height / 5
                ctx.move(to: CGPoint(x: r.minX, y: r.minY + o)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + o - r.height * 0.4))
            }
            ctx.strokePath()
            ctx.restoreGState()
            self.text(text, x: s.x, y: s.y + s.height * 0.4, w: s.width, size: s.height * 0.12, color: .white, weight: .heavy, align: .center)
        }

        func desk(x0: Double, x1: Double, top: Double, body: NSColor, surface: NSColor, accent a: ProjectColor, text: String, neon: Bool = false) {
            let t = 0.04, inset = 0.03
            let surf = poly([(x0 + inset, top), (x1 - inset, top), (x1, top + t), (x0, top + t)])
            fillGradient(surf, [surface, surface.blended(withFraction: 0.35, of: .black) ?? surface], from: P(0, top), to: P(0, top + t))
            let front = poly([(x0, top + t), (x1, top + t), (x1 - 0.02, 1.02), (x0 + 0.02, 1.02)])
            fillGradient(front, [body.blended(withFraction: 0.2, of: .white) ?? body, body], from: P(0, top + t), to: P(0, 1.0))
            // Accent strip, glowing.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: (neon ? 30 : 16) * u, color: mix(a, 1).cgColor)
            ctx.setFillColor(mix(a, 1).cgColor)
            ctx.fill(R(x0 + 0.004, top + t + 0.012, x1 - x0 - 0.008, neon ? 0.006 : 0.01))
            if neon {
                ctx.setStrokeColor(mix(a, 1).cgColor); ctx.setLineWidth(3 * u)
                ctx.addPath(surf); ctx.strokePath()
            }
            ctx.restoreGState()
            if !text.isEmpty {
                self.text(text, x: x0, y: top + t + 0.06, w: x1 - x0, size: 0.04, color: NSColor(white: 1, alpha: 0.9), weight: .heavy, align: .center)
            }
        }

        func lectern(cx: Double, top: Double, w: Double, accent a: NSColor, text: String) {
            let p = poly([(cx - w / 2, top), (cx + w / 2, top), (cx + w * 0.38, 1.02), (cx - w * 0.38, 1.02)])
            fillGradient(p, [rgb(0.85, 0.87, 0.9), rgb(0.45, 0.48, 0.55)], from: P(cx - w / 2, 0), to: P(cx + w / 2, 0))
            let topEdge = poly([(cx - w / 2 - 0.01, top - 0.012), (cx + w / 2 + 0.01, top - 0.012), (cx + w / 2, top + 0.012), (cx - w / 2, top + 0.012)])
            fill(topEdge, rgb(0.2, 0.22, 0.26))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 14 * u, color: a.cgColor)
            ctx.setFillColor(a.cgColor)
            ctx.fill(R(cx - w * 0.4, top + 0.08, w * 0.8, 0.012))
            ctx.restoreGState()
            if !text.isEmpty { self.text(text, x: cx - w / 2, y: top + 0.12, w: w, size: 0.03, color: .white, weight: .bold, align: .center) }
        }
        func lectern(cx: Double, top: Double, w: Double, accent a: ProjectColor, text: String) {
            lectern(cx: cx, top: top, w: w, accent: mix(a, 1), text: text)
        }

        func stageEdge(y: Double, accent a: ProjectColor) {
            fill(poly([(-0.5, y), (1.5, y), (1.5, 1.2), (-0.5, 1.2)]), rgb(0.02, 0.02, 0.03))
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 20 * u, color: mix(a, 1).cgColor)
            ctx.setFillColor(mix(a, 0.9).cgColor)
            ctx.fill(R(-0.5, y, 2, 0.006))
            ctx.restoreGState()
        }

        func beams(count: Int, accent a: ProjectColor) {
            for i in 0..<count {
                let x = 0.08 + Double(i) / Double(max(count - 1, 1)) * 0.84
                let spread = 0.08 + 0.04 * Double(i % 2)
                let b = poly([(x - 0.005, 0.04), (x + 0.005, 0.04), (x + spread, 0.9), (x - spread, 0.9)])
                fillGradient(b, [mix(a, 0.35), mix(a, 0)], from: P(x, 0.04), to: P(x, 0.9))
            }
        }

        func truss(y: Double) {
            ctx.setStrokeColor(rgb(0.35, 0.37, 0.42).cgColor)
            ctx.setLineWidth(3 * u)
            ctx.stroke(R(0, y, 1, 0.025))
            var x = 0.0
            while x < 1 {
                ctx.move(to: P(x, y)); ctx.addLine(to: P(x + 0.0125, y + 0.025)); ctx.addLine(to: P(x + 0.025, y))
                x += 0.025
            }
            ctx.strokePath()
        }

        func slats(y: Double, h: Double, count: Int, color: NSColor) {
            let w = 1.0 / Double(count)
            for i in 0..<count where i % 2 == 0 {
                ctx.setFillColor(color.cgColor)
                ctx.fill(R(Double(i) * w, y, w * 0.6, h))
            }
        }

        func bokeh(count: Int, seed: UInt64, y0: Double, y1: Double, color: NSColor) {
            var rng = seed
            func r() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 33) / Double(1 << 31) }
            for _ in 0..<count {
                let x = r(), y = y0 + (y1 - y0) * r(), s = 0.01 + 0.03 * r()
                glow(x, y, s, color.withAlphaComponent(color.alphaComponent * (0.3 + 0.7 * r())))
            }
        }

        func chair(cx: Double, seat: Double, color: NSColor) {
            let back = CGPath(roundedRect: R(cx - 0.13, seat - 0.3, 0.26, 0.34), cornerWidth: 40 * u, cornerHeight: 40 * u, transform: nil)
            fillGradient(back, [color.blended(withFraction: 0.2, of: .white) ?? color, color.blended(withFraction: 0.4, of: .black) ?? color],
                         from: P(cx, seat - 0.3), to: P(cx, seat + 0.04))
            let arms = CGPath(roundedRect: R(cx - 0.16, seat - 0.06, 0.32, 0.2), cornerWidth: 30 * u, cornerHeight: 30 * u, transform: nil)
            fill(arms, color.blended(withFraction: 0.3, of: .black) ?? color)
        }

        func table(cx: Double, top: Double, w: Double, color: NSColor, accent a: ProjectColor) {
            fill(CGPath(ellipseIn: R(cx - w / 2, top, w, 0.03), transform: nil), color.blended(withFraction: 0.2, of: .white) ?? color)
            fill(poly([(cx - 0.01, top + 0.02), (cx + 0.01, top + 0.02), (cx + 0.02, top + 0.12), (cx - 0.02, top + 0.12)]), color)
            glow(cx, top + 0.005, 0.02, mix(a, 0.6))
        }

        func drapes(color: NSColor, y: Double, h: Double) {
            for i in 0..<8 {
                let x = Double(i) / 8
                let p = CGMutablePath()
                p.move(to: P(x, y))
                p.addQuadCurve(to: P(x + 0.125, y), control: P(x + 0.0625, y + 0.12))
                p.addLine(to: P(x + 0.125, y + h)); p.addLine(to: P(x, y + h)); p.closeSubpath()
                fillGradient(p, [color, color.withAlphaComponent(0.05), color], from: P(x, 0), to: P(x + 0.125, 0))
            }
        }

        func chandelier(cx: Double, y: Double, accent a: ProjectColor) {
            for i in 0..<14 {
                let ang = Double(i) / 14 * Double.pi
                let x = cx + cos(ang) * 0.12, yy = y + 0.04 + sin(ang) * 0.05
                glow(x, yy, 0.02, rgb(1, 0.95, 0.8, 0.9))
                ctx.setFillColor(mix(a, 1).cgColor); ctx.fill(R(x - 0.001, y, 0.002, yy - y))
            }
        }

        func aisle(color: NSColor) {
            fillGradient(poly([(0.46, 0.66), (0.54, 0.66), (0.72, 1.2), (0.28, 1.2)]), [color.withAlphaComponent(0.6), color],
                         from: P(0, 0.66), to: P(0, 1.1))
        }

        func arch(cx: Double, base: Double, r: Double, accent a: ProjectColor) {
            let flowers = [rgb(1, 1, 1), rgb(0.98, 0.78, 0.82), mix(a, 1), rgb(0.95, 0.6, 0.65)]
            ctx.setStrokeColor(mix(a, 1).cgColor); ctx.setLineWidth(10 * u)
            let p = CGMutablePath()
            p.move(to: P(cx - r * H / W, base))
            p.addLine(to: P(cx - r * H / W, base - r))
            p.addArc(center: P(cx, base - r), radius: r * H, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: P(cx + r * H / W, base))
            ctx.addPath(p); ctx.strokePath()
            var rng: UInt64 = 11
            func rnd() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 33) / Double(1 << 31) }
            // Flowers clustered at the top corners and the crown of the arch.
            for i in 0..<90 {
                let t = Double(i) / 90
                let ang = Double.pi * (1 + t)
                let x = cx + cos(ang) * r * H / W, y = base - r + sin(ang) * r
                let dense = t < 0.25 || t > 0.75 || abs(t - 0.5) < 0.12
                guard dense || i % 3 == 0 else { continue }
                let s = (dense ? 0.022 : 0.014) * (0.7 + 0.6 * rnd())
                let c = flowers[Int(rnd() * 4) % 4]
                fill(CGPath(ellipseIn: R(x - s * H / W + (rnd() - 0.5) * 0.02, y - s + (rnd() - 0.5) * 0.03, 2 * s * H / W, 2 * s), transform: nil), c)
            }
        }

        func hexes(accent a: ProjectColor) {
            ctx.setStrokeColor(mix(a, 0.12).cgColor); ctx.setLineWidth(2 * u)
            let s = 0.05
            var row = 0
            var y = 0.0
            while y < 0.64 {
                var x = row % 2 == 0 ? 0 : s * 0.87
                while x < 1.05 {
                    let p = CGMutablePath()
                    for k in 0..<6 {
                        let ang = Double(k) * Double.pi / 3 + Double.pi / 6
                        let pt = CGPoint(x: x * W + cos(ang) * s * H * 0.6, y: y * H + sin(ang) * s * H * 0.6)
                        if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath(); ctx.addPath(p)
                    x += s * 1.74 * H / W * 1.0
                }
                y += s * 0.9; row += 1
            }
            ctx.strokePath()
        }

        func neonFrame(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ a: ProjectColor) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 24 * u, color: mix(a, 1).cgColor)
            ctx.setStrokeColor(mix(a, 1).cgColor); ctx.setLineWidth(5 * u)
            ctx.addPath(CGPath(roundedRect: R(x, y, w, h), cornerWidth: 20 * u, cornerHeight: 20 * u, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }

        func stripes(accent a: ProjectColor) {
            for i in 0..<4 {
                let x = 0.0 + Double(i) * 0.05
                fill(poly([(x, 0.62), (x + 0.03, 0.62), (x + 0.33, 0.18), (x + 0.3, 0.18)]), mix(a, 0.5 - Double(i) * 0.1))
            }
        }

        func dots(accent a: ProjectColor) {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
            var y = 0.03
            while y < 0.7 {
                var x = 0.02
                while x < 1 { ctx.fillEllipse(in: R(x, y, 0.004, 0.007)); x += 0.025 }
                y += 0.04
            }
            glow(0.75, 0.3, 0.5, mix(a, 0.25))
        }

        func cyclorama() {
            vGradient(-0.5, 0, 2, 1.2, [rgb(0.97, 0.97, 0.98), rgb(0.93, 0.93, 0.95), rgb(0.82, 0.83, 0.86)])
            glow(0.5, 0.45, 0.7, NSColor(white: 1, alpha: 0.6))
        }

        func shadow(cx: Double, y: Double, w: Double) {
            guard let g = gradient([NSColor(white: 0, alpha: 0.28), NSColor(white: 0, alpha: 0)]) else { return }
            ctx.saveGState()
            ctx.translateBy(x: cx * W, y: y * H); ctx.scaleBy(x: 1, y: 0.15)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: w * W / 2, options: [])
            ctx.restoreGState()
        }

        func skyline(accent a: ProjectColor) {
            var rng: UInt64 = 5
            func r() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 33) / Double(1 << 31) }
            glow(0.75, 0.15, 0.08, rgb(1, 0.97, 0.85, 0.9))
            var x = -0.02
            while x < 1.02 {
                let w = 0.03 + 0.06 * r(), top = 0.18 + 0.32 * r()
                ctx.setFillColor(rgb(0.06, 0.05, 0.14).cgColor)
                ctx.fill(R(x, top, w, 0.64 - top))
                var wy = top + 0.015
                while wy < 0.6 {
                    var wx = x + 0.006
                    while wx < x + w - 0.008 {
                        if r() > 0.55 { ctx.setFillColor((r() > 0.85 ? mix(a, 0.9) : rgb(1, 0.85, 0.5, 0.85)).cgColor); ctx.fill(R(wx, wy, 0.004, 0.008)) }
                        wx += 0.009
                    }
                    wy += 0.018
                }
                x += w + 0.004
            }
        }

        func windowFrames() {
            ctx.setFillColor(rgb(0.03, 0.03, 0.05).cgColor)
            for i in 0...4 { ctx.fill(R(Double(i) * 0.25 - 0.006, 0, 0.012, 0.64)) }
            ctx.fill(R(0, 0.3, 1, 0.008))
        }

        func split(left: NSColor, right: NSColor, h: Double) {
            vGradient(0, 0, 0.5, h, [left, left.blended(withFraction: 0.5, of: .black) ?? left])
            vGradient(0.5, 0, 0.5, h, [right, right.blended(withFraction: 0.5, of: .black) ?? right])
            ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
            ctx.fill(R(0.4985, 0, 0.003, h))
        }

        func stars(accent a: ProjectColor) {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)
            for i in 0..<12 {
                let x = 0.05 + Double(i) * 0.08, y = 0.06 + 0.03 * Double(i % 3)
                ctx.fillEllipse(in: R(x, y, 0.006, 0.01))
            }
            glow(0.5, 0.35, 0.3, mix(a, 0.2))
        }

        func foam() {
            let s = 0.07
            var y = 0.02
            var row = 0
            while y < 0.64 {
                var x = row % 2 == 0 ? 0.01 : 0.01 + s / 2
                while x < 1 {
                    let r = R(x, y, s * H / W * 0.95, s * 0.95)
                    let p = CGPath(rect: r, transform: nil)
                    fillGradient(p, [rgb(0.2, 0.2, 0.24), rgb(0.08, 0.08, 0.1)], from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
                    x += s * H / W
                }
                y += s; row += 1
            }
        }

        func neonText(_ s: String, x: Double, y: Double, w: Double, accent a: ProjectColor) {
            guard !s.isEmpty else { return }
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30 * u, color: mix(a, 1).cgColor)
            text(s, x: x, y: y, w: w, size: 0.07, color: mix(a, 1), weight: .heavy, align: .center)
            ctx.restoreGState()
        }

        func mic(x: Double, top: Double) {
            ctx.setFillColor(rgb(0.1, 0.1, 0.12).cgColor)
            ctx.fill(R(x - 0.002, top - 0.12, 0.004, 0.12))
            fill(CGPath(roundedRect: R(x - 0.012, top - 0.2, 0.024, 0.09), cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil), rgb(0.25, 0.25, 0.28))
        }

        func curtains(color: NSColor, gold a: ProjectColor) {
            for side in [0.0, 1.0] {
                for i in 0..<6 {
                    let x = side == 0 ? Double(i) * 0.04 : 1 - Double(i + 1) * 0.04
                    fillGradient(CGPath(rect: R(x, 0, 0.04, 0.72), transform: nil),
                                 [color.blended(withFraction: 0.5, of: .black) ?? color, color, color.blended(withFraction: 0.5, of: .black) ?? color],
                                 from: P(x, 0), to: P(x + 0.04, 0))
                }
            }
            // Valance with a gold fringe.
            fill(poly([(0, 0), (1, 0), (1, 0.08), (0, 0.08)]), color.blended(withFraction: 0.3, of: .black) ?? color)
            ctx.setFillColor(mix(a, 1).cgColor); ctx.fill(R(0, 0.08, 1, 0.008))
        }

        func sparkles(accent a: ProjectColor) { bokeh(count: 50, seed: 21, y0: 0.1, y1: 0.65, color: mix(a, 0.7)) }

        func spot(cx: Double, accent c: NSColor) {
            fillGradient(poly([(cx - 0.02, 0), (cx + 0.02, 0), (cx + 0.22, 1.0), (cx - 0.22, 1.0)]), [c, c.withAlphaComponent(0)],
                         from: P(cx, 0), to: P(cx, 1))
        }

        /// Grey person shape where a talent goes (gallery and editor only).
        func silhouette(_ r: NormRect, cropBottom: Double) {
            let full = r.height / max(1 - cropBottom, 0.01)
            let cx = r.x + r.width / 2
            ctx.saveGState()
            ctx.clip(to: R(r.x, r.y, r.width, r.height))
            let head = full * 0.13
            ctx.setFillColor(NSColor(white: 0.55, alpha: 0.75).cgColor)
            ctx.fillEllipse(in: R(cx - head * 0.45 * H / W, r.y + full * 0.16, head * 0.9 * H / W, head * 1.1))
            let body = CGPath(roundedRect: R(cx - full * 0.17 * H / W, r.y + full * 0.33, full * 0.34 * H / W, full * 0.7),
                              cornerWidth: 60 * u, cornerHeight: 60 * u, transform: nil)
            fill(body, NSColor(white: 0.55, alpha: 0.75))
            ctx.restoreGState()
        }

        func text(_ s: String, x: Double, y: Double, w: Double, size: Double, color: NSColor, weight: NSFont.Weight = .bold,
                  align: NSTextAlignment = .center, family: String? = nil, italic: Bool = false) {
            guard !s.isEmpty else { return }
            var font = NSFont.systemFont(ofSize: size * H, weight: weight)
            if let family, let f = NSFont(name: family, size: size * H) { font = f }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byClipping
            let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            a.draw(with: NSRect(x: x * W, y: y * H, width: w * W, height: size * H * 1.5), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
#endif
