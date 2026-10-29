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
    // 0.46.0
    case pipBottomLeft     // full screen + small box bottom left
    case doublePip         // full screen + two boxes on the right
    case splitTall         // two full-height halves (cropped)
    case grid3x3           // nine boxes
    case oneOverThree      // one large top, three across the bottom
    case sidebar           // main 3/4 left, three stacked on the right
    case newsDesk          // presenter box + guest box with a frame margin
    case lShape            // main box top left, free strip right and bottom for graphics
    case panel3            // three boxes with gaps (talk show / panel)
    case panel4            // four boxes in a row with gaps (webinar / quiz)

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
        case .pipBottomLeft:
            return [.full, NormRect(x: 0.03, y: 0.69, width: 0.28, height: 0.28)]
        case .doublePip:
            return [.full, NormRect(x: 0.69, y: 0.05, width: 0.28, height: 0.28), NormRect(x: 0.69, y: 0.36, width: 0.28, height: 0.28)]
        case .splitTall:
            return [NormRect(x: 0, y: 0, width: 0.5, height: 1), NormRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case .grid3x3:
            let w = 1.0 / 3.0
            return (0..<9).map { NormRect(x: Double($0 % 3) * w, y: Double($0 / 3) * w, width: w, height: w) }
        case .oneOverThree:
            let w = 1.0 / 3.0
            return [NormRect(x: 0.2, y: 0, width: 0.6, height: 0.6)]
                + (0..<3).map { NormRect(x: Double($0) * w, y: 0.6 + (0.4 - w) / 2, width: w, height: w) }
        case .sidebar:
            return [NormRect(x: 0, y: 0.125, width: 0.75, height: 0.75)]
                + (0..<3).map { NormRect(x: 0.75, y: 0.125 + Double($0) * 0.25, width: 0.25, height: 0.25) }
        case .newsDesk:
            return [NormRect(x: 0.04, y: 0.1, width: 0.6, height: 0.6), NormRect(x: 0.67, y: 0.1, width: 0.29, height: 0.29)]
        case .lShape:
            return [NormRect(x: 0, y: 0, width: 0.75, height: 0.75)]
        case .panel3:
            let w = 0.3, gap = 0.025
            return (0..<3).map { NormRect(x: gap + Double($0) * (w + gap), y: 0.2, width: w, height: w) }
        case .panel4:
            let w = 0.22, gap = 0.024
            return (0..<4).map { NormRect(x: gap + Double($0) * (w + gap), y: 0.25, width: w, height: w) }
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
