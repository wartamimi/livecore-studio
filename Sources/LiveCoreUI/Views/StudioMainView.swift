#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Workspaces of the Studio UI. Each one arranges the same live panels for one job; switching
/// never stops anything (inputs, stream and recording keep running).
/// 0.72.1: three workspaces (the separate Inputs one repeated Live), each with its own colour.
enum StudioWorkspace: String, CaseIterable, Identifiable {
    case live, audio, show
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .audio: return "slider.vertical.3"
        case .show: return "wand.and.stars"
        }
    }
    var color: Color {
        switch self {
        case .live: return Color(red: 1.0, green: 0.38, blue: 0.36)
        case .audio: return Color(red: 0.16, green: 0.78, blue: 0.62)
        case .show: return Color(red: 0.66, green: 0.48, blue: 1.0)
        }
    }
    var title: String { L10n.t("studio.ws.\(rawValue)") }
    var number: Int { (StudioWorkspace.allCases.firstIndex(of: self) ?? 0) + 1 }
    /// ⌘1 … ⌘3.
    var key: KeyEquivalent { KeyEquivalent(Character("\(number)")) }
}

/// The Studio main window (Settings › Appearance › Interface = Studio).
///
/// 0.72.1 redesign: the layout follows the window size (wide: workspace rail on the left and
/// inputs beside the mixer; narrow: workspace tabs in the header and Inputs / Mixer as tabs),
/// springy colourful controls, and nothing that repeats another control (the inspector, the
/// clock, the Inputs workspace and the rail's tool shortcuts are gone).
/// The Classic UI of 0.71.0 is untouched in `MainView`.
struct StudioShell: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Binding var settingsTab: Int
    @AppStorage("studio.workspace") private var workspaceRaw = StudioWorkspace.live.rawValue
    @State private var showPalette = false

    /// Below this window width the rail folds into the header and the Live panels become tabs.
    static let narrowWidth: CGFloat = 1120

    init(showSettings: Binding<Bool>, settingsTab: Binding<Int>) {
        _showSettings = showSettings
        _settingsTab = settingsTab
    }

    private var workspace: Binding<StudioWorkspace> {
        Binding(get: { StudioWorkspace(rawValue: workspaceRaw) ?? .live }, set: { workspaceRaw = $0.rawValue })
    }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < Self.narrowWidth
            VStack(spacing: 6) {
                StudioHeader(workspace: workspace, narrow: narrow, showPalette: $showPalette) { openSettings($0) }
                ErrorBanner()
                HStack(spacing: 6) {
                    if !narrow { StudioRail(workspace: workspace) }
                    // Rebuilt when the workspace or the size class changes, so split views start
                    // from their ideal sizes (they keep old divider positions otherwise).
                    StudioWorkspaceView(workspace: workspace.wrappedValue, narrow: narrow)
                        .id("\(workspace.wrappedValue.rawValue)-\(narrow)")
                }
                OutputDockView { openSettings($0) }
            }
            .padding(6)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: $showPalette) {
            CommandPalette(workspace: workspace, openSettings: { openSettings($0) })
                .environmentObject(model)
        }
        .background(shortcuts)
    }

    private func openSettings(_ tab: Int) {
        settingsTab = tab
        showSettings = true
    }

    /// ⌘K opens the command palette, ⌘1–⌘3 switch workspaces.
    private var shortcuts: some View {
        ZStack {
            Button("") { showPalette = true }.keyboardShortcut("k", modifiers: [.command])
            ForEach(StudioWorkspace.allCases) { w in
                Button("") { workspace.wrappedValue = w }.keyboardShortcut(w.key, modifiers: [.command])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// Press feedback of the Studio controls: they dip and spring back.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

// MARK: Header

/// Top strip: logo and show name, File menu, (narrow windows) the workspace tabs, search,
/// ON AIR / REC lamps and the AI / Multiview / Settings buttons.
private struct StudioHeader: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var workspace: StudioWorkspace
    let narrow: Bool
    @Binding var showPalette: Bool
    let openSettings: (Int) -> Void
    @State private var spin = 0.0

    private var projectName: String {
        model.projectURL?.deletingPathExtension().lastPathComponent ?? L10n.t("studio.untitled")
    }

    var body: some View {
        HStack(spacing: narrow ? 8 : 12) {
            // The logo takes a spin when clicked (just for fun).
            LiveCoreLogo().frame(width: 24, height: 24)
                .rotationEffect(.degrees(spin))
                .onTapGesture { withAnimation(.spring(response: 0.7, dampingFraction: 0.55)) { spin += 360 } }
            if !narrow {
                VStack(alignment: .leading, spacing: 0) {
                    Text(projectName).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(model.settings.output.label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: 200, alignment: .leading)
            }
            ProjectFileMenu(compact: narrow)
            if narrow { WorkspaceSwitcher(workspace: $workspace, axis: .horizontal) }
            Spacer(minLength: 0)
            searchButton
            Spacer(minLength: 0)
            StatePill(title: L10n.t("studio.on_air"), icon: "antenna.radiowaves.left.and.right", on: model.isStreamingActive, labelled: !narrow)
            StatePill(title: "REC", icon: "record.circle", on: model.isRecording, labelled: !narrow)
            AIAssistantButton { openWindow(id: "ai-assistant") }
            iconButton("square.grid.3x2", help: L10n.t("multiview.open")) { openWindow(id: "multiview") }
            if !model.isOperatorMode {
                iconButton("gearshape", help: L10n.t("settings.title")) { openSettings(6) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .panel()
    }

    private var searchButton: some View {
        Button { showPalette = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                if !narrow { Text(L10n.t("studio.search")).lineLimit(1) }
                Spacer(minLength: 0)
                Text("⌘K").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.panelHover).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(width: narrow ? 92 : 300)
            .background(Theme.panelRaised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(BouncyButtonStyle())
        .help(L10n.t("studio.search_help"))
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .help(help)
            .buttonStyle(StudioButtonStyle())
            .frame(width: 36)
    }
}

/// ON AIR / REC lamp: grey when off, red, glowing and pulsing while live.
private struct StatePill: View {
    let title: String
    let icon: String
    let on: Bool
    let labelled: Bool
    @State private var blink = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            if labelled || on { Text(title).font(.system(size: 11, weight: .heavy, design: .rounded)).tracking(0.6) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(on ? Color.white : Theme.textDim)
        .background(on ? Theme.program.opacity(blink ? 0.75 : 1) : Theme.panelRaised)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(on ? Theme.program : Theme.border))
        .shadow(color: on ? Theme.program.opacity(blink ? 0.7 : 0.25) : .clear, radius: blink ? 8 : 3)
        .help(title)
        .onAppear { updateBlink(on) }
        .onChange(of: on) { updateBlink($0) }
    }

    private func updateBlink(_ live: Bool) {
        if live {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { blink = true }
        } else {
            withAnimation(.default) { blink = false }
        }
    }
}

// MARK: Workspace switcher

/// Left rail of wide windows: the workspaces, and the way back to the Classic UI.
private struct StudioRail: View {
    @EnvironmentObject var model: AppModel
    @Binding var workspace: StudioWorkspace
    @State private var hoverClassic = false

    var body: some View {
        VStack(spacing: 6) {
            WorkspaceSwitcher(workspace: $workspace, axis: .vertical)
            Spacer(minLength: 4)
            Button { model.appearance.style = .classic } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("studio.classic")).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(hoverClassic ? Theme.text : Theme.textDim)
                .background(hoverClassic ? Theme.panelHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(BouncyButtonStyle())
            .onHover { hoverClassic = $0 }
            .help(L10n.t("studio.classic_help"))
        }
        .padding(.vertical, 8).padding(.horizontal, 5)
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .panel()
    }
}

/// The workspace buttons, as a column (rail) or a row of icons (header of narrow windows). The
/// coloured pill slides to the chosen workspace.
private struct WorkspaceSwitcher: View {
    @Binding var workspace: StudioWorkspace
    let axis: Axis
    @Namespace private var pill

    var body: some View {
        let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(StudioWorkspace.allCases) { w in
                WorkspaceButton(workspace: w, selected: workspace == w, compact: axis == .horizontal, pill: pill) {
                    workspace = w
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: workspace)
    }
}

private struct WorkspaceButton: View {
    let workspace: StudioWorkspace
    let selected: Bool
    let compact: Bool
    let pill: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: workspace.icon)
                    .font(.system(size: compact ? 13 : 17, weight: .bold))
                    .scaleEffect(hovering ? 1.18 : 1)
                    .rotationEffect(.degrees(hovering && !selected ? -8 : 0))
                if !compact {
                    Text(workspace.title).font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: compact ? 42 : nil, height: compact ? 28 : nil)
            .frame(maxWidth: compact ? nil : .infinity)
            .padding(.vertical, compact ? 0 : 9)
            .foregroundStyle(selected ? Color.white : (hovering ? workspace.color : Theme.textDim))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [workspace.color, workspace.color.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: workspace.color.opacity(0.5), radius: 6, y: 2)
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(workspace.color.opacity(0.14))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { hovering = h } }
        .help("\(workspace.title)  ⌘\(workspace.number)")
    }
}

// MARK: Workspaces

private struct StudioWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let workspace: StudioWorkspace
    let narrow: Bool
    /// Narrow windows: which panel shows under the monitors in Live.
    @AppStorage("studio.live.panel") private var livePanel = "inputs"

    var body: some View {
        switch workspace {
        case .live:
            VSplitView {
                MonitorRow().frame(minHeight: 200, idealHeight: 430)
                if narrow {
                    // One panel at a time, each with the full width.
                    VStack(spacing: 5) {
                        panelTabs
                        if livePanel == "mixer" { mixer } else { InputPanelView() }
                    }
                    .frame(minHeight: 280, idealHeight: 320, alignment: .top)
                } else {
                    HSplitView {
                        InputPanelView().frame(minWidth: 260, idealWidth: 560)
                        mixer.frame(minWidth: 320)
                    }
                    .frame(minHeight: 250, idealHeight: 300, alignment: .top)
                }
            }
        case .audio:
            // Mixing: the full mixer with small monitors.
            VSplitView {
                MonitorRow().frame(minHeight: 170, idealHeight: 220)
                mixer.frame(minHeight: 300, alignment: .top)
            }
        case .show:
            VSplitView {
                MonitorRow().frame(minHeight: 200, idealHeight: 320)
                StudioToolsView().frame(minHeight: 220)
            }
        }
    }

    private var panelTabs: some View {
        HStack(spacing: 4) {
            panelTab("inputs", L10n.t("studio.ws.inputs"), icon: "square.grid.2x2", color: StudioWorkspace.live.color)
            panelTab("mixer", L10n.t("studio.live.mixer"), icon: "slider.vertical.3", color: StudioWorkspace.audio.color)
            Spacer(minLength: 0)
        }
    }

    private func panelTab(_ id: String, _ title: String, icon: String, color: Color) -> some View {
        let on = livePanel == id || (id == "inputs" && livePanel != "mixer")
        return Button { livePanel = id } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Theme.textDim)
                .background(on ? color : Theme.panelRaised)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(BouncyButtonStyle())
    }

    @ViewBuilder private var mixer: some View {
        HStack(alignment: .top, spacing: 6) {
            AudioMixerView()
            if model.hasPlaylists {
                PlaylistDockView().frame(minWidth: 200, idealWidth: 290, maxWidth: 320)
            }
        }
    }
}

// MARK: Show tools

/// One place for every show tool window, with its shortcut (they used to be reachable only from
/// the menu bar).
struct StudioTool: Identifiable {
    let id: String          // window id
    let titleKey: String
    let icon: String
    let shortcut: String
    var title: String { L10n.t(titleKey) }
    var help: String { L10n.t(titleKey + "_help") }

    static let all: [StudioTool] = [
        StudioTool(id: "ai-assistant", titleKey: "studio.tool.ai", icon: "sparkles", shortcut: "⌥⌘J"),
        StudioTool(id: "macros", titleKey: "studio.tool.macros", icon: "bolt.fill", shortcut: "⌥⌘K"),
        StudioTool(id: "automation", titleKey: "studio.tool.automation", icon: "gearshape.2", shortcut: "⌥⌘A"),
        StudioTool(id: "teleprompter", titleKey: "studio.tool.prompter", icon: "text.alignleft", shortcut: "⌥⌘P"),
        StudioTool(id: "rundown", titleKey: "studio.tool.rundown", icon: "list.bullet.rectangle", shortcut: "⇧⌘R"),
        StudioTool(id: "multiview", titleKey: "studio.tool.multiview", icon: "square.grid.3x2", shortcut: "⌥⌘M"),
        StudioTool(id: "highlights", titleKey: "studio.tool.highlights", icon: "star.fill", shortcut: "⇧⌘J"),
        StudioTool(id: "transcript", titleKey: "studio.tool.transcript", icon: "captions.bubble", shortcut: ""),
        StudioTool(id: "program-output", titleKey: "studio.tool.program_output", icon: "tv", shortcut: ""),
    ]

    /// Card colours, in turn.
    static let colors: [Color] = [
        Color(red: 0.66, green: 0.48, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.20), Color(red: 0.16, green: 0.78, blue: 0.62),
        Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 1.0, green: 0.42, blue: 0.62), Color(red: 0.95, green: 0.80, blue: 0.22),
    ]
}

private struct StudioToolsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let n = StudioTool.all.count
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                ForEach(Array(StudioTool.all.enumerated()), id: \.element.id) { i, t in
                    ToolCard(title: t.title, help: t.help, icon: t.icon, shortcut: t.shortcut, color: color(i)) { openWindow(id: t.id) }
                }
                ToolCard(title: L10n.t("studio.tool.outputs"), help: L10n.t("studio.tool.outputs_help"), icon: "square.stack.3d.up",
                         shortcut: "", color: color(n)) { model.showOutputsPanel = true }
                ToolCard(title: L10n.t("studio.tool.preflight"), help: L10n.t("studio.tool.preflight_help"), icon: "checklist",
                         shortcut: "", color: color(n + 1)) { model.showPreflight = true }
            }
            .padding(8)
        }
        .panel()
    }

    private func color(_ i: Int) -> Color { StudioTool.colors[i % StudioTool.colors.count] }
}

