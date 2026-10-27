/// vMix-style scene layouts: a set of slots (normalised rectangles, back to front) that the scene
/// editor applies to a scene's layers. Slot 0 is the largest / background slot.
public enum SceneTemplate: String, CaseIterable, Codable, Sendable {
    case full              // every layer full screen
    case pip               // full screen + picture-in-picture top right
    case sideBySide        // two halves (16:9 boxes, letterboxed vertically)
    case grid2x2           // four quarters
    case oneAndTwo         // one large left, two stacked right
    case threeAcross       // three columns
    case interview         // two boxes with a gap, lower area free for a title

    /// Rectangles for the template's slots, back to front.
    public var slots: [NormRect] {
        switch self {
        case .full:
            return [.full]
        case .pip:
            return [.full, LayoutPreset.pipTopRight.rect]
        case .sideBySide:
            return [NormRect(x: 0, y: 0.25, width: 0.5, height: 0.5), NormRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)]
        case .grid2x2:
            return [NormRect(x: 0, y: 0, width: 0.5, height: 0.5), NormRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    NormRect(x: 0, y: 0.5, width: 0.5, height: 0.5), NormRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case .oneAndTwo:
            let big = 2.0 / 3.0
            return [NormRect(x: 0, y: (1 - big) / 2, width: big, height: big),
                    NormRect(x: big, y: 1.0 / 6.0, width: 1 - big, height: 1.0 / 3.0),
                    NormRect(x: big, y: 0.5, width: 1 - big, height: 1.0 / 3.0)]
        case .threeAcross:
            let w = 1.0 / 3.0
            return (0..<3).map { NormRect(x: Double($0) * w, y: 0.5 - w / 2, width: w, height: w) }
        case .interview:
            return [NormRect(x: 0.03, y: 0.12, width: 0.455, height: 0.455), NormRect(x: 0.515, y: 0.12, width: 0.455, height: 0.455)]
        }
    }

    /// Positions `layers` (back to front) on the template. The first `skip` layers (a scene's own
    /// blank base) keep their place; extra layers beyond the slots are left where they are.
    public func apply(to layers: [Layer], skip: Int = 0) -> [Layer] {
        var out = layers
        let s = slots
        var slot = 0
        for i in out.indices where i >= skip {
            guard slot < s.count else { break }
            out[i].rect = s[slot]
            out[i].scaleMode = .fill
            slot += 1
        }
        if self == .full { for i in out.indices where i >= skip { out[i].scaleMode = .fit } }
        return out
    }
}
