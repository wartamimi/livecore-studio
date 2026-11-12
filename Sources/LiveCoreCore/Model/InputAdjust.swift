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
    /// Clockwise rotation in degrees: 0, 90, 180 or 270 (since 0.17.0). 90 / 270 swap width and height.
    public var rotation: Int
    /// Capture-card fix for a wrongly flagged signal (since 0.28.0).
    public var range: RangeFix
    /// Blend the two fields of an interlaced signal (1080i) to remove combing (since 0.28.0).
    public var deinterlace: Bool
    /// The video levels were already decided for this input (detected automatically, or set by the
    /// operator), so the automatic check does not run again (0.47.0).
    public var rangeChecked: Bool = false
    /// 3D LUT (.cube file path) applied after the colour correction, and how much of it (0.48.0).
    public var lut: String?
    public var lutStrength: Double = 1
    /// Video mask (0.51.0): shape or image that cuts the input's picture, everywhere it is used.
    public var mask = InputMask()
    /// Waving-flag warp (0.51.0), animated in the compositor.
    public var wave = InputWave()
    /// Looping motion of the picture (0.62.0): pulse, float, shake, swing, spin... animated in the compositor.
    public var motion = InputMotion()

    /// The LUT in use (a path is set and the strength is above zero).
    public var activeLUT: String? {
        guard let lut, !lut.isEmpty, lutStrength > 0.001 else { return nil }
        return lut
    }

    /// Video level correction: "limited" (16–235) pictures shown as full range look washed out;
    /// full range pictures treated as limited look crushed.
    public enum RangeFix: Int, Codable, Sendable, CaseIterable {
        case none = 0, limitedToFull = 1, fullToLimited = 2
    }

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, gamma: Double = 1,
                flipHorizontal: Bool = false, flipVertical: Bool = false, rotation: Int = 0,
                range: RangeFix = .none, deinterlace: Bool = false) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation; self.gamma = gamma
        self.flipHorizontal = flipHorizontal; self.flipVertical = flipVertical; self.rotation = rotation
        self.range = range; self.deinterlace = deinterlace
    }

    /// The same settings with colour correction and orientation reset, keeping the capture fixes.
    public var resetKeepingSignalFixes: InputAdjust {
        var a = InputAdjust(range: range, deinterlace: deinterlace); a.rangeChecked = rangeChecked; return a
    }

    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, gamma, flipHorizontal, flipVertical, rotation, range, deinterlace, rangeChecked
        case lut, lutStrength, mask, wave, motion
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(brightness: try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0,
                  contrast: try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1,
                  saturation: try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1,
                  gamma: try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1,
                  flipHorizontal: try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false,
                  flipVertical: try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false,
                  rotation: try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0,
                  range: try c.decodeIfPresent(RangeFix.self, forKey: .range) ?? .none,
                  deinterlace: try c.decodeIfPresent(Bool.self, forKey: .deinterlace) ?? false)
        rangeChecked = try c.decodeIfPresent(Bool.self, forKey: .rangeChecked) ?? false
        lut = try c.decodeIfPresent(String.self, forKey: .lut)
        lutStrength = try c.decodeIfPresent(Double.self, forKey: .lutStrength) ?? 1
        mask = try c.decodeIfPresent(InputMask.self, forKey: .mask) ?? InputMask()
        wave = try c.decodeIfPresent(InputWave.self, forKey: .wave) ?? InputWave()
        motion = try c.decodeIfPresent(InputMotion.self, forKey: .motion) ?? InputMotion()
    }

    /// Rotation snapped to 0 / 90 / 180 / 270.
    public var normalizedRotation: Int { ((Int((Double(rotation) / 90).rounded()) % 4) + 4) % 4 * 90 }

    /// Size of the adjusted picture (width and height swap for 90° / 270°).
    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        normalizedRotation % 180 == 90 ? (height, width) : (width, height)
    }

    /// Source texture coordinates (0...1, origin top-left) shown at the destination's top-left,
    /// bottom-left, top-right and bottom-right corners: flips (in the destination) then the
    /// clockwise rotation.
    public var cornerUVs: [(u: Double, v: Double)] {
        [(0.0, 0.0), (0, 1), (1, 0), (1, 1)].map { corner in
            var x = corner.0, y = corner.1
            if flipHorizontal { x = 1 - x }
            if flipVertical { y = 1 - y }
            switch normalizedRotation {
            case 90: return (y, 1 - x)
            case 180: return (1 - x, 1 - y)
            case 270: return (1 - y, x)
            default: return (x, y)
            }
        }
    }

    public var clamped: InputAdjust {
        var a = InputAdjust(brightness: min(max(brightness, -0.5), 0.5), contrast: min(max(contrast, 0), 2),
                    saturation: min(max(saturation, 0), 2), gamma: min(max(gamma, 0.5), 2),
                    flipHorizontal: flipHorizontal, flipVertical: flipVertical, rotation: normalizedRotation,
                    range: range, deinterlace: deinterlace)
        a.rangeChecked = rangeChecked
        a.lut = lut
        a.lutStrength = min(max(lutStrength, 0), 1)
        a.mask = mask.clamped
        a.wave = wave.clamped
        a.motion = motion.clamped
        return a
    }

    /// True when the picture is unchanged (the compositor then skips the adjustment pass).
    public var isIdentity: Bool {
        let a = clamped
        return abs(a.brightness) < 1e-4 && abs(a.contrast - 1) < 1e-4 && abs(a.saturation - 1) < 1e-4
            && abs(a.gamma - 1) < 1e-4 && !flipHorizontal && !flipVertical && a.rotation == 0
            && range == .none && !deinterlace && a.activeLUT == nil && !mask.isActive && !wave.enabled && !motion.isActive
    }

    /// Nothing worth keeping: no picture change and no remembered levels decision.
    public var isEmpty: Bool { isIdentity && !rangeChecked }

    public var hasColorChange: Bool {
        var a = self; a.flipHorizontal = false; a.flipVertical = false; a.rotation = 0
        a.mask = InputMask(); a.wave = InputWave(); a.motion = InputMotion()
        return !a.isIdentity
    }

    /// The colour math of the GPU pass (`adjust_fragment`), on straight (unpremultiplied) 0...1
    /// values: level range fix, gamma, then contrast around 0.5 plus brightness, then saturation
    /// around Rec. 709 luma.
    public func apply(r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let a = clamped
        func lv(_ v: Double) -> Double { Self.levels(v, a.range) }
        func gam(_ v: Double) -> Double { Self.pow(max(v, 0), 1 / a.gamma) }
        var c = (gam(lv(r)), gam(lv(g)), gam(lv(b)))
        func con(_ v: Double) -> Double { (v - 0.5) * a.contrast + 0.5 + a.brightness }
        c = (con(c.0), con(c.1), con(c.2))
        let luma = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        func sat(_ v: Double) -> Double { min(max(luma + (v - luma) * a.saturation, 0), 1) }
        return (sat(c.0), sat(c.1), sat(c.2))
    }

    /// 16–235 ↔ 0–255 level mapping (same formula as the shader).
    public static func levels(_ v: Double, _ fix: RangeFix) -> Double {
        switch fix {
        case .none: return v
        case .limitedToFull: return min(max((v - 16.0 / 255) * (255.0 / 219), 0), 1)
        case .fullToLimited: return v * (219.0 / 255) + 16.0 / 255
        }
    }

    /// pow without Foundation (exp/log series are not needed: x^y = e^(y ln x)).
    static func pow(_ x: Double, _ y: Double) -> Double {
        if x <= 0 { return 0 }
        if y == 1 { return x }
        return exp(y * log(x))
    }
}

