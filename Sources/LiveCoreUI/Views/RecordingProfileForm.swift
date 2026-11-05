#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Advanced recording settings shared by the Recorder and the MultiCorder: folder, file name,
/// codec (H.264 / HEVC / ProRes), container, bitrate, keyframes, B-frames, audio, bus, and an
/// estimate of the disk space per hour.
struct RecordingProfileForm: View {
    @Binding var settings: RecordingSettings
    let output: OutputFormat
    /// Files written at once with these settings (MultiCorder: one per chosen input).
    var files = 1

    var body: some View {
        LabeledContent(L10n.t("record.folder")) {
            Text(settings.folderPath.isEmpty ? RecordingEngine.defaultFolder().path : settings.folderPath)
                .lineLimit(1).truncationMode(.head)
            Button(L10n.t("record.choose")) {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                if p.runModal() == .OK, let url = p.url { settings.folderPath = url.path }
            }
        }
        TextField(L10n.t("settings.filename"), text: $settings.fileNamePattern)
        Text("Tokens: {date} {time} {n}").font(.caption).foregroundStyle(Theme.textDim)
        Picker(L10n.t("recprofile.codec"), selection: Binding(get: { settings.videoCodec }, set: { settings.codec = $0 })) {
            ForEach(RecordingCodec.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Text(L10n.t(settings.videoCodec.isProRes ? "recprofile.prores_help" : "recprofile.hw_help"))
            .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        Picker(L10n.t("settings.container"), selection: $settings.container) {
            Text("MP4").tag(RecordingContainer.mp4)
            Text(L10n.t("recprofile.mov")).tag(RecordingContainer.mov)
        }
        .disabled(settings.videoCodec.isProRes || settings.pcmAudio == true)
        if settings.effectiveContainer != settings.container {
            Text(L10n.t("recprofile.mov_forced")).font(.caption).foregroundStyle(Theme.textDim)
        }
        if settings.videoCodec.usesBitrate {
            Stepper(value: Binding(get: { settings.bitrateKbps / 1000 }, set: { settings.bitrateKbps = $0 * 1000 }),
                    in: 2...150, step: settings.bitrateKbps >= 40_000 ? 5 : 1) {
                LabeledContent(L10n.t("recprofile.bitrate"), value: "\(settings.bitrateKbps / 1000) Mbps")
            }
            Picker(L10n.t("recprofile.keyframe"), selection: Binding(get: { settings.keyframeInterval }, set: { settings.keyframeSeconds = $0 })) {
                ForEach([0.5, 1, 2, 3, 4, 5, 10], id: \.self) { s in Text(s < 1 ? "0.5 s" : "\(Int(s)) s").tag(s) }
            }
            Toggle(L10n.t("recprofile.bframes"), isOn: Binding(get: { settings.bFrames }, set: { settings.frameReordering = $0 }))
                .help(L10n.t("recprofile.bframes_help"))
        }
        Toggle(L10n.t("recprofile.pcm"), isOn: Binding(get: { settings.pcmAudio == true }, set: { settings.pcmAudio = $0 }))
        if !settings.usesPCM {
            Picker(L10n.t("recprofile.audio_bitrate"), selection: Binding(get: { settings.audioKbps }, set: { settings.audioBitrateKbps = $0 })) {
                ForEach(RecordingSettings.audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
            }
        }
        OutputBusPicker(selection: Binding(get: { settings.bus }, set: { settings.audioBus = $0 }))
        Text(L10n.f("recprofile.estimate", settings.gigabytesPerHour(output: output, files: files), max(files, 1)))
            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
    }
}
#endif
