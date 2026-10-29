#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct TopBarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Environment(\.openWindow) private var openWindow

    /// Full bar when the window is wide; on narrow windows labels become icons and the machine
    /// stats move to the tooltip (0.43.0).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            if !compact {
                Text(L10n.t("app.name")).font(.system(size: 15, weight: .heavy))
                Text("\(model.settings.output.label)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
            Button { model.showOutputsPanel = true } label: {
                Label(L10n.t("outputs.button"), systemImage: "square.stack.3d.up").labelStyle(AdaptiveLabelStyle(iconOnly: compact))
            }
                .buttonStyle(StudioButtonStyle())
                .fixedSize()
                .help(L10n.t("outputs.help"))
            FullscreenGroup()
            if !model.isOperatorMode && !compact { machineStats }
            stat(L10n.t("top.fps"), String(format: "%.1f", model.performance.renderFPS),
                 warn: model.performance.renderFPS < Double(model.settings.output.frameRate) * 0.95 && model.performance.renderFPS > 0)
            if !compact { stat(L10n.t("top.dropped"), "\(model.performance.droppedRenderFrames)", warn: false) }
            if model.performance.thermalState == .serious || model.performance.thermalState == .critical {
                Label("Thermal", systemImage: "thermometer.high").foregroundStyle(Theme.warning).font(.system(size: 11, weight: .bold))
            }
            Divider().frame(height: 18)
            StatusPill(text: streamText, color: streamColor, systemImage: "dot.radiowaves.left.and.right")
            StatusPill(text: recordText, color: model.isRecording ? Theme.program : Theme.panelRaised, systemImage: "record.circle")
            Button { openWindow(id: "rundown") } label: {
                Label(L10n.t("rundown.button"), systemImage: "list.number").labelStyle(AdaptiveLabelStyle(iconOnly: compact))
            }
                .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.rundownIndex != nil))
                .fixedSize()
                .help(L10n.t("rundown.title"))
            Button { openWindow(id: "vertical") } label: {
                Label("9:16", systemImage: "rectangle.portrait").labelStyle(AdaptiveLabelStyle(iconOnly: compact))
            }
                .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isVerticalStreaming))
                .fixedSize()
                .help(L10n.t("vertical.window"))
            Button { openWindow(id: "multiview") } label: { Image(systemName: "square.grid.3x2") }
                .help(L10n.t("multiview.open"))
                .buttonStyle(.borderless)
            if !model.isOperatorMode {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help(L10n.t("settings.title"))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .panel()
    }

    @ViewBuilder
    private var machineStats: some View {
        stat(L10n.t("top.cpu"), String(format: "%.0f%%", model.performance.cpuPercentOfMachine),
             warn: model.performance.cpuPercentOfMachine > 70)
        stat(L10n.t("top.gpu"), String(format: "%.1f ms", model.performance.gpuFrameMs),
             warn: model.performance.gpuFrameMs > 1000 / Double(max(model.settings.output.frameRate, 1)) * 0.8)
        stat(L10n.t("top.mem"), String(format: "%.0f MB", model.performance.memoryMB), warn: false)
    }

    private func stat(_ label: String, _ value: String, warn: Bool) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim)
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(warn ? Theme.warning : Theme.text)
        }
    }

    private var streamText: String {
        switch model.streamStats.state {
        case .idle: return L10n.t("stream.idle")
        case .connecting: return L10n.t("stream.connecting")
        case .live: return "\(L10n.t("stream.live")) \(formatDuration(model.streamStats.uptime)) · \(Int(model.streamStats.bitrateKbps)) kbps"
        case let .reconnecting(a, _): return L10n.f("stream.reconnecting", a)
        case .failed: return L10n.t("stream.failed")
        case .stopping: return L10n.t("stream.stopping")
        }
    }

    private var streamColor: Color {
        switch model.streamStats.state {
        case .live: return Theme.program
        case .connecting, .reconnecting, .stopping: return Theme.warning
        case .failed: return Theme.warning.opacity(0.6)
        case .idle: return Theme.panelRaised
        }
    }

    private var recordText: String {
        model.isRecording ? "\(L10n.t("top.record")) \(formatDuration(model.recordStats.duration))" : L10n.t("top.record")
    }
}

