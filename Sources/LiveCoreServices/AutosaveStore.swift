import Foundation

/// Autosave and crash recovery. The app writes the current project here every 30 seconds (only
/// when it changed) and marks the session as running; a clean quit marks it finished. If the
/// next launch finds a session that never finished (crash, force quit, power loss), it offers
/// the last autosave.
///
/// Files (in Application Support/LiveCore Studio/Autosave):
///   session.json          { running, startedAt, projectPath }
///   autosave.livecore     latest project (atomic write)
///   autosave-previous.livecore   the one before it (in case the latest is damaged)
///   autosave-info.json    { savedAt, projectPath }
/// Projects never contain stream keys (those stay in the Keychain), so neither does the autosave.
public final class AutosaveStore {
    public struct Recovery: Equatable {
        public let savedAt: Date
        /// The project file that was open (nil = an unsaved project).
        public let projectPath: String?
        public let fileURL: URL
    }

    private struct Session: Codable { var running: Bool; var startedAt: Date; var pid: Int32 }
    private struct Info: Codable { var savedAt: Date; var projectPath: String? }

    public let directory: URL
    private var lastData: Data?
    private let fm = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/LiveCore Studio/Autosave
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveCore Studio/Autosave", isDirectory: true)
    }

    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var infoURL: URL { directory.appendingPathComponent("autosave-info.json") }
    public var latestURL: URL { directory.appendingPathComponent("autosave.livecore") }
    public var previousURL: URL { directory.appendingPathComponent("autosave-previous.livecore") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// Call once at launch. Returns what can be recovered when the last session did not end
    /// cleanly, then marks this session as running.
    @discardableResult
    public func beginSession(now: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Recovery? {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var recovery: Recovery?
        if let data = try? Data(contentsOf: sessionURL), let s = try? Self.decoder.decode(Session.self, from: data), s.running,
           fm.fileExists(atPath: latestURL.path) {
            let info = (try? Data(contentsOf: infoURL)).flatMap { try? Self.decoder.decode(Info.self, from: $0) }
            recovery = Recovery(savedAt: info?.savedAt ?? s.startedAt, projectPath: info?.projectPath, fileURL: latestURL)
        }
        write(Session(running: true, startedAt: now, pid: pid), to: sessionURL)
        return recovery
    }

    /// Saves `data` (an encoded project) unless it is identical to the last save. Returns true
    /// when a file was written.
    @discardableResult
    public func save(_ data: Data, projectPath: String?, now: Date = Date()) throws -> Bool {
        if data == lastData { return false }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: latestURL.path) {
            try? fm.removeItem(at: previousURL)
            try? fm.copyItem(at: latestURL, to: previousURL)
        }
        try data.write(to: latestURL, options: .atomic)
        write(Info(savedAt: now, projectPath: projectPath), to: infoURL)
        lastData = data
        return true
    }

    /// The recovered project data; falls back to the previous autosave when the latest cannot be read.
    public func recoveryData(validate: (Data) -> Bool = { _ in true }) -> Data? {
        for url in [latestURL, previousURL] {
            if let d = try? Data(contentsOf: url), validate(d) { return d }
        }
        return nil
    }

    /// Clean quit: the next launch will not offer recovery.
    public func endSession() {
        guard let data = try? Data(contentsOf: sessionURL), var s = try? Self.decoder.decode(Session.self, from: data) else { return }
        s.running = false
        write(s, to: sessionURL)
    }

    /// Removes the autosave files (after the operator chose not to recover, or saved the project).
    public func discard() {
        for url in [latestURL, previousURL, infoURL] { try? fm.removeItem(at: url) }
        lastData = nil
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let d = try? Self.encoder.encode(value) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
