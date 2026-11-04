import Foundation

/// LCS Live (0.52.0): a remote guest who joins from a web browser with camera and microphone,
/// in the spirit of vMix Call. The guest opens a secret link, the call runs over WebRTC
/// (peer to peer, STUN, optional TURN), the guest's picture and sound become this input, and the
/// guest gets a return feed: the Program picture and a mix-minus (program sound without their
/// own voice).
public struct ProjectLiveCall: Codable, Equatable, Sendable {
    /// Secret part of the guest link (/live/<key>). A new key revokes the old link.
    public var key: String
    /// Shown to the guest on the join page (event or show name).
    public var title: String
    /// Size of the picture this input produces (the guest's video is fitted inside, black bars).
    public var width: Int
    public var height: Int
    public var fps: Int
    /// Return feed: Program picture to the guest.
    public var returnVideo: Bool
    /// Return feed: mix-minus sound (program without this guest) to the guest.
    public var returnAudio: Bool

    public init(key: String = LiveCallKey.make(), title: String = "LCS Live", width: Int = 1280, height: Int = 720,
                fps: Int = 30, returnVideo: Bool = true, returnAudio: Bool = true) {
        self.key = key; self.title = title; self.width = width; self.height = height; self.fps = fps
        self.returnVideo = returnVideo; self.returnAudio = returnAudio
    }

    /// Picture size kept inside 320×180 … 1920×1080 and 10…30 fps.
    public var clamped: ProjectLiveCall {
        var c = self
        c.width = min(max(width, 320), 1920); c.height = min(max(height, 180), 1080); c.fps = min(max(fps, 10), 30)
        c.title = String(title.prefix(60))
        return c
    }
}

public enum LiveCallKey {
    static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// 22 random characters (≈ 128 bits): the link cannot be guessed.
    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return make(using: &g)
    }

    public static func make<G: RandomNumberGenerator>(using g: inout G) -> String {
        String((0..<22).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    public static func isValid(_ s: String) -> Bool {
        s.count >= 16 && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// ICE servers handed to both ends of the call (RTCPeerConnection `iceServers`).
public struct LiveCallICE: Equatable, Sendable {
    public static let defaultSTUN = ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]
    public var turnURL: String
    public var turnUser: String
    public var turnPassword: String

    public init(turnURL: String = "", turnUser: String = "", turnPassword: String = "") {
        self.turnURL = turnURL; self.turnUser = turnUser; self.turnPassword = turnPassword
    }

    /// A TURN entry is used only when it looks like turn: / turns: URL(s).
    public var turnURLs: [String] {
        turnURL.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
            .filter { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
    }

    /// JSON array for RTCPeerConnection.
    public var json: String {
        var parts = ["{\"urls\":[\(Self.defaultSTUN.map(LiveCallJSON.string).joined(separator: ","))]}"]
        let turns = turnURLs
        if !turns.isEmpty {
            parts.append("{\"urls\":[\(turns.map(LiveCallJSON.string).joined(separator: ","))],\"username\":\(LiveCallJSON.string(turnUser)),\"credential\":\(LiveCallJSON.string(turnPassword))}")
        }
        return "[" + parts.joined(separator: ",") + "]"
    }
}

public enum LiveCallJSON {
    /// A JSON string literal (quotes included); safe inside an HTML <script> too ("</" escaped).
    public static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