/// vMix FULLSCREEN in the top bar: the button opens the chosen outputs full screen on their
/// displays (2nd, 3rd... screen) or closes them; ⚙ picks, per output, the display and the picture.
struct FullscreenGroup: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 6) {
            Button { model.toggleFullscreen() } label: {
                Label(L10n.t("fullscreen.big"), systemImage: "display")
            }
            .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.isFullscreenActive))
            .frame(width: StudioButtonStyle.mainWidth)
            .help(L10n.t("fullscreen.big_help"))
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(StudioButtonStyle())
                .frame(width: 36)
                .help(L10n.t("fullscreen.settings"))
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    FullscreenSettingsView().environmentObject(model).padding(12).frame(width: 560)
                }
        }
    }
}

/// FULLSCREEN ⚙: for each output, whether the button opens it, on which display, with which picture.
struct FullscreenSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.t("fullscreen.big"))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    Text(L10n.t("fullscreen.col_display")).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textDim)
                    Text(L10n.t("fullscreen.col_source")).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textDim)
                    Text("")
                }
                ForEach(1...OutputRouting.count, id: \.self) { i in
                    if let fs = model.outputFullscreens[i] { FullscreenRow(index: i, output: fs) }
                }
            }
            if (model.outputFullscreens[1]?.displays.count ?? 0) < 2 {
                Label(L10n.t("fullscreen.one_display"), systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.t("fullscreen.settings_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.outputFullscreens.values.forEach { $0.reloadDisplays() } }
    }
}

private struct FullscreenRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @ObservedObject var output: FullscreenOutput

    var body: some View {
        GridRow {
            Toggle(L10n.f("output.title", index), isOn: Binding(get: { model.fullscreenOutputs.contains(index) },
                                                                set: { model.setFullscreenUse(index, $0) }))
                .toggleStyle(.checkbox).font(.system(size: 11, weight: .bold))
                .help(L10n.t("fullscreen.use_help"))
            Picker("", selection: Binding(get: { output.target?.id ?? 0 }, set: { id in
                if let d = output.displays.first(where: { $0.id == id }) { output.select(d) }
            })) {
                if output.displays.isEmpty { Text(L10n.t("fullscreen.none")).tag(UInt32(0)) }
                ForEach(output.displays, id: \.id) { d in
                    Text(d.isMain ? d.name + " · " + L10n.t("fullscreen.main") : d.name).tag(d.id)
                }
            }
            .labelsHidden().frame(width: 220)
            Picker("", selection: Binding(get: { model.outputRouting.slot(index).source },
                                          set: { model.setOutputSource(index, $0) })) {
                Text(L10n.t("monitor.program")).tag(OutputSource.program)
                Text(L10n.t("monitor.preview")).tag(OutputSource.preview)
                Divider()
                ForEach(model.inputs) { inp in Text("\(inp.number) \(inp.name)").tag(OutputSource.input(inp.id)) }
            }
            .labelsHidden().frame(width: 170)
            FullscreenButton(output: output, compact: true)
        }
    }
}

/// vMix-style Fullscreen button: click toggles, the menu picks the display.
struct FullscreenButton: View {
    @ObservedObject var output: FullscreenOutput
    /// Icon only (output rows under EXTERNAL ⚙).
    var compact = false
    var body: some View {
        Button { output.toggle() } label: {
            Label(L10n.t("fullscreen.button"), systemImage: output.isActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .labelStyle(AdaptiveLabelStyle(iconOnly: compact))
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 4)
                .background(output.isActive ? Theme.program : Theme.panelRaised)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.t("fullscreen.help"))
        .contextMenu {
            Section(L10n.t("fullscreen.display")) {
                if output.displays.isEmpty { Text(L10n.t("fullscreen.none")) }
                ForEach(output.displays, id: \.id) { d in
                    Button { output.select(d) } label: {
                        if output.target?.id == d.id { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            }
        }
    }
}

struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 4) { configuration.icon; configuration.title } }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    let systemImage: String
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color)
            .clipShape(Capsule())
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(max(0, s))
    return String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
}
#endif
