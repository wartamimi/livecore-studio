#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Preview | Transition controls | Program
struct MonitorRow: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(RecordReminderMode.storageKey) private var reminder = RecordReminderMode.always.rawValue
    @StateObject private var designer = LayerDesignerState()

    var body: some View {
        HStack(spacing: 6) {
            MonitorView(title: L10n.t("monitor.preview"), color: Theme.preview, feed: model.previewFeed,
                        inputName: name(model.switcher.preview), live: false, designer: designer)
                .onChange(of: model.switcher.preview) { id in if designer.active { designer.load(model, input: id) } }
                .onChange(of: designer.active) { on in if on { designer.load(model, input: model.switcher.preview) } else { model.editorUndo = nil } }
            TransitionControls().frame(width: 170)
            MonitorView(title: L10n.t("monitor.program"), color: Theme.program, feed: model.programFeed,
                        inputName: name(model.switcher.transition?.to ?? model.switcher.program),
                        live: model.isStreamingActive || model.isRecording,
                        notRecording: RecordReminder.applies(mode: RecordReminderMode(rawValue: reminder) ?? .always,
                                                             recording: model.isRecording, streaming: model.isStreamingActive),
                        snapshot: { model.saveSnapshot() })
        }
    }

    private func name(_ id: InputID?) -> String {
        guard let id, let i = model.inputs.first(where: { $0.id == id }) else { return L10n.t("monitor.no_input") }
        return "\(i.number) · \(i.name)"
    }
}

struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let color: Color
    let feed: FrameFeed
    let inputName: String
    let live: Bool
    var notRecording = false
    /// Program only: camera button under the picture, at the right, that saves a PNG.
    var snapshot: (() -> Void)? = nil
    /// Preview only: the Layer Designer (button in the header, tools under the picture).
    var designer: LayerDesignerState? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .heavy)).foregroundStyle(color)
                Text(inputName).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer()
                if let designer { DesignerToggle(state: designer) }
                if live {
                    Text("ON AIR").font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.program).clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            PixelBufferView(feed: feed)
                .aspectRatio(model.canvasAspect, contentMode: .fit)   // follows Settings › Canvas
                .overlay(Rectangle().stroke(color, lineWidth: 2))
                .overlay { MonitorGuides() }
                .overlay(alignment: .top) { if notRecording { NotRecordingBadge().padding(.top, 8) } }
                .overlay { if let designer { DesignerCanvasIfActive(state: designer) } }
                .overlay { if snapshot != nil { SnapshotConfirmation() } }
                .modifier(ProgramContextMenu(enabled: snapshot != nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let designer { DesignerBarIfActive(state: designer) }
            if snapshot != nil { ProgramTransportBar() }
            // Media controller under Preview too (0.61.0), so a clip can be cued / checked before
            // it goes on air. Hidden while the Layer Designer uses that space.
            if let designer { PreviewTransportIfIdle(state: designer) }
            // Screenshot / Grab as Still: right-click (two-finger click) on Program (0.49.0).
        }
        .padding(4)
        .panel()
    }
}

/// Preview media controller, hidden while the Layer Designer is open.
private struct PreviewTransportIfIdle: View {
    @ObservedObject var state: LayerDesignerState
    var body: some View { if !state.active { ProgramTransportBar(preview: true) } }
}

/// Program monitor right-click (two-finger click on a trackpad), 0.49.0: Screenshot saves a PNG
/// of Program, Grab as Still also adds it as a new image input. Replaces the PHOTO dock button.
private struct ProgramContextMenu: ViewModifier {
    @EnvironmentObject var model: AppModel
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button { model.saveSnapshot() } label: { Label(L10n.t("program.screenshot"), systemImage: "camera") }
                Button { model.grabStill() } label: { Label(L10n.t("program.grab_still"), systemImage: "photo.badge.plus") }
                Divider()
                // Fullscreen on a chosen display (0.63.0).
                Menu {
                    let displays = model.fullscreenDisplays
                    if displays.isEmpty { Text(L10n.t("program.fullscreen_none")) }
                    ForEach(displays, id: \.id) { d in
                        Button(d.isMain ? L10n.f("program.fullscreen_main", d.name) : d.name) { model.fullscreenProgram(on: d) }
                    }
                    if model.isFullscreenActive {
                        Divider()
                        Button(L10n.t("program.fullscreen_close")) { model.toggleFullscreen() }
                    }
                } label: { Label(L10n.t("program.fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right") }
            }
        } else {
            content
        }
    }
}

