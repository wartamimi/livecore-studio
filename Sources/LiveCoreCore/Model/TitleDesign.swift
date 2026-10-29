/// Title Designer (0.34.0): template gallery plus vMix-style advanced settings for the title /
/// lower-third generator. Titles made from a template render on a transparent canvas the size of
/// the output, so a template can place itself anywhere (lower third, centre, corner). Older
/// titles without a design keep the 0.3.0 lower-third strip.
///
/// Geometry lives here (portable, unit tested); the macOS renderer measures the text with
/// CoreText, asks `TitleLayout` where everything goes, and draws it.

public enum TitleCategory: String, Codable, Sendable, CaseIterable {
    case lowerThird, title, corner
}

/// How a template is built from boxes and text.
public enum TitleKind: String, Codable, Sendable {
    /// One box behind title + subtitle (also pills and corner bugs).
    case strap
    /// Title box with a second-colour subtitle box under it.
    case twoTone
    /// Accent bar beside the text, optional box behind it.
    case accentLine
    /// Accent tag box (LIVE, BREAKING…) left of the title box, subtitle box under both.
    case news
    /// Text with an accent line under the title.
    case underline
    /// Bar across the whole canvas width.
    case fullBar
    /// Box over the whole canvas (full-screen title card), text on top.
    case card
}

public enum TitleAnchor: String, Codable, Sendable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    /// 0 = left, 0.5 = centre, 1 = right.
    public var horizontal: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: return 0
        case .top, .center, .bottom: return 0.5
        case .topRight, .right, .bottomRight: return 1
        }
    }

    /// 0 = top, 0.5 = middle, 1 = bottom.
    public var vertical: Double {
        switch self {
        case .topLeft, .top, .topRight: return 0
        case .left, .center, .right: return 0.5
        case .bottomLeft, .bottom, .bottomRight: return 1
        }
    }
}

public enum TitleAlign: String, Codable, Sendable, CaseIterable {
    case left, center, right
}

public enum TitleWeight: String, Codable, Sendable, CaseIterable {
    case light, regular, medium, semibold, bold, heavy
}

/// Every setting of a template-based title. Sizes and paddings are in points of a 1080-line
/// canvas (scaled to the real output); positions are fractions of the canvas.
public struct TitleDesign: Codable, Equatable, Sendable {
    public var template: TitleTemplate
    /// Label text for templates with a tag (LIVE, BREAKING NEWS…).
    public var tag: String = ""

    // Text
    /// Font family name; nil = system font.
    public var fontFamily: String?
    public var titleWeight: TitleWeight = .bold
    public var subtitleWeight: TitleWeight = .regular
    public var italic = false
    public var uppercase = false
    /// Extra letter spacing (points).
    public var tracking: Double = 0
    public var titleSize: Double = 54
    public var subtitleSize: Double = 32
    /// Space between title and subtitle (points).
    public var lineGap: Double = 6
    public var align: TitleAlign = .left
    public var titleColor = ProjectColor(r: 1, g: 1, b: 1)
    public var subtitleColor = ProjectColor(r: 1, g: 1, b: 1, a: 0.9)
    public var tagColor = ProjectColor(r: 1, g: 1, b: 1)

    // Boxes
    public var showBox = true
    public var boxColor = ProjectColor(r: 0.05, g: 0.27, b: 0.62, a: 0.9)
    /// Second box (subtitle box of two-tone and news templates, full-screen card background).
    public var box2Color = ProjectColor(r: 0.08, g: 0.08, b: 0.1, a: 0.85)
    /// Accent line / tag box.
    public var accentColor = ProjectColor(r: 0.93, g: 0.2, b: 0.2)
    public var cornerRadius: Double = 0
    /// Rounded ends (pill shape) regardless of `cornerRadius`.
    public var pill = false
    public var paddingX: Double = 28
    public var paddingY: Double = 14
    /// Minimum box width as a fraction of the canvas width (0 = fit the text).
    public var minWidth: Double = 0

    // Position
    public var anchor: TitleAnchor = .bottomLeft
    /// Safe margin from the canvas edge (fraction of width / height).
    public var marginX: Double = 0.06
    public var marginY: Double = 0.08
    /// Fine position (fraction of the canvas, −0.5…0.5).
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    /// Overall size (0.5…2).
    public var scale: Double = 1

    // Effects
    /// Text outline width (points); 0 = none.
    public var outlineWidth: Double = 0
    public var outlineColor = ProjectColor(r: 0, g: 0, b: 0)
    public var shadow = false
    public var shadowBlur: Double = 8
    public var shadowOffset: Double = 3
    public var shadowColor = ProjectColor(r: 0, g: 0, b: 0, a: 0.75)

