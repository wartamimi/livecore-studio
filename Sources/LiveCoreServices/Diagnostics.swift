import Foundation

/// "Export logs & diagnostics": a folder with a readable summary (app and Mac, settings, inputs,
/// performance), the app's log files, recent crash reports and the current project, ready to zip
/// and send with a bug report. Stream keys and the remote PIN are never included: they are not in
/// settings or projects (Keychain only), and every text file is scrubbed with the known secrets.
public struct DiagnosticsBundle {
    public struct Section {
        public var title: String
        public var lines: [String]
        public init(title: String, lines: [String]) { self.title = title; self.lines = lines }
    }

    public var sections: [Section] = []
    /// Extra text files to include (name → contents), e.g. "settings.json", "project.livecore", "system-log.txt".
    public var files: [String: String] = [:]
    /// Files to copy as they are (log files, crash reports).
    public var copies: [URL] = []
    public var secrets: [String] = []

    public init() {}

    public func summary() -> String {
        var out = "LiveCore Studio diagnostics\n===========================\n"
        for s in sections {
            out += "\n## \(s.title)\n"
            for l in s.lines { out += "\(l)\n" }
        }
        return scrub(out)
    }

    public func scrub(_ text: String) -> String {
        var t = text
        for s in secrets where s.count >= 4 { t = t.replacingOccurrences(of: s, with: "<redacted>") }
        return Self.scrubURLKeys(t)
    }

    /// Masks what looks like a stream key at the end of an rtmp(s)/srt address pasted in full
    /// ("rtmp://a.rtmp.youtube.com/live2/abcd-efgh-…" → ".../live2/<redacted>"), and srt
    /// passphrase / streamid parameters.
    public static func scrubURLKeys(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        let schemes = ["rtmp://", "rtmps://", "srt://"]
        while let r = schemes.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            out += rest[rest.startIndex..<r.lowerBound]
            let end = rest[r.lowerBound...].firstIndex { $0 == " " || $0 == "\"" || $0 == "\n" || $0 == "," || $0 == "'" } ?? rest.endIndex
            out += maskAddress(String(rest[r.lowerBound..<end]))
            rest = rest[end...]
        }
        return out + rest
    }

    static func maskAddress(_ url: String) -> String {
        if url.hasPrefix("srt://") {
            guard let q = url.firstIndex(of: "?") else { return url }
            let params = url[url.index(after: q)...].split(separator: "&").map { p -> String in
                let kv = p.split(separator: "=", maxSplits: 1)
                let k = kv.first.map(String.init) ?? ""
                return ["passphrase", "streamid"].contains(k.lowercased()) ? "\(k)=<redacted>" : String(p)
            }
            return String(url[..<q]) + "?" + params.joined(separator: "&")
        }
        // rtmp(s)://host/app/key: keep scheme, host and app; mask anything after the app.
        let afterScheme = url.range(of: "://").map { url[$0.upperBound...] } ?? Substring(url)
        let parts = afterScheme.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 2 else { return url }
        let prefix = url[..<afterScheme.startIndex]
        return prefix + parts[0] + "/" + parts[1] + "/<redacted>"
    }

    /// Writes the bundle into a new folder inside `parent` and returns it.
    public func write(into parent: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(summary().utf8).write(to: dir.appendingPathComponent("summary.txt"))
        for (file, text) in files {
            try Data(scrub(text).utf8).write(to: dir.appendingPathComponent(file))
        }
        for url in copies where fm.fileExists(atPath: url.path) {
            let text = (try? String(contentsOf: url, encoding: .utf8)).map(scrub)
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            if let text { try Data(text.utf8).write(to: dst) } else { try? fm.copyItem(at: url, to: dst) }
        }
        return dir
    }
}
