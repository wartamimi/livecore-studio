#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let designer { DesignerBarIfActive(state: designer) }
            if let snapshot {
                HStack {
                    Spacer()
                    // Same size and style as RECORD / STREAM / FULLSCREEN.
                    Button(action: snapshot) {
                        Label(L10n.t("snapshot.button_big"), systemImage: "camera.fill")
                    }
                    .buttonStyle(StudioButtonStyle(color: Theme.accent))
                    .frame(width: StudioButtonStyle.mainWidth)
                    .help(L10n.t("snapshot.help"))
                }
                .padding(.top, 3).padding(.horizontal, 4)
            }
        }
        .padding(4)
        .panel()
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
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
                .help("Shortcut: \(model.shortcuts.cut)")
            Button(L10n.t("transition.auto")) { model.auto() }
                .buttonStyle(StudioButtonStyle(color: Theme.accent, active: model.switcher.transition != nil))
                .help("Shortcut: \(model.shortcuts.auto)")
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
