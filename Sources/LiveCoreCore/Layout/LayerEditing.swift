/// Geometry operations used by the visual scene editor (drag to move, corner handles to resize).
/// Pure functions on normalized rects, so the editor's behaviour is unit-tested.
public enum LayerEditing {
    public static let minimumSize = 0.05
    /// A layer may hang off the canvas, but at least this much of it stays visible/grabbable.
    public static let minimumVisible = 0.05

    public enum Handle: Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    public static func move(_ r: NormRect, dx: Double, dy: Double) -> NormRect {
        var o = r
        o.x = min(max(r.x + dx, minimumVisible - r.width), 1 - minimumVisible)
        o.y = min(max(r.y + dy, minimumVisible - r.height), 1 - minimumVisible)
        return o
    }

    /// Drags one corner by (dx, dy). With `aspect` (width/height in normalized units) the
    /// opposite corner stays fixed and the rect keeps that shape.
    public static func resize(_ r: NormRect, handle: Handle, dx: Double, dy: Double, aspect: Double? = nil) -> NormRect {
        var x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
        switch handle {
        case .topLeft: x0 += dx; y0 += dy
        case .topRight: x1 += dx; y0 += dy
        case .bottomLeft: x0 += dx; y1 += dy
        case .bottomRight: x1 += dx; y1 += dy
        }
        var w = max(x1 - x0, minimumSize), h = max(y1 - y0, minimumSize)
        if let aspect, aspect > 0 {
            // Follow the larger relative change, then derive the other side.
            if w / aspect >= h { h = max(w / aspect, minimumSize); w = h * aspect } else { w = max(h * aspect, minimumSize); h = w / aspect }
        }
        // Anchor the corner opposite the handle.
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let nx = left ? r.x + r.width - w : r.x
        let ny = top ? r.y + r.height - h : r.y
        return NormRect(x: nx, y: ny, width: w, height: h)
    }

    /// Normalized aspect (width/height in canvas units) that makes a source of `source` pixels
    /// undistorted on a canvas of `canvas` pixels.
    public static func normalizedAspect(source: PixelSize, canvas: PixelSize) -> Double? {
        guard source.width > 0, source.height > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        return source.aspect / canvas.aspect
    }

    /// Moves the layer at `from` to `to` (indices into the layer list). Layer 0 (the input itself)
    /// stays the bottom layer; out-of-range moves are ignored.
    public static func reorder(_ layers: [Layer], from: Int, to: Int) -> [Layer] {
        guard from > 0, to > 0, from < layers.count, to < layers.count, from != to else { return layers }
        var l = layers
        let item = l.remove(at: from)
        l.insert(item, at: to)
        return l
    }

    /// Snaps an edge value to 0, 0.5, 1 and the safe-area guides when within `tolerance`.
    public static func snap(_ v: Double, tolerance: Double = 0.01) -> Double {
        for g in [0, 0.05, 0.5, 0.95, 1.0] where abs(v - g) <= tolerance { return g }
        return v
    }
}