/// Mask applied to an input's picture (0.51.0). The rectangle is in the picture's own 0...1
/// coordinates (origin top-left), so it follows the input into every layer and output.
public struct InputMask: Codable, Equatable, Sendable {
    public enum Shape: Int, Codable, Sendable, CaseIterable {
        case none = 0, rectangle = 1, ellipse = 2, imageLuma = 3, imageAlpha = 4
        public var title: String {
            switch self {
            case .none: return "None"
            case .rectangle: return "Rectangle / rounded"
            case .ellipse: return "Circle / ellipse"
            case .imageLuma: return "Image (white = visible)"
            case .imageAlpha: return "Image (transparency)"
            }
        }
    }
    public var shape: Shape = .none
    public var x: Double = 0.1, y: Double = 0.1, width: Double = 0.8, height: Double = 0.8
    /// Corner radius as a fraction of the shorter side (rectangle only), 0...0.5.
    public var radius: Double = 0
    /// Soft edge as a fraction of the shorter side, 0...0.25.
    public var feather: Double = 0
    public var invert = false
    /// PNG/JPEG for the image shapes, stretched over the picture.
    public var imagePath: String?

    public init() {}

    public var isActive: Bool {
        switch shape {
        case .none: return false
        case .imageLuma, .imageAlpha: return !(imagePath ?? "").isEmpty
        default: return true
        }
    }

    public var clamped: InputMask {
        var m = self
        m.x = min(max(x, -1), 1); m.y = min(max(y, -1), 1)
        m.width = min(max(width, 0.001), 2); m.height = min(max(height, 0.001), 2)
        m.radius = min(max(radius, 0), 0.5); m.feather = min(max(feather, 0), 0.25)
        return m
    }

