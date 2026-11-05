#if os(macOS)
import AppKit
import CoreImage
import LiveCoreCore

/// Draws a title with its 3D look (0.59.0): the flat title is drawn offscreen, extruded (copies
/// towards `direction` in the side colour, far ones darker), given a bevel shine, then turned in
/// perspective (`Projection3D` + Core Image's perspective transform) for the tilt and the in / out
/// motion. Shared by template titles and running text.
enum Title3DRenderer {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        guard w > 0, h > 0 else { return nil }
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        c?.clear(CGRect(x: 0, y: 0, width: w, height: h))
        return c
    }

    /// - Parameter flat: draws the 2D title into the given full-size context, returns its area (y-up).
    static func draw(_ t: Title3D, in ctx: CGContext, width W: Double, height H: Double, progress: Double,
                     flat: (CGContext) -> CGRect) {
        let pose = t.pose(progress: progress)
        guard pose.opacity > 0.001 else { return }
        let iw = Int(W.rounded()), ih = Int(H.rounded())
        guard let off = context(iw, ih) else { return }
        let covered = flat(off)
        guard !covered.isNull, !covered.isEmpty, let full = off.makeImage() else { return }
        let u = H / 1080
        let depthPx = t.depth * u
        let pad = depthPx + 40 * u
        let crop = covered.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        guard crop.width >= 2, crop.height >= 2,
              let face = full.cropping(to: CGRect(x: crop.minX, y: H - crop.maxY, width: crop.width, height: crop.height)),
              let solid = extruded(face, t, unit: u) else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(CGFloat(pose.opacity))
        if pose.isRest {
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 18 * u, color: CGColor(gray: 0, alpha: 0.45))
            ctx.draw(solid, in: crop)
            return
        }
        // Perspective: corners in y-down pixels, then to Core Image's y-up space.
        let c = Projection3D.corners(x: crop.minX, y: H - crop.maxY, w: crop.width, h: crop.height, pose: pose, distance: 2.2 * H)
        func v(_ p: (x: Double, y: Double)) -> CIVector { CIVector(x: p.x, y: H - p.y) }
        let input = CIImage(cgImage: solid)
        guard let f = CIFilter(name: "CIPerspectiveTransform") else { return }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(v(c[0]), forKey: "inputTopLeft")
        f.setValue(v(c[1]), forKey: "inputTopRight")
        f.setValue(v(c[2]), forKey: "inputBottomRight")
        f.setValue(v(c[3]), forKey: "inputBottomLeft")
        guard let out = f.outputImage else { return }
        let ext = out.extent.intersection(CGRect(x: -W, y: -H, width: 3 * W, height: 3 * H)).integral
        guard !ext.isNull, !ext.isInfinite, ext.width >= 1, ext.height >= 1,
              let img = SharedCI.standard.createCGImage(out, from: ext) else { return }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.draw(img, in: ext)
        // Darker while turned away from the light.
        let shade = pose.turn * 0.55
        if shade > 0.01 {
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(CGColor(gray: 0, alpha: shade))
            ctx.fill(ext)
        }
        ctx.endTransparencyLayer()
    }

    /// The face with its extrusion and bevel, same size as `face` (the padding holds the depth).
    static func extruded(_ face: CGImage, _ t: Title3D, unit u: Double) -> CGImage? {
        let w = face.width, h = face.height
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let steps = min(Int((t.depth * u).rounded()), 80)
        guard let out = context(w, h) else { return nil }
        if steps > 0 {
            func tinted(_ color: CGColor?, darken: Double) -> CGImage? {
                guard let c = context(w, h) else { return nil }
                c.draw(face, in: rect)
                c.setBlendMode(.sourceAtop)
                if let color { c.setFillColor(color); c.fill(rect) }
                c.setFillColor(CGColor(gray: 0, alpha: darken))
                c.fill(rect)
                return c.makeImage()
            }
            let side = t.sideColor.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1).cgColor }
            let near = tinted(side, darken: side == nil ? 0.45 : 0)
            let far = tinted(side, darken: side == nil ? 0.65 : 0.3)
            let step = t.extrusionStep(unit: 1)
            for i in stride(from: steps, through: 1, by: -1) {
                guard let img = i > steps / 2 ? far : near else { continue }
                out.draw(img, in: rect.offsetBy(dx: step.dx * Double(i), dy: step.dy * Double(i)))
            }
        }
        // Face with a shine across its top half.
        if t.bevel, let c = context(w, h) {
            c.draw(face, in: rect)
            c.setBlendMode(.sourceAtop)
            let colors = [CGColor(gray: 1, alpha: 0.38), CGColor(gray: 1, alpha: 0.05), CGColor(gray: 0, alpha: 0.12)] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: Double(h)), end: CGPoint(x: 0, y: 0), options: [])
            }
            if let img = c.makeImage() { out.draw(img, in: rect) }
        } else {
            out.draw(face, in: rect)
        }
        return out.makeImage()
    }

    /// Running-text helper: an image drawn with extrusion only (no motion), e.g. the text strip.
    static func extrudedImage(_ img: CGImage, depth: Double, unit u: Double, side: ProjectColor? = nil) -> CGImage? {
        let pad = Int((depth * u).rounded(.up)) + 2
        guard let c = context(img.width + pad, img.height + pad) else { return nil }
        c.draw(img, in: CGRect(x: 0, y: pad, width: img.width, height: img.height))
        guard let padded = c.makeImage() else { return nil }
        return extruded(padded, Title3D(depth: depth, direction: 300, sideColor: side, bevel: true, motion: .off), unit: u)
    }
}
#endif