    // Animation (0.35.0): how the title comes in and goes out when its overlay number is pressed.
    public var animation: OverlayAnimation = .fade
    /// Seconds (0.1…5).
    public var animationDuration: Double = 0.6
    /// true = use the overlay channel's own animation instead.
    public var useOverlayAnimation = false
    /// Letter-by-letter text animation (0.36.0), played each time the title goes on air.
    public var textAnimation: TextAnimation = .off
    /// Seconds between one letter and the next (0.01…0.3).
    public var letterDelay: Double = 0.04

    public init(template: TitleTemplate) { self.template = template }

    /// Values kept inside what the renderer and the editor allow.
    public func clamped() -> TitleDesign {
        var d = self
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
        d.tracking = c(tracking, -5, 30)
        d.titleSize = c(titleSize, 12, 300)
        d.subtitleSize = c(subtitleSize, 8, 200)
        d.lineGap = c(lineGap, -20, 100)
        d.cornerRadius = c(cornerRadius, 0, 100)
        d.paddingX = c(paddingX, 0, 200)
        d.paddingY = c(paddingY, 0, 200)
        d.minWidth = c(minWidth, 0, 1)
        d.marginX = c(marginX, 0, 0.4)
        d.marginY = c(marginY, 0, 0.4)
        d.offsetX = c(offsetX, -0.5, 0.5)
        d.offsetY = c(offsetY, -0.5, 0.5)
        d.scale = c(scale, 0.5, 2)
        d.outlineWidth = c(outlineWidth, 0, 20)
        d.shadowBlur = c(shadowBlur, 0, 60)
        d.shadowOffset = c(shadowOffset, -30, 30)
        d.animationDuration = c(animationDuration, 0.1, 5)
        d.letterDelay = c(letterDelay, 0.01, 0.3)
        if d.tag.count > 40 { d.tag = String(d.tag.prefix(40)) }
        return d
    }

    // Missing keys (designs saved by an older or newer version) fall back to the template's
    // defaults, so a project never fails to open over a title setting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? c.decode(TitleTemplate.self, forKey: .template)) ?? .classicStrap
        var d = t.defaultDesign
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        d.tag = v(.tag, d.tag)
        d.fontFamily = (try? c.decodeIfPresent(String.self, forKey: .fontFamily)) ?? nil
        d.titleWeight = v(.titleWeight, d.titleWeight)
        d.subtitleWeight = v(.subtitleWeight, d.subtitleWeight)
        d.italic = v(.italic, d.italic)
        d.uppercase = v(.uppercase, d.uppercase)
        d.tracking = v(.tracking, d.tracking)
        d.titleSize = v(.titleSize, d.titleSize)
        d.subtitleSize = v(.subtitleSize, d.subtitleSize)
        d.lineGap = v(.lineGap, d.lineGap)
        d.align = v(.align, d.align)
        d.titleColor = v(.titleColor, d.titleColor)
        d.subtitleColor = v(.subtitleColor, d.subtitleColor)
        d.tagColor = v(.tagColor, d.tagColor)
        d.showBox = v(.showBox, d.showBox)
        d.boxColor = v(.boxColor, d.boxColor)
        d.box2Color = v(.box2Color, d.box2Color)
        d.accentColor = v(.accentColor, d.accentColor)
        d.cornerRadius = v(.cornerRadius, d.cornerRadius)
        d.pill = v(.pill, d.pill)
        d.paddingX = v(.paddingX, d.paddingX)
        d.paddingY = v(.paddingY, d.paddingY)
        d.minWidth = v(.minWidth, d.minWidth)
        d.anchor = v(.anchor, d.anchor)
        d.marginX = v(.marginX, d.marginX)
        d.marginY = v(.marginY, d.marginY)
        d.offsetX = v(.offsetX, d.offsetX)
        d.offsetY = v(.offsetY, d.offsetY)
        d.scale = v(.scale, d.scale)
        d.outlineWidth = v(.outlineWidth, d.outlineWidth)
        d.outlineColor = v(.outlineColor, d.outlineColor)
        d.shadow = v(.shadow, d.shadow)
        d.shadowBlur = v(.shadowBlur, d.shadowBlur)
        d.shadowOffset = v(.shadowOffset, d.shadowOffset)
        d.shadowColor = v(.shadowColor, d.shadowColor)
        d.animation = v(.animation, d.animation)
        d.animationDuration = v(.animationDuration, d.animationDuration)
        d.useOverlayAnimation = v(.useOverlayAnimation, d.useOverlayAnimation)
        d.textAnimation = v(.textAnimation, d.textAnimation)
        d.letterDelay = v(.letterDelay, d.letterDelay)
        self = d.clamped()
    }
}

