import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import LiveCoreCore

/// Reads a vMix GT title template (.gtzip): `document.xml` for the layout and storyboard,
/// `resources.xml` to find the pictures, which are stored in the archive under GUID names.
/// Layers are flattened: every element gets its absolute box in template pixels and the layer
/// box as its clip. Supported elements: Rectangle, Ellipse, TextBlock, Text3D (drawn flat), Image.
public enum GTReader {
    public enum ReadError: Error, CustomStringConvertible {
        case notGT
        case unzipFailed(String)
        public var description: String {
            switch self {
            case .notGT: return "Not a vMix GT title (.gtzip without document.xml)."
            case let .unzipFailed(m): return "Could not open the .gtzip file: \(m)"
            }
        }
    }

    public static func template(at url: URL) throws -> GTTemplate {
        let doc: Data?
        do { doc = try XLSXReader.entry(url, "document.xml") } catch XLSXReader.ReadError.notXLSX { throw ReadError.notGT }
        guard let doc else { throw ReadError.notGT }
        let map = (try? XLSXReader.entry(url, "resources.xml")).flatMap { $0 }.map(resourceMap) ?? [:]
        return parse(document: doc) { source in
            guard let guid = map[normalize(source)] else { return nil }
            return (try? XLSXReader.entry(url, guid)) ?? nil
        }
    }

