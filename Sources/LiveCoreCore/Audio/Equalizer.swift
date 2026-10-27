#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Second-order IIR section (Transposed Direct Form II), stereo state.
/// Coefficients follow the RBJ "Audio EQ Cookbook" formulas (public-domain reference maths).
public struct Biquad: Sendable {
    public enum Kind: Sendable, Equatable { case highPass, lowShelf, peaking, highShelf }
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var zL1: Float = 0, zL2: Float = 0, zR1: Float = 0, zR2: Float = 0

    public init() {}

    public mutating func configure(_ kind: Kind, frequency: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let f = min(max(frequency, 10), sampleRate * 0.45)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 0.1))
        let A = pow(10, gainDB / 40)
        var nb0 = 1.0, nb1 = 0.0, nb2 = 0.0, na0 = 1.0, na1 = 0.0, na2 = 0.0
        switch kind {
        case .highPass:
            nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = (1 + cw) / 2
            na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .peaking:
            nb0 = 1 + alpha * A; nb1 = -2 * cw; nb2 = 1 - alpha * A
            na0 = 1 + alpha / A; na1 = -2 * cw; na2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * A.squareRoot() * alpha
            nb0 = A * ((A + 1) - (A - 1) * cw + s); nb1 = 2 * A * ((A - 1) - (A + 1) * cw); nb2 = A * ((A + 1) - (A - 1) * cw - s)
            na0 = (A + 1) + (A - 1) * cw + s; na1 = -2 * ((A - 1) + (A + 1) * cw); na2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * A.squareRoot() * alpha
            nb0 = A * ((A + 1) + (A - 1) * cw + s); nb1 = -2 * A * ((A - 1) + (A + 1) * cw); nb2 = A * ((A + 1) + (A - 1) * cw - s)
            na0 = (A + 1) - (A - 1) * cw + s; na1 = 2 * ((A - 1) - (A + 1) * cw); na2 = (A + 1) - (A - 1) * cw - s
        }
        b0 = Float(nb0 / na0); b1 = Float(nb1 / na0); b2 = Float(nb2 / na0)
        a1 = Float(na1 / na0); a2 = Float(na2 / na0)
    }

    public mutating func reset() { zL1 = 0; zL2 = 0; zR1 = 0; zR2 = 0 }

    public mutating func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        for i in 0..<frames {
            let x = left[i]
            let y = b0 * x + zL1
            zL1 = b1 * x - a1 * y + zL2
            zL2 = b2 * x - a2 * y
            left[i] = y
        }
        guard let right else { return }
        for i in 0..<frames {
            let x = right[i]
            let y = b0 * x + zR1
            zR1 = b1 * x - a1 * y + zR2
            zR2 = b2 * x - a2 * y
            right[i] = y
        }
    }

    /// Magnitude response in dB at `frequency` (used by tests and could drive a UI curve).
    public func responseDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // H(e^jw) = (b0 + b1 e^-jw + b2 e^-2jw) / (1 + a1 e^-jw + a2 e^-2jw)
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        let num = mag(Double(b0), Double(b1), Double(b2))
        let den = mag(1, Double(a1), Double(a2))
        return 20 * log10(max(num / den, 1e-12))
    }
}

/// Channel EQ: optional high-pass (rumble/handling noise) + low shelf, mid peak, high shelf.
/// Parameters are compared each block and coefficients recomputed only on change.
public struct ChannelEQ: Sendable {
    public struct Params: Equatable, Sendable {
        public var highPassEnabled = false
        public var highPassHz: Double = 80
        public var eqEnabled = false
        public var lowGainDB: Double = 0       // shelf at 120 Hz
        public var midGainDB: Double = 0       // peak, Q 0.9
        public var midHz: Double = 1_000
        public var highGainDB: Double = 0      // shelf at 8 kHz
        public init() {}
    }
    public private(set) var params: Params
    public let sampleRate: Double
    private var hpf = Biquad(), low = Biquad(), mid = Biquad(), high = Biquad()

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        params = Params()
        configure(force: true, Params())
    }

    public mutating func update(_ p: Params) { if p != params { configure(force: false, p) } }

    private mutating func configure(force: Bool, _ p: Params) {
        let old = params
        if force || p.highPassHz != old.highPassHz { hpf.configure(.highPass, frequency: p.highPassHz, gainDB: 0, q: 0.707, sampleRate: sampleRate) }
        if force || p.lowGainDB != old.lowGainDB { low.configure(.lowShelf, frequency: 120, gainDB: p.lowGainDB, q: 0.707, sampleRate: sampleRate) }
        if force || p.midGainDB != old.midGainDB || p.midHz != old.midHz {
            mid.configure(.peaking, frequency: p.midHz, gainDB: p.midGainDB, q: 0.9, sampleRate: sampleRate)
        }
        if force || p.highGainDB != old.highGainDB { high.configure(.highShelf, frequency: 8_000, gainDB: p.highGainDB, q: 0.707, sampleRate: sampleRate) }
        if p.highPassEnabled && !old.highPassEnabled { hpf.reset() }
        if p.eqEnabled && !old.eqEnabled { low.reset(); mid.reset(); high.reset() }
        params = p
    }

    public mutating func processHighPass(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if params.highPassEnabled { hpf.process(left: left, right: right, frames: frames) }
    }

    public mutating func processEQ(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        guard params.eqEnabled else { return }
        if params.lowGainDB != 0 { low.process(left: left, right: right, frames: frames) }
        if params.midGainDB != 0 { mid.process(left: left, right: right, frames: frames) }
        if params.highGainDB != 0 { high.process(left: left, right: right, frames: frames) }
    }

    /// Total response of the enabled stages in dB.
    public func responseDB(at f: Double) -> Double {
        var db = 0.0
        if params.highPassEnabled { db += hpf.responseDB(at: f, sampleRate: sampleRate) }
        if params.eqEnabled {
            if params.lowGainDB != 0 { db += low.responseDB(at: f, sampleRate: sampleRate) }
            if params.midGainDB != 0 { db += mid.responseDB(at: f, sampleRate: sampleRate) }
            if params.highGainDB != 0 { db += high.responseDB(at: f, sampleRate: sampleRate) }
        }
        return db
    }
}
