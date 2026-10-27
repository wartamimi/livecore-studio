#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Large view of one input (its whole scene, at output resolution) opened from the fullscreen
/// button on an input tile. Transparent areas show a checkerboard.
struct SourceViewerWindow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Checkerboard(cell: 12)
                PixelBufferView(feed: model.viewerFeed, transparent: true)
            }
            .aspectRatio(CGFloat(model.outputFormat.size.width) / CGFloat(max(1, model.outputFormat.size.height)), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            HStack(spacing: 10) {
                if let id = model.viewerInput, let info = model.inputs.first(where: { $0.id == id }) {
                    Text("\(info.number)  \(info.name)").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(L10n.t("inputs.preview")) { model.preview(id) }
                    Button(L10n.t("inputs.cutdirect")) { model.cutDirect(id) }
                } else {
                    Text(L10n.t("viewer.none")).foregroundStyle(Theme.textDim)
                    Spacer()
                }
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Label(L10n.t("fullscreen.button"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help(L10n.t("viewer.fullscreen_help"))
            }
            .padding(8)
        }
        .background(Theme.background)
        .onDisappear { model.closeViewer() }
    }
}

/// Camera / capture card settings: device, format (size and frame rate), mirroring and the
/// device's own audio. Used when adding the input and afterwards from its menu.
struct CaptureCardSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Input being edited, nil when adding a new one.
    let editing: InputID?
    @State private var deviceID: String = ""
    @State private var formats: [CaptureFormatCandidate] = []
    @State private var size: String = "auto"        // "auto" or "WxH"
    @State private var fps: Double = 0               // 0 = automatic
    @State private var mirror = false
    @State private var audioUID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil ? L10n.t("capturecard.add_title") : L10n.t("capturecard.edit_title")).font(.headline)
            Form {
                Picker(L10n.t("capturecard.device"), selection: $deviceID) {
                    if model.videoDevices.isEmpty { Text(L10n.t("inputs.no_cameras")).tag("") }
                    ForEach(model.videoDevices) { d in Text(d.name).tag(d.id) }
                }
                .disabled(editing != nil)
                Picker(L10n.t("capturecard.resolution"), selection: $size) {
                    Text(L10n.f("capturecard.auto", model.outputFormat.size.width, model.outputFormat.size.height)).tag("auto")
                    ForEach(sizes, id: \.self) { s in Text(s.replacingOccurrences(of: "x", with: " × ")).tag(s) }
                }
                Picker(L10n.t("capturecard.framerate"), selection: $fps) {
                    Text(L10n.f("capturecard.auto_fps", model.outputFormat.frameRate)).tag(0.0)
                    ForEach(rates, id: \.self) { r in Text(r.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(r)) fps" : String(format: "%.2f fps", r)).tag(r) }
                }
                Toggle(L10n.t("capturecard.mirror"), isOn: $mirror)
                if editing == nil {
                    Picker(L10n.t("capturecard.audio"), selection: $audioUID) {
                        Text(L10n.t("capturecard.no_audio")).tag("")
                        ForEach(model.audioDevices) { d in Text(d.name).tag(d.id) }
                    }
                }
                if let id = editing, let cam = model.cameraSource(id) {
                    LabeledContent(L10n.t("capturecard.status")) { Text(cam.status.label).foregroundStyle(Theme.textDim) }
                }
            }
            .formStyle(.grouped)
            Text(L10n.t("capturecard.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    if let id = editing { model.updateCamera(id, config: config) }
                    else { model.addCamera(uniqueID: deviceID, config: config, audioUID: audioUID.isEmpty ? nil : audioUID) }
                    dismiss()
                }
                .disabled(deviceID.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear(perform: load)
        .onChange(of: deviceID) { _ in
            formats = model.captureFormats(uniqueID: deviceID)
            if !sizes.contains(size) { size = "auto" }
            // Capture cards usually expose their audio as a device with a similar name.
            if editing == nil, let name = model.videoDevices.first(where: { $0.id == deviceID })?.name {
                audioUID = model.audioDevices.first(where: { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) })?.id ?? ""
            }
        }
    }

    private var sizes: [String] {
        var seen = Set<String>(), out: [(Int, Int)] = []
        for f in formats where seen.insert("\(f.width)x\(f.height)").inserted { out.append((f.width, f.height)) }
        return out.sorted { $0.0 * $0.1 > $1.0 * $1.1 }.map { "\($0.0)x\($0.1)" }
    }

    private var rates: [Double] {
        let chosen = parsedSize
        let list = formats.filter { chosen == nil || ($0.width == chosen!.0 && $0.height == chosen!.1) }
        var out: [Double] = []
        for f in list { for r in f.offeredFrameRates where !out.contains(where: { abs($0 - r) < 0.05 }) { out.append(r) } }
        return out.sorted()
    }

    private var parsedSize: (Int, Int)? {
        let p = size.split(separator: "x")
        guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]) else { return nil }
        return (w, h)
    }

    private var config: CaptureConfig {
        CaptureConfig(width: parsedSize?.0, height: parsedSize?.1, frameRate: fps > 0 ? fps : nil, mirror: mirror)
    }

    private func load() {
        model.refreshDevices()
        if let id = editing, let cam = model.cameraSource(id) {
            deviceID = cam.deviceUniqueID
            let c = cam.config
            if let w = c.width, let h = c.height { size = "\(w)x\(h)" }
            fps = c.frameRate ?? 0
            mirror = c.mirror
        } else if deviceID.isEmpty {
            deviceID = model.videoDevices.first?.id ?? ""
        }
        formats = model.captureFormats(uniqueID: deviceID)
    }
}
#endif
