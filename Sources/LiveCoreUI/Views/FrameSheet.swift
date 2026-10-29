#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Camera frame designer: 8 templates, the camera shown in the window, name labels and colours.
struct FrameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?

    @State private var design = FrameTemplate.rounded.defaultDesign
    @State private var camera: InputID?
    @State private var thumbs: [FrameTemplate: CGImage] = [:]

    /// Inputs that can be shown in the window (not frames).
    private var cameras: [ProductionEngine.InputInfo] {
        model.inputs.filter { $0.kind != .frame && $0.id != editing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t(editing == nil ? "frame.add_title" : "frame.edit_title")).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(FrameTemplate.allCases, id: \.self) { t in
                    Button { choose(t) } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                Checkerboard()
                                if let img = thumbs[t] { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                            }
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(L10n.t("frametpl." + t.rawValue)).font(.system(size: 10, weight: design.template == t ? .bold : .regular))
                        }
                        .padding(4)
                        .background(design.template == t ? Theme.accent.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(design.template == t ? Theme.accent : Theme.border,
                                                                          lineWidth: design.template == t ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker(L10n.t("frame.camera"), selection: $camera) {
                Text(L10n.t("frame.no_camera")).tag(InputID?.none)
                ForEach(cameras) { c in Text("\(c.number). \(c.name)").tag(InputID?.some(c.id)) }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.t("title.title"))
                    TextField("", text: $design.title)
                }
                GridRow {
                    Text(L10n.t("title.subtitle"))
                    TextField("", text: $design.subtitle)
                }
                if design.template.usesTag {
                    GridRow {
                        Text(L10n.t("titled.tag"))
                        TextField("", text: $design.tag)
                    }
                }
            }
            HStack(spacing: 14) {
                colorPicker(L10n.t("frame.background_top"), \.background1)
                colorPicker(L10n.t("frame.background_bottom"), \.background2)
                colorPicker(L10n.t("frame.accent"), \.accent)
                colorPicker(L10n.t("frame.text"), \.textColor)
            }
            Toggle(L10n.t("frame.transparent"), isOn: $design.transparentBackground)
            Text(L10n.t("frame.help")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    if let id = editing { model.updateFrame(id, design, camera: camera) } else { model.addFrame(design, camera: camera) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
        .onAppear(perform: load)
    }

    private func colorPicker(_ label: String, _ kp: WritableKeyPath<FrameDesign, ProjectColor>) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(nsColor: design[keyPath: kp].nsColor) },
                                              set: { design[keyPath: kp] = ProjectColor(NSColor($0)) }), supportsOpacity: false)
    }

    /// A new template keeps the operator's text.
    private func choose(_ t: FrameTemplate) {
        var d = t.defaultDesign
        d.title = design.title
        d.subtitle = design.subtitle
        if !design.tag.isEmpty { d.tag = design.tag }
        d.transparentBackground = design.transparentBackground
        design = d
    }

    private func load() {
        var th: [FrameTemplate: CGImage] = [:]
        for t in FrameTemplate.allCases { th[t] = FrameRenderer.image(t.defaultDesign, width: 320, height: 180) }
        thumbs = th
        if let id = editing, let f = model.frameSource(id) {
            design = f.design
            camera = model.frameCamera(id)
        } else {
            camera = model.inputs.first { $0.kind == .camera }?.id
        }
    }
}
#endif
