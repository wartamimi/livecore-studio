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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.t("inputs.title"))
                Spacer()
                addMenu
            }
            if model.inputs.isEmpty {
                Text(L10n.t("inputs.empty")).font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                        ForEach(model.inputs) { info in
                            InputTile(info: info)
                                .contextMenu { contextMenu(info) }
                        }
                    }
                }
            }
        }
        .padding(8)
        .panel()
        .sheet(isPresented: $showTitleSheet) { TitleSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingTitle) { id in TitleSheet(editing: id).environmentObject(model) }
        .sheet(item: $keying) { id in ChromaKeySheet(input: id).environmentObject(model) }
        .sheet(item: $editingScene) { id in SceneEditorSheet(input: id).environmentObject(model) }
        .sheet(isPresented: $showBrowserSheet) { BrowserSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingBrowser) { id in BrowserSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showTimerSheet) { TimerSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingTimer) { id in TimerSheet(editing: id).environmentObject(model) }
        .sheet(isPresented: $showCaptureSheet) { CaptureSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingCapture) { id in CaptureSheet(editing: id).environmentObject(model) }
        .alert(L10n.t("inputs.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $renameText)
            Button(L10n.t("common.ok")) { if let id = renaming { model.rename(id, renameText) }; renaming = nil }
            Button(L10n.t("settings.cancel"), role: .cancel) { renaming = nil }
        }
    }

    private var addMenu: some View {
        Menu {
            Section(L10n.t("inputs.camera")) {
                if model.videoDevices.isEmpty { Text(L10n.t("inputs.no_cameras")) }
                ForEach(model.videoDevices) { d in Button(d.name) { model.addCamera(d) } }
            }
            Button(L10n.t("media.add")) { model.addMedia() }
            Button(L10n.t("media.add_playlist")) { model.addMediaPlaylist() }
            Button(L10n.t("inputs.image")) { model.addImage() }
            Button(L10n.t("inputs.title_generator")) { showTitleSheet = true }
            Button(L10n.t("capture.add")) { showCaptureSheet = true }
            Button(L10n.t("browser.add")) { showBrowserSheet = true }
            Button(L10n.t("timer.add")) { showTimerSheet = true }
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

    @ViewBuilder
    private func contextMenu(_ info: ProductionEngine.InputInfo) -> some View {
        Button(L10n.t("inputs.preview")) { model.preview(info.id) }
        Button(L10n.t("inputs.cutdirect")) { model.cutDirect(info.id) }
        Button(L10n.t("scene.edit")) { editingScene = info.id }
        Menu(L10n.t("inputs.addlayer")) {
            ForEach([LayoutPreset.pipTopRight, .pipTopLeft, .pipBottomRight, .pipBottomLeft, .sideBySideLeft, .sideBySideRight], id: \.self) { p in
                Button(p.rawValue) { model.addPiP(source: info.id, preset: p) }
            }
        }
        if info.kind == .camera || info.kind == .videoFile || info.kind == .image {
            Button(L10n.t("key.menu")) { keying = info.id }
        }
        if info.kind == .text { Button("Edit Title…") { editingTitle = info.id } }
        if info.kind == .browser {
            Button(L10n.t("browser.edit")) { editingBrowser = info.id }
            Button(L10n.t("browser.reload")) { model.browserSource(info.id)?.reload() }
        }
        if info.kind == .screen {
            Button(L10n.t("capture.edit")) { editingCapture = info.id }
            Button(L10n.t("capture.retry")) { model.captureSource(info.id)?.start() }
        }
        if info.kind == .timer {
            Button(L10n.t("timer.start")) { model.timerControl(info.id, "play") }
            Button(L10n.t("timer.pause")) { model.timerControl(info.id, "pause") }
            Button(L10n.t("timer.reset")) { model.timerControl(info.id, "reset") }
            Button(L10n.t("timer.edit")) { editingTimer = info.id }
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
        Button(L10n.t("inputs.remove"), role: .destructive) { model.remove(info.id) }
    }
}

extension InputID: Identifiable { public var id: String { raw } }

struct InputTile: View {
    @EnvironmentObject var model: AppModel
    let info: ProductionEngine.InputInfo

    private var isProgram: Bool { model.switcher.program == info.id || model.switcher.transition?.from == info.id }
    private var isPreview: Bool { model.switcher.preview == info.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                PixelBufferView(feed: model.feed(for: info.id))
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text("\(info.number)")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isProgram ? Theme.program : (isPreview ? Theme.preview : Color.black.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(info.status.label)
                Text(info.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            if info.kind == .videoFile, let v = model.videoFile(info.id) { MediaClock(video: v) }
            if !info.status.isHealthy, info.status != .starting {
                Text(info.status.label).font(.system(size: 9)).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
        .padding(4)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isProgram ? Theme.program : (isPreview ? Theme.preview : Theme.border), lineWidth: isProgram || isPreview ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.cutDirect(info.id) }
        .onTapGesture { model.preview(info.id) }
        .help("Click: Preview · Double-click: Cut to Program")
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
        }
    }
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
                        }.tag("w\(w.windowID)")
                    }
                }
                Section(L10n.t("capture.displays")) {
                    ForEach(displays, id: \.id) { d in Text(d.name).tag("d\(d.id)") }
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
                .disabled(config == nil)
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
            return ProjectScreenCapture(target: .window, bundleID: w.bundleID, appName: w.appName, windowTitle: w.title,
                                        captureAudio: audio, fps: fps, showsCursor: cursor)
        }
        if selection.hasPrefix("d"), let id = UInt32(selection.dropFirst()) {
            return ProjectScreenCapture(target: .display, displayID: id, captureAudio: audio, fps: fps, showsCursor: cursor)
        }
        return nil
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

/// Add or edit a web page input.
struct BrowserSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var url = "https://"
    @State private var size = 1080
    @State private var fps = 15
    @State private var transparent = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("browser.title")).font(.headline)
            HStack {
                TextField("https://…", text: $url)
                Button(L10n.t("browser.file")) {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.html]
                    if p.runModal() == .OK, let u = p.url { url = u.absoluteString }
                }
            }
            Picker(L10n.t("browser.size"), selection: $size) {
                Text("1920 × 1080").tag(1080)
                Text("1280 × 720").tag(720)
            }
            Picker(L10n.t("browser.fps"), selection: $fps) {
                ForEach(BrowserURLPolicy.allowedFPS, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Toggle(L10n.t("browser.transparent"), isOn: $transparent)
            Text(L10n.t("browser.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(Theme.warning).font(.system(size: 11)) }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    let w = size == 1080 ? 1920 : 1280
                    let err = editing.map { model.updateBrowser($0, url: url, width: w, height: size, fps: fps, transparent: transparent) }
                        ?? model.addBrowser(url: url, width: w, height: size, fps: fps, transparent: transparent)
                    if let err { error = err } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            if let id = editing, let b = model.browserSource(id)?.config {
                url = b.url; size = b.height >= 1080 ? 1080 : 720; fps = b.fps; transparent = b.transparent
            }
        }
    }
}

/// Add or edit a clock / countdown / count-up input.
struct TimerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var config = TimerConfig()
    @State private var minutes = 5
    @State private var seconds = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("timer.title")).font(.headline)
            Picker(L10n.t("timer.mode"), selection: $config.mode) {
                Text(L10n.t("timer.mode.countdown")).tag(TimerConfig.Mode.countdown)
                Text(L10n.t("timer.mode.countup")).tag(TimerConfig.Mode.countUp)
                Text(L10n.t("timer.mode.clock")).tag(TimerConfig.Mode.clock)
            }
            .pickerStyle(.segmented)
            if config.mode == .countdown {
                HStack {
                    Stepper("\(minutes) min", value: $minutes, in: 0...599)
                    Stepper("\(seconds) s", value: $seconds, in: 0...59)
                }
            }
            Toggle(L10n.t("timer.show_seconds"), isOn: $config.showSeconds)
            TextField(L10n.t("timer.label"), text: $config.label, prompt: Text(L10n.t("timer.label_prompt")))
            if config.mode != .clock {
                Text(L10n.t("timer.hint")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    config.durationSeconds = Double(minutes * 60 + seconds)
                    if let id = editing { model.updateTimer(id, config) } else { model.addTimer(config) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            if let id = editing, let t = model.timerSource(id) {
                config = t.config
                minutes = Int(t.config.durationSeconds) / 60; seconds = Int(t.config.durationSeconds) % 60
            }
        }
    }
}

