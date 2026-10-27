/// Parsed RTMP/RTMPS publish endpoint.
///
/// Accepted forms (stream key entered separately, as most platforms present it):
///   rtmp://a.rtmp.youtube.com/live2                 app = "live2"
///   rtmps://live-api-s.facebook.com:443/rtmp/       app = "rtmp"
///   rtmp://host:1935/app/instance                   app = "app/instance"
///   rtmp://host/app?token=abc                       app = "app?token=abc"  (query kept, like librtmp)
/// If the key field is empty, the last path component is used as the stream key
/// (e.g. rtmp://host/live/mystream -> app "live", key "mystream").
public struct RTMPURL: Equatable, Sendable {
    public enum Scheme: String, Sendable { case rtmp, rtmps }

    public var scheme: Scheme
    public var host: String
    public var port: Int
    public var app: String
    public var streamKey: String

    public var useTLS: Bool { scheme == .rtmps }

    /// tcUrl sent in the `connect` command (never contains the stream key).
    public var tcUrl: String {
        let defaultPort = scheme == .rtmps ? 443 : 1935
        let portPart = port == defaultPort ? "" : ":\(port)"
        return "\(scheme.rawValue)://\(host)\(portPart)/\(app)"
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unsupportedScheme(String)
        case missingHost
        case missingApp
        case missingStreamKey
        case invalidPort

        public var description: String {
            switch self {
            case let .unsupportedScheme(s): return "Unsupported URL scheme '\(s)'. Use rtmp:// or rtmps://."
            case .missingHost: return "The server URL has no host name."
            case .missingApp: return "The server URL has no application path (e.g. /live)."
            case .missingStreamKey: return "No stream key was provided."
            case .invalidPort: return "The port in the server URL is not valid."
            }
        }
    }

    public init(scheme: Scheme, host: String, port: Int, app: String, streamKey: String) {
        self.scheme = scheme; self.host = host; self.port = port; self.app = app; self.streamKey = streamKey
    }

    public static func parse(serverURL raw: String, streamKey rawKey: String) throws -> RTMPURL {
        let url = raw.trimmed
        let key = rawKey.trimmed
        guard let sepRange = url.firstRange(ofLiteral: "://") else { throw ParseError.unsupportedScheme(url) }
        let schemeStr = String(url[url.startIndex..<sepRange.lowerBound]).lowercased()
        guard let scheme = Scheme(rawValue: schemeStr) else { throw ParseError.unsupportedScheme(schemeStr) }
        let rest = url[sepRange.upperBound...]

        let slash = rest.firstIndex(of: "/")
        let authority = slash.map { rest[rest.startIndex..<$0] } ?? rest
        var path = slash.map { String(rest[rest.index(after: $0)...]) } ?? ""

        var host = String(authority)
        var port = scheme == .rtmps ? 443 : 1935
        if host.hasPrefix("[") { // IPv6 literal [::1]:1935
            guard let close = host.firstIndex(of: "]") else { throw ParseError.missingHost }
            let after = host[host.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = Int(after.dropFirst()), (1...65535).contains(p) else { throw ParseError.invalidPort }
                port = p
            }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":") {
            guard let p = Int(host[host.index(after: colon)...]), (1...65535).contains(p) else { throw ParseError.invalidPort }
            port = p
            host = String(host[host.startIndex..<colon])
        }
        guard !host.isEmpty else { throw ParseError.missingHost }

        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { throw ParseError.missingApp }

        var finalKey = key
        if finalKey.isEmpty {
            // Key embedded as last path component.
            guard let lastSlash = path.lastIndex(of: "/") else { throw ParseError.missingStreamKey }
            finalKey = String(path[path.index(after: lastSlash)...])
            path = String(path[path.startIndex..<lastSlash])
            guard !finalKey.isEmpty, !path.isEmpty else { throw ParseError.missingStreamKey }
        }
        return RTMPURL(scheme: scheme, host: host, port: port, app: path, streamKey: finalKey)
    }
}

extension String {
    var trimmed: String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s.removeFirst() }
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return String(s)
    }
    func firstRange(ofLiteral t: String) -> Range<String.Index>? {
        Substring(self).firstRange(of: t).map { $0.lowerBound..<$0.upperBound }
    }
}
