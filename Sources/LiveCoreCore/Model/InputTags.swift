/// Colour labels for inputs (vMix-style): inputs with the same colour form a group in the
/// inputs panel, and the panel can show one colour only. Saved in the project.
public enum InputColorTag: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink

    /// sRGB 0...1.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: return (0.93, 0.26, 0.27)
        case .orange: return (0.98, 0.55, 0.15)
        case .yellow: return (0.96, 0.80, 0.18)
        case .green: return (0.24, 0.76, 0.40)
        case .teal: return (0.15, 0.72, 0.75)
        case .blue: return (0.25, 0.52, 0.98)
        case .purple: return (0.62, 0.38, 0.95)
        case .pink: return (0.93, 0.36, 0.68)
        }
    }
}

/// One section of the inputs panel: the inputs with one colour (or with none).
public struct InputGroup: Equatable, Sendable {
    public var tag: InputColorTag?
    public var inputs: [InputID]
    public init(tag: InputColorTag?, inputs: [InputID]) { self.tag = tag; self.inputs = inputs }
}

public enum InputGrouping {
    /// Groups `order` by colour. Without any colour there is one group (no header). Colour
    /// groups come in the order their first input appears; inputs without a colour come last.
    /// With `filter`, only that colour's group (possibly empty).
    public static func groups(order: [InputID], tags: [InputID: InputColorTag], filter: InputColorTag? = nil) -> [InputGroup] {
        if let filter { return [InputGroup(tag: filter, inputs: order.filter { tags[$0] == filter })] }
        guard order.contains(where: { tags[$0] != nil }) else { return [InputGroup(tag: nil, inputs: order)] }
        var seen: [InputColorTag] = []
        for id in order { if let t = tags[id], !seen.contains(t) { seen.append(t) } }
        var out = seen.map { t in InputGroup(tag: t, inputs: order.filter { tags[$0] == t }) }
        let untagged = order.filter { tags[$0] == nil }
        if !untagged.isEmpty { out.append(InputGroup(tag: nil, inputs: untagged)) }
        return out
    }

    /// Colours in use, in panel order, with how many inputs carry each.
    public static func usedTags(order: [InputID], tags: [InputID: InputColorTag]) -> [(tag: InputColorTag, count: Int)] {
        groups(order: order, tags: tags).compactMap { g in g.tag.map { ($0, g.inputs.count) } }
    }
}
