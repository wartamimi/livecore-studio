#if os(macOS)
import AppKit
import CoreImage
import CoreVideo
import LiveCoreCore

/// QR code input (0.58.0): the selected item's code on a styled card at the output size,
/// transparent around it, so it works as an overlay (full screen) with its own in / out motion.
public final class QRCodeSource: VideoSource {
    public let id: InputID
    public let kind: InputKind = .qrCode
    public var name: String
    public private(set) var status: SourceStatus = .live
    public var onStatusChange: ((SourceStatus) -> Void)?
    public private(set) var design: QRDesign
    private let outputSize: PixelSize
    private let lock = UnfairLock()
    private var frame: CVPixelBuffer?

    public init(id: InputID, design: QRDesign, outputSize: PixelSize) {
        self.id = id; self.design = design; self.outputSize = outputSize
        name = Self.name(for: design)
        render()
    }

    static func name(for d: QRDesign) -> String {
        let n = d.current.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == "QR" ? "QR Code" : "QR – \(n)"
    }

    public func update(_ d: QRDesign) {
        design = d
        render()
    }

    /// Shows item `index` (0-based, clamped).
    public func select(_ index: Int) {
        design.selected = min(max(index, 0), design.items.count - 1)
        render()
    }

    private func render() {
        let d = design, w = outputSize.width, h = outputSize.height
        let pb = PixelBufferFactory.draw(width: w, height: h) { ctx in
            QRRenderer.draw(d, in: ctx, width: Double(w), height: Double(h))
        }
        lock.withLock { frame = pb }
    }

    public func start() {}
    public func stop() {}
    public func currentFrame() -> CVPixelBuffer? { lock.withLock { frame } }
}

