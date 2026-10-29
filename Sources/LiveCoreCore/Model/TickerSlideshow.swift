/// Scrolling text (news ticker / running text) shown in a band at the bottom of the picture.
public struct TickerConfig: Codable, Equatable, Sendable {
    public var text: String
    /// Scroll speed in pixels per second at 1080p (scaled with the output height).
    public var speed: Double
    /// Text size in points at 1080p.
    public var fontSize: Double
    public var textColor: ProjectColor
    public var barColor: ProjectColor
    public var showBar: Bool
    /// Band height as a fraction of the picture height.
    public var bandHeight: Double
    /// Plain-text file whose contents replace `text`, re-read when the file changes (since 0.18.0).
    public var textFilePath: String?
    /// Scroll direction (since 0.19.0; nil = right to left).
    public var direction: TickerDirection?
    /// RSS / Atom feed whose item titles replace `text` (since 0.19.0). Takes priority over the file.
    public var feedURL: String?
    /// Minutes between feed refreshes (nil = 5).
    public var feedRefreshMinutes: Double?

    // Advanced (0.35.0, Title Designer › Running text). nil = the earlier look.
    public var template: TickerTemplate?
    /// Fixed label at the left of the band (BREAKING, INFO…); empty / nil = none.
    public var label: String?
    public var labelColor: ProjectColor?
    public var labelTextColor: ProjectColor?
    public var fontFamily: String?
    public var weight: TitleWeight?
    public var italic: Bool?
    public var uppercase: Bool?
    /// Placed between items (lines); nil = "•".
    public var separator: String?
    public var separatorColor: ProjectColor?
    /// Top of the band as a fraction of the picture height; nil = near the bottom.
    public var bandY: Double?
    public var shadow: Bool?
    /// In / out motion when shown with an overlay number; nil = the overlay's own setting.
    public var animation: OverlayAnimation?
    public var animationDuration: Double?

    public var labelText: String { Self.trim(label ?? "") }
    public var separatorText: String { separator ?? "•" }
    public var textWeight: TitleWeight { weight ?? .semibold }

    public var scrollDirection: TickerDirection { direction ?? .rightToLeft }
    public var feedRefreshSeconds: Double { min(max(feedRefreshMinutes ?? 5, 1), 120) * 60 }

    public init(text: String, speed: Double = 120, fontSize: Double = 44,
                textColor: ProjectColor = ProjectColor(r: 1, g: 1, b: 1),
                barColor: ProjectColor = ProjectColor(r: 0.6, g: 0.05, b: 0.05, a: 0.9),
                showBar: Bool = true, bandHeight: Double = 0.08) {
        self.text = text; self.speed = speed; self.fontSize = fontSize; self.textColor = textColor
        self.barColor = barColor; self.showBar = showBar; self.bandHeight = bandHeight
    }

    public static let speedRange: ClosedRange<Double> = 20...600
    public var clamped: TickerConfig {
        var c = self
        c.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        c.fontSize = min(max(fontSize, 12), 120)
        c.bandHeight = min(max(bandHeight, 0.04), 0.25)
        if let y = bandY { c.bandY = min(max(y.isFinite ? y : 0, 0), 1 - c.bandHeight) }
        if let d = animationDuration { c.animationDuration = min(max(d.isFinite ? d : 0.5, 0.1), 5) }
        if let l = label, l.count > 30 { c.label = String(l.prefix(30)) }
        if let s = separator, s.count > 8 { c.separator = String(s.prefix(8)) }
        return c
    }

    /// Normalised layer rectangle of the band (near the bottom unless `bandY` says otherwise).
    public var layerRect: NormRect {
        let c = clamped
        return NormRect(x: 0, y: c.bandY ?? (1 - c.bandHeight - 0.04), width: 1, height: c.bandHeight)
    }

    static func trim(_ s: String) -> String {
        var t = Substring(s)
        while let f = t.first, f == " " || f == "\t" { t.removeFirst() }
        while let l = t.last, l == " " || l == "\t" { t.removeLast() }
        return String(t)
    }

