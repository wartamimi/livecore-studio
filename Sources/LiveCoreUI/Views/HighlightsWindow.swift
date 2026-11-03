#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Marked moments of a recording and the highlight video made from them (0.58.0).
struct HighlightsWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { model.markHighlight() } label: {
                    Label(L10n.f("package.highlight_button", "\(model.highlightCount)"), systemImage: "star.fill")
                }
                .help(L10n.t("highlights.mark_help"))
                Spacer()
                Button(L10n.t("highlights.last_recording")) { model.loadLastRecordingHighlights() }
                Button(L10n.t("highlights.open")) { model.openHighlightRecording() }
            }
            if let s = model.highlightSession {
                Text(s.recording.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                marksList(s)
                settings
                footer(s)
            } else {
                Spacer()
                Text(L10n.t("highlights.empty")).foregroundStyle(Theme.textDim).frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
        .padding(14)
        .onAppear { if model.highlightSession == nil { model.loadLastRecordingHighlights() } }
        .onChange(of: model.isRecording) { _ in model.loadLastRecordingHighlights() }
    }

    private func marksList(_ s: HighlightSession) -> some View {
        List {
            if s.marks.isEmpty { Text(L10n.t("highlights.none")).foregroundStyle(Theme.textDim) }
            ForEach(s.marks) { m in
                HStack(spacing: 8) {
                    Toggle("", isOn: binding(m, \.enabled)).labelsHidden()
                    Text(ClientPackage.timestamp(max(0, m.offset))).monospacedDigit().frame(width: 64, alignment: .leading)
                    TextField(L10n.t("highlights.title_hint"), text: binding(m, \.title))
                    Button { model.highlightSession?.marks.removeAll { $0.id == m.id }; model.saveHighlightSession() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 160)
    }

    private func binding<T>(_ m: HighlightMark, _ kp: WritableKeyPath<HighlightMark, T>) -> Binding<T> {
        Binding(get: { model.highlightSession?.marks.first { $0.id == m.id }?[keyPath: kp] ?? m[keyPath: kp] },
                set: { v in
                    guard let i = model.highlightSession?.marks.firstIndex(where: { $0.id == m.id }) else { return }
                    model.highlightSession?.marks[i][keyPath: kp] = v
                    model.saveHighlightSession()
                })
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text(L10n.t("highlights.pre_roll"))
                Stepper(value: $model.highlightSettings.preRoll, in: 0...120, step: 1) {
                    Text(L10n.f("qr.seconds", "\(Int(model.highlightSettings.preRoll))")).monospacedDigit()
                }
                Text(L10n.t("highlights.post_roll"))
                Stepper(value: $model.highlightSettings.postRoll, in: 0...120, step: 1) {
                    Text(L10n.f("qr.seconds", "\(Int(model.highlightSettings.postRoll))")).monospacedDigit()
                }
            }
            GridRow {
                Text(L10n.t("highlights.crossfade"))
                HStack {
                    Slider(value: $model.highlightSettings.crossfade, in: 0...2)
                    Text(String(format: "%.1f s", model.highlightSettings.crossfade)).monospacedDigit().frame(width: 40)
                }
                Text(L10n.t("highlights.format"))
                Picker("", selection: $model.highlightSettings.format) {
                    Text("16:9").tag(HighlightFormat.landscape)
                    Text("9:16").tag(HighlightFormat.vertical)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            GridRow {
                Toggle(L10n.t("highlights.fade_ends"), isOn: $model.highlightSettings.fadeEnds).gridCellColumns(2)
                Toggle(L10n.t("highlights.separate"), isOn: $model.highlightSettings.separateClips).gridCellColumns(2)
            }
        }
        .font(.system(size: 12))
    }

    private func footer(_ s: HighlightSession) -> some View {
        let duration = s.marks.map(\.offset).max().map { $0 + model.highlightSettings.postRoll } ?? 0
        let ranges = HighlightPlan.ranges(s.marks, duration: duration, settings: model.highlightSettings)
        let total = HighlightPlan.totalDuration(HighlightPlan.timeline(ranges, crossfade: model.highlightSettings.crossfade))
        return HStack {
            Text(L10n.f("highlights.estimate", "\(ranges.count)", ClientPackage.timestamp(total)))
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            if let p = model.highlightProgress {
                ProgressView().controlSize(.small)
                Text(p).font(.system(size: 11))
            }
            Button(L10n.t("highlights.make")) { model.makeHighlightVideo() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.highlightProgress != nil || model.highlightRecordingBusy || ranges.isEmpty)
        }
    }
}
#endif
