#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

/// GT title editor (0.40.0), in the spirit of vMix GT Designer: the element list, a preview where
/// the selected element can be dragged, and an inspector for text, font, colours, geometry,
/// visibility, pictures and the in-animation of each element.
struct GTTitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var texts: [String: String] = [:]
    @State private var overrides: [String: GTElementOverride] = [:]
    @State private var speed = 1.0
    @State private var selected: String?
    @State private var images: [String: Data] = [:]
    @State private var playStart: Date?
    @State private var playingOut = false
    @State private var dragBase: (x: Double, y: Double)?

    private var source: GTTitleSource? { model.gtTitleSource(input) }
    @State private var fonts = NSFontManager.shared.availableFontFamilies
    @State private var downloading = false
    private static let animationTypes = ["Reveal", "Expand", "Zoom", "Fade", "None"]
    private static let directions = ["Left", "Right", "Top", "Bottom"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = source {
                header(s)
                fontBanner(s.original)
                HStack(alignment: .top, spacing: 12) {
                    elementList(s.original).frame(width: 190)
                    VStack(spacing: 8) {
                        preview(s.original)
                        animationBar(s.original)
                    }
                    ScrollView { inspector(s.original).padding(.trailing, 6) }.frame(width: 290)
                }
            } else {
                Text(L10n.t("gt.missing"))
            }
            HStack {
                Button(L10n.t("gt.reset_all")) { overrides = [:]; speed = 1; if let s = source { resetTexts(s) } }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) {
                    model.updateGTTitle(input, fields: texts, overrides: overrides, speed: speed)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(source == nil)
            }
        }
        .padding(16)
        .frame(width: 1060, height: 640)
        .onAppear {
            guard let s = source else { return }
            resetTexts(s)
            overrides = s.overrides
            speed = s.speed
            for o in s.overrides.values { if let r = o.image, let d = GTTitleSource.loadImage(r) { images[r.path] = d } }
            selected = s.original.elements.first?.name
        }
    }

    private func resetTexts(_ s: GTTitleSource) {
        texts = [:]
        for f in s.original.textFields { texts[f] = s.text(f) }
    }

    // MARK: Header and list

    @ViewBuilder
    private func fontBanner(_ t: GTTemplate) -> some View {
        let missing = FontInstaller.missing(in: applied(t)).filter { !fonts.contains($0) }
        if !missing.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.f("gt.fonts_banner", missing.joined(separator: ", "))).lineLimit(2)
                Spacer()
                if downloading { ProgressView().controlSize(.small) }
                Button(L10n.t("gt.fonts_download")) {
                    downloading = true
                    model.downloadFonts(missing) { downloading = false; fonts = NSFontManager.shared.availableFontFamilies }
                }.disabled(downloading)
                Button(L10n.t("gt.fonts_file")) { pickFontFile() }
            }
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func pickFontFile() {
        model.installFontsFromPicker()
        fonts = NSFontManager.shared.availableFontFamilies
    }

    private func header(_ s: GTTitleSource) -> some View {
        HStack {
            Text(L10n.t("gt.edit_title")).font(.headline)
            Text(s.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(L10n.t("gt.note_short")).font(.caption).foregroundStyle(.secondary)
            Button(L10n.t("gt.fonts_file")) { pickFontFile() }
        }
    }

    private func elementList(_ t: GTTemplate) -> some View {
        List(selection: $selected) {
            ForEach(t.elements, id: \.name) { e in
                HStack(spacing: 6) {
                    Image(systemName: icon(e.kind)).frame(width: 16)
                    Text(e.name).lineLimit(1)
                        .foregroundStyle(overrides[e.name]?.hidden == true ? .secondary : .primary)
                    Spacer()
                    Button {
                        var o = overrides[e.name] ?? GTElementOverride()
                        o.hidden = o.hidden == true ? nil : true
                        overrides[e.name] = o
                    } label: {
                        Image(systemName: overrides[e.name]?.hidden == true ? "eye.slash" : "eye")
                    }.buttonStyle(.borderless).help(L10n.t("gt.visible"))
                }
                .tag(e.name)
            }
        }
        .listStyle(.bordered)
    }

    private func icon(_ k: GTElement.Kind) -> String {
        switch k {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .image: return "photo"
        }
    }

    // MARK: Preview

    private func applied(_ t: GTTemplate) -> GTTemplate {
        t.applying(overrides, speed: speed) { images[$0.path] ?? GTTitleSource.loadImage($0) }
    }

    private func preview(_ original: GTTemplate) -> some View {
        let t = applied(original)
        return GeometryReader { geo in
            let scale = min(geo.size.width / max(t.width, 1), geo.size.height / max(t.height, 1))
            let w = t.width * scale, h = t.height * scale
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(paused: playStart == nil)) { ctx in
                    if let img = render(t, width: Int(w), height: Int(h), phase: phase(t, at: ctx.date)) {
                        Image(decorative: img, scale: 1).resizable().frame(width: w, height: h)
                    }
                }
                if let name = selected, let e = t.elements.first(where: { $0.name == name }) {
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .contentShape(Rectangle())
                        .frame(width: max(4, e.width * scale), height: max(4, e.height * scale))
                        .offset(x: e.x * scale, y: e.y * scale)
                        .gesture(DragGesture().onChanged { g in
                            if dragBase == nil { dragBase = (e.x, e.y) }
                            guard let b = dragBase else { return }
                            var o = overrides[name] ?? GTElementOverride()
                            o.x = (b.x + g.translation.width / scale).rounded()
                            o.y = (b.y + g.translation.height / scale).rounded()
                            overrides[name] = o
                        }.onEnded { _ in dragBase = nil })
                }
            }
            .frame(width: w, height: h)
            .background(checkerboard)
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 300)
    }

    private var checkerboard: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(Color.gray.opacity(0.2))
    }

    private func phase(_ t: GTTemplate, at date: Date) -> GTPhase {
        guard let start = playStart else { return .shown }
        let e = date.timeIntervalSince(start)
        if playingOut { return e < t.outDuration + 0.4 ? .leaving(e) : .shown }
        return e < t.inDuration ? .entering(e) : .shown
    }

    private func play(out: Bool, _ t: GTTemplate) {
        playingOut = out
        let start = Date()
        playStart = start
        let total = (out ? applied(t).outDuration : applied(t).inDuration) + 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { if playStart == start { playStart = nil } }
    }

    private func render(_ t: GTTemplate, width: Int, height: Int, phase: GTPhase) -> CGImage? {
        guard width > 0, height > 0, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        GTRenderer.draw(t, fields: texts, in: ctx, width: Double(width), height: Double(height), phase: phase)
        return ctx.makeImage()
    }

    private func animationBar(_ t: GTTemplate) -> some View {
        HStack {
            Button { play(out: false, t) } label: { Label(L10n.t("gt.play"), systemImage: "play.fill") }
            Button { play(out: true, t) } label: { Label(L10n.t("gt.play_out"), systemImage: "arrow.uturn.backward") }
            Text(L10n.t("gt.speed"))
            Slider(value: $speed, in: 0.25...3, step: 0.25).frame(width: 160)
            Text(String(format: "%.2g×", speed)).monospacedDigit().frame(width: 40, alignment: .leading)
            Spacer()
            Text(L10n.f("gt.duration", String(format: "%.1f", applied(t).inDuration))
                 + " · " + L10n.f("gt.out_duration", String(format: "%.1f", applied(t).outDuration))).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Inspector

    private func bind<T>(_ name: String, _ kp: WritableKeyPath<GTElementOverride, T?>, _ fallback: T) -> Binding<T> {
        Binding(get: { overrides[name]?[keyPath: kp] ?? fallback },
                set: { var o = overrides[name] ?? GTElementOverride(); o[keyPath: kp] = $0; overrides[name] = o })
    }

    private func colorBinding(_ name: String, _ kp: WritableKeyPath<GTElementOverride, String?>, _ fallback: GTColor) -> Binding<Color> {
        Binding(get: {
            let c = overrides[name]?[keyPath: kp].flatMap(GTColor.init(hex:)) ?? fallback
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }, set: { new in
            guard let n = NSColor(new).usingColorSpace(.sRGB) else { return }
            var o = overrides[name] ?? GTElementOverride()
            o[keyPath: kp] = GTColor(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent),
                                     a: Double(n.alphaComponent)).hex
            overrides[name] = o
        })
    }

    private func number(_ label: String, _ value: Binding<Double>, step: Double = 1) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField("", value: value, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
            Stepper("", value: value, step: step).labelsHidden()
        }
    }

    @ViewBuilder
    private func inspector(_ t: GTTemplate) -> some View {
        if let name = selected, let e = t.elements.first(where: { $0.name == name }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(e.name).font(.headline).lineLimit(1)
                    Spacer()
                    Button(L10n.t("gt.reset_element")) { overrides[name] = nil; if e.kind == .text { texts[name] = e.text } }
                }
                Toggle(L10n.t("gt.visible"), isOn: Binding(get: { overrides[name]?.hidden != true },
                                                           set: { v in var o = overrides[name] ?? GTElementOverride(); o.hidden = v ? nil : true; overrides[name] = o }))
                if e.kind == .text {
                    GroupBox(L10n.t("gt.text")) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: Binding(get: { texts[name] ?? e.text }, set: { texts[name] = $0 }))
                                .font(.body).frame(height: 54)
                            Picker(L10n.t("gt.font"), selection: bind(name, \.fontFamily, e.fontFamily)) {
                                if !fonts.contains(e.fontFamily) { Text(e.fontFamily + " ⚠︎").tag(e.fontFamily) }
                                ForEach(fonts, id: \.self) { Text($0).tag($0) }
                            }
                            if !fonts.contains(overrides[name]?.fontFamily ?? e.fontFamily) {
                                Text(L10n.t("gt.font_missing")).font(.caption).foregroundStyle(.orange)
                            }
                            number(L10n.t("gt.font_size"), bind(name, \.fontSize, e.fontSize), step: 2)
                            HStack {
                                Toggle(L10n.t("gt.bold"), isOn: bind(name, \.bold, e.bold))
                                Toggle(L10n.t("gt.italic"), isOn: bind(name, \.italic, e.italic))
                                ColorPicker(L10n.t("gt.color"), selection: colorBinding(name, \.color, textColor(e)))
                            }
                            Picker(L10n.t("gt.align"), selection: bind(name, \.alignment, e.alignment)) {
                                Image(systemName: "text.alignleft").tag("Left")
                                Image(systemName: "text.aligncenter").tag("Center")
                                Image(systemName: "text.alignright").tag("Right")
                            }.pickerStyle(.segmented)
                            Picker(L10n.t("gt.valign"), selection: bind(name, \.verticalAlignment, e.verticalAlignment)) {
                                Text(L10n.t("gt.top")).tag("Top")
                                Text(L10n.t("gt.middle")).tag("Center")
                                Text(L10n.t("gt.bottom")).tag("Bottom")
                            }.pickerStyle(.segmented)
                        }.padding(4)
                    }
                }
                if e.kind == .rectangle || e.kind == .ellipse {
                    GroupBox(L10n.t("gt.shape")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ColorPicker(L10n.t("gt.fill"), selection: colorBinding(name, \.color, e.fill.stops.first?.color ?? e.fill.color))
                            if e.fill.kind != .solid && overrides[name]?.color == nil {
                                Text(L10n.t("gt.gradient_note")).font(.caption).foregroundStyle(.secondary)
                            }
                            ColorPicker(L10n.t("gt.stroke"), selection: colorBinding(name, \.strokeColor, e.stroke ?? .clear))
                            number(L10n.t("gt.stroke_width"), bind(name, \.strokeThickness, e.strokeThickness))
                            if e.kind == .rectangle { number(L10n.t("gt.radius"), bind(name, \.cornerRadius, e.cornerRadius), step: 2) }
                        }.padding(4)
                    }
                }
                if e.kind == .image {
                    GroupBox(L10n.t("gt.picture")) {
                        HStack {
                            Button(L10n.t("gt.replace_image")) { pickImage(name) }
                            if overrides[name]?.image != nil {
                                Button(L10n.t("gt.original_image")) { var o = overrides[name]; o?.image = nil; overrides[name] = o }
                            }
                        }.padding(4)
                    }
                }
                GroupBox(L10n.t("gt.position")) {
                    VStack(alignment: .leading, spacing: 4) {
                        number("X", bind(name, \.x, e.x))
                        number("Y", bind(name, \.y, e.y))
                        number(L10n.t("gt.width"), bind(name, \.width, e.width))
                        number(L10n.t("gt.height"), bind(name, \.height, e.height))
                        number(L10n.t("gt.skew"), bind(name, \.skewX, e.skewX))
                        HStack {
                            Text(L10n.t("gt.opacity")).frame(width: 90, alignment: .leading)
                            Slider(value: bind(name, \.opacity, e.opacity), in: 0...1)
                        }
                        Text(L10n.t("gt.drag_hint")).font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                animationBox(name, source?.original.animation(for: name))
            }
        } else {
            Text(L10n.t("gt.select")).foregroundStyle(.secondary)
        }
    }

    private func textColor(_ e: GTElement) -> GTColor {
        e.fill.kind == .solid || e.fill.stops.isEmpty ? e.fill.color : e.fill.stops.sorted { $0.position < $1.position }[0].color
    }

    private func animationBox(_ name: String, _ base: GTAnimation?) -> some View {
        GroupBox(L10n.t("gt.animation")) {
            VStack(alignment: .leading, spacing: 4) {
                Picker(L10n.t("gt.anim_type"), selection: bind(name, \.animation, base?.type ?? "None")) {
                    ForEach(Self.animationTypes, id: \.self) { Text(L10n.t("gt.anim." + $0.lowercased())).tag($0) }
                    if let b = base?.type, !Self.animationTypes.contains(b) { Text(b).tag(b) }
                }
                if (overrides[name]?.animation ?? base?.type ?? "None") != "None" {
                    Picker(L10n.t("gt.direction"), selection: bind(name, \.direction, base?.direction ?? "Left")) {
                        ForEach(Self.directions, id: \.self) { Text(L10n.t("gt.dir." + $0.lowercased())).tag($0) }
                    }
                    number(L10n.t("gt.delay"), bind(name, \.delay, base?.delay ?? 0), step: 0.1)
                    number(L10n.t("gt.anim_duration"), bind(name, \.duration, base?.duration ?? 0.5), step: 0.1)
                }
            }.padding(4)
        }
    }

    private func pickImage(_ name: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        guard panel.runModal() == .OK, let url = panel.url, let d = try? Data(contentsOf: url) else { return }
        images[url.path] = d
        var o = overrides[name] ?? GTElementOverride()
        o.image = ProjectMediaRef(path: url.path)
        overrides[name] = o
    }
}
#endif
