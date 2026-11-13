#if os(macOS)
import Foundation
import LiveCoreCore

/// Saved layouts of the Layer Designer (kept on this Mac, not in project files).
extension AppModel {
    static let layoutTemplatesKey = "layout.templates"

    static func loadLayoutTemplates() -> [LayoutTemplate] {
        guard let data = UserDefaults.standard.data(forKey: layoutTemplatesKey),
              let list = try? JSONDecoder().decode([LayoutTemplate].self, from: data) else { return [] }
        return list
    }

    private func storeLayoutTemplates() {
        if let data = try? JSONEncoder().encode(layoutTemplates) { UserDefaults.standard.set(data, forKey: Self.layoutTemplatesKey) }
    }

    /// Saves the layers as a template; a template with the same name is replaced.
    public func saveLayoutTemplate(name: String, layers: [Layer]) {
        let t = LayoutTemplate(id: UUID().uuidString, name: name, layers: layers)
        layoutTemplates.removeAll { $0.name == name }
        layoutTemplates.append(t)
        layoutTemplates.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        storeLayoutTemplates()
    }

    public func deleteLayoutTemplate(_ t: LayoutTemplate) {
        layoutTemplates.removeAll { $0.id == t.id }
        storeLayoutTemplates()
    }
}
#endif
