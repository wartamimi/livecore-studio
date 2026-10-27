#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Lower-right control area: overlays, streaming and recording.
struct ControlPanelView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                OverlaySection()
                Divider()
                StreamSection(showSettings: $showSettings)
                Divider()
                RecordSection()
                Divider()
                ReplaySection()
                if model.zoomAvailable {
                    Divider()
                    ZoomSection()
                }
            }
            .padding(8)
        }
        .panel()
    }
}

/// Zoom meeting: sign in, join, participants as inputs, return feed.
struct ZoomSection: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("zoom.lastMeeting") private var meeting = ""
    @AppStorage("zoom.displayName") private var displayName = "LiveCore Studio"
    @State private var passcode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: "Zoom")
                Spacer()
                Text(stateText).font(.system(size: 10, weight: .semibold)).foregroundStyle(stateColor)
            }
            if !model.zoomMessage.isEmpty {
                Text(model.zoomMessage).font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            switch model.zoomState {
            case .notAuthorized, .failed:
                Button(L10n.t("zoom.sign_in")) { model.zoomAuthorize() }
                    .disabled(!model.zoomHasCredentials)
                if !model.zoomHasCredentials { Text(L10n.t("zoom.no_credentials")).font(.system(size: 10)).foregroundStyle(Theme.warning) }
            case .authorizing, .joining:
                ProgressView().controlSize(.small)
                if case .joining = model.zoomState { Button(L10n.t("zoom.leave")) { model.zoomLeave() } }
            case .ready:
                TextField(L10n.t("zoom.meeting"), text: $meeting, prompt: Text("812 3456 7890 / https://zoom.us/j/…"))
                SecureField(L10n.t("zoom.passcode"), text: $passcode)
                TextField(L10n.t("zoom.name"), text: $displayName)
                Toggle(L10n.t("zoom.send_program"), isOn: $model.zoomSendProgram)
                Picker(L10n.t("zoom.mic_bus"), selection: $model.zoomMicBus) {
                    Text(L10n.t("zoom.mic_off")).tag(OutputBus?.none)
                    Text("Master").tag(Optional(OutputBus.master))
                    Text("Bus A").tag(Optional(OutputBus.busA))
                    Text("Bus B").tag(Optional(OutputBus.busB))
                }
                Button(L10n.t("zoom.join")) { model.zoomJoin(meeting, passcode: passcode, displayName: displayName) }
                    .buttonStyle(StudioButtonStyle(color: Theme.preview, active: false))
                    .disabled(meeting.isEmpty)
            case let .inMeeting(raw):
                HStack {
                    Button(L10n.t("zoom.leave"), role: .destructive) { model.zoomLeave() }
                    if raw != .allowed {
                        Button(raw == .requested ? L10n.t("zoom.waiting_host") : L10n.t("zoom.ask_permission")) { model.zoomRequestRawData() }
                            .disabled(raw == .requested)
                    }
                }
                if raw != .allowed { Text(L10n.t("zoom.permission_note")).font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                ForEach(model.zoomParticipants.filter { !$0.isMe }) { p in
                    HStack(spacing: 6) {
                        Image(systemName: p.videoOn ? "video.fill" : "video.slash").font(.system(size: 10))
                            .foregroundStyle(p.videoOn ? Theme.text : Theme.textDim)
                        Text(p.name + (p.isHost ? " (host)" : "")).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        if model.isZoomParticipantInput(p) {
                            Text(L10n.t("zoom.is_input")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        } else {
                            Button(L10n.t("zoom.add_input")) { model.addZoomParticipant(p) }
                                .font(.system(size: 10)).disabled(raw != .allowed)
                        }
                    }
                }
            }
        }
    }

    private var stateText: String {
        switch model.zoomState {
        case .notAuthorized: return L10n.t("zoom.state.signed_out")
        case .authorizing: return L10n.t("zoom.state.signing_in")
        case .ready: return L10n.t("zoom.state.ready")
        case .joining: return L10n.t("zoom.state.joining")
        case .inMeeting: return L10n.t("zoom.state.in_meeting")
        case .failed: return L10n.t("zoom.state.failed")
        }
    }

    private var stateColor: Color {
        switch model.zoomState {
        case .inMeeting: return Theme.program
        case .failed: return Theme.warning
        default: return Theme.textDim
        }
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
                    Button("\(ch.index)") { model.toggleOverlay(ch.index) }
                        .buttonStyle(StudioButtonStyle(color: Theme.program, active: ch.isOn))
                        .frame(width: 44)
                        .disabled(ch.source == nil)
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
                }
            }
        }
    }
}

struct StreamSection: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool

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
            Button(model.isStreamingActive ? L10n.t("stream.stop") : L10n.t("stream.start")) {
                if !model.isStreamingActive && model.readyDestinationCount == 0 { showSettings = true } else { model.toggleStream() }
            }
            .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isStreamingActive))
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

struct RecordSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("record.title"))
            Text(folderLabel).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.head)
            HStack(spacing: 6) {
                Button(model.isRecording ? L10n.t("record.stop") : L10n.t("record.start")) { model.toggleRecord() }
                    .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isRecording))
                Button { model.saveSnapshot() } label: { Image(systemName: "camera") }
                    .buttonStyle(StudioButtonStyle(color: Theme.accent))
                    .frame(width: 44)
                    .help(L10n.t("snapshot.help"))
            }
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
#endif
