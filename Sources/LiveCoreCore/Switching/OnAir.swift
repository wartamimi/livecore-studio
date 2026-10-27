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

    /// Inputs whose audio should be heard (AFV): like `visibleInputs`, except that a running
    /// transition counts as already done, so the outgoing input's audio fades out while the
    /// incoming one fades in over the transition (a T-bar flips at its half-way point).
    public static func audioInputs(switcher: SwitcherSnapshot, layers: [InputID: [Layer]],
                                   overlays: [OverlayChannel]) -> Set<InputID> {
        var s = switcher
        if let t = s.transition {
            if let m = t.manualPosition, m < 0.5 { s.program = t.from } else { s.program = t.to }
            s.transition = nil
        }
        return visibleInputs(switcher: s, layers: layers, overlays: overlays)
    }

    /// AFV fade length: the transition's duration while an automatic transition runs, a short
    /// de-click ramp otherwise (cut, T-bar, overlay).
    public static func audioFadeSeconds(switcher: SwitcherSnapshot) -> Double {
        guard let t = switcher.transition, t.manualPosition == nil else { return 0.05 }
        return min(max(t.duration, 0.05), 10)
    }

    /// AFV gate of a channel linked to `link`: open when the input is visible. Channels without a
    /// link are never gated.
    public static func audioOpen(link: InputID?, visible: Set<InputID>) -> Bool {
        guard let link else { return true }
        return visible.contains(link)
    }
}