    /// Items joined with the separator, as scrolled.
    public var scrollText: String {
        let items = text.split(whereSeparator: { $0.isNewline }).map { Self.trim(String($0)) }.filter { !$0.isEmpty }
        let joined = items.joined(separator: "   \(separatorText)   ")
        return (uppercase ?? false) ? joined.uppercased() : joined
    }
}

/// Running-text styles offered in the Title Designer.
public enum TickerTemplate: String, Codable, Sendable, CaseIterable {
    case newsRed, breakingYellow, darkLabel, blueInfo, minimal, topBand
    // 0.46.0: wedding greetings / couple names
    case weddingGold, weddingBlush

    public func config(text: String) -> TickerConfig {
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> ProjectColor { ProjectColor(r: r, g: g, b: b, a: a) }
        var c = TickerConfig(text: text)
        c.template = self
        c.animation = .slideFromBottom
        c.animationDuration = 0.5
        switch self {
        case .newsRed:
            c.barColor = rgb(0.6, 0.05, 0.05, 0.92)
            c.label = "NEWS"
            c.labelColor = rgb(1, 1, 1)
            c.labelTextColor = rgb(0.6, 0.05, 0.05)
            c.weight = .semibold
        case .breakingYellow:
            c.barColor = rgb(0.05, 0.05, 0.08, 0.92)
            c.label = "BREAKING"
            c.labelColor = rgb(1, 0.82, 0.1)
            c.labelTextColor = rgb(0.08, 0.05, 0.02)
            c.uppercase = true
            c.weight = .bold
            c.separatorColor = rgb(1, 0.82, 0.1)
        case .darkLabel:
            c.barColor = rgb(0.08, 0.09, 0.12, 0.88)
            c.label = "INFO"
            c.labelColor = rgb(0.25, 0.55, 1)
            c.labelTextColor = rgb(1, 1, 1)
            c.separatorColor = rgb(0.25, 0.55, 1)
        case .blueInfo:
            c.barColor = rgb(0.05, 0.25, 0.6, 0.92)
            c.weight = .medium
            c.separator = "|"
            c.separatorColor = rgb(1, 1, 1, 0.6)
        case .minimal:
            c.showBar = false
            c.shadow = true
            c.weight = .semibold
            c.animation = .fade
        case .topBand:
            c.barColor = rgb(0, 0, 0, 0.7)
            c.bandY = 0.03
            c.bandHeight = 0.06
            c.fontSize = 34
            c.label = "LIVE"
            c.labelColor = rgb(0.88, 0.08, 0.1)
            c.labelTextColor = rgb(1, 1, 1)
            c.animation = .slideFromTop
        case .weddingGold:
            c.barColor = rgb(0.99, 0.96, 0.9, 0.9)
            c.textColor = rgb(0.42, 0.32, 0.14)
            c.label = "♥ Rina & Dimas"
            c.labelColor = rgb(0.8, 0.65, 0.35)
            c.labelTextColor = rgb(1, 1, 1)
            c.fontFamily = "Didot"
            c.italic = true
            c.weight = .regular
            c.separator = "❦"
            c.separatorColor = rgb(0.8, 0.65, 0.35)
            c.speed = 90
            c.animation = .fade
            c.animationDuration = 0.8
        case .weddingBlush:
            c.barColor = rgb(0.95, 0.8, 0.8, 0.88)
            c.textColor = rgb(0.38, 0.14, 0.18)
            c.label = "Happy Wedding"
            c.labelColor = rgb(0.6, 0.25, 0.32)
            c.labelTextColor = rgb(1, 0.95, 0.95)
            c.fontFamily = "Snell Roundhand"
            c.fontSize = 48
            c.weight = .regular
            c.separator = "♥"
            c.separatorColor = rgb(0.6, 0.25, 0.32)
            c.speed = 90
            c.animation = .riseFade
            c.animationDuration = 0.8
        }
        return c
    }
}

