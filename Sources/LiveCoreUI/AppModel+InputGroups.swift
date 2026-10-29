#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Inputs panel organisation (vMix-style): colour labels group inputs, tiles can be minimized,
/// and the panel can show one colour only. Saved in the project.
extension AppModel {
    public func setColorTag(_ tag: InputColorTag?, for id: InputID) {
        inputTags[id] = tag
        if let f = inputFilter, !inputTags.values.contains(f) { inputFilter = nil }
    }

    public func toggleMinimized(_ id: InputID) {
        if minimizedInputs.contains(id) { minimizedInputs.remove(id) } else { minimizedInputs.insert(id) }
    }

    /// Minimizes or expands every input shown (all, or the filtered colour).
    public func setAllMinimized(_ on: Bool) {
        let shown = inputGroups.flatMap(\.inputs)
        if on { minimizedInputs.formUnion(shown) } else { minimizedInputs.subtract(shown) }
    }

    public func renameGroup(_ tag: InputColorTag, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        groupNames[tag] = n.isEmpty ? nil : n
    }

    public func groupName(_ tag: InputColorTag?) -> String {
        guard let tag else { return L10n.t("groups.untagged") }
        return groupNames[tag] ?? L10n.t("color." + tag.rawValue)
    }

    /// Panel sections for the current inputs, colour labels and filter.
    public var inputGroups: [InputGroup] {
        InputGrouping.groups(order: inputs.map(\.id), tags: inputTags, filter: inputFilter)
    }

    public var usedColorTags: [(tag: InputColorTag, count: Int)] {
        InputGrouping.usedTags(order: inputs.map(\.id), tags: inputTags)
    }

    func applyInputGroups(from doc: ProjectDocument) {
        rundown = doc.rundown ?? Rundown()
        rundownIndex = nil
        rundownStart = nil
        inputTags = Dictionary(uniqueKeysWithValues: doc.inputs.compactMap { i in i.colorTag.map { (i.id, $0) } })
        minimizedInputs = Set(doc.inputs.filter { $0.minimized == true }.map(\.id))
        groupNames = Dictionary(uniqueKeysWithValues: (doc.groupNames ?? [:]).compactMap { k, v in
            InputColorTag(rawValue: k).map { ($0, v) }
        })
        inputFilter = nil
    }

    func storeInputGroups(in doc: inout ProjectDocument) {
        doc.rundown = rundown.segments.isEmpty ? nil : rundown
        for k in doc.inputs.indices {
            let id = doc.inputs[k].id
            doc.inputs[k].colorTag = inputTags[id]
            doc.inputs[k].minimized = minimizedInputs.contains(id) ? true : nil
        }
        doc.groupNames = groupNames.isEmpty ? nil : Dictionary(uniqueKeysWithValues: groupNames.map { ($0.key.rawValue, $0.value) })
    }
}

extension InputColorTag {
    var color: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }
}
#endif
