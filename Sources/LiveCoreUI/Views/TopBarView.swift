#if os(macOS)
import SwiftUI
import LiveCoreEngine

struct TopBarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 14) {
            Text(L10n.t("app.name")).font(.system(size: 15, weight: .heavy))
            Text("\(model.settings.output.label)").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            Spacer()
            stat(L10n.t("top.cpu"), String(format: "%.0f%%", model.performance.cpuPercentOfMachine),
                 warn: model.performance.cpuPercentOfMachine > 70)
            stat(L10n.t("top.gpu"), String(format: "%.1f ms", model.performance.gpuFrameMs),
                 warn: model.performance.gpuFrameMs > 1000 / Double(max(model.settings.output.frameRate, 1)) * 0.8)
            stat(L10n.t("top.mem"), String(format: "%.0f MB", model.performance.memoryMB), warn: false)
            stat(L10n.t("top.fps"), String(format: "%.1f", model.performance.renderFPS),
                 warn: model.performance.renderFPS < Double(model.settings.output.frameRate) * 0.95 && model.performance.renderFPS > 0)
            stat(L10n.t("top.dropped"), "\(model.performance.droppedRenderFrames)", warn: false)
            if model.performance.thermalState == .serious || model.performance.thermalState == .critical {
                Label("Thermal", systemImage: "thermometer.high").foregroundStyle(Theme.warning).font(.system(size: 11, weight: .bold))
            }
            Divider().frame(height: 18)
            StatusPill(text: streamText, color: streamColor, systemImage: "dot.radiowaves.left.and.right")
            StatusPill(text: recordText, color: model.isRecording ? Theme.program : Theme.panelRaised, systemImage: "record.circle")
            Button { openWindow(id: "multiview") } label: { Image(systemName: "square.grid.3x2") }
                .help(L10n.t("multiview.open"))
                .buttonStyle(.borderless)
            FullscreenButton(output: model.fullscreen)
            Button { openWindow(id: "program-output") } label: { Image(systemName: "rectangle.on.rectangle") }
                .help("Open Program output window (drag to an external display)")
                .buttonStyle(.borderless)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help(L10n.t("settings.title"))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .panel()
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

/// vMix-style Fullscreen button: click toggles, the menu picks the display.
struct FullscreenButton: View {
    @ObservedObject var output: FullscreenOutput
    var body: some View {
        Button { output.toggle() } label: {
            Label(L10n.t("fullscreen.button"), systemImage: output.isActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
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
