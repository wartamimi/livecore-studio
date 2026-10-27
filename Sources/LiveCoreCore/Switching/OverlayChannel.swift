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
    public var onPreview: Bool = false
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

    public func isVisible(at now: Double) -> Bool { source != nil && opacity(at: now) > 0.001 }

    /// Moves an overlay that is waiting on Preview to Program (fading in). Returns true if it moved.
    @discardableResult
    public mutating func takeToProgram(now: Double) -> Bool {
        guard onPreview else { return false }
        onPreview = false
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

    public func placement(_ rect: NormRect, progress: Double) -> (rect: NormRect, opacity: Double) {
        let p = min(max(progress, 0), 1)
        let e = p * p * (3 - 2 * p)   // smoothstep: eases in and out
        var r = rect
        switch self {
        case .fade:
            return (rect, p)
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
        }
        // Slides stay opaque while moving; a short fade at the very start hides the first frame's edge.
        return (r, min(1, p * 8))
    }
}
