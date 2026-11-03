import Foundation

/// QR code overlay (0.58.0): donations, digital angpao (wedding gift money), seminar material
/// links, Wi-Fi, contact cards… One QR input holds several items (presets) and shows one at a
/// time on a styled card. The payload text is built here (portable, unit tested); the macOS
/// engine draws the code with Core Image's QR generator and CoreGraphics.

public enum QRKind: String, Codable, Sendable, CaseIterable {
    /// Web link (https:// is added when no scheme is given).
    case url
    /// Any text, including a QRIS / EMV payment string copied from a bank or e-wallet.
    case text
    /// QRIS / payment: the EMV text read from the merchant's QR picture (or pasted).
    case payment
    /// Wi-Fi network (phones offer to join).
    case wifi
    /// Contact card (vCard 3.0).
    case vcard
    /// WhatsApp chat with a ready message.
    case whatsapp
    /// E-mail with a subject.
    case email
    /// Phone number to call.
    case phone
    /// A picture of an existing QR code shown as it is (when it cannot be read or must not change).
    case image
}

public enum QRWiFiSecurity: String, Codable, Sendable, CaseIterable { case wpa = "WPA", wep = "WEP", open = "nopass" }

/// Error correction level of the code: higher survives a logo in the middle and bad cameras.
public enum QRCorrection: String, Codable, Sendable, CaseIterable {
    case low = "L", medium = "M", quartile = "Q", high = "H"
    public var rank: Int { ["L": 0, "M": 1, "Q": 2, "H": 3][rawValue] ?? 1 }
}

/// One preset of a QR input: what the code holds plus the words around it.
public struct QRItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String = UUID().uuidString
    /// Preset name for the operator ("Angpao – groom", "Slides day 1").
    public var name: String = "QR"
    public var kind: QRKind = .url
    /// URL, text or payment string.
    public var text: String = ""
    // Wi-Fi
    public var ssid: String = ""
    public var password: String = ""
    public var security: QRWiFiSecurity = .wpa
    public var hiddenNetwork: Bool = false
    // Contact / WhatsApp / e-mail / phone
    public var contactName: String = ""
    public var organization: String = ""
    public var phoneNumber: String = ""
    public var emailAddress: String = ""
    public var website: String = ""
    /// WhatsApp message or e-mail subject.
    public var message: String = ""
    /// `.image`: the QR picture on disk.
    public var imagePath: String = ""
    /// Shown above the code ("Amplop Digital", "Scan for the slides").
    public var title: String = ""
    /// Shown under the code ("BCA 1234567890 a.n. Budi"); new lines allowed.
    public var caption: String = ""

    public init(name: String = "QR", kind: QRKind = .url, text: String = "", title: String = "", caption: String = "") {
        self.name = name; self.kind = kind; self.text = text; self.title = title; self.caption = caption
    }

    /// The text encoded in the code (nil = nothing to encode yet, or `.image`).
    public var payload: String? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch kind {
        case .url:
            let t = clean(text)
            guard !t.isEmpty else { return nil }
            return t.contains("://") || t.lowercased().hasPrefix("mailto:") ? t : "https://" + t
        case .text:
            return text.isEmpty ? nil : text
        case .payment:
            let t = clean(text)
            return t.isEmpty ? nil : t
        case .wifi:
            guard !ssid.isEmpty else { return nil }
            var s = "WIFI:T:\(security.rawValue);S:\(Self.wifiEscape(ssid));"
            if security != .open { s += "P:\(Self.wifiEscape(password));" }
            if hiddenNetwork { s += "H:true;" }
            return s + ";"
        case .vcard:
            guard !clean(contactName).isEmpty || !clean(phoneNumber).isEmpty else { return nil }
            var lines = ["BEGIN:VCARD", "VERSION:3.0"]
            let n = clean(contactName)
            lines.append("N:\(Self.vcardEscape(n));;;;")
            lines.append("FN:\(Self.vcardEscape(n))")
            if !clean(organization).isEmpty { lines.append("ORG:\(Self.vcardEscape(clean(organization)))") }
            if !clean(phoneNumber).isEmpty { lines.append("TEL;TYPE=CELL:\(clean(phoneNumber))") }
            if !clean(emailAddress).isEmpty { lines.append("EMAIL:\(clean(emailAddress))") }
            if !clean(website).isEmpty { lines.append("URL:\(Self.vcardEscape(clean(website)))") }
            lines.append("END:VCARD")
            return lines.joined(separator: "\r\n")
        case .whatsapp:
            let digits = Self.internationalDigits(phoneNumber)
            guard !digits.isEmpty else { return nil }
            let m = clean(message)
            return "https://wa.me/\(digits)" + (m.isEmpty ? "" : "?text=" + Self.percentEncode(m))
        case .email:
            let a = clean(emailAddress)
            guard !a.isEmpty else { return nil }
            let m = clean(message)
            return "mailto:\(a)" + (m.isEmpty ? "" : "?subject=" + Self.percentEncode(m))
        case .phone:
            let p = clean(phoneNumber).filter { $0.isNumber || $0 == "+" }
            return p.isEmpty ? nil : "tel:\(p)"
        case .image:
            return nil
        }
    }

    /// Escapes `\ ; , : "` as the Wi-Fi QR format asks.
    public static func wifiEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\;,:\"".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func vcardEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// "0812-3456 789" → "628123456789" (Indonesian 0 prefix becomes 62); "+1 555…" → "1555…".
    public static func internationalDigits(_ s: String) -> String {
        let d = s.filter(\.isNumber)
        if d.hasPrefix("0") { return "62" + d.dropFirst() }
        return d
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Where the card sits on the output.
public enum QRAnchor: String, Codable, Sendable, CaseIterable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    /// (0, 0.5, 1) horizontally and vertically (y down).
    public var factors: (x: Double, y: Double) {
        switch self {
        case .topLeft: return (0, 0)
        case .top: return (0.5, 0)
        case .topRight: return (1, 0)
        case .left: return (0, 0.5)
        case .center: return (0.5, 0.5)
        case .right: return (1, 0.5)
        case .bottomLeft: return (0, 1)
        case .bottom: return (0.5, 1)
        case .bottomRight: return (1, 1)
        }
    }
}

