#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProductionSettings()
    @State private var keyField = ""
    @State private var destKeys: [String: String] = [:]   // additional destination id → newly typed key
    @State private var shortcuts = ShortcutSettings()
    @State private var errors: [String] = []
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                outputTab.tabItem { Text(L10n.t("settings.output")) }.tag(0)
                streamTab.tabItem { Text(L10n.t("stream.title")) }.tag(1)
                recordTab.tabItem { Text(L10n.t("record.title")) }.tag(2)
                audioTab.tabItem { Text(L10n.t("audio.title")) }.tag(3)
                shortcutTab.tabItem { Text(L10n.t("settings.shortcuts")) }.tag(4)
                MIDISettingsView().tabItem { Text("MIDI") }.tag(5)
            }
            .padding()
            if !errors.isEmpty {
                VStack(alignment: .leading) { ForEach(errors, id: \.self) { Text($0).foregroundStyle(Theme.warning) } }
                    .padding(.horizontal)
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) { apply() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 520)
        .onAppear {
            draft = model.settings
            shortcuts = model.shortcuts
            keyField = ""
            destKeys = [:]
        }
    }

    private var outputLocked: Bool { model.isStreamingActive || model.isRecording }

    private var outputTab: some View {
        Form {
            Picker(L10n.t("settings.resolution"), selection: $draft.output) {
                ForEach(OutputFormat.presets, id: \.self) { f in Text(f.label).tag(f) }
            }
            .disabled(outputLocked)
            if outputLocked { Text(L10n.t("settings.locked")).font(.caption).foregroundStyle(Theme.warning) }
            Stepper(value: $draft.video.bitrateKbps, in: 500...20_000, step: 250) {
                LabeledContent(L10n.t("settings.video_bitrate"), value: "\(draft.video.bitrateKbps)")
            }
            Picker(L10n.t("settings.audio_bitrate"), selection: $draft.audio.bitrateKbps) {
                ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0)").tag($0) }
            }
            Picker(L10n.t("settings.keyframe"), selection: $draft.video.keyframeIntervalSeconds) {
                ForEach([1.0, 2.0, 3.0, 4.0], id: \.self) { Text(String(format: "%.0f", $0)).tag($0) }
            }
            Picker(L10n.t("settings.profile"), selection: $draft.video.profile) {
                ForEach(H264Profile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Toggle(L10n.t("settings.hardware"), isOn: $draft.video.preferHardware)
            Text("Streaming and recording use H.264 + AAC-LC \(draft.audio.sampleRate / 1000) kHz stereo. Most platforms recommend a 2 s keyframe interval.")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
        .formStyle(.grouped)
    }

    private var streamTab: some View {
        Form {
            Section(L10n.t("stream.primary")) {
                HStack {
                    Toggle("", isOn: $draft.stream.primaryEnabled).labelsHidden()
                    TextField(L10n.t("stream.dest_name"), text: $draft.stream.primaryName, prompt: Text("YouTube"))
                }
                TextField(L10n.t("stream.server"), text: $draft.stream.serverURL, prompt: Text("rtmp://a.rtmp.youtube.com/live2"))
                SecureField(L10n.t("stream.key"), text: $keyField,
                            prompt: Text(model.hasStreamKey ? "•••••••• (\(L10n.t("stream.key_saved")))" : ""))
                if model.hasStreamKey {
                    Button(L10n.t("stream.delete_key"), role: .destructive) { model.saveStreamKey("") }
                }
            }
            ForEach($draft.stream.additional) { $d in
                Section {
                    HStack {
                        Toggle("", isOn: $d.enabled).labelsHidden()
                        TextField(L10n.t("stream.dest_name"), text: $d.name, prompt: Text("Facebook"))
                        Button(L10n.t("stream.remove_dest"), role: .destructive) {
                            draft.stream.additional.removeAll { $0.id == d.id }
                            destKeys[d.id] = nil
                        }
                    }
                    TextField(L10n.t("stream.server"), text: $d.serverURL, prompt: Text("rtmps://live-api-s.facebook.com:443/rtmp/"))
                    SecureField(L10n.t("stream.key"), text: Binding(get: { destKeys[d.id] ?? "" }, set: { destKeys[d.id] = $0 }),
                                prompt: Text(model.hasKey(account: d.keychainAccount) ? "•••••••• (\(L10n.t("stream.key_saved")))" : ""))
                }
            }
            if draft.stream.additional.count < StreamSettings.maxDestinations - 1 {
                Button(L10n.t("stream.add_dest")) {
                    let id = String(UUID().uuidString.prefix(8)).lowercased()
                    draft.stream.additional.append(StreamDestination(id: id, name: "Destination \(draft.stream.additional.count + 2)"))
                }
            }
            Text(L10n.t("stream.multi_note"))
                .font(.caption).foregroundStyle(Theme.textDim)
            Text("Stream keys are stored in the macOS Keychain, never in settings files or logs. Leave a key field empty to keep the saved key.")
                .font(.caption).foregroundStyle(Theme.textDim)
            Toggle(L10n.t("settings.reconnect"), isOn: $draft.stream.autoReconnect)
            Text("Reconnect: \(Int(draft.stream.reconnect.initialDelay)) s, doubling to \(Int(draft.stream.reconnect.maxDelay)) s, max \(draft.stream.reconnect.maxAttempts) attempts.")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
        .formStyle(.grouped)
        .disabled(model.isStreamingActive)
    }

    private var recordTab: some View {
        Form {
            LabeledContent(L10n.t("record.folder")) {
                Text(draft.recording.folderPath.isEmpty ? RecordingEngine.defaultFolder().path : draft.recording.folderPath)
                    .lineLimit(1).truncationMode(.head)
                Button(L10n.t("record.choose")) {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    if p.runModal() == .OK, let url = p.url { draft.recording.folderPath = url.path }
                }
            }
            TextField(L10n.t("settings.filename"), text: $draft.recording.fileNamePattern)
            Text("Tokens: {date} {time} {n}").font(.caption).foregroundStyle(Theme.textDim)
            Picker(L10n.t("settings.container"), selection: $draft.recording.container) {
                Text("MP4 (H.264/AAC)").tag(RecordingContainer.mp4)
                Text("MOV (H.264/AAC, crash-resilient)").tag(RecordingContainer.mov)
            }
            Stepper(value: $draft.recording.bitrateKbps, in: 2_000...50_000, step: 1_000) {
                LabeledContent(L10n.t("settings.record_bitrate"), value: "\(draft.recording.bitrateKbps)")
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Picker(L10n.t("audio.monitor_device"), selection: Binding(get: { model.monitorDeviceUID }, set: { model.setMonitorDevice(uid: $0) })) {
                Text("System default").tag("")
                ForEach(model.outputDevices, id: \.uid) { d in Text(d.name).tag(d.uid) }
            }
            LabeledContent(L10n.t("audio.sync")) {
                Slider(value: $model.syncOffsetMs, in: -500...500, step: 10)
                Text("\(Int(model.syncOffsetMs))").monospacedDigit().frame(width: 40)
            }
            Text("Positive values delay audio relative to video. Measure with a clap/slate test (docs/TEST_PLAN.md, T-07).")
                .font(.caption).foregroundStyle(Theme.textDim)
            Text("Mixer: 48 kHz, 32-bit float, stereo. Input devices at other rates are converted by Core Audio.")
                .font(.caption).foregroundStyle(Theme.textDim)
        }
        .formStyle(.grouped)
    }

    private var shortcutTab: some View {
        Form {
            shortcutPicker(L10n.t("shortcut.cut"), $shortcuts.cut)
            shortcutPicker(L10n.t("shortcut.auto"), $shortcuts.auto)
            shortcutPicker(L10n.t("shortcut.stream"), $shortcuts.stream)
            shortcutPicker(L10n.t("shortcut.record"), $shortcuts.record)
            Text(L10n.t("shortcut.inputs")).font(.caption).foregroundStyle(Theme.textDim)
        }
        .formStyle(.grouped)
    }

    private func shortcutPicker(_ label: String, _ binding: Binding<String>) -> some View {
        Picker(label, selection: binding) {
            ForEach(ShortcutSettings.choices, id: \.self) { Text($0).tag($0) }
        }
    }

    private func apply() {
        let old = model.settings
        draft.transition = model.transitionKind
        draft.transitionDuration = model.transitionDuration
        let errs = model.apply(draft)
        if !keyField.isEmpty { model.saveStreamKey(keyField) }
        for d in draft.stream.additional { if let k = destKeys[d.id], !k.isEmpty { model.saveKey(k, account: d.keychainAccount) } }
        if errs.isEmpty {
            // Removed destinations: delete their Keychain items too.
            let kept = Set(draft.stream.additional.map(\.id))
            for d in old.stream.additional where !kept.contains(d.id) { model.saveKey("", account: d.keychainAccount) }
        }
        model.saveShortcuts(shortcuts)
        errors = errs
        if errs.isEmpty { dismiss() }
    }
}
/// MIDI controller mapping with Learn: click Learn, then press a pad/key or move a fader.
/// Mappings apply immediately and are stored in user preferences (not in projects).
struct MIDISettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.midiSources.isEmpty ? L10n.t("midi.no_devices") : L10n.f("midi.devices", model.midiSources.joined(separator: ", ")))
                .font(.caption).foregroundStyle(Theme.textDim)
            if !model.lastMIDI.isEmpty {
                Text(L10n.f("midi.last", model.lastMIDI)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
            }
            List {
                ForEach(ControlAction.catalog, id: \.self) { a in
                    HStack {
                        Text(AppModel.actionName(a))
                        Spacer()
                        if model.midiLearning == a {
                            Text(L10n.t("midi.waiting")).foregroundStyle(Theme.warning)
                            Button(L10n.t("settings.cancel")) { model.midiLearning = nil }
                        } else {
                            Text(model.midiMap.trigger(for: a)?.description ?? "—")
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textDim)
                            Button(L10n.t("midi.learn")) { model.midiLearning = a }
                            Button {
                                model.midiMap.clear(a)
                            } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .disabled(model.midiMap.trigger(for: a) == nil)
                        }
                    }
                }
            }
            Text(L10n.t("midi.hint")).font(.caption).foregroundStyle(Theme.textDim)
        }
        .padding(8)
        .onDisappear { model.midiLearning = nil }
    }
}
#endif
