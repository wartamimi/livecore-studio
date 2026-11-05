#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Virtual Set designer (0.59.0): 12 studios, talent cameras (keyed), the screen input, shot and
/// fine placement.
struct VirtualSetSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?

    @State private var design = VirtualSetTemplate.newsDesk.defaultDesign
    @State private var thumbs: [VirtualSetTemplate: CGImage] = [:]

    /// Inputs that can stand in the set or show on its screen (not other virtual sets).
    private var sources: [ProductionEngine.InputInfo] {
        model.inputs.filter { $0.kind != .virtualSet && $0.id != editing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t(editing == nil ? "vset.add_title" : "vset.edit_title")).font(.headline)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(VirtualSetTemplate.allCases, id: \.self) { t in tile(t) }
                }
            }
            .frame(height: 300)
            HStack(alignment: .top, spacing: 16) {
                preview
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(0..<design.template.spots.count, id: \.self) { i in
                        GridRow {
                            Text(L10n.f("vset.talent", i + 1))
                            Picker("", selection: talent(i)) {
                                Text(L10n.t("vset.none")).tag(String?.none)
                                ForEach(sources) { c in Text("\(c.number). \(c.name)").tag(String?.some(c.id.raw)) }
                            }
                            .labelsHidden()
                        }
                    }
                    if design.template.screen != nil {
                        GridRow {
                            Text(L10n.t("vset.screen"))
                            Picker("", selection: $design.screenInput) {
                                Text(L10n.t("vset.screen_art")).tag(String?.none)
                                ForEach(sources) { c in Text("\(c.number). \(c.name)").tag(String?.some(c.id.raw)) }
                            }
                            .labelsHidden()
                        }
                    }
                    GridRow {
                        Text(L10n.t("vset.shot"))
                        Picker("", selection: $design.shot) {
                            ForEach(VirtualSetShot.allCases, id: \.self) { Text(L10n.t("vset.shot." + $0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    GridRow {
                        Text(L10n.t("vset.text"))
                        TextField("", text: $design.text)
                    }
                    GridRow {
                        Text(L10n.t("frame.accent"))
                        ColorPicker("", selection: Binding(get: { Color(nsColor: design.accent.nsColor) },
                                                           set: { design.accent = ProjectColor(NSColor($0)) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                    GridRow {
                        Text(L10n.t("vset.size"))
                        Slider(value: $design.talentScale, in: 0.5...1.6)
                    }
                    GridRow {
                        Text(L10n.t("vset.move_x"))
                        Slider(value: $design.talentOffsetX, in: -0.3...0.3)
                    }
                    GridRow {
                        Text(L10n.t("vset.move_y"))
                        Slider(value: $design.talentOffsetY, in: -0.3...0.3)
                    }
                }
                .font(.system(size: 12))
            }
            HStack(spacing: 14) {
                Toggle(L10n.t("vset.desk_cut"), isOn: $design.deskCut)
                Toggle(L10n.t("vset.auto_key"), isOn: $design.autoKey)
            }
            .font(.system(size: 12))
            Text(L10n.t("vset.help")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("common.add") : L10n.t("settings.apply")) {
                    if let id = editing { model.updateVirtualSet(id, design.clamped) } else { model.addVirtualSet(design.clamped) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760)
        .onAppear(perform: load)
    }

    private func tile(_ t: VirtualSetTemplate) -> some View {
        Button { choose(t) } label: {
            VStack(spacing: 3) {
                ZStack {
                    Color.black
                    if let img = thumbs[t] { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(L10n.t("vsettpl." + t.rawValue)).font(.system(size: 10, weight: design.template == t ? .bold : .regular)).lineLimit(1)
            }
            .padding(4)
            .background(design.template == t ? Theme.accent.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(design.template == t ? Theme.accent : Theme.border,
                                                              lineWidth: design.template == t ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    /// The chosen studio with grey stand-ins where the talents go.
    private var preview: some View {
        let aspect = model.settings.output.size.aspect > 0 ? model.settings.output.size.aspect : 16.0 / 9.0
        let img = VirtualSetRenderer.image(design, width: 384, height: max(Int(384 / aspect), 16))
        return ZStack {
            Color.black
            if let img { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
        .frame(width: 320, height: 320 / aspect)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }

    private func talent(_ i: Int) -> Binding<String?> {
        Binding(get: { i < design.talents.count && !design.talents[i].isEmpty ? design.talents[i] : nil },
                set: { v in
                    while design.talents.count <= i { design.talents.append("") }
                    design.talents[i] = v ?? ""
                })
    }

    /// A new studio keeps the talents, screen input and placement; text and colour follow the
    /// studio unless the operator changed them.
    private func choose(_ t: VirtualSetTemplate) {
        var d = t.defaultDesign
        let old = design.template
        d.talents = design.talents
        d.screenInput = design.screenInput
        d.shot = design.shot
        d.talentScale = design.talentScale
        d.talentOffsetX = design.talentOffsetX
        d.talentOffsetY = design.talentOffsetY
        d.deskCut = design.deskCut
        d.autoKey = design.autoKey
        if design.text != old.sampleText { d.text = design.text }
        if design.accent != old.defaultAccent { d.accent = design.accent }
        design = d
    }

    private func load() {
        var th: [VirtualSetTemplate: CGImage] = [:]
        for t in VirtualSetTemplate.allCases { th[t] = VirtualSetRenderer.image(t.defaultDesign, width: 256, height: 144) }
        thumbs = th
        if let id = editing, let v = model.virtualSetSource(id) {
            design = v.design
        } else {
            let cams = model.inputs.filter { $0.kind == .camera }.map(\.id.raw)
            design.talents = Array(cams.prefix(design.template.spots.count))
        }
    }
}
#endif
