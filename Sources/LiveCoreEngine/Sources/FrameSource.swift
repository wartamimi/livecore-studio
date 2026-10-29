#if os(macOS)
import AppKit
import CoreVideo
import LiveCoreCore

/// Camera frame input: the frame picture (background, card, glow, corners, labels) at the output
/// size, transparent where the camera shows through. The camera itself is the input's second
/// layer, placed and styled from `FrameLayout`.
public final class FrameSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .frame
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var design: FrameDesign
    private let outputSize: PixelSize
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    public init(id: InputID, design: FrameDesign, outputSize: PixelSize) {
        self.id = id; self.design = design; self.outputSize = outputSize
        name = design.title.isEmpty ? "Frame" : "Frame – \(design.title)"
        render()
    }

    public func update(_ d: FrameDesign) {
        design = d
        render()
    }

    public var layout: FrameLayout { FrameLayout.layout(design.template, aspect: outputSize.aspect) }

    private func render() {
        let d = design, w = outputSize.width, h = outputSize.height
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            FrameRenderer.draw(d, in: ctx, width: Double(w), height: Double(h), placeholder: false)
        }
        lock.withLock { frame = pb }
    }

    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

public enum FrameRenderer {
    /// Draws a frame in a `width` × `height` CoreGraphics context (y up). With `placeholder` the
    /// camera window is filled grey and outlined (gallery pictures), else it is left transparent.
    public static func draw(_ d: FrameDesign, in ctx: CGContext, width W: Double, height H: Double, placeholder: Bool) {
        let l = FrameLayout.layout(d.template, aspect: W / max(H, 1))
        func rect(_ r: NormRect) -> CGRect { CGRect(x: r.x * W, y: H - (r.y + r.height) * H, width: r.width * W, height: r.height * H) }
        let cam = rect(l.camera)
        let radius: CGFloat = l.shape == .ellipse ? 0 : CGFloat(l.cornerRadius) * min(cam.width, cam.height)
        func windowPath(_ r: CGRect, grow: CGFloat = 0) -> CGPath {
            let g = r.insetBy(dx: -grow, dy: -grow)
            return l.shape == .ellipse ? CGPath(ellipseIn: g, transform: nil)
                : CGPath(roundedRect: g, cornerWidth: radius + grow, cornerHeight: radius + grow, transform: nil)
        }
        let all = CGRect(x: 0, y: 0, width: W, height: H)
        let u = CGFloat(H / 1080)   // 1 px at 1080p

        // Background gradient.
        if !d.transparentBackground {
            let colors = [d.background1.nsColor.cgColor, d.background2.nsColor.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: all)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0.0, y: H), end: CGPoint(x: W * 0.3, y: 0.0), options: [])
                ctx.restoreGState()
            }
        }
        // Template decorations (outside the window).
        switch d.template {
        case .polaroid:
            if let c = l.card {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 30 * u, color: CGColor(gray: 0, alpha: 0.5))
                ctx.setFillColor(d.accent.nsColor.cgColor)
                ctx.fill(rect(c))
                ctx.restoreGState()
            }
        case .neon:
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 40 * u, color: d.accent.nsColor.cgColor)
            ctx.setStrokeColor(d.accent.nsColor.cgColor)
            ctx.setLineWidth(6 * u)
            ctx.addPath(windowPath(cam, grow: 6 * u))
            ctx.strokePath()
            ctx.restoreGState()
        case .broadcast:
            // Corner brackets just outside the window.
            let len = min(cam.width, cam.height) * 0.12, gap = 10 * u, t = 8 * u
            ctx.setFillColor(d.accent.nsColor.cgColor)
            let o = cam.insetBy(dx: -gap - t, dy: -gap - t)
            for (x, y, sx, sy) in [(o.minX, o.minY, 1.0, 1.0), (o.maxX, o.minY, -1.0, 1.0), (o.minX, o.maxY, 1.0, -1.0), (o.maxX, o.maxY, -1.0, -1.0)] {
                ctx.fill(CGRect(x: sx > 0 ? x : x - len, y: sy > 0 ? y : y - t, width: len, height: t))
                ctx.fill(CGRect(x: sx > 0 ? x : x - t, y: sy > 0 ? y : y - len, width: t, height: len))
            }
        case .cinema:
            if d.transparentBackground {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(all)
            }
        case .conference:
            // Accent strip along the bottom and a bar beside the speaker panel.
            ctx.setFillColor(d.accent.nsColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: 0.035 * H))
            if let lab = l.label {
                let r = rect(lab)
                ctx.fill(CGRect(x: r.minX - 18 * u, y: r.minY, width: 6 * u, height: r.height))
            }
            ctx.setFillColor(d.accent.nsColor.withAlphaComponent(0.35).cgColor)
            ctx.fill(CGRect(x: 0, y: 0.035 * H, width: W, height: 4 * u))
        case .meeting:
            // Soft shadow under the window and an accent underline under the name.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * u), blur: 28 * u, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(windowPath(cam))
            ctx.fillPath()
            ctx.restoreGState()
            if let lab = l.label {
                let r = rect(lab)
                ctx.setFillColor(d.accent.nsColor.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX, y: r.minY - 2 * u, width: 120 * u, height: 6 * u),
                                   cornerWidth: 3 * u, cornerHeight: 3 * u, transform: nil))
                ctx.fillPath()
            }
        case .webinar:
            // Glow behind the window and an accent bar above the title.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 50 * u, color: d.accent.nsColor.withAlphaComponent(0.6).cgColor)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(windowPath(cam))
            ctx.fillPath()
            ctx.restoreGState()
            if let lab = l.label {
                let r = rect(lab)
                ctx.setFillColor(d.accent.nsColor.cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.maxY + 10 * u, width: 90 * u, height: 8 * u))
            }
        case .keynote:
            // Thin accent line above the name strap.
            if let lab = l.label {
                let r = rect(lab)
                ctx.setFillColor(d.accent.nsColor.cgColor)
                ctx.fill(CGRect(x: r.midX - 60 * u, y: r.maxY - 4 * u, width: 120 * u, height: 3 * u))
            }
        default:
            break
        }
        // The window: transparent (the camera shows through) or a placeholder.
        ctx.saveGState()
        ctx.addPath(windowPath(cam))
        if placeholder {
            ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
            ctx.fillPath()
            if l.border > 0 {
                ctx.setStrokeColor(d.accent.nsColor.cgColor)
                ctx.setLineWidth(CGFloat(l.border * H))
                ctx.addPath(windowPath(cam))
                ctx.strokePath()
            }
        } else {
            ctx.setBlendMode(.clear)
            ctx.fillPath()
        }
        ctx.restoreGState()
        drawLabels(d, l, in: ctx, rect: l.label.map(rect), unit: u)
    }

    private static func drawLabels(_ d: FrameDesign, _ l: FrameLayout, in ctx: CGContext, rect: CGRect?, unit u: CGFloat) {
        guard let r = rect, d.showsLabels else { return }
        let handwritten = d.template == .polaroid
        let titleSize: CGFloat = min(r.height * (d.subtitle.isEmpty ? 0.6 : 0.42), (handwritten ? 70 : 64) * u)
        let subSize: CGFloat = titleSize * 0.6
        func font(_ size: CGFloat, bold: Bool) -> NSFont {
            if handwritten, let f = NSFont(name: "Noteworthy-Bold", size: size) { return f }
            return NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = l.labelAlign == .center ? .center : .left
        para.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: d.template == .cinema ? d.title.uppercased() : d.title, attributes: [
            .font: font(titleSize, bold: true), .foregroundColor: d.textColor.nsColor, .paragraphStyle: para,
            .kern: d.template == .cinema ? 6 * u : 0])
        let sub = NSAttributedString(string: d.subtitle, attributes: [
            .font: font(subSize, bold: false), .foregroundColor: d.textColor.nsColor.withAlphaComponent(0.85), .paragraphStyle: para])
        let tagText = d.template.usesTag ? d.tag : ""
        let th = d.title.isEmpty ? 0 : title.size().height
        let sh = d.subtitle.isEmpty ? 0 : sub.size().height
        var x = r.minX, width = r.width
        let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        if d.template == .broadcast {
            // Strap: accent tag box, then a dark box with the name.
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.75))
            ctx.fill(r)
            if !tagText.isEmpty {
                let tag = NSAttributedString(string: tagText.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: r.height * 0.36, weight: .heavy), .foregroundColor: NSColor.white, .kern: 2 * u])
                let tw = tag.size().width + 40 * u
                ctx.setFillColor(d.accent.nsColor.cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: tw, height: r.height))
                tag.draw(at: CGPoint(x: r.minX + 20 * u, y: r.midY - tag.size().height / 2))
                x += tw + 24 * u; width -= tw + 24 * u
            } else {
                x += 24 * u; width -= 24 * u
            }
        }
        let block = th + sh
        var y = r.midY + block / 2
        if th > 0 { y -= th; title.draw(in: CGRect(x: x, y: y, width: width, height: th)) }
        if sh > 0 { y -= sh; sub.draw(in: CGRect(x: x, y: y, width: width, height: sh)) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Gallery picture with a grey camera window.
    public static func image(_ d: FrameDesign, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(d, in: ctx, width: Double(width), height: Double(height), placeholder: true)
        return ctx.makeImage()
    }
}
#endif
