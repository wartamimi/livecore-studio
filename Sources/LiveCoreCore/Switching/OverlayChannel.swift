/// An overlay channel keys a source over the program output (titles, logos, lower thirds, PiP).
/// Overlays are composited after the program transition, so they stay on air across cuts.
public struct OverlayChannel: Equatable, Codable, Sendable {
    public var index: Int
    public var source: InputID?
    public var preset: LayoutPreset
    public var fadeDuration: Double
    /// How the overlay comes in and goes out over `fadeDuration` (since 0.20.0).
    public var animation: OverlayAnimation = .fade
    public private(set) var isOn: Bool = false
    /// Shown on Preview only (vMix "overlay to preview"); the next CUT/AUTO takes it to Program.
    /// Set with ``setPreview(_:now:)`` so it animates on Preview like it will on Program.
    public var onPreview: Bool = false
    // Preview animation state (0.45.0)
    private var previewStart: Double = -1e9
    private var previewFrom: Double = 0
    private var previewTarget: Double = 0
    // Fade state
    private var fadeStart: Double = 0
    private var fadeFrom: Double = 0
    private var target: Double = 0

    public init(index: Int, source: InputID? = nil, preset: LayoutPreset = .lowerThird, fadeDuration: Double = 0.5) {
        self.index = index; self.source = source; self.preset = preset; self.fadeDuration = fadeDuration
    }

    public mutating func set(on: Bool, now: Double) {
        guard on != isOn else { return }
        fadeFrom = opacity(at: now)
        fadeStart = now
        target = on ? 1 : 0
        isOn = on
    }

    public func opacity(at now: Double) -> Double {
        guard fadeDuration > 0 else { return target }
        let p = min(max((now - fadeStart) / fadeDuration, 0), 1)
        return fadeFrom + (target - fadeFrom) * p
    }

    /// Where and how opaque the overlay is drawn at `now`, for an overlay placed at `rect`.
    public func placement(_ rect: NormRect, at now: Double) -> (rect: NormRect, opacity: Double) {
        animation.placement(rect, progress: opacity(at: now))
    }

    /// Shows or hides the overlay on Preview with the same in / out animation as on Program.
    public mutating func setPreview(_ on: Bool, now: Double) {
        let from = previewProgress(at: now)
        onPreview = on
        guard on || from > 0 else { previewTarget = 0; return }
        previewFrom = from; previewStart = now; previewTarget = on ? 1 : 0
    }

    /// 0 = hidden on Preview, 1 = fully in.
    public func previewProgress(at now: Double) -> Double {
        if onPreview && previewTarget == 0 { return 1 }   // set directly, without an animation
        guard fadeDuration > 0 else { return previewTarget }
        let p = min(max((now - previewStart) / fadeDuration, 0), 1)
        return previewFrom + (previewTarget - previewFrom) * p
    }

    /// Where and how opaque the overlay is drawn on Preview at `now`.
    public func previewPlacement(_ rect: NormRect, at now: Double) -> (rect: NormRect, opacity: Double) {
        animation.placement(rect, progress: previewProgress(at: now))
    }

    public func isVisible(at now: Double) -> Bool { source != nil && opacity(at: now) > 0.001 }

    /// Moves an overlay that is waiting on Preview to Program (fading in). Returns true if it moved.
    @discardableResult
    public mutating func takeToProgram(now: Double) -> Bool {
        guard onPreview else { return false }
        onPreview = false; previewTarget = 0; previewFrom = 0
        guard source != nil else { return false }
        set(on: true, now: now)
        return true
    }
}

/// Overlay in / out animation (vMix-style). Progress 0 = hidden, 1 = fully in; going out plays
/// the same motion backwards (a slide from the left leaves to the left).
public enum OverlayAnimation: String, Codable, Sendable, CaseIterable {
    case fade
    case slideFromLeft, slideFromRight, slideFromBottom, slideFromTop
    case zoom
    /// Fully shown for the whole duration: the source animates itself (vMix GT titles, 0.41.0).
    case hold
    // 0.45.0
    /// Rises a short way while fading in (the common broadcast lower-third move).
    case riseFade
    /// Grows from 85 % with a small overshoot, fading in.
    case pop
    /// Shrinks from 115 % into place, fading in.
    case zoomOut
    /// Slides a short way in from the left while fading.
    case nudgeLeft
    /// Slides a short way in from the right while fading.
    case nudgeRight

    /// The motions an operator can pick (``hold`` is set by titles that animate themselves).
    public static var selectable: [OverlayAnimation] { allCases.filter { $0 != .hold } }

    public func placement(_ rect: NormRect, progress: Double) -> (rect: NormRect, opacity: Double) {
        let p = min(max(progress, 0), 1)
        if p >= 1 { return (rect, 1) }
        // Ease-in-out cubic: a soft start and a long, soft landing (closer to vMix than smoothstep).
        let q = -2 * p + 2
        let e = p < 0.5 ? 4 * p * p * p : 1 - q * q * q / 2
        // Ease-out cubic for the short moves.
        let o = 1 - (1 - p) * (1 - p) * (1 - p)
        var r = rect
        func scaled(_ s: Double) -> NormRect {
            var n = rect
            n.width = rect.width * s; n.height = rect.height * s
            n.x = rect.x + (rect.width - n.width) / 2; n.y = rect.y + (rect.height - n.height) / 2
            return n
        }
        switch self {
        case .fade:
            return (rect, p)
        case .hold:
            return (rect, p > 0 ? 1 : 0)
        case .slideFromLeft:
            r.x = rect.x - (rect.x + rect.width) * (1 - e)
        case .slideFromRight:
            r.x = rect.x + (1 - rect.x) * (1 - e)
        case .slideFromBottom:
            r.y = rect.y + (1 - rect.y) * (1 - e)
        case .slideFromTop:
            r.y = rect.y - (rect.y + rect.height) * (1 - e)
        case .zoom:
            let s = 0.6 + 0.4 * e
            r.width = rect.width * s; r.height = rect.height * s
            r.x = rect.x + (rect.width - r.width) / 2; r.y = rect.y + (rect.height - r.height) / 2
            return (r, e)
        case .riseFade:
            r.y = rect.y + 0.05 * (1 - o)
            return (r, o)
        case .pop:
            // Back ease-out: 0.85 → ~1.03 → 1.
            let c1 = 1.70158, c3 = c1 + 1
            let m = p - 1
            let b = 1 + c3 * m * m * m + c1 * m * m
            return (scaled(0.85 + 0.15 * b), min(1, p * 2.5))
        case .zoomOut:
            return (scaled(1.15 - 0.15 * o), o)
        case .nudgeLeft:
            r.x = rect.x - 0.08 * (1 - o)
            return (r, o)
        case .nudgeRight:
            r.x = rect.x + 0.08 * (1 - o)
            return (r, o)
        }
        // Slides stay opaque while moving; a short fade at the very start hides the first frame's edge.
        return (r, min(1, p * 8))
    }
}