/// Built-in templates. Raw values are stored in project files.
public enum TitleTemplate: String, Codable, Sendable, CaseIterable {
    // Lower thirds
    case classicStrap, roundedStrap, twoTone, boxedName, accentLine, modernGlass
    case newsLive, minimalUnderline, pill, socialHandle, fullWidthBar, rightStrap
    // Titles
    case headline, fullScreenTitle, chapterCard, quote, endCard, breakingBanner
    // Corners
    case cornerBug, locationTag, liveBadge
    // 0.45.0
    case weddingScript, corporateSplit, cleanWhite, neonDark, outlineBold, goldBar, sportsBar
    case weddingCard, seminarTitle, sponsorCard
    case hashtagTag, sponsorBug

    public var category: TitleCategory {
        switch self {
        case .classicStrap, .roundedStrap, .twoTone, .boxedName, .accentLine, .modernGlass,
             .newsLive, .minimalUnderline, .pill, .socialHandle, .fullWidthBar, .rightStrap,
             .weddingScript, .corporateSplit, .cleanWhite, .neonDark, .outlineBold, .goldBar, .sportsBar:
            return .lowerThird
        case .headline, .fullScreenTitle, .chapterCard, .quote, .endCard, .breakingBanner,
             .weddingCard, .seminarTitle, .sponsorCard:
            return .title
        case .cornerBug, .locationTag, .liveBadge, .hashtagTag, .sponsorBug:
            return .corner
        }
    }

    public var kind: TitleKind {
        switch self {
        case .classicStrap, .roundedStrap, .modernGlass, .pill, .socialHandle, .rightStrap,
             .cornerBug, .locationTag, .liveBadge, .cleanWhite, .neonDark, .hashtagTag, .sponsorBug:
            return .strap
        case .twoTone, .boxedName, .corporateSplit, .sportsBar: return .twoTone
        case .accentLine, .weddingScript, .outlineBold, .goldBar: return .accentLine
        case .newsLive, .breakingBanner: return .news
        case .minimalUnderline, .chapterCard, .headline, .quote, .seminarTitle: return .underline
        case .weddingCard, .sponsorCard: return .card
        case .fullWidthBar: return .fullBar
        case .fullScreenTitle, .endCard: return .card
        }
    }

    /// Whether the template shows the tag field.
    public var usesTag: Bool { kind == .news }