public enum QRRenderer {
    /// The module grid of `text` (nil when it cannot be encoded, e.g. too long).
    public static func matrix(_ text: String, correction: QRCorrection) -> QRMatrix? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue(correction.rawValue, forKey: "inputCorrectionLevel")
        guard let img = f.outputImage else { return nil }
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w > 0, h > 0, w < 400, let cg = SharedCI.standard.createCGImage(img, from: img.extent) else { return nil }
        var px = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // CGContext rows start at the top of memory = top of the picture.
        return QRMatrix.trimmed(width: w, height: h, dark: px.map { $0 < 128 })
    }

    /// Reads the text of the first QR code in a picture (to restyle a bank's QRIS picture).
    public static func decode(imageAt url: URL) -> String? {
        guard let img = CIImage(contentsOf: url),
              let det = CIDetector(ofType: CIDetectorTypeQRCode, context: SharedCI.standard,
                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return det.features(in: img).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    private static var imageCache: [String: CGImage] = [:]
    private static let cacheLock = UnfairLock()

    static func image(_ path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let c = cacheLock.withLock({ imageCache[path] }) { return c }
        guard let ns = NSImage(contentsOfFile: path), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cacheLock.withLock { if imageCache.count > 16 { imageCache.removeAll() }; imageCache[path] = cg }
        return cg
    }

    /// Draws the card in a `width` × `height` CoreGraphics context (y up).
    public static func draw(_ d: QRDesign, in ctx: CGContext, width W: Double, height H: Double) {
        let s = d.style, item = d.current
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = item.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionLines = caption.isEmpty ? 0 : min(4, caption.components(separatedBy: "\n").count)
        let l = QRCardLayout.layout(s, width: W, height: H, titleLines: title.isEmpty ? 0 : 1, captionLines: captionLines)
        // y-down layout → y-up context
        func r(_ q: QRRect) -> CGRect { CGRect(x: q.x, y: H - q.y - q.height, width: q.width, height: q.height) }
        let card = r(l.card), code = r(l.code)
        let radius = CGFloat(s.cornerRadius * l.code.width)

        ctx.saveGState()
        if s.card != .none {
            let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if s.card == .glow {
                ctx.setShadow(offset: .zero, blur: CGFloat(l.padding * 1.6), color: s.accent.nsColor.withAlphaComponent(0.9).cgColor)
            } else {
                ctx.setShadow(offset: CGSize(width: 0, height: -l.padding * 0.15), blur: CGFloat(l.padding * 0.6),
                              color: NSColor(white: 0, alpha: 0.35).cgColor)
            }
            ctx.addPath(path); ctx.setFillColor(s.cardColor.nsColor.cgColor); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            if s.card == .border || s.card == .glow {
                let lw = CGFloat(max(2, l.padding * 0.18))
                let inset = card.insetBy(dx: lw / 2, dy: lw / 2)
                ctx.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, radius - lw / 2), cornerHeight: max(0, radius - lw / 2), transform: nil))
                ctx.setStrokeColor(s.accent.nsColor.cgColor); ctx.setLineWidth(lw); ctx.strokePath()
            }
        }
        ctx.restoreGState()

        // Code background (light quiet zone).
        let bgRadius = s.card == .none ? radius : radius * 0.5
        ctx.addPath(CGPath(roundedRect: code, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil))
        ctx.setFillColor(s.background.nsColor.cgColor); ctx.fillPath()

        if item.kind == .image {
            if let img = image(item.imagePath) { drawFitted(img, in: code.insetBy(dx: code.width * 0.03, dy: code.width * 0.03), ctx: ctx) }
        } else if let text = item.payload, let m = matrix(text, correction: s.effectiveCorrection) {
            drawModules(m, style: s, in: code, ctx: ctx)
        } else {
            drawPlaceholder(in: code, ctx: ctx)
        }

        // Words
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        if !title.isEmpty {
            let font = NSFont.systemFont(ofSize: CGFloat(QRCardLayout.titleFont(s, height: H)), weight: .bold)
            let rect = CGRect(x: card.minX + l.padding * 0.5, y: card.maxY - l.padding - l.titleHeight,
                              width: card.width - l.padding, height: l.titleHeight)
            fit(title, font: font, color: s.titleColor.nsColor, para: para, in: rect)
        }
        if captionLines > 0 {
            let font = NSFont.systemFont(ofSize: CGFloat(QRCardLayout.captionFont(s, height: H)), weight: .medium)
            let rect = CGRect(x: card.minX + l.padding * 0.5, y: card.minY + l.padding * 0.6,
                              width: card.width - l.padding, height: l.captionHeight)
            fit(caption, font: font, color: s.captionColor.nsColor, para: para, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws text in `rect`, shrinking the font when a line is wider than the card.
    private static func fit(_ text: String, font: NSFont, color: NSColor, para: NSParagraphStyle, in rect: CGRect) {
        var size = font.pointSize
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let widest = text.components(separatedBy: "\n").map { NSAttributedString(string: $0, attributes: attrs).size().width }.max() ?? 0
        if widest > rect.width, widest > 0 {
            size = max(8, size * rect.width / widest)
            attrs[.font] = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let h = str.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        let y = rect.minY + max(0, (rect.height - h) / 2)
        str.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: min(h, rect.height + size)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func drawFitted(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let sc = min(rect.width / iw, rect.height / ih)
        let w = iw * sc, h = ih * sc
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    private static func drawPlaceholder(in rect: CGRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor(white: 0.6, alpha: 1).cgColor)
        ctx.setLineWidth(max(2, rect.width * 0.01))
        ctx.setLineDash(phase: 0, lengths: [rect.width * 0.04, rect.width * 0.03])
        ctx.stroke(rect.insetBy(dx: rect.width * 0.1, dy: rect.width * 0.1))
        ctx.setLineDash(phase: 0, lengths: [])
    }

    static func drawModules(_ m: QRMatrix, style s: QRStyle, in rect: CGRect, ctx: CGContext) {
        let quiet = 2.0
        let unit = rect.width / CGFloat(Double(m.size) + quiet * 2)
        let ox = rect.minX + unit * CGFloat(quiet), oyTop = rect.maxY - unit * CGFloat(quiet)
        func cell(_ x: Int, _ y: Int) -> CGRect { CGRect(x: ox + CGFloat(x) * unit, y: oyTop - CGFloat(y + 1) * unit, width: unit, height: unit) }
        ctx.setFillColor(s.foreground.nsColor.cgColor)
        ctx.setShouldAntialias(s.moduleShape != .square)
        let logo = image(s.logoPath)
        let logoSide = CGFloat(s.clampedLogoSize) * rect.width
        let logoRect = CGRect(x: rect.midX - logoSide / 2, y: rect.midY - logoSide / 2, width: logoSide, height: logoSide)
        let clearRect = logo == nil ? CGRect.null : logoRect.insetBy(dx: -unit * 0.6, dy: -unit * 0.6)
        for y in 0..<m.size { for x in 0..<m.size where m[x, y] && !m.isFinder(x, y) {
            let c = cell(x, y)
            if !clearRect.isNull, clearRect.intersects(c.insetBy(dx: unit * 0.3, dy: unit * 0.3)) { continue }
            switch s.moduleShape {
            case .square: ctx.fill(c.insetBy(dx: -0.25, dy: -0.25))
            case .rounded:
                ctx.addPath(CGPath(roundedRect: c.insetBy(dx: unit * 0.04, dy: unit * 0.04), cornerWidth: unit * 0.32, cornerHeight: unit * 0.32, transform: nil))
                ctx.fillPath()
            case .dots: ctx.fillEllipse(in: c.insetBy(dx: unit * 0.08, dy: unit * 0.08))
            }
        } }
        ctx.setShouldAntialias(true)
        // Eyes
        for (ex, ey) in [(0, 0), (m.size - 7, 0), (0, m.size - 7)] {
            let outer = cell(ex, ey).union(cell(ex + 6, ey + 6))
            let ring = unit
            let inner = cell(ex + 2, ey + 2).union(cell(ex + 4, ey + 4))
            ctx.setFillColor(s.eyeColor.nsColor.cgColor)
            let rOuter: CGFloat = s.moduleShape == .square ? 0 : unit * 1.6
            let rHole: CGFloat = s.moduleShape == .square ? 0 : unit * 1.0
            let rInner: CGFloat = s.moduleShape == .square ? 0 : unit * (s.moduleShape == .dots ? 1.5 : 0.8)
            let p = CGMutablePath()
            p.addRoundedRect(in: outer, cornerWidth: rOuter, cornerHeight: rOuter)
            p.addRoundedRect(in: outer.insetBy(dx: ring, dy: ring), cornerWidth: rHole, cornerHeight: rHole)
            ctx.addPath(p); ctx.fillPath(using: .evenOdd)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: rInner, cornerHeight: rInner, transform: nil)); ctx.fillPath()
        }
        if let logo {
            let pad = logoRect.insetBy(dx: -unit * 0.5, dy: -unit * 0.5)
            ctx.addPath(CGPath(roundedRect: pad, cornerWidth: unit, cornerHeight: unit, transform: nil))
            ctx.setFillColor(s.background.nsColor.cgColor); ctx.fillPath()
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: logoRect, cornerWidth: unit * 0.6, cornerHeight: unit * 0.6, transform: nil)); ctx.clip()
            drawFitted(logo, in: logoRect, ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// Picture for the editor (the whole output, transparent around the card).
    public static func image(_ d: QRDesign, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(d, in: ctx, width: Double(width), height: Double(height))
        return ctx.makeImage()
    }
}
#endif
