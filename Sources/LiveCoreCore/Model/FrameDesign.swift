/// Camera frames (0.36.0): a designed background with a window the camera shows through, plus
/// name labels. A Frame input is drawn as two layers: the frame picture (output size, transparent
/// where the camera goes) and the chosen camera in the window, with rounded corners / circle and
/// border from `LayerStyle`. Used as an overlay over a full-screen camera, the window shows the
/// Program picture through.
///
/// Geometry lives here (portable, unit tested); the macOS renderer draws it with CoreGraphics.

public enum FrameTemplate: String, Codable, Sendable, CaseIterable {
    /// Thin white border around a large window.
    case clean
    /// Rounded window on a gradient, name under it.
    case rounded
    /// Round window (podcast / interview), name beside it.
    case circle
    /// White instant-photo card with a handwritten caption.
    case polaroid
    /// Glowing coloured outline on a dark background.
    case neon
    /// Broadcast corners and a LIVE name strap.
    case broadcast
    /// Portrait (9:16) window for phone footage, name beside it.
    case vertical
    /// Wide cinema bars with a caption.
    case cinema
    // 0.46.0: meeting & conference
    /// Corporate stage: large window left, event / speaker panel right, accent strip below.
    case conference
    /// Light, friendly meeting look: rounded window, name under it with an accent underline.
    case meeting
    /// Webinar: title block left, presenter window right.
    case webinar
    /// Keynote: centred window with a thin accent border, name strap under it.
    case keynote

    public var defaultDesign: FrameDesign {
        var d = FrameDesign(template: self)
        func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> ProjectColor { ProjectColor(r: r, g: g, b: b, a: a) }
        switch self {
        case .clean:
            d.background1 = rgb(0.10, 0.11, 0.13); d.background2 = rgb(0.04, 0.04, 0.05)
            d.accent = rgb(1, 1, 1); d.title = ""; d.subtitle = ""
        case .rounded:
            d.background1 = rgb(0.16, 0.22, 0.45); d.background2 = rgb(0.38, 0.13, 0.42)
            d.accent = rgb(1, 1, 1)
        case .circle:
            d.background1 = rgb(0.07, 0.09, 0.14); d.background2 = rgb(0.13, 0.17, 0.27)
            d.accent = rgb(0.98, 0.62, 0.15)
        case .polaroid:
            d.background1 = rgb(0.55, 0.42, 0.33); d.background2 = rgb(0.30, 0.22, 0.18)
            d.accent = rgb(0.98, 0.97, 0.94); d.textColor = rgb(0.15, 0.15, 0.18)
            d.title = "Good times"; d.subtitle = ""
        case .neon:
            d.background1 = rgb(0.03, 0.02, 0.08); d.background2 = rgb(0.06, 0.02, 0.12)
            d.accent = rgb(0.95, 0.2, 0.85)
        case .broadcast:
            d.background1 = rgb(0.06, 0.08, 0.12); d.background2 = rgb(0.02, 0.03, 0.05)
            d.accent = rgb(0.86, 0.1, 0.12); d.tag = "LIVE"
        case .vertical:
            d.background1 = rgb(0.12, 0.10, 0.25); d.background2 = rgb(0.03, 0.03, 0.08)
            d.accent = rgb(0.25, 0.85, 0.95)
        case .cinema:
            d.background1 = rgb(0, 0, 0); d.background2 = rgb(0, 0, 0)
            d.accent = rgb(0.95, 0.8, 0.45); d.subtitle = ""
        case .conference:
            d.background1 = rgb(0.03, 0.12, 0.28); d.background2 = rgb(0.01, 0.04, 0.10)
            d.accent = rgb(0.0, 0.62, 0.95)
            d.title = "Speaker Name"; d.subtitle = "Annual Conference 2026"
        case .meeting:
            d.background1 = rgb(0.94, 0.95, 0.97); d.background2 = rgb(0.84, 0.87, 0.92)
            d.accent = rgb(0.2, 0.45, 0.95); d.textColor = rgb(0.1, 0.12, 0.18)
            d.title = "Team Meeting"; d.subtitle = "Weekly update"
        case .webinar:
            d.background1 = rgb(0.09, 0.07, 0.2); d.background2 = rgb(0.02, 0.1, 0.18)
            d.accent = rgb(0.35, 0.85, 0.65)
            d.title = "Webinar Title"; d.subtitle = "Presenter Name"
        case .keynote:
            d.background1 = rgb(0.06, 0.06, 0.07); d.background2 = rgb(0.0, 0.0, 0.0)
            d.accent = rgb(0.95, 0.72, 0.2)
            d.title = "Speaker Name"; d.subtitle = "Keynote"
        }
        return d
    }
}

