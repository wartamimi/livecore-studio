/// Converts switcher + overlay state into a per-frame drawing plan for the compositor.
/// Pure function of its inputs, so it is unit-tested on any platform.
public struct DrawCommand: Equatable, Sendable {
    public var source: InputID
    public var rect: NormRect
    public var scaleMode: ScaleMode
    public var opacity: Double
}

public struct TransitionPlan: Equatable, Sendable {
    public var kind: TransitionKind
    public var progress: Double
    /// Composition of the incoming input (B). The outgoing input (A) is `FramePlan.program`.
    public var incoming: [DrawCommand]
}

public struct FramePlan: Equatable, Sendable {
    public var program: [DrawCommand]          // empty = black
    public var transition: TransitionPlan?
    public var overlays: [DrawCommand]
    public var preview: [DrawCommand]
    public var programInput: InputID?
    public var previewInput: InputID?
}

public enum FramePlanner {
    /// - Parameter layersFor: returns the scene layers of an input (the input itself first, plus any
    ///   layers the operator added). Return nil if the input no longer exists.
    public static func plan(snapshot: SwitcherSnapshot,
                            overlays: [OverlayChannel],
                            now: Double,
                            layersFor: (InputID) -> [Layer]?) -> FramePlan {
        func composition(_ id: InputID?) -> [DrawCommand] {
            guard let id, let layers = layersFor(id) else { return [] }
            return layers.compactMap { l in
                // Guard against a scene layer that points at a removed input.
                guard l.source == id || layersFor(l.source) != nil else { return nil }
                return DrawCommand(source: l.source, rect: l.rect, scaleMode: l.scaleMode, opacity: l.opacity)
            }
        }

        var plan = FramePlan(program: [], transition: nil, overlays: [], preview: [],
                             programInput: snapshot.program, previewInput: snapshot.preview)
        if let t = snapshot.transition {
            plan.program = composition(t.from)
            plan.transition = TransitionPlan(kind: t.kind, progress: t.progress(at: now), incoming: composition(t.to))
            plan.programInput = t.from
        } else {
            plan.program = composition(snapshot.program)
        }
        plan.preview = composition(snapshot.preview)
        for ch in overlays.sorted(by: { $0.index < $1.index }) {
            guard let src = ch.source, layersFor(src) != nil else { continue }
            let a = ch.opacity(at: now)
            guard a > 0.001 else { continue }
            plan.overlays.append(DrawCommand(source: src, rect: ch.preset.rect, scaleMode: ch.preset == .fullScreen || ch.preset == .lowerThird ? .fit : .fill, opacity: a))
        }
        return plan
    }
}