    /// Sample text for the gallery and for a new title (English; the editor localises).
    public var sample: (title: String, subtitle: String, tag: String) {
        switch self {
        case .headline: return ("HEADLINE", "Supporting line", "")
        case .fullScreenTitle: return ("Event Title", "Subtitle · Date", "")
        case .chapterCard: return ("Chapter 1", "Introduction", "")
        case .quote: return ("“Make it simple.”", "— Speaker Name", "")
        case .endCard: return ("Thanks for watching", "See you next time", "")
        case .breakingBanner: return ("Breaking headline goes here", "More details", "BREAKING")
        case .newsLive: return ("Speaker Name", "Title / Organisation", "LIVE")
        case .socialHandle: return ("@yourchannel", "", "")
        case .cornerBug: return ("LiveCore", "", "")
        case .locationTag: return ("Jakarta", "", "")
        case .liveBadge: return ("● LIVE", "", "")
        case .weddingScript: return ("Rina & Dimas", "The Wedding · 12.12.2026", "")
        case .weddingCard: return ("Rina & Dimas", "Saturday, 12 December 2026", "")
        case .seminarTitle: return ("Digital Transformation 2026", "Keynote Session", "")
        case .sponsorCard: return ("Supported by", "Sponsor Name", "")
        case .hashtagTag: return ("#YourEvent2026", "", "")
        case .sponsorBug: return ("Presented by Sponsor", "", "")
        case .sportsBar: return ("HOME 2 - 1 AWAY", "2nd half · 67′", "")
        default: return ("Speaker Name", "Title / Organisation", "")
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> ProjectColor {
        ProjectColor(r: r, g: g, b: b, a: a)
    }

    /// In / out motion that suits the template (used when its overlay number is pressed).
    public var defaultAnimation: OverlayAnimation {
        switch self {
        case .classicStrap, .roundedStrap, .twoTone, .boxedName, .accentLine, .modernGlass, .newsLive, .pill, .chapterCard, .locationTag:
            return .slideFromLeft
        case .rightStrap, .socialHandle, .cornerBug:
            return .slideFromRight
        case .fullWidthBar, .breakingBanner:
            return .slideFromBottom
        case .headline, .liveBadge:
            return .zoom
        case .minimalUnderline, .fullScreenTitle, .quote, .endCard:
            return .fade
        case .weddingScript, .weddingCard, .seminarTitle, .cleanWhite, .goldBar:
            return .riseFade
        case .corporateSplit, .outlineBold, .sportsBar:
            return .nudgeLeft
        case .neonDark, .sponsorCard:
            return .zoomOut
        case .hashtagTag, .sponsorBug:
            return .pop
        }
    }

    public var defaultDesign: TitleDesign {
        var d = TitleDesign(template: self)
        d.tag = sample.tag
        d.animation = defaultAnimation
        d.animationDuration = category == .title ? 0.8 : 0.5
        let white = Self.rgb(1, 1, 1)
        switch self {
        case .classicStrap:
            break
        case .roundedStrap:
            d.cornerRadius = 14
            d.boxColor = Self.rgb(0.10, 0.11, 0.14, 0.9)
            d.minWidth = 0.3
        case .twoTone:
            d.boxColor = Self.rgb(0.85, 0.15, 0.2, 0.95)
            d.box2Color = Self.rgb(1, 1, 1, 0.95)
            d.subtitleColor = Self.rgb(0.1, 0.1, 0.12)
            d.paddingY = 10
        case .boxedName:
            d.boxColor = Self.rgb(1, 1, 1, 0.97)
            d.titleColor = Self.rgb(0.08, 0.08, 0.1)
            d.box2Color = Self.rgb(0.95, 0.65, 0.1, 0.97)
            d.subtitleColor = Self.rgb(0.08, 0.08, 0.1)
            d.uppercase = true
            d.tracking = 1.5
            d.titleWeight = .heavy
            d.subtitleWeight = .semibold
            d.paddingY = 10
        case .accentLine:
            d.showBox = false
            d.accentColor = Self.rgb(0.98, 0.75, 0.1)
            d.shadow = true
        case .modernGlass:
            d.boxColor = Self.rgb(0, 0, 0, 0.55)
            d.cornerRadius = 8
            d.titleWeight = .semibold
            d.subtitleWeight = .light
            d.minWidth = 0.28
        case .newsLive:
            d.boxColor = Self.rgb(0.06, 0.12, 0.3, 0.95)
            d.box2Color = Self.rgb(1, 1, 1, 0.95)
            d.subtitleColor = Self.rgb(0.06, 0.12, 0.3)
            d.accentColor = Self.rgb(0.85, 0.08, 0.1)
            d.titleWeight = .heavy
            d.paddingY = 8
        case .minimalUnderline:
            d.showBox = false
            d.shadow = true
            d.accentColor = Self.rgb(0.25, 0.55, 1)
            d.titleWeight = .semibold
        case .pill:
            d.pill = true
            d.paddingX = 40
            d.boxColor = Self.rgb(0.45, 0.25, 0.85, 0.92)
        case .socialHandle:
            d.pill = true
            d.paddingX = 34
            d.paddingY = 10
            d.titleSize = 40
            d.boxColor = Self.rgb(0.9, 0.2, 0.45, 0.92)
            d.anchor = .bottomRight
        case .fullWidthBar:
            d.minWidth = 1
            d.marginY = 0.06
            d.paddingX = 110
        case .rightStrap:
            d.anchor = .bottomRight
            d.align = .right
            d.boxColor = Self.rgb(0.0, 0.45, 0.4, 0.9)
        case .headline:
            d.showBox = false
            d.anchor = .center
            d.align = .center
            d.titleSize = 110
            d.subtitleSize = 44
            d.titleWeight = .heavy
            d.shadow = true
            d.shadowBlur = 14
            d.accentColor = Self.rgb(0.98, 0.75, 0.1)
            d.lineGap = 18
        case .fullScreenTitle:
            d.anchor = .center
            d.align = .center
            d.titleSize = 120
            d.subtitleSize = 46
            d.titleWeight = .heavy
            d.box2Color = Self.rgb(0.04, 0.06, 0.12, 0.92)
            d.lineGap = 16
        case .chapterCard:
            d.showBox = false
            d.anchor = .left
            d.titleSize = 96
            d.subtitleSize = 40
            d.titleWeight = .bold
            d.shadow = true
            d.accentColor = Self.rgb(0.2, 0.75, 0.45)
            d.lineGap = 16
        case .quote:
            d.showBox = false
            d.anchor = .center
            d.align = .center
            d.italic = true
            d.titleSize = 76
            d.subtitleSize = 36
            d.titleWeight = .medium
            d.shadow = true
            d.accentColor = Self.rgb(1, 1, 1, 0.6)
            d.lineGap = 22
        case .endCard:
            d.anchor = .center
            d.align = .center
            d.titleSize = 100
            d.subtitleSize = 42
            d.box2Color = Self.rgb(0.06, 0.05, 0.1, 0.95)
            d.lineGap = 16
        case .breakingBanner:
            d.minWidth = 1
            d.marginX = 0
            d.marginY = 0.05
            d.boxColor = Self.rgb(0.75, 0.05, 0.08, 0.96)
            d.box2Color = Self.rgb(0.05, 0.05, 0.08, 0.92)
            d.accentColor = Self.rgb(1, 0.85, 0.1)
            d.tagColor = Self.rgb(0.1, 0.05, 0.05)
            d.uppercase = true
            d.titleWeight = .heavy
            d.titleSize = 50
            d.subtitleColor = white
            d.paddingY = 10
        case .cornerBug:
            d.anchor = .topRight
            d.titleSize = 34
            d.cornerRadius = 6
            d.paddingX = 20
            d.paddingY = 8
            d.boxColor = Self.rgb(0, 0, 0, 0.45)
            d.titleWeight = .semibold
            d.marginY = 0.06
            d.marginX = 0.04
        case .locationTag:
            d.anchor = .topLeft
            d.pill = true
            d.titleSize = 32
            d.paddingX = 26
            d.paddingY = 8
            d.boxColor = Self.rgb(0.1, 0.55, 0.35, 0.92)
            d.marginY = 0.06
            d.marginX = 0.04
        case .liveBadge:
            d.anchor = .topLeft
            d.titleSize = 34
            d.cornerRadius = 4
            d.paddingX = 18
            d.paddingY = 6
            d.boxColor = Self.rgb(0.88, 0.08, 0.1, 0.97)
            d.titleWeight = .heavy
            d.tracking = 2
            d.marginY = 0.06
            d.marginX = 0.04
        case .weddingScript:
            d.showBox = false
            d.fontFamily = "Snell Roundhand"
            d.titleSize = 72
            d.subtitleSize = 28
            d.titleWeight = .regular
            d.subtitleWeight = .light
            d.tracking = 0.5
            d.accentColor = Self.rgb(0.85, 0.7, 0.4)
            d.shadow = true
            d.textAnimation = .fade
            d.letterDelay = 0.03
        case .corporateSplit:
            d.boxColor = Self.rgb(0.0, 0.32, 0.6, 0.96)
            d.box2Color = Self.rgb(0.93, 0.95, 0.97, 0.96)
            d.subtitleColor = Self.rgb(0.0, 0.25, 0.45)
            d.titleWeight = .semibold
            d.paddingY = 10
            d.cornerRadius = 4
        case .cleanWhite:
            d.boxColor = Self.rgb(1, 1, 1, 0.96)
            d.titleColor = Self.rgb(0.07, 0.07, 0.09)
            d.subtitleColor = Self.rgb(0.35, 0.35, 0.4)
            d.cornerRadius = 10
            d.titleWeight = .semibold
            d.minWidth = 0.26
            d.shadow = true
            d.shadowColor = Self.rgb(0, 0, 0, 0.35)
        case .neonDark:
            d.boxColor = Self.rgb(0.04, 0.04, 0.08, 0.88)
            d.titleColor = Self.rgb(0.35, 0.95, 1)
            d.subtitleColor = Self.rgb(1, 0.4, 0.85)
            d.cornerRadius = 6
            d.uppercase = true
            d.tracking = 2
            d.shadow = true
            d.shadowColor = Self.rgb(0.2, 0.85, 1, 0.7)
            d.shadowBlur = 16
            d.shadowOffset = 0
        case .outlineBold:
            d.showBox = false
            d.uppercase = true
            d.titleWeight = .heavy
            d.titleSize = 64
            d.outlineWidth = 3
            d.outlineColor = Self.rgb(0, 0, 0)
            d.accentColor = Self.rgb(1, 0.82, 0.1)
            d.textAnimation = .pop
        case .goldBar:
            d.showBox = false
            d.accentColor = Self.rgb(0.83, 0.68, 0.33)
            d.titleWeight = .medium
            d.subtitleColor = Self.rgb(0.95, 0.88, 0.7)
            d.tracking = 1
            d.shadow = true
        case .sportsBar:
            d.boxColor = Self.rgb(0.07, 0.09, 0.12, 0.95)
            d.box2Color = Self.rgb(0.95, 0.75, 0.05, 0.97)
            d.subtitleColor = Self.rgb(0.07, 0.07, 0.09)
            d.titleWeight = .heavy
            d.uppercase = true
            d.paddingY = 8
            d.anchor = .topLeft
        case .weddingCard:
            d.anchor = .center
            d.align = .center
            d.fontFamily = "Snell Roundhand"
            d.titleSize = 120
            d.subtitleSize = 40
            d.titleWeight = .regular
            d.subtitleWeight = .light
            d.box2Color = Self.rgb(0.98, 0.96, 0.92, 0.94)
            d.titleColor = Self.rgb(0.55, 0.42, 0.2)
            d.subtitleColor = Self.rgb(0.35, 0.3, 0.25)
            d.lineGap = 16
            d.textAnimation = .fade
            d.letterDelay = 0.035
        case .seminarTitle:
            d.showBox = false
            d.anchor = .left
            d.titleSize = 84
            d.subtitleSize = 38
            d.titleWeight = .heavy
            d.shadow = true
            d.accentColor = Self.rgb(0.0, 0.55, 0.95)
            d.lineGap = 14
        case .sponsorCard:
            d.anchor = .center
            d.align = .center
            d.titleSize = 48
            d.subtitleSize = 96
            d.titleWeight = .medium
            d.subtitleWeight = .heavy
            d.box2Color = Self.rgb(0.08, 0.08, 0.1, 0.92)
            d.lineGap = 12
        case .hashtagTag:
            d.anchor = .topRight
            d.pill = true
            d.titleSize = 32
            d.paddingX = 24
            d.paddingY = 8
            d.boxColor = Self.rgb(0.12, 0.45, 0.95, 0.92)
            d.titleWeight = .semibold
            d.marginY = 0.06
            d.marginX = 0.04
        case .sponsorBug:
            d.anchor = .bottomRight
            d.titleSize = 26
            d.cornerRadius = 6
            d.paddingX = 18
            d.paddingY = 6
            d.boxColor = Self.rgb(0, 0, 0, 0.5)
            d.titleWeight = .medium
            d.marginY = 0.05
            d.marginX = 0.04
        }
        return d
    }
}

// MARK: - Layout

public struct TitleRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    func offsetBy(_ dx: Double, _ dy: Double) -> TitleRect { TitleRect(x: x + dx, y: y + dy, width: width, height: height) }
}

public struct TitleSize: Equatable, Sendable {
    public var width: Double, height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    public static let zero = TitleSize(0, 0)
    var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Which colour fills a box.
public enum TitleFill: Equatable, Sendable { case box, box2, accent }
public enum TitleTextRole: Equatable, Sendable { case title, subtitle, tag }

public struct TitleBoxItem: Equatable, Sendable {
    public var rect: TitleRect
    public var fill: TitleFill
    public var radius: Double
}

public struct TitleTextItem: Equatable, Sendable {
    public var role: TitleTextRole
    /// Where the measured text goes (top-left origin, pixels).
    public var rect: TitleRect
}

public struct TitleLayoutResult: Equatable, Sendable {
    public var boxes: [TitleBoxItem] = []
    public var texts: [TitleTextItem] = []
}

public enum TitleLayout {
    /// Points of the 1080-line reference → pixels of this canvas (portrait canvases use width).
    public static func unit(_ d: TitleDesign, canvasWidth: Double, canvasHeight: Double) -> Double {
        min(canvasWidth, canvasHeight) / 1080 * d.scale
    }

