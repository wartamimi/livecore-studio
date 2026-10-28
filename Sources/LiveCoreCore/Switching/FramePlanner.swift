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

/// One flattened input (Layer.flatten): its layers drawn into one full-size transparent image,
/// which then stands in for the input's own picture for the rest of the frame.
public struct FlattenPass: Equatable, Sendable {
    public var input: InputID
    public var layers: [DrawCommand]
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
    /// Full-size, opaque pictures of single inputs for the extra outputs.
    public var extra: [InputID: [DrawCommand]] = [:]
    /// Preview at full output size, for an extra output that shows Preview (nil when none does).
    public var fullPreview: [DrawCommand]? = nil
    /// Flattened inputs used this frame, in drawing order (an input before those that contain it).
    public var flatten: [FlattenPass] = []

    /// Every list of draw commands in the plan (to find the sources a frame needs).
    public var allCommandLists: [[DrawCommand]] {
        var lists: [[DrawCommand]] = [program, overlays, preview]
        lists.append(transition?.incoming ?? [])
        lists.append(detail ?? [])
        lists.append(fullPreview ?? [])
        lists.append(contentsOf: extra.values)
        lists.append(contentsOf: thumbnails.values)
        lists.append(contentsOf: flatten.map(\.layers))
        if let stinger { lists.append([stinger]) }
        return lists
    }
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
                            detailInput: InputID? = nil,
                            extraInputs: [InputID] = [],
                            fullPreview: Bool = false,
                            previewLayers: [InputID: [Layer]] = [:]) -> FramePlan {
        /// Flattened inputs draw as their one pre-composed picture (see `FlattenPass`).
        func isFlat(_ id: InputID) -> Bool {
            guard let l = layersFor(id), l.count > 1 else { return false }
            return l.first?.flatten == true
        }
        /// Preview of an input with a Layer Designer draft: the draft's layers, drawn directly
        /// (a draft is never flattened, so every edit shows at once).
        func previewComposition(_ id: InputID?) -> [DrawCommand] {
            guard let id, let draft = previewLayers[id], layersFor(id) != nil else { return composition(id) }
            return draft.compactMap { l in
                guard !l.isHidden, l.source == id || layersFor(l.source) != nil else { return nil }
                return DrawCommand(source: l.source, rect: l.rect, scaleMode: l.scaleMode, opacity: l.opacity,
                                   key: l.source == id ? rawKey(id) : key(l.source), style: l.style?.clamped)
            }
        }
        func rawKey(_ id: InputID) -> ChromaKey? {
            guard let k = keyFor(id), k.enabled else { return nil }
            return k.clamped
        }
        /// A flattened input is already keyed inside its own image.
        func key(_ id: InputID) -> ChromaKey? { isFlat(id) ? nil : rawKey(id) }
        /// The input's visible layers, back to front.
        func layered(_ id: InputID) -> [DrawCommand] {
            guard let layers = layersFor(id) else { return [] }
            return layers.compactMap { l in
                // Guard against a scene layer that points at a removed input.
                guard !l.isHidden, l.source == id || layersFor(l.source) != nil else { return nil }
                return DrawCommand(source: l.source, rect: l.rect, scaleMode: l.scaleMode, opacity: l.opacity,
                                   key: l.source == id ? rawKey(id) : key(l.source),
                                   style: l.style?.clamped)
            }
        }
        func composition(_ id: InputID?) -> [DrawCommand] {
            guard let id, layersFor(id) != nil else { return [] }
            if isFlat(id) { return [DrawCommand(source: id, rect: .full, scaleMode: .stretch, opacity: 1)] }
            return layered(id)
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
        plan.preview = previewComposition(snapshot.preview)
        /// A full-screen overlay shows the input as it looks on Program (its own layers, e.g. a
        /// running-text band at its position), moved and faded as one; other presets draw the
        /// input's picture in the preset box.
        func overlayCommands(_ ch: OverlayChannel, _ src: InputID, frame: NormRect, opacity: Double) -> [DrawCommand] {
            guard ch.preset == .fullScreen else {
                return [DrawCommand(source: src, rect: frame, scaleMode: ch.preset == .lowerThird ? .fit : .fill,
                                    opacity: opacity, key: key(src))]
            }
            return composition(src).map { c in
                var d = c
                d.rect = NormRect(x: frame.x + c.rect.x * frame.width, y: frame.y + c.rect.y * frame.height,
                                  width: c.rect.width * frame.width, height: c.rect.height * frame.height)
                d.opacity = c.opacity * opacity
                return d
            }
        }
        // Overlays waiting on Preview are drawn over the preview picture at full opacity.
        for ch in overlays.sorted(by: { $0.index < $1.index }) where ch.onPreview {
            guard let src = ch.source, layersFor(src) != nil else { continue }
            plan.preview += overlayCommands(ch, src, frame: ch.preset.rect, opacity: 1)
        }
        for ch in overlays.sorted(by: { $0.index < $1.index }) {
            guard let src = ch.source, layersFor(src) != nil else { continue }
            let (rect, a) = ch.placement(ch.preset.rect, at: now)
            guard a > 0.001 else { continue }
            plan.overlays += overlayCommands(ch, src, frame: rect, opacity: a)
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
        for id in extraInputs where layersFor(id) != nil { plan.extra[id] = composition(id) }
        if fullPreview { plan.fullPreview = plan.preview }

        // Flatten passes for every flattened input this frame draws, contained inputs first.
        var done = Set<InputID>(), visiting = Set<InputID>()
        func addPass(_ id: InputID) {
            guard isFlat(id), !done.contains(id), !visiting.contains(id) else { return }   // cycles: drawn once
            visiting.insert(id)
            let layers = layered(id)
            for c in layers where c.source != id { addPass(c.source) }
            visiting.remove(id)
            done.insert(id)
            plan.flatten.append(FlattenPass(input: id, layers: layers))
        }
        for list in plan.allCommandLists { for c in list { addPass(c.source) } }
        return plan
    }
}