public enum QRModuleShape: String, Codable, Sendable, CaseIterable { case square, rounded, dots }

public enum QRCardStyle: String, Codable, Sendable, CaseIterable {
    /// Only the code on its light background.
    case none
    /// Rounded card behind code and words.
    case card
    /// Card with a coloured border.
    case border
    /// Card with a soft coloured glow.
    case glow
}

/// Look, place and timing of a QR input (shared by all its items).
public struct QRStyle: Codable, Equatable, Sendable {
    public var anchor: QRAnchor = .bottomRight
    /// Distance from the edges, fraction of the output height.
    public var margin: Double = 0.05
    /// Side of the code (with its quiet zone), fraction of the output height.
    public var size: Double = 0.30
    public var foreground = ProjectColor(r: 0.05, g: 0.05, b: 0.08)
    public var background = ProjectColor(r: 1, g: 1, b: 1)
    /// Colour of the three corner squares (finder patterns).
    public var eyeColor = ProjectColor(r: 0.05, g: 0.05, b: 0.08)
    public var moduleShape: QRModuleShape = .square
    public var correction: QRCorrection = .medium
    public var card: QRCardStyle = .card
    public var cardColor = ProjectColor(r: 1, g: 1, b: 1, a: 0.96)
    public var accent = ProjectColor(r: 0.85, g: 0.65, b: 0.20)
    /// Corner radius, fraction of the code side.
    public var cornerRadius: Double = 0.08
    public var titleColor = ProjectColor(r: 0.08, g: 0.08, b: 0.10)
    public var captionColor = ProjectColor(r: 0.25, g: 0.25, b: 0.28)
    /// Text size multiplier (1 = default).
    public var textScale: Double = 1
    /// Picture drawn in the middle of the code (path on this Mac; empty = none).
    public var logoPath: String = ""
    /// Logo side, fraction of the code side (kept ≤ 0.28 so the code still reads).
    public var logoSize: Double = 0.22
    /// In / out motion when shown as an overlay.
    public var animation: OverlayAnimation = .pop
    public var animationDuration: Double = 0.5
    /// Hides the overlay by itself after this many seconds (0 = stays until taken off).
    public var autoHide: Double = 0

