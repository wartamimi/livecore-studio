#if os(macOS)
import SwiftUI

/// User-configurable keyboard shortcuts (persisted in UserDefaults).
public struct ShortcutSettings: Codable, Equatable {
    public var cut: String = "space"
    public var auto: String = "return"
    public var stream: String = "l"     // with ⌘
    public var record: String = "r"     // with ⌘

    public static let choices: [String] = ["space", "return", "tab"] + "abcdefghijklmnopqrstuvwxyz".map(String.init)

    static func key(_ name: String) -> KeyEquivalent {
        switch name {
        case "space": return .space
        case "return": return .return
        case "tab": return .tab
        default: return KeyEquivalent(name.first ?? " ")
        }
    }

    static func load() -> ShortcutSettings {
        guard let d = UserDefaults.standard.data(forKey: "shortcuts"),
              let s = try? JSONDecoder().decode(ShortcutSettings.self, from: d) else { return ShortcutSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "shortcuts") }
    }
}
#endif
