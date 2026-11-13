/// Virtual Set input (0.59.0): a drawn studio (original artwork, generated in code) with one or
/// two keyed talent cameras standing in it, plus an optional input shown on the studio screen.
///
/// The input is drawn as layers: layer 0 is the studio picture, then the screen input, then the
/// talents. Talents use their own chroma key. Where a template has a desk or lectern, the talent
/// layer is cut at the desk top (crop), so the desk in the picture appears in front of them.
/// Geometry lives here so it is unit tested on Linux; the macOS renderer draws the studios.

public enum VirtualSetTemplate: String, Codable, Sendable, CaseIterable {
    case newsDesk, talkShow, corporateStage, weddingHall, techNeon, sportsCenter
    case seminarPodium, minimalWhite, citySkyline, debateStage, podcastStudio, goldGala

    /// Where a talent stands: centre x, bottom of the camera box, its height (fractions of the
    /// canvas at the wide shot) and the desk top that hides the lower part (nil = no desk).
    public struct Spot: Equatable, Sendable {
        public var cx: Double, bottom: Double, height: Double, desk: Double?
        public init(cx: Double, bottom: Double, height: Double, desk: Double? = nil) {
            self.cx = cx; self.bottom = bottom; self.height = height; self.desk = desk
        }
    }

    public var spots: [Spot] {
        switch self {
        case .newsDesk: return [Spot(cx: 0.56, bottom: 0.98, height: 0.80, desk: 0.70)]
        case .talkShow: return [Spot(cx: 0.30, bottom: 1.0, height: 0.70), Spot(cx: 0.70, bottom: 1.0, height: 0.70)]
        case .corporateStage: return [Spot(cx: 0.28, bottom: 1.02, height: 0.86)]
        case .weddingHall: return [Spot(cx: 0.5, bottom: 1.02, height: 0.84)]
        case .techNeon: return [Spot(cx: 0.38, bottom: 0.98, height: 0.80, desk: 0.72)]
        case .sportsCenter: return [Spot(cx: 0.34, bottom: 0.98, height: 0.80, desk: 0.70)]
        case .seminarPodium: return [Spot(cx: 0.72, bottom: 1.0, height: 0.76, desk: 0.66)]
        case .minimalWhite: return [Spot(cx: 0.5, bottom: 1.02, height: 0.88)]
        case .citySkyline: return [Spot(cx: 0.5, bottom: 0.98, height: 0.80, desk: 0.72)]
        case .debateStage: return [Spot(cx: 0.24, bottom: 1.0, height: 0.72, desk: 0.68), Spot(cx: 0.76, bottom: 1.0, height: 0.72, desk: 0.68)]
        case .podcastStudio: return [Spot(cx: 0.30, bottom: 0.98, height: 0.74, desk: 0.74), Spot(cx: 0.70, bottom: 0.98, height: 0.74, desk: 0.74)]
        case .goldGala: return [Spot(cx: 0.5, bottom: 1.02, height: 0.84)]
        }
    }

    /// Studio screen (normalised, top-left origin) that can show another input; nil = none.
    public var screen: NormRect? {
        switch self {
        case .newsDesk: return NormRect(x: 0.05, y: 0.15, width: 0.30, height: 0.30)
        case .talkShow: return NormRect(x: 0.38, y: 0.10, width: 0.24, height: 0.24)
        case .corporateStage: return NormRect(x: 0.52, y: 0.12, width: 0.42, height: 0.42)
        case .techNeon: return NormRect(x: 0.62, y: 0.14, width: 0.32, height: 0.32)
        case .sportsCenter: return NormRect(x: 0.56, y: 0.12, width: 0.38, height: 0.38)
        case .seminarPodium: return NormRect(x: 0.05, y: 0.10, width: 0.48, height: 0.48)
        case .debateStage: return NormRect(x: 0.38, y: 0.10, width: 0.24, height: 0.24)
        case .citySkyline, .weddingHall, .minimalWhite, .podcastStudio, .goldGala: return nil
        }
    }

    /// Default text on the set (logo wall, screen frame…).
    public var sampleText: String {
        switch self {
        case .newsDesk: return "NEWS 24"
        case .talkShow: return "TALK TONIGHT"
        case .corporateStage: return "ANNUAL MEETING 2026"
        case .weddingHall: return "Rina & Dimas"
        case .techNeon: return "TECH LIVE"
        case .sportsCenter: return "SPORTS CENTER"
        case .seminarPodium: return "NATIONAL SEMINAR"
        case .minimalWhite: return ""
        case .citySkyline: return "CITY TONIGHT"
        case .debateStage: return "THE DEBATE"
        case .podcastStudio: return "ON AIR"
        case .goldGala: return "GALA NIGHT"
        }
    }

    /// Accent colour of the template (lights, desk trims, logo).
    public var defaultAccent: ProjectColor {
        func c(_ r: Double, _ g: Double, _ b: Double) -> ProjectColor { ProjectColor(r: r, g: g, b: b) }
        switch self {
        case .newsDesk: return c(0.1, 0.45, 1)
        case .talkShow: return c(1, 0.55, 0.2)
        case .corporateStage: return c(0.15, 0.6, 0.95)
        case .weddingHall: return c(0.85, 0.68, 0.38)
        case .techNeon: return c(0.2, 1, 0.9)
        case .sportsCenter: return c(1, 0.35, 0.1)
        case .seminarPodium: return c(0.2, 0.5, 0.9)
        case .minimalWhite: return c(0.75, 0.78, 0.82)
        case .citySkyline: return c(0.55, 0.35, 1)
        case .debateStage: return c(0.85, 0.12, 0.15)
        case .podcastStudio: return c(1, 0.25, 0.45)
        case .goldGala: return c(0.95, 0.75, 0.3)
        }
    }

