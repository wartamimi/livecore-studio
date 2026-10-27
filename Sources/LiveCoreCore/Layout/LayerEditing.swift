/// Geometry operations used by the visual scene editor (drag to move, corner handles to resize).
/// Pure functions on normalized rects, so the editor's behaviour is unit-tested.
public enum LayerEditing {
    public static let minimumSize = 0.05
    /// A layer may hang off the canvas, but at least this much of it stays visible/grabbable.
    public static let minimumVisible = 0.05

    public enum Handle: Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        /// Edge handles (Layer Designer): move one side only.
        case top, bottom, left, right

        public static let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        /// Position on the layer box: 0 = left/top, 0.5 = middle, 1 = right/bottom.
        public var anchor: (x: Double, y: Double) {
            switch self {
            case .topLeft: return (0, 0)
            case .topRight: return (1, 0)
            case .bottomLeft: return (0, 1)
            case .bottomRight: return (1, 1)
            case .top: return (0.5, 0)
            case .bottom: return (0.5, 1)
            case .left: return (0, 0.5)
            case .right: return (1, 0.5)
            }
        }
        public var isCorner: Bool { Self.corners.contains(self) }
        var movesLeft: Bool { self == .topLeft || self == .bottomLeft || self == .left }
        var movesRight: Bool { self == .topRight || self == .bottomRight || self == .right }
        var movesTop: Bool { self == .topLeft || self == .topRight || self == .top }
        var movesBottom: Bool { self == .bottomLeft || self == .bottomRight || self == .bottom }
    }

    public static func move(_ r: NormRect, dx: Double, dy: Double) -> NormRect {
        var o = r
        o.x = min(max(r.x + dx, minimumVisible - r.width), 1 - minimumVisible)
        o.y = min(max(r.y + dy, minimumVisible - r.height), 1 - minimumVisible)
        return o
    }

    /// Drags one corner by (dx, dy). With `aspect` (width/height in normalized units) the
    /// opposite corner stays fixed and the rect keeps that shape.
    /// An edge handle moves that side only (`aspect` is ignored).
    public static func resize(_ r: NormRect, handle: Handle, dx: Double, dy: Double, aspect: Double? = nil) -> NormRect {
        var x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
        if handle.movesLeft { x0 += dx }
        if handle.movesRight { x1 += dx }
        if handle.movesTop { y0 += dy }
        if handle.movesBottom { y1 += dy }
        var w = max(x1 - x0, minimumSize), h = max(y1 - y0, minimumSize)
        if !handle.isCorner {
            return NormRect(x: handle.movesLeft ? r.x + r.width - w : r.x, y: handle.movesTop ? r.y + r.height - h : r.y,
                            width: w, height: h)
        }
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

    // MARK: Layer Designer (0.25.0)

    /// Lines a moved or resized layer snaps to: canvas edges, centre, title-safe guides, and the
    /// edges and centres of the other layers.
    public struct SnapResult: Equatable, Sendable {
        public var rect: NormRect
        /// Guide lines to draw (normalized x of vertical lines, y of horizontal lines).
        public var guidesX: [Double]
        public var guidesY: [Double]
    }

    static let canvasGuides: [Double] = [0, 0.05, 0.5, 0.95, 1]

    /// Snaps a moved layer: its left, centre or right (top, middle or bottom) line jumps onto the
    /// nearest guide within `tolerance`, keeping its size.
    public static func snapMove(_ r: NormRect, others: [NormRect], tolerance: Double = 0.012) -> SnapResult {
        let gx = canvasGuides + others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] }
        let gy = canvasGuides + others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] }
        var out = r
        var lx: [Double] = [], ly: [Double] = []
        if let (shift, line) = best([r.x, r.x + r.width / 2, r.x + r.width], gx, tolerance) { out.x += shift; lx = [line] }
        if let (shift, line) = best([r.y, r.y + r.height / 2, r.y + r.height], gy, tolerance) { out.y += shift; ly = [line] }
        return SnapResult(rect: out, guidesX: lx, guidesY: ly)
    }

    /// Snaps the sides a resize handle moves onto the nearest guide (the other sides stay).
    public static func snapResize(_ r: NormRect, handle: Handle, others: [NormRect], tolerance: Double = 0.012) -> SnapResult {
        let gx = canvasGuides + others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] }
        let gy = canvasGuides + others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] }
        var x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
        var lx: [Double] = [], ly: [Double] = []
        if handle.movesLeft, let (s, l) = best([x0], gx, tolerance), x1 - (x0 + s) >= minimumSize { x0 += s; lx = [l] }
        if handle.movesRight, let (s, l) = best([x1], gx, tolerance), x1 + s - x0 >= minimumSize { x1 += s; lx = [l] }
        if handle.movesTop, let (s, l) = best([y0], gy, tolerance), y1 - (y0 + s) >= minimumSize { y0 += s; ly = [l] }
        if handle.movesBottom, let (s, l) = best([y1], gy, tolerance), y1 + s - y0 >= minimumSize { y1 += s; ly = [l] }
        return SnapResult(rect: NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), guidesX: lx, guidesY: ly)
    }

    /// Smallest shift that puts one of `lines` on one of `guides`, with the guide it lands on.
    private static func best(_ lines: [Double], _ guides: [Double], _ tolerance: Double) -> (Double, Double)? {
        var found: (Double, Double)?
        for v in lines {
            for g in guides where abs(g - v) <= tolerance {
                if found == nil || abs(g - v) < abs(found!.0) { found = (g - v, g) }
            }
        }
        return found
    }

    /// Crops a layer by dragging one of its edges, vMix-style: the picture stays where it is and
    /// the edge eats into it. `symmetric` (Shift) crops the opposite side by the same amount.
    /// Exact for Stretch, and for Fit/Fill when the box has the cropped picture's aspect.
    public static func crop(_ r: NormRect, crop c: LayerStyle.Crop, handle: Handle, dx: Double, dy: Double,
                            symmetric: Bool) -> (rect: NormRect, crop: LayerStyle.Crop) {
        var out = c
        // The box the whole (uncropped) source would fill.
        let fullW = r.width / max(1 - c.left - c.right, 0.1), fullH = r.height / max(1 - c.top - c.bottom, 0.1)
        let fullX = r.x - c.left * fullW, fullY = r.y - c.top * fullH
        func clampPair(_ a: inout Double, _ b: inout Double) {
            a = min(max(a, 0), 0.45); b = min(max(b, 0), 0.45)
            if a + b > 0.9 { let k = 0.9 / (a + b); a *= k; b *= k }
        }
        if handle.movesLeft || handle.movesRight {
            let d = handle.movesLeft ? dx / fullW : -dx / fullW
            if handle.movesLeft { out.left = c.left + d } else { out.right = c.right + d }
            if symmetric { if handle.movesLeft { out.right = c.right + d } else { out.left = c.left + d } }
            clampPair(&out.left, &out.right)
        }
        if handle.movesTop || handle.movesBottom {
            let d = handle.movesTop ? dy / fullH : -dy / fullH
            if handle.movesTop { out.top = c.top + d } else { out.bottom = c.bottom + d }
            if symmetric { if handle.movesTop { out.bottom = c.bottom + d } else { out.top = c.top + d } }
            clampPair(&out.top, &out.bottom)
        }
        let rect = NormRect(x: fullX + out.left * fullW, y: fullY + out.top * fullH,
                            width: fullW * (1 - out.left - out.right), height: fullH * (1 - out.top - out.bottom))
        return (rect, out)
    }
}

/// A saved layout (Layer Designer › Save as template): the layers of an input with their place,
/// look and sources, to put on another input later.
public struct LayoutTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var layers: [Layer]

    public init(id: String, name: String, layers: [Layer]) {
        self.id = id; self.name = name; self.layers = layers
    }

    /// Layers of the target input after applying the template: layers are matched by position
    /// (layer 0 is each input's own picture). Matched layers keep their source and take the
    /// template's place and look; template layers beyond the target's are added when their
    /// source still exists (`exists`). Flatten stays as the target had it.
    public func apply(to target: [Layer], exists: (InputID) -> Bool) -> [Layer] {
        var out = target
        for (i, t) in layers.enumerated() {
            if out.indices.contains(i) {
                out[i].rect = t.rect
                out[i].scaleMode = t.scaleMode
                out[i].opacity = t.opacity
                out[i].style = t.style
                out[i].hidden = t.hidden
                out[i].locked = t.locked
            } else if i > 0, exists(t.source) {
                var l = t
                l.flatten = nil
                out.append(l)
            }
        }
        return out
    }
}
