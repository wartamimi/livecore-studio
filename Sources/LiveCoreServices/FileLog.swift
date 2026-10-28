import Foundation

/// A small text log on disk (~/Library/Logs/LiveCore Studio/livecore.log) that survives a crash,
/// so "Export logs & diagnostics" can include what happened before it. Lines are timestamped;
/// the file rotates at `maxBytes` keeping `keep` old files. Thread-safe.
///
/// Never log secrets: callers pass texts that are already free of stream keys and PINs; `scrub`
/// is applied with the secrets registered through `addSecret` as a second guard.
public final class FileLog {
    public static let shared = FileLog(directory: FileLog.defaultDirectory())

    public let directory: URL
    public let maxBytes: Int
    public let keep: Int
    private let queue = DispatchQueue(label: "livecore.filelog")
    private var handle: FileHandle?
    private var secrets: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public init(directory: URL, maxBytes: Int = 5_000_000, keep: Int = 3) {
        self.directory = directory
        self.maxBytes = max(maxBytes, 10_000)
        self.keep = max(keep, 1)
    }

    public static func defaultDirectory() -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return lib.appendingPathComponent("Logs/LiveCore Studio", isDirectory: true)
    }

    public var currentURL: URL { directory.appendingPathComponent("livecore.log") }
    public func rotatedURL(_ n: Int) -> URL { directory.appendingPathComponent("livecore.\(n).log") }

    /// Texts that must never reach the file (stream keys, PIN). Short strings are ignored.
    public func addSecret(_ s: String) {
        guard s.count >= 4 else { return }
        queue.sync { if !secrets.contains(s) { secrets.append(s) } }
    }

    public func write(_ level: String, _ message: String, date: Date = Date()) {
        queue.async { [self] in
            var text = message
            for s in secrets { text = text.replacingOccurrences(of: s, with: "<redacted>") }
            let line = "\(formatter.string(from: date)) [\(level)] \(text.replacingOccurrences(of: "\n", with: " "))\n"
            append(Data(line.utf8))
        }
    }

    public func info(_ m: String) { write("info", m) }
    public func warning(_ m: String) { write("warn", m) }
    public func error(_ m: String) { write("error", m) }

    /// Waits until queued lines are on disk (tests, export).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    /// The current and rotated files, newest first, that exist.
    public func files() -> [URL] {
        flush()
        return ([currentURL] + (1...keep).map(rotatedURL)).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func append(_ data: Data) {
        let fm = FileManager.default
        if handle == nil {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: currentURL.path) { fm.createFile(atPath: currentURL.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: currentURL)
            _ = try? handle?.seekToEnd()
        }
        guard let h = handle else { return }
        if let size = try? h.offset(), Int(size) + data.count > maxBytes {
            try? h.close()
            handle = nil
            for n in stride(from: keep, through: 1, by: -1) {
                let src = n == 1 ? currentURL : rotatedURL(n - 1)
                let dst = rotatedURL(n)
                try? fm.removeItem(at: dst)
                if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dst) }
            }
            append(data)
            return
        }
        try? h.write(contentsOf: data)
    }
}
