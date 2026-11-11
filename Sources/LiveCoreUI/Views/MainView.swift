#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var settingsTab = 6   // Canvas, the first tab
    // Docked panels that are minimized to a slim bar (remembered between launches).
    @AppStorage("dock.inputs.minimized") private var inputsMin = false
    @AppStorage("dock.playlist.minimized") private var playlistMin = false
    @AppStorage("mixer.inputsFolded") private var mixerInputsMin = false
    @AppStorage("welcome.showAtLaunch") private var welcomeAtLaunch = true
    /// Animated logo once per launch (0.72.0), not again for a second main window.
    @State private var showSplash = MainView.takeSplash()
    private static var splashTaken = false
    private static func takeSplash() -> Bool {
        guard !splashTaken else { return false }
        splashTaken = true
        return AppearanceSettings.load().splash
    }

    /// The Playlist dock appears once a music playlist or a video (playlist) input exists.
    /// Only for real playlists (0.55.1): a single file from Add Media does not open it.
    private var showPlaylist: Bool { model.hasPlaylists }

    var body: some View {
        mainContent.background(MainWindowQuitHook())
            .overlay {
                if showSplash {
                    SplashView { showSplash = false }
                }
            }
    }

    @ViewBuilder private var mainContent: some View {
        Group {
            if let err = model.startupError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(Theme.warning)
                    Text("LiveCore Studio could not start").font(.title2)
                    Text(err).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.appearance.style == .studio {
                // New Studio UI (0.72.0); Settings › Appearance › Interface switches back.
                StudioShell(showSettings: $showSettings, settingsTab: $settingsTab)
            } else {
                // Classic UI (0.71.0), unchanged.
                VStack(spacing: 6) {
                    TopBarView(showSettings: $showSettings)
                    ErrorBanner()
                    // Rebuilt when a dock is minimized or restored (0.63.0): split views keep their old
                        // divider positions otherwise and the remaining panels did not fill the space.
                    dockArea
                        .id(DockKey(appearance: model.appearance, inputsMin: inputsMin, playlistMin: playlistMin,
                                    mixerInputsMin: mixerInputsMin))
                    // Always shown: RECORD, STREAM, EXTERNAL and the four outputs.
                    OutputDockView { tab in settingsTab = tab; showSettings = true }
                }
                .padding(6)
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showSettings) { SettingsView(initialTab: settingsTab).environmentObject(model) }
        .onChange(of: showSettings) { shown in if !shown { settingsTab = 6 } }
        .background(KeyboardShortcuts())
        // Pre-flight lives in Settings (0.38.0); the menu command opens that tab.
        .onChange(of: model.showPreflight) { show in
            guard show else { return }
            model.showPreflight = false
            settingsTab = 9
            showSettings = true
        }
        .onChange(of: model.openSettingsRequest) { open in
            guard open else { return }
            model.openSettingsRequest = false
            showSettings = true
        }
        .addInputSheets(model)
        .sheet(isPresented: $model.showOutputsPanel) { OutputsPanelSheet().environmentObject(model) }
        .sheet(isPresented: $model.showTemplates) { TemplatesSheet().environmentObject(model) }
        .sheet(item: $model.propertiesRequest) { id in InputPropertiesSheet(input: id).environmentObject(model) }
        .onAppear {
            // Welcome screen with the templates on an empty start (not over the recovery question).
            // After the splash, when it shows.
            DispatchQueue.main.asyncAfter(deadline: .now() + (showSplash ? 3.3 : 1.2)) {
                if welcomeAtLaunch, !model.recoveryPending, model.inputs.isEmpty, model.projectURL == nil, model.startupError == nil {
                    model.showTemplates = true
                }
            }
        }
        .alert(model.pendingStop == .record ? L10n.t("record.stop_confirm") : model.pendingStop == .multicorder ? L10n.t("multicorder.stop_confirm") : L10n.t("stream.stop_confirm"),
               isPresented: Binding(get: { model.pendingStop != nil }, set: { if !$0 { model.pendingStop = nil } }),
               presenting: model.pendingStop) { r in
            Button(r == .record ? L10n.t("record.stop") : r == .multicorder ? L10n.t("multicorder.stop") : L10n.t("stream.stop"), role: .destructive) { model.confirmStop(r) }
            Button(L10n.t("settings.cancel"), role: .cancel) { model.pendingStop = nil }
        } message: { r in
            Text(r == .record ? L10n.t("record.stop_message") : r == .multicorder ? L10n.t("multicorder.stop_message") : L10n.t("stream.stop_message"))
        }
    }
}