public struct FrameDesign: Codable, Equatable, Sendable {
    public var template: FrameTemplate
    public var title = "Your Name"
    public var subtitle = "Title or topic"
    /// Short tag (LIVE…) on the templates that show one.
    public var tag = ""
    /// Top and bottom of the background gradient.
    public var background1 = ProjectColor(r: 0.1, g: 0.1, b: 0.12)
    public var background2 = ProjectColor(r: 0.03, g: 0.03, b: 0.04)
    /// Border, glow, corners and strap colour.
    public var accent = ProjectColor(r: 1, g: 1, b: 1)
    public var textColor = ProjectColor(r: 1, g: 1, b: 1)
    /// Only the border, corners and labels (to lay over a full-screen camera).
    public var transparentBackground = false

    public init(template: FrameTemplate) { self.template = template }

    public var showsLabels: Bool { !title.isEmpty || !subtitle.isEmpty || (template.usesTag && !tag.isEmpty) }

    // Missing keys fall back to the template's defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = (try? c.decode(FrameTemplate.self, forKey: .template)) ?? .clean
        var d = t.defaultDesign
        func v<T: Decodable>(_ k: CodingKeys, _ cur: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? cur }
        d.title = v(.title, d.title)
        d.subtitle = v(.subtitle, d.subtitle)
        d.tag = v(.tag, d.tag)
        d.background1 = v(.background1, d.background1)
        d.background2 = v(.background2, d.background2)
        d.accent = v(.accent, d.accent)
        d.textColor = v(.textColor, d.textColor)
        d.transparentBackground = v(.transparentBackground, d.transparentBackground)
        self = d
    }
}

public extension FrameTemplate {
    var usesTag: Bool { self == .broadcast }
}

/// Where a frame's parts go on a canvas (normalised, origin top-left).
public struct FrameLayout: Equatable, Sendable {
    public enum Shape: Equatable, Sendable { case rectangle, ellipse }
    /// The window the camera shows through.
    public var camera: NormRect
    public var shape: Shape
    /// Corner radius as a fraction of the window's shorter side.
    public var cornerRadius: Double
    /// Border drawn by the compositor around the camera, as a fraction of the canvas height.
    public var border: Double
    /// White card behind the window (polaroid).
    public var card: NormRect?
    /// Name block: title over subtitle.
    public var label: NormRect?
    public var labelAlign: Align
    public enum Align: Equatable, Sendable { case left, center }