    static func normalize(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\").lowercased() }

    /// filename → GUID entry name, from resources.xml.
    static func resourceMap(_ data: Data) -> [String: String] {
        let d = ResourceDelegate()
        let p = XMLParser(data: utf8(data))
        p.delegate = d
        p.parse()
        return d.map
    }

    /// GT saves UTF-8 bytes under an `encoding="utf-16"` declaration (and sometimes real UTF-16);
    /// both become plain UTF-8 for XMLParser.
    static func utf8(_ data: Data) -> Data {
        var text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else if data.count > 1, data[data.startIndex] == 0x3C, data[data.startIndex + 1] == 0 {
            text = String(data: data, encoding: .utf16LittleEndian) ?? ""
        } else {
            text = String(decoding: data, as: UTF8.self)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if let r = text.range(of: #"encoding="[^"]*""#, options: .regularExpression),
           r.lowerBound < text.index(text.startIndex, offsetBy: min(100, text.count)) {
            text.replaceSubrange(r, with: #"encoding="utf-8""#)
        }
        return Data(text.utf8)
    }

    public static func parse(document: Data, resource: (String) -> Data? = { _ in nil }) -> GTTemplate {
        let d = DocumentDelegate()
        let p = XMLParser(data: utf8(document))
        p.delegate = d
        p.parse()
        var t = d.template
        for i in t.elements.indices where t.elements[i].kind == .image {
            if let src = d.imageSources[i] { t.elements[i].imageData = resource(src) }
        }
        return t
    }

    static func numbers(_ s: String?) -> [Double] {
        (s ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

private final class ResourceDelegate: NSObject, XMLParserDelegate {
    var map: [String: String] = [:]
    private var file: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        if name == "resource" { file = a["filename"] }
        if name == "source", let f = file, let g = a["guid"] { map[GTReader.normalize(f)] = g }
    }
}

private final class DocumentDelegate: NSObject, XMLParserDelegate {
    var template = GTTemplate(width: 1920, height: 1080)
    var imageSources: [Int: String] = [:]

    /// Maps a composition's own pixels to template pixels.
    private struct Space { var ox = 0.0, oy = 0.0, sx = 1.0, sy = 1.0, clip: (x: Double, y: Double, width: Double, height: Double)? }
    private var spaces: [Space] = []
    private var compositionIsSpace: [Bool] = []
    /// The layer whose inner composition comes next: its box in the parent's pixels.
    private var pendingLayer: (x: Double, y: Double, w: Double, h: Double)?
    private var current: Int?           // index in template.elements
    private var brushTarget = ""        // "Fill" or "Stroke"
    private var inAnimations = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        switch name {
        case "Composition":
            let w = Double(a["Width"] ?? "") ?? 0, h = Double(a["Height"] ?? "") ?? 0
            if spaces.isEmpty {
                if w > 0, h > 0 { template.width = w; template.height = h }
                spaces.append(Space()); compositionIsSpace.append(true)
            } else if let l = pendingLayer {
                let parent = spaces.last!
                var s = Space()
                s.ox = parent.ox + l.x * parent.sx
                s.oy = parent.oy + l.y * parent.sy
                s.sx = parent.sx * (w > 0 ? l.w / w : 1)
                s.sy = parent.sy * (h > 0 ? l.h / h : 1)
                s.clip = (s.ox, s.oy, l.w * parent.sx, l.h * parent.sy)
                spaces.append(s); compositionIsSpace.append(true)
                pendingLayer = nil
            } else {
                compositionIsSpace.append(false)
            }
        case "Layer":
            let loc = GTReader.numbers(a["Location"]), dim = GTReader.numbers(a["Dimensions"])
            pendingLayer = (loc.first ?? 0, loc.count > 1 ? loc[1] : 0, dim.first ?? 0, dim.count > 1 ? dim[1] : 0)
        case "Rectangle", "Ellipse", "TextBlock", "Text3D", "Image":
            guard !inAnimations else { break }
            let kind: GTElement.Kind = name == "Rectangle" ? .rectangle : name == "Ellipse" ? .ellipse
                : name == "Image" ? .image : .text
            var e = GTElement(kind: kind, name: a["Name"] ?? name)
            let s = spaces.last ?? Space()
            let loc = GTReader.numbers(a["Location"]), dim = GTReader.numbers(a["Dimensions"])
            e.x = s.ox + (loc.first ?? 0) * s.sx
            e.y = s.oy + (loc.count > 1 ? loc[1] : 0) * s.sy
            e.width = (dim.first ?? 0) * s.sx
            e.height = (dim.count > 1 ? dim[1] : 0) * s.sy
            e.clip = s.clip
            e.cornerRadius = (GTReader.numbers(a["Radius"]).first ?? 0) * min(s.sx, s.sy)
            e.strokeThickness = (Double(a["StrokeThickness"] ?? "") ?? 0) * min(s.sx, s.sy)
            if kind == .text {
                e.text = a["Text"] ?? ""
                e.fontFamily = a["FontFamily"] ?? "Arial"
                e.fontSize = (Double(a["FontSize"] ?? "") ?? 30) * s.sy
                e.bold = (a["FontWeight"] ?? "").lowercased().contains("bold")
                e.italic = (a["FontStyle"] ?? "").lowercased() == "italic"
                e.alignment = a["TextAlign"] ?? "Left"
                e.verticalAlignment = a["VerticalAlign"] ?? "Top"
                e.fill = GTBrush(color: .white)
            }
            template.elements.append(e)
            current = template.elements.count - 1
        case "Effect":
            guard let i = current else { break }
            let v = GTReader.numbers(a["Angle"] ?? a["Offset"])
            switch a["Type"] ?? "" {
            case "Skew": template.elements[i].skewX = v.first ?? 0
            case "Shadow": template.elements[i].shadow = (v.first ?? 4, v.count > 1 ? v[1] : 4)
            default: break
            }
        case _ where name.hasSuffix(".Fill"): brushTarget = "Fill"
        case _ where name.hasSuffix(".Stroke"): brushTarget = "Stroke"
        case "Brush":
            guard let i = current else { break }
            let color = GTColor(hex: a["Color"] ?? "") ?? .clear
            if brushTarget == "Stroke" {
                template.elements[i].stroke = color
            } else {
                var b = GTBrush(color: color)
                switch a["Type"] ?? "" {
                case "LinearGradient": b.kind = .linear
                case "RadialGradient": b.kind = .radial
                default: break
                }
                let sp = GTReader.numbers(a["StartPoint"]), ep = GTReader.numbers(a["EndPoint"])
                if sp.count == 2 { b.start = (sp[0], sp[1]) } else { b.start = (0, 0) }
                if ep.count == 2 { b.end = (ep[0], ep[1]) }
                template.elements[i].fill = b
            }
        case "GradientStop":
            guard let i = current, brushTarget == "Fill" else { break }
            template.elements[i].fill.stops.append((Double(a["Position"] ?? "") ?? 0, GTColor(hex: a["Color"] ?? "") ?? .clear))
        case "Bitmap":
            if let i = current, let src = a["Source"] { imageSources[i] = src }
        case "Storyboard.Animations":
            inAnimations = true
        default:
            if inAnimations, let obj = a["Object"] {
                template.animations.append(GTAnimation(type: name, object: obj, delay: Double(a["Delay"] ?? "") ?? 0,
                                                       duration: Double(a["Duration"] ?? "") ?? 0.5, direction: a["Direction"]))
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "Composition":
            if compositionIsSpace.popLast() == true, spaces.count > 1 { spaces.removeLast() }
        case "Rectangle", "Ellipse", "TextBlock", "Text3D", "Image": current = nil
        case _ where name.hasSuffix(".Fill") || name.hasSuffix(".Stroke"): brushTarget = ""
        case "Storyboard.Animations": inAnimations = false
        default: break
        }
    }
}
