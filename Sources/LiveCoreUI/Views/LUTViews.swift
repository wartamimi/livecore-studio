#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// LUT choice for one input, inside the colour page (0.48.0).
struct LUTSection: View {
    @EnvironmentObject var model: AppModel
    let input: InputID
    @Binding var adjust: InputAdjust
    @State private var library: [URL] = []
    @State private var showGenerator = false

    var body: some View {
        Section(L10n.t("lut.title")) {
            Picker(L10n.t("lut.file"), selection: Binding(get: { adjust.lut }, set: { set(lut: $0) })) {
                Text(L10n.t("lut.none")).tag(String?.none)
                ForEach(library, id: \.path) { u in
                    Text(u.deletingPathExtension().lastPathComponent).tag(Optional(u.path))
                }
                if let p = adjust.lut, !library.contains(where: { $0.path == p }) {
                    Text(URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent).tag(Optional(p))
                }
            }
            LabeledContent(L10n.t("lut.strength")) {
                Slider(value: Binding(get: { adjust.lutStrength }, set: { adjust.lutStrength = $0; model.setAdjust(input, adjust) }), in: 0...1)
                    .disabled(adjust.lut == nil)
                Text("\(Int((adjust.lutStrength * 100).rounded()))%").monospacedDigit().frame(width: 50, alignment: .trailing)
            }
            HStack {
                Button(L10n.t("lut.import")) {
                    if let u = model.importLUT() { library = model.lutLibrary(); set(lut: u.path) }
                }
                Button(L10n.t("lut.generator")) { showGenerator = true }
                Spacer()
                Button { NSWorkspace.shared.open(AppModel.lutFolder) } label: { Image(systemName: "folder") }
                    .help(L10n.t("lut.show_folder"))
                    .disabled(library.isEmpty)
            }
            Text(L10n.t("lut.hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
        .onAppear { library = model.lutLibrary() }
        .sheet(isPresented: $showGenerator, onDismiss: {
            library = model.lutLibrary()
            adjust = model.adjust(of: input)
        }) {
            LUTGeneratorSheet(input: input).environmentObject(model)
        }
    }

    private func set(lut: String?) {
        adjust.lut = lut
        if lut != nil, adjust.lutStrength < 0.01 { adjust.lutStrength = 1 }
        model.setAdjust(input, adjust)
    }
}

/// Professional LUT generator (0.48.0): presets plus exposure, white balance, film contrast,
/// lift / gamma / gain, saturation, vibrance, split toning, fade and highlight roll-off. The input
/// shows the look live while editing; Save puts a .cube in the library and applies it, Export
/// writes a .cube for other apps.
struct LUTGeneratorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var look = LUTLook()
    @State private var name = "My Look"
    @State private var size = 33
    @State private var presetID = "neutral"
    @State private var original = InputAdjust()
    @State private var previewTask: Task<Void, Never>?
    @State private var previewURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("livecore-lut-preview-\(UUID().uuidString).cube")
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("lut.generator")).font(.headline)
            Text(L10n.t("lut.generator_hint")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(LUTPreset.all) { p in
                    Button {
                        presetID = p.id; look = p.look
                        if name == "My Look" || LUTPreset.all.contains(where: { $0.name == name }) { name = p.name }
                    } label: {
                        Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(presetID == p.id ? Theme.accent.opacity(0.35) : Theme.panelRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            ScrollView {
                Form {
                    Section(L10n.t("lut.sec_light")) {
                        row(L10n.t("lut.exposure"), \.exposure, -2...2, "%+.2f")
                        row(L10n.t("lut.contrast"), \.contrast, 0.5...2, "%.2f")
                        row(L10n.t("lut.rolloff"), \.highlightRolloff, 0...1, "%.2f")
                        row(L10n.t("lut.fade"), \.fade, 0...0.3, "%.2f")
                    }
                    Section(L10n.t("lut.sec_color")) {
                        row(L10n.t("lut.temperature"), \.temperature, -1...1, "%+.2f")
                        row(L10n.t("lut.tint"), \.tint, -1...1, "%+.2f")
                        row(L10n.t("lut.saturation"), \.saturation, 0...2, "%.2f")
                        row(L10n.t("lut.vibrance"), \.vibrance, -1...1, "%+.2f")
                        Toggle(L10n.t("lut.monochrome"), isOn: $look.monochrome)
                    }
                    Section(L10n.t("lut.sec_cdl")) {
                        row(L10n.t("lut.lift"), \.lift, -0.2...0.2, "%+.3f")
                        row(L10n.t("lut.gamma"), \.gamma, 0.5...2, "%.2f")
                        row(L10n.t("lut.gain"), \.gain, 0.5...1.5, "%.2f")
                    }
                    Section(L10n.t("lut.sec_split")) {
                        row(L10n.t("lut.shadow_hue"), \.shadowHue, 0...360, "%.0f°")
                        row(L10n.t("lut.shadow_amount"), \.shadowAmount, 0...1, "%.2f")
                        row(L10n.t("lut.highlight_hue"), \.highlightHue, 0...360, "%.0f°")
                        row(L10n.t("lut.highlight_amount"), \.highlightAmount, 0...1, "%.2f")
                    }
                    Section(L10n.t("lut.sec_file")) {
                        TextField(L10n.t("lut.name"), text: $name)
                        Picker(L10n.t("lut.size"), selection: $size) {
                            ForEach(CubeLUT.sizes, id: \.self) { Text("\($0)³").tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .formStyle(.grouped)
            }
            .frame(minHeight: 320)
            HStack {
                Button(L10n.t("lut.reset")) { look = LUTLook(); presetID = "neutral" }
                Button(L10n.t("lut.export")) { model.exportGeneratedLUT(look, name: name, size: size) }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("lut.save_apply")) {
                    if let u = model.saveGeneratedLUT(look, name: name, size: size) {
                        saved = true
                        var a = model.adjust(of: input)
                        a.lut = u.path; a.lutStrength = 1
                        model.setAdjust(input, a)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 680)
        .onAppear {
            original = model.adjust(of: input)
            model.preview(input)
        }
        .onChange(of: look) { _ in schedulePreview() }
        .onDisappear {
            previewTask?.cancel()
            if !saved {
                // Cancelled: the input gets its LUT back.
                var a = model.adjust(of: input)
                a.lut = original.lut; a.lutStrength = original.lutStrength
                model.setAdjust(input, a)
            }
            try? FileManager.default.removeItem(at: previewURL)
        }
    }

    /// Shows the look on the input (a small 17³ LUT, a quarter second after the last change).
    private func schedulePreview() {
        previewTask?.cancel()
        let look = look, url = previewURL
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let text = await Task.detached(priority: .userInitiated) { look.makeLUT(title: "Preview", size: 17).cubeText() }.value
            guard !Task.isCancelled, (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
            model.engine?.reloadLUT(url.path)
            var a = model.adjust(of: input)
            a.lut = url.path; a.lutStrength = 1
            model.setAdjust(input, a)
        }
    }

    private func row(_ label: String, _ path: WritableKeyPath<LUTLook, Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        LabeledContent(label) {
            Slider(value: Binding(get: { look[keyPath: path] }, set: { look[keyPath: path] = $0; presetID = "" }), in: range)
            Text(String(format: fmt, look[keyPath: path])).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }
}
#endif
