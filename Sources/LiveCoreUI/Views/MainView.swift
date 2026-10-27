#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    // Docked panels that are minimized to a slim bar (remembered between launches).
    @AppStorage("dock.inputs.minimized") private var inputsMin = false
    @AppStorage("dock.mixer.minimized") private var mixerMin = false
    @AppStorage("dock.controls.minimized") private var controlsMin = false
    @AppStorage("dock.monitors.minimized") private var monitorsMin = false

    var body: some View {
        Group {
            if let err = model.startupError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.warning)
                    Text("LiveCore Studio could not start").font(.title2)
                    Text(err).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    TopBarView(showSettings: $showSettings)
                    ErrorBanner()
                    HStack(spacing: 6) {
                        if inputsMin {
                            DockBar(title: L10n.t("inputs.title"), axis: .vertical) { inputsMin = false }
                        }
                        HSplitView {
                            if !inputsMin {
                                InputPanelView()
                                    .dockHandle { inputsMin = true }
                                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                            }
                            VStack(spacing: 6) {
                                if monitorsMin {
                                    DockBar(title: L10n.t("dock.monitors"), axis: .horizontal) { monitorsMin = false }
                                }
                                VSplitView {
                                    if !monitorsMin {
                                        MonitorRow()
                                            .dockHandle { monitorsMin = true }
                                            .frame(minHeight: 300)
                                    }
                                    if !(mixerMin && controlsMin) {
                                        HStack(alignment: .top, spacing: 6) {
                                            if mixerMin {
                                                DockBar(title: L10n.t("audio.title"), axis: .vertical) { mixerMin = false }
                                            } else {
                                                AudioMixerView().dockHandle { mixerMin = true }
                                            }
                                            if controlsMin {
                                                DockBar(title: L10n.t("dock.controls"), axis: .vertical) { controlsMin = false }
                                            } else {
                                                ControlPanelView(showSettings: $showSettings)
                                                    .dockHandle { controlsMin = true }
                                                    .frame(width: 330)
                                            }
                                        }
                                        .frame(minHeight: 230, idealHeight: 280)
                                    }
                                }
                                if mixerMin && controlsMin {
                                    HStack(spacing: 6) {
                                        DockBar(title: L10n.t("audio.title"), axis: .horizontal) { mixerMin = false }
                                        DockBar(title: L10n.t("dock.controls"), axis: .horizontal) { controlsMin = false }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .background(KeyboardShortcuts())
        .alert(model.pendingStop == .record ? L10n.t("record.stop_confirm") : L10n.t("stream.stop_confirm"),
               isPresented: Binding(get: { model.pendingStop != nil }, set: { if !$0 { model.pendingStop = nil } }),
               presenting: model.pendingStop) { r in
            Button(r == .record ? L10n.t("record.stop") : L10n.t("stream.stop"), role: .destructive) { model.confirmStop(r) }
            Button(L10n.t("settings.cancel"), role: .cancel) { model.pendingStop = nil }
        } message: { r in
            Text(r == .record ? L10n.t("record.stop_message") : L10n.t("stream.stop_message"))
        }
    }
}

/// Slim bar shown in place of a minimized panel; click to restore it (like vMix's collapsed docks).
struct DockBar: View {
    let title: String
    let axis: Axis
    let restore: () -> Void

    var body: some View {
        Button(action: restore) {
            Group {
                if axis == .vertical {
                    VStack(spacing: 8) {
                        Image(systemName: "chevron.right.2").font(.system(size: 9, weight: .bold))
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            .fixedSize()
                            .rotationEffect(.degrees(90))
                            .frame(width: 14, height: 120)
                        Spacer()
                    }
                    .padding(.top, 8)
                    .frame(width: 26)
                    .frame(maxHeight: .infinity)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down.2").font(.system(size: 9, weight: .bold))
                        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(Theme.textDim)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.f("dock.restore", title))
    }
}

extension View {
    /// Small handle at the top centre of a docked panel that minimizes it.
    func dockHandle(_ minimize: @escaping () -> Void) -> some View {
        overlay(alignment: .top) {
            Button(action: minimize) {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 30, height: 11)
                    .background(Theme.panelRaised)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .padding(.top, 1)
            .help(L10n.t("dock.minimize"))
        }
    }
}

/// Invisible buttons that carry the configurable shortcuts.
struct KeyboardShortcuts: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Button("") { model.cut() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.cut), modifiers: [])
            Button("") { model.auto() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.auto), modifiers: [])
            Button("") { model.requestToggleStream() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.stream), modifiers: [.command])
            Button("") { model.requestToggleRecord() }.keyboardShortcut(ShortcutSettings.key(model.shortcuts.record), modifiers: [.command])
            ForEach(1..<10) { n in
                Button("") { model.previewNumber(n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if !model.errors.isEmpty {
            VStack(spacing: 4) {
                ForEach(model.errors) { e in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text(e.message).font(.system(size: 12)).lineLimit(3)
                        Spacer()
                        Button(L10n.t("common.dismiss")) { model.dismissError(e) }.buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Theme.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

/// Full-screen Program output for an external display / projector: open the window from
/// the toolbar, drag it to the external screen and press ⌃⌘F for full screen.
struct ProgramOutputWindow: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PixelBufferView(feed: model.programOutputFeed)
            .background(Color.black)
            .frame(minWidth: 320, minHeight: 180)
            .ignoresSafeArea()
    }
}
#endif
