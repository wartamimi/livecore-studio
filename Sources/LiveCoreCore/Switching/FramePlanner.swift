/// Converts switcher + overlay state into a per-frame drawing plan for the compositor.
/// Pure function of its inputs, so it is unit-tested on any platform.
public struct DrawCommand: Equatable, Sendable {
    public var source: InputID
    public var rect: NormRect
    public var scaleMode: ScaleMode
    public var opacity: Double
    /// Enabled chroma key of the source, nil when the source is drawn unkeyed.
    public var key: ChromaKey?
    /// The source has straight (non-premultiplied) alpha; the compositor premultiplies it.
    public var premultiply: Bool
    /// Crop / mask / border of a scene layer (clamped); nil = plain.
    public var style: LayerStyle?
    public init(source: InputID, rect: NormRect, scaleMode: ScaleMode, opacity: Double, key: ChromaKey? = nil,
                premultiply: Bool = false, style: LayerStyle? = nil) {
        self.source = source; self.rect = rect; self.scaleMode = scaleMode; self.opacity = opacity; self.key = key
        self.premultiply = premultiply; self.style = style
    }
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
    /// Stinger clip drawn full screen on top of program and overlays while a stinger runs.
    public var stinger: DrawCommand? = nil
    /// Input thumbnails on a transparent background: the source itself, or its whole scene for the
    /// inputs in `composedThumbnails` (scene inputs, whose own picture is empty).
    public var thumbnails: [InputID: [DrawCommand]] = [:]
    /// Full-size view of one input (the per-input fullscreen viewer), nil when none is open.
    public var detail: [DrawCommand]? = nil
}

public enum FramePlanner {
    /// - Parameter layersFor: returns the scene layers of an input (the input itself first, plus any
    ///   layers the operator added). Return nil if the input no longer exists.
    /// - Parameter keyFor: the chroma key configured on a source (only enabled keys are applied).
    public static func plan(snapshot: SwitcherSnapshot,
                            overlays: [OverlayChannel],
                            now: Double,
                            layersFor: (InputID) -> [Layer]?,
                            keyFor: (InputID) -> ChromaKey? = { _ in nil },
                            thumbnailsFor: [InputID] = [],
                            composedThumbnails: Set<InputID> = [],
                            detailInput: InputID? = nil) -> FramePlan {
        func key(_ id: InputID) -> ChromaKey? {
            guard let k = keyFor(id), k.enabled else { return nil }
            return k.clamped
        }
        func composition(_ id: InputID?) -> [DrawCommand] {
            guard let id, let layers = layersFor(id) else { return [] }
            return layers.compactMap { l in
                // Guard against a scene layer that points at a removed input.
                guard l.source == id || layersFor(l.source) != nil else { return nil }
                return DrawCommand(source: l.source, rect: l.rect, scaleMode: l.scaleMode, opacity: l.opacity, key: key(l.source),
                                   style: l.style?.clamped)
            }
        }

        var plan = FramePlan(program: [], transition: nil, overlays: [], preview: [],
                             programInput: snapshot.program, previewInput: snapshot.preview)
        if let t = snapshot.transition, t.kind == .stinger, let s = t.stinger {
            // Hard cut at the cut point, hidden behind the clip.
            let past = t.progress(at: now) >= s.cutFraction
            plan.program = composition(past ? t.to : t.from)
            plan.programInput = past ? t.to : t.from
            if layersFor(s.source) != nil {
                plan.stinger = DrawCommand(source: s.source, rect: .full, scaleMode: .fit, opacity: 1)
            }
        } else if let t = snapshot.transition {
            plan.program = composition(t.from)
            plan.transition = TransitionPlan(kind: t.kind, progress: t.progress(at: now), incoming: composition(t.to))
            plan.programInput = t.from
        } else {
            plan.program = composition(snapshot.program)
        }
        plan.preview = composition(snapshot.preview)
        // Overlays waiting on Preview are drawn over the preview picture at full opacity.
        for ch in overlays.sorted(by: { $0.index < $1.index }) where ch.onPreview {
            guard let src = ch.source, layersFor(src) != nil else { continue }
            plan.preview.append(DrawCommand(source: src, rect: ch.preset.rect,
                                            scaleMode: ch.preset == .fullScreen || ch.preset == .lowerThird ? .fit : .fill,
                                            opacity: 1, key: key(src)))
        }
        for ch in overlays.sorted(by: { $0.index < $1.index }) {
            guard let src = ch.source, layersFor(src) != nil else { continue }
            let a = ch.opacity(at: now)
            guard a > 0.001 else { continue }
            plan.overlays.append(DrawCommand(source: src, rect: ch.preset.rect, scaleMode: ch.preset == .fullScreen || ch.preset == .lowerThird ? .fit : .fill,
                                             opacity: a, key: key(src)))
        }
        for id in thumbnailsFor where layersFor(id) != nil {
            if composedThumbnails.contains(id) {
                let c = composition(id)
                if !c.isEmpty { plan.thumbnails[id] = c }
            } else {
                plan.thumbnails[id] = [DrawCommand(source: id, rect: .full, scaleMode: .fit, opacity: 1, key: key(id))]
            }
        }
        if let d = detailInput, layersFor(d) != nil { plan.detail = composition(d) }
        return plan
    }
}