/// PHOTO feedback on the Program monitor: a short white flash and a banner with the file name
/// (click it to show the file in Finder). Never drawn on the real output.
private struct SnapshotConfirmation: View {
    @EnvironmentObject var model: AppModel
    @State private var flash = 0.0
    @State private var shownAt: Date?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white.opacity(flash).allowsHitTesting(false)
            if let at = shownAt, let url = model.lastSnapshotURL, at == model.lastSnapshotAt {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.preview)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L10n.t("snapshot.saved_title")).font(.system(size: 12, weight: .bold))
                            Text(url.lastPathComponent).font(.system(size: 10)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L10n.t("snapshot.show_in_finder"))
                .overlay(alignment: .topTrailing) {
                    // The photo as a new image input (vMix "snapshot to input").
                    Button { model.addImageInput(url); shownAt = nil } label: {
                        Label(L10n.t("snapshot.as_input"), systemImage: "plus.rectangle.on.rectangle")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.accent).foregroundStyle(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 8, y: -16)
                }
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .onChange(of: model.lastSnapshotAt) { at in
            guard let at else { return }
            flash = 0.7
            withAnimation(.easeOut(duration: 0.35)) { flash = 0 }
            withAnimation(.easeOut(duration: 0.2)) { shownAt = at }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if shownAt == at { withAnimation(.easeIn(duration: 0.3)) { shownAt = nil } }
            }
        }
    }
}