    public init() {}

    /// The correction actually used: a logo needs at least Q, better H.
    public var effectiveCorrection: QRCorrection {
        logoPath.isEmpty ? correction : (correction.rank < QRCorrection.high.rank ? .high : correction)
    }

    public var clampedLogoSize: Double { min(max(logoSize, 0.1), 0.28) }

    // Every field optional when decoding, so later additions keep old projects readable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = QRStyle()
        anchor = (try? c.decodeIfPresent(QRAnchor.self, forKey: .anchor)) ?? d.anchor
        margin = (try? c.decodeIfPresent(Double.self, forKey: .margin)) ?? d.margin
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? d.size
        foreground = (try? c.decodeIfPresent(ProjectColor.self, forKey: .foreground)) ?? d.foreground
        background = (try? c.decodeIfPresent(ProjectColor.self, forKey: .background)) ?? d.background
        eyeColor = (try? c.decodeIfPresent(ProjectColor.self, forKey: .eyeColor)) ?? foreground
        moduleShape = (try? c.decodeIfPresent(QRModuleShape.self, forKey: .moduleShape)) ?? d.moduleShape
        correction = (try? c.decodeIfPresent(QRCorrection.self, forKey: .correction)) ?? d.correction
        card = (try? c.decodeIfPresent(QRCardStyle.self, forKey: .card)) ?? d.card
        cardColor = (try? c.decodeIfPresent(ProjectColor.self, forKey: .cardColor)) ?? d.cardColor
        accent = (try? c.decodeIfPresent(ProjectColor.self, forKey: .accent)) ?? d.accent
        cornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? d.cornerRadius
        titleColor = (try? c.decodeIfPresent(ProjectColor.self, forKey: .titleColor)) ?? d.titleColor
        captionColor = (try? c.decodeIfPresent(ProjectColor.self, forKey: .captionColor)) ?? d.captionColor
        textScale = (try? c.decodeIfPresent(Double.self, forKey: .textScale)) ?? d.textScale
        logoPath = (try? c.decodeIfPresent(String.self, forKey: .logoPath)) ?? d.logoPath
        logoSize = (try? c.decodeIfPresent(Double.self, forKey: .logoSize)) ?? d.logoSize
        animation = (try? c.decodeIfPresent(OverlayAnimation.self, forKey: .animation)) ?? d.animation
        animationDuration = (try? c.decodeIfPresent(Double.self, forKey: .animationDuration)) ?? d.animationDuration
        autoHide = (try? c.decodeIfPresent(Double.self, forKey: .autoHide)) ?? d.autoHide
    }
}

/// A QR input: its items (presets), the one on air and the shared style.
public struct QRDesign: Codable, Equatable, Sendable {
    public var items: [QRItem]
    public var selected: Int
    public var style: QRStyle

    public init(items: [QRItem] = [QRItem()], selected: Int = 0, style: QRStyle = QRStyle()) {
        self.items = items.isEmpty ? [QRItem()] : items
        self.selected = selected; self.style = style
    }

    public var current: QRItem { items[min(max(selected, 0), items.count - 1)] }

    /// Next / previous item, wrapping around.
    public mutating func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = ((selected + delta) % items.count + items.count) % items.count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = (try? c.decodeIfPresent([QRItem].self, forKey: .items)) ?? []
        items = list.isEmpty ? [QRItem()] : list
        selected = min(max((try? c.decodeIfPresent(Int.self, forKey: .selected)) ?? 0, 0), items.count - 1)
        style = (try? c.decodeIfPresent(QRStyle.self, forKey: .style)) ?? QRStyle()
    }

    /// Ready-made starting points offered when adding a QR input.
    public static func template(_ name: String) -> QRDesign {
        var d = QRDesign()
        switch name {
        case "angpao":
            var a = QRItem(name: "Angpao", kind: .payment, title: "Amplop Digital",
                           caption: "Scan QRIS untuk mengirim hadiah\nTerima kasih atas doa & restunya")
            a.text = ""
            d.items = [a]
            d.style.accent = ProjectColor(r: 0.80, g: 0.62, b: 0.25)
            d.style.card = .border
            d.style.titleColor = ProjectColor(r: 0.55, g: 0.40, b: 0.12)
            d.style.anchor = .right
        case "donation":
            d.items = [QRItem(name: "Donasi", kind: .payment, title: "Donasi", caption: "Scan untuk berdonasi")]
            d.style.card = .glow
            d.style.accent = ProjectColor(r: 0.15, g: 0.65, b: 0.40)
        case "seminar":
            d.items = [QRItem(name: "Materi", kind: .url, text: "", title: "Materi Seminar", caption: "Scan untuk mengunduh materi")]
            d.style.accent = ProjectColor(r: 0.15, g: 0.45, b: 0.85)
            d.style.card = .border
            d.style.anchor = .bottomRight
        case "wifi":
            var w = QRItem(name: "Wi-Fi", kind: .wifi, title: "Wi-Fi", caption: "")
            w.ssid = ""
            d.items = [w]
        default:
            break
        }
        return d
    }

    public static let templates = ["blank", "angpao", "donation", "seminar", "wifi"]
}

