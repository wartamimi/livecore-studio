#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Workspaces of the Studio UI (0.72.0). Each one arranges the same live panels for one job;
/// switching never stops anything (inputs, stream and recording keep running).
enum StudioWorkspace: String, CaseIterable, Identifiable {
    case live, inputs, audio, show
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .inputs: return "square.grid.2x2"
        case .audio: return "slider.vertical.3"
        case .show: return "wand.and.stars"
        }
    }
    var title: String { L10n.t("studio.ws.\(rawValue)") }
    /// ⌘1 … ⌘4.
    var key: KeyEquivalent { KeyEquivalent(Character("\((StudioWorkspace.allCases.firstIndex(of: self) ?? 0) + 1)")) }
}

/// The Studio main window (Settings › Appearance › Interface = Studio): header with status,
/// a workspace rail on the left, the workspace, and the output dock (RECORD / STREAM / OUTPUTS).
/// The Classic UI of 0.71.0 is untouched in `MainView` and one click away on the rail.
struct StudioShell: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Binding var settingsTab: Int
    @AppStorage("studio.workspace") private var workspaceRaw = StudioWorkspace.live.rawValue
    @AppStorage("studio.inspector") private var showInspector = true
    @State private var showPalette = false

    init(showSettings: Binding<Bool>, settingsTab: Binding<Int>) {
        _showSettings = showSettings
        _settingsTab = settingsTab
    }

    private var workspace: Binding<StudioWorkspace> {
        Binding(get: { StudioWorkspace(rawValue: workspaceRaw) ?? .live }, set: { workspaceRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 6) {
            StudioHeader(showPalette: $showPalette, showInspector: $showInspector) { openSettings($0) }
            ErrorBanner()
            HStack(spacing: 6) {
                StudioRail(workspace: workspace) { openSettings($0) }
                StudioWorkspaceView(workspace: workspace.wrappedValue, showInspector: showInspector)
                    .id(workspace.wrappedValue)
            }
            OutputDockView { openSettings($0) }
        }
        .padding(6)
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

    /// ⌘K opens the command palette, ⌘1–⌘4 switch workspaces, ⌥⌘I shows / hides the inspector.
    private var shortcuts: some View {
        ZStack {
            Button("") { showPalette = true }.keyboardShortcut("k", modifiers: [.command])
            ForEach(StudioWorkspace.allCases) { w in
                Button("") { workspace.wrappedValue = w }.keyboardShortcut(w.key, modifiers: [.command])
            }
            Button("") { showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

// MARK: Header

/// Top strip: logo, project and output format, File menu, search, ON AIR / REC, clock and the
/// AI / Multiview / Settings buttons.
private struct StudioHeader: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var showPalette: Bool
    @Binding var showInspector: Bool
    let openSettings: (Int) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
    }

    private var projectName: String {
        model.projectURL?.deletingPathExtension().lastPathComponent ?? L10n.t("studio.untitled")
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            LiveCoreLogo().frame(width: 22, height: 22)
            if !compact {
                VStack(alignment: .leading, spacing: 0) {
                    Text(projectName).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(model.settings.output.label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            ProjectFileMenu(compact: compact)
            Spacer(minLength: 0)
            searchButton(compact: compact)
            Spacer(minLength: 0)
            StatePill(title: L10n.t("studio.on_air"), icon: "antenna.radiowaves.left.and.right", on: model.isStreamingActive)
            StatePill(title: "REC", icon: "record.circle", on: model.isRecording)
            if !compact {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(ctx.date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                }
            }
            AIAssistantButton { openWindow(id: "ai-assistant") }
            iconButton("square.grid.3x2", help: L10n.t("multiview.open")) { openWindow(id: "multiview") }
            iconButton(showInspector ? "sidebar.right" : "sidebar.squares.right", help: L10n.t("studio.inspector_toggle")) {
                showInspector.toggle()
            }
            if !model.isOperatorMode {
                iconButton("gearshape", help: L10n.t("settings.title")) { openSettings(6) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .panel()
    }

    private func searchButton(compact: Bool) -> some View {
        Button { showPalette = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                if !compact { Text(L10n.t("studio.search")).lineLimit(1) }
                Spacer(minLength: 0)
                Text("⌘K").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.panelHover).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: compact ? 90 : 300)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("studio.search_help"))
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .help(help)
            .buttonStyle(StudioButtonStyle())
            .frame(width: 36)
    }
}

/// ON AIR / REC lamp: grey when off, red and pulsing while live.
private struct StatePill: View {
    let title: String
    let icon: String
    let on: Bool
    @State private var blink = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(title).font(.system(size: 11, weight: .heavy)).tracking(0.6)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(on ? Color.white : Theme.textDim)
        .background(on ? Theme.program.opacity(blink ? 0.75 : 1) : Theme.panelRaised)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(on ? Theme.program : Theme.border))
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

// MARK: Rail

/// Left rail: the four workspaces, the show tools that are used most, and the way back to the
/// Classic UI.
private struct StudioRail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Binding var workspace: StudioWorkspace
    let openSettings: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(StudioWorkspace.allCases) { w in
                railButton(w.title, icon: w.icon, selected: workspace == w,
                           help: "\(w.title)  ⌘\((StudioWorkspace.allCases.firstIndex(of: w) ?? 0) + 1)") { workspace = w }
            }
            Divider().padding(.vertical, 4)
            railButton(L10n.t("studio.tool.macros"), icon: "bolt.fill", selected: false, help: L10n.t("macro.menu")) { openWindow(id: "macros") }
            railButton(L10n.t("studio.tool.automation"), icon: "gearshape.2", selected: false, help: L10n.t("automation.menu")) { openWindow(id: "automation") }
            railButton(L10n.t("studio.tool.prompter"), icon: "text.alignleft", selected: false, help: L10n.t("prompter.menu")) { openWindow(id: "teleprompter") }
            Spacer(minLength: 4)
            railButton(L10n.t("studio.classic"), icon: "rectangle.3.group", selected: false, help: L10n.t("studio.classic_help")) {
                model.appearance.style = .classic
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 68)
        .frame(maxHeight: .infinity)
        .panel()
    }

    private func railButton(_ title: String, icon: String, selected: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        RailButton(title: title, icon: icon, selected: selected, action: action).help(help)
    }
}

private struct RailButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).frame(height: 20)
                Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : (hovering ? Theme.text : Theme.textDim))
            .background(selected ? Theme.accent.opacity(0.85) : (hovering ? Theme.panelHover : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Workspaces

private struct StudioWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let workspace: StudioWorkspace
    let showInspector: Bool

    var body: some View {
        switch workspace {
        case .live:
            // Monitors large on top, inputs and mixer side by side underneath.
            VSplitView {
                withInspector(MonitorRow()).frame(minHeight: 220, idealHeight: 430)
                HSplitView {
                    InputPanelView().frame(minWidth: 260, idealWidth: 560)
                    mixer.frame(minWidth: 320)
                }
                .frame(minHeight: 250, idealHeight: 300, alignment: .top)
            }
        case .inputs:
            // Building the show: a big input wall with the inspector, small monitors on top.
            VSplitView {
                MonitorRow().frame(minHeight: 170, idealHeight: 240)
                withInspector(InputPanelView()).frame(minHeight: 260)
            }
        case .audio:
            // Mixing: the full mixer with small monitors.
            VSplitView {
                MonitorRow().frame(minHeight: 170, idealHeight: 220)
                mixer.frame(minHeight: 300, alignment: .top)
            }
        case .show:
            VSplitView {
                withInspector(MonitorRow()).frame(minHeight: 200, idealHeight: 320)
                StudioToolsView().frame(minHeight: 220)
            }
        }
    }

    @ViewBuilder private var mixer: some View {
        HStack(alignment: .top, spacing: 6) {
            AudioMixerView()
            if model.hasPlaylists {
                PlaylistDockView().frame(minWidth: 200, idealWidth: 290, maxWidth: 320)
            }
        }
    }

    private func withInspector<V: View>(_ content: V) -> some View {
        HStack(spacing: 6) {
            content
            if showInspector { StudioInspector().frame(width: 250) }
        }
    }
}

// MARK: Inspector

/// Right panel: the input on Preview with one-click actions, what is on Program, and the four
/// overlay channels with their state.
struct StudioInspector: View {
    @EnvironmentObject var model: AppModel

    private func info(_ id: InputID?) -> ProductionEngine.InputInfo? {
        guard let id else { return nil }
        return model.inputs.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L10n.t("monitor.preview"))
                if let p = info(model.switcher.preview) {
                    inputCard(p, color: Theme.preview)
                    HStack(spacing: 6) {
                        Button("CUT") { model.cut() }.buttonStyle(StudioButtonStyle(color: Theme.program, active: false))
                        Button("AUTO") { model.auto() }.buttonStyle(StudioButtonStyle(color: Theme.accent, active: false))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("studio.overlay_program")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        OverlayNumbers(input: p.id)
                    }
                    Button { model.propertiesRequest = p.id } label: {
                        Label(L10n.t("studio.properties"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(p.locked)
                } else {
                    empty(L10n.t("studio.no_preview"))
                }

                Divider()
                SectionHeader(title: L10n.t("monitor.program"))
                if let p = info(model.switcher.program) { inputCard(p, color: Theme.program) } else { empty(L10n.t("monitor.no_input")) }

                Divider()
                SectionHeader(title: L10n.t("studio.overlays"))
                ForEach(model.overlays, id: \.index) { ch in overlayRow(ch) }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .panel()
    }

    private func inputCard(_ i: ProductionEngine.InputInfo, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: i.kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(i.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(L10n.t("studio.input")) \(i.number)").font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            if i.locked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.textDim) }
        }
        .padding(6)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.6)))
    }

    private func overlayRow(_ ch: OverlayChannel) -> some View {
        let name = info(ch.source)?.name ?? "—"
        let state = ch.isOn ? Theme.overlayProgram : (ch.onPreview ? Theme.overlayPreview : Theme.panelHover)
        return HStack(spacing: 8) {
            Text("\(ch.index)")
                .font(.system(size: 11, weight: .heavy))
                .frame(width: 20, height: 20)
                .background(state)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name).font(.system(size: 12)).lineLimit(1).foregroundStyle(ch.source == nil ? Theme.textDim : Theme.text)
            Spacer(minLength: 0)
            Button(ch.isOn ? L10n.t("studio.off") : L10n.t("studio.on")) { model.toggleOverlay(ch.index) }
                .controlSize(.small)
                .disabled(ch.source == nil)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Theme.panelRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
}

private struct StudioToolsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(StudioTool.all) { t in
                    card(t.title, help: t.help, icon: t.icon, shortcut: t.shortcut) { openWindow(id: t.id) }
                }
                card(L10n.t("studio.tool.outputs"), help: L10n.t("studio.tool.outputs_help"), icon: "square.stack.3d.up", shortcut: "") {
                    model.showOutputsPanel = true
                }
                card(L10n.t("studio.tool.preflight"), help: L10n.t("studio.tool.preflight_help"), icon: "checklist", shortcut: "") {
                    model.showPreflight = true
                }
            }
            .padding(8)
        }
        .panel()
    }

    private func card(_ title: String, help: String, icon: String, shortcut: String, action: @escaping () -> Void) -> some View {
        ToolCard(title: title, help: help, icon: icon, shortcut: shortcut, action: action)
    }
}

private struct ToolCard: View {
    let title: String
    let help: String
    let icon: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.18))
                    .foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
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
            .background(hovering ? Theme.panelHover : Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
