#if os(macOS)
import SwiftUI
import LiveCoreCore

/// Settings › Appearance (0.62.0): themes, accent colour, tally colours, panel corners and
/// ready-made dock layouts. Changes apply at once (no Apply needed) so they can be previewed.
struct AppearanceSettingsView: View {
    @EnvironmentObject var model: AppModel

    private var a: Binding<AppearanceSettings> { $model.appearance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(L10n.t("appearance.theme")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(AppearanceSettings.ThemeChoice.allCases, id: \.self) { t in themeCard(t) }
                    }
                }
                section(L10n.t("appearance.accent")) {
                    HStack(spacing: 12) {
                        ForEach(AppearanceSettings.AccentChoice.allCases, id: \.self) { c in accentDot(c) }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 5)
                }
                section(L10n.t("appearance.layout")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(AppearanceSettings.DockLayout.allCases, id: \.self) { l in layoutCard(l) }
                    }
                }
                section(L10n.t("appearance.more")) {
                    Toggle(L10n.t("appearance.tally_safe"), isOn: Binding(get: { a.wrappedValue.tally == .colorSafe },
                                                                         set: { a.wrappedValue.tally = $0 ? .colorSafe : .classic }))
                    Text(L10n.t("appearance.tally_safe_help")).font(.caption).foregroundStyle(Theme.textDim)
                    Toggle(L10n.t("appearance.rounded"), isOn: a.roundedPanels)
                    Toggle(L10n.t("appearance.splash"), isOn: a.splash)
                }
                HStack {
                    Spacer()
                    Button(L10n.t("appearance.reset")) { model.appearance = AppearanceSettings() }
                        .disabled(model.appearance == AppearanceSettings())
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 6)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            c()
        }
    }

    private func themeCard(_ t: AppearanceSettings.ThemeChoice) -> some View {
        var probe = model.appearance
        probe.theme = t
        probe.accent = .theme
        let p = ThemePalette(probe)
        let on = model.appearance.theme == t
        return Button { a.wrappedValue.theme = t } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    p.background
                    HStack(spacing: 3) {
                        p.panel.frame(width: 18)
                        VStack(spacing: 3) {
                            HStack(spacing: 3) {
                                p.panelRaised.overlay(Rectangle().stroke(p.preview, lineWidth: 1.5))
                                p.panelRaised.overlay(Rectangle().stroke(p.program, lineWidth: 1.5))
                            }
                            p.panel.overlay(alignment: .leading) { p.accent.frame(width: 22, height: 4).padding(4) }
                        }
                    }
                    .padding(5)
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(L10n.t("appearance.theme.\(t.rawValue)")).font(.caption).lineLimit(1)
            }
            .padding(6)
            .background(on ? Theme.accent.opacity(0.2) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func accentDot(_ c: AppearanceSettings.AccentChoice) -> some View {
        var probe = model.appearance
        probe.accent = c
        let col = ThemePalette(probe).accent
        let on = model.appearance.accent == c
        return Button { a.wrappedValue.accent = c } label: {
            Circle().fill(col).frame(width: 24, height: 24)
                .padding(3)
                .overlay(Circle().stroke(Color.white.opacity(on ? 0.95 : 0), lineWidth: 2))
                .contentShape(Circle())
                .overlay { if c == .theme { Image(systemName: "wand.and.stars").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
        }
        .buttonStyle(.plain)
        .help(L10n.t("appearance.accent.\(c.rawValue)"))
    }

    private func layoutCard(_ l: AppearanceSettings.DockLayout) -> some View {
        let on = model.appearance.layout == l
        return Button { a.wrappedValue.layout = l } label: {
            VStack(alignment: .leading, spacing: 6) {
                LayoutSketch(layout: l).frame(height: 70)
                Text(L10n.t("appearance.layout.\(l.rawValue)")).font(.caption.weight(.semibold)).lineLimit(1)
                Text(L10n.t("appearance.layout.\(l.rawValue).help")).font(.caption2).foregroundStyle(Theme.textDim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Theme.accent.opacity(0.2) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small drawing of where the docks go in a layout.
private struct LayoutSketch: View {
    let layout: AppearanceSettings.DockLayout

    var body: some View {
        let inputs = Theme.accent.opacity(0.55), mon = Theme.panelRaised, mixer = Theme.preview.opacity(0.5)
        let m = HStack(spacing: 2) { mon; mon }
        return Group {
            switch layout {
            case .classic, .compact:
                HStack(spacing: 2) {
                    inputs.frame(width: layout == .compact ? 16 : 22)
                    VStack(spacing: 2) { m; mixer.frame(height: layout == .compact ? 12 : 18) }
                }
            case .stage:
                HStack(spacing: 2) {
                    inputs.frame(width: 14)
                    VStack(spacing: 2) { m; mixer.frame(height: 8) }
                }
            case .inputsRight:
                HStack(spacing: 2) {
                    VStack(spacing: 2) { m; mixer.frame(height: 18) }
                    inputs.frame(width: 22)
                }
            case .inputsBottom:
                VStack(spacing: 2) {
                    HStack(spacing: 2) { m; mixer.frame(width: 26) }
                    inputs.frame(height: 16)
                }
            case .mixerRight:
                HStack(spacing: 2) {
                    inputs.frame(width: 22)
                    m
                    mixer.frame(width: 26)
                }
            }
        }
        .padding(3)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
#endif
