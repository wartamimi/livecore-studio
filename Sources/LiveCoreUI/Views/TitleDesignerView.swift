#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Title Designer (vMix-style): template gallery on the left, live preview and advanced settings
/// (text, box, position, effects) on the right. Classic titles open as their closest template.
struct TitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?

    @State private var title = TitleTemplate.classicStrap.sample.title
    @State private var subtitle = TitleTemplate.classicStrap.sample.subtitle
    @State private var design = TitleTemplate.classicStrap.defaultDesign
    @State private var category: TitleCategory = .lowerThird
    @State private var tab = 0
    @State private var thumbs: [TitleTemplate: CGImage] = [:]
    @State private var families: [String] = []

    private var canvas: PixelSize { model.settings.output.size }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                gallery
                Divider()
                editor
            }
            Divider()
            HStack {
                Button(L10n.t("titled.reset")) { design = design.template.defaultDesign.keepingTag(design.tag) }
                    .help(L10n.t("titled.reset_help"))
                Spacer()
                Text(L10n.t("titled.animation_hint")).font(.caption).foregroundStyle(Theme.textDim)
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    var st = TextSource.Style(title: title, subtitle: subtitle)
                    st.design = design.clamped()
                    if let id = editing { model.updateTitle(id, style: st) } else { model.addTitle(st) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 920, height: 640)
        .onAppear(perform: load)
    }

    // MARK: Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("inputs.title_generator")).font(.headline)
            Picker("", selection: $category) {
                ForEach(TitleCategory.allCases, id: \.self) { Text(L10n.t("titlecat." + $0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(TitleTemplate.allCases.filter { $0.category == category }, id: \.self) { t in
                        templateTile(t)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    private func templateTile(_ t: TitleTemplate) -> some View {
        let on = design.template == t
        return Button { choose(t) } label: {
            VStack(spacing: 3) {
                ZStack {
                    Checkerboard()
                    if let img = thumbs[t] { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(L10n.t("titletpl." + t.rawValue)).font(.system(size: 10, weight: on ? .bold : .regular)).lineLimit(1)
            }
            .padding(4)
            .background(on ? Theme.accent.opacity(0.25) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    /// Switching template keeps the operator's text; sample text is replaced by the new sample.
    private func choose(_ t: TitleTemplate) {
        let old = design.template.sample
        if title == old.title || title.isEmpty { title = t.sample.title }
        if subtitle == old.subtitle { subtitle = t.sample.subtitle }
        let tag = design.tag == old.tag ? t.sample.tag : design.tag
        design = t.defaultDesign.keepingTag(tag)
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            preview
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.t("title.title")).gridColumnAlignment(.trailing)
                    TextField("", text: $title)
                }
                GridRow {
                    Text(L10n.t("title.subtitle"))
                    TextField("", text: $subtitle)
                }
                if design.template.usesTag {
                    GridRow {
                        Text(L10n.t("titled.tag"))
                        TextField("", text: $design.tag)
                    }
                }
            }
            Picker("", selection: $tab) {
                Text(L10n.t("titled.tab.text")).tag(0)
                Text(L10n.t("titled.tab.box")).tag(1)
                Text(L10n.t("titled.tab.position")).tag(2)
                Text(L10n.t("titled.tab.effects")).tag(3)
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case 0: textTab
                    case 1: boxTab
                    case 2: positionTab
                    default: effectsTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    private var preview: some View {
        let w = 560.0, h = w * Double(canvas.height) / Double(max(canvas.width, 1))
        let ph = min(h, 300), pw = ph * Double(canvas.width) / Double(max(canvas.height, 1))
        let scale = 640 / Double(max(canvas.width, canvas.height))
        let iw = max(Int(Double(canvas.width) * scale), 16), ih = max(Int(Double(canvas.height) * scale), 16)
        return HStack {
            Spacer(minLength: 0)
            ZStack {
                Checkerboard()
                if let img = TitleRenderer.image(design, title: title, subtitle: subtitle, width: iw, height: ih) {
                    Image(decorative: img, scale: 1).resizable()
                }
            }
            .frame(width: pw, height: ph)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
            Spacer(minLength: 0)
        }
    }

    private var textTab: some View {
        Group {
            row(L10n.t("titled.font")) {
                Picker("", selection: $design.fontFamily) {
                    Text(L10n.t("titled.system_font")).tag(String?.none)
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(width: 240)
            }
            row(L10n.t("titled.weight")) {
                weightPicker($design.titleWeight)
                Text(L10n.t("title.subtitle")).foregroundStyle(Theme.textDim)
                weightPicker($design.subtitleWeight)
            }
            row("") {
                Toggle(L10n.t("titled.italic"), isOn: $design.italic)
                Toggle(L10n.t("titled.uppercase"), isOn: $design.uppercase)
            }
            slider(L10n.t("title.size"), $design.titleSize, 12...300)
            slider(L10n.t("title.subsize"), $design.subtitleSize, 8...200)
            slider(L10n.t("titled.tracking"), $design.tracking, -5...30, step: 0.5)
            slider(L10n.t("titled.line_gap"), $design.lineGap, -20...100)
            row(L10n.t("titled.align")) {
                Picker("", selection: $design.align) {
                    Image(systemName: "text.alignleft").tag(TitleAlign.left)
                    Image(systemName: "text.aligncenter").tag(TitleAlign.center)
                    Image(systemName: "text.alignright").tag(TitleAlign.right)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            row(L10n.t("titled.colors")) {
                ColorPicker(L10n.t("title.title"), selection: color(\.titleColor), supportsOpacity: true)
                ColorPicker(L10n.t("title.subtitle"), selection: color(\.subtitleColor), supportsOpacity: true)
                if design.template.usesTag {
                    ColorPicker(L10n.t("titled.tag"), selection: color(\.tagColor), supportsOpacity: true)
                }
            }
        }
    }

    private var boxTab: some View {
        Group {
            row("") { Toggle(L10n.t("titled.show_box"), isOn: $design.showBox) }
            row(L10n.t("titled.colors")) {
                ColorPicker(L10n.t("titled.box"), selection: color(\.boxColor), supportsOpacity: true)
                ColorPicker(L10n.t("titled.box2"), selection: color(\.box2Color), supportsOpacity: true)
                ColorPicker(L10n.t("titled.accent"), selection: color(\.accentColor), supportsOpacity: true)
            }
            row("") { Toggle(L10n.t("titled.pill"), isOn: $design.pill) }
            slider(L10n.t("titled.radius"), $design.cornerRadius, 0...100).disabled(design.pill)
            slider(L10n.t("titled.padding_x"), $design.paddingX, 0...200)
            slider(L10n.t("titled.padding_y"), $design.paddingY, 0...200)
            slider(L10n.t("titled.min_width"), $design.minWidth, 0...1, step: 0.01, percent: true)
            Text(L10n.t("titled.box_help")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var positionTab: some View {
        Group {
            row(L10n.t("titled.anchor")) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { r in
                        GridRow {
                            ForEach(0..<3, id: \.self) { c in
                                let a = TitleAnchor.allCases[r * 3 + c]
                                Button { design.anchor = a } label: {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(design.anchor == a ? Theme.accent : Theme.panelRaised)
                                        .frame(width: 26, height: 16)
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
                                }
                                .buttonStyle(.plain)
                                .help(L10n.t("titled.anchor." + a.rawValue))
                            }
                        }
                    }
                }
            }
            slider(L10n.t("titled.offset_x"), $design.offsetX, -0.5...0.5, step: 0.005, percent: true)
            slider(L10n.t("titled.offset_y"), $design.offsetY, -0.5...0.5, step: 0.005, percent: true)
            slider(L10n.t("titled.margin_x"), $design.marginX, 0...0.4, step: 0.005, percent: true)
            slider(L10n.t("titled.margin_y"), $design.marginY, 0...0.4, step: 0.005, percent: true)
            slider(L10n.t("titled.scale"), $design.scale, 0.5...2, step: 0.01, percent: true)
            Button(L10n.t("titled.center_offset")) { design.offsetX = 0; design.offsetY = 0 }
        }
    }

    private var effectsTab: some View {
        Group {
            slider(L10n.t("titled.outline"), $design.outlineWidth, 0...20, step: 0.5)
            row("") { ColorPicker(L10n.t("titled.outline_color"), selection: color(\.outlineColor), supportsOpacity: true) }
            Divider()
            row("") { Toggle(L10n.t("titled.shadow"), isOn: $design.shadow) }
            Group {
                slider(L10n.t("titled.shadow_blur"), $design.shadowBlur, 0...60)
                slider(L10n.t("titled.shadow_offset"), $design.shadowOffset, -30...30)
                row("") { ColorPicker(L10n.t("titled.shadow_color"), selection: color(\.shadowColor), supportsOpacity: true) }
            }
            .disabled(!design.shadow)
        }
    }

    // MARK: Helpers

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 120, alignment: .trailing).foregroundStyle(Theme.textDim)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double = 1, percent: Bool = false) -> some View {
        row(label) {
            Slider(value: value, in: range, step: step)
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded())) %" : String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue))
                .monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func weightPicker(_ b: Binding<TitleWeight>) -> some View {
        Picker("", selection: b) {
            ForEach(TitleWeight.allCases, id: \.self) { Text(L10n.t("titled.weight." + $0.rawValue)).tag($0) }
        }
        .labelsHidden().frame(width: 110)
    }

    private func color(_ kp: WritableKeyPath<TitleDesign, ProjectColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: design[keyPath: kp].nsColor) },
                set: { design[keyPath: kp] = ProjectColor(NSColor($0)) })
    }

    private func load() {
        families = TitleRenderer.fontFamilies
        if let id = editing, let t = model.textSource(id) {
            let st = t.style
            title = st.title
            subtitle = st.subtitle
            design = st.design ?? TitleDesign.fromClassic(
                layout: st.layout.rawValue, showBar: st.showBar, textColor: ProjectColor(st.textColor),
                barColor: ProjectColor(st.barColor), titleSize: Double(st.titleSize), subtitleSize: Double(st.subtitleSize))
        }
        category = design.template.category
        var th: [TitleTemplate: CGImage] = [:]
        for t in TitleTemplate.allCases {
            let s = t.sample
            th[t] = TitleRenderer.image(t.defaultDesign, title: s.title, subtitle: s.subtitle, width: 320, height: 180)
        }
        thumbs = th
    }
}

private extension TitleDesign {
    func keepingTag(_ tag: String) -> TitleDesign { var d = self; d.tag = tag; return d }
}

#endif
