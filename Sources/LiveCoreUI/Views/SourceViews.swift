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
    // Advanced
    @State private var showAdvanced = false
    @State private var codec = ""                    // "" = automatic
    @State private var bufferFrames = false
    @State private var range: InputAdjust.RangeFix = .none
    @State private var deinterlace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editing == nil ? L10n.t("capturecard.add_title") : L10n.t("capturecard.edit_title")).font(.headline)
            Form {
                Picker(L10n.t("capturecard.device"), selection: $deviceID) {
                    if model.videoDevices.isEmpty { Text(L10n.t("inputs.no_cameras")).tag("") }
                    ForEach(model.videoDevices) { d in
                        if editing == nil, let used = model.cameraInUse(d.id) {
                            Text(L10n.f("inputs.in_use_item", d.name, used)).tag(d.id)
                        } else {
                            Text(d.name).tag(d.id)
                        }
                    }
                }
                .disabled(editing != nil)
                if editing == nil, let used = model.cameraInUse(deviceID) {
                    Text(L10n.f("inputs.already_used", used)).font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
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
                DisclosureGroup(L10n.t("capturecard.advanced"), isExpanded: $showAdvanced) { advanced }
            }
            .formStyle(.grouped)
            Text(L10n.t("capturecard.note")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    let id = editing ?? model.addCamera(uniqueID: deviceID, config: config, audioUID: audioUID.isEmpty ? nil : audioUID)
                    if editing != nil, let id { model.updateCamera(id, config: config) }
                    if let id { model.setSignalFixes(id, range: range, deinterlace: deinterlace) }
                    dismiss()
                }
                .disabled(deviceID.isEmpty || (editing == nil && model.cameraInUse(deviceID) != nil))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500)
        .onAppear(perform: load)
        .onChange(of: size) { _ in if !codecs.contains(codec) { codec = "" } }
        .onChange(of: deviceID) { _ in
            formats = model.captureFormats(uniqueID: deviceID)
            if !codecs.contains(codec) { codec = "" }
            if !sizes.contains(size) { size = "auto" }
            // Capture cards usually expose their audio as a device with a similar name.
            if editing == nil, let name = model.videoDevices.first(where: { $0.id == deviceID })?.name {
                audioUID = model.audioDevices.first(where: { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) })?.id ?? ""
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        Picker(L10n.t("capturecard.codec"), selection: $codec) {
            Text(L10n.t("capturecard.codec_auto")).tag("")
            ForEach(codecs, id: \.self) { c in Text(CaptureCodec.label(c)).tag(c) }
        }
        .help(L10n.t("capturecard.codec_help"))
        if !codec.isEmpty {
            Text(L10n.t(CaptureCodec.isUncompressed(codec) ? "capturecard.codec_uncompressed_note" : "capturecard.codec_compressed_note"))
                .font(.system(size: 10)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
        Picker(L10n.t("capturecard.range"), selection: $range) {
            Text(L10n.t("capturecard.range_none")).tag(InputAdjust.RangeFix.none)
            Text(L10n.t("capturecard.range_expand")).tag(InputAdjust.RangeFix.limitedToFull)
            Text(L10n.t("capturecard.range_compress")).tag(InputAdjust.RangeFix.fullToLimited)
        }
        .help(L10n.t("capturecard.range_help"))
        Toggle(L10n.t("capturecard.deinterlace"), isOn: $deinterlace).help(L10n.t("capturecard.deinterlace_help"))
        Toggle(L10n.t("capturecard.buffer"), isOn: $bufferFrames).help(L10n.t("capturecard.buffer_help"))
        if let id = editing, let cam = model.cameraSource(id) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let s = cam.signalStats
                LabeledContent(L10n.t("capturecard.signal")) {
                    Text(L10n.f("capturecard.signal_value", s.size, CaptureCodec.label(s.codec), s.fps, s.dropped as Int))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.trailing)
                }
            }
            Button(L10n.t("capturecard.restart")) { cam.restartDevice() }.help(L10n.t("capturecard.restart_help"))
        }
    }

    /// Device formats offered at the chosen size (all sizes when automatic).
    private var codecs: [String] {
        let chosen = parsedSize
        var out: [String] = []
        for f in formats where !f.codec.isEmpty && (chosen == nil || (f.width == chosen!.0 && f.height == chosen!.1)) {
            if !out.contains(f.codec) { out.append(f.codec) }
        }
        return out.sorted { (CaptureCodec.isUncompressed($0) ? 0 : 1, $0) < (CaptureCodec.isUncompressed($1) ? 0 : 1, $1) }
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
        CaptureConfig(width: parsedSize?.0, height: parsedSize?.1, frameRate: fps > 0 ? fps : nil, mirror: mirror,
                      codec: codec.isEmpty ? nil : codec, bufferFrames: bufferFrames ? true : nil)
    }

    private func load() {
        model.refreshDevices()
        if let id = editing, let cam = model.cameraSource(id) {
            deviceID = cam.deviceUniqueID
            let c = cam.config
            if let w = c.width, let h = c.height { size = "\(w)x\(h)" }
            fps = c.frameRate ?? 0
            mirror = c.mirror
            codec = c.codec ?? ""
            bufferFrames = c.bufferFrames == true
            let a = model.adjust(of: id)
            range = a.range
            deinterlace = a.deinterlace
            showAdvanced = !codec.isEmpty || bufferFrames || range != .none || deinterlace
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
                Button(L10n.t("adjust.reset")) { a = a.resetKeepingSignalFixes; model.setAdjust(input, a) }
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
                .disabled(c.textFilePath != nil || !(c.feedURL ?? "").isEmpty)
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
            HStack {
                TextField(L10n.t("ticker.feed"), text: Binding(get: { c.feedURL ?? "" }, set: { c.feedURL = $0.isEmpty ? nil : $0 }),
                          prompt: Text("https://…/rss.xml"))
                Stepper(L10n.f("ticker.feed_every", "\(Int(c.feedRefreshMinutes ?? 5))"),
                        value: Binding(get: { c.feedRefreshMinutes ?? 5 }, set: { c.feedRefreshMinutes = $0 }), in: 1...120)
                    .fixedSize()
            }
            if !(c.feedURL ?? "").isEmpty {
                Text(L10n.t("ticker.feed_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                if let id = editing, let st = model.tickerSource(id)?.feedStatus, !st.isEmpty {
                    Text(st).font(.system(size: 10)).foregroundStyle(st.hasPrefix("Feed error") || st.hasPrefix("Invalid") ? Theme.warning : Theme.textDim)
                }
            }
            Form {
                Picker(L10n.t("ticker.direction"), selection: Binding(get: { c.scrollDirection }, set: { c.direction = $0 })) {
                    Text(L10n.t("ticker.rtl")).tag(TickerDirection.rightToLeft)
                    Text(L10n.t("ticker.ltr")).tag(TickerDirection.leftToRight)
                }
                .pickerStyle(.segmented)
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
                .disabled(c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (c.feedURL ?? "").isEmpty)
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
            .formStyle(.grouped)
            if folder != nil {
                Text(L10n.t("slideshow.watch_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
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