public enum TickerDirection: String, Codable, Sendable, CaseIterable {
    case rightToLeft, leftToRight
}

public enum TickerMath {
    /// X position (pixels) of the text strip's left edge at `elapsed` seconds: it enters at one
    /// edge of the view, leaves at the other, and starts again (one copy on screen at a time).
    /// Right to left (default) enters on the right; left to right enters on the left.
    public static func offset(elapsed: Double, speed: Double, stripWidth: Double, viewWidth: Double,
                              direction: TickerDirection = .rightToLeft) -> Double {
        let cycle = stripWidth + viewWidth
        guard cycle > 0, speed > 0 else { return direction == .rightToLeft ? viewWidth : -stripWidth }
        var d = (elapsed * speed).truncatingRemainder(dividingBy: cycle)
        if d < 0 { d += cycle }
        return direction == .rightToLeft ? viewWidth - d : d - stripWidth
    }
}

/// Item titles of an RSS 2.0 / RSS 1.0 / Atom feed, without Foundation (small tolerant scanner,
/// not a validating XML parser). The channel / feed title itself is skipped.
public enum FeedTitles {
    public static func parse(_ xml: String, limit: Int = 30) -> [String] {
        let s = Array(xml.unicodeScalars)
        var titles: [String] = []
        var i = 0
        var inItem = false
        func matches(_ tag: String, at p: Int) -> Bool {
            let t = Array(tag.unicodeScalars)
            guard p + t.count <= s.count else { return false }
            for k in 0..<t.count where lower(s[p + k]) != t[k] { return false }
            // Tag name must end here (so <items> or <titles> do not match).
            let e = p + t.count
            return e >= s.count || [" ", ">", "/", "\t", "\n", "\r"].contains(Character(s[e]))
        }
        while i < s.count, titles.count < limit {
            guard s[i] == "<" else { i += 1; continue }
            if matches("<item", at: i) || matches("<entry", at: i) { inItem = true; i += 1; continue }
            if matches("</item", at: i) || matches("</entry", at: i) { inItem = false; i += 1; continue }
            if inItem, matches("<title", at: i) {
                // Skip the start tag's attributes.
                var j = i
                while j < s.count, s[j] != ">" { j += 1 }
                if j > i, s[j - 1] == "/" { i = j + 1; continue }   // <title/>
                let start = j + 1
                var end = start
                while end < s.count, !matches("</title", at: end) {
                    if matches("<![cdata[", at: end) {   // CDATA may contain "</title"-like text
                        end += 9
                        while end + 2 < s.count, !(s[end] == "]" && s[end + 1] == "]" && s[end + 2] == ">") { end += 1 }
                        end += 3
                    } else { end += 1 }
                }
                guard end <= s.count else { break }
                let text = clean(String(String.UnicodeScalarView(s[start..<min(end, s.count)])))
                if !text.isEmpty { titles.append(text) }
                i = end + 1
                inItem = true
                continue
            }
            i += 1
        }
        return titles
    }

    private static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (c.value >= 65 && c.value <= 90) ? Unicode.Scalar(c.value + 32)! : c
    }

    /// CDATA unwrapped, tags removed, entities decoded, whitespace collapsed.
    static func clean(_ raw: String) -> String {
        // Unwrap CDATA sections.
        let c = Array(raw)
        let open = Array("<![CDATA["), close = Array("]]>")
        func at(_ p: Int, _ n: [Character]) -> Bool { p + n.count <= c.count && Array(c[p..<p + n.count]) == n }
        var t = ""
        var i = 0
        while i < c.count {
            if at(i, open) {
                i += open.count
                while i < c.count, !at(i, close) { t.append(c[i]); i += 1 }
                i += close.count
            } else { t.append(c[i]); i += 1 }
        }
        // Remove tags (a title may contain <b>…</b> after CDATA).
        var noTags = ""
        var depth = false
        for ch in t { if ch == "<" { depth = true } else if ch == ">" && depth { depth = false } else if !depth { noTags.append(ch) } }
        let decoded = decodeEntities(noTags)
        return decoded.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).joined(separator: " ")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                switch name {
                case "amp": rep = "&"
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "quot": rep = "\""
                case "apos": rep = "'"
                case "nbsp": rep = " "
                default:
                    if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                        rep = String(Character(u))
                    } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) {
                        rep = String(Character(u))
                    }
                }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