extension MainView {
    // MARK: Dock layouts (Settings › Appearance, 0.62.0)

    @ViewBuilder var inputsPanel: some View {
        InputPanelView()
            .dockHandle { inputsMin = true }
            .frame(minWidth: 180, idealWidth: model.appearance.layout == .compact ? 210 : 260,
                   maxWidth: model.appearance.layout == .inputsBottom ? .infinity : 360)
    }

    @ViewBuilder var inputsBar: some View {
        DockBar(title: L10n.t("inputs.title"), axis: .vertical) { inputsMin = false }
    }

    /// Monitors + Transition and the Audio Mixer cannot be minimized (0.55.0).
    @ViewBuilder var monitors: some View {
        MonitorRow().frame(minHeight: 200)
    }

    /// Height the mixer needs so its strips (fader, M / S / PGM, sends) are never cut off.
    var mixerMin: CGFloat { model.appearance.layout == .stage ? 210 : 250 }

    @ViewBuilder var mixerArea: some View {
        HStack(alignment: .top, spacing: 6) {
            AudioMixerView()
            if showPlaylist {
                if playlistMin {
                    DockBar(title: L10n.t("playlist.dock"), axis: .vertical) { playlistMin = false }
                } else {
                    PlaylistDockView()
                        .dockHandle { playlistMin = true }
                        .frame(minWidth: 200, idealWidth: 290, maxWidth: 320)
                }
            }
        }
    }

    @ViewBuilder var dockArea: some View {
        let l = model.appearance.layout
        switch l {
        case .classic, .compact, .stage:
            // Inputs left, monitors on top, mixer below (stage: smaller mixer, compact: narrower inputs).
            HStack(spacing: 6) {
                if inputsMin { inputsBar }
                HSplitView {
                    if !inputsMin { inputsPanel }
                    VSplitView {
                        monitors
                        mixerArea.frame(minHeight: mixerMin, idealHeight: l == .stage ? 230 : (l == .compact ? 260 : 300), alignment: .top)
                    }
                    .frame(minWidth: 480)
                }
            }
        case .inputsRight:
            HStack(spacing: 6) {
                HSplitView {
                    VSplitView {
                        monitors
                        mixerArea.frame(minHeight: mixerMin, idealHeight: 300, alignment: .top)
                    }
                    .frame(minWidth: 480)
                    if !inputsMin { inputsPanel }
                }
                if inputsMin { inputsBar }
            }
        case .inputsBottom:
            // Monitors across the top; inputs and mixer side by side underneath.
            VSplitView {
                monitors.frame(minHeight: 220, idealHeight: 420)
                HStack(spacing: 6) {
                    if inputsMin {
                        inputsBar
                        mixerArea
                    } else {
                        HSplitView {
                            inputsPanel.frame(minWidth: 300, idealWidth: 560)
                            mixerArea.frame(minWidth: 320)
                        }
                    }
                }
                .frame(minHeight: mixerMin, idealHeight: 320, alignment: .top)
            }
        case .mixerRight:
            // Inputs left, monitors centre, mixer as a column on the right.
            HStack(spacing: 6) {
                if inputsMin { inputsBar }
                HSplitView {
                    if !inputsMin { inputsPanel }
                    monitors.frame(minWidth: 420)
                    mixerArea.frame(minWidth: 240, idealWidth: 360, maxWidth: 620)
                }
            }
        }
    }
}

/// Identity of the dock area: a new layout or a minimized / restored dock rebuilds it.
private struct DockKey: Hashable {
    let appearance: AppearanceSettings
    let inputsMin: Bool
    let playlistMin: Bool
    let mixerInputsMin: Bool
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

/// Keyboard shortcuts (0.62.0): one key monitor runs the table from Settings › Keyboard.
struct KeyboardShortcuts: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { model.installShortcutMonitor() }
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
