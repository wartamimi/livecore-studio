/// Geometry helpers shared by the compositor and the UI.
public enum LayoutMath {
    /// Destination rectangle (pixels) for a source of size `source` drawn into `box` with `mode`.
    /// For `.fill` the returned rect may extend beyond `box`; the compositor clips with a scissor.
    public static func place(source: PixelSize, in box: PixelRect, mode: ScaleMode) -> PixelRect {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else { return box }
        if mode == .stretch { return box }
        let sx = box.width / Double(source.width)
        let sy = box.height / Double(source.height)
        let s = mode == .fit ? min(sx, sy) : max(sx, sy)
        let w = Double(source.width) * s
        let h = Double(source.height) * s
        return PixelRect(x: box.x + (box.width - w) / 2, y: box.y + (box.height - h) / 2, width: w, height: h)
    }

    public static func toPixels(_ r: NormRect, canvas: PixelSize) -> PixelRect {
        PixelRect(x: r.x * Double(canvas.width), y: r.y * Double(canvas.height),
                  width: r.width * Double(canvas.width), height: r.height * Double(canvas.height))
    }

    /// Intersection, used for scissor rects. Returns nil when empty.
    public static func intersect(_ a: PixelRect, _ b: PixelRect) -> PixelRect? {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Even dimensions are required by H.264 4:2:0 encoders.
    public static func evenSize(_ s: PixelSize) -> PixelSize {
        PixelSize(width: max(2, s.width & ~1), height: max(2, s.height & ~1))
    }
}
