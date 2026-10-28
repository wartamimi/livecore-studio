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
    @State private var canvasMode: OutputFormat.Orientation = .horizontal
    @State private var canvasLines = 1080
    @State private var customWidth = 1920
    @State private var customHeight = 1080
    /// Tab shown first (6 Canvas, 0 Output, 1 Stream, 2 Record, ...).
    var initialTab = 0

    init(initialTab: Int = 0) { self.initialTab = initialTab }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                canvasTab.tabItem { Text(L10n.t("canvas.title")) }.tag(6)
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
            loadCanvas()
            tab = initialTab
            shortcuts = model.shortcuts
            keyField = ""
            destKeys = [:]
        }
    }

    private var outputLocked: Bool { model.isStreamingActive || model.isRecording }

    // MARK: Canvas

    /// Size and frame rate of everything produced: program, recording, stream, NDI, fullscreen.
    private var canvasTab: some View {
        Form {
            Section {
                Picker(L10n.t("canvas.orientation"), selection: $canvasMode) {
                    Label(L10n.t("canvas.horizontal"), systemImage: "rectangle").tag(OutputFormat.Orientation.horizontal)
                    Label(L10n.t("canvas.portrait"), systemImage: "rectangle.portrait").tag(OutputFormat.Orientation.portrait)
                    Label(L10n.t("canvas.custom"), systemImage: "aspectratio").tag(OutputFormat.Orientation.custom)
                }
                .pickerStyle(.segmented)
                if canvasMode == .custom {
                    HStack {
                        Text(L10n.t("canvas.size"))
                        Spacer()
                        TextField("", value: $customWidth, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                        Text("×")
                        TextField("", value: $customHeight, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                        Text("px").foregroundStyle(Theme.textDim)
                    }
                    HStack(spacing: 6) {
                        Text(L10n.t("canvas.quick")).font(.caption).foregroundStyle(Theme.textDim)
                        Spacer()
                        ForEach(Self.quickSizes, id: \.name) { q in
                            Button(q.name) { customWidth = q.width; customHeight = q.height }.controlSize(.small)
                        }
                    }
                    Text(L10n.f("canvas.custom_help", OutputFormat.minSide, OutputFormat.maxSide))
                        .font(.caption).foregroundStyle(Theme.textDim)
                } else {
                    Picker(L10n.t("canvas.quality"), selection: $canvasLines) {
                        ForEach(OutputFormat.lineChoices, id: \.self) { l in
                            let f = OutputFormat.canvas(canvasMode, lines: l, frameRate: draft.output.frameRate)
                            Text("\(l)p  (\(f.size.width)×\(f.size.height))").tag(l)
                        }
                    }
                }
                Picker(L10n.t("canvas.frame_rate"), selection: $draft.output.frameRate) {
                    ForEach(OutputFormat.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            .disabled(outputLocked)
            Section {
                HStack(alignment: .center, spacing: 14) {
                    canvasPreview
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.output.label).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text(L10n.t("canvas.help_\(canvasMode.rawValue)")).font(.caption).foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if outputLocked { Text(L10n.t("settings.locked")).font(.caption).foregroundStyle(Theme.warning) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: canvasMode) { _ in updateCanvas() }
        .onChange(of: canvasLines) { _ in updateCanvas() }
        .onChange(of: customWidth) { _ in updateCanvas() }
        .onChange(of: customHeight) { _ in updateCanvas() }
        .onChange(of: draft.output.frameRate) { _ in updateCanvas() }
    }

    private struct QuickSize { let width: Int, height: Int, name: String }
    private static let quickSizes = [QuickSize(width: 1080, height: 1080, name: "1:1"), QuickSize(width: 1080, height: 1350, name: "4:5"),
                                     QuickSize(width: 1440, height: 1080, name: "4:3"), QuickSize(width: 2560, height: 1080, name: "21:9"),
                                     QuickSize(width: 3840, height: 2160, name: "4K")]

    /// Small picture of the canvas shape.
    private var canvasPreview: some View {
        let a = max(draft.output.size.aspect, 0.1)
        let w = min(96, 64 * a)
        return RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent, lineWidth: 1.5))
            .overlay(Image(systemName: "person.fill").font(.system(size: 16)).foregroundStyle(Theme.accent.opacity(0.7)))
            .frame(width: w, height: w / a)
            .frame(width: 100, height: 70)
    }

    private func loadCanvas() {
        let f = draft.output
        canvasMode = f.orientation
        let short = min(f.size.width, f.size.height)
        canvasLines = OutputFormat.lineChoices.contains(short) ? short : 1080
        customWidth = f.size.width
        customHeight = f.size.height
    }

    private func updateCanvas() {
        let fps = draft.output.frameRate
        let f = canvasMode == .custom
            ? OutputFormat.custom(width: customWidth, height: customHeight, frameRate: fps)
            : OutputFormat.canvas(canvasMode, lines: canvasLines, frameRate: fps)
        if f != draft.output { draft.output = f }
    }

    private var outputTab: some View {
        Form {
            LabeledContent(L10n.t("canvas.title")) {
                Button("\(draft.output.label)  ›") { tab = 6 }.buttonStyle(.link)
            }
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
                OutputBusPicker(selection: $draft.stream.primaryAudioBus)
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
                    OutputBusPicker(selection: Binding(get: { d.bus }, set: { d.audioBus = $0 }))
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
            OutputBusPicker(selection: Binding(get: { draft.recording.bus }, set: { draft.recording.audioBus = $0 }))
            Text(L10n.t("bus.note")).font(.caption).foregroundStyle(Theme.textDim)
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
        draft.customTransition = model.customTransitionID
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
/// Audio bus feeding an output (recording or one stream destination).
struct OutputBusPicker: View {
    @Binding var selection: OutputBus
    var body: some View {
        Picker(L10n.t("bus.output"), selection: $selection) {
            Text("Master").tag(OutputBus.master)
            Text("Bus A").tag(OutputBus.busA)
            Text("Bus B").tag(OutputBus.busB)
        }
    }
}
#endif
