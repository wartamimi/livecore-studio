#if os(macOS)
import SwiftUI

/// Studio palette. Red = on air (Program), green = Preview, amber = warnings.
/// 0.62.0: the colours come from the theme chosen in Settings › Appearance.
enum Theme {
    static private(set) var palette = ThemePalette(AppearanceSettings.load())
    static func apply(_ a: AppearanceSettings) { palette = ThemePalette(a) }

    static var background: Color { palette.background }
    static var panel: Color { palette.panel }
    static var panelRaised: Color { palette.panelRaised }
    static var border: Color { palette.border }
    static var text: Color { palette.text }
    static var textDim: Color { palette.textDim }
    static var program: Color { palette.program }
    static var preview: Color { palette.preview }
    static var accent: Color { palette.accent }
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.15)
    /// Overlay buttons: waiting on Preview (orange) / on Program (green).
    static let overlayPreview = Color(red: 1.0, green: 0.55, blue: 0.10)
    static var overlayProgram: Color { palette.preview }
    static let meterGreen = Color(red: 0.2, green: 0.85, blue: 0.35)
    static let meterYellow = Color(red: 0.95, green: 0.82, blue: 0.2)
    static let meterRed = Color(red: 0.95, green: 0.2, blue: 0.2)
    static var panelHover: Color { palette.panelHover }
    /// "All" filter and inputs without a colour label: a dark light grey (0.55.0).
    static let labelAll = Color(red: 0.44, green: 0.45, blue: 0.48)
    /// Panel corner radius (Appearance › Corners).
    static var corner: CGFloat { palette.corner }
    /// Corner of raised items inside a panel (tiles, mixer strips, buttons).
    static var cardCorner: CGFloat { palette.corner > 4 ? 8 : 2 }
    /// Bright edge of glass surfaces (0.73.0 glass look).
    static var highlight: Color { Color.white.opacity(0.26) }
    /// Edge of glass: bright at the top, faint at the bottom, like light on a pane.
    static var glassEdge: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.07)], startPoint: .top, endPoint: .bottom)
    }
    /// Soft light falling from the top of a surface.
    static var sheen: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.0)], startPoint: .top, endPoint: .bottom)
    }
}

/// Settings › Appearance (0.62.0), kept in user preferences (not in projects).
public struct AppearanceSettings: Codable, Equatable, Hashable {
    public enum ThemeChoice: String, Codable, CaseIterable { case studio, midnight, oled, graphite, ember, forest, contrast }
    public enum AccentChoice: String, Codable, CaseIterable { case theme, blue, purple, pink, orange, teal, green }
    public enum TallyChoice: String, Codable, CaseIterable { case classic, colorSafe }
    public enum DockLayout: String, Codable, CaseIterable { case classic, inputsRight, inputsBottom, mixerRight, stage, compact }

    public var theme: ThemeChoice = .studio
    public var accent: AccentChoice = .theme
    public var tally: TallyChoice = .classic
    public var layout: DockLayout = .classic
    public var roundedPanels = true
    /// Animated logo when the app opens (0.72.0).
    public var splash = true

    public init() {}

    static let key = "appearance.v1"

    public static func load() -> AppearanceSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let a = try? JSONDecoder().decode(AppearanceSettings.self, from: d) else { return AppearanceSettings() }
        return a
    }

    public func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decode(ThemeChoice.self, forKey: .theme)) ?? .studio
        accent = (try? c.decode(AccentChoice.self, forKey: .accent)) ?? .theme
        tally = (try? c.decode(TallyChoice.self, forKey: .tally)) ?? .classic
        layout = (try? c.decode(DockLayout.self, forKey: .layout)) ?? .classic
        roundedPanels = (try? c.decode(Bool.self, forKey: .roundedPanels)) ?? true
        splash = (try? c.decode(Bool.self, forKey: .splash)) ?? true
    }
}

/// The colours of one theme.
struct ThemePalette {
    var background, panel, panelRaised, panelHover, border, text, textDim, program, preview, accent: Color
    var corner: CGFloat

