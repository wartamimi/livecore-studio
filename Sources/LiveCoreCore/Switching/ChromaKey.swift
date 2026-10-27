/// Per-input chroma key (green/blue screen). Evaluated on the GPU in `key_fragment`
/// (LiveCoreEngine/Render/Shaders.swift); this type holds the parameters and the colour math
/// shared by the shader and the unit tests.
///
/// Method: the pixel and the key colour are converted to their chroma components (Cb, Cr of
/// BT.709 Y'CbCr). The distance between them, minus `similarity`, is shaped by `smoothness`
/// into alpha; `spill` desaturates pixels near the key colour to remove green/blue fringes.
public struct ChromaKey: Codable, Equatable, Sendable {
    public struct RGB: Codable, Equatable, Sendable {
        public var r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        /// Typical lit chroma-key green / blue as a camera sees them (not pure primaries).
        public static let green = RGB(r: 0.0, g: 0.69, b: 0.25)
        public static let blue = RGB(r: 0.05, g: 0.20, b: 0.75)
    }

    public var enabled: Bool
    public var keyColor: RGB
    public var similarity: Double     // 0.01 ... 0.6, chroma distance that is fully keyed
    public var smoothness: Double     // 0.001 ... 0.5, width of the soft edge
    public var spill: Double          // 0.001 ... 0.5, spill-suppression range

    public init(enabled: Bool = false, keyColor: RGB = .green, similarity: Double = 0.20,
                smoothness: Double = 0.08, spill: Double = 0.10) {
        self.enabled = enabled; self.keyColor = keyColor
        self.similarity = similarity; self.smoothness = smoothness; self.spill = spill
    }

    /// Values clamped to the ranges the UI and shader expect.
    public var clamped: ChromaKey {
        var k = self
        k.similarity = min(max(similarity, 0.01), 0.6)
        k.smoothness = min(max(smoothness, 0.001), 0.5)
        k.spill = min(max(spill, 0.001), 0.5)
        return k
    }

    /// BT.709 chroma (Cb, Cr) of a non-linear RGB colour, both in about -0.5 ... 0.5.
    public static func chroma(r: Double, g: Double, b: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }

    /// CPU reference of the shader's alpha for one pixel (used by tests; the GPU does the real work).
    public func alpha(r: Double, g: Double, b: Double) -> Double {
        let k = clamped
        let p = Self.chroma(r: r, g: g, b: b)
        let q = Self.chroma(r: k.keyColor.r, g: k.keyColor.g, b: k.keyColor.b)
        let d = ((p.cb - q.cb) * (p.cb - q.cb) + (p.cr - q.cr) * (p.cr - q.cr)).squareRoot()
        let base = d - k.similarity
        let x = min(max(base / k.smoothness, 0), 1)
        return x * x * (3 - 2 * x)   // smoothstep, identical to the shader
    }
}
