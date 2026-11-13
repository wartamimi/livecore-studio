import Foundation

// AI Assistant 0.70.2: files and designs. The model can save what it writes (scripts, rundowns,
// subtitles, captions) as files, draw graphics as SVG (stills) or HTML (animated, transparent)
// that become inputs, and keep a title / running-text look as a .lctitle in My Templates.

public struct AIFileRequest: Equatable, Sendable {
    public var fileName: String
    public var content: String
}

public struct AIGraphicRequest: Equatable, Sendable {
    public enum Kind: String, Sendable { case svg, html }
    public var kind: Kind
    public var name: String
    public var fileName: String
    public var content: String
    public var overlay: Int?
}

extension AIAgent {
    public static let fileFormats = ["txt", "md", "csv", "srt", "vtt", "json", "html", "svg", "xml"]
    public static let maxFileBytes = 2_000_000

    /// A safe file name: no folders, no hidden files, at most 80 characters, with the extension.
    public static func safeFileName(_ raw: String, ext: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var s = String(raw.filter { !bad.contains($0) && !$0.isNewline })
        let dotExt = "." + ext
        if s.lowercased().hasSuffix(dotExt) { s.removeLast(dotExt.count) }
        while s.hasPrefix(".") || s.hasPrefix(" ") { s.removeFirst() }
        while s.hasSuffix(" ") || s.hasSuffix(".") { s.removeLast() }
        if s.isEmpty { s = "LiveCore AI" }
        if s.count > 80 { s = String(s.prefix(80)) }
        return s + dotExt
    }

    public static func fileRequest(from o: [String: Any]) -> Result<AIFileRequest, StepError> {
        var ext = (o["format"] as? String ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let name = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if ext.isEmpty, let dot = name.lastIndex(of: ".") { ext = String(name[name.index(after: dot)...]).lowercased() }
        guard fileFormats.contains(ext) else {
            return .failure(.init("format must be one of \(fileFormats.joined(separator: ", "))"))
        }
        guard let content = o["content"] as? String, !content.isEmpty else { return .failure(.init("content is missing")) }
        guard content.utf8.count <= maxFileBytes else { return .failure(.init("content is larger than 2 MB")) }
        return .success(AIFileRequest(fileName: safeFileName(name, ext: ext), content: content))
    }

    public static func graphicRequest(from o: [String: Any]) -> Result<AIGraphicRequest, StepError> {
        let name = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? "AI graphic" : String(name.prefix(60))
        var overlay: Int?
        if let v = o["overlay"], !(v is NSNull) {
            guard let n = intValue(v), (1...4).contains(n) else { return .failure(.init("overlay must be 1 to 4")) }
            overlay = n
        }
        if let svg = o["svg"] as? String, !svg.isEmpty {
            guard svg.range(of: "<svg", options: .caseInsensitive) != nil, svg.range(of: "</svg>", options: .caseInsensitive) != nil else {
                return .failure(.init("svg must be a whole <svg …>…</svg> document"))
            }
            guard svg.utf8.count <= maxFileBytes else { return .failure(.init("svg is larger than 2 MB")) }
            var doc = svg
            if !doc.contains("xmlns=") {
                doc = doc.replacingOccurrences(of: "<svg", with: "<svg xmlns=\"http://www.w3.org/2000/svg\"", options: .caseInsensitive,
                                               range: doc.range(of: "<svg", options: .caseInsensitive))
            }
            return .success(AIGraphicRequest(kind: .svg, name: display, fileName: safeFileName(display, ext: "svg"), content: doc, overlay: overlay))
        }
        if let html = o["html"] as? String, !html.isEmpty {
            guard html.utf8.count <= maxFileBytes else { return .failure(.init("html is larger than 2 MB")) }
            var doc = html
            if doc.range(of: "<html", options: .caseInsensitive) == nil {
                doc = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;width:1920px;height:1080px;background:transparent;overflow:hidden}</style></head><body>\n" + doc + "\n</body></html>"
            }
            return .success(AIGraphicRequest(kind: .html, name: display, fileName: safeFileName(display, ext: "html"), content: doc, overlay: overlay))
        }
        return .failure(.init("give svg (a still graphic) or html (an animated graphic)"))
    }

    /// A file name that is not taken yet in `folder` ("Name.svg", "Name 2.svg", …).
    public static func freeName(_ fileName: String, existing: Set<String>) -> String {
        guard existing.contains(fileName) else { return fileName }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var k = 2
        while existing.contains("\(base) \(k).\(ext)") { k += 1 }
        return "\(base) \(k).\(ext)"
    }

    static var fileTools: [[String: Any]] {
        [
            [
                "name": "save_file",
                "description": "Saves text you wrote as a file in the operator's Documents › LiveCore Studio › AI folder: scripts, rundowns, captions (txt / md), tables (csv), subtitles (srt / vtt), data (json / xml), web pages (html) or vector pictures (svg). Use it when the operator asks for a file, a document or to save / export something. Answers with the file's path.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "File name without folders"],
                        "format": ["type": "string", "enum": fileFormats],
                        "content": ["type": "string", "description": "The whole file content"],
                    ] as [String: Any],
                    "required": ["name", "format", "content"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "create_graphic",
                "description": """
                Designs a graphic and adds it as a new input (optionally loaded on an overlay channel, not \
                shown yet). Give either svg: a complete SVG document, viewBox="0 0 1920 1080", transparent \
                background unless a full-screen card is wanted, safe margins of 96 px, system fonts \
                (Helvetica Neue, Avenir Next, Georgia, SF Pro); good for logos, bugs, lower thirds, \
                scoreboards, frames, posters, slides, thank-you cards. Or html: a complete page \
                1920×1080 with a transparent body and CSS / JS animation (slide-in lower thirds, animated \
                countdowns, social handles, tickers, confetti); it runs as a Browser input. Make it look \
                professional: clear hierarchy, two or three colours, readable at a distance.
                """,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "svg": ["type": "string"],
                        "html": ["type": "string"],
                        "overlay": ["type": "integer", "minimum": 1, "maximum": 4],
                    ] as [String: Any],
                    "required": ["name"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "save_title_template",
                "description": "Saves the design of a title / lower-third or running-text input as a .lctitle template in My Templates, so it can be used again in any project.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "input": ["description": "Input number or name"],
                        "name": ["type": "string"],
                    ] as [String: Any],
                    "required": ["input", "name"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }
}
