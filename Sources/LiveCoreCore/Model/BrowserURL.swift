/// Rules for what a browser source may load. Only web pages (http/https) and local files the
/// operator picked; no custom schemes, no javascript:/data: URLs typed into the field.
public enum BrowserURLPolicy {
    public enum Verdict: Equatable, Sendable { case web(String), file(String), rejected(String) }

    public static let allowedFPS = [5, 10, 15, 30]

    /// Normalises what the operator typed: "example.com/overlay" -> "https://example.com/overlay".
    public static func check(_ raw: String) -> Verdict {
        let s = raw.trimmingCharacters(in: " \t\n\r")
        guard !s.isEmpty else { return .rejected("Enter a web address.") }
        let lower = s.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return s.count > lower.prefix(while: { $0 != ":" }).count + 3 ? .web(s) : .rejected("Incomplete address.")
        }
        if lower.hasPrefix("file://") { return .file(s) }
        if lower.hasPrefix("/") { return .file("file://" + s) }
        if let colon = lower.firstIndex(of: ":"), !lower[..<colon].contains(".") , !lower[..<colon].contains("/"),
           !(lower[lower.index(after: colon)...].first?.isNumber ?? false) {
            // A scheme such as javascript:, data:, ftp:, mailto: ...
            return .rejected("Only http, https and local files are allowed.")
        }
        if s.contains(" ") { return .rejected("Address contains spaces.") }
        // Local overlay servers (localhost, LAN IPs) rarely have TLS certificates.
        let isLocal = lower.hasPrefix("localhost") || (lower.first?.isNumber ?? false)
        return .web((isLocal ? "http://" : "https://") + s)
    }

    /// Nearest allowed snapshot rate.
    public static func clampFPS(_ fps: Int) -> Int {
        allowedFPS.min(by: { abs($0 - fps) < abs($1 - fps) }) ?? 15
    }
}

private extension String {
    func trimmingCharacters(in set: String) -> String {
        var sub = Substring(self)
        while let f = sub.first, set.contains(f) { sub.removeFirst() }
        while let l = sub.last, set.contains(l) { sub.removeLast() }
        return String(sub)
    }
}
