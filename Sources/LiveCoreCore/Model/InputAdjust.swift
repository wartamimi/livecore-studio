/// Per-input picture adjustments (input colour correction and orientation, like vMix's input
/// colour correction): applied once to the source picture, so every use of the input (Program,
/// Preview, scene layers, overlays, thumbnails) shows the corrected picture.
public struct InputAdjust: Codable, Equatable, Sendable {
    /// Added to every channel, -0.5...0.5.
    public var brightness: Double
    /// Around mid grey, 0...2 (1 = unchanged).
    public var contrast: Double
    /// 0 = black and white, 1 = unchanged, 2 = double.
    public var saturation: Double
    /// 0.5...2 (1 = unchanged; above 1 brightens the mid tones).
    public var gamma: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, gamma: Double = 1,
                flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation; self.gamma = gamma
        self.flipHorizontal = flipHorizontal; self.flipVertical = flipVertical
    }

    private enum CodingKeys: String, CodingKey { case brightness, contrast, saturation, gamma, flipHorizontal, flipVertical }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(brightness: try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0,
                  contrast: try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
                  saturation: try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1,
                  gamma: try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1,
                  flipHorizontal: try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false,
                  flipVertical: try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false)
    }

    public var clamped: InputAdjust {
        InputAdjust(brightness: min(max(brightness, -0.5), 0.5), contrast: min(max(contrast, 0), 2),
                    saturation: min(max(saturation, 0), 2), gamma: min(max(gamma, 0.5), 2),
                    flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    /// True when the picture is unchanged (the compositor then skips the adjustment pass).
    public var isIdentity: Bool {
        let a = clamped
        return abs(a.brightness) < 1e-4 && abs(a.contrast - 1) < 1e-4 && abs(a.saturation - 1) < 1e-4
            && abs(a.gamma - 1) < 1e-4 && !flipHorizontal && !flipVertical
    }

    public var hasColorChange: Bool {
        var a = self; a.flipHorizontal = false; a.flipVertical = false
        return !a.isIdentity
    }

    /// The colour math of the GPU pass (`adjust_fragment`), on straight (unpremultiplied) 0...1
    /// values: gamma, then contrast around 0.5 plus brightness, then saturation around Rec. 709 luma.
    public func apply(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let a = clamped
        func gam(_ v: Double) -> Double { Self.pow(max(v, 0), 1 / a.gamma) }
        var c = (gam(r), gam(g), gam(b))
        func con(_ v: Double) -> Double { (v - 0.5) * a.contrast + 0.5 + a.brightness }
        c = (con(c.0), con(c.1), con(c.2))
        let luma = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        func sat(_ v: Double) -> Double { min(max(luma + (v - luma) * a.saturation, 0), 1) }
        return (sat(c.0), sat(c.1), sat(c.2))
    }

    /// pow without Foundation (exp/log series are not needed: x^y = e^(y ln x)).
    static func pow(_ x: Double, _ y: Double) -> Double {
        if x <= 0 { return 0 }
        if y == 1 { return x }
        return exp(y * log(x))
    }
}

// Foundation-free exp/log good to ~1e-12 for the ranges used here.
private func log(_ x: Double) -> Double {
    // ln x = 2 atanh((x-1)/(x+1)) after range reduction by powers of 2.
    var m = x, k = 0.0
    while m > 2 { m /= 2; k += 1 }
    while m < 0.5 { m *= 2; k -= 1 }
    let t = (m - 1) / (m + 1), t2 = t * t
    var term = t, sum = 0.0
    var n = 1.0
    for _ in 0..<40 { sum += term / n; term *= t2; n += 2 }
    return 2 * sum + k * 0.6931471805599453
}

private func exp(_ x: Double) -> Double {
    // e^x = (e^(x/2^k))^(2^k) with a Taylor series for the small remainder.
    var k = 0, r = x
    while abs(r) > 0.5 { r /= 2; k += 1 }
    var term = 1.0, sum = 1.0
    for i in 1..<25 { term *= r / Double(i); sum += term }
    for _ in 0..<k { sum *= sum }
    return sum
}
