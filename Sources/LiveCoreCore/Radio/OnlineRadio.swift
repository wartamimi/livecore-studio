import Foundation

/// An internet radio station from the Radio Browser directory (radio-browser.info: free, open,
/// no account or API key). Stored in projects so a show reopens with the same station.
public struct RadioStation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String          // Radio Browser `stationuuid`
    public var name: String
    public var streamURL: String   // `url_resolved`: the stream itself, playlists already resolved
    public var homepage: String
    public var favicon: String
    public var tags: String        // comma separated genres
    public var countryCode: String
    public var codec: String       // MP3, AAC, AAC+ ...
    public var bitrate: Int        // kbit/s, 0 = unknown

    public init(id: String, name: String, streamURL: String, homepage: String = "", favicon: String = "",
                tags: String = "", countryCode: String = "", codec: String = "", bitrate: Int = 0) {
        self.id = id; self.name = name; self.streamURL = streamURL; self.homepage = homepage; self.favicon = favicon
        self.tags = tags; self.countryCode = countryCode; self.codec = codec; self.bitrate = bitrate
    }

    /// Codecs the app decodes from a live stream (Core Audio's MP3 and ADTS AAC / HE-AAC parsers).
    public static let supportedCodecs: Set<String> = ["MP3", "AAC", "AAC+"]

    public var isAAC: Bool { codec.uppercased().hasPrefix("AAC") }

    /// "MP3 · 128 kbit/s · ID · pop, dangdut"
    public var summary: String {
        var parts = [codec.isEmpty ? "?" : codec.uppercased()]
        if bitrate > 0 { parts.append("\(bitrate) kbit/s") }
        if !countryCode.isEmpty { parts.append(countryCode) }
        let t = tags.split(separator: ",").prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !t.isEmpty { parts.append(t.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Radio Browser API (https://api.radio-browser.info). Only stations the app can play are kept:
/// HTTPS streams (no exceptions to App Transport Security), no HLS, MP3 or AAC, last check OK.
public enum RadioBrowser {
    /// Public mirrors, tried in turn.
    public static let servers = ["de1.api.radio-browser.info", "de2.api.radio-browser.info",
                                 "fi1.api.radio-browser.info", "at1.api.radio-browser.info"]
    /// The directory asks clients to identify themselves.
    public static let userAgent = "LiveCoreStudio/1.0"

    public struct Query: Equatable, Sendable {
        public var name = ""
        public var tag = ""
        public var countryCode = ""
        public var limit = 60
        public init(name: String = "", tag: String = "", countryCode: String = "", limit: Int = 60) {
            self.name = name; self.tag = tag; self.countryCode = countryCode; self.limit = limit
        }
    }

    public static func searchURL(server: String, _ q: Query) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = server
        c.path = "/json/stations/search"
        var items = [URLQueryItem]()
        let name = q.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = q.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let cc = q.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        if !tag.isEmpty { items.append(URLQueryItem(name: "tag", value: tag.lowercased())) }
        if cc.count == 2 { items.append(URLQueryItem(name: "countrycode", value: cc)) }
        items += [
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "is_https", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true"),
            // Ask for more than shown: some are filtered out below (HLS, other codecs).
            URLQueryItem(name: "limit", value: String(max(1, min(q.limit, 200)) * 2)),
        ]
        c.queryItems = items
        return c.url
    }

    /// Counts a play in the directory's popularity ranking (the directory asks clients to do so).
    public static func clickURL(server: String, stationID: String) -> URL? {
        guard stationID.allSatisfy({ $0.isHexDigit || $0 == "-" }), !stationID.isEmpty else { return nil }
        return URL(string: "https://\(server)/json/url/\(stationID)")
    }

    private struct APIStation: Decodable {
        var stationuuid: String?
        var name: String?
        var url_resolved: String?
        var url: String?
        var homepage: String?
        var favicon: String?
        var tags: String?
        var countrycode: String?
        var codec: String?
        var bitrate: Int?
        var hls: Int?
        var lastcheckok: Int?
    }

    /// Stations from a search response that the app can play, in the server's order, without duplicates.
    public static func decodeStations(_ data: Data, limit: Int = 60) throws -> [RadioStation] {
        let raw = try JSONDecoder().decode([APIStation].self, from: data)
        var seen = Set<String>(), out = [RadioStation]()
        for s in raw {
            guard let id = s.stationuuid, !id.isEmpty, !seen.contains(id) else { continue }
            let stream = (s.url_resolved?.isEmpty == false ? s.url_resolved : s.url) ?? ""
            let station = RadioStation(id: id, name: (s.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                       streamURL: stream.trimmingCharacters(in: .whitespacesAndNewlines),
                                       homepage: s.homepage ?? "", favicon: s.favicon ?? "", tags: s.tags ?? "",
                                       countryCode: s.countrycode ?? "", codec: (s.codec ?? "").uppercased(), bitrate: s.bitrate ?? 0)
            guard s.hls ?? 0 == 0, s.lastcheckok ?? 1 == 1, isPlayable(station) else { continue }
            seen.insert(id)
            out.append(station)
            if out.count >= limit { break }
        }
        return out
    }

    public static func isPlayable(_ s: RadioStation) -> Bool {
        guard !s.name.isEmpty, RadioStation.supportedCodecs.contains(s.codec.uppercased()),
              let u = URL(string: s.streamURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return false }
        let path = u.path.lowercased()
        return !path.hasSuffix(".m3u8") && !path.hasSuffix(".m3u") && !path.hasSuffix(".pls")
    }
}

/// Removes SHOUTcast/Icecast "ICY" metadata blocks from a stream requested with
/// `Icy-MetaData: 1`: after every `metaInt` audio bytes comes one length byte (×16) and that many
/// bytes of text such as `StreamTitle='Artist - Song';`.
public struct ICYMetadataReader: Sendable {
    public let metaInt: Int
    private var untilMeta: Int
    private var metaLeft = -1        // -1: not inside a metadata block
    private var meta: [UInt8] = []

    public init(metaInt: Int) {
        self.metaInt = max(metaInt, 0)
        untilMeta = self.metaInt
    }

    /// Audio bytes of `chunk`, and any song titles that arrived with it.
    public mutating func feed(_ chunk: [UInt8]) -> (audio: [UInt8], titles: [String]) {
        guard metaInt > 0 else { return (chunk, []) }
        var audio = [UInt8](), titles = [String]()
        audio.reserveCapacity(chunk.count)
        var i = 0
        while i < chunk.count {
            if metaLeft < 0 && untilMeta > 0 {
                let n = min(untilMeta, chunk.count - i)
                audio.append(contentsOf: chunk[i..<(i + n)])
                untilMeta -= n
                i += n
            } else if metaLeft < 0 {
                metaLeft = Int(chunk[i]) * 16
                i += 1
                meta.removeAll(keepingCapacity: true)
                if metaLeft == 0 { metaLeft = -1; untilMeta = metaInt }
            } else {
                let n = min(metaLeft, chunk.count - i)
                meta.append(contentsOf: chunk[i..<(i + n)])
                metaLeft -= n
                i += n
                if metaLeft == 0 {
                    if let t = Self.title(in: meta) { titles.append(t) }
                    metaLeft = -1
                    untilMeta = metaInt
                }
            }
        }
        return (audio, titles)
    }

    /// `StreamTitle='…';` from a metadata block (UTF-8, or Latin-1 from older servers).
    public static func title(in block: [UInt8]) -> String? {
        let bytes = block.prefix { $0 != 0 }
        guard let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1),
              let start = text.range(of: "StreamTitle='") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "';")?.lowerBound ?? rest.lastIndex(of: "'") ?? rest.endIndex
        let title = String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

/// Jitter buffer between a network stream (arrives in bursts, on the station's clock) and the
/// mixer (pulls in real time). Playback starts once `prebuffer` frames are queued, waits again
/// (silence) after running dry, and drops the oldest audio when more than `capacity` is queued.
public struct StreamAudioBuffer: Sendable {
    public let capacity: Int
    public let prebuffer: Int
    public private(set) var isBuffering = true
    public private(set) var underruns = 0
    public private(set) var droppedFrames = 0
    private var left: [Float]
    private var right: [Float]
    private var head = 0             // read position
    private var count = 0

    public init(capacity: Int, prebuffer: Int) {
        self.capacity = max(capacity, 1)
        self.prebuffer = min(max(prebuffer, 1), self.capacity)
        left = [Float](repeating: 0, count: self.capacity)
        right = [Float](repeating: 0, count: self.capacity)
    }

    public var queuedFrames: Int { count }

    public mutating func append(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        var start = 0, n = n
        if n > capacity { start = n - capacity; droppedFrames += start; n = capacity }
        let overflow = count + n - capacity
        if overflow > 0 {
            head = (head + overflow) % capacity
            count -= overflow
            droppedFrames += overflow
        }
        var w = (head + count) % capacity
        for k in 0..<n {
            left[w] = l[start + k]
            right[w] = r[start + k]
            w += 1
            if w == capacity { w = 0 }
        }
        count += n
        if isBuffering && count >= prebuffer { isBuffering = false }
    }

    /// Copies up to `n` frames out; returns how many (0 while buffering).
    public mutating func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count n: Int) -> Int {
        guard !isBuffering, n > 0 else { return 0 }
        let m = min(n, count)
        for k in 0..<m {
            l[k] = left[head]
            r[k] = right[head]
            head += 1
            if head == capacity { head = 0 }
        }
        count -= m
        if count == 0 {
            isBuffering = true
            underruns += 1
        }
        return m
    }

    public mutating func reset() {
        head = 0; count = 0; isBuffering = true
    }
}
