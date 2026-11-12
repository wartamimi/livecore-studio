import Foundation

/// A streaming platform preset (0.75.0, like OBS's service list): ingest server, where its stream
/// key is found, and whether LiveCore can fetch the key after the operator logs in.
public struct StreamService: Equatable, Sendable, Identifiable {
    /// How "Log in" works for a service. Only platforms with a public device-login (OAuth 2.0
    /// device flow) and an API that returns the stream key are listed.
    public enum Login: String, Sendable { case youtube, twitch }

    public let id: String
    public let name: String
    /// Empty when every account / event gets its own server (TikTok, Instagram, LinkedIn…).
    public let server: String
    public let backup: String
    /// Page where the key is shown.
    public let keyPage: String
    public let login: Login?

    public static let all: [StreamService] = [
        StreamService(id: "youtube", name: "YouTube", server: "rtmp://a.rtmp.youtube.com/live2",
                      backup: "rtmp://b.rtmp.youtube.com/live2?backup=1",
                      keyPage: "https://www.youtube.com/live_dashboard", login: .youtube),
        StreamService(id: "facebook", name: "Facebook", server: "rtmps://live-api-s.facebook.com:443/rtmp/",
                      keyPage: "https://www.facebook.com/live/producer"),
        StreamService(id: "twitch", name: "Twitch", server: "rtmp://live.twitch.tv/app",
                      keyPage: "https://dashboard.twitch.tv/settings/stream", login: .twitch),
        StreamService(id: "kick", name: "Kick", server: "rtmps://fa723fc1b171.global-contribute.live-video.net/app",
                      keyPage: "https://kick.com/dashboard/settings/stream"),
        StreamService(id: "tiktok", name: "TikTok Live", server: "", keyPage: "https://livecenter.tiktok.com/producer"),
        StreamService(id: "instagram", name: "Instagram", server: "", keyPage: "https://www.instagram.com/"),
        StreamService(id: "x", name: "X (Twitter)", server: "rtmps://va.pscp.tv:443/x", keyPage: "https://studio.x.com/producer"),
        StreamService(id: "linkedin", name: "LinkedIn Live", server: "", keyPage: "https://www.linkedin.com/video/golive/now"),
        StreamService(id: "vimeo", name: "Vimeo", server: "rtmps://rtmp-global.cloud.vimeo.com:443/live", keyPage: "https://vimeo.com/library"),
        StreamService(id: "trovo", name: "Trovo", server: "rtmp://livepush.trovo.live/live/", keyPage: "https://studio.trovo.live/stream"),
    ]

    init(id: String, name: String, server: String, backup: String = "", keyPage: String, login: Login? = nil) {
        self.id = id; self.name = name; self.server = server; self.backup = backup; self.keyPage = keyPage; self.login = login
    }

    /// The service whose ingest server `url` points at (same host), nil for a custom server.
    public static func match(_ url: String) -> StreamService? {
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return nil }
        return all.first { s in
            [s.server, s.backup].compactMap { URLComponents(string: $0)?.host?.lowercased() }.contains(host)
        }
    }
}

/// OAuth 2.0 device authorization (RFC 8628) endpoints and the API calls that return the stream
/// key. Pure request building / response parsing, so it is tested on Linux; the app does the I/O.
public enum StreamLoginAPI {
    public struct Endpoints: Sendable {
        public let device: URL, token: URL, scope: String, consolePage: String, needsSecret: Bool
    }

    public static func endpoints(_ l: StreamService.Login) -> Endpoints {
        switch l {
        case .youtube:
            return Endpoints(device: URL(string: "https://oauth2.googleapis.com/device/code")!,
                             token: URL(string: "https://oauth2.googleapis.com/token")!,
                             scope: "https://www.googleapis.com/auth/youtube",
                             consolePage: "https://console.cloud.google.com/apis/credentials", needsSecret: true)
        case .twitch:
            return Endpoints(device: URL(string: "https://id.twitch.tv/oauth2/device")!,
                             token: URL(string: "https://id.twitch.tv/oauth2/token")!,
                             scope: "channel:read:stream_key",
                             consolePage: "https://dev.twitch.tv/console/apps", needsSecret: false)
        }
    }

    /// The code the operator types on the platform's page.
    public struct DeviceCode: Equatable, Sendable {
        public let deviceCode: String, userCode: String, verificationURL: String, interval: Int
    }

    public enum PollResult: Equatable, Sendable { case pending, slowDown, token(String), failed(String) }

    public static func form(_ fields: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    public static func deviceRequest(_ l: StreamService.Login, clientID: String) -> Data {
        form(["client_id": clientID, (l == .twitch ? "scopes" : "scope"): endpoints(l).scope])
    }

    public static func tokenRequest(_ l: StreamService.Login, clientID: String, secret: String, deviceCode: String) -> Data {
        var f = ["client_id": clientID, "device_code": deviceCode,
                 "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]
        if l == .twitch { f["scopes"] = endpoints(l).scope }
        if !secret.isEmpty { f["client_secret"] = secret }
        return form(f)
    }

    private static func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    public static func parseDeviceCode(_ d: Data) -> DeviceCode? {
        let j = json(d)
        guard let dc = j["device_code"] as? String, let uc = j["user_code"] as? String,
              let url = (j["verification_uri"] ?? j["verification_url"]) as? String else { return nil }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationURL: url, interval: max(j["interval"] as? Int ?? 5, 1))
    }

    public static func parseToken(_ d: Data) -> PollResult {
        let j = json(d)
        if let t = j["access_token"] as? String { return .token(t) }
        let err = (j["error"] as? String) ?? (j["message"] as? String) ?? "unknown error"
        switch err {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        default: return .failed(err)
        }
    }

    /// Body of `POST liveStreams?part=snippet,cdn` when the channel has no stream yet.
    public static let youTubeNewStream = Data(#"{"snippet":{"title":"LiveCore Studio"},"cdn":{"ingestionType":"rtmp","resolution":"variable","frameRate":"variable"}}"#.utf8)

    /// Server and key of the first YouTube live stream: a `liveStreams` list or one created stream.
    public static func parseYouTubeStream(_ d: Data) -> (server: String, key: String)? {
        let j = json(d)
        let items = j["items"] as? [[String: Any]] ?? [j]
        guard let info = items.compactMap({ ($0["cdn"] as? [String: Any])?["ingestionInfo"] as? [String: Any] }).first,
              let server = info["ingestionAddress"] as? String, let key = info["streamName"] as? String else { return nil }
        return (server, key)
    }

    /// `data[0].<field>` of a Twitch Helix response (user `id`, `stream_key`).
    public static func parseTwitch(_ d: Data, field: String) -> String? {
        ((json(d)["data"] as? [[String: Any]])?.first)?[field] as? String
    }
}
