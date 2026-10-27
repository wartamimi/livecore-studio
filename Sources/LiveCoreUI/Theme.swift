#if os(macOS)
import SwiftUI

/// Dark studio palette. Red = on air (Program), green = Preview, amber = warnings.
enum Theme {
    static let background = Color(red: 0.07, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.11, green: 0.115, blue: 0.13)
    static let panelRaised = Color(red: 0.15, green: 0.155, blue: 0.175)
    static let border = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.55)
    static let program = Color(red: 0.90, green: 0.16, blue: 0.16)
    static let preview = Color(red: 0.16, green: 0.75, blue: 0.35)
    static let accent = Color(red: 0.25, green: 0.55, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.15)
    static let meterGreen = Color(red: 0.2, green: 0.85, blue: 0.35)
    static let meterYellow = Color(red: 0.95, green: 0.82, blue: 0.2)
    static let meterRed = Color(red: 0.95, green: 0.2, blue: 0.2)
}

struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }
}

extension View {
    func panel() -> some View { modifier(PanelStyle()) }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textDim)
            .tracking(0.8)
    }
}

/// Big console-style button.
struct StudioButtonStyle: ButtonStyle {
    var color: Color = Theme.panelRaised
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(active ? color : (configuration.isPressed ? color.opacity(0.7) : Theme.panelRaised))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? color : Theme.border, lineWidth: active ? 2 : 1))
    }
}
#endif
