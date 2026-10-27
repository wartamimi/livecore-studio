/// Transitions that are actually implemented in the Metal shader (see LiveCoreEngine/Render/Shaders.swift).
/// The raw value is passed to the GPU, keep in sync with `transitionKind` in the shader.
public enum TransitionKind: Int, Codable, Sendable, CaseIterable {
    case cut = 0
    case dissolve = 1     // linear cross-fade A -> B
    case fadeToBlack = 2  // A -> black -> B (dip to black)
    case wipeLeft = 3     // B revealed right-to-left with a soft edge

    public var displayName: String {
        switch self {
        case .cut: return "Cut"
        case .dissolve: return "Dissolve"
        case .fadeToBlack: return "Fade"
        case .wipeLeft: return "Wipe"
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

    public func progress(at now: Double) -> Double {
        if let manual = manualPosition { return min(max(manual, 0), 1) }
        guard duration > 0 else { return 1 }
        return min(max((now - startTime) / duration, 0), 1)
    }
}
