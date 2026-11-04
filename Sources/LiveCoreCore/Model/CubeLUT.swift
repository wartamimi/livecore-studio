import Foundation

/// A 3D colour look-up table in the Adobe / Resolve `.cube` format (0.48.0).
/// `values` holds `size³` RGB triplets, red changing fastest (the .cube order).
public struct CubeLUT: Equatable, Sendable {
    public var title: String
    public var size: Int
    public var values: [Float]

    public static let sizes = [17, 33, 65]

    public init(title: String = "", size: Int, values: [Float]) {
        self.title = title; self.size = size; self.values = values
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingSize, badSize(Int), badLine(Int), wrongCount(expected: Int, found: Int), only1D
        public var description: String {
            switch self {
            case .missingSize: return "LUT_3D_SIZE is missing"
            case let .badSize(n): return "Unsupported LUT size \(n) (2–128)"
            case let .badLine(n): return "Unreadable line \(n)"
            case let .wrongCount(e, f): return "Expected \(e) colour lines, found \(f)"
            case .only1D: return "1D LUTs are not supported, use a 3D .cube"
            }
        }
    }

    /// Reads a .cube file's text. DOMAIN_MIN / DOMAIN_MAX are applied (values rescaled to 0...1).
    public static func parse(_ text: String) throws -> CubeLUT {
        var title = "", size = 0
        var dMin: [Float] = [0, 0, 0], dMax: [Float] = [1, 1, 1]
        var values: [Float] = []
        var lineNo = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            switch head.uppercased() {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard parts.count > 1, let n = Int(parts[1]) else { throw ParseError.badLine(lineNo) }
                guard (2...128).contains(n) else { throw ParseError.badSize(n) }
                size = n
                values.reserveCapacity(n * n * n * 3)
            case "LUT_1D_SIZE":
                throw ParseError.only1D
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 3 else { throw ParseError.badLine(lineNo) }
                if head.uppercased() == "DOMAIN_MIN" { dMin = v } else { dMax = v }
            case "LUT_3D_INPUT_RANGE", "LUT_IN_VIDEO_RANGE", "LUT_OUT_VIDEO_RANGE":
                continue
            default:
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                    // Unknown keywords (vendor extensions) are skipped; numbers that do not parse are errors.
                    if head.first?.isLetter == true { continue }
                    throw ParseError.badLine(lineNo)
                }
                values += [r, g, b]
            }
        }
        guard size > 0 else { throw ParseError.missingSize }
        let expected = size * size * size * 3
        guard values.count == expected else { throw ParseError.wrongCount(expected: expected / 3, found: values.count / 3) }
        if dMin != [0, 0, 0] || dMax != [1, 1, 1] {
            for i in stride(from: 0, to: values.count, by: 3) {
                for c in 0..<3 where dMax[c] > dMin[c] { values[i + c] = (values[i + c] - dMin[c]) / (dMax[c] - dMin[c]) }
            }
        }
        return CubeLUT(title: title, size: size, values: values)
    }

    /// The .cube text (6 decimals, red fastest).
    public func cubeText(comment: String? = nil) -> String {
        var out = ""
        out.reserveCapacity(values.count * 9 + 200)
        if let comment { for l in comment.split(separator: "\n") { out += "# \(l)\n" } }
        if !title.isEmpty { out += "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\n" }
        out += "LUT_3D_SIZE \(size)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
        for i in stride(from: 0, to: values.count, by: 3) {
            out += String(format: "%.6f %.6f %.6f\n", values[i], values[i + 1], values[i + 2])
        }
        return out
    }

    /// A LUT that changes nothing.
    public static func identity(size: Int = 2) -> CubeLUT {
        build(title: "Identity", size: size) { $0 }
    }

    /// Samples `f` on the lattice (red fastest).
    public static func build(title: String, size: Int, _ f: (RGB) -> RGB) -> CubeLUT {
        let n = max(size, 2)
        var v: [Float] = []
        v.reserveCapacity(n * n * n * 3)
        let s = 1 / Double(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let o = f(RGB(Double(r) * s, Double(g) * s, Double(b) * s)).clamped
            v += [Float(o.r), Float(o.g), Float(o.b)]
        } } }
        return CubeLUT(title: title, size: n, values: v)
    }

    /// Trilinear lookup (the GPU's 3D texture filter does the same).
    public func sample(_ c: RGB) -> RGB {
        let n = size, m = Double(n - 1)
        func split(_ x: Double) -> (Int, Int, Double) {
            let p = min(max(x, 0), 1) * m
            let i = min(Int(p), n - 2)
            return (i, i + 1, p - Double(i))
        }
        let (r0, r1, fr) = split(c.r), (g0, g1, fg) = split(c.g), (b0, b1, fb) = split(c.b)
        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB {
            let i = ((b * n + g) * n + r) * 3
            return RGB(Double(values[i]), Double(values[i + 1]), Double(values[i + 2]))
        }
        func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t) }
        let c00 = mix(at(r0, g0, b0), at(r1, g0, b0), fr), c10 = mix(at(r0, g1, b0), at(r1, g1, b0), fr)
        let c01 = mix(at(r0, g0, b1), at(r1, g0, b1), fr), c11 = mix(at(r0, g1, b1), at(r1, g1, b1), fr)
        return mix(mix(c00, c10, fg), mix(c01, c11, fg), fb)
    }

    /// RGBA float data for a 3D texture (alpha 1), same lattice order.
    public var rgbaValues: [Float] {
        var out = [Float](repeating: 1, count: size * size * size * 4)
        for i in 0..<(size * size * size) {
            out[i * 4] = values[i * 3]; out[i * 4 + 1] = values[i * 3 + 1]; out[i * 4 + 2] = values[i * 3 + 2]
        }
        return out
    }
}