/// Header button of the Preview monitor that opens / closes the Layer Designer.
private struct DesignerToggle: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: LayerDesignerState
    var body: some View {
        Button { if state.active { state.close() } else { state.active = true } } label: {
            Label(L10n.t("designer.button"), systemImage: "square.on.square.dashed")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(state.active ? Theme.accent : Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .disabled(model.switcher.preview == nil)
        .help(L10n.t("designer.help"))
    }
}

private struct DesignerCanvasIfActive: View {
    @ObservedObject var state: LayerDesignerState
    var body: some View { if state.active { LayerDesignerCanvas(state: state) } }
}

private struct DesignerBarIfActive: View {
    @ObservedObject var state: LayerDesignerState
    var body: some View { if state.active { LayerDesignerBar(state: state) } }
}

/// Controller under the Program monitor (0.55.0): transport of the input on Program. Video
/// files and playlists get restart / previous / play-pause / next and a seek bar; presentations
/// get first / previous / next slide. Hidden for other inputs (0.55.1). Narrow monitors drop the
/// remaining time and the AUTO / loop toggles.
struct ProgramTransportBar: View {
    @EnvironmentObject var model: AppModel
    @State private var scrub: Double?
    /// Controls the input on Preview instead of Program (0.61.0).
    var preview = false

    private var programID: InputID? { preview ? model.switcher.preview : (model.switcher.transition?.to ?? model.switcher.program) }

    /// Hidden while the input on Program has nothing to control (camera, title, colour...).
    var body: some View {
        if let id = programID, model.videoFile(id) != nil || model.presentationSource(id) != nil {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                ViewThatFits(in: .horizontal) {
                    bar(compact: false)
                    bar(compact: true)
                }
            }
            .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 2)
            .frame(height: 30)
        }
    }

    @ViewBuilder private func bar(compact: Bool) -> some View {
        let video = programID.flatMap { model.videoFile($0) }
        let slides = video == nil ? programID.flatMap { model.presentationSource($0) } : nil
        let info = programID.flatMap { id in model.inputs.first { $0.id == id } }
        HStack(spacing: 6) {
            if let v = video {
                key("backward.end.fill", L10n.t("transport.restart")) { v.seek(to: 0) }
                key("backward.fill", L10n.t("transport.previous")) { v.previousClip() }
                key(v.isPlaying ? "pause.fill" : "play.fill", L10n.t("transport.play_pause"), on: v.isPlaying) {
                    v.isPlaying ? v.pause() : v.play()
                }
                key("forward.fill", L10n.t("transport.next")) { v.nextClip() }.disabled(!v.isPlaylist)
                if let d = v.duration, d > 0 {
                    Slider(value: Binding(get: { scrub ?? min(v.position, d) }, set: { scrub = $0; v.seek(to: $0) }),
                           in: 0...d, onEditingChanged: { if !$0 { scrub = nil } })
                        .controlSize(.small)
                        .frame(minWidth: 60)
                    Text(TimerMath.duration(scrub ?? v.position)).foregroundStyle(Theme.text)
                    if !compact { Text("-" + TimerMath.duration(max(d - (scrub ?? v.position), 0))).foregroundStyle(Theme.program) }
                } else {
                    Spacer(minLength: 0)
                }
                if v.isPlaylist { Text("\(v.index + 1)/\(v.urls.count)") }
                if !compact {
                    // Loop (0.61.0): repeat the clip / playlist.
                    toggle("LOOP", on: v.loop, help: L10n.t("transport.loop")) {
                        v.loop.toggle(); model.objectWillChange.send()
                    }
                    toggle("AUTO", on: v.autoPlayEnabled, help: L10n.t("media.auto_help")) {
                        model.setAutoPlayEnabled(!v.autoPlayEnabled, for: v.id)
                    }
                    toggle("↺", on: v.autoRestart, help: L10n.t(v.autoRestart ? "media.restart_on_help" : "media.restart_off_help")) {
                        model.setAutoRestart(!v.autoRestart, for: v.id)
                    }
                }
            } else if let p = slides {
                key("backward.end.fill", L10n.t("presentation.first")) { p.first() }
                key("chevron.left", L10n.t("presentation.previous")) { p.previous() }
                key("chevron.right", L10n.t("presentation.next")) { p.next() }
                if let s = info?.slide, s.count > 0 { Text(L10n.f("presentation.counter", String(s.index), String(s.count))) }
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.textDim)
        .lineLimit(1)
    }

    /// Square transport key in the studio style (same look as the dock buttons, smaller).
    private func key(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 22)
                .background(on ? Theme.program : Theme.panelRaised)
                .foregroundStyle(on ? Color.white : Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Theme.program : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle(_ label: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .heavy))
                .frame(minWidth: 26, minHeight: 22)
                .padding(.horizontal, 7)
                .background(on ? Theme.accent : Theme.panelRaised)
                .foregroundStyle(on ? Color.white : Theme.textDim)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct TransitionControls: View {
    @EnvironmentObject var model: AppModel

    /// Built-in kinds are tagged "kind:<raw value>"; custom shaders by their library id.
    private var choice: Binding<String> {
        Binding(
            get: {
                if model.transitionKind == .custom, let id = model.customTransitionID { return id }
                return "kind:\(model.transitionKind.rawValue)"
            },
            set: { tag in
                if tag.hasPrefix("kind:"), let raw = Int(tag.dropFirst(5)), let k = TransitionKind(rawValue: raw) {
                    model.transitionKind = k
                } else {
                    model.selectCustomTransition(tag)
                }
            })
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 8) {
            SectionHeader(title: L10n.t("transition.type"))
            Picker("", selection: choice) {
                ForEach(TransitionKind.allCases.filter { $0 != .cut && $0 != .custom }, id: \.self) { k in
                    Text(k.displayName).tag("kind:\(k.rawValue)")
                }
                if !model.customTransitions.isEmpty {
                    Divider()
                    ForEach(model.customTransitions) { t in Text(t.isBuiltIn ? t.name : "\(t.name) ✎").tag(t.id) }
                }
            }
            .labelsHidden()
            if model.transitionKind == .custom {
                CustomTransitionControls()
            }
            if model.transitionKind == .stinger {
                StingerControls()
            } else {
                HStack {
                    Text(L10n.t("transition.duration")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(String(format: "%.1fs", model.transitionDuration)).font(.system(size: 11).monospacedDigit())
                }
                Slider(value: $model.transitionDuration, in: 0.2...5, step: 0.1)
            }
            Button(L10n.t("transition.cut")) { model.cut() }
                .buttonStyle(StudioButtonStyle(color: Theme.program))
                .help(model.shortcuts.combo(for: .cut).map { "Shortcut: \($0.display)" } ?? "CUT")
            Button(L10n.t("transition.auto")) { model.auto() }
                .buttonStyle(StudioButtonStyle(color: Theme.accent, active: model.switcher.transition != nil))
                .help(model.shortcuts.combo(for: .auto).map { "Shortcut: \($0.display)" } ?? "AUTO")
            // Manual T-bar
            TBarControl()
            Divider()
            ReplaySection()
            Spacer(minLength: 0)
        }
        .padding(8)
        }
        .panel()
    }
}
/// Stinger clip (a video file input, ideally with alpha) and the point where A cuts to B.
struct StingerControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let clips = model.inputs.filter { $0.kind == .videoFile }
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(get: { model.stinger.source },
                                          set: { model.setStinger(source: $0, cutPoint: nil) })) {
                Text(L10n.t("stinger.none")).tag(InputID?.none)
                ForEach(clips) { i in Text("\(i.number) \(i.name)").tag(Optional(i.id)) }
            }
            .labelsHidden()
            if let d = model.stingerDuration {
                let cut = min(model.stinger.cutPoint ?? d / 2, d)
                HStack {
                    Text(L10n.t("stinger.cut_point")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text(String(format: "%.2f / %.2fs", cut, d)).font(.system(size: 11).monospacedDigit())
                }
                Slider(value: Binding(get: { cut }, set: { model.setStinger(source: model.stinger.source, cutPoint: $0) }),
                       in: 0...d)
            } else {
                Text(clips.isEmpty ? L10n.t("stinger.add_clip") : L10n.t("stinger.choose"))
                    .font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(L10n.t("stinger.help"))
    }
}

