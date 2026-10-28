#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Instant replay under the T-bar: buffer on/off, replay the last 5/10/20 s, speed, transport.
/// Sized for the narrow transition column.
struct ReplaySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(L10n.t("replay.title").uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim)
                Spacer(minLength: 0)
                Toggle(L10n.t("replay.buffer"), isOn: Binding(get: { model.replayEnabled }, set: { model.setReplayEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(L10n.t("replay.help"))
            }
            if model.replayEnabled {
                HStack(spacing: 3) {
                    ForEach(ReplayIndex.lengths, id: \.self) { sec in
                        Button("\(Int(sec))s") { model.replayLast(sec) }
                            .font(.system(size: 10, weight: .bold))
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(model.replayAvailable < 1)
                            .help(L10n.f("replay.last", Int(sec)))
                    }
                }
                HStack(spacing: 4) {
                    Picker("", selection: $model.replaySpeed) {
                        ForEach(ReplayIndex.speeds, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                    .help(L10n.t("replay.speed"))
                    if let r = model.replaySource, r.hasClip {
                        Button { r.isPlaying ? r.pause() : r.play() } label: { Image(systemName: r.isPlaying ? "pause.fill" : "play.fill") }
                            .buttonStyle(.borderless)
                        Button { r.cue() } label: { Image(systemName: "backward.end.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                Text(L10n.f("replay.available", Int(model.replayAvailable)))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// Stream destinations and live statistics (STREAM ⚙ in the bottom dock).
struct StreamDetails: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("stream.title"))
            ForEach(destinationRows, id: \.id) { row in
                HStack(spacing: 6) {
                    Circle().fill(color(row.stats)).frame(width: 7, height: 7)
                    Text(row.name).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Text(row.detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(row.warn ? Theme.warning : Theme.textDim)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            statsView
        }
    }

    @ViewBuilder private var statsView: some View {
        let s = model.streamStats
        switch s.state {
        case .live, .reconnecting, .connecting:
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow { label(L10n.t("stream.bitrate")); value(String(format: "%.0f kbps", s.bitrateKbps)) }
                GridRow { label(L10n.t("top.dropped")); value("\(s.droppedVideoFrames) net · \(s.encoderDropped) enc") }
                GridRow { label(L10n.t("stream.queue")); value("\(s.queuedMs) ms") }
                GridRow { label("Reconnects"); value("\(s.reconnects)") }
                GridRow { label("Encoder"); value(s.encoderHardware ? L10n.t("stream.encoder_hw") : L10n.t("stream.encoder_sw")) }
            }
        case let .failed(reason):
            Text(reason).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private struct Row { var id: String; var name: String; var stats: StreamingEngine.Stats?; var detail: String; var warn: Bool }

    /// While streaming: the destinations of this session. Otherwise: the configured ones, with key status.
    private var destinationRows: [Row] {
        if !model.streamTargets.isEmpty && (model.isStreamingActive || model.destinationStats.values.contains { if case .failed = $0.state { return true }; return false }) {
            return model.streamTargets.map { t in
                let s = model.destinationStats[t.id]
                return Row(id: t.id, name: t.name, stats: s, detail: s.map(stateText) ?? L10n.t("stream.connecting"), warn: s.map(isWarn) ?? false)
            }
        }
        let st = model.settings.stream
        var rows: [Row] = []
        func row(_ id: String, _ name: String, _ enabled: Bool, _ url: String, _ hasKey: Bool) {
            let detail = !enabled ? L10n.t("stream.dest_off") : url.isEmpty ? L10n.t("stream.dest_no_server") : hasKey ? L10n.t("stream.key_saved") : L10n.t("stream.key_missing")
            rows.append(Row(id: id, name: name.isEmpty ? id : name, stats: nil, detail: detail, warn: enabled && (url.isEmpty || !hasKey)))
        }
        row(AppModel.primaryDestinationID, st.primaryName, st.primaryEnabled, st.serverURL, model.hasStreamKey)
        for d in st.additional { row(d.id, d.name, d.enabled, d.serverURL, model.hasKey(account: d.keychainAccount)) }
        return rows
    }

    private func stateText(_ s: StreamingEngine.Stats) -> String {
        switch s.state {
        case .idle: return L10n.t("stream.idle")
        case .connecting: return L10n.t("stream.connecting")
        case .live: return String(format: "%.0f kbps", s.bitrateKbps)
        case let .reconnecting(attempt, _): return L10n.f("stream.reconnecting", attempt)
        case let .failed(reason): return reason
        case .stopping: return L10n.t("stream.stopping")
        }
    }

    private func isWarn(_ s: StreamingEngine.Stats) -> Bool {
        switch s.state {
        case .failed, .reconnecting: return true
        default: return false
        }
    }

    private func color(_ s: StreamingEngine.Stats?) -> Color {
        guard let s else { return Theme.textDim.opacity(0.5) }
        switch s.state {
        case .live: return Theme.program
        case .failed, .reconnecting: return Theme.warning
        case .connecting: return Theme.accent
        default: return Theme.textDim.opacity(0.5)
        }
    }

    private func label(_ s: String) -> some View { Text(s).font(.system(size: 10)).foregroundStyle(Theme.textDim) }
    private func value(_ s: String) -> some View { Text(s).font(.system(size: 11).monospacedDigit()) }
}

/// Padlock next to Stream / Record: while locked the button cannot start or stop anything.
struct LockButton: View {
    @Binding var locked: Bool
    let help: String
    var body: some View {
        Button { locked.toggle() } label: { Image(systemName: locked ? "lock.fill" : "lock.open") }
            .buttonStyle(StudioButtonStyle(color: Theme.warning, active: locked))
            .frame(width: 36)
            .help(help)
    }
}

/// Recording folder, options and the file being written (RECORD ⚙ in the bottom dock).
struct RecordDetails: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(RecordReminderMode.storageKey) private var reminder = RecordReminderMode.always.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("record.title"))
            Text(folderLabel).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.head)
            Picker(L10n.t("record.reminder"), selection: $reminder) {
                ForEach(RecordReminderMode.allCases, id: \.self) { m in Text(L10n.t("record.reminder." + m.rawValue)).tag(m.rawValue) }
            }
            .font(.system(size: 11))
            .help(L10n.t("record.reminder_help"))
            Toggle(L10n.t("record.with_stream"), isOn: $model.recordWithStream)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .help(L10n.t("record.with_stream_help"))
            if let snap = model.lastSnapshotURL {
                Button(L10n.f("snapshot.saved", snap.lastPathComponent)) { NSWorkspace.shared.activateFileViewerSelecting([snap]) }
                    .buttonStyle(.link).font(.system(size: 10)).lineLimit(1)
            }
            switch model.recordStats.state {
            case let .recording(url):
                Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1)
                Text("\(formatDuration(model.recordStats.duration)) · \(ByteCountFormatter.string(fromByteCount: model.recordStats.fileBytes, countStyle: .file)) · \(L10n.t("record.free")) \(ByteCountFormatter.string(fromByteCount: model.recordStats.freeBytes, countStyle: .file))")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
                if model.recordStats.droppedVideoFrames > 0 {
                    Text("\(model.recordStats.droppedVideoFrames) frames dropped by writer").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
            case let .finished(url, bytes):
                Text(L10n.f("record.saved", url.lastPathComponent)).font(.system(size: 10)).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Button(L10n.t("record.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
            case let .failed(msg):
                Text(msg).font(.system(size: 11)).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            case .finishing:
                ProgressView().controlSize(.small)
            case .idle:
                EmptyView()
            }
        }
    }

    private var folderLabel: String {
        model.settings.recording.folderPath.isEmpty ? RecordingEngine.defaultFolder().path : model.settings.recording.folderPath
    }
}
/// MULTICORDER ⚙: pick up to 4 inputs recorded to their own files, see each file's state.
struct MultiCorderDetails: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "ISOCorder")
            let p = model.settings.multiCorderRecording
            Text("\(p.videoCodec.label)\(p.videoCodec.usesBitrate ? " · \(p.bitrateKbps / 1000) Mbps" : "") · \(p.effectiveContainer.rawValue.uppercased()) · \(model.settings.output.size.width)×\(model.settings.output.size.height) \(model.settings.output.frameRate) fps")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
            ForEach(model.inputs) { i in
                let on = model.multiCorder.contains(i.id)
                Toggle(isOn: Binding(get: { on }, set: { _ in model.toggleISO(i.id) })) {
                    HStack(spacing: 5) {
                        if let t = model.inputTags[i.id] { Circle().fill(t.color).frame(width: 7, height: 7) }
                        Text("\(i.number)  \(i.name)").lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox).font(.system(size: 11))
                .disabled(model.isMultiCorderRunning || (!on && model.multiCorder.isFull))
            }
            if model.inputs.isEmpty {
                Text(L10n.t("multicorder.no_inputs")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            Text(L10n.f("multicorder.help", MultiCorderConfig.maxInputs)).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.f("recprofile.estimate", p.gigabytesPerHour(output: model.settings.output, files: model.multiCorder.inputs.count),
                        model.multiCorder.inputs.count))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
            ForEach(model.isoFiles) { f in isoRow(f.input, f.stats) }
        }
    }

    @ViewBuilder
    private func isoRow(_ i: ProductionEngine.InputInfo, _ s: RecordingEngine.Stats) -> some View {
        HStack(spacing: 4) {
            switch s.state {
            case .recording:
                Circle().fill(Theme.program).frame(width: 6, height: 6)
                Text("ISO \(i.number)  \(ByteCountFormatter.string(fromByteCount: s.fileBytes, countStyle: .file))")
                if s.droppedVideoFrames > 0 { Text("· \(s.droppedVideoFrames) drop").foregroundStyle(Theme.warning) }
            case let .finished(url, bytes):
                Text("ISO \(i.number)  \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                Button(L10n.t("record.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
            case let .failed(msg):
                Text("ISO \(i.number): \(msg)").foregroundStyle(Theme.warning).lineLimit(2)
            case .finishing:
                Text("ISO \(i.number)"); ProgressView().controlSize(.mini)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 10).monospacedDigit())
    }
}
/// Transparent click target that tells a primary click from a secondary one (two-finger click
/// on a trackpad, right click, or control-click). SwiftUI has no secondary-click action on macOS 13.
struct TwoClickArea: NSViewRepresentable {
    let primary: () -> Void
    let secondary: () -> Void

    final class ClickView: NSView {
        var primary: () -> Void = {}
        var secondary: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { secondary() } else { primary() }
        }
        override func rightMouseDown(with event: NSEvent) { secondary() }
    }

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.primary = primary; v.secondary = secondary
        return v
    }

    func updateNSView(_ v: ClickView, context: Context) {
        v.primary = primary; v.secondary = secondary
    }
}
#endif
