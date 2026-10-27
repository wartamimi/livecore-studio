#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

struct InputPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var showTitleSheet = false
    @State private var editingTitle: InputID?
    @State private var keying: InputID?
    @State private var renaming: InputID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.t("inputs.title"))
                Spacer()
                addMenu
            }
            if model.inputs.isEmpty {
                Text(L10n.t("inputs.empty")).font(.system(size: 12)).foregroundStyle(Theme.textDim).padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                        ForEach(model.inputs) { info in
                            InputTile(info: info)
                                .contextMenu { contextMenu(info) }
                        }
                    }
                }
            }
        }
        .padding(8)
        .panel()
        .sheet(isPresented: $showTitleSheet) { TitleSheet(editing: nil).environmentObject(model) }
        .sheet(item: $editingTitle) { id in TitleSheet(editing: id).environmentObject(model) }
        .sheet(item: $keying) { id in ChromaKeySheet(input: id).environmentObject(model) }
        .alert(L10n.t("inputs.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $renameText)
            Button(L10n.t("common.ok")) { if let id = renaming { model.rename(id, renameText) }; renaming = nil }
            Button(L10n.t("settings.cancel"), role: .cancel) { renaming = nil }
        }
    }

    private var addMenu: some View {
        Menu {
            Section(L10n.t("inputs.camera")) {
                if model.videoDevices.isEmpty { Text(L10n.t("inputs.no_cameras")) }
                ForEach(model.videoDevices) { d in Button(d.name) { model.addCamera(d) } }
            }
            Button(L10n.t("inputs.video")) { model.addVideo() }
            Button(L10n.t("inputs.image")) { model.addImage() }
            Button(L10n.t("inputs.title_generator")) { showTitleSheet = true }
            Menu(L10n.t("inputs.color")) {
                Button("Black") { model.addColor(.black, name: "Black") }
                Button("White") { model.addColor(.white, name: "White") }
                Button("Blue") { model.addColor(NSColor(calibratedRed: 0.05, green: 0.2, blue: 0.55, alpha: 1), name: "Blue") }
                Button("Green screen") { model.addColor(NSColor(calibratedRed: 0, green: 0.7, blue: 0.25, alpha: 1), name: "Green") }
            }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t("inputs.add"))
        .onAppear { model.refreshDevices() }
    }

    @ViewBuilder
    private func contextMenu(_ info: ProductionEngine.InputInfo) -> some View {
        Button(L10n.t("inputs.preview")) { model.preview(info.id) }
        Button(L10n.t("inputs.cutdirect")) { model.cutDirect(info.id) }
        Menu(L10n.t("inputs.addlayer")) {
            ForEach([LayoutPreset.pipTopRight, .pipTopLeft, .pipBottomRight, .pipBottomLeft, .sideBySideLeft, .sideBySideRight], id: \.self) { p in
                Button(p.rawValue) { model.addPiP(source: info.id, preset: p) }
            }
        }
        if info.kind == .camera || info.kind == .videoFile || info.kind == .image {
            Button(L10n.t("key.menu")) { keying = info.id }
        }
        if info.kind == .text { Button("Edit Title…") { editingTitle = info.id } }
        if info.kind == .videoFile, let v = model.videoFile(info.id) {
            Button("Play") { v.play() }
            Button("Pause") { v.pause() }
            Button("Restart") { v.restart() }
        }
        Divider()
        Button(L10n.t("inputs.rename")) { renameText = info.name; renaming = info.id }
        Button(L10n.t("inputs.remove"), role: .destructive) { model.remove(info.id) }
    }
}

extension InputID: Identifiable { public var id: String { raw } }

struct InputTile: View {
    @EnvironmentObject var model: AppModel
    let info: ProductionEngine.InputInfo

    private var isProgram: Bool { model.switcher.program == info.id || model.switcher.transition?.from == info.id }
    private var isPreview: Bool { model.switcher.preview == info.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                PixelBufferView(feed: model.feed(for: info.id))
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text("\(info.number)")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isProgram ? Theme.program : (isPreview ? Theme.preview : Color.black.opacity(0.6)))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(info.status.label)
                Text(info.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            if !info.status.isHealthy, info.status != .starting {
                Text(info.status.label).font(.system(size: 9)).foregroundStyle(Theme.warning).lineLimit(2)
            }
        }
        .padding(4)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isProgram ? Theme.program : (isPreview ? Theme.preview : Theme.border), lineWidth: isProgram || isPreview ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.cutDirect(info.id) }
        .onTapGesture { model.preview(info.id) }
        .help("Click: Preview · Double-click: Cut to Program")
    }

    private var statusColor: Color {
        switch info.status {
        case .live: return Theme.preview
        case .starting: return Theme.textDim
        case .noSignal: return Theme.warning
        case .error: return Theme.program
        }
    }

    private var icon: String {
        switch info.kind {
        case .camera: return "video.fill"
        case .image: return "photo"
        case .videoFile: return "film"
        case .color: return "paintpalette"
        case .text: return "textformat"
        }
    }
}

struct TitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?
    @State private var title = "Speaker Name"
    @State private var subtitle = "Title / Organisation"
    @State private var bar = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("inputs.title_generator")).font(.headline)
            TextField(L10n.t("title.title"), text: $title)
            TextField(L10n.t("title.subtitle"), text: $subtitle)
            Toggle(L10n.t("title.bar"), isOn: $bar)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    if let id = editing { model.updateTitle(id, title: title, subtitle: subtitle, bar: bar) }
                    else { model.addTitle(title: title, subtitle: subtitle, bar: bar) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            if let id = editing, let t = model.textSource(id) {
                title = t.style.title; subtitle = t.style.subtitle; bar = t.style.showBar
            }
        }
    }
}

/// Live chroma-key editor: every change is applied to the engine immediately so the operator
/// sees the result in Preview/Program/Multiview while adjusting.
struct ChromaKeySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var key = ChromaKey()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(L10n.t("key.title")) — \(model.inputs.first { $0.id == input }?.name ?? "")").font(.headline)
            Toggle(L10n.t("key.enable"), isOn: $key.enabled)
            HStack {
                Text(L10n.t("key.color"))
                Spacer()
                Button(L10n.t("key.green")) { key.keyColor = .green }
                Button(L10n.t("key.blue")) { key.keyColor = .blue }
                ColorPicker("", selection: colorBinding, supportsOpacity: false).labelsHidden()
            }
            slider(L10n.t("key.similarity"), $key.similarity, 0.01...0.6)
            slider(L10n.t("key.smoothness"), $key.smoothness, 0.001...0.5)
            slider(L10n.t("key.spill"), $key.spill, 0.001...0.5)
            Text(L10n.t("key.hint")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            HStack {
                Button("Reset") { key = ChromaKey(enabled: key.enabled) }
                Spacer()
                Button(L10n.t("common.ok")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { key = model.chromaKey(input); loaded = true }
        .onChange(of: key) { k in if loaded { model.setChromaKey(k, for: input) } }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.3f", value.wrappedValue)).font(.system(size: 11).monospacedDigit()).frame(width: 44)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(.sRGB, red: key.keyColor.r, green: key.keyColor.g, blue: key.keyColor.b) },
                set: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .green
                    key.keyColor = ChromaKey.RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
                })
    }
}
#endif