/// A show tool: lifts and its icon tilts under the pointer.
private struct ToolCard: View {
    let title: String
    let help: String
    let icon: String
    let shortcut: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(color.opacity(hovering ? 1 : 0.18))
                    .foregroundStyle(hovering ? Color.white : color)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .rotationEffect(.degrees(hovering ? -8 : 0))
                    .scaleEffect(hovering ? 1.08 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).lineLimit(1)
                        Spacer(minLength: 0)
                        if !shortcut.isEmpty {
                            Text(shortcut).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Theme.textDim)
                        }
                    }
                    Text(help).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hovering ? color.opacity(0.8) : Theme.border))
            .shadow(color: hovering ? color.opacity(0.3) : .clear, radius: 8, y: 3)
            .offset(y: hovering ? -2 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(BouncyButtonStyle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hovering = h } }
    }
}

// MARK: Command palette

/// ⌘K: type to find any action, input, window or setting and run it with Return or a click.
struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Binding var workspace: StudioWorkspace
    let openSettings: (Int) -> Void
    @State private var query = ""
    @State private var selection = 0

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let run: () -> Void
    }

    private var items: [Item] {
        var r: [Item] = []
        let switching = L10n.t("studio.cat.switching")
        r.append(Item(id: "cut", title: "CUT", detail: switching, icon: "scissors") { model.cut() })
        r.append(Item(id: "auto", title: "AUTO", detail: switching, icon: "wand.and.rays") { model.auto() })
        r.append(Item(id: "stream", title: model.isStreamingActive ? L10n.t("studio.cmd.stream_stop") : L10n.t("studio.cmd.stream_start"),
                      detail: L10n.t("studio.cat.output"), icon: "antenna.radiowaves.left.and.right") { model.requestToggleStream() })
        r.append(Item(id: "record", title: model.isRecording ? L10n.t("studio.cmd.record_stop") : L10n.t("studio.cmd.record_start"),
                      detail: L10n.t("studio.cat.output"), icon: "record.circle") { model.requestToggleRecord() })
        for i in model.inputs {
            r.append(Item(id: "pv-\(i.id.raw)", title: L10n.f("studio.cmd.preview", "\(i.number) · \(i.name)"), detail: switching,
                          icon: i.kind.symbol) { model.preview(i.id) })
            if !i.locked {
                r.append(Item(id: "pp-\(i.id.raw)", title: L10n.f("studio.cmd.properties", i.name), detail: L10n.t("studio.cat.inputs"),
                              icon: "slider.horizontal.3") { model.propertiesRequest = i.id })
            }
        }
        for ch in model.overlays {
            r.append(Item(id: "ov-\(ch.index)", title: L10n.f("studio.cmd.overlay", ch.index), detail: switching,
                          icon: "square.on.square") { model.toggleOverlay(ch.index) })
        }
        for w in StudioWorkspace.allCases {
            r.append(Item(id: "ws-\(w.rawValue)", title: L10n.f("studio.cmd.workspace", w.title), detail: L10n.t("studio.cat.view"),
                          icon: w.icon) { workspace = w })
        }
        for t in StudioTool.all {
            r.append(Item(id: "win-\(t.id)", title: t.title, detail: L10n.t("studio.cat.tools"), icon: t.icon) { openWindow(id: t.id) })
        }
        r.append(Item(id: "outputs", title: L10n.t("studio.tool.outputs"), detail: L10n.t("studio.cat.output"), icon: "square.stack.3d.up") {
            model.showOutputsPanel = true
        })
        r.append(Item(id: "preflight", title: L10n.t("studio.tool.preflight"), detail: L10n.t("studio.cat.tools"), icon: "checklist") {
            model.showPreflight = true
        })
        let settings = L10n.t("settings.title")
        for (tab, key, icon) in [(1, "studio.set.stream", "antenna.radiowaves.left.and.right"), (2, "studio.set.record", "record.circle"),
                                 (3, "studio.set.audio", "speaker.wave.2"), (4, "studio.set.keyboard", "keyboard"),
                                 (6, "studio.set.canvas", "rectangle"), (12, "studio.set.appearance", "paintbrush")] {
            r.append(Item(id: "set-\(tab)", title: L10n.t(key), detail: settings, icon: icon) { openSettings(tab) })
        }
        let file = L10n.t("top.file")
        r.append(Item(id: "new", title: L10n.t("project.new"), detail: file, icon: "doc") { model.newProject() })
        r.append(Item(id: "open", title: L10n.t("project.open"), detail: file, icon: "folder") { model.openProject() })
        r.append(Item(id: "save", title: L10n.t("project.save"), detail: file, icon: "square.and.arrow.down") { model.saveProject() })
        r.append(Item(id: "templates", title: L10n.t("template.menu"), detail: file, icon: "square.grid.3x3") { model.showTemplates = true })
        r.append(Item(id: "classic", title: L10n.t("studio.cmd.classic"), detail: L10n.t("studio.cat.view"), icon: "rectangle.3.group") {
            model.appearance.style = .classic
        })
        return r
    }

    private var filtered: [Item] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let hay = (item.title + " " + item.detail).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim)
                TextField(L10n.t("studio.search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .onSubmit { run(list, selection) }
                    .onChange(of: query) { _ in selection = 0 }
                Text("esc").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textDim)
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { n, item in
                            row(item, selected: n == selection).id(n)
                                .onTapGesture { run(list, n) }
                        }
                        if list.isEmpty {
                            Text(L10n.t("studio.no_results")).foregroundStyle(Theme.textDim).padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo($0) }
            }
            HStack {
                Text(L10n.t("studio.palette_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Spacer()
                Button("") { selection = max(0, selection - 1) }.keyboardShortcut(.upArrow, modifiers: []).opacity(0).frame(width: 0)
                Button("") { selection = min(max(list.count - 1, 0), selection + 1) }.keyboardShortcut(.downArrow, modifiers: []).opacity(0).frame(width: 0)
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 560, height: 440)
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).frame(width: 22).foregroundStyle(selected ? Color.white : Theme.accent)
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            Text(item.detail).font(.system(size: 11)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.textDim)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Theme.accent.opacity(0.85) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func run(_ list: [Item], _ n: Int) {
        guard list.indices.contains(n) else { return }
        let item = list[n]
        dismiss()
        // After the sheet closes, so windows and sheets the action opens are not blocked by it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { item.run() }
    }
}
#endif
