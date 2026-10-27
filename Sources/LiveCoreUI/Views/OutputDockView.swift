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
            group {
                Button { model.requestToggleRecord() } label: {
                    Label(L10n.t("dock.record"), systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isRecording))
                .frame(width: 120)
                .disabled(model.recordLocked)
                LockButton(locked: $model.recordLocked, help: L10n.t("lock.record_help"))
                Button { model.saveSnapshot() } label: { Image(systemName: "camera") }
                    .buttonStyle(StudioButtonStyle(color: Theme.accent))
                    .frame(width: 40)
                    .help(L10n.t("snapshot.help"))
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
                LockButton(locked: $model.streamLocked, help: L10n.t("lock.stream_help"))
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
                    ExternalSettingsView().padding(12).frame(width: 520)
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
        let syphon = model.outputRouting.slots.filter(\.syphon).count
        var parts: [String] = []
        if syphon > 0 { parts.append(L10n.f("dock.external_syphon", syphon)) }
        if model.virtualCamera == .sending { parts.append(L10n.t("vcam.short_on")) }
        return parts.isEmpty ? L10n.t("dock.external_nothing") : parts.joined(separator: " · ")
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
                .background(slot.syphon && model.externalActive ? Theme.accent.opacity(0.35) : Theme.panelRaised)
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

/// EXTERNAL ⚙: the four outputs (picture, window, full screen, Syphon) and the virtual camera.
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
                    }
                }
            }
            Text(L10n.t("output.obs_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VirtualCameraSection()
        }
    }
}

struct VirtualCameraSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("vcam.title"))
            Picker(L10n.t("vcam.output"), selection: Binding(get: { model.outputRouting.virtualCameraOutput ?? 0 },
                                                            set: { model.setVirtualCameraOutput($0 == 0 ? nil : $0) })) {
                Text(L10n.t("vcam.off")).tag(0)
                ForEach(1...OutputRouting.count, id: \.self) { i in Text(L10n.f("output.title", i)).tag(i) }
            }
            .font(.system(size: 11))
            .frame(width: 260)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(statusText).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                switch model.virtualCamera {
                case .installed, .sending:
                    Button(L10n.t("vcam.remove")) { model.removeVirtualCamera() }
                case .waitingForApproval:
                    Button(L10n.t("vcam.open_settings")) { model.openExtensionSettings() }
                    Button(L10n.t("vcam.check")) { model.refreshVirtualCamera() }
                default:
                    Button(L10n.t("vcam.install")) { model.installVirtualCamera() }
                    Button(L10n.t("vcam.check")) { model.refreshVirtualCamera() }
                }
            }
            .font(.system(size: 11))
            Text(L10n.t("vcam.note")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshVirtualCamera() }
    }

    private var statusText: String {
        switch model.virtualCamera {
        case .unknown, .notInstalled: return L10n.t("vcam.status_not_installed")
        case .installed: return model.externalActive ? L10n.t("vcam.status_no_output") : L10n.t("vcam.status_installed")
        case .sending: return L10n.t("vcam.status_sending")
        case .waitingForApproval: return L10n.t("vcam.status_approval")
        case let .failed(msg): return msg
        }
    }

    private var color: Color {
        switch model.virtualCamera {
        case .sending: return Theme.preview
        case .installed: return Theme.accent
        case .failed, .waitingForApproval: return Theme.warning
        default: return Theme.textDim.opacity(0.5)
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
