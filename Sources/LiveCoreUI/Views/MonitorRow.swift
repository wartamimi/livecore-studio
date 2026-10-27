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

    var body: some View {
        VStack(spacing: 8) {
            SectionHeader(title: L10n.t("transition.type"))
            Picker("", selection: $model.transitionKind) {
                ForEach(TransitionKind.allCases.filter { $0 != .cut }, id: \.self) { k in Text(k.displayName).tag(k) }
            }
            .labelsHidden()
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
#endif
