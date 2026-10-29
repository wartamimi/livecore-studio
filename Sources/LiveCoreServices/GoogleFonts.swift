import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Finds free fonts on Google Fonts for titles whose font is not installed (0.40.0). The CSS API
/// answers non-browser clients with direct .ttf links; an unknown family answers HTTP 400.
public enum GoogleFonts {
    /// CSS URLs to try, most complete first: regular, bold and italic styles, then the default style only.
    public static func cssURLs(family: String) -> [URL] {
        let name = family.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "+")
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) else { return [] }
        return ["https://fonts.googleapis.com/css2?family=\(name):ital,wght@0,400;0,700;1,400;1,700",
                "https://fonts.googleapis.com/css2?family=\(name)"].compactMap(URL.init(string:))
    }

    /// The font file links in a CSS answer (https only, .ttf / .otf), without duplicates.
    public static func fontURLs(css: String) -> [URL] {
        var out: [URL] = []
        var rest = css[...]
        while let r = rest.range(of: "url(") {
            rest = rest[r.upperBound...]
            guard let end = rest.firstIndex(of: ")") else { break }
            let raw = rest[..<end].trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            if let u = URL(string: raw), u.scheme == "https", ["ttf", "otf"].contains(u.pathExtension.lowercased()),
               !out.contains(u) { out.append(u) }
            rest = rest[end...]
        }
        return out
    }

    public enum Result: Equatable, Sendable {
        case installed([URL])     // files saved in the folder
        case notOnGoogleFonts
        case failed(String)
    }

    /// Downloads the family's files into `folder`. The caller registers them with CoreText.
    public static func download(family: String, into folder: URL, session: URLSession = .shared) async -> Result {
        do {
            var css: String?
            for u in cssURLs(family: family) {
                let (data, resp) = try await session.data(from: u)
                if (resp as? HTTPURLResponse)?.statusCode == 200 { css = String(decoding: data, as: UTF8.self); break }
            }
            guard let css else { return .notOnGoogleFonts }
            let links = fontURLs(css: css)
            guard !links.isEmpty else { return .notOnGoogleFonts }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safe = family.filter { $0.isLetter || $0.isNumber }
            var saved: [URL] = []
            for (i, link) in links.enumerated() {
                let (data, resp) = try await session.data(from: link)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
                let dest = folder.appendingPathComponent("\(safe)-\(i).\(link.pathExtension.lowercased())")
                try data.write(to: dest, options: .atomic)
                saved.append(dest)
            }
            return saved.isEmpty ? .failed("no font file could be downloaded") : .installed(saved)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
