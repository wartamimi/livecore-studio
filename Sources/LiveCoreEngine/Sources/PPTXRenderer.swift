#if os(macOS)
import AppKit
import LiveCoreServices

/// LiveCore's own PowerPoint engine (0.80.0): draws a .pptx into a PDF, one page per slide, with
/// Core Graphics and AppKit text. No Keynote, PowerPoint or LibreOffice needed.
/// What it covers and what not: see PPTXModel.swift.
enum PPTXRenderer {
    static func writePDF(_ pptx: URL, to out: URL) throws {
        try PPTXParser.withDeck(pptx) { deck in
            var box = CGRect(x: 0, y: 0, width: deck.width, height: deck.height)
            guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else {
                throw PresentationConverter.Failure(message: "Cannot write \(out.lastPathComponent)")
            }
            for slide in deck.slides {
                ctx.beginPDFPage(nil)
                // PowerPoint measures from the top left: flip once, AppKit then draws text and images upright.
                ctx.translateBy(x: 0, y: box.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                draw(slide, in: box, ctx)
                NSGraphicsContext.restoreGraphicsState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
    }

    private static func draw(_ slide: PPTXSlide, in box: CGRect, _ ctx: CGContext) {
        ctx.setFillColor(cg(slide.background))
        ctx.fill(box)
        if let f = slide.backgroundImage, let img = NSImage(contentsOfFile: f) {
            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        for s in slide.shapes { draw(s, ctx) }
    }

    private static func draw(_ s: PPTXShape, _ ctx: CGContext) {
        let r = CGRect(x: s.frame.x, y: s.frame.y, width: s.frame.width, height: s.frame.height)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if s.rotation != 0 || s.flipH || s.flipV {
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: s.rotation * .pi / 180)
            ctx.scaleBy(x: s.flipH ? -1 : 1, y: s.flipV ? -1 : 1)
            ctx.translateBy(x: -r.midX, y: -r.midY)
        }
        let path = outline(s, r)
        if let f = s.fill { ctx.addPath(path); ctx.setFillColor(cg(f)); ctx.fillPath() }
        if let file = s.image, let img = NSImage(contentsOfFile: file) {
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let size = img.size, c = s.crop
            let src = CGRect(x: size.width * c[0], y: size.height * c[3],
                             width: size.width * (1 - c[0] - c[2]), height: size.height * (1 - c[1] - c[3]))
            img.draw(in: r, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }
        if let l = s.line, s.lineWidth > 0 {
            ctx.addPath(path); ctx.setStrokeColor(cg(l)); ctx.setLineWidth(s.lineWidth); ctx.strokePath()
        }
        if let t = s.text { draw(t, in: r) }
    }

    private static func outline(_ s: PPTXShape, _ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        switch s.geometry {
        case .rect: p.addRect(r)
        case .roundRect:
            let k = min(r.width, r.height) * 0.1667
            p.addRoundedRect(in: r, cornerWidth: k, cornerHeight: k)
        case .ellipse: p.addEllipse(in: r)
        case .line: p.move(to: pt(0, 0)); p.addLine(to: pt(1, 1))
        case .triangle: p.addLines(between: [pt(0.5, 0), pt(1, 1), pt(0, 1)]); p.closeSubpath()
        case .rtTriangle: p.addLines(between: [pt(0, 0), pt(1, 1), pt(0, 1)]); p.closeSubpath()
        case .diamond: p.addLines(between: [pt(0.5, 0), pt(1, 0.5), pt(0.5, 1), pt(0, 0.5)]); p.closeSubpath()
        case .custom:
            for c in s.path {
                switch c {
                case let .move(x, y): p.move(to: pt(x, y))
                case let .line(x, y): if p.isEmpty { p.move(to: pt(x, y)) } else { p.addLine(to: pt(x, y)) }
                case let .cubic(x1, y1, x2, y2, x, y): if !p.isEmpty { p.addCurve(to: pt(x, y), control1: pt(x1, y1), control2: pt(x2, y2)) }
                case .close: if !p.isEmpty { p.closeSubpath() }
                }
            }
        }
        return p
    }

    // MARK: Text

    private static func draw(_ t: PPTXText, in r: CGRect) {
        let area = CGRect(x: r.minX + t.insets[0], y: r.minY + t.insets[1],
                          width: max(r.width - t.insets[0] - t.insets[2], 1), height: max(r.height - t.insets[1] - t.insets[3], 1))
        let width = t.wrap ? area.width : .greatestFiniteMagnitude
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        var scale = 1.0, text = attributed(t, scale: scale)
        var height = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options).height
        // "Shrink text on overflow": smaller steps until it fits (PowerPoint stores its own scale, but not always).
        while t.shrink, height > area.height, scale > 0.4 {
            scale -= 0.08
            text = attributed(t, scale: scale)
            height = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options).height
        }
        let y: CGFloat
        switch t.anchor {
        case .top: y = area.minY
        case .middle: y = area.midY - height / 2
        case .bottom: y = area.maxY - height
        }
        text.draw(with: CGRect(x: area.minX, y: y, width: t.wrap ? area.width : max(area.width, 10_000), height: height + 2),
                  options: options)
    }

    private static func attributed(_ t: PPTXText, scale: Double) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, p) in t.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            switch p.align {
            case .left: style.alignment = .left
            case .center: style.alignment = .center
            case .right: style.alignment = .right
            case .justify: style.alignment = .justified
            }
            style.headIndent = p.marginLeft
            style.firstLineHeadIndent = max(p.marginLeft + p.firstLine, 0)
            style.paragraphSpacingBefore = i == 0 ? 0 : p.spaceBefore * scale
            if let m = p.lineSpacing { style.lineHeightMultiple = m }
            if p.bullet != nil { style.tabStops = [NSTextTab(textAlignment: .left, location: p.marginLeft)] }
            var runs = p.runs
            if let b = p.bullet, let first = runs.first { runs.insert(PPTXRun(text: b + "\t", size: first.size, color: first.color, font: first.font), at: 0) }
            if i < t.paragraphs.count - 1, let last = runs.last { runs.append(PPTXRun(text: "\n", size: last.size, color: last.color, font: last.font)) }
            for run in runs {
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font(run, size: run.size * scale), .foregroundColor: NSColor(cgColor: cg(run.color)) ?? .black,
                    .paragraphStyle: style,
                ]
                if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                out.append(NSAttributedString(string: run.text, attributes: attrs))
            }
        }
        return out
    }

    private static func font(_ r: PPTXRun, size: Double) -> NSFont {
        let size = max(size, 1)
        var traits: NSFontTraitMask = []
        if r.bold { traits.insert(.boldFontMask) }
        if r.italic { traits.insert(.italicFontMask) }
        let fm = NSFontManager.shared
        let base = r.font.flatMap { fm.font(withFamily: $0, traits: traits, weight: 5, size: size) ?? NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: r.bold ? .bold : .regular)
        return traits.isEmpty ? base : fm.convert(base, toHaveTrait: traits)
    }

    private static func cg(_ c: PPTXColor) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
}
#endif