    /// `aspect` = canvas width / height (16:9 → 1.78; portrait canvases work too).
    public static func layout(_ t: FrameTemplate, aspect a0: Double) -> FrameLayout {
        let a = a0.isFinite && a0 > 0 ? a0 : 16.0 / 9.0
        switch t {
        case .clean:
            return FrameLayout(camera: NormRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), shape: .rectangle,
                               cornerRadius: 0, border: 0.004, card: nil, label: nil, labelAlign: .left)
        case .rounded:
            return FrameLayout(camera: NormRect(x: 0.06, y: 0.06, width: 0.88, height: 0.74), shape: .rectangle,
                               cornerRadius: 0.06, border: 0, card: nil,
                               label: NormRect(x: 0.06, y: 0.83, width: 0.88, height: 0.13), labelAlign: .left)
        case .circle:
            let h = 0.70, w = min(h / a, 0.9)
            return FrameLayout(camera: NormRect(x: max(0.30 - w / 2, 0.02), y: 0.15, width: w, height: h), shape: .ellipse,
                               cornerRadius: 0, border: 0.008, card: nil,
                               label: NormRect(x: 0.56, y: 0.36, width: 0.40, height: 0.28), labelAlign: .left)
        case .polaroid:
            let cardH = 0.86, cardW = min(cardH * 0.84 / a, 0.9)
            let card = NormRect(x: 0.5 - cardW / 2, y: 0.07, width: cardW, height: cardH)
            let pad = cardW * 0.07
            let camH = cardH * 0.70
            return FrameLayout(camera: NormRect(x: card.x + pad, y: card.y + pad * a, width: cardW - 2 * pad, height: camH),
                               shape: .rectangle, cornerRadius: 0, border: 0, card: card,
                               label: NormRect(x: card.x, y: card.y + pad * a + camH + 0.02, width: cardW,
                                               height: cardH - pad * a - camH - 0.04), labelAlign: .center)
        case .neon:
            return FrameLayout(camera: NormRect(x: 0.09, y: 0.08, width: 0.82, height: 0.78), shape: .rectangle,
                               cornerRadius: 0.04, border: 0.006, card: nil,
                               label: NormRect(x: 0.09, y: 0.885, width: 0.82, height: 0.09), labelAlign: .center)
        case .broadcast:
            return FrameLayout(camera: NormRect(x: 0.05, y: 0.06, width: 0.9, height: 0.74), shape: .rectangle,
                               cornerRadius: 0, border: 0, card: nil,
                               label: NormRect(x: 0.05, y: 0.83, width: 0.9, height: 0.12), labelAlign: .left)
        case .vertical:
            let h = 0.92, w = min(h * 9 / 16 / a, 0.9)
            return FrameLayout(camera: NormRect(x: 0.5 - w / 2, y: 0.04, width: w, height: h), shape: .rectangle,
                               cornerRadius: 0.05, border: 0.003, card: nil,
                               label: NormRect(x: 0.04, y: 0.40, width: max(0.5 - w / 2 - 0.07, 0.05), height: 0.2), labelAlign: .left)
        case .cinema:
            return FrameLayout(camera: NormRect(x: 0, y: 0.12, width: 1, height: 0.76), shape: .rectangle,
                               cornerRadius: 0, border: 0, card: nil,
                               label: NormRect(x: 0.05, y: 0.895, width: 0.9, height: 0.08), labelAlign: .center)
        case .conference:
            return FrameLayout(camera: NormRect(x: 0.03, y: 0.06, width: 0.68, height: 0.78), shape: .rectangle,
                               cornerRadius: 0.015, border: 0.003, card: nil,
                               label: NormRect(x: 0.745, y: 0.3, width: 0.235, height: 0.3), labelAlign: .left)
        case .meeting:
            return FrameLayout(camera: NormRect(x: 0.05, y: 0.05, width: 0.9, height: 0.76), shape: .rectangle,
                               cornerRadius: 0.04, border: 0, card: nil,
                               label: NormRect(x: 0.05, y: 0.835, width: 0.7, height: 0.12), labelAlign: .left)
        case .webinar:
            return FrameLayout(camera: NormRect(x: 0.42, y: 0.1, width: 0.55, height: 0.8), shape: .rectangle,
                               cornerRadius: 0.03, border: 0.004, card: nil,
                               label: NormRect(x: 0.04, y: 0.35, width: 0.35, height: 0.3), labelAlign: .left)
        case .keynote:
            return FrameLayout(camera: NormRect(x: 0.1, y: 0.05, width: 0.8, height: 0.78), shape: .rectangle,
                               cornerRadius: 0, border: 0.002, card: nil,
                               label: NormRect(x: 0.1, y: 0.86, width: 0.8, height: 0.11), labelAlign: .center)
        }
    }

    /// The camera layer's style (corners or circle, and the border in the accent colour).
    public func cameraStyle(accent: ProjectColor) -> LayerStyle {
        LayerStyle(shape: shape == .ellipse ? .ellipse : .rectangle, cornerRadius: cornerRadius,
                   borderWidth: border, borderColor: ChromaKey.RGB(r: accent.r, g: accent.g, b: accent.b))
    }
}