/// Photo slideshow: images shown in order for `interval` seconds with a cross-fade.
public struct ProjectSlideshow: Codable, Equatable, Sendable {
    public var images: [ProjectMediaRef]
    public var interval: Double
    public var fade: Double
    public var loop: Bool
    /// Slow zoom and pan on each photo (since 0.18.0).
    public var kenBurns: Bool?
    /// Folder the photos came from; new or removed photos there are picked up while running (since 0.18.0).
    public var folder: ProjectMediaRef?
    /// Fit, transition and frame (0.45.0; nil = fit + cross-fade, as before).
    public var look: SlideshowLook?
    public init(images: [ProjectMediaRef], interval: Double = 5, fade: Double = 1, loop: Bool = true,
                kenBurns: Bool? = nil, folder: ProjectMediaRef? = nil) {
        self.images = images; self.interval = interval; self.fade = fade; self.loop = loop
        self.kenBurns = kenBurns; self.folder = folder
    }
}

/// How a slideshow places and changes its photos (0.45.0).
public struct SlideshowLook: Codable, Equatable, Sendable {
    public enum Fit: String, Codable, Sendable, CaseIterable {
        /// Whole photo, bars around it.
        case fit
        /// Fills the frame, edges cropped.
        case fill
        /// Whole photo over a blurred, enlarged copy of itself (no black bars).
        case blurFill
    }
    public enum Transition: String, Codable, Sendable, CaseIterable {
        case crossfade
        /// The next photo pushes in from the right.
        case slide
        /// The next photo grows slightly while fading in.
        case zoomFade
        /// Fades to the background colour, then up into the next photo.
        case dipToColor
    }
    public enum Frame: String, Codable, Sendable, CaseIterable {
        case none
        /// White border with a thicker bottom edge, slightly tilted (photo print).
        case polaroid
        /// Rounded corners with a soft shadow, inset from the edges.
        case rounded
    }
    public var fit: Fit = .fit
    public var transition: Transition = .crossfade
    public var frame: Frame = .none
    /// "#RRGGBB" background.
    public var backgroundHex: String = "#000000"
    public init() {}
    public init(fit: Fit, transition: Transition, frame: Frame = .none, backgroundHex: String = "#000000") {
        self.fit = fit; self.transition = transition; self.frame = frame; self.backgroundHex = backgroundHex
    }
}

/// Ready-made slideshow set-ups (0.45.0): look plus timing.
public struct SlideshowTemplate: Equatable, Sendable {
    public var id: String
    public var look: SlideshowLook
    public var interval: Double
    public var fade: Double
    public var kenBurns: Bool
    public var loop: Bool

    public static let all: [SlideshowTemplate] = [
        .init(id: "wedding", look: .init(fit: .blurFill, transition: .crossfade), interval: 6, fade: 1.5, kenBurns: true, loop: true),
        .init(id: "photobooth", look: .init(fit: .fit, transition: .slide, frame: .polaroid, backgroundHex: "#1E1B24"),
              interval: 4, fade: 0.6, kenBurns: false, loop: true),
        .init(id: "gallery", look: .init(fit: .fit, transition: .zoomFade, frame: .rounded, backgroundHex: "#111317"),
              interval: 5, fade: 0.8, kenBurns: false, loop: true),
        .init(id: "fullscreen", look: .init(fit: .fill, transition: .crossfade), interval: 5, fade: 1, kenBurns: true, loop: true),
        .init(id: "memorial", look: .init(fit: .blurFill, transition: .dipToColor), interval: 8, fade: 2, kenBurns: true, loop: true),
        .init(id: "party", look: .init(fit: .fill, transition: .slide), interval: 2.5, fade: 0.4, kenBurns: false, loop: true),
        .init(id: "corporate", look: .init(fit: .fit, transition: .crossfade, frame: .none, backgroundHex: "#0B1A33"),
              interval: 7, fade: 0.8, kenBurns: false, loop: true),
    ]
}