public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public var clamped: RGB { RGB(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1)) }
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// Parameters of the LUT generator (0.48.0). Works on Rec. 709 display values (what cameras and
/// capture cards deliver); exposure and white balance are done on linearised light.
public struct LUTLook: Codable, Equatable, Sendable {
    /// Stops, -2...2.
    public var exposure: Double = 0
    /// -1 (cool / blue) ... 1 (warm / amber).
    public var temperature: Double = 0
    /// -1 (green) ... 1 (magenta).
    public var tint: Double = 0
    /// Film-style S-curve around mid grey, 0.5...2 (1 = none).
    public var contrast: Double = 1
    /// ASC-CDL style: lift (offset) -0.2...0.2, gamma (power) 0.5...2, gain (slope) 0.5...1.5.
    public var lift: Double = 0
    public var gamma: Double = 1
    public var gain: Double = 1
    /// 0 = black and white, 1 = unchanged, 2 = double.
    public var saturation: Double = 1
    /// Boosts muted colours more than strong ones (skin stays natural), -1...1.
    public var vibrance: Double = 0
    /// Raised, milky blacks (matte film), 0...0.3.
    public var fade: Double = 0
    /// Soft roll-off of bright highlights, 0...1.
    public var highlightRolloff: Double = 0
    /// Split toning: hue in degrees and strength 0...1 for shadows and highlights.
    public var shadowHue: Double = 200
    public var shadowAmount: Double = 0
    public var highlightHue: Double = 35
    public var highlightAmount: Double = 0
    /// Black and white (toning still applies, e.g. sepia).
    public var monochrome = false

    public init() {}

    public var isIdentity: Bool { self == LUTLook() }

    /// The colour of one pixel through the look.
    public func apply(_ input: RGB) -> RGB {
        var c = input.clamped
        // Linear light for exposure and white balance.
        if exposure != 0 || temperature != 0 || tint != 0 {
            var l = RGB(Self.toLinear(c.r), Self.toLinear(c.g), Self.toLinear(c.b))
            let e = Foundation.pow(2, exposure)
            let t = temperature * 0.18, ti = tint * 0.12
            l = RGB(l.r * e * (1 + t) * (1 + ti * 0.5), l.g * e * (1 - ti), l.b * e * (1 - t) * (1 + ti * 0.5))
            c = RGB(Self.toDisplay(l.r), Self.toDisplay(l.g), Self.toDisplay(l.b))
        }
        // Lift / gamma / gain (CDL: out = (in * slope + offset) ^ power).
        if lift != 0 || gamma != 1 || gain != 1 {
            func cdl(_ v: Double) -> Double { Foundation.pow(max(v * gain + lift, 0), 1 / max(gamma, 0.05)) }
            c = RGB(cdl(c.r), cdl(c.g), cdl(c.b))
        }
        if contrast != 1 {
            func s(_ v: Double) -> Double { Self.sCurve(min(max(v, 0), 1), contrast) }
            c = RGB(s(c.r), s(c.g), s(c.b))
        }
        if highlightRolloff > 0 {
            let knee = 1 - 0.35 * highlightRolloff
            func roll(_ v: Double) -> Double {
                guard v > knee else { return v }
                let room = 1 - knee
                let x = (v - knee) / room
                // Shoulder: slope 1 at the knee, flattening towards white (white stays white).
                let k = 0.9 * highlightRolloff
                return knee + room * (x + k * x * x * (1 - x))
            }
            c = RGB(roll(c.r), roll(c.g), roll(c.b))
        }
        let y = c.luma
        if monochrome {
            c = RGB(y, y, y)
        } else if saturation != 1 || vibrance != 0 {
            let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            let k = max(0, saturation * (1 + vibrance * (1 - sat)))
            c = RGB(y + (c.r - y) * k, y + (c.g - y) * k, y + (c.b - y) * k)
        }
        if shadowAmount > 0 || highlightAmount > 0 {
            let w = min(max(y, 0), 1)
            let sh = Self.hueColor(shadowHue), hi = Self.hueColor(highlightHue)
            let ws = shadowAmount * 0.25 * (1 - w) * (1 - w), wh = highlightAmount * 0.25 * w * w
            c = RGB(c.r + (sh.r - 0.5) * ws + (hi.r - 0.5) * wh,
                    c.g + (sh.g - 0.5) * ws + (hi.g - 0.5) * wh,
                    c.b + (sh.b - 0.5) * ws + (hi.b - 0.5) * wh)
        }
        if fade > 0 {
            c = RGB(fade + c.r * (1 - fade), fade + c.g * (1 - fade), fade + c.b * (1 - fade))
        }
        return c.clamped
    }

