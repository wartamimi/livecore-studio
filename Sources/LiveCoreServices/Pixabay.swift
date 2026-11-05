import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// "Online Library by Pixabay" (0.61.0): searches the free Pixabay image and video library with
/// the operator's own API key (free at pixabay.com/api/docs). Picked items are downloaded to the
/// Mac once and become ordinary image / video inputs, so a show never depends on the connection
/// after that. Pixabay asks apps to show where results come from and not to hotlink, which the
/// sheet and the download follow.
public enum Pixabay {
    public static let keychainAccount = "pixabay.apikey"
    public static let apiDocs = URL(string: "https://pixabay.com/api/docs/")!

    public enum Kind: String, CaseIterable, Sendable { case photo, illustration, vector, video }

    public struct Hit: Identifiable, Equatable, Sendable {
        public let id: Int
        public let isVideo: Bool
        public let tags: String
        public let user: String
        public let pageURL: URL?
        public let thumbnailURL: URL?
        /// What is downloaded: the largest image / video the free API offers (videos: up to 1080p).
        public let downloadURL: URL
        public let width: Int
        public let height: Int
        public let duration: Int?
        public var fileExtension: String {
            let e = downloadURL.pathExtension.lowercased()
            return e.isEmpty ? (isVideo ? "mp4" : "jpg") : e
        }
    }

    public struct Page: Sendable {
        public let total: Int
        public let hits: [Hit]
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noKey, badKey, rateLimited, http(Int), decode, network(String)
        public var description: String {
            switch self {
            case .noKey: return "Enter your Pixabay API key first."
            case .badKey: return "Pixabay rejected the API key. Check it at pixabay.com/api/docs."
            case .rateLimited: return "Too many requests to Pixabay; wait a minute and try again."
            case let .http(c): return "Pixabay answered HTTP \(c)."
            case .decode: return "Unexpected answer from Pixabay."
            case let .network(m): return m
            }
        }
    }

    public static func searchURL(key: String, query: String, kind: Kind, page: Int = 1, perPage: Int = 40,
                                 safeSearch: Bool = true) -> URL? {
        var c = URLComponents(string: kind == .video ? "https://pixabay.com/api/videos/" : "https://pixabay.com/api/")
        var items = [URLQueryItem(name: "key", value: key),
                     URLQueryItem(name: "q", value: String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))),
                     URLQueryItem(name: "page", value: String(max(1, page))),
                     URLQueryItem(name: "per_page", value: String(min(max(perPage, 3), 200))),
                     URLQueryItem(name: "safesearch", value: safeSearch ? "true" : "false")]
        if kind != .video { items.append(URLQueryItem(name: "image_type", value: kind.rawValue)) }
        c?.queryItems = items
        return c?.url
    }

    /// Parses an answer of /api/ or /api/videos/.
    public static func parse(_ data: Data, video: Bool) throws -> Page {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["hits"] as? [[String: Any]] else { throw Failure.decode }
        let total = (root["totalHits"] as? Int) ?? raw.count
        let hits: [Hit] = raw.compactMap { h in
            guard let id = h["id"] as? Int else { return nil }
            let tags = h["tags"] as? String ?? ""
            let user = h["user"] as? String ?? ""
            let page = (h["pageURL"] as? String).flatMap(URL.init(string:))
            if video {
                guard let v = h["videos"] as? [String: [String: Any]] else { return nil }
                // Largest rendition up to 1080p (4K "large" files are big for live use).
                let order = ["large", "medium", "small", "tiny"]
                let pick = order.compactMap { k -> (String, [String: Any])? in v[k].map { (k, $0) } }
                    .first { _, r in
                        guard let s = r["url"] as? String, !s.isEmpty else { return false }
                        return ((r["height"] as? Int) ?? 0) <= 1080 && ((r["width"] as? Int) ?? 0) <= 1920
                    }
                    ?? order.compactMap { k -> (String, [String: Any])? in v[k].map { (k, $0) } }.first { ($0.1["url"] as? String)?.isEmpty == false }
                guard let (_, r) = pick, let u = (r["url"] as? String).flatMap(URL.init(string:)) else { return nil }
                let thumb = ((v["tiny"]?["thumbnail"] ?? v["small"]?["thumbnail"] ?? v["medium"]?["thumbnail"]) as? String)
                    .flatMap(URL.init(string:))
                    ?? (h["picture_id"] as? String).flatMap { URL(string: "https://i.vimeocdn.com/video/\($0)_295x166.jpg") }
                return Hit(id: id, isVideo: true, tags: tags, user: user, pageURL: page, thumbnailURL: thumb, downloadURL: u,
                           width: r["width"] as? Int ?? 0, height: r["height"] as? Int ?? 0, duration: h["duration"] as? Int)
            } else {
                guard let s = (h["largeImageURL"] as? String) ?? (h["webformatURL"] as? String), let u = URL(string: s) else { return nil }
                let thumb = ((h["webformatURL"] as? String) ?? (h["previewURL"] as? String)).flatMap(URL.init(string:))
                return Hit(id: id, isVideo: false, tags: tags, user: user, pageURL: page, thumbnailURL: thumb, downloadURL: u,
                           width: h["imageWidth"] as? Int ?? 0, height: h["imageHeight"] as? Int ?? 0, duration: nil)
            }
        }
        return Page(total: total, hits: hits)
    }

    public static func search(key: String, query: String, kind: Kind, page: Int = 1,
                              session: URLSession = .shared) async -> Result<Page, Failure> {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return .failure(.noKey) }
        guard let url = searchURL(key: k, query: query, kind: kind, page: page) else { return .failure(.decode) }
        do {
            let (data, resp) = try await session.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            switch code {
            case 200: break
            case 400 where String(data: data, encoding: .utf8)?.lowercased().contains("key") == true: return .failure(.badKey)
            case 401, 403: return .failure(.badKey)
            case 429: return .failure(.rateLimited)
            default: return .failure(.http(code))
            }
            return .success(try parse(data, video: kind == .video))
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    /// Local file name for a hit: stable, so a second "Add" reuses the downloaded file.
    public static func fileName(for hit: Hit) -> String {
        "pixabay-\(hit.isVideo ? "video" : "image")-\(hit.id).\(hit.fileExtension)"
    }

    /// Downloads `hit` into `folder` (or reuses an earlier download).
    public static func download(_ hit: Hit, into folder: URL, session: URLSession = .shared) async -> Result<URL, Failure> {
        let dest = folder.appendingPathComponent(fileName(for: hit))
        if let a = try? FileManager.default.attributesOfItem(atPath: dest.path), ((a[.size] as? NSNumber)?.intValue ?? 0) > 0 {
            return .success(dest)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (tmp, resp) = try await session.download(from: hit.downloadURL)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard code == 200 else { try? FileManager.default.removeItem(at: tmp); return .failure(.http(code)) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return .success(dest)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
