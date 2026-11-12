#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine
import LiveCoreRemote

/// Add or change an SRT input (0.54.0): listen for an encoder or call one.
struct SRTInputSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var c = ProjectSRTInput()
    @State private var paste = ""
    @State private var addresses: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DialogTitle("dot.radiowaves.up.forward", editing == nil ? L10n.t("srtin.add_title") : L10n.t("srtin.edit_title"))
            Form {
                Section {
                    Picker(L10n.t("srtin.mode"), selection: $c.mode) {
                        Text(L10n.t("srtin.listener")).tag(ProjectSRTInput.Mode.listener)
                        Text(L10n.t("srtin.caller")).tag(ProjectSRTInput.Mode.caller)
                    }
                    .pickerStyle(.segmented)
                    if c.mode == .caller {
                        TextField(L10n.t("srtin.host"), text: $c.host, prompt: Text("192.168.1.50"))
                    }
                    TextField(L10n.t("srtin.port"), value: $c.port, format: .number.grouping(.never))
                    Stepper(L10n.f("srtin.latency", c.latencyMs), value: $c.latencyMs, in: 20...8000, step: 20)
                        .help(L10n.t("srtin.latency_help"))
                    if c.mode == .caller {
                        TextField(L10n.t("srtin.streamid"), text: Binding(get: { c.streamID ?? "" },
                                                                         set: { c.streamID = $0.isEmpty ? nil : $0 }))
                    }
                    Toggle(L10n.t("ndi.audio"), isOn: Binding(get: { c.wantsAudio }, set: { c.audio = $0 ? nil : false }))
                    TextField(L10n.t("srtin.paste"), text: $paste, prompt: Text("srt://…"))
                        .onSubmit { if let p = ProjectSRTInput.parse(paste) { c = p; paste = "" } }
                }
                if c.mode == .listener {
                    Section(L10n.t("srtin.encoder_url")) {
                        if addresses.isEmpty { Text("srt://<IP>:\(c.port)").textSelection(.enabled) }
                        ForEach(addresses, id: \.self) { a in
                            HStack {
                                Text(c.callerURL(host: a)).font(.system(size: 11).monospaced()).textSelection(.enabled)
                                Spacer()
                                Button(L10n.t("srtin.copy")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(c.callerURL(host: a), forType: .string)
                                }
                            }
                        }
                    }
                }
                if let id = editing, let src = model.srtSource(id) {
                    Section(L10n.t("capturecard.status")) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let s = src.signal
                            VStack(alignment: .leading, spacing: 3) {
                                Text(src.status.label).foregroundStyle(Theme.textDim).lineLimit(2)
                                if !s.peer.isEmpty {
                                    Text(L10n.f("srtin.peer", s.peer, s.streamID.isEmpty ? "—" : s.streamID))
                                }
                                if s.width > 0 {
                                    Text(L10n.f("srtin.signal", s.width, s.height, s.fps, s.videoCodec, s.audio.isEmpty ? "—" : s.audio, s.kbps))
                                }
                                Text(L10n.f("srtin.stats", s.srt.rttMs, s.srt.latencyMs, s.srt.lostPackets, s.srt.recoveredPackets, s.srt.droppedPackets))
                            }
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textDim)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Text(L10n.t("srtin.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if let msg = problem {
                Text(msg).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("common.add") : L10n.t("settings.apply")) {
                    var v = c
                    v.host = v.host.trimmingCharacters(in: .whitespaces)
                    v.latencyMs = v.clampedLatency
                    if let id = editing { model.updateSRTInput(id, v) } else { model.addSRTInput(v) }
                    dismiss()
                }
                .disabled(problem != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 580)
        .onAppear {
            if let id = editing, let src = model.srtSource(id) { c = src.config }
            addresses = RemoteServer.lanAddresses()
        }
    }

    private var problem: String? {
        switch c.problem {
        case .badPort?: return L10n.t("srtin.bad_port")
        case .missingHost?: return L10n.t("srtin.missing_host")
        case nil:
            if c.mode == .listener, let used = model.srtPortInUse(c.port, except: editing) { return L10n.f("inputs.already_used", used) }
            return nil
        }
    }
}