    init(_ a: AppearanceSettings) {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        // background, panel, raised, hover, theme accent
        let base: (Color, Color, Color, Color, Color)
        switch a.theme {
        case .studio: base = (rgb(0.07, 0.075, 0.085), rgb(0.11, 0.115, 0.13), rgb(0.15, 0.155, 0.175), rgb(0.21, 0.215, 0.24), rgb(0.25, 0.55, 1.0))
        case .midnight: base = (rgb(0.04, 0.06, 0.11), rgb(0.07, 0.10, 0.17), rgb(0.10, 0.14, 0.23), rgb(0.15, 0.20, 0.31), rgb(0.35, 0.62, 1.0))
        case .oled: base = (rgb(0, 0, 0), rgb(0.05, 0.05, 0.055), rgb(0.10, 0.10, 0.11), rgb(0.16, 0.16, 0.17), rgb(0.30, 0.58, 1.0))
        case .graphite: base = (rgb(0.13, 0.13, 0.135), rgb(0.18, 0.18, 0.185), rgb(0.23, 0.23, 0.235), rgb(0.29, 0.29, 0.30), rgb(0.55, 0.60, 0.70))
        case .ember: base = (rgb(0.09, 0.065, 0.06), rgb(0.14, 0.10, 0.09), rgb(0.19, 0.14, 0.12), rgb(0.26, 0.19, 0.16), rgb(1.0, 0.55, 0.25))
        case .forest: base = (rgb(0.05, 0.08, 0.07), rgb(0.08, 0.12, 0.10), rgb(0.11, 0.17, 0.14), rgb(0.16, 0.23, 0.19), rgb(0.30, 0.80, 0.55))
        case .contrast: base = (rgb(0, 0, 0), rgb(0.08, 0.08, 0.08), rgb(0.16, 0.16, 0.16), rgb(0.26, 0.26, 0.26), rgb(1.0, 0.85, 0.0))
        }
        background = base.0; panel = base.1; panelRaised = base.2; panelHover = base.3
        border = Color.white.opacity(a.theme == .contrast ? 0.35 : (a.theme == .oled ? 0.12 : 0.08))
        text = Color.white.opacity(a.theme == .contrast ? 1 : 0.92)
        textDim = Color.white.opacity(a.theme == .contrast ? 0.78 : 0.55)
        switch a.accent {
        case .theme: accent = base.4
        case .blue: accent = rgb(0.25, 0.55, 1.0)
        case .purple: accent = rgb(0.62, 0.45, 1.0)
        case .pink: accent = rgb(1.0, 0.40, 0.70)
        case .orange: accent = rgb(1.0, 0.55, 0.20)
        case .teal: accent = rgb(0.20, 0.78, 0.80)
        case .green: accent = rgb(0.30, 0.80, 0.45)
        }
        // Colour-safe tally: Program stays red-orange, Preview becomes blue (red/green look alike
        // to many people with colour-vision deficiency).
        program = a.tally == .colorSafe ? rgb(0.95, 0.35, 0.10) : rgb(0.90, 0.16, 0.16)
        preview = a.tally == .colorSafe ? rgb(0.20, 0.55, 1.0) : rgb(0.16, 0.75, 0.35)
        corner = a.roundedPanels ? 11 : 2
    }
}

/// Docked panel (0.73.0 glass look, like macOS): the window backdrop shows through a blurred
/// pane tinted with the theme's panel colour, with a thin bright edge and a soft shadow. The pane
/// is the background of the content, so live video inside is never blurred or re-rendered.
struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        content
            .clipShape(shape)
            .background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Theme.panel.opacity(0.50)))
                    .overlay(shape.fill(Theme.sheen))
                    .shadow(color: Color.black.opacity(0.30), radius: 10, y: 4)
            )
            .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
    }
}

/// Raised item on a glass panel: input tile, mixer strip, card. A lighter pane of glass (no blur
/// of its own, there can be dozens); `glow` lights its edge (tally).
struct CardStyle: ViewModifier {
    var stroke: Color
    var lineWidth: CGFloat
    var glow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
        content
            .clipShape(shape)
            .background(
                shape.fill(Theme.panelRaised.opacity(0.55))
                    .overlay(shape.fill(Theme.sheen))
                    .shadow(color: glow ? stroke.opacity(0.6) : Color.black.opacity(0.22), radius: glow ? 7 : 3, y: glow ? 0 : 2)
            )
            .overlay(shape.strokeBorder(stroke, lineWidth: lineWidth))
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
    func card(stroke: Color = Color.white.opacity(0.14), lineWidth: CGFloat = 1, glow: Bool = false) -> some View {
        modifier(CardStyle(stroke: stroke, lineWidth: lineWidth, glow: glow))
    }
}

/// Window background behind the glass: the theme colour with soft pools of the accent and the
/// tally colours, which the panels blur.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.42), Color.clear], center: UnitPoint(x: 0.08, y: 0.0), startRadius: 0, endRadius: 720)
            RadialGradient(colors: [Theme.program.opacity(0.20), Color.clear], center: UnitPoint(x: 1.0, y: 0.25), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Theme.preview.opacity(0.16), Color.clear], center: UnitPoint(x: 0.35, y: 1.05), startRadius: 0, endRadius: 680)
            LinearGradient(colors: [Color.clear, Color.black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.textDim)
            .tracking(0.9)
    }
}

/// Big console-style button.
struct StudioButtonStyle: ButtonStyle {
    /// Width shared by the big labelled buttons (RECORD, STREAM, EXTERNAL, FULLSCREEN, PHOTO).
    static let mainWidth: CGFloat = 148
    var color: Color = Theme.panelRaised
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        StudioButtonBody(configuration: configuration, color: color, active: active)
    }
}

/// Body of `StudioButtonStyle`: a glass key that brightens on hover, dips when pressed and
/// glows in its colour while active (0.73.0).
private struct StudioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    let active: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
        let pressed = configuration.isPressed
        let lit = hovering && enabled
        let fill: Color = active ? color.opacity(0.92) : Color.white.opacity(lit ? 0.17 : 0.085)
        let shadowColor: Color = active ? color.opacity(0.55) : Color.black.opacity(pressed ? 0.05 : 0.22)
        let shadowRadius: CGFloat = active ? 8 : (pressed ? 1 : 3)
        let shadowY: CGFloat = (active || pressed) ? 0 : 2
        let edge: Color = active ? Color.white.opacity(0.45) : Color.white.opacity(lit ? 0.38 : 0.20)
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            // Always one line ("FULLSCREEN" must not wrap); shrinks a little instead.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(Theme.text)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                shape.fill(fill)
                    .overlay(shape.fill(Theme.sheen).opacity(pressed ? 0.3 : 1))
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
            )
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
#endif
