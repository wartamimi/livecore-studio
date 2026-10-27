#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Lower-right control area: overlays and instant replay. Record / Stream / External live in
/// the bottom dock (OutputDockView).
struct ControlPanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                OverlaySection()
                Divider()
                ReplaySection()
            }
            .padding(8)
        }
        .panel()
    }
}

/// Instant replay: buffer on/off, replay the last 5/10/20 s, speed, transport.
struct ReplaySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.t("replay.title"))
                Spacer()
                Toggle(L10n.t("replay.buffer"), isOn: Binding(get: { model.replayEnabled }, set: { model.setReplayEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .help(L10n.t("replay.help"))
            }
            if model.replayEnabled {
                HStack(spacing: 6) {
                    ForEach(ReplayIndex.lengths, id: \.self) { sec in
                        Button(L10n.f("replay.last", Int(sec))) { model.replayLast(sec) }
                            .buttonStyle(StudioButtonStyle(color: Theme.preview, active: false))
                            .disabled(model.replayAvailable < 1)
                    }
                }
                HStack(spacing: 6) {
                    Picker(L10n.t("replay.speed"), selection: $model.replaySpeed) {
                        ForEach(ReplayIndex.speeds, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 170)
                    if let r = model.replaySource, r.hasClip {
                        Button { r.isPlaying ? r.pause() : r.play() } label: { Image(systemName: r.isPlaying ? "pause.fill" : "play.fill") }
                            .buttonStyle(.borderless)
                        Button { r.cue() } label: { Image(systemName: "backward.end.fill") }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Text(L10n.f("replay.available", Int(model.replayAvailable)))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
                }
            }
        }
    }
}

struct OverlaySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("overlay.title"))
            ForEach(model.overlays, id: \.index) { ch in
                HStack(spacing: 6) {
                    // Click = Preview (orange), secondary / two-finger click = Program (green).
                    Button("\(ch.index)") {}
                        .buttonStyle(StudioButtonStyle(color: ch.isOn ? Theme.overlayProgram : Theme.overlayPreview,
                                                       active: ch.isOn || ch.onPreview))
                        .frame(width: 44)
                        .overlay(TwoClickArea(primary: { model.toggleOverlayPreview(ch.index) },
                                              secondary: { model.toggleOverlay(ch.index) }))
                        .disabled(ch.source == nil)
                        .help(L10n.t("overlay.help"))
                    Picker("", selection: Binding(get: { ch.source }, set: { model.configureOverlay(ch.index, source: $0, preset: ch.preset) })) {
                        Text(L10n.t("overlay.none")).tag(InputID?.none)
                        ForEach(model.inputs) { i in Text("\(i.number) \(i.name)").tag(Optional(i.id)) }
                    }
                    .labelsHidden()
                    Picker("", selection: Binding(get: { ch.preset }, set: { model.configureOverlay(ch.index, source: ch.source, preset: $0) })) {
                        ForEach(LayoutPreset.allCases, id: \.self) { p in Text(p.rawValue).tag(p) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Menu {
                        Section(L10n.t("overlay.animation")) {
                            ForEach(OverlayAnimation.allCases, id: \.self) { a in
                                Button((ch.animation == a ? "✓ " : "") + L10n.t("overlay.anim." + a.rawValue)) {
                                    model.setOverlayAnimation(ch.index, animation: a, duration: ch.fadeDuration)
                                }
                            }
                        }
                        Section(L10n.t("overlay.duration")) {
                            ForEach([0.25, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { d in
                                Button((abs(ch.fadeDuration - d) < 0.01 ? "✓ " : "") + String(format: "%.2g s", d)) {
                                    model.setOverlayAnimation(ch.index, animation: ch.animation, duration: d)
                                }
                            }
                        }
                    } label: { Image(systemName: "wand.and.stars") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.t("overlay.animation_help"))
                }
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
