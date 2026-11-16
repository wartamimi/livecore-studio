/// Mix input (0.79.0): a second Preview/Program switcher whose Program is the input's picture.
/// Like any input it can go to an extra output (window, display, NDI), be recorded on its own
/// (MultiCorder) or be used inside the main mix. It cuts or fades (cross-dissolve).
public struct ProjectMix: Codable, Equatable, Sendable {
    public var preview: InputID?
    public var program: InputID?
    /// Fade length in seconds.
    public var duration: Double
    public init(preview: InputID? = nil, program: InputID? = nil, duration: Double = 0.5) {
        self.preview = preview; self.program = program; self.duration = duration
    }
}

public final class MixBus {
    public let switcher = Switcher()
    public var duration: Double

    public init(_ p: ProjectMix = ProjectMix()) {
        duration = p.duration
        switcher.setPreview(p.program)
        switcher.cut()
        switcher.setPreview(p.preview)
    }

    public var project: ProjectMix {
        ProjectMix(preview: switcher.state.preview, program: switcher.state.program, duration: duration)
    }

    public func fade(now: Double) { switcher.auto(kind: .dissolve, duration: min(max(duration, 0.1), 5), now: now) }
}

extension SwitcherSnapshot {
    /// The mix's picture as layers: Program, or during a fade the outgoing input under the
    /// incoming one at the fade's progress.
    public func mixLayers(now: Double) -> [(source: InputID, opacity: Double)] {
        guard let t = transition else { return program.map { [($0, 1)] } ?? [] }
        let p = t.progress(at: now)
        return (t.from.map { [($0, 1)] } ?? []) + (t.to.map { [($0, p)] } ?? [])
    }
}