/// Card geometry in pixels (y down), shared by the renderer and the tests.
public struct QRCardLayout: Equatable, Sendable {
    public var card: QRRect
    public var code: QRRect
    public var titleHeight: Double
    public var captionHeight: Double
    public var padding: Double

    /// `titleLines` / `captionLines`: number of text lines (0 = none).
    public static func layout(_ s: QRStyle, width W: Double, height H: Double, titleLines: Int, captionLines: Int) -> QRCardLayout {
        let side = max(16, min(max(s.size, 0.08), 0.9) * H)
        let pad = s.card == .none ? side * 0.04 : side * 0.08
        let titleFont = side * 0.115 * s.textScale
        let captionFont = side * 0.07 * s.textScale
        let th = titleLines > 0 ? titleFont * 1.25 * Double(titleLines) + pad * 0.5 : 0
        let ch = captionLines > 0 ? captionFont * 1.3 * Double(captionLines) + pad * 0.5 : 0
        let cw = side + pad * 2
        let chh = side + pad * 2 + th + ch
        let m = s.margin * H
        let f = s.anchor.factors
        let x = m + (W - 2 * m - cw) * f.x
        let y = m + (H - 2 * m - chh) * f.y
        let card = QRRect(x: x, y: y, width: cw, height: chh)
        let code = QRRect(x: x + pad, y: y + pad + th, width: side, height: side)
        return QRCardLayout(card: card, code: code, titleHeight: th, captionHeight: ch, padding: pad)
    }

    public static func titleFont(_ s: QRStyle, height H: Double) -> Double { max(16, min(max(s.size, 0.08), 0.9) * H) * 0.115 * s.textScale }
    public static func captionFont(_ s: QRStyle, height H: Double) -> Double { max(16, min(max(s.size, 0.08), 0.9) * H) * 0.07 * s.textScale }
}

public struct QRRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// A QR module grid (true = dark), read from the generator's bitmap.
public struct QRMatrix: Equatable, Sendable {
    public let size: Int
    public var cells: [Bool]
    public init(size: Int, cells: [Bool]) { self.size = size; self.cells = cells }
    public subscript(x: Int, y: Int) -> Bool { x >= 0 && y >= 0 && x < size && y < size && cells[y * size + x] }

    /// True for modules of the three 7×7 corner squares (drawn separately as "eyes").
    public func isFinder(_ x: Int, _ y: Int) -> Bool {
        (x < 7 && y < 7) || (x >= size - 7 && y < 7) || (x < 7 && y >= size - 7)
    }

    /// Crops a bitmap (row-major, y down, dark = true) to its dark bounding box: the generator
    /// adds a quiet zone we draw ourselves.
    public static func trimmed(width: Int, height: Int, dark: [Bool]) -> QRMatrix? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where dark[y * width + x] {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        let n = max(maxX - minX, maxY - minY) + 1
        var cells = [Bool](repeating: false, count: n * n)
        for y in 0..<n { for x in 0..<n {
            let sx = minX + x, sy = minY + y
            if sx < width, sy < height { cells[y * n + x] = dark[sy * width + sx] }
        } }
        return QRMatrix(size: n, cells: cells)
    }
}