/// Transport of a video input: seekbar (drag to scrub), position / length, previous, play/pause,
/// next (clips of a playlist; for a single clip previous goes back to the start).
struct MediaClock: View {
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
                    if video.autoPlay != .off { Text("AUTO").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.accent) }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            }
        }
    }
}

struct TitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var style = TextSource.Style(title: "Speaker Name", subtitle: "Title / Organisation")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("inputs.title_generator")).font(.headline)
            TextField(L10n.t("title.title"), text: $style.title)
            TextField(L10n.t("title.subtitle"), text: $style.subtitle)
            Picker(L10n.t("title.layout"), selection: $style.layout) {
                Text(L10n.t("title.layout.bar")).tag(TextSource.Layout.barLeft)
                Text(L10n.t("title.layout.full")).tag(TextSource.Layout.fullWidth)
                Text(L10n.t("title.layout.centered")).tag(TextSource.Layout.centered)
            }
            Toggle(L10n.t("title.bar"), isOn: $style.showBar).disabled(style.layout == .centered)
            HStack {
                Text(L10n.t("title.size")).frame(width: 110, alignment: .leading)
                Slider(value: Binding(get: { Double(style.titleSize) }, set: { style.titleSize = CGFloat($0) }), in: 24...110)
                Text("\(Int(style.titleSize))").monospacedDigit().frame(width: 30)
            }
            HStack {
                Text(L10n.t("title.subsize")).frame(width: 110, alignment: .leading)
                Slider(value: Binding(get: { Double(style.subtitleSize) }, set: { style.subtitleSize = CGFloat($0) }), in: 16...80)
                Text("\(Int(style.subtitleSize))").monospacedDigit().frame(width: 30)
            }
            HStack(spacing: 16) {
                ColorPicker(L10n.t("title.text_color"), selection: color(\.textColor), supportsOpacity: false)
                ColorPicker(L10n.t("title.bar_color"), selection: color(\.barColor), supportsOpacity: true)
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    if let id = editing { model.updateTitle(id, style: style) } else { model.addTitle(style) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            if let id = editing, let t = model.textSource(id) { style = t.style }
        }
    }

    private func color(_ key: WritableKeyPath<TextSource.Style, NSColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: style[keyPath: key]) },
                set: { style[keyPath: key] = NSColor($0) })
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
#endif
