#if os(macOS)
import SwiftUI
import LiveCoreCore

/// Preview | Transition controls | Program
struct MonitorRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            MonitorView(title: L10n.t("monitor.preview"), color: Theme.preview, feed: model.previewFeed,
                        inputName: name(model.switcher.preview), live: false)
            TransitionControls().frame(width: 150)
            MonitorView(title: L10n.t("monitor.program"), color: Theme.program, feed: model.programFeed,
                        inputName: name(model.switcher.transition?.to ?? model.switcher.program),
                        live: model.isStreamingActive || model.isRecording)
        }
    }

    private func name(_ id: InputID?) -> String {
        guard let id, let i = model.inputs.first(where: { $0.id == id }) else { return L10n.t("monitor.no_input") }
        return "\(i.number) · \(i.name)"
    }
}

struct MonitorView: View {
    let title: String
    let color: Color
    let feed: FrameFeed
    let inputName: String
    let live: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .heavy)).foregroundStyle(color)
                Text(inputName).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1)
                Spacer()
                if live {
                    Text("ON AIR").font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.program).clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            PixelBufferView(feed: feed)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(Rectangle().stroke(color, lineWidth: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(4)
        .panel()
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
            VStack(spacing: 2) {
                Text("T-BAR").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim)
                Slider(value: Binding(get: { model.tbar }, set: { model.setTBar($0) }), in: 0...1)
            }
            if let t = model.switcher.transition {
                ProgressView(value: t.manualPosition ?? 0).opacity(t.manualPosition == nil ? 0 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
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
#endif
