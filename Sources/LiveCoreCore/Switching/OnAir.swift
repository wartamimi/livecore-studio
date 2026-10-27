/// What is on air right now: shared by auto play and audio-follow-video (AFV).
public enum OnAir {
    /// Inputs visible on Program: the program input, both sides of a running transition, the
    /// scene layers of those inputs, and the sources of overlay channels that are on.
    public static func visibleInputs(switcher: SwitcherSnapshot, layers: [InputID: [Layer]],
                                     overlays: [OverlayChannel]) -> Set<InputID> {
        var visible = Set<InputID>()
        for id in [switcher.program, switcher.transition?.from, switcher.transition?.to].compactMap({ $0 }) {
            visible.insert(id)
            for l in layers[id] ?? [] { visible.insert(l.source) }
        }
        for o in overlays where o.isOn { if let s = o.source { visible.insert(s) } }
        return visible
    }

    /// AFV gate of a channel linked to `link`: open when the input is visible. Channels without a
    /// link are never gated.
    public static func audioOpen(link: InputID?, visible: Set<InputID>) -> Bool {
        guard let link else { return true }
        return visible.contains(link)
    }
}
