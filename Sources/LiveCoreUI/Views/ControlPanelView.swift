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
            }
            .padding(8)
        }
        .panel()
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
            Text(model.settings.stream.serverURL.isEmpty ? "—" : model.settings.stream.serverURL)
                .font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            Text(model.hasStreamKey ? L10n.t("stream.key_saved") : L10n.t("stream.key_missing"))
                .font(.system(size: 10)).foregroundStyle(model.hasStreamKey ? Theme.textDim : Theme.warning)
            Button(model.isStreamingActive ? L10n.t("stream.stop") : L10n.t("stream.start")) {
                if model.settings.stream.serverURL.isEmpty || !model.hasStreamKey { showSettings = true } else { model.toggleStream() }
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

    private func label(_ s: String) -> some View { Text(s).font(.system(size: 10)).foregroundStyle(Theme.textDim) }
    private func value(_ s: String) -> some View { Text(s).font(.system(size: 11).monospacedDigit()) }
}

struct RecordSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("record.title"))
            Text(folderLabel).font(.system(size: 11)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.head)
            Button(model.isRecording ? L10n.t("record.stop") : L10n.t("record.start")) { model.toggleRecord() }
                .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isRecording))
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
