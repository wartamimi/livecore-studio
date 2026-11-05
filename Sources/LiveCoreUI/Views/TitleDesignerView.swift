#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Gallery sections: the three title categories and running text.
enum TitleGalleryTab: Hashable {
    case title(TitleCategory)
    case ticker
    /// Templates saved by the operator or imported from .lctitle files (0.64.0).
    case mine
}

/// One template in My Templates, with its gallery picture.
struct MyTitleTemplate: Identifiable {
    let url: URL
    let package: TitlePackage
    let thumb: CGImage?
    var id: String { url.path }
}

/// Title Designer (vMix-style): template gallery on the left, live preview and advanced settings
/// (text, box, position, effects, animation) on the right. Classic titles open as their closest
/// template. Running text (ticker) inputs are made and edited here too.
struct TitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?

    @State private var title = TitleTemplate.classicStrap.sample.title
    @State private var subtitle = TitleTemplate.classicStrap.sample.subtitle
    @State private var design = TitleTemplate.classicStrap.defaultDesign
    @State private var galleryTab: TitleGalleryTab = .title(.lowerThird)
    @State private var tab = 0
    @State private var thumbs: [TitleTemplate: CGImage] = [:]
    @State private var tickerThumbs: [TickerTemplate: CGImage] = [:]
    @State private var myTemplates: [MyTitleTemplate] = []
    @State private var savingName: String?
    @State private var families: [String] = []
    /// Running text instead of a title.
    @State private var isTicker = false
    @State private var ticker = TickerTemplate.newsRed.config(text: L10n.t("titled.ticker_sample"))
    /// Start of the animation test in the preview.
    @State private var animStart: Date?
    @StateObject private var undo = DraftHistory<TitleDraft>()

    /// Everything the sheet edits, for undo / redo.
    struct TitleDraft: Equatable {
        var title: String
        var subtitle: String
        var design: TitleDesign
        var ticker: TickerConfig
        var isTicker: Bool
    }

    private var draft: TitleDraft { TitleDraft(title: title, subtitle: subtitle, design: design, ticker: ticker, isTicker: isTicker) }

    /// An existing input keeps its kind (title or running text).
    private var editingTicker: Bool { editing.map { model.tickerSource($0) != nil } ?? false }

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
                Button(L10n.t("titled.reset")) {
                    if isTicker {
                        if let t = ticker.template { ticker = t.config(text: ticker.text).keepingSource(of: ticker) }
                    } else {
                        design = design.template.defaultDesign.keepingTag(design.tag)
                    }
                }
                .help(L10n.t("titled.reset_help"))
                Button { animStart = Date() } label: { Label(L10n.t("titled.try_animation"), systemImage: "play.circle") }
                    .help(L10n.t("titled.try_animation_help"))
                UndoRedoButtons(history: undo)
                Menu {
                    Button(L10n.t("mytpl.save")) { savingName = isTicker ? (ticker.labelText.isEmpty ? L10n.t("titlecat.ticker") : ticker.labelText) : title }
                    Button(L10n.t("mytpl.export")) { exportTemplate() }
                    Divider()
                    Button(L10n.t("mytpl.import")) { importTemplate() }
                    Button(L10n.t("mytpl.show_folder")) {
                        try? FileManager.default.createDirectory(at: TitleTemplateLibrary.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(TitleTemplateLibrary.folder)
                    }
                } label: { Label(L10n.t("mytpl.menu"), systemImage: "square.and.arrow.down.on.square") }
                .fixedSize()
                .help(L10n.t("mytpl.help"))
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("title.add") : L10n.t("settings.apply")) {
                    if isTicker {
                        if let id = editing { model.updateTicker(id, ticker.clamped) } else { model.addTicker(ticker.clamped) }
                    } else {
                        var st = TextSource.Style(title: title, subtitle: subtitle)
                        st.design = design.clamped()
                        // A title linked to a table keeps its link.
                        if let id = editing { st.dataSource = model.dataSource(id) }
                        if let id = editing { model.updateTitle(id, style: st) } else { model.addTitle(st) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTicker && ticker.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (ticker.feedURL ?? "").isEmpty)
            }
            .padding(12)
        }
        .frame(width: 920, height: 640)
        .onAppear {
            load()
            undo.apply = { d in title = d.title; subtitle = d.subtitle; design = d.design; ticker = d.ticker; isTicker = d.isTicker }
            undo.start(draft, model: model)
        }
        .onDisappear { undo.stop(model: model) }
        .onChange(of: draft) { undo.record($0) }
        .alert(L10n.t("mytpl.save"), isPresented: Binding(get: { savingName != nil }, set: { if !$0 { savingName = nil } })) {
            TextField(L10n.t("mytpl.name"), text: Binding(get: { savingName ?? "" }, set: { savingName = $0 }))
            Button(L10n.t("settings.cancel"), role: .cancel) { savingName = nil }
            Button(L10n.t("mytpl.save_button")) {
                let name = (savingName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                savingName = nil
                do {
                    try TitleTemplateLibrary.save(currentPackage(name: name.isEmpty ? "Template" : name))
                    reloadMine()
                    galleryTab = .mine
                } catch { model.report(L10n.f("mytpl.save_failed", "\(error)")) }
            }
        }
    }

    // MARK: My Templates (.lctitle, 0.64.0)

    /// What is in the editor now, as a template file.
    private func currentPackage(name: String) -> TitlePackage {
        isTicker ? TitlePackage(name: name, ticker: ticker) : TitlePackage(name: name, title: title, subtitle: subtitle, design: design)
    }

    /// Kinds this sheet can take (an existing input keeps its kind).
    private func accepts(_ p: TitlePackage) -> Bool {
        guard let id = editing else { return true }
        return (p.kind == .ticker) == (model.tickerSource(id) != nil)
    }

    private func reloadMine() {
        myTemplates = TitleTemplateLibrary.list().map { item in
            let p = item.package
            let img: CGImage?
            if p.kind == .ticker, let c = p.ticker {
                img = TickerRenderer.preview(c, width: 320, height: 180)
            } else if let d = p.design {
                img = TitleRenderer.image(d, title: p.title ?? d.template.sample.title, subtitle: p.subtitle ?? "", width: 320, height: 180)
            } else { img = nil }
            return MyTitleTemplate(url: item.url, package: p, thumb: img)
        }
    }

    /// Puts a template in the editor. Text the operator typed is kept; sample text is replaced.
    private func apply(_ p: TitlePackage) {
        guard accepts(p) else { model.report(L10n.t("mytpl.wrong_kind")); return }
        if p.kind == .ticker, let c = p.ticker {
            isTicker = true
            let keep = ticker.text != L10n.t("titled.ticker_sample") || ticker.textFilePath != nil || !(ticker.feedURL ?? "").isEmpty
            ticker = keep ? c.keepingSource(of: ticker) : c
        } else if let d = p.design {
            isTicker = false
            let old = design.template.sample
            if title == old.title || title.isEmpty { title = p.title ?? d.template.sample.title }
            if subtitle == old.subtitle || subtitle.isEmpty { subtitle = p.subtitle ?? "" }
            design = d
        }
    }

    private func exportTemplate() {
        let panel = NSSavePanel()
        let name = isTicker ? (ticker.labelText.isEmpty ? "Running text" : ticker.labelText) : (title.isEmpty ? "Title" : title)
        panel.nameFieldStringValue = TitlePackage.fileName(for: name)
        panel.allowedContentTypes = [AppModel.titleTemplateType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TitleTemplateLibrary.write(currentPackage(name: url.deletingPathExtension().lastPathComponent), to: url) }
        catch { model.report(L10n.f("mytpl.save_failed", "\(error)")) }
    }

    private func importTemplate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppModel.titleTemplateType]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var last: TitlePackage?
        for url in panel.urls {
            do {
                let p = try TitleTemplateLibrary.read(url) { _ = FontInstaller.installFiles($0) }
                try TitleTemplateLibrary.save(p)
                last = p
            } catch { model.report("\(url.lastPathComponent): \(error)") }
        }
        reloadMine()
        families = TitleRenderer.fontFamilies
        if let last {
            galleryTab = .mine
            if accepts(last) { apply(last) }
        }
    }

    private func myTile(_ m: MyTitleTemplate) -> some View {
        tile(image: m.thumb, name: m.package.name, on: false) { apply(m.package) }
            .opacity(accepts(m.package) ? 1 : 0.4)
            .contextMenu {
                Button(L10n.t("mytpl.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
                Button(L10n.t("mytpl.delete"), role: .destructive) {
                    try? FileManager.default.trashItem(at: m.url, resultingItemURL: nil)
                    reloadMine()
                }
            }
    }

    // MARK: Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("inputs.title_generator")).font(.headline)
            Picker("", selection: $galleryTab) {
                if !editingTicker {
                    ForEach(TitleCategory.allCases, id: \.self) { Text(L10n.t("titlecat." + $0.rawValue)).tag(TitleGalleryTab.title($0)) }
                }
                if editing == nil || editingTicker { Text(L10n.t("titlecat.ticker")).tag(TitleGalleryTab.ticker) }
                Text(L10n.t("titlecat.mine")).tag(TitleGalleryTab.mine)
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    switch galleryTab {
                    case let .title(category):
                        ForEach(TitleTemplate.allCases.filter { $0.category == category }, id: \.self) { t in
                            templateTile(t)
                        }
                    case .ticker:
                        ForEach(TickerTemplate.allCases, id: \.self) { t in tickerTile(t) }
                    case .mine:
                        if myTemplates.isEmpty {
                            Text(L10n.t("mytpl.empty")).font(.caption).foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(myTemplates) { m in myTile(m) }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    private func templateTile(_ t: TitleTemplate) -> some View {
        tile(image: thumbs[t], name: L10n.t("titletpl." + t.rawValue), on: !isTicker && design.template == t) {
            isTicker = false
            choose(t)
        }
    }

    private func tickerTile(_ t: TickerTemplate) -> some View {
        tile(image: tickerThumbs[t], name: L10n.t("tickertpl." + t.rawValue), on: isTicker && ticker.template == t) {
            isTicker = true
            ticker = t.config(text: ticker.text).keepingSource(of: ticker)
        }
    }

    private func tile(image: CGImage?, name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Checkerboard()
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(name).font(.system(size: 10, weight: on ? .bold : .regular)).lineLimit(1)
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

    @ViewBuilder private var editor: some View {
        if isTicker {
            VStack(alignment: .leading, spacing: 10) {
                preview
                TickerEditorPanel(config: $ticker, editing: editing, families: families)
            }
            .padding(12)
        } else {
            titleEditor
        }
    }

    private var titleEditor: some View {
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
                Text(L10n.t("titled.tab.animation")).tag(4)
                Text("3D").tag(5)
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case 0: textTab
                    case 1: boxTab
                    case 2: positionTab
                    case 3: effectsTab
                    case 4: animationTab
                    default: tab3D
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
        let still = isTicker ? nil : TitleRenderer.image(design, title: title, subtitle: subtitle, width: iw, height: ih)
        return HStack {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isTicker && animStart == nil)) { ctx in
                let motion = motionProgress(at: ctx.date)
                let img = isTicker ? TickerRenderer.preview(ticker, width: iw, height: ih,
                                                           elapsed: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                                   : (letterElapsed(at: ctx.date) != nil || motion != nil
                                      ? TitleRenderer.image(design, title: title, subtitle: subtitle, width: iw, height: ih,
                                                            elapsed: letterElapsed(at: ctx.date), motion: motion)
                                      : still)
                let placed = animationPlacement(at: ctx.date)
                let r = placed.0, a = placed.1
                ZStack {
                    Checkerboard()
                    if let img {
                        Image(decorative: img, scale: 1).resizable()
                            .frame(width: pw * r.width, height: ph * r.height)
                            .position(x: pw * (r.x + r.width / 2), y: ph * (r.y + r.height / 2))
                            .opacity(a)
                    }
                }
                .frame(width: pw, height: ph)
                .clipped()
            }
            .frame(width: pw, height: ph)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
            Spacer(minLength: 0)
        }
    }

    /// Seconds into the letter animation while "Try animation" plays (nil = show the whole title).
    private func letterElapsed(at now: Date) -> Double? {
        guard !isTicker, let start = animStart, design.textAnimation != .off else { return nil }
        return now.timeIntervalSince(start)
    }

    /// How long the preview holds the title between in and out: 1 s, or until every letter is in.
    private var holdSeconds: Double {
        guard !isTicker, design.textAnimation != .off else { return 1 }
        let letters = TitleRenderer.letterCount(title: title, subtitle: subtitle, design: design)
        return max(1, TextReveal(animation: design.textAnimation, delay: design.letterDelay).totalDuration(letters: letters) + 0.5)
    }

    /// 3D motion progress while "Try animation" plays a title with a 3D motion: in, hold, out.
    private func motionProgress(at now: Date) -> Double? {
        guard !isTicker, let start = animStart, let t3 = design.active3D, t3.hasMotion else { return nil }
        let t = now.timeIntervalSince(start), dur = t3.duration, hold = holdSeconds
        if t < dur { return t / dur }
        if t < dur + hold { return 1 }
        if t < 2 * dur + hold { return 1 - (t - dur - hold) / dur }
        DispatchQueue.main.async { if animStart == start { animStart = nil } }
        return nil
    }

    /// The chosen in / out animation played once in the preview: in, hold, out.
    private func animationPlacement(at now: Date) -> (NormRect, Double) {
        guard let start = animStart else { return (.full, 1) }
        if !isTicker, design.active3D?.hasMotion == true { return (.full, 1) }
        let (anim, dur): (OverlayAnimation, Double) = isTicker
            ? (ticker.animation ?? .fade, ticker.animationDuration ?? 0.5)
            : (design.animation, design.animationDuration)
        let t = now.timeIntervalSince(start)
        let progress: Double
        let hold = holdSeconds
        if t < dur { progress = t / dur } else if t < dur + hold { progress = 1 } else if t < 2 * dur + hold { progress = 1 - (t - dur - hold) / dur } else {
            DispatchQueue.main.async { if animStart == start { animStart = nil } }
            return (.full, 1)
        }
        let p = anim.placement(.full, progress: progress)
        return (p.rect, p.opacity)
    }

    private var animationTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("") { Toggle(L10n.t("titled.use_overlay_animation"), isOn: $design.useOverlayAnimation) }
            VStack(alignment: .leading, spacing: 6) {
                row(L10n.t("titled.animation")) {
                    AnimationPicker(selection: Binding(get: { design.animation }, set: { design.animation = $0 }))
                }
                slider(L10n.t("titled.animation_duration"), $design.animationDuration, 0.1...5, step: 0.1)
            }
            .disabled(design.useOverlayAnimation)
            Divider()
            row(L10n.t("titled.text_animation")) {
                Picker("", selection: Binding(get: { design.textAnimation }, set: { design.textAnimation = $0 })) {
                    ForEach(TextAnimation.allCases, id: \.self) { Text(L10n.t("textanim." + $0.rawValue)).tag($0) }
                }
                .labelsHidden().frame(width: 200)
                ExperimentalTag()
            }
            if design.textAnimation != .off {
                slider(L10n.t("titled.letter_delay"), Binding(get: { design.letterDelay * 1000 }, set: { design.letterDelay = $0 / 1000 }),
                       10...300, step: 5)
            }
            Text(L10n.t("titled.animation_help")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 3D look and motion (0.59.0).
    private var tab3D: some View {
        let on = design.active3D != nil
        let t3 = Binding<Title3D>(get: { design.look3D ?? Title3D() }, set: { design.look3D = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            row("") {
                Toggle(L10n.t("titled3d.enable"), isOn: Binding(get: { on }, set: { v in
                    let def = design.template.defaultDesign.look3D
                    design.look3D = v ? (def?.isActive == true ? def : Title3D()) : Title3D.flat
                }))
            }
            Group {
                slider(L10n.t("titled3d.depth"), t3.depth, 0...60)
                slider(L10n.t("titled3d.direction"), t3.direction, 0...360, step: 5)
                row("") {
                    Toggle(L10n.t("titled3d.auto_side"), isOn: Binding(get: { t3.wrappedValue.sideColor == nil },
                                                                     set: { t3.wrappedValue.sideColor = $0 ? nil : ProjectColor(r: 0.2, g: 0.2, b: 0.25) }))
                    if t3.wrappedValue.sideColor != nil {
                        ColorPicker(L10n.t("titled3d.side"), selection: Binding(
                            get: { Color(nsColor: (t3.wrappedValue.sideColor ?? ProjectColor(r: 0, g: 0, b: 0)).nsColor) },
                            set: { t3.wrappedValue.sideColor = ProjectColor(NSColor($0)) }), supportsOpacity: false)
                    }
                }
                row("") { Toggle(L10n.t("titled3d.bevel"), isOn: t3.bevel) }
                slider(L10n.t("titled3d.tilt_x"), t3.tiltX, -35...35)
                slider(L10n.t("titled3d.tilt_y"), t3.tiltY, -35...35)
                Divider()
                row(L10n.t("titled3d.motion")) {
                    Picker("", selection: t3.motion) {
                        ForEach(Motion3D.allCases, id: \.self) { Text(L10n.t("motion3d." + $0.rawValue)).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
                if t3.wrappedValue.motion != .off {
                    slider(L10n.t("titled.animation_duration"), t3.duration, 0.2...3, step: 0.1)
                }
            }
            .disabled(!on)
            Text(L10n.t("titled3d.help")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
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
        var tt: [TickerTemplate: CGImage] = [:]
        for t in TickerTemplate.allCases {
            tt[t] = TickerRenderer.preview(t.config(text: L10n.t("titled.ticker_sample")), width: 320, height: 180)
        }
        tickerThumbs = tt
        if let id = editing, let k = model.tickerSource(id) {
            isTicker = true
            ticker = k.config
            galleryTab = .ticker
        }
        if let id = editing, let t = model.textSource(id) {
            let st = t.style
            title = st.title
            subtitle = st.subtitle
            design = st.design ?? TitleDesign.fromClassic(
                layout: st.layout.rawValue, showBar: st.showBar, textColor: ProjectColor(st.textColor),
                barColor: ProjectColor(st.barColor), titleSize: Double(st.titleSize), subtitleSize: Double(st.subtitleSize))
        }
        if !isTicker { galleryTab = .title(design.template.category) }
        var th: [TitleTemplate: CGImage] = [:]
        for t in TitleTemplate.allCases {
            let s = t.sample
            th[t] = TitleRenderer.image(t.defaultDesign, title: s.title, subtitle: s.subtitle, width: 320, height: 180)
        }
        thumbs = th
        reloadMine()
    }
}

private extension TitleDesign {
    func keepingTag(_ tag: String) -> TitleDesign { var d = self; d.tag = tag; return d }
}

private extension TickerConfig {
    /// A new style keeps the operator's text, file and feed.
    func keepingSource(of old: TickerConfig) -> TickerConfig {
        var c = self
        c.text = old.text
        c.textFilePath = old.textFilePath
        c.feedURL = old.feedURL
        c.feedRefreshMinutes = old.feedRefreshMinutes
        return c
    }
}

/// Overlay animation choice (fade, slides, zoom).
struct AnimationPicker: View {
    @Binding var selection: OverlayAnimation
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(OverlayAnimation.selectable, id: \.self) { Text(L10n.t("overlay.anim." + $0.rawValue)).tag($0) }
        }
        .labelsHidden().frame(width: 200)
    }
}

/// Running-text settings (vMix-style): text / file / RSS, style, band and label, motion.
struct TickerEditorPanel: View {
    @EnvironmentObject var model: AppModel
    @Binding var config: TickerConfig
    let editing: InputID?
    let families: [String]
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                Text(L10n.t("titled.tab.text")).tag(0)
                Text(L10n.t("tickered.tab.style")).tag(1)
                Text(L10n.t("tickered.tab.band")).tag(2)
                Text(L10n.t("tickered.tab.motion")).tag(3)
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case 0: textTab
                    case 1: styleTab
                    case 2: bandTab
                    default: motionTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var textTab: some View {
        Group {
            TextEditor(text: $config.text)
                .font(.system(size: 13))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.textDim.opacity(0.4)))
                .disabled(config.textFilePath != nil || !(config.feedURL ?? "").isEmpty)
            HStack {
                Button(L10n.t("ticker.from_file")) {
                    if let u = model.pickTextFile() {
                        config.textFilePath = u.path
                        if let t = try? String(contentsOf: u, encoding: .utf8) { config.text = t }
                    }
                }
                if let f = config.textFilePath {
                    Text((f as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Button { config.textFilePath = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
                Spacer()
            }
            Text(L10n.t(config.textFilePath == nil ? "ticker.text_hint" : "ticker.file_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
            HStack {
                TextField(L10n.t("ticker.feed"), text: Binding(get: { config.feedURL ?? "" }, set: { config.feedURL = $0.isEmpty ? nil : $0 }),
                          prompt: Text("https://…/rss.xml"))
                Stepper(L10n.f("ticker.feed_every", "\(Int(config.feedRefreshMinutes ?? 5))"),
                        value: Binding(get: { config.feedRefreshMinutes ?? 5 }, set: { config.feedRefreshMinutes = $0 }), in: 1...120)
                    .fixedSize()
                ExperimentalTag()
            }
            if !(config.feedURL ?? "").isEmpty {
                Text(L10n.t("ticker.feed_hint")).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                if let id = editing, let st = model.tickerSource(id)?.feedStatus, !st.isEmpty {
                    Text(st).font(.system(size: 10)).foregroundStyle(st.hasPrefix("Feed error") || st.hasPrefix("Invalid") ? Theme.warning : Theme.textDim)
                }
            }
        }
    }

    private var styleTab: some View {
        Group {
            row(L10n.t("titled.font")) {
                Picker("", selection: $config.fontFamily) {
                    Text(L10n.t("titled.system_font")).tag(String?.none)
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(width: 240)
            }
            row(L10n.t("titled.weight")) {
                Picker("", selection: Binding(get: { config.textWeight }, set: { config.weight = $0 })) {
                    ForEach(TitleWeight.allCases, id: \.self) { Text(L10n.t("titled.weight." + $0.rawValue)).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
            row("") {
                Toggle(L10n.t("titled.italic"), isOn: flag(\.italic))
                Toggle(L10n.t("titled.uppercase"), isOn: flag(\.uppercase))
                Toggle(L10n.t("titled.shadow"), isOn: flag(\.shadow))
            }
            slider(L10n.t("ticker.size"), $config.fontSize, 12...120)
            row(L10n.t("ticker.text_color")) { ColorPicker("", selection: color(\.textColor), supportsOpacity: true).labelsHidden() }
            row(L10n.t("tickered.separator")) {
                TextField("•", text: Binding(get: { config.separator ?? "•" }, set: { config.separator = $0 })).frame(width: 60)
                ColorPicker("", selection: Binding(get: { Color(nsColor: (config.separatorColor ?? config.textColor).nsColor) },
                                                   set: { config.separatorColor = ProjectColor(NSColor($0)) }), supportsOpacity: true).labelsHidden()
            }
        }
    }

    private var bandTab: some View {
        Group {
            row("") { Toggle(L10n.t("ticker.show_bar"), isOn: $config.showBar) }
            row(L10n.t("ticker.bar_color")) { ColorPicker("", selection: color(\.barColor), supportsOpacity: true).labelsHidden() }
            slider(L10n.t("ticker.band"), $config.bandHeight, 0.04...0.25, step: 0.005, percent: true)
            row(L10n.t("tickered.position")) {
                Picker("", selection: Binding(get: { positionMode },
                                              set: { v in config.bandY = v == 0 ? nil : (v == 1 ? Self.topY : 0.5) })) {
                    Text(L10n.t("tickered.bottom")).tag(0)
                    Text(L10n.t("tickered.top")).tag(1)
                    Text(L10n.t("tickered.custom")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            if positionMode == 2 {
                slider(L10n.t("tickered.band_y"), Binding(get: { config.bandY ?? 0.9 }, set: { config.bandY = $0 }),
                       0...max(1 - config.bandHeight, 0.01), step: 0.005, percent: true)
            }
            Divider()
            row(L10n.t("tickered.label")) {
                TextField(L10n.t("tickered.label_hint"), text: Binding(get: { config.label ?? "" }, set: { config.label = $0 })).frame(width: 160)
            }
            row(L10n.t("titled.colors")) {
                ColorPicker(L10n.t("tickered.label_box"), selection: Binding(
                    get: { Color(nsColor: (config.labelColor ?? ProjectColor(r: 1, g: 1, b: 1)).nsColor) },
                    set: { config.labelColor = ProjectColor(NSColor($0)) }), supportsOpacity: true)
                ColorPicker(L10n.t("tickered.label_text"), selection: Binding(
                    get: { Color(nsColor: (config.labelTextColor ?? ProjectColor(r: 1, g: 1, b: 1)).nsColor) },
                    set: { config.labelTextColor = ProjectColor(NSColor($0)) }), supportsOpacity: true)
            }
        }
    }

    private var motionTab: some View {
        Group {
            row(L10n.t("ticker.direction")) {
                Picker("", selection: Binding(get: { config.scrollDirection }, set: { config.direction = $0 })) {
                    Text(L10n.t("ticker.rtl")).tag(TickerDirection.rightToLeft)
                    Text(L10n.t("ticker.ltr")).tag(TickerDirection.leftToRight)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            slider(L10n.t("ticker.speed"), $config.speed, TickerConfig.speedRange)
            Divider()
            row("") {
                Toggle(L10n.t("titled.use_overlay_animation"), isOn: Binding(get: { config.animation == nil },
                                                                             set: { config.animation = $0 ? nil : .slideFromBottom }))
            }
            if config.animation != nil {
                row(L10n.t("titled.animation")) {
                    AnimationPicker(selection: Binding(get: { config.animation ?? .fade }, set: { config.animation = $0 }))
                }
                slider(L10n.t("titled.animation_duration"), Binding(get: { config.animationDuration ?? 0.5 }, set: { config.animationDuration = $0 }),
                       0.1...5, step: 0.1)
            }
            Divider()
            row("") { Toggle(L10n.t("tickered.look3d"), isOn: flag(\.look3D)) }
            row(L10n.t("titled3d.motion")) {
                Picker("", selection: Binding(get: { config.motion3D ?? .off }, set: { config.motion3D = $0 == .off ? nil : $0 })) {
                    ForEach(Motion3D.allCases, id: \.self) { Text(L10n.t("motion3d." + $0.rawValue)).tag($0) }
                }
                .labelsHidden().frame(width: 200)
            }
            if config.hasMotion3D {
                slider(L10n.t("titled.animation_duration"), Binding(get: { config.animationDuration ?? 0.5 }, set: { config.animationDuration = $0 }),
                       0.1...5, step: 0.1)
            }
            Text(L10n.t("ticker.hint")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    static let topY = 0.03
    /// 0 = bottom, 1 = top, 2 = custom height.
    private var positionMode: Int {
        guard let y = config.bandY else { return 0 }
        return abs(y - Self.topY) < 0.0001 ? 1 : 2
    }

    private func flag(_ kp: WritableKeyPath<TickerConfig, Bool?>) -> Binding<Bool> {
        Binding(get: { config[keyPath: kp] ?? false }, set: { config[keyPath: kp] = $0 })
    }

    private func color(_ kp: WritableKeyPath<TickerConfig, ProjectColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: config[keyPath: kp].nsColor) }, set: { config[keyPath: kp] = ProjectColor(NSColor($0)) })
    }

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
}

#endif
