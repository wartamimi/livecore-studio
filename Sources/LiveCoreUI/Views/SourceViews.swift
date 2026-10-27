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
/// Colour correction and orientation of one input, applied live (vMix input colour correction).
struct InputAdjustSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var a = InputAdjust()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(L10n.t("adjust.title")) — \(model.inputs.first { $0.id == input }?.name ?? "")").font(.headline)
            Form {
                row(L10n.t("adjust.brightness"), \.brightness, -0.5...0.5, "%+.2f")
                row(L10n.t("adjust.contrast"), \.contrast, 0...2, "%.2f")
                row(L10n.t("adjust.saturation"), \.saturation, 0...2, "%.2f")
                row(L10n.t("adjust.gamma"), \.gamma, 0.5...2, "%.2f")
                Toggle(L10n.t("adjust.flip_h"), isOn: binding(\.flipHorizontal))
                Toggle(L10n.t("adjust.flip_v"), isOn: binding(\.flipVertical))
                Picker(L10n.t("adjust.rotation"), selection: binding(\.rotation)) {
                    Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                }
                .pickerStyle(.segmented)
                Text(L10n.t("adjust.rotate_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            .formStyle(.grouped)
            HStack {
                Button(L10n.t("adjust.reset")) { a = InputAdjust(); model.setAdjust(input, a) }
                Spacer()
                Button(L10n.t("common.ok")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            a = model.adjust(of: input)
            model.preview(input)
        }
    }

    private func binding<T>(_ path: WritableKeyPath<InputAdjust, T>) -> Binding<T> {
        Binding(get: { a[keyPath: path] }, set: { v in a[keyPath: path] = v; model.setAdjust(input, a) })
    }

    private func row(_ label: String, _ path: WritableKeyPath<InputAdjust, Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        LabeledContent(label) {
            Slider(value: binding(path), in: range)
            Text(String(format: fmt, a[keyPath: path])).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }
}

/// Add or edit a running-text (ticker) input.
struct TickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var c = TickerConfig(text: "")
    @State private var textColor = Color.white
    @State private var barColor = Color(red: 0.6, green: 0.05, blue: 0.05).opacity(0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("ticker.title")).font(.headline)
            TextEditor(text: $c.text)
                .font(.system(size: 13))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.textDim.opacity(0.4)))
                .disabled(c.textFilePath != nil)
            HStack {
                Button(L10n.t("ticker.from_file")) {
                    if let u = model.pickTextFile() {
                        c.textFilePath = u.path
                        if let t = try? String(contentsOf: u, encoding: .utf8) { c.text = t }
                    }
                }
                if let f = c.textFilePath {
                    Text((f as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button { c.textFilePath = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
                Spacer()
            }
            Text(L10n.t(c.textFilePath == nil ? "ticker.text_hint" : "ticker.file_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            Form {
                LabeledContent(L10n.t("ticker.speed")) {
                    Slider(value: $c.speed, in: TickerConfig.speedRange)
                    Text("\(Int(c.speed)) px/s").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                LabeledContent(L10n.t("ticker.size")) {
                    Slider(value: $c.fontSize, in: 12...120)
                    Text("\(Int(c.fontSize)) pt").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                LabeledContent(L10n.t("ticker.band")) {
                    Slider(value: $c.bandHeight, in: 0.04...0.25)
                    Text("\(Int(c.bandHeight * 100))%").monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                ColorPicker(L10n.t("ticker.text_color"), selection: $textColor, supportsOpacity: false)
                Toggle(L10n.t("ticker.show_bar"), isOn: $c.showBar)
                if c.showBar { ColorPicker(L10n.t("ticker.bar_color"), selection: $barColor, supportsOpacity: true) }
            }
            .formStyle(.grouped)
            Text(L10n.t("ticker.hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    c.textColor = ProjectColor(NSColor(textColor))
                    c.barColor = ProjectColor(NSColor(barColor))
                    if let id = editing { model.updateTicker(id, c) } else { model.addTicker(c) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            if let id = editing, let t = model.tickerSource(id) { c = t.config }
            textColor = Color(c.textColor.nsColor)
            barColor = Color(c.barColor.nsColor)
        }
    }
}

/// Add or edit a photo slideshow: a folder (or picked images), time per photo, cross-fade, loop.
struct SlideshowSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var urls: [URL] = []
    @State private var interval = 5.0
    @State private var fade = 1.0
    @State private var loop = true
    @State private var kenBurns = false
    @State private var folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("slideshow.title")).font(.headline)
            HStack {
                Button(L10n.t("slideshow.pick_folder")) { if let f = model.pickFolder() { folder = f; urls = SlideshowSource.images(inFolder: f) } }
                Button(L10n.t("slideshow.pick_images")) { let u = model.pickImages(); if !u.isEmpty { urls = u; folder = nil } }
                Spacer()
                Text(L10n.f("slideshow.count", "\(urls.count)")).foregroundStyle(Theme.textDim)
            }
            if !urls.isEmpty {
                Text(urls.prefix(6).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 6 ? ", …" : ""))
                    .font(.system(size: 10)).foregroundStyle(Theme.textDim).lineLimit(2)
            }
            Form {
                LabeledContent(L10n.t("slideshow.interval")) {
                    Slider(value: $interval, in: 1...60, step: 0.5)
                    Text(String(format: "%.1f s", interval)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                LabeledContent(L10n.t("slideshow.fade")) {
                    Slider(value: $fade, in: 0...5, step: 0.25)
                    Text(String(format: "%.2f s", fade)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Toggle(L10n.t("slideshow.loop"), isOn: $loop)
                Toggle(L10n.t("slideshow.kenburns"), isOn: $kenBurns)
            }
            if folder != nil {
                Text(L10n.t("slideshow.watch_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    if let id = editing {
                        model.slideshowSource(id)?.update(urls: urls, interval: interval, fade: fade, loop: loop,
                                                          kenBurns: kenBurns, folder: folder)
                    } else {
                        model.addSlideshow(urls: urls, interval: interval, fade: fade, loop: loop, kenBurns: kenBurns, folder: folder)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urls.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            if let id = editing, let s = model.slideshowSource(id) {
                urls = s.urls; interval = s.interval; fade = s.fade; loop = s.loop; kenBurns = s.kenBurns; folder = s.folder
            }
        }
    }
}
#endif
