#if os(macOS)
import AppKit
import CoreImage
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Window for the portrait 9:16 output: live picture, how the crop follows people, and its own
/// stream and recording (0.42.0).
struct VerticalOutputView: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    private static let ci = CIContext(options: [.workingColorSpace: NSNull()])

    private var v: VerticalSettings { model.verticalSettings }
    private func set(_ change: (inout VerticalSettings) -> Void) {
        var x = model.verticalSettings
        change(&x)
        x.enabled = true
        model.setVertical(x)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            monitor
            Form {
                Section(L10n.t("vertical.crop")) {
                    Picker(L10n.t("vertical.follow"), selection: Binding(get: { v.follow }, set: { f in set { $0.follow = f } })) {
                        Text(L10n.t("vertical.follow.faces")).tag(VerticalSettings.Follow.faces)
                        Text(L10n.t("vertical.follow.center")).tag(VerticalSettings.Follow.center)
                        Text(L10n.t("vertical.follow.manual")).tag(VerticalSettings.Follow.manual)
                    }
                    if v.follow == .manual {
                        Slider(value: Binding(get: { v.manualX }, set: { x in set { $0.manualX = x } }), in: 0...1) {
                            Text(L10n.t("vertical.position"))
                        }
                    }
                    if v.follow == .faces {
                        Slider(value: Binding(get: { v.smoothing }, set: { x in set { $0.smoothing = x } }), in: 0.02...0.3) {
                            Text(L10n.t("vertical.speed"))
                        }
                    }
                    Picker(L10n.t("vertical.size"), selection: Binding(get: { v.size }, set: { x in set { $0.size = x } })) {
                        ForEach(VerticalSettings.sizes, id: \.self) { Text("\($0.width)×\($0.height)").tag($0) }
                    }.disabled(model.isVerticalStreaming || model.isRecording)
                }
                Section(L10n.t("vertical.record")) {
                    Toggle(L10n.t("vertical.record_with"), isOn: Binding(get: { v.recordWithProgram && v.enabled },
                                                                          set: { x in set { $0.recordWithProgram = x } }))
                        .disabled(model.isRecording)
                }
                Section(L10n.t("vertical.stream")) {
                    TextField(L10n.t("vertical.server"), text: Binding(get: { v.streamURL }, set: { x in set { $0.streamURL = x } }),
                              prompt: Text("rtmps://…"))
                        .disabled(model.isVerticalStreaming)
                    HStack {
                        SecureField(model.hasVerticalKey() ? L10n.t("vertical.key_saved") : L10n.t("vertical.key"), text: $key)
                        Button(L10n.t("vertical.save_key")) { model.saveVerticalKey(key); key = "" }.disabled(key.isEmpty)
                    }
                    Stepper(L10n.f("vertical.bitrate", "\(v.bitrateKbps)"), value: Binding(get: { v.bitrateKbps },
                                                                                       set: { x in set { $0.bitrateKbps = x } }),
                            in: 1500...12000, step: 500).disabled(model.isVerticalStreaming)
                    HStack {
                        Button(model.isVerticalStreaming ? L10n.t("vertical.stop") : L10n.t("vertical.start")) {
                            set { _ in }
                            model.toggleVerticalStream()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(model.isVerticalStreaming ? .red : .accentColor)
                        Text(statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.t("vertical.note")).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(minWidth: 360)
        }
        .padding(12)
        .onAppear { model.engine?.vertical.setMonitor(true) }
        .onDisappear { model.engine?.vertical.setMonitor(false) }
    }

    private var statusText: String {
        guard let s = model.verticalStreamStats else { return "" }
        switch s.state {
        case .idle: return ""
        case .connecting: return L10n.t("vertical.connecting")
        case .live: return String(format: "LIVE · %.0f kbps", s.bitrateKbps)
        case let .reconnecting(n, _): return L10n.f("vertical.reconnecting", "\(n)")
        case let .failed(m): return m
        case .stopping: return "…"
        }
    }

    private var monitor: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
                ZStack {
                    Color.black
                    if let pb = model.engine?.vertical.latestFrame(),
                       let img = Self.ci.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))) {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text(L10n.t("vertical.waiting")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(9.0 / 16, contentMode: .fit)
            .frame(width: 270)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.isVerticalStreaming ? Color.red : Color.gray.opacity(0.5),
                                                              lineWidth: model.isVerticalStreaming ? 3 : 1))
            Text("9:16").font(.caption.bold()).foregroundStyle(.secondary)
        }
    }
}
#endif
