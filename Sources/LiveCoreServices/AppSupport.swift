import Foundation

/// ~/Library/Application Support/LiveCore Studio and its sub-folders.
public enum AppSupport {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveCore Studio", isDirectory: true)
    }

    public static func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
}
