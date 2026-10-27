/// An overlay channel keys a source over the program output (titles, logos, lower thirds, PiP).
/// Overlays are composited after the program transition, so they stay on air across cuts.
public struct OverlayChannel: Equatable, Codable, Sendable {
    public var index: Int
    public var source: InputID?
    public var preset: LayoutPreset
    public var fadeDuration: Double
    public private(set) var isOn: Bool = false
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

    public func isVisible(at now: Double) -> Bool { source != nil && opacity(at: now) > 0.001 }
}