    /// Places boxes and text for a design on a canvas (pixels, top-left origin). Text sizes are
    /// measured by the caller with the design's fonts at `unit` scale; `.zero` = no text.
    public static func layout(_ design: TitleDesign, canvasWidth W: Double, canvasHeight H: Double,
                              title: TitleSize, subtitle: TitleSize, tag: TitleSize = .zero) -> TitleLayoutResult {
        let d = design.clamped()
        let u = unit(d, canvasWidth: W, canvasHeight: H)
        let px = d.paddingX * u, py = d.paddingY * u
        let gap = subtitle.isEmpty || title.isEmpty ? 0 : d.lineGap * u
        let blockW = max(title.width, subtitle.width)
        let blockH = title.height + gap + subtitle.height
        let minW = d.minWidth * W
        var out = TitleLayoutResult()

        /// Position of a group of size (w, h) for the anchor, margins and offset.
        func place(_ w: Double, _ h: Double, fullWidth: Bool = false) -> (Double, Double) {
            let mx = fullWidth ? 0 : d.marginX * W, my = d.marginY * H
            let x = fullWidth ? 0 : mx + d.anchor.horizontal * max(W - 2 * mx - w, 0) + d.offsetX * W
            let y = my + d.anchor.vertical * max(H - 2 * my - h, 0) + d.offsetY * H
            return (x, y)
        }
        /// Text x inside a container.
        func tx(_ size: TitleSize, in x: Double, _ w: Double, pad: Double) -> Double {
            switch d.align {
            case .left: return x + pad
            case .center: return x + (w - size.width) / 2
            case .right: return x + w - pad - size.width
            }
        }
        func radius(_ h: Double) -> Double { d.pill ? h / 2 : d.cornerRadius * u }
        func text(_ role: TitleTextRole, _ s: TitleSize, _ x: Double, _ y: Double) {
            guard !s.isEmpty else { return }
            out.texts.append(TitleTextItem(role: role, rect: TitleRect(x: x, y: y, width: s.width, height: s.height)))
        }
        func box(_ r: TitleRect, _ f: TitleFill, _ rad: Double) {
            out.boxes.append(TitleBoxItem(rect: r, fill: f, radius: rad))
        }

        switch d.template.kind {
        case .strap, .fullBar:
            let full = d.template.kind == .fullBar || d.minWidth >= 1
            let w = full ? W : max(blockW + 2 * px, minW)
            let h = blockH + 2 * py
            let (x, y) = place(w, h, fullWidth: full)
            if d.showBox { box(TitleRect(x: x, y: y, width: w, height: h), .box, radius(h)) }
            text(.title, title, tx(title, in: x, w, pad: px), y + py)
            text(.subtitle, subtitle, tx(subtitle, in: x, w, pad: px), y + py + title.height + gap)

        case .twoTone:
            let tw = max(title.width + 2 * px, minW), th = title.height + 2 * py
            let sw = subtitle.isEmpty ? 0 : subtitle.width + 2 * px
            let sh = subtitle.isEmpty ? 0 : subtitle.height + 2 * py * 0.7
            let w = max(tw, sw), h = th + sh
            let (x, y) = place(w, h)
            // Both boxes line up on the aligned edge.
            func bx(_ bw: Double) -> Double {
                switch d.align {
                case .left: return x
                case .center: return x + (w - bw) / 2
                case .right: return x + w - bw
                }
            }
            let tr = TitleRect(x: bx(tw), y: y, width: tw, height: th)
            if d.showBox { box(tr, .box, radius(th)) }
            text(.title, title, tx(title, in: tr.x, tw, pad: px), y + py)
            if !subtitle.isEmpty {
                let sr = TitleRect(x: bx(sw), y: y + th, width: sw, height: sh)
                if d.showBox { box(sr, .box2, radius(sh)) }
                text(.subtitle, subtitle, tx(subtitle, in: sr.x, sw, pad: px), sr.y + py * 0.7)
            }

        case .accentLine:
            let bar = max(6 * u, 2)
            let inner = blockW + 2 * px
            let w = max(inner + bar, minW), h = blockH + 2 * py
            let (x, y) = place(w, h)
            let barX = d.align == .right ? x + w - bar : x
            let boxX = d.align == .right ? x : x + bar
            if d.showBox { box(TitleRect(x: boxX, y: y, width: w - bar, height: h), .box, d.cornerRadius * u) }
            box(TitleRect(x: barX, y: y, width: bar, height: h), .accent, 0)
            text(.title, title, tx(title, in: boxX, w - bar, pad: px), y + py)
            text(.subtitle, subtitle, tx(subtitle, in: boxX, w - bar, pad: px), y + py + title.height + gap)

        case .news:
            let full = d.minWidth >= 1
            let hasTag = !tag.isEmpty
            let tagW = hasTag ? tag.width + 2 * px * 0.6 : 0
            let rowH = max(title.height, tag.height) + 2 * py
            let mainW = title.width + 2 * px
            let sh = subtitle.isEmpty ? 0 : subtitle.height + 2 * py * 0.7
            let w = full ? W : max(tagW + mainW, subtitle.width + 2 * px, minW)
            let h = rowH + sh
            let (x, y) = place(w, h, fullWidth: full)
            if hasTag {
                box(TitleRect(x: x, y: y, width: tagW, height: rowH), .accent, d.cornerRadius * u)
                text(.tag, tag, x + (tagW - tag.width) / 2, y + (rowH - tag.height) / 2)
            }
            let mr = TitleRect(x: x + tagW, y: y, width: w - tagW, height: rowH)
            if d.showBox { box(mr, .box, d.cornerRadius * u) }
            text(.title, title, tx(title, in: mr.x, mr.width, pad: px), y + (rowH - title.height) / 2)
            if !subtitle.isEmpty {
                let sr = TitleRect(x: x, y: y + rowH, width: w, height: sh)
                if d.showBox { box(sr, .box2, 0) }
                text(.subtitle, subtitle, tx(subtitle, in: x, w, pad: px), sr.y + py * 0.7)
            }

        case .underline:
            let line = max(5 * u, 2)
            let lineGap = 8 * u
            let w = max(blockW, minW), h = title.height + lineGap + line + (subtitle.isEmpty ? 0 : lineGap + subtitle.height)
            let padX = d.showBox ? px : 0, padY = d.showBox ? py : 0
            let (x0, y0) = place(w + 2 * padX, h + 2 * padY)
            if d.showBox { box(TitleRect(x: x0, y: y0, width: w + 2 * padX, height: h + 2 * padY), .box, radius(h + 2 * padY)) }
            let x = x0 + padX, y = y0 + padY
            text(.title, title, tx(title, in: x, w, pad: 0), y)
            let lineW = min(max(title.width * 0.35, 60 * u), w)
            let lx: Double
            switch d.align {
            case .left: lx = x
            case .center: lx = x + (w - lineW) / 2
            case .right: lx = x + w - lineW
            }
            box(TitleRect(x: lx, y: y + title.height + lineGap, width: lineW, height: line), .accent, line / 2)
            text(.subtitle, subtitle, tx(subtitle, in: x, w, pad: 0), y + title.height + 2 * lineGap + line)

        case .card:
            if d.showBox { box(TitleRect(x: 0, y: 0, width: W, height: H), .box2, 0) }
            let (x, y) = place(blockW, blockH)
            text(.title, title, tx(title, in: x, blockW, pad: 0), y)
            text(.subtitle, subtitle, tx(subtitle, in: x, blockW, pad: 0), y + title.height + gap)
        }
        return out
    }
}

extension TitleDesign {
    /// The closest template design for a classic (0.3.0) title, used when it is opened in the
    /// Title Designer: bar on the left → Classic strap, full-width bar → Full-width bar,
    /// centred → Headline at the bottom.
    public static func fromClassic(layout: String?, showBar: Bool, textColor: ProjectColor, barColor: ProjectColor,
                                   titleSize: Double?, subtitleSize: Double?) -> TitleDesign {
        var d: TitleDesign
        switch layout {
        case "fullWidth":
            d = TitleTemplate.fullWidthBar.defaultDesign
        case "centered":
            d = TitleTemplate.headline.defaultDesign
            d.anchor = .bottom
            d.titleWeight = .bold
        default:
            d = TitleTemplate.classicStrap.defaultDesign
            d.minWidth = 0.62
        }
        d.showBox = layout == "centered" ? false : showBar
        d.titleColor = textColor
        d.subtitleColor = ProjectColor(r: textColor.r, g: textColor.g, b: textColor.b, a: textColor.a * 0.9)
        d.boxColor = barColor
        d.titleSize = titleSize ?? 54
        d.subtitleSize = subtitleSize ?? 34
        return d.clamped()
    }
}

/// Letter-by-letter animation of a title's text (vMix title "text effects").
public enum TextAnimation: String, Codable, Sendable, CaseIterable {
    case off
    /// Letters appear one after another.
    case typewriter
    /// Each letter fades in.
    case fade
    /// Each letter rises into place while fading in.
    case rise
    /// Each letter drops into place while fading in.
    case drop
    /// Each letter grows from small.
    case pop
    /// Each letter shrinks into place from large (0.45.0).
    case shrink
    /// Each letter drops in and bounces slightly (0.45.0).
    case bounce

