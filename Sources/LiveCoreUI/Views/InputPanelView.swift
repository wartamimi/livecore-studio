#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

struct InputPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTitleSheet = false
    @State private var editingTitle: InputID?
    @State private var keying: InputID?
    @State private var editingScene: InputID?
    @State private var renaming: InputID?
    @State private var renameText = ""
    @State private var showBrowserSheet = false
    @State private var editingBrowser: InputID?
    @State private var showTimerSheet = false
    @State private var editingTimer: InputID?
    @State private var showCaptureSheet = false
    @State private var editingCapture: InputID?
    @State private var showNDISheet = false
    @State private var editingNDI: InputID?
    @State private var showFrameSheet = false
    @State private var editingFrame: InputID?
    @State private var editingGT: InputID?
    @State private var editingSubtitles: InputID?
    @State private var closing: InputID?
    @State private var showCaptureCard = false
    @State private var editingCaptureCard: InputID?
    @State private var adjusting: InputID?
    @State private var editingTicker: InputID?
    @State private var showSlideshowSheet = false
    @State private var editingSlideshow: InputID?
    @State private var editingData: InputID?
    @State private var editingPTZ: InputID?
    @State private var editingAI: InputID?
    @State private var collapsedGroups: Set<String> = []
    @State private var renamingGroup: InputColorTag?
    @State private var groupNameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.t("inputs.title"))
                Spacer()
                if !model.inputs.isEmpty {
                    let allMin = model.inputGroups.flatMap(\.inputs).allSatisfy { model.minimizedInputs.contains($0) }
                    Button { model.setAllMinimized(!allMin) } label: {
                        Image(systemName: allMin ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    }
                    .buttonStyle(.borderless)
                    .help(allMin ? L10n.t("groups.expand_all") : L10n.t("groups.minimize_all"))
                    let allLocked = model.inputs.allSatisfy(\.locked)
                    Button { model.lockAllInputs(!allLocked) } label: { Image(systemName: allLocked ? "lock.fill" : "lock.open") }
                        .buttonStyle(.borderless)
                        .help(allLocked ? L10n.t("lock.unlock_all") : L10n.t("lock.lock_all"))
                }
                addMenu
            }
            if model.inputs.isEmpty {
                Text(L10n.t("inputs.empty")).font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.top, 20)
                Spacer()
            } else {
                if !model.usedColorTags.isEmpty { filterBar }
                ScrollView {
                    let groups = model.inputGroups
                    let byID = Dictionary(uniqueKeysWithValues: model.inputs.map { ($0.id, $0) })
                    let headers = groups.count > 1 || groups.first?.tag != nil
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.key) { g in
                            if headers { groupHeader(g) }
                            if !headers || !collapsedGroups.contains(g.key) {
                                let infos = g.inputs.compactMap { byID[$0] }
                                let full = infos.filter { !model.minimizedInputs.contains($0.id) }
                                let mini = infos.filter { model.minimizedInputs.contains($0.id) }
                                if !full.isEmpty {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                                        ForEach(full) { info in
                                            InputTile(info: info, onClose: { closing = info.id })
                                                .contextMenu { contextMenu(info) }
                                        }
                                    }
                                }
                                if !mini.isEmpty {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 4)], spacing: 4) {
                                        ForEach(mini) { info in
                                            MiniInputTile(info: info).contextMenu { contextMenu(info) }
                                        }
                                    }
                                }
                                if infos.isEmpty {
                                    Text(L10n.t("groups.empty")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .panel()
        .sheet(isPresented: $showTitleSheet) { TitleSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingTitle) { id in TitleSheet(editing: id).environmentObject(model) }
        .sheet(item: $editingAI) { id in InputAISheet(input: id).environmentObject(model) }
        .sheet(item: $keying) { id in ChromaKeySheet(input: id).environmentObject(model) }
        .sheet(item: $editingScene) { id in SceneEditorSheet(input: id).environmentObject(model) }
        .sheet(isPresented: $showBrowserSheet) { BrowserSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingBrowser) { id in BrowserSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showTimerSheet) { TimerSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingTimer) { id in TimerSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showCaptureSheet) { CaptureSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingCapture) { id in CaptureSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showNDISheet) { NDIInputSheet(editing: nil).environmentObject(model) }
        .sheet(isPresented: $showFrameSheet) { FrameSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingFrame) { id in FrameSheet(editing: id).environmentObject(model) }
        .sheet(item: $editingGT) { id in GTTitleSheet(input: id).environmentObject(model) }
        .sheet(item: $editingSubtitles) { id in SubtitleSheet(input: id).environmentObject(model) }
        .sheet(item: $editingNDI) { id in NDIInputSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showCaptureCard) { CaptureCardSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingCaptureCard) { id in CaptureCardSheet(editing: id).environmentObject(model) }
        .sheet(item: $adjusting) { id in InputAdjustSheet(input: id).environmentObject(model) }
        .sheet(item: $editingTicker) { id in TitleSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showSlideshowSheet) { SlideshowSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingSlideshow) { id in SlideshowSheet(editing: id).environmentObject(model) }
        .sheet(item: $editingData) { id in DataSourceSheet(input: id).environmentObject(model) }
        .sheet(item: $editingPTZ) { id in PTZSheet(input: id).environmentObject(model) }
        .alert(L10n.f("inputs.close_confirm", model.inputs.first { $0.id == closing }?.name ?? ""),
               isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
            Button(L10n.t("inputs.close"), role: .destructive) { if let id = closing { model.remove(id) }; closing = nil }
            Button(L10n.t("settings.cancel"), role: .cancel) { closing = nil }
        } message: {
            Text(L10n.t("inputs.close_message"))
        }
        .alert(L10n.t("groups.rename"), isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("", text: $groupNameText)
            Button(L10n.t("common.ok")) { if let t = renamingGroup { model.renameGroup(t, groupNameText) }; renamingGroup = nil }
            Button(L10n.t("settings.cancel"), role: .cancel) { renamingGroup = nil }
        }
        .alert(L10n.t("inputs.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $renameText)
            Button(L10n.t("common.ok")) { if let id = renaming { model.rename(id, renameText) }; renaming = nil }
            Button(L10n.t("settings.cancel"), role: .cancel) { renaming = nil }
        }
    }

    /// Colour filter (vMix-style): all inputs, or one colour group only.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                filterChip(nil, label: L10n.f("groups.all", model.inputs.count))
                let used = model.usedColorTags
                ForEach(used.map { $0.tag }, id: \.self) { tag in
                    let n = used.first { $0.tag == tag }?.count ?? 0
                    filterChip(tag, label: "\(model.groupName(tag)) (\(n))")
                }
            }
        }
    }

    private func filterChip(_ tag: InputColorTag?, label: String) -> some View {
        let on = model.inputFilter == tag
        return Button { model.inputFilter = tag } label: {
            HStack(spacing: 4) {
                if let tag { Circle().fill(tag.color).frame(width: 8, height: 8) }
                Text(label).font(.system(size: 10, weight: on ? .bold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(on ? (tag?.color.opacity(0.35) ?? Theme.accent.opacity(0.35)) : Theme.panelRaised)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(on ? (tag?.color ?? Theme.accent) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func groupHeader(_ g: InputGroup) -> some View {
        let collapsed = collapsedGroups.contains(g.key)
        return HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .bold)).frame(width: 10)
            RoundedRectangle(cornerRadius: 2).fill(g.tag?.color ?? Theme.textDim.opacity(0.5)).frame(width: 14, height: 8)
            Text(model.groupName(g.tag)).font(.system(size: 11, weight: .semibold))
            Text("\(g.inputs.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
            Rectangle().fill((g.tag?.color ?? Theme.border).opacity(0.35)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { if collapsed { collapsedGroups.remove(g.key) } else { collapsedGroups.insert(g.key) } }
        .contextMenu {
            if let t = g.tag {
                Button(L10n.t("groups.rename") + "…") { groupNameText = model.groupName(t); renamingGroup = t }
            }
            Button(L10n.t("groups.minimize_group")) { g.inputs.forEach { if !model.minimizedInputs.contains($0) { model.toggleMinimized($0) } } }
            Button(L10n.t("groups.expand_group")) { g.inputs.forEach { if model.minimizedInputs.contains($0) { model.toggleMinimized($0) } } }
        }
    }

    private var addMenu: some View {
        Menu {
            // One entry for every camera, capture card and iPhone (0.46.0, like vMix's "Video
            // Capture Device"): the device, format and audio are picked in the sheet.
            Section(L10n.t("inputs.camera_group")) {
                Button { model.refreshDevices(); showCaptureCard = true } label: {
                    Label(L10n.t("inputs.video_capture"), systemImage: "video")
                }
            }
            // Media files grouped in one place: video, video playlist, image, slideshow, presentation.
            Section(L10n.t("inputs.media_group")) {
                Button(L10n.t("media.add")) { model.addMedia() }
                Button(L10n.t("media.add_playlist")) { model.addMediaPlaylist() }
                Button(L10n.t("inputs.image")) { model.addImage() }
                Button(L10n.t("slideshow.add")) { showSlideshowSheet = true }
                Button(L10n.t("presentation.add")) { model.addPresentation() }
            }
            Section(L10n.t("inputs.graphics_group")) {
                // Titles, lower thirds and running text are all made in the Title Designer.
                Button(L10n.t("inputs.title_menu")) { showTitleSheet = true }
                Button(L10n.t("timer.add")) { showTimerSheet = true }
                Button(L10n.t("frame.add")) { showFrameSheet = true }
                Button(L10n.t("gt.add")) { if let id = model.addGTTitle() { editingGT = id } }
                Button(L10n.t("subtitles.add")) { if let id = model.addSubtitles() { editingSubtitles = id } }
                Button(L10n.t("scene.new")) { if let id = model.addScene() { editingScene = id } }
            }
            Section(L10n.t("inputs.other_group")) {
                Button(L10n.t("browser.add")) { showBrowserSheet = true }
                if !model.isOperatorMode {
                    Button(L10n.t("capture.add")) { showCaptureSheet = true }
                    Button(L10n.t("ndi.add")) { showNDISheet = true }
                    Button(L10n.t("inputs.colorbars")) { model.addColorBars() }
                }
            }
            Menu(L10n.t("inputs.color")) {
                Button("Black") { model.addColor(.black, name: "Black") }
                Button("White") { model.addColor(.white, name: "White") }
                Button("Blue") { model.addColor(NSColor(calibratedRed: 0.05, green: 0.2, blue: 0.55, alpha: 1), name: "Blue") }
                Button("Green screen") { model.addColor(NSColor(calibratedRed: 0, green: 0.7, blue: 0.25, alpha: 1), name: "Green") }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t("inputs.add"))
        .onAppear { model.refreshDevices() }
    }

    /// On-device AI per input (0.43.0). Since 0.46.0 a plain item that opens a sheet: a live
    /// submenu with toggles was rebuilt on every tile refresh and flickered (cursor blinking).
    @ViewBuilder
    private func aiMenu(_ id: InputID) -> some View {
        Button(L10n.t("ai.menu") + "…") { editingAI = id }
    }

    @ViewBuilder
    private func contextMenu(_ info: ProductionEngine.InputInfo) -> some View {
        Button(L10n.t("inputs.preview")) { model.preview(info.id) }
        Button(L10n.t("inputs.cutdirect")) { model.cutDirect(info.id) }
        Button(info.locked ? L10n.t("lock.unlock_input") : L10n.t("lock.lock_input")) { model.toggleLock(info.id) }
        Button(model.minimizedInputs.contains(info.id) ? L10n.t("groups.expand") : L10n.t("groups.minimize")) { model.toggleMinimized(info.id) }
        Menu(L10n.t("groups.color_label")) {
            ForEach(InputColorTag.allCases, id: \.self) { t in
                Button((model.inputTags[info.id] == t ? "✓ " : "") + model.groupName(t)) { model.setColorTag(t, for: info.id) }
            }
            Divider()
            Button((model.inputTags[info.id] == nil ? "✓ " : "") + L10n.t("groups.no_label")) { model.setColorTag(nil, for: info.id) }
        }
        Divider()
        Group { editItems(info) }.disabled(info.locked)
    }

    @ViewBuilder
    private func editItems(_ info: ProductionEngine.InputInfo) -> some View {
        Button(L10n.t("scene.edit")) { editingScene = info.id }
        Menu(L10n.t("inputs.addlayer")) {
            ForEach([LayoutPreset.pipTopRight, .pipTopLeft, .pipBottomRight, .pipBottomLeft, .sideBySideLeft, .sideBySideRight], id: \.self) { p in
                Button(p.rawValue) { model.addPiP(source: info.id, preset: p) }
            }
        }
        if info.kind == .camera && !model.isOperatorMode { Button(L10n.t("capturecard.edit_menu")) { editingCaptureCard = info.id } }
        if info.kind != .scene { Button(L10n.t("adjust.menu")) { adjusting = info.id } }
        if info.kind == .camera || info.kind == .videoFile || info.kind == .image || info.kind == .ndi {
            Button(L10n.t("key.menu")) { keying = info.id }
        }
        if info.kind == .text {
            Button(L10n.t("titled.edit_menu")) { editingTitle = info.id }
            Button(L10n.t("data.menu")) { editingData = info.id }
            if model.dataSource(info.id) != nil {
                Button(L10n.t("data.next")) { model.stepDataRow(info.id, by: 1) }
                Button(L10n.t("data.previous")) { model.stepDataRow(info.id, by: -1) }
                if let t = model.dataTables[info.id], let ds = model.dataSource(info.id), !t.rows.isEmpty {
                    Menu(L10n.f("data.row_menu", t.label(row: ds.row))) {
                        ForEach(t.rows.indices.prefix(200), id: \.self) { i in
                            Button((i == ds.row ? "▶ " : "") + t.label(row: i)) { model.setDataRow(info.id, i) }
                        }
                    }
                }
                Button(L10n.t("data.reload")) { model.loadDataSource(info.id) }
            }
        }
        if info.kind == .camera { Button(L10n.t("ptz.menu")) { editingPTZ = info.id } }
        if info.kind == .browser {
            Button(L10n.experimental("browser.interact")) { model.editBrowserPage(info.id) }
            if let b = model.browserSource(info.id) {
                Toggle(L10n.t("browser.freeze"), isOn: Binding(get: { b.freezeWhileEditing },
                                                               set: { b.freezeWhileEditing = $0; model.objectWillChange.send() }))
            }
            Button(L10n.t("browser.edit")) { editingBrowser = info.id }
            Button(L10n.t("browser.reload")) { model.browserSource(info.id)?.reload() }
        }
        if info.kind == .screen {
            Button(L10n.t("capture.edit")) { editingCapture = info.id }
            Button(L10n.t("capture.retry")) { model.captureSource(info.id)?.start() }
        }
        if info.kind == .ndi { Button(L10n.t("ndi.edit")) { editingNDI = info.id } }
        if info.kind == .frame { Button(L10n.t("frame.edit")) { editingFrame = info.id } }
        if info.kind == .gtTitle { Button(L10n.t("gt.edit")) { editingGT = info.id } }
        if info.kind == .subtitles { Button(L10n.t("subtitles.edit")) { editingSubtitles = info.id } }
        if [.camera, .ndi, .videoFile, .screen].contains(info.kind) { aiMenu(info.id) }
        if info.kind == .timer {
            Button(L10n.t("timer.start")) { model.timerControl(info.id, "play") }
            Button(L10n.t("timer.pause")) { model.timerControl(info.id, "pause") }
            Button(L10n.t("timer.reset")) { model.timerControl(info.id, "reset") }
            Button(L10n.t("timer.edit")) { editingTimer = info.id }
        }
        if info.kind == .ticker, let t = model.tickerSource(info.id) {
            Button(t.isPaused ? L10n.t("ticker.resume") : L10n.t("ticker.pause")) { t.setPaused(!t.isPaused) }
            Button(L10n.t("ticker.restart")) { t.restart() }
            Button(L10n.t("ticker.edit")) { editingTicker = info.id }
        }
        if info.kind == .presentation, let p = model.presentationSource(info.id) {
            Button(L10n.t("presentation.next")) { p.next() }
            Button(L10n.t("presentation.previous")) { p.previous() }
            Button(L10n.t("presentation.first")) { p.first() }
            Button(L10n.t("presentation.last")) { p.last() }
            if p.slideCount > 1 {
                Menu(L10n.t("presentation.go_to")) {
                    ForEach(0..<p.slideCount, id: \.self) { i in
                        Button((i == p.slide ? "▶ " : "") + L10n.f("presentation.slide_n", String(i + 1))) { p.go(to: i) }
                    }
                }
            }
            if p.canPlayLive {
                Toggle(L10n.experimental("presentation.live"), isOn: Binding(get: { p.prefersLive },
                                                                   set: { p.setLive($0); model.objectWillChange.send() }))
            }
            Menu(L10n.t("presentation.background")) {
                Button(L10n.t("presentation.bg_black")) { p.setBackground(nil) }
                Button(L10n.t("presentation.bg_white")) { p.setBackground(ProjectColor(r: 1, g: 1, b: 1)) }
            }
            Button(L10n.t("presentation.reload")) { p.reload() }
            Button(L10n.t("presentation.open_app")) { NSWorkspace.shared.open(p.url) }
        }
        if info.kind == .slideshow, let s = model.slideshowSource(info.id) {
            Button(L10n.t("playlist.next")) { s.next() }
            Button(L10n.t("playlist.previous")) { s.previous() }
            Button(s.isPaused ? L10n.t("ticker.resume") : L10n.t("ticker.pause")) { s.setPaused(!s.isPaused) }
            Button(L10n.t("slideshow.edit")) { editingSlideshow = info.id }
        }
        if info.kind == .videoFile, let v = model.videoFile(info.id) {
            Button("Play") { v.play() }
            Button("Pause") { v.pause() }
            Button("Restart") { v.restart() }
            if v.isPlaylist {
                Button(L10n.t("playlist.next")) { v.nextClip() }
                Button(L10n.t("playlist.previous")) { v.previousClip() }
                Menu(L10n.t("playlist.clips")) {
                    ForEach(Array(v.urls.enumerated()), id: \.offset) { i, u in
                        Button((i == v.index ? "▶ " : "") + u.deletingPathExtension().lastPathComponent) { v.selectClip(i) }
                    }
                }
            }
            Button(L10n.t("playlist.add_clips")) { model.addClips(to: info.id) }
            Toggle(v.isPlaylist ? L10n.t("playlist.loop") : L10n.t("video.loop"),
                   isOn: Binding(get: { v.loop }, set: { v.loop = $0; model.objectWillChange.send() }))
            Menu(L10n.t("autoplay.title")) {
                ForEach(VideoFileSource.AutoPlay.allCases, id: \.self) { m in
                    Button((v.autoPlay == m ? "✓ " : "") + L10n.t("autoplay." + m.rawValue)) { model.setAutoPlay(m, for: info.id) }
                }
            }
        }
        Divider()
        Button(L10n.t("inputs.rename")) { renameText = info.name; renaming = info.id }
        Button(L10n.t("inputs.remove"), role: .destructive) { closing = info.id }
    }
}

extension InputID: Identifiable { public var id: String { raw } }

/// Small overlay dock under each input (vMix-style): 1–4 put this input on that overlay channel.
/// Click = Preview (orange), secondary / two-finger click = Program (green); fade, full screen.
struct OverlayNumbers: View {
    @EnvironmentObject var model: AppModel
    let input: InputID

    var body: some View {
        HStack(spacing: 3) {
            ForEach(model.overlays, id: \.index) { ch in
                let mine = ch.source == input
                let program = mine && ch.isOn
                let preview = mine && ch.onPreview && !ch.isOn
                Text("\(ch.index)")
                    .font(.system(size: 10, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 16)
                    .foregroundStyle(program || preview ? Color.white : Theme.textDim)
                    .background(program ? Theme.overlayProgram : (preview ? Theme.overlayPreview : Theme.panel))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
                    .overlay(TwoClickArea(primary: { model.overlayFromTile(ch.index, input: input, toProgram: false) },
                                          secondary: { model.overlayFromTile(ch.index, input: input, toProgram: true) }))
                    .help(L10n.f("overlay.tile_help", ch.index))
            }
        }
    }
}

struct InputTile: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let info: ProductionEngine.InputInfo
    var onClose: () -> Void = {}
    @State private var hovering = false

    private var isProgram: Bool { model.switcher.program == info.id || model.switcher.transition?.from == info.id }
    private var isPreview: Bool { model.switcher.preview == info.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    Checkerboard(cell: 6)
                    PixelBufferView(feed: model.feed(for: info.id), transparent: true)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                Text("\(info.number)")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isProgram ? Theme.program : (isPreview ? Theme.preview : Color.black.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(4)
                if hovering {
                    HStack(spacing: 4) {
                        if info.kind == .browser {
                            tileButton("hand.point.up.left.fill", L10n.t("browser.interact")) { model.editBrowserPage(info.id) }
                        }
                        Spacer()
                        tileButton("arrow.up.left.and.arrow.down.right.circle.fill", L10n.t("viewer.open")) {
                            model.openViewer(info.id)
                            openWindow(id: "source-viewer")
                        }
                        // Minimize sits between full screen and close (vMix layout).
                        tileButton("minus.circle.fill", L10n.t("groups.minimize")) { model.toggleMinimized(info.id) }
                        if !info.locked { tileButton("xmark.circle.fill", L10n.t("inputs.close"), action: onClose) }
                    }
                    .padding(4)
                }
            }
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(info.status.label)
                Text(info.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Button { model.toggleLock(info.id) } label: {
                    Image(systemName: info.locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                        .foregroundStyle(info.locked ? Theme.warning : Theme.textDim)
                }
                .buttonStyle(.plain)
                .help(info.locked ? L10n.t("lock.unlock_input") : L10n.t("lock.lock_input"))
            }
            if info.kind == .browser, model.browserSource(info.id)?.isEditing == true {
                Label(L10n.t("browser.editing_badge"), systemImage: "hand.point.up.left.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.warning)
            }
            OverlayNumbers(input: info.id)
            if info.kind == .videoFile, let v = model.videoFile(info.id) { MediaClock(video: v) }
            if info.kind == .presentation, let p = model.presentationSource(info.id) { SlideControls(info: info, source: p) }
            if !info.status.isHealthy, info.status != .starting {
                Text(info.status.label).font(.system(size: 9)).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
        .padding(4)
        .padding(.top, model.inputTags[info.id] == nil ? 0 : 2)
        .background(Theme.panelRaised)
        .overlay(alignment: .top) {
            if let t = model.inputTags[info.id] { Rectangle().fill(t.color).frame(height: 4) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isProgram ? Theme.program : (isPreview ? Theme.preview : Theme.border), lineWidth: isProgram || isPreview ? 2 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.cutDirect(info.id) }
        .onTapGesture { model.preview(info.id) }
        .help("Click: Preview · Double-click: Cut to Program")
    }

    private func tileButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.65))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var statusColor: Color {
        switch info.status {
        case .live: return Theme.preview
        case .starting: return Theme.textDim
        case .noSignal: return Theme.warning
        case .error: return Theme.program
        }
    }

    private var icon: String {
        switch info.kind {
        case .camera: return "video.fill"
        case .image: return "photo"
        case .videoFile: return "film"
        case .color: return "paintpalette"
        case .text: return "textformat"
        case .browser: return "globe"
        case .timer: return "timer"
        case .screen: return "macwindow"
        case .replay: return "gobackward"
        case .colorBars: return "chart.bar.fill"
        case .scene: return "square.on.square"
        case .ticker: return "text.line.first.and.arrowtriangle.forward"
        case .slideshow: return "photo.stack"
        case .ndi: return "antenna.radiowaves.left.and.right"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .frame: return "person.crop.rectangle"
        case .gtTitle: return "rectangle.bottomthird.inset.filled"
        case .subtitles: return "captions.bubble"
        }
    }
}

/// Minimized input (vMix-style): one compact row with the colour label, tally number, name and
/// status. Click = Preview, double-click = Cut; the square button opens it again.
struct MiniInputTile: View {
    @EnvironmentObject var model: AppModel
    let info: ProductionEngine.InputInfo

    private var isProgram: Bool { model.switcher.program == info.id || model.switcher.transition?.from == info.id }
    private var isPreview: Bool { model.switcher.preview == info.id }

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(model.inputTags[info.id]?.color ?? Color.clear).frame(width: 4)
            Text("\(info.number)")
                .font(.system(size: 10, weight: .heavy))
                .frame(minWidth: 18)
                .padding(.vertical, 1)
                .background(isProgram ? Theme.program : (isPreview ? Theme.preview : Color.black.opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(info.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
            if info.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.warning) }
            Button { model.toggleMinimized(info.id) } label: {
                Image(systemName: "plus.square").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .help(L10n.t("groups.expand"))
        }
        .padding(.trailing, 5)
        .frame(height: 24)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isProgram ? Theme.program : (isPreview ? Theme.preview : Theme.border), lineWidth: isProgram || isPreview ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.cutDirect(info.id) }
        .onTapGesture { model.preview(info.id) }
        .help("Click: Preview · Double-click: Cut to Program")
    }
}

extension InputGroup {
    /// Stable key for SwiftUI lists and the collapsed-group set.
    var key: String { tag?.rawValue ?? "untagged" }
}

/// Add or change a window / display capture (Zoom, Teams, Meet, slides...).
struct CaptureSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var windows: [WindowCandidate] = []
    @State private var displays: [DisplayInfo] = []
    @State private var selection: String?       // "w<id>" or "d<id>"
    @State private var audio = true
    @State private var cursor = false
    @State private var fps = 30
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("capture.title")).font(.headline)
            if let error {
                Text(error).foregroundStyle(Theme.warning).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Button(L10n.t("capture.open_settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            List(selection: $selection) {
                Section(L10n.t("capture.windows")) {
                    ForEach(windows, id: \.windowID) { w in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.appName).font(.system(size: 12, weight: .semibold))
                            Text(w.title).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                            if let used = inUse(windowConfig(w)) { usedLabel(used) }
                        }.tag("w\(w.windowID)")
                    }
                }
                Section(L10n.t("capture.displays")) {
                    ForEach(displays, id: \.id) { d in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name)
                            if let used = inUse(displayConfig(d.id)) { usedLabel(used) }
                        }.tag("d\(d.id)")
                    }
                }
            }
            .frame(height: 260)
            Toggle(L10n.t("capture.audio"), isOn: $audio)
            Toggle(L10n.t("capture.cursor"), isOn: $cursor)
            Picker("FPS", selection: $fps) {
                ForEach([15, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            Text(L10n.t("capture.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.t("capture.refresh")) { load() }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    guard let cfg = config else { return }
                    if let id = editing { model.updateCapture(id, cfg) } else { model.addCapture(cfg) }
                    dismiss()
                }
                .disabled(config == nil || config.flatMap(inUse) != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            if let id = editing, let c = model.captureSource(id)?.config {
                audio = c.captureAudio; cursor = c.showsCursor; fps = c.fps
            }
            load()
        }
    }

    private var config: ProjectScreenCapture? {
        guard let selection else { return nil }
        if selection.hasPrefix("w"), let id = UInt32(selection.dropFirst()), let w = windows.first(where: { $0.windowID == id }) {
            return windowConfig(w)
        }
        if selection.hasPrefix("d"), let id = UInt32(selection.dropFirst()) { return displayConfig(id) }
        return nil
    }

    private func windowConfig(_ w: WindowCandidate) -> ProjectScreenCapture {
        ProjectScreenCapture(target: .window, bundleID: w.bundleID, appName: w.appName, windowTitle: w.title,
                             captureAudio: audio, fps: fps, showsCursor: cursor)
    }

    private func displayConfig(_ id: UInt32) -> ProjectScreenCapture {
        ProjectScreenCapture(target: .display, displayID: id, captureAudio: audio, fps: fps, showsCursor: cursor)
    }

    /// Another input already captures this window / display (the one being edited does not count).
    private func inUse(_ c: ProjectScreenCapture) -> String? { model.captureInUse(c, except: editing) }

    private func usedLabel(_ used: String) -> some View {
        Text(L10n.f("inputs.in_use", used)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warning)
    }

    private func load() {
        ScreenCaptureSource.shareable { result in
            switch result {
            case let .success(list):
                windows = list.windows; displays = list.displays; error = nil
                if selection == nil, let zoom = windows.first(where: { $0.bundleID == "us.zoom.xos" }) { selection = "w\(zoom.windowID)" }
            case let .failure(e):
                error = L10n.f("capture.permission", e.localizedDescription)
            }
        }
    }
}

/// Add or edit a web page input (vMix-style options: video only, zoom, CSS, mute).
struct BrowserSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var config = ProjectBrowser(url: "https://")
    @State private var size = 1080
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("browser.title")).font(.headline)
            HStack {
                TextField("https://…", text: $config.url)
                Button(L10n.t("browser.file")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.html]
                    if p.runModal() == .OK, let u = p.url { config.url = u.absoluteString }
                }
            }
            Picker(L10n.t("browser.size"), selection: $size) {
                Text("1920 × 1080").tag(1080)
                Text("1280 × 720").tag(720)
            }
            Picker(L10n.t("browser.fps"), selection: $config.fps) {
                ForEach(BrowserURLPolicy.allowedFPS, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Toggle(L10n.t("browser.transparent"), isOn: $config.transparent)
            Toggle(L10n.t("browser.video_only"), isOn: Binding(get: { config.videoOnly ?? false }, set: { config.videoOnly = $0 ? true : nil }))
            Text(L10n.t("browser.video_only_help")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.t("browser.mute"), isOn: Binding(get: { config.muted ?? false }, set: { config.muted = $0 ? true : nil }))
            HStack {
                Text(L10n.t("browser.zoom"))
                Slider(value: Binding(get: { config.pageZoom }, set: { config.zoom = abs($0 - 1) < 0.01 ? nil : $0 }),
                       in: ProjectBrowser.zoomRange, step: 0.05)
                Text("\(Int((config.pageZoom * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Text(L10n.t("browser.css")).font(.system(size: 11))
            TextEditor(text: Binding(get: { config.css ?? "" }, set: { config.css = $0.isEmpty ? nil : $0 }))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.textDim.opacity(0.4)))
            Text(L10n.t("browser.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Theme.warning).font(.system(size: 11)) }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    var c = config
                    c.width = size == 1080 ? 1920 : 1280
                    c.height = size
                    let err = editing.map { model.updateBrowser($0, c) } ?? model.addBrowser(c)
                    if let err { error = err } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            if let id = editing, let b = model.browserSource(id)?.config {
                config = b
                size = b.height >= 1080 ? 1080 : 720
            }
        }
    }
}

/// Add or edit a clock / countdown / count-up input, with its look (0.45.0).
struct TimerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var config = TimerConfig()
    @State private var style = TimerStyle()
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var target = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("timer.title")).font(.headline)
            Picker(L10n.t("timer.mode"), selection: $config.mode) {
                Text(L10n.t("timer.mode.countdown")).tag(TimerConfig.Mode.countdown)
                Text(L10n.t("timer.mode.until")).tag(TimerConfig.Mode.untilTime)
                Text(L10n.t("timer.mode.countup")).tag(TimerConfig.Mode.countUp)
                Text(L10n.t("timer.mode.clock")).tag(TimerConfig.Mode.clock)
            }
            .pickerStyle(.segmented)
            Form {
                Section {
                    if config.mode == .countdown {
                        HStack {
                            Stepper("\(minutes) min", value: $minutes, in: 0...599)
                            Stepper("\(seconds) s", value: $seconds, in: 0...59)
                        }
                        HStack(spacing: 6) {
                            ForEach([1, 3, 5, 10, 15, 30, 60], id: \.self) { m in
                                Button("\(m)′") { minutes = m; seconds = 0 }.controlSize(.small)
                            }
                        }
                    }
                    if config.mode == .untilTime {
                        DatePicker(L10n.t("timer.until"), selection: $target, displayedComponents: .hourAndMinute)
                        Stepper(L10n.f("timer.progress_window", minutes), value: $minutes, in: 1...600)
                    }
                    Toggle(L10n.t("timer.show_seconds"), isOn: $config.showSeconds)
                    if config.mode != .clock {
                        Toggle(L10n.t("timer.tenths"), isOn: $style.showTenths).disabled(!config.showSeconds)
                    }
                    if config.mode == .clock {
                        Toggle(L10n.t("timer.12h"), isOn: $style.twelveHour)
                        Toggle(L10n.t("timer.show_date"), isOn: $style.showDate)
                    }
                    TextField(L10n.t("timer.label"), text: $config.label, prompt: Text(L10n.t("timer.label_prompt")))
                }
                if config.mode == .countdown || config.mode == .untilTime {
                    Section(L10n.t("timer.end")) {
                        Stepper(style.warnSeconds > 0 ? L10n.f("timer.warn", Int(style.warnSeconds)) : L10n.t("timer.warn_off"),
                                value: $style.warnSeconds, in: 0...600, step: 15)
                        TextField(L10n.t("timer.finished_text"), text: $style.finishedText, prompt: Text("00:00"))
                        Toggle(L10n.t("timer.blink"), isOn: $style.blinkWhenFinished)
                        if config.mode == .countdown { Toggle(L10n.t("timer.overtime"), isOn: $style.overtime) }
                    }
                }
                Section(L10n.t("timer.graphic")) {
                    Picker(L10n.t("timer.plate"), selection: $style.plate) {
                        ForEach(TimerStyle.Plate.allCases, id: \.self) { Text(L10n.t("timer.plate.\($0.rawValue)")).tag($0) }
                    }
                    Picker(L10n.t("timer.font"), selection: $style.font) {
                        ForEach(TimerStyle.Font.allCases, id: \.self) { Text(L10n.t("timer.font.\($0.rawValue)")).tag($0) }
                    }
                    HStack {
                        hexColor(L10n.t("timer.color_text"), $style.textHex)
                        hexColor(L10n.t("timer.color_plate"), $style.plateHex)
                        hexColor(L10n.t("timer.color_warn"), $style.warnHex)
                        hexColor(L10n.t("timer.color_end"), $style.accentHex)
                    }
                    LabeledContent(L10n.t("timer.plate_opacity")) {
                        Slider(value: $style.plateOpacity, in: 0...1)
                        Text("\(Int(style.plateOpacity * 100)) %").monospacedDigit().frame(width: 44)
                    }
                    HStack(spacing: 6) {
                        Text(L10n.t("timer.presets")).font(.caption).foregroundStyle(Theme.textDim)
                        ForEach(Self.presets, id: \.0) { p in
                            Button(L10n.t("timer.preset.\(p.0)")) { let o = style; style = p.1; style.showTenths = o.showTenths; style.twelveHour = o.twelveHour; style.showDate = o.showDate }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
            if config.mode != .clock {
                Text(L10n.t("timer.hint")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    config.durationSeconds = config.mode == .untilTime ? Double(minutes * 60) : Double(minutes * 60 + seconds)
                    let cal = Calendar.current
                    config.targetSecondsOfDay = target.timeIntervalSince(cal.startOfDay(for: target))
                    config.style = style
                    if let id = editing { model.updateTimer(id, config) } else { model.addTimer(config) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            if let id = editing, let t = model.timerSource(id) {
                config = t.config
                style = t.config.look
                minutes = Int(t.config.durationSeconds) / 60; seconds = Int(t.config.durationSeconds) % 60
                if let s = t.config.targetSecondsOfDay { target = Calendar.current.startOfDay(for: Date()).addingTimeInterval(s) }
            }
        }
    }

    private func hexColor(_ label: String, _ hex: Binding<String>) -> some View {
        ColorPicker(label, selection: Binding(
            get: { let c = ProjectColor(hex: hex.wrappedValue) ?? ProjectColor(r: 1, g: 1, b: 1)
                   return Color(.sRGB, red: c.r, green: c.g, blue: c.b) },
            set: { c in
                let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                hex.wrappedValue = ProjectColor(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent)).hex
            }), supportsOpacity: false)
            .font(.system(size: 11))
    }

    /// Ready looks: broadcast (dark plate), stage (big, no plate), sport (bar), minimal ring.
    static let presets: [(String, TimerStyle)] = {
        var broadcast = TimerStyle(); broadcast.plate = .rounded
        var stage = TimerStyle(); stage.plate = .none; stage.font = .rounded; stage.warnSeconds = 120
        var sport = TimerStyle(); sport.plate = .bar; sport.font = .condensed; sport.plateHex = "#101820"; sport.plateOpacity = 0.9
        var ring = TimerStyle(); ring.plate = .ring; ring.font = .rounded; ring.accentHex = "#22D36F"
        var progress = TimerStyle(); progress.plate = .progress; progress.plateHex = "#0B1A33"; progress.plateOpacity = 0.85
        var light = TimerStyle(); light.plate = .pill; light.plateHex = "#FFFFFF"; light.plateOpacity = 0.9; light.textHex = "#111111"
        return [("broadcast", broadcast), ("stage", stage), ("sport", sport), ("ring", ring), ("progress", progress), ("light", light)]
    }()
}

/// Transport of a video input: seekbar (drag to scrub), position / length, previous, play/pause,
/// next (clips of a playlist; for a single clip previous goes back to the start).
struct MediaClock: View {
    @EnvironmentObject var model: AppModel
    let video: VideoFileSource
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 2) {
                if let d = video.duration {
                    Slider(value: Binding(get: { scrub ?? min(video.position, d) },
                                          set: { scrub = $0; video.seek(to: $0) }),
                           in: 0...d, onEditingChanged: { editing in if !editing { scrub = nil } })
                        .controlSize(.mini)
                }
                HStack(spacing: 6) {
                    Button { video.previousClip() } label: { Image(systemName: "backward.end.fill") }
                    Button { video.isPlaying ? video.pause() : video.play() } label: {
                        Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { video.nextClip() } label: { Image(systemName: "forward.end.fill") }
                        .disabled(!video.isPlaylist)
                    Text("\(TimerMath.duration(scrub ?? video.position)) / \(video.duration.map { TimerMath.duration($0) } ?? "--:--")")
                    if video.isPlaylist { Text("\(video.index + 1)/\(video.urls.count)") }
                    Spacer(minLength: 0)
                    // vMix-style toggles: AUTO = play on Program / pause off it; ↺ = restart.
                    toggle("AUTO", on: video.autoPlayEnabled, help: L10n.t("media.auto_help")) {
                        model.setAutoPlayEnabled(!video.autoPlayEnabled, for: video.id)
                    }
                    Button { model.setAutoRestart(!video.autoRestart, for: video.id) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 13)
                            .background(video.autoRestart ? Theme.accent : Theme.panel)
                            .foregroundStyle(video.autoRestart ? Color.white : Theme.textDim)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .help(L10n.t(video.autoRestart ? "media.restart_on_help" : "media.restart_off_help"))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            }
        }
    }

    private func toggle(_ label: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .frame(height: 13)
                .padding(.horizontal, 4)
                .background(on ? Theme.accent : Theme.panel)
                .foregroundStyle(on ? Color.white : Theme.textDim)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .help(help)
    }
}

/// Presentation tile bar: first / previous / next and "slide n / total" (vMix PowerPoint input).
struct SlideControls: View {
    let info: ProductionEngine.InputInfo
    let source: PresentationSource

    var body: some View {
        HStack(spacing: 6) {
            Button { source.first() } label: { Image(systemName: "backward.end.fill") }
                .help(L10n.t("presentation.first"))
            Button { source.previous() } label: { Image(systemName: "chevron.left") }
                .help(L10n.t("presentation.previous"))
            if source.prefersLive {
                Text("LIVE").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 3)
                    .background(Theme.program).foregroundStyle(Color.white).clipShape(RoundedRectangle(cornerRadius: 2))
                    .help(L10n.t("presentation.live_help"))
            }
            if let s = info.slide, s.converting {
                ProgressView().controlSize(.mini)
                Text(L10n.t(source.prefersLive ? "presentation.starting_live" : "presentation.converting"))
            } else if let s = info.slide, s.count > 0 {
                Text(L10n.f("presentation.counter", String(s.index), String(s.count)))
            } else {
                Text("--")
            }
            Button { source.next() } label: { Image(systemName: "chevron.right") }
                .help(L10n.t("presentation.next"))
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(Theme.textDim)
        .lineLimit(1)
    }
}

/// Live chroma-key editor: every change is applied to the engine immediately so the operator
/// sees the result in Preview/Program/Multiview while adjusting.
struct ChromaKeySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var key = ChromaKey()
    @State private var loaded = false
    @State private var still: AppModel.InputStill?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(L10n.t("key.title")) — \(model.inputs.first { $0.id == input }?.name ?? "")").font(.headline)
            Toggle(L10n.t("key.enable"), isOn: $key.enabled)
            HStack {
                Text(L10n.t("key.color"))
                Spacer()
                Button(L10n.t("key.green")) { key.keyColor = .green }
                Button(L10n.t("key.blue")) { key.keyColor = .blue }
                ColorPicker("", selection: colorBinding, supportsOpacity: false).labelsHidden()
                Button { still = model.inputStill(input); picking = still != nil } label: { Image(systemName: "eyedropper") }
                    .help(L10n.t("key.eyedropper_help"))
            }
            if picking, let still {
                VStack(alignment: .leading, spacing: 4) {
                    Image(decorative: still.image, scale: 1)
                        .resizable()
                        .aspectRatio(CGFloat(still.width) / CGFloat(still.height), contentMode: .fit)
                        .overlay(GeometryReader { geo in
                            Color.clear.contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { v in
                                    if let c = still.sample(nx: v.location.x / geo.size.width, ny: v.location.y / geo.size.height) {
                                        key.keyColor = c
                                        if !key.enabled { key.enabled = true }
                                    }
                                })
                        })
                        .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                        .frame(maxHeight: 220)
                    HStack {
                        Text(L10n.t("key.eyedropper_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        Spacer()
                        Button(L10n.t("key.eyedropper_refresh")) { self.still = model.inputStill(input) }.controlSize(.small)
                        Button(L10n.t("common.ok")) { picking = false }.controlSize(.small)
                    }
                }
            }
            slider(L10n.t("key.similarity"), $key.similarity, 0.01...0.6)
            slider(L10n.t("key.smoothness"), $key.smoothness, 0.001...0.5)
            slider(L10n.t("key.spill"), $key.spill, 0.001...0.5)
            Text(L10n.t("key.hint")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            HStack {
                Button("Reset") { key = ChromaKey(enabled: key.enabled) }
                Spacer()
                Button(L10n.t("common.ok")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { key = model.chromaKey(input); loaded = true }
        .onChange(of: key) { k in if loaded { model.setChromaKey(k, for: input) } }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.3f", value.wrappedValue)).font(.system(size: 11).monospacedDigit()).frame(width: 44)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(.sRGB, red: key.keyColor.r, green: key.keyColor.g, blue: key.keyColor.b) },
                set: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .green
                    key.keyColor = ChromaKey.RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
                })
    }
}

/// AI options for one input (0.46.0), moved out of the context menu.
struct InputAISheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var ai = InputAI()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("ai.menu")).font(.headline)
            if model.aiAvailable {
                Toggle(L10n.t("ai.remove_bg"), isOn: $ai.removeBackground)
                Toggle(L10n.t("ai.auto_frame"), isOn: $ai.autoFrame)
                Picker(L10n.t("ai.zoom"), selection: $ai.zoom) {
                    Text(L10n.t("ai.zoom.wide")).tag(1.25)
                    Text(L10n.t("ai.zoom.medium")).tag(1.5)
                    Text(L10n.t("ai.zoom.close")).tag(2.0)
                }
                .disabled(!ai.autoFrame)
            } else {
                Text(L10n.t("ai.needs_apple_silicon")).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button(L10n.t("common.close")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { ai = model.inputAI(input); loaded = true }
        .onChange(of: ai) { v in if loaded { model.setInputAI(input, v) } }
    }
}
#endif