/// Add or change a Blackmagic DeckLink / UltraStudio / Intensity input (0.54.0).
struct DeckLinkInputSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var devices: [DeckLinkRuntime.Device] = []
    @State private var modes: [DeckLinkRuntime.Mode] = []
    @State private var device = 0
    @State private var mode: UInt32 = 0
    @State private var connection = ""
    @State private var audio = true
    @State private var loaded = false

    private var available: Bool { DeckLinkRuntime.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DialogTitle("rectangle.connected.to.line.below", editing == nil ? L10n.t("decklink.add_title") : L10n.t("decklink.edit_title"))
            if !available {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("decklink.no_driver")).foregroundStyle(Theme.warning)
                    Link(L10n.t("decklink.download"), destination: DeckLinkRuntime.downloadURL)
                }
            } else if loaded && devices.isEmpty {
                Text(L10n.t("decklink.no_device")).foregroundStyle(Theme.warning)
            } else {
                Form {
                    Section {
                        Picker(L10n.t("capturecard.device"), selection: $device) {
                            ForEach(devices) { d in Text(d.name).tag(d.index) }
                        }
                        .onChange(of: device) { _ in loadModes() }
                        Picker(L10n.t("decklink.connection"), selection: $connection) {
                            Text(L10n.t("decklink.connection_default")).tag("")
                            ForEach(connectionNames, id: \.self) { n in Text(n.uppercased()).tag(n) }
                        }
                        Picker(L10n.t("decklink.format"), selection: $mode) {
                            Text(currentDevice?.formatDetection == false ? L10n.t("decklink.format_first") : L10n.t("decklink.format_auto")).tag(UInt32(0))
                            ForEach(modes) { m in Text(m.name).tag(m.code) }
                        }
                        Toggle(L10n.t("ndi.audio"), isOn: $audio)
                    }
                    if let id = editing, let src = model.deckLinkSource(id) {
                        Section(L10n.t("capturecard.status")) {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let s = src.signal
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(src.status.label).lineLimit(2)
                                    if s.width > 0 {
                                        Text(L10n.f("decklink.signal", s.width, s.height, s.fps, s.rgb ? "RGB 4:4:4" : "YUV 4:2:2"))
                                    }
                                }
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Text(L10n.f("decklink.note", available ? DeckLinkRuntime.version : "—")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("common.add") : L10n.t("settings.apply")) {
                    guard let d = currentDevice else { return }
                    let c = ProjectDeckLink(deviceName: d.name, deviceIndex: d.index, mode: mode == 0 ? nil : mode,
                                            connection: connection.isEmpty ? nil : connection, audio: audio ? nil : false)
                    if let id = editing { model.updateDeckLink(id, c) } else { model.addDeckLink(c) }
                    dismiss()
                }
                .disabled(currentDevice == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500, height: 440)
        .onAppear(perform: load)
    }

    private var currentDevice: DeckLinkRuntime.Device? { devices.first { $0.index == device } }

    private var connectionNames: [String] {
        let bits = currentDevice?.connections ?? 0
        return ProjectDeckLink.connections.filter { bits & $0.bit != 0 }.map(\.name)
    }

    private func load() {
        guard available else { loaded = true; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = DeckLinkRuntime.devices()
            DispatchQueue.main.async {
                devices = list
                loaded = true
                if let id = editing, let src = model.deckLinkSource(id) {
                    let c = src.config
                    device = DeckLinkRuntime.resolve(c, in: list) ?? list.first?.index ?? 0
                    mode = c.mode ?? 0
                    connection = c.connection ?? ""
                    audio = c.wantsAudio
                } else {
                    device = list.first?.index ?? 0
                }
                loadModes()
            }
        }
    }

    private func loadModes() {
        let d = device
        DispatchQueue.global(qos: .userInitiated).async {
            let list = DeckLinkRuntime.modes(device: d)
            DispatchQueue.main.async {
                modes = list
                if mode != 0, !list.contains(where: { $0.code == mode }) { mode = 0 }
            }
        }
    }
}
#endif
