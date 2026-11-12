#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

/// QR code designer (0.58.0): several items (presets) per input, the code's content (link, text,
/// QRIS / payment, Wi-Fi, contact, WhatsApp, e-mail, phone or an existing QR picture), the card's
/// look and place, and how it is shown (motion, hide after N seconds).
struct QRCodeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: InputID?

    enum Page: String, CaseIterable { case content, style, show }

    @State private var design = QRDesign.template("blank")
    @State private var page: Page = .content
    @State private var preview: CGImage?
    @State private var note: String?

    private var index: Int { min(max(design.selected, 0), design.items.count - 1) }
    private var item: Binding<QRItem> {
        Binding(get: { design.items[index] }, set: { design.items[index] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DialogTitle("qrcode", L10n.t(editing == nil ? "qr.add_title" : "qr.edit_title"))
                Spacer()
                if editing == nil {
                    Menu(L10n.t("qr.template")) {
                        ForEach(QRDesign.templates, id: \.self) { t in
                            Button(L10n.t("qr.tpl." + t)) { design = QRDesign.template(t) }
                        }
                    }
                    .fixedSize()
                }
            }
            HStack(alignment: .top, spacing: 12) {
                itemList.frame(width: 170)
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $page) {
                        ForEach(Page.allCases, id: \.self) { Text(L10n.t("qr.page." + $0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    ScrollView {
                        Group {
                            switch page {
                            case .content: contentPage
                            case .style: stylePage
                            case .show: showPage
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                    }
                    .frame(height: 360)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        Checkerboard()
                        if let img = preview { Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                    if let p = design.current.payload {
                        Text(p).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textDim)
                            .lineLimit(3).textSelection(.enabled)
                    } else if design.current.kind != .image {
                        Text(L10n.t("qr.empty")).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
                }
                .frame(width: 300)
            }
            HStack {
                Text(L10n.t("qr.help")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }
                Button(editing == nil ? L10n.t("common.add") : L10n.t("settings.apply")) {
                    if let id = editing { model.updateQRCode(id, design) } else { model.addQRCode(design) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 940)
        .onAppear(perform: load)
        .onChange(of: design) { _ in refresh() }
    }

    // MARK: Items

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("qr.items")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textDim)
            List(selection: Binding(get: { design.selected }, set: { if let v = $0 { design.selected = v } })) {
                ForEach(Array(design.items.enumerated()), id: \.offset) { i, it in
                    HStack(spacing: 6) {
                        Image(systemName: icon(it.kind)).frame(width: 14)
                        Text(it.name.isEmpty ? "QR" : it.name).lineLimit(1)
                    }
                    .tag(i)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 300)
            HStack(spacing: 4) {
                Button { design.items.append(QRItem(name: "QR \(design.items.count + 1)")); design.selected = design.items.count - 1 } label: { Image(systemName: "plus") }
                    .help(L10n.t("qr.item_add"))
                Button {
                    var c = design.items[index]; c.id = UUID().uuidString; c.name += " 2"
                    design.items.insert(c, at: index + 1); design.selected = index + 1
                } label: { Image(systemName: "plus.square.on.square") }
                    .help(L10n.t("qr.item_duplicate"))
                Button { design.items.remove(at: index); design.selected = max(0, index - 1) } label: { Image(systemName: "minus") }
                    .disabled(design.items.count < 2).help(L10n.t("qr.item_remove"))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index >= design.items.count - 1)
            }
            .buttonStyle(.borderless)
        }
    }

    private func move(_ d: Int) {
        let j = index + d
        guard j >= 0, j < design.items.count else { return }
        design.items.swapAt(index, j)
        design.selected = j
    }

    private func icon(_ k: QRKind) -> String {
        switch k {
        case .url: return "link"
        case .text: return "text.alignleft"
        case .payment: return "creditcard"
        case .wifi: return "wifi"
        case .vcard: return "person.crop.square"
        case .whatsapp: return "message"
        case .email: return "envelope"
        case .phone: return "phone"
        case .image: return "photo"
        }
    }

    // MARK: Content

    private var contentPage: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            row(L10n.t("qr.name")) { TextField("", text: item.name) }
            row(L10n.t("qr.kind")) {
                Picker("", selection: item.kind) {
                    ForEach(QRKind.allCases, id: \.self) { Label(L10n.t("qr.kind." + $0.rawValue), systemImage: icon($0)).tag($0) }
                }
                .labelsHidden()
            }
            switch design.current.kind {
            case .url:
                row(L10n.t("qr.link")) { TextField("https://…", text: item.text) }
            case .text:
                row(L10n.t("qr.text")) { editor(item.text) }
            case .payment:
                row(L10n.t("qr.payment_data")) { editor(item.text) }
                row("") {
                    Button(L10n.t("qr.read_picture")) { readPicture() }
                }
                note(L10n.t("qr.payment_help"))
            case .wifi:
                row(L10n.t("qr.ssid")) { TextField("", text: item.ssid) }
                row(L10n.t("qr.security")) {
                    Picker("", selection: item.security) {
                        ForEach(QRWiFiSecurity.allCases, id: \.self) { Text(L10n.t("qr.sec." + $0.rawValue)).tag($0) }
                    }.labelsHidden()
                }
                if design.current.security != .open { row(L10n.t("qr.password")) { TextField("", text: item.password) } }
                row("") { Toggle(L10n.t("qr.hidden_network"), isOn: item.hiddenNetwork) }
            case .vcard:
                row(L10n.t("qr.contact_name")) { TextField("", text: item.contactName) }
                row(L10n.t("qr.organization")) { TextField("", text: item.organization) }
                row(L10n.t("qr.phone")) { TextField("", text: item.phoneNumber) }
                row(L10n.t("qr.email")) { TextField("", text: item.emailAddress) }
                row(L10n.t("qr.website")) { TextField("", text: item.website) }
            case .whatsapp:
                row(L10n.t("qr.phone")) { TextField("0812…", text: item.phoneNumber) }
                row(L10n.t("qr.message")) { editor(item.message) }
            case .email:
                row(L10n.t("qr.email")) { TextField("", text: item.emailAddress) }
                row(L10n.t("qr.subject")) { TextField("", text: item.message) }
            case .phone:
                row(L10n.t("qr.phone")) { TextField("", text: item.phoneNumber) }
            case .image:
                row(L10n.t("qr.picture")) {
                    HStack {
                        Text(design.current.imagePath.isEmpty ? "—" : URL(fileURLWithPath: design.current.imagePath).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                        Button(L10n.t("qr.choose")) { if let p = choosePicture() { design.items[index].imagePath = p } }
                    }
                }
                note(L10n.t("qr.image_help"))
            }
            Divider().gridCellColumns(2)
            row(L10n.t("qr.card_title")) { TextField(L10n.t("qr.card_title_hint"), text: item.title) }
            row(L10n.t("qr.caption")) { editor(item.caption, height: 54) }
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat = 70) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }

    private func note(_ s: String) -> some View {
        GridRow {
            Text("")
            Text(s).font(.system(size: 11)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            content()
        }
    }

    // MARK: Style

    private var stylePage: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            row(L10n.t("qr.position")) {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<3, id: \.self) { r in
                        GridRow {
                            ForEach(0..<3, id: \.self) { c in
                                let a = QRAnchor.allCases[r * 3 + c]
                                Button { design.style.anchor = a } label: {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(design.style.anchor == a ? Theme.accent : Theme.border)
                                        .frame(width: 22, height: 13)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            slider(L10n.t("qr.size"), \.size, 0.12...0.7, pct: true)
            slider(L10n.t("qr.margin"), \.margin, 0...0.2, pct: true)
            row(L10n.t("qr.card")) {
                Picker("", selection: $design.style.card) {
                    ForEach(QRCardStyle.allCases, id: \.self) { Text(L10n.t("qr.card." + $0.rawValue)).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            row(L10n.t("qr.modules")) {
                Picker("", selection: $design.style.moduleShape) {
                    ForEach(QRModuleShape.allCases, id: \.self) { Text(L10n.t("qr.shape." + $0.rawValue)).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            row(L10n.t("qr.correction")) {
                Picker("", selection: $design.style.correction) {
                    ForEach(QRCorrection.allCases, id: \.self) { Text(L10n.t("qr.ec." + $0.rawValue)).tag($0) }
                }.labelsHidden()
            }
            row(L10n.t("qr.colors")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        colorPicker(L10n.t("qr.color.code"), \.foreground)
                        colorPicker(L10n.t("qr.color.eyes"), \.eyeColor)
                        colorPicker(L10n.t("qr.color.background"), \.background)
                    }
                    HStack(spacing: 12) {
                        colorPicker(L10n.t("qr.color.card"), \.cardColor, opacity: true)
                        colorPicker(L10n.t("qr.color.accent"), \.accent)
                        colorPicker(L10n.t("qr.color.title"), \.titleColor)
                        colorPicker(L10n.t("qr.color.caption"), \.captionColor)
                    }
                }
            }
            slider(L10n.t("qr.corners"), \.cornerRadius, 0...0.25, pct: true)
            slider(L10n.t("qr.text_size"), \.textScale, 0.6...1.8, pct: true)
            row(L10n.t("qr.logo")) {
                HStack {
                    Text(design.style.logoPath.isEmpty ? "—" : URL(fileURLWithPath: design.style.logoPath).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    Button(L10n.t("qr.choose")) { if let p = choosePicture() { design.style.logoPath = p } }
                    if !design.style.logoPath.isEmpty { Button(L10n.t("qr.clear")) { design.style.logoPath = "" } }
                }
            }
            if !design.style.logoPath.isEmpty {
                slider(L10n.t("qr.logo_size"), \.logoSize, 0.1...0.28, pct: true)
                note(L10n.t("qr.logo_help"))
            }
        }
    }

    private func slider(_ label: String, _ kp: WritableKeyPath<QRStyle, Double>, _ range: ClosedRange<Double>, pct: Bool) -> some View {
        row(label) {
            HStack {
                Slider(value: Binding(get: { design.style[keyPath: kp] }, set: { design.style[keyPath: kp] = $0 }), in: range)
                Text(String(format: "%.0f%%", design.style[keyPath: kp] * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func colorPicker(_ label: String, _ kp: WritableKeyPath<QRStyle, ProjectColor>, opacity: Bool = false) -> some View {
        ColorPicker(label, selection: Binding(get: { Color(nsColor: design.style[keyPath: kp].nsColor) },
                                              set: { design.style[keyPath: kp] = ProjectColor(NSColor($0)) }), supportsOpacity: opacity)
            .font(.system(size: 11))
    }

    // MARK: Show

    private var showPage: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            row(L10n.t("qr.animation")) {
                Picker("", selection: Binding(get: { design.style.animation }, set: { design.style.animation = $0 })) {
                    ForEach(OverlayAnimation.selectable, id: \.self) { Text(L10n.t("overlay.anim." + $0.rawValue)).tag($0) }
                }.labelsHidden()
            }
            row(L10n.t("qr.animation_time")) {
                HStack {
                    Slider(value: $design.style.animationDuration, in: 0.1...2)
                    Text(String(format: "%.1f s", design.style.animationDuration)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            row(L10n.t("qr.auto_hide")) {
                HStack {
                    Stepper(value: $design.style.autoHide, in: 0...600, step: 5) {
                        Text(design.style.autoHide <= 0 ? L10n.t("qr.auto_hide_off") : L10n.f("qr.seconds", "\(Int(design.style.autoHide))"))
                            .monospacedDigit()
                    }
                    ForEach([0, 15, 30, 60], id: \.self) { s in
                        Button(s == 0 ? L10n.t("qr.auto_hide_off") : "\(s) s") { design.style.autoHide = Double(s) }
                    }
                }
            }
            note(L10n.t("qr.show_help"))
        }
    }

    // MARK: Helpers

    private func choosePicture() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Reads a bank / e-wallet QR picture: its text becomes the payment data, so the code can be
    /// redrawn sharp in the card's style; a picture that cannot be read is shown as it is.
    private func readPicture() {
        guard let p = choosePicture() else { return }
        if let text = QRRenderer.decode(imageAt: URL(fileURLWithPath: p)) {
            design.items[index].text = text
            note = L10n.t("qr.read_ok")
        } else {
            design.items[index].kind = .image
            design.items[index].imagePath = p
            note = L10n.t("qr.read_failed")
        }
    }

    private func refresh() {
        let d = design
        preview = QRRenderer.image(d, width: 640, height: 360)
    }

    private func load() {
        if let id = editing, let q = model.qrSource(id) { design = q.design }
        refresh()
    }
}
#endif