/// Shader file actions and the compiler message for custom transitions.
struct CustomTransitionControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let err = model.customTransitionError {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.program)
                    .lineLimit(6)
                    .textSelection(.enabled)
                Text(L10n.t("transition.custom.fallback")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 4) {
                Button(L10n.t("transition.custom.new")) { model.newCustomTransition() }
                Button(L10n.t("transition.custom.import")) { model.importCustomTransition() }
            }
            HStack(spacing: 4) {
                Button(L10n.t("transition.custom.reload")) { model.reloadCustomTransitions() }
                Button(L10n.t("transition.custom.folder")) { model.revealCustomTransitionsFolder() }
            }
        }
        .controlSize(.small)
        .font(.system(size: 10))
    }
}
/// Operator guides drawn over Preview and Program only (never on the output): safe areas,
/// rule of thirds, centre cross and a 9:16 / 4:3 crop frame (Settings › Canvas, 0.45.0).
struct MonitorGuides: View {
    @AppStorage("guides.safe") private var safe = false
    @AppStorage("guides.thirds") private var thirds = false
    @AppStorage("guides.center") private var center = false
    @AppStorage("guides.crop") private var crop = ""   // "", "9:16", "4:3", "1:1"

    var body: some View {
        if safe || thirds || center || !crop.isEmpty {
            Canvas { ctx, size in
                let line = GraphicsContext.Shading.color(.white.opacity(0.55))
                func box(_ f: CGFloat) -> CGRect {
                    CGRect(x: size.width * (1 - f) / 2, y: size.height * (1 - f) / 2, width: size.width * f, height: size.height * f)
                }
                if safe {
                    ctx.stroke(Path(box(0.93)), with: line, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    ctx.stroke(Path(box(0.90)), with: .color(.yellow.opacity(0.6)), lineWidth: 1)
                }
                if thirds {
                    var p = Path()
                    for i in 1...2 {
                        let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 1)
                }
                if center {
                    var p = Path()
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), r: CGFloat = 12
                    p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
                    ctx.stroke(p, with: line, lineWidth: 1.5)
                }
                let ratio: CGFloat? = crop == "9:16" ? 9.0 / 16 : crop == "4:3" ? 4.0 / 3 : crop == "1:1" ? 1 : nil
                if let ratio {
                    var w = size.height * ratio, h = size.height
                    if w > size.width { w = size.width; h = w / ratio }
                    let r = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                    var outside = Path(CGRect(origin: .zero, size: size)); outside.addRect(r)
                    ctx.fill(outside, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                    ctx.stroke(Path(r), with: .color(.cyan.opacity(0.8)), lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
#endif
