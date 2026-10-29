/// Per-layer look: crop of the source, rounded corners or an ellipse mask, and a border (0.13.0).
/// Absent (nil) on layers from older projects, which draw exactly as before.
public struct LayerStyle: Equatable, Codable, Sendable {
    /// Fractions of the source cut away on each side (0...0.45; opposite sides keep ≥ 10 % visible).
    public struct Crop: Equatable, Codable, Sendable {
        public var left: Double, top: Double, right: Double, bottom: Double
        public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
            self.left = left; self.top = top; self.right = right; self.bottom = bottom
        }
        public static let none = Crop()
        public var isNone: Bool { left <= 0 && top <= 0 && right <= 0 && bottom <= 0 }
        public var clamped: Crop {
            func c(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 0.45) : 0 }
            var r = Crop(left: c(left), top: c(top), right: c(right), bottom: c(bottom))
            if r.left + r.right > 0.9 { let s = 0.9 / (r.left + r.right); r.left *= s; r.right *= s }
            if r.top + r.bottom > 0.9 { let s = 0.9 / (r.top + r.bottom); r.top *= s; r.bottom *= s }
            return r
        }
    }

    public enum Shape: String, Codable, Sendable, CaseIterable {
        case rectangle   // with `cornerRadius` (0 = sharp corners)
        case ellipse     // circle when the layer box is square
    }

    public var crop: Crop
    public var shape: Shape
    /// Corner radius as a fraction of the shorter side of the drawn picture (0...0.5).
    public var cornerRadius: Double
    /// Border width as a fraction of the canvas height (0...0.05); 0 = no border.
    public var borderWidth: Double
    public var borderColor: ChromaKey.RGB

    public init(crop: Crop = .none, shape: Shape = .rectangle, cornerRadius: Double = 0,
                borderWidth: Double = 0, borderColor: ChromaKey.RGB = ChromaKey.RGB(r: 1, g: 1, b: 1)) {
        self.crop = crop; self.shape = shape; self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth; self.borderColor = borderColor
    }

    public var clamped: LayerStyle {
        func c(_ v: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, 0), hi) : 0 }
        var s = self
        s.crop = crop.clamped
        s.cornerRadius = c(cornerRadius, 0.5)
        s.borderWidth = c(borderWidth, 0.05)
        return s
    }

    /// True when the layer needs the masked (rounded / ellipse / border) draw path.
    public var needsMask: Bool { shape == .ellipse || cornerRadius > 0.0005 || borderWidth > 0.0001 }
}

/// Geometry of one layer draw: where it lands and which part of the source it samples.
public struct LayerDraw: Equatable, Sendable {
    /// Destination in canvas pixels (already clipped to the layer box and the canvas).
    public var dest: PixelRect
    /// Texture coordinates of `dest`'s corners: u0, v0, u1, v1.
    public var uv: (Double, Double, Double, Double)
    /// Visible picture before canvas clipping: the mask (corners, ellipse, border) follows it.
    public var maskRect: PixelRect

    public static func == (a: LayerDraw, b: LayerDraw) -> Bool {
        a.dest == b.dest && a.maskRect == b.maskRect
            && a.uv.0 == b.uv.0 && a.uv.1 == b.uv.1 && a.uv.2 == b.uv.2 && a.uv.3 == b.uv.3
    }

    /// nil when nothing is visible.
    public static func compute(rect: NormRect, source: PixelSize, mode: ScaleMode, crop: LayerStyle.Crop,
                               canvas: PixelSize) -> LayerDraw? {
        let c = crop.clamped
        let cw = 1 - c.left - c.right, ch = 1 - c.top - c.bottom
        // The cropped source behaves like a smaller source for placement.
        let cropped = PixelSize(width: max(Int((Double(source.width) * cw).rounded()), 1),
                                height: max(Int((Double(source.height) * ch).rounded()), 1))
        let box = LayoutMath.toPixels(rect, canvas: canvas)
        let placed = LayoutMath.place(source: cropped, in: box, mode: mode)
        let canvasRect = PixelRect(x: 0, y: 0, width: Double(canvas.width), height: Double(canvas.height))
        guard placed.width > 0, placed.height > 0,
              let visible = LayoutMath.intersect(placed, box),
              let dest = LayoutMath.intersect(visible, canvasRect) else { return nil }
        // uv within the cropped picture, then mapped into the full texture.
        let pu0 = (dest.x - placed.x) / placed.width, pv0 = (dest.y - placed.y) / placed.height
        let pu1 = (dest.x + dest.width - placed.x) / placed.width, pv1 = (dest.y + dest.height - placed.y) / placed.height
        let uv = (c.left + pu0 * cw, c.top + pv0 * ch, c.left + pu1 * cw, c.top + pv1 * ch)
        return LayerDraw(dest: dest, uv: uv, maskRect: visible)
    }
}