    /// Seconds one letter takes to settle.
    public var letterDuration: Double {
        switch self {
        case .off, .typewriter: return 0
        case .fade: return 0.35
        case .rise, .drop: return 0.4
        case .pop: return 0.3
        case .shrink: return 0.35
        case .bounce: return 0.5
        }
    }
}

/// Timing of a letter-by-letter animation: letter `i` starts `i × delay` after the title goes on
/// air and settles over the animation's letter duration. Letters are counted over title, subtitle
/// and tag in that order.
public struct TextReveal: Equatable, Sendable {
    public var animation: TextAnimation
    public var delay: Double

    public init(animation: TextAnimation, delay: Double) {
        self.animation = animation
        self.delay = delay.isFinite ? min(max(delay, 0.01), 0.3) : 0.04
    }

    /// 0 = not shown yet, 1 = in place.
    public func progress(letter i: Int, at t: Double) -> Double {
        guard animation != .off else { return 1 }
        let start = Double(i) * delay
        let d = animation.letterDuration
        if d <= 0 { return t >= start ? 1 : 0 }
        return min(max((t - start) / d, 0), 1)
    }

    /// Seconds until the last of `letters` letters is in place.
    public func totalDuration(letters: Int) -> Double {
        guard animation != .off, letters > 0 else { return 0 }
        return Double(letters - 1) * delay + animation.letterDuration
    }

    /// Ease-out curve applied to movement and growth.
    public static func ease(_ p: Double) -> Double { 1 - (1 - p) * (1 - p) * (1 - p) }

    /// Vertical shift of a letter as a fraction of its font size (positive = up, CoreGraphics).
    public func offset(_ p: Double) -> Double {
        let e = Self.ease(p)
        switch animation {
        case .rise: return -0.45 * (1 - e)
        case .drop: return 0.45 * (1 - e)
        case .bounce:
            // Back ease-out from above: overshoots below its line, then settles.
            let c1 = 1.9, c3 = c1 + 1, m = min(max(p, 0), 1) - 1
            return 0.6 * (1 - (1 + c3 * m * m * m + c1 * m * m))
        default: return 0
        }
    }

    /// Scale of a letter (pop) and its opacity.
    public func scale(_ p: Double) -> Double {
        switch animation {
        case .pop: return 0.3 + 0.7 * Self.ease(p)
        case .shrink: return 1.9 - 0.9 * Self.ease(p)
        default: return 1
        }
    }
    public func opacity(_ p: Double) -> Double { animation == .typewriter ? (p > 0 ? 1 : 0) : p }
}
