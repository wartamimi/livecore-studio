/// LiveCore title template file (0.64.0): `.lctitle`, a zip with `template.json` (this type) and
/// `assets/fonts/` (font files the template uses that are not part of macOS). Holds one title /
/// lower third / corner design or one running-text style, with its sample text, so a look can be
/// shared between projects and Macs. JSON keeps it readable; unknown or missing settings fall back
/// to defaults (see `TitleDesign` / `TickerConfig` decoding), so newer and older versions open it.
public struct TitlePackage: Codable, Equatable, Sendable {
    public static let fileExtension = "lctitle"
    public static let jsonName = "template.json"
    public static let fontsFolder = "assets/fonts"
    /// Format written by this version; files with a higher number still open (best effort).
    public static let currentFormat = 1

    public enum Kind: String, Codable, Sendable { case title, ticker }

    public var format: Int
    public var name: String
    public var kind: Kind
    public var title: String?
    public var subtitle: String?
    public var design: TitleDesign?
    public var ticker: TickerConfig?
    /// Font file names inside `assets/fonts/`.
    public var fonts: [String]
    /// App that wrote the file ("LiveCore Studio 0.64.0"), for information only.
    public var app: String?

    public init(name: String, title: String, subtitle: String, design: TitleDesign) {
        format = Self.currentFormat; self.name = name; kind = .title
        self.title = title; self.subtitle = subtitle; self.design = design.clamped(); fonts = []
    }

    public init(name: String, ticker: TickerConfig) {
        format = Self.currentFormat; self.name = name; kind = .ticker
        var c = ticker.clamped
        c.textFilePath = nil   // a path on this Mac means nothing elsewhere
        self.ticker = c; fonts = []
    }

    /// Font families the template asks for.
    public var fontFamilies: [String] {
        [design?.fontFamily, ticker?.fontFamily].compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// Usable content: a title package needs a design, a running-text package a style.
    public var isValid: Bool { kind == .title ? design != nil : ticker != nil }

    /// File name for the template name (characters macOS / zip dislike removed).
    public static func fileName(for name: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var s = String(name.filter { !bad.contains($0) && !$0.isNewline })
        while s.hasPrefix(".") || s.hasPrefix(" ") { s.removeFirst() }
        while s.hasSuffix(" ") { s.removeLast() }
        if s.isEmpty { s = "Template" }
        if s.count > 80 { s = String(s.prefix(80)) }
        return s + "." + fileExtension
    }

    /// Only plain file names are accepted for fonts (no folders, no "..").
    public static func isSafeAssetName(_ n: String) -> Bool {
        !n.isEmpty && !n.contains("/") && !n.contains("\\") && n != "." && n != ".." && !n.hasPrefix(".")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decodeIfPresent(Int.self, forKey: .format)) ?? 1
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Template"
        design = try? c.decodeIfPresent(TitleDesign.self, forKey: .design)
        ticker = try? c.decodeIfPresent(TickerConfig.self, forKey: .ticker)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? (ticker != nil && design == nil ? .ticker : .title)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        fonts = ((try? c.decodeIfPresent([String].self, forKey: .fonts)) ?? []).filter(Self.isSafeAssetName)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        ticker?.textFilePath = nil
    }
}
