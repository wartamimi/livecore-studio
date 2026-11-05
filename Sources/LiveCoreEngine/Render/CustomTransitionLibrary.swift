#if os(macOS)
import Foundation
import LiveCoreCore

/// Custom transition shaders: the built-in examples plus `.metal` files in
/// ~/Library/Application Support/LiveCore Studio/Transitions (imported or written by the user).
public enum CustomTransitionLibrary {
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let isBuiltIn: Bool
    }

    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveCore Studio/Transitions", isDirectory: true)
    }

    /// Built-ins first, then user files sorted by name.
    public static func entries() -> [Entry] {
        var out = BuiltInTransition.all.map { Entry(id: $0.id, name: $0.name, isBuiltIn: true) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files.sorted() where file.hasSuffix(".metal") && !file.hasPrefix(".") {
            let id = CustomTransitionSource.fileID(file)
            let fallback = String(file.dropLast(6))
            let name = code(for: id).map { CustomTransitionSource.name(in: $0, fallback: fallback) } ?? fallback
            out.append(Entry(id: id, name: name, isBuiltIn: false))
        }
        return out
    }

    public static func code(for id: String) -> String? {
        if let b = BuiltInTransition.find(id: id) { return b.code }
        guard let name = CustomTransitionSource.fileName(fromID: id) else { return nil }
        let url = folder.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= CustomTransitionSource.maxBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Copies a .metal file into the transitions folder (replacing one with the same name) and
    /// returns its id.
    public static func importFile(_ url: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = url.lastPathComponent
        if !name.hasSuffix(".metal") { name += ".metal" }
        let dest = folder.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)
        return CustomTransitionSource.fileID(name)
    }

    /// Writes the template as a new file (My Transition.metal, My Transition 2.metal, …).
    public static func createFromTemplate() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var n = 1
        var url = folder.appendingPathComponent("My Transition.metal")
        while fm.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("My Transition \(n).metal")
        }
        try BuiltInTransition.template.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
#endif
