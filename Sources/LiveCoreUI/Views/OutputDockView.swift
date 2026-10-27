#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

extension RecordReminderMode {
    /// UserDefaults key of the "NOT RECORDING" reminder setting.
    static let storageKey = "record.reminder"
}

/// vMix-style bottom bar: RECORD, STREAM and EXTERNAL, each with its settings (⚙) beside it,
/// and the four outputs. It is always shown (cannot be minimized).
struct OutputDockView: View {
    @EnvironmentObject var model: AppModel
    /// Opens the Settings window on a tab (1 = Stream, 2 = Record).
    let openSettings: (Int) -> Void
    @State private var showRecord = false
    @State private var showStream = false
    @State private var showExternal = false

    init(openSettings: @escaping (Int) -> Void) { self.openSettings = openSettings }

    var body: some View {
        HStack(spacing: 10) {
            // One padlock for the whole dock: while locked RECORD and STREAM cannot start or stop.
            LockButton(locked: Binding(get: { model.recordLocked && model.streamLocked },
                                       set: { model.recordLocked = $0; model.streamLocked = $0 }),
                       help: L10n.t("lock.dock_help"))
            group {
                Button { model.requestToggleRecord() } label: {
                    Label(L10n.t("dock.record"), systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isRecording))
                .frame(width: 120)
                .disabled(model.recordLocked)
                gear($showRecord, help: L10n.t("dock.record_settings")) {
                    VStack(alignment: .leading, spacing: 10) {
                        RecordDetails()
                        Button(L10n.t("dock.more_settings")) { showRecord = false; openSettings(2) }
                    }
                    .padding(12).frame(width: 340)
                }
                status(recordStatus, live: model.isRecording)
            }
            group {
                Button {
                    if !model.isStreamingActive && model.readyDestinationCount == 0 { openSettings(1) } else { model.requestToggleStream() }
                } label: {
                    Label(L10n.t("dock.stream"), systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isStreamingActive))
                .frame(width: 120)
                .disabled(model.streamLocked)
                gear($showStream, help: L10n.t("dock.stream_settings")) {
                    VStack(alignment: .leading, spacing: 10) {
                        StreamDetails()
                        Button(L10n.t("dock.more_settings")) { showStream = false; openSettings(1) }
                    }
                    .padding(12).frame(width: 360)
                }
                status(streamStatus, live: model.isStreamingActive)
            }
            group {
                Button { model.toggleExternal() } label: {
                    Label(L10n.t("dock.external"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(StudioButtonStyle(color: Theme.accent, active: model.externalActive))
                .frame(width: 130)
                .help(L10n.t("dock.external_help"))
                gear($showExternal, help: L10n.t("dock.external_settings")) {
                    ExternalSettingsView().padding(12).frame(width: 640)
                }
                status(externalStatus, live: model.externalActive)
            }
            Spacer(minLength: 0)
            OutputChips()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(height: 46)
        .panel()
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.trailing, 6)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1, height: 26) }
    }

    private func gear<P: View>(_ shown: Binding<Bool>, help: String, @ViewBuilder content: @escaping () -> P) -> some View {
        Button { shown.wrappedValue.toggle() } label: { Image(systemName: "gearshape.fill") }
            .buttonStyle(StudioButtonStyle())
            .frame(width: 36)
            .help(help)
            .popover(isPresented: shown, arrowEdge: .top) { content().environmentObject(model) }
    }

    private func status(_ text: String, live: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: live ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(live ? Theme.text : Theme.textDim)
            .lineLimit(2)
            .frame(width: 118, alignment: .leading)
    }

    private var recordStatus: String {
        guard model.isRecording else { return L10n.t("dock.record_off") }
        return "\(formatDuration(model.recordStats.duration)) · \(ByteCountFormatter.string(fromByteCount: model.recordStats.fileBytes, countStyle: .file))"
    }

    private var streamStatus: String {
        let s = model.streamStats
        switch s.state {
        case .live: return "\(formatDuration(s.uptime)) · \(Int(s.bitrateKbps)) kbps"
        case .connecting: return L10n.t("stream.connecting")
        case let .reconnecting(a, _): return L10n.f("stream.reconnecting", a)
        case .failed: return L10n.t("stream.failed")
        case .stopping: return L10n.t("stream.stopping")
        case .idle: return L10n.f("dock.stream_ready", model.readyDestinationCount)
        }
    }

    private var externalStatus: String {
        guard model.externalActive else { return L10n.t("dock.external_off") }
        let syphon = model.syphonStatus.count, ndi = model.ndiStatus.count
        guard syphon + ndi > 0 else { return L10n.t("dock.external_nothing") }
        var parts: [String] = []
        if syphon > 0 { parts.append(L10n.f("dock.external_syphon", syphon)) }
        if ndi > 0 { parts.append(L10n.f("dock.external_ndi", ndi)) }
        let connected = model.syphonStatus.values.filter { $0 }.count + model.ndiStatus.values.reduce(0, +)
        if connected > 0 { parts.append(L10n.f("dock.external_clients", connected)) }
        return parts.joined(separator: " · ")
    }
}

/// Output 1–4 buttons: click opens the output's window, the menu picks its picture.
struct OutputChips: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...OutputRouting.count, id: \.self) { i in
                let slot = model.outputRouting.slot(i)
                Menu {
                    Button(L10n.t("output.window")) { openWindow(id: "output", value: i) }
                    if let fs = model.outputFullscreens[i] {
                        Button(fs.isActive ? L10n.t("output.fullscreen_close") : L10n.t("output.fullscreen")) { fs.toggle() }
                    }
                    Divider()
                    OutputSourcePicker(index: i)
                } label: {
                    VStack(spacing: 0) {
                        Text(L10n.f("output.short", i)).font(.system(size: 9, weight: .heavy))
                        Text(model.outputSourceName(slot.source)).font(.system(size: 9)).lineLimit(1)
                    }
                    .frame(width: 62)
                } primaryAction: {
                    openWindow(id: "output", value: i)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background((slot.syphon || slot.ndi) && model.externalActive ? Theme.accent.opacity(0.35) : Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .help(L10n.f("output.help", i))
            }
        }
    }
}