    /// Reference of the shader's shape coverage (0 hidden ... 1 visible) at picture point u, v
    /// for a picture of aspect `aspect` (width / height). Image shapes are not covered here.
    public func coverage(u: Double, v: Double, aspect: Double = 16.0 / 9) -> Double {
        let m = clamped
        guard m.shape == .rectangle || m.shape == .ellipse else { return 1 }
        // Work in units of picture height so circles stay round.
        let px = u * aspect, py = v
        let hw = m.width * aspect / 2, hh = m.height / 2
        let cx = (m.x * aspect) + hw, cy = m.y + hh
        let rx = px - cx, ry = py - cy
        let short = min(hw, hh)
        let d: Double
        if m.shape == .ellipse {
            d = ((rx / hw) * (rx / hw) + (ry / hh) * (ry / hh)).squareRoot() * short - short
        } else {
            let r = min(m.radius * 2 * short, short)
            let qx = abs(rx) - (hw - r), qy = abs(ry) - (hh - r)
            let ox = max(qx, 0), oy = max(qy, 0)
            d = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
        }
        let f = max(m.feather * 2 * short, 0.001)
        let c = min(max(0.5 - d / f, 0), 1)
        return m.invert ? 1 - c : c
    }
}

/// Waving-flag warp (0.51.0): the left edge stays at the pole, waves run to the right.
public struct InputWave: Codable, Equatable, Sendable {
    public var enabled = false
    /// Height of the wave as a fraction of the picture height, 0...0.15.
    public var amplitude: Double = 0.05
    /// Waves across the picture, 0.5...4.
    public var frequency: Double = 1.5
    /// Cycles per second, 0.05...3.
    public var speed: Double = 0.8
    /// Light/shadow of the folds, 0...1.
    public var shading: Double = 0.5

    public init() {}

    public var clamped: InputWave {
        var w = self
        w.amplitude = min(max(amplitude, 0), 0.15); w.frequency = min(max(frequency, 0.5), 4)
        w.speed = min(max(speed, 0.05), 3); w.shading = min(max(shading, 0), 1)
        return w
    }
}

/// Looping picture animation of an input (0.62.0), next to the waving flag: the picture moves
/// inside its own frame (parts that move out are transparent), on every use of the input.
public struct InputMotion: Codable, Equatable, Sendable {
    public enum Kind: Int, Codable, CaseIterable, Sendable {
        case none = 0
        /// Grows and shrinks a little (breathing zoom).
        case pulse = 1
        /// Fades in and out.
        case breathe = 2
        /// Drifts up and down.
        case float = 3
        /// Small fast random shake (impact, earthquake).
        case shake = 4
        /// Swings like a hanging sign.
        case swing = 5
        /// Turns round and round.
        case spin = 6
        /// Slow zoom in and out (Ken Burns).
        case zoom = 7
        /// Water ripples from the centre.
        case ripple = 8
        /// Digital glitch: bands jump sideways now and then.
        case glitch = 9
        /// Double beat, like a heart.
        case heartbeat = 10
        /// Bounces on the floor.
        case bounce = 11
        /// Slides left and right.
        case sway = 12

        public var title: String {
            switch self {
            case .none: return "None"
            case .pulse: return "Pulse"
            case .breathe: return "Breathe (fade)"
            case .float: return "Float"
            case .shake: return "Shake"
            case .swing: return "Swing"
            case .spin: return "Spin"
            case .zoom: return "Slow zoom (Ken Burns)"
            case .ripple: return "Ripple"
            case .glitch: return "Glitch"
            case .heartbeat: return "Heartbeat"
            case .bounce: return "Bounce"
            case .sway: return "Sway"
            }
        }
    }

    public var kind: Kind = .none
    /// How strong, 0...1.
    public var amount: Double = 0.5
    /// Cycles per second, 0.05...4.
    public var speed: Double = 0.6

    public init(kind: Kind = .none, amount: Double = 0.5, speed: Double = 0.6) {
        self.kind = kind; self.amount = amount; self.speed = speed
    }

    public var isActive: Bool { kind != .none && amount > 0.001 }

    public var clamped: InputMotion {
        InputMotion(kind: kind, amount: min(max(amount, 0), 1), speed: min(max(speed, 0.05), 4))
    }

    /// Speed the picker starts with for each kind (what looks natural).
    public static func defaultSpeed(_ k: Kind) -> Double {
        switch k {
        case .shake: return 3
        case .glitch: return 1.5
        case .spin: return 0.15
        case .zoom: return 0.08
        case .heartbeat: return 1.1
        default: return 0.6
        }
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
