/// Transitions that are actually implemented in the Metal shader (see LiveCoreEngine/Render/Shaders.swift).
/// The raw value is passed to the GPU, keep in sync with `transition_fragment` in the shader and
/// with `TransitionMath` below (the CPU reference used by the unit tests).
public enum TransitionKind: Int, Codable, Sendable, CaseIterable {
    case cut = 0
    case dissolve = 1     // linear cross-fade A -> B
    case fadeToBlack = 2  // A -> black -> B (dip to black)
    case wipeLeft = 3     // B revealed right-to-left with a soft edge
    case wipeRight = 4    // B revealed left-to-right
    case wipeUp = 5       // B revealed bottom-to-top
    case wipeDown = 6     // B revealed top-to-bottom
    case pushLeft = 7     // B pushes A out to the left
    case pushRight = 8    // B pushes A out to the right
    case slideLeft = 9    // B slides in from the right over a still A
    case slideRight = 10  // B slides in from the left over a still A
    case iris = 11        // B revealed by a growing circle from the centre
    /// A video clip (normally with alpha) plays over the program; A cuts to B at the clip's cut
    /// point, hidden behind the clip. Not a shader transition: see `FramePlanner` / `StingerParams`.
    case stinger = 12
    /// User-written Metal shader (`CustomTransitionSource`); which one is `ProductionSettings.customTransition`.
    case custom = 13

    public var displayName: String {
        switch self {
        case .cut: return "Cut"
        case .dissolve: return "Dissolve"
        case .fadeToBlack: return "Fade"
        case .wipeLeft: return "Wipe ←"
        case .wipeRight: return "Wipe →"
        case .wipeUp: return "Wipe ↑"
        case .wipeDown: return "Wipe ↓"
        case .pushLeft: return "Push ←"
        case .pushRight: return "Push →"
        case .slideLeft: return "Slide ←"
        case .slideRight: return "Slide →"
        case .iris: return "Iris"
        case .stinger: return "Stinger"
        case .custom: return "Custom"
        }
    }
}

/// CPU reference of the geometric transitions (what the shader samples at a pixel). Used by unit
/// tests to pin the shader's behaviour; the GPU does the real work.
public enum TransitionMath {
    public enum Sample: Equatable, Sendable {
        case a(u: Double, v: Double)
        case b(u: Double, v: Double)
        /// Blend of A and B at the same uv; `weightB` 0...1 (soft edges, dissolve).
        case mix(weightB: Double)
        case black
    }

    public static let softEdge = 0.02

    @inline(__always) static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Sample for normalized position (u, v) — (0,0) top-left — at progress t on a canvas of
    /// `aspect` (width/height).
    public static func sample(_ kind: TransitionKind, t rawT: Double, u: Double, v: Double, aspect: Double = 16.0 / 9.0) -> Sample {
        let t = min(max(rawT, 0), 1)
        func wipe(_ coord: Double) -> Sample {
            // B appears where coord > edge; edge sweeps 1+soft -> -soft.
            let edge = (1 + softEdge) + (-softEdge - (1 + softEdge)) * t
            let m = smoothstep(edge - softEdge, edge + softEdge, coord)
            return m <= 0 ? .a(u: u, v: v) : (m >= 1 ? .b(u: u, v: v) : .mix(weightB: m))
        }
        switch kind {
        case .cut: return t < 1 ? .a(u: u, v: v) : .b(u: u, v: v)
        case .stinger: return t < 0.5 ? .a(u: u, v: v) : .b(u: u, v: v)   // real cut point: StingerParams
        // Custom shaders run only on the GPU; the CPU reference treats them as a dissolve.
        case .dissolve, .custom: return t <= 0 ? .a(u: u, v: v) : (t >= 1 ? .b(u: u, v: v) : .mix(weightB: t))
        case .fadeToBlack:
            if t == 0.5 { return .black }
            return t < 0.5 ? .a(u: u, v: v) : .b(u: u, v: v)
        case .wipeLeft: return wipe(u)
        case .wipeRight: return wipe(1 - u)
        case .wipeUp: return wipe(v)
        case .wipeDown: return wipe(1 - v)
        case .pushLeft: return u < 1 - t ? .a(u: u + t, v: v) : .b(u: u - (1 - t), v: v)
        case .pushRight: return u >= t ? .a(u: u - t, v: v) : .b(u: u + (1 - t), v: v)
        case .slideLeft: return u >= 1 - t ? .b(u: u - (1 - t), v: v) : .a(u: u, v: v)
        case .slideRight: return u < t ? .b(u: u + (1 - t), v: v) : .a(u: u, v: v)
        case .iris:
            let dx = (u - 0.5) * aspect, dy = v - 0.5
            let d = (dx * dx + dy * dy).squareRoot()
            let maxR = (aspect * aspect / 4 + 0.25).squareRoot() + softEdge
            let r = t * maxR
            let m = 1 - smoothstep(r - softEdge, r, d)
            if t >= 1 { return .b(u: u, v: v) }
            return m <= 0 ? .a(u: u, v: v) : (m >= 1 ? .b(u: u, v: v) : .mix(weightB: m))
        }
    }
}

/// A transition in progress from the current program input (`from`) to the preview input (`to`).
public struct ActiveTransition: Equatable, Sendable {
    public var kind: TransitionKind
    public var from: InputID?
    public var to: InputID?
    public var startTime: Double
    public var duration: Double
    /// Non-nil while the operator drives the transition manually (T-bar).
    public var manualPosition: Double?
    /// Set for `.stinger` transitions.
    public var stinger: StingerParams? = nil

    public func progress(at now: Double) -> Double {
        if let manual = manualPosition { return min(max(manual, 0), 1) }
        guard duration > 0 else { return 1 }
        return min(max((now - startTime) / duration, 0), 1)
    }
}