/// Program / Preview / one input, as menu items with a check mark.
struct OutputSourcePicker: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        let current = model.outputRouting.slot(index).source
        item(.program, current)
        item(.preview, current)
        Divider()
        ForEach(model.inputs) { i in item(.input(i.id), current) }
    }

    private func item(_ s: OutputSource, _ current: OutputSource) -> some View {
        Button((s == current ? "✓ " : "") + model.outputSourceName(s)) { model.setOutputSource(index, s) }
    }
}

/// EXTERNAL ⚙: the four outputs (picture, window, full screen, Syphon, NDI).
struct ExternalSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.t("output.section"))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(1...OutputRouting.count, id: \.self) { i in
                    GridRow {
                        Text(L10n.f("output.title", i)).font(.system(size: 11, weight: .bold))
                        Picker("", selection: Binding(get: { model.outputRouting.slot(i).source },
                                                      set: { model.setOutputSource(i, $0) })) {
                            Text(L10n.t("monitor.program")).tag(OutputSource.program)
                            Text(L10n.t("monitor.preview")).tag(OutputSource.preview)
                            Divider()
                            ForEach(model.inputs) { inp in Text("\(inp.number) \(inp.name)").tag(OutputSource.input(inp.id)) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Button { openWindow(id: "output", value: i) } label: { Image(systemName: "macwindow") }
                            .buttonStyle(.borderless)
                            .help(L10n.t("output.window"))
                        if let fs = model.outputFullscreens[i] { FullscreenButton(output: fs, compact: true) }
                        Toggle(L10n.t("output.syphon"), isOn: Binding(get: { model.outputRouting.slot(i).syphon },
                                                                      set: { model.setOutputSyphon(i, $0) }))
                            .toggleStyle(.checkbox).font(.system(size: 11))
                            .help(L10n.f("output.syphon_help", OutputRouting.syphonName(i)))
                        Toggle(L10n.t("output.ndi"), isOn: Binding(get: { model.outputRouting.slot(i).ndi },
                                                                   set: { model.setOutputNDI(i, $0) }))
                            .toggleStyle(.checkbox).font(.system(size: 11))
                            .disabled(!model.ndiAvailable && !model.outputRouting.slot(i).ndi)
                            .help(L10n.f("output.ndi_help", OutputRouting.ndiName(i)))
                        VStack(alignment: .leading, spacing: 1) {
                            syphonState(i)
                            ndiState(i)
                        }
                    }
                }
            }
            if !model.externalActive {
                Label(L10n.t("output.external_off_hint"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ndiSection
            Text(L10n.t("output.obs_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshExternalStatus() }
    }

    /// How to reach Zoom / Meet without OBS, or where to get the NDI runtime.
    @ViewBuilder private var ndiSection: some View {
        if model.ndiAvailable {
            Label(L10n.t("output.ndi_zoom_hint"), systemImage: "video.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let v = NDIRuntime.version {
                Text(L10n.f("output.ndi_runtime", v)).font(.system(size: 9)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("output.ndi_missing"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Link(L10n.t("output.ndi_download"), destination: NDIRuntime.downloadURL).font(.system(size: 11))
            }
        }
        Text(L10n.t("output.ndi_trademark")).font(.system(size: 9)).foregroundStyle(Theme.textDim)
    }

    /// Whether this output's NDI source is offered, and how many receivers take it.
    @ViewBuilder private func ndiState(_ i: Int) -> some View {
        if let n = model.ndiStatus[i] {
            Text(n > 0 ? L10n.f("output.ndi_connected", n) : L10n.t("output.ndi_waiting"))
                .font(.system(size: 10)).foregroundStyle(n > 0 ? Theme.preview : Theme.textDim)
        } else if model.outputRouting.slot(i).ndi {
            Text(model.ndiAvailable ? L10n.t("output.ndi_off_external") : L10n.t("output.ndi_no_runtime"))
                .font(.system(size: 10)).foregroundStyle(model.ndiAvailable ? Theme.textDim : Theme.warning)
        }
    }

    /// Whether this output's Syphon source is offered, and whether an app receives it.
    @ViewBuilder private func syphonState(_ i: Int) -> some View {
        if let connected = model.syphonStatus[i] {
            Text(connected ? L10n.t("output.syphon_connected") : L10n.t("output.syphon_waiting"))
                .font(.system(size: 10)).foregroundStyle(connected ? Theme.preview : Theme.textDim)
        } else {
            Text(model.outputRouting.slot(i).syphon ? L10n.t("output.syphon_off_external") : "")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
    }
}

/// Window showing one output; drag it to another display or use full screen.
struct OutputWindowView: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    var body: some View {
        PixelBufferView(feed: model.outputFeeds[index] ?? model.programOutputFeed)
            .background(Color.black)
            .frame(minWidth: 320, minHeight: 180)
            .ignoresSafeArea()
            .navigationTitle(L10n.f("output.title", index) + " · " + model.outputSourceName(model.outputRouting.slot(index).source))
            .onAppear { model.setOutputWindow(index, open: true) }
            .onDisappear { model.setOutputWindow(index, open: false) }
    }
}

/// vMix "NOT RECORDING" warning, blinking over the Program monitor (never on the real output).
struct NotRecordingBadge: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            Text(L10n.t("record.not_recording"))
                .font(.system(size: 13, weight: .heavy)).tracking(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Theme.program)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(RecordReminder.visible(elapsed: ctx.date.timeIntervalSinceReferenceDate) ? 1 : 0.12)
        }
        .allowsHitTesting(false)
        .accessibilityLabel(L10n.t("record.not_recording"))
    }
}
#endif