    public var defaultDesign: VirtualSetDesign {
        var d = VirtualSetDesign(template: self)
        d.accent = defaultAccent
        d.text = sampleText
        return d
    }
}

/// Camera framing of the whole set.
public enum VirtualSetShot: String, Codable, Sendable, CaseIterable {
    case wide, medium, close
    public var zoom: Double {
        switch self {
        case .wide: return 1
        case .medium: return 1.35
        case .close: return 1.8
        }
    }
}

public struct VirtualSetDesign: Codable, Equatable, Sendable {
    public var template: VirtualSetTemplate
    public var shot: VirtualSetShot = .wide
    public var accent = ProjectColor(r: 0.1, g: 0.45, b: 1)
    /// Name on the logo wall / screen frame.
    public var text = ""
    /// Talent inputs (raw input ids), one per spot; extra ones are ignored.
    public var talents: [String] = []
    /// Input shown on the studio screen (raw id), nil = the screen shows the set's own artwork.
    public var screenInput: String?
    /// Talent size (0.5…1.6), and fine position (fractions of the canvas, −0.3…0.3).
    public var talentScale: Double = 1
    public var talentOffsetX: Double = 0
    public var talentOffsetY: Double = 0
    /// Hide the talent's lower part behind the desk / lectern.
    public var deskCut = true
    /// Turn on the green-screen key of a talent input that has none when it is put in the set.
    public var autoKey = true

    public init(template: VirtualSetTemplate) { self.template = template }

    public var clamped: VirtualSetDesign {
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
        var d = self
        d.talentScale = c(talentScale, 0.5, 1.6)
        d.talentOffsetX = c(talentOffsetX, -0.3, 0.3)
        d.talentOffsetY = c(talentOffsetY, -0.3, 0.3)
        if d.text.count > 40 { d.text = String(d.text.prefix(40)) }
        if d.talents.count > template.spots.count { d.talents = Array(d.talents.prefix(template.spots.count)) }
        return d
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? c.decode(VirtualSetTemplate.self, forKey: .template)) ?? .newsDesk
        var d = t.defaultDesign
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        d.shot = v(.shot, d.shot)
        d.accent = v(.accent, d.accent)
        d.text = v(.text, d.text)
        d.talents = v(.talents, d.talents)
        d.screenInput = (try? c.decodeIfPresent(String.self, forKey: .screenInput)) ?? nil
        d.talentScale = v(.talentScale, d.talentScale)
        d.talentOffsetX = v(.talentOffsetX, d.talentOffsetX)
        d.talentOffsetY = v(.talentOffsetY, d.talentOffsetY)
        d.deskCut = v(.deskCut, d.deskCut)
        d.autoKey = v(.autoKey, d.autoKey)
        self = d.clamped
    }
}

/// Where everything of a virtual set goes for one design and canvas.
public struct VirtualSetPlacement: Equatable, Sendable {
    public struct Talent: Equatable, Sendable {
        public var rect: NormRect
        /// Fraction of the camera picture cut from the bottom (behind the desk).
        public var cropBottom: Double
    }
    /// The studio is drawn scaled by `zoom` with the visible window starting at (originX, originY).
    public var zoom: Double
    public var originX: Double
    public var originY: Double
    public var talents: [Talent]
    public var screen: NormRect?

    /// Maps a point of the wide studio to the canvas.
    public func map(x: Double, y: Double) -> (x: Double, y: Double) { ((x - originX) * zoom, (y - originY) * zoom) }
    public func map(_ r: NormRect) -> NormRect {
        let p = map(x: r.x, y: r.y)
        return NormRect(x: p.x, y: p.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// - Parameters:
    ///   - aspect: canvas width / height.
    ///   - cameraAspect: aspect of the talent cameras (16:9).
    public static func place(_ d0: VirtualSetDesign, aspect: Double, cameraAspect: Double = 16.0 / 9.0) -> VirtualSetPlacement {
        let d = d0.clamped
        let spots = d.template.spots
        let z = d.shot.zoom
        let fx = spots.map(\.cx).reduce(0, +) / Double(max(spots.count, 1)) + d.talentOffsetX
        let fy = spots.map { $0.bottom - $0.height * 0.75 }.reduce(0, +) / Double(max(spots.count, 1)) + d.talentOffsetY
        func origin(_ f: Double) -> Double { min(max(f - 0.5 / z, 0), 1 - 1 / z) }
        var p = VirtualSetPlacement(zoom: z, originX: origin(fx), originY: origin(fy), talents: [], screen: nil)
        p.screen = d.template.screen.map { p.map($0) }
        let a = aspect > 0 ? aspect : 16.0 / 9.0
        for s in spots {
            let h = s.height * d.talentScale
            let w = h * cameraAspect / a
            let bottom = s.bottom + d.talentOffsetY
            var r = NormRect(x: s.cx + d.talentOffsetX - w / 2, y: bottom - h, width: w, height: h)
            var cut = 0.0
            if d.deskCut, let desk = s.desk, bottom > desk {
                cut = min((bottom - desk) / h, 0.45)
                r.height = h * (1 - cut)
            }
            p.talents.append(Talent(rect: p.map(r), cropBottom: cut))
        }
        return p
    }
}