    public func makeLUT(title: String, size: Int = 33) -> CubeLUT {
        CubeLUT.build(title: title, size: size) { apply($0) }
    }

    /// Contrast S-curve with fixed black, white and mid grey (0.5).
    static func sCurve(_ x: Double, _ k: Double) -> Double {
        guard k != 1 else { return x }
        let a = Foundation.pow(x, k), b = Foundation.pow(1 - x, k)
        return a + b > 0 ? a / (a + b) : x
    }

    /// Rec. 709 / sRGB-like transfer (2.4 power with a linear toe).
    static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : Foundation.pow((v + 0.055) / 1.055, 2.4) }
    static func toDisplay(_ v: Double) -> Double {
        let x = max(v, 0)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * Foundation.pow(x, 1 / 2.4) - 0.055
    }

    /// Fully saturated colour of a hue (degrees), 0...1.
    static func hueColor(_ deg: Double) -> RGB {
        let h = (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return RGB(1, x, 0)
        case 1: return RGB(x, 1, 0)
        case 2: return RGB(0, 1, x)
        case 3: return RGB(0, x, 1)
        case 4: return RGB(x, 0, 1)
        default: return RGB(1, 0, x)
        }
    }
}

/// Starting points for the generator, tuned for events, weddings and talk shows.
public struct LUTPreset: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let look: LUTLook

    public static let all: [LUTPreset] = {
        func p(_ id: String, _ name: String, _ f: (inout LUTLook) -> Void) -> LUTPreset {
            var l = LUTLook(); f(&l); return LUTPreset(id: id, name: name, look: l)
        }
        return [
            p("neutral", "Neutral") { _ in },
            p("rec709_punch", "Rec.709 Punch") { $0.contrast = 1.18; $0.vibrance = 0.25; $0.highlightRolloff = 0.3 },
            p("warm_wedding", "Warm Wedding") { $0.temperature = 0.35; $0.contrast = 1.08; $0.vibrance = 0.15; $0.fade = 0.03; $0.highlightHue = 40; $0.highlightAmount = 0.35; $0.highlightRolloff = 0.5 },
            p("soft_pastel", "Soft Pastel") { $0.contrast = 0.85; $0.saturation = 0.85; $0.fade = 0.08; $0.lift = 0.02; $0.highlightHue = 330; $0.highlightAmount = 0.2; $0.highlightRolloff = 0.6 },
            p("teal_orange", "Teal & Orange") { $0.contrast = 1.15; $0.shadowHue = 190; $0.shadowAmount = 0.8; $0.highlightHue = 30; $0.highlightAmount = 0.6; $0.vibrance = 0.1; $0.highlightRolloff = 0.4 },
            p("cinematic", "Cinematic Film") { $0.contrast = 1.25; $0.saturation = 0.9; $0.fade = 0.04; $0.shadowHue = 200; $0.shadowAmount = 0.45; $0.highlightHue = 40; $0.highlightAmount = 0.3; $0.highlightRolloff = 0.7 },
            p("warm_film", "Warm Film Print") { $0.temperature = 0.2; $0.contrast = 1.12; $0.saturation = 0.92; $0.fade = 0.05; $0.shadowHue = 20; $0.shadowAmount = 0.25; $0.highlightRolloff = 0.6 },
            p("bleach_bypass", "Bleach Bypass") { $0.contrast = 1.35; $0.saturation = 0.45; $0.highlightRolloff = 0.2 },
            p("vintage_fade", "Vintage Fade") { $0.contrast = 0.9; $0.saturation = 0.75; $0.fade = 0.12; $0.temperature = 0.15; $0.shadowHue = 160; $0.shadowAmount = 0.35; $0.highlightHue = 45; $0.highlightAmount = 0.4 },
            p("cool_night", "Cool Night") { $0.temperature = -0.4; $0.exposure = -0.2; $0.contrast = 1.12; $0.saturation = 0.85; $0.shadowHue = 220; $0.shadowAmount = 0.5 },
            p("moody_green", "Moody Green") { $0.tint = -0.15; $0.contrast = 1.2; $0.saturation = 0.8; $0.shadowHue = 150; $0.shadowAmount = 0.5; $0.fade = 0.03 },
            p("bright_clean", "Bright & Clean") { $0.exposure = 0.25; $0.contrast = 1.05; $0.vibrance = 0.2; $0.highlightRolloff = 0.6 },
            p("bw_classic", "B&W Classic") { $0.monochrome = true; $0.contrast = 1.15; $0.highlightRolloff = 0.4 },
            p("bw_contrast", "B&W High Contrast") { $0.monochrome = true; $0.contrast = 1.5 },
            p("sepia", "Sepia") { $0.monochrome = true; $0.contrast = 1.05; $0.fade = 0.04; $0.shadowHue = 30; $0.shadowAmount = 0.6; $0.highlightHue = 40; $0.highlightAmount = 0.5 },
        ]
    }()
}