public enum SlideshowMath {
    public struct Position: Equatable, Sendable {
        /// Image shown (fading out while `mix` > 0).
        public var index: Int
        /// Image fading in, nil when no fade is running.
        public var next: Int?
        /// 0...1 progress of the fade into `next`.
        public var mix: Double
        /// True once a non-looping show has reached its last image.
        public var finished: Bool
    }

    /// Ken Burns motion progress (0...1) of the shown image and of the one fading in, `within`
    /// seconds into the current slot. Each image moves from the start of its fade-in to the end of
    /// its fade-out, so the motion carries on without a jump when the next image takes over.
    public static func motionProgress(within: Double, interval: Double, fade: Double) -> (current: Double, next: Double) {
        let iv = max(interval, 0.5)
        let fd = min(max(fade, 0), iv * 0.9)
        let span = iv + fd
        let cur = min(max((within + fd) / span, 0), 1)
        let nxt = min(max((within - (iv - fd)) / span, 0), 1)
        return (cur, nxt)
    }

    /// Part of image `index` (normalised, origin top-left) shown at motion `progress`: even images
    /// zoom in, odd ones zoom out (100 % ↔ 115 %), each drifting toward a different corner.
    public static func kenBurnsRect(progress: Double, index: Int) -> NormRect {
        let p = min(max(progress, 0), 1)
        let zoom = index % 2 == 0 ? 1 + 0.15 * p : 1.15 - 0.15 * p
        let w = 1 / zoom
        let dirs: [(Double, Double)] = [(1, 1), (-1, 1), (1, -1), (-1, -1)]
        let d = dirs[((index % 4) + 4) % 4]
        let travel = (1 - w) / 2 * (2 * p - 1)
        let cx = 0.5 + d.0 * travel, cy = 0.5 + d.1 * travel
        return NormRect(x: cx - w / 2, y: cy - w / 2, width: w, height: w)
    }

    /// Where the show is after `elapsed` seconds. Each image is shown for `interval` seconds
    /// (fade included); the fade into the next image takes the last `fade` seconds of that.
    public static func position(elapsed: Double, count: Int, interval: Double, fade: Double, loop: Bool) -> Position {
        guard count > 0 else { return Position(index: 0, next: nil, mix: 0, finished: true) }
        let iv = max(interval, 0.5)
        let fd = min(max(fade, 0), iv * 0.9)
        let t = max(elapsed, 0)
        var slot = Int((t / iv).rounded(.down))
        let within = t - Double(slot) * iv
        if !loop && slot >= count - 1 { return Position(index: count - 1, next: nil, mix: 0, finished: true) }
        slot %= count
        let next = (slot + 1) % count
        if count > 1, fd > 0, within > iv - fd {
            return Position(index: slot, next: next, mix: min(1, (within - (iv - fd)) / fd), finished: false)
        }
        return Position(index: slot, next: nil, mix: 0, finished: false)
    }
}

/// Fade between songs of a music input: each song fades in over its first `fade` seconds and
/// out over its last `fade` seconds (the songs do not overlap).
public enum MusicFade {
    public static let range: ClosedRange<Double> = 0...10

    public static func gain(position: Double, duration: Double?, fade: Double) -> Double {
        let f = min(max(fade, 0), range.upperBound)
        guard f > 0 else { return 1 }
        var g = min(max(position / f, 0), 1)
        if let d = duration, d > 0 {
            // Short songs: never fade for more than a third of the song at either end.
            let fe = min(f, d / 3)
            g = min(min(max(position / fe, 0), 1), min(max((d - position) / fe, 0), 1))
        }
        return g
    }
}
