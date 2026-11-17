import Foundation
import LiveCoreCore

/// Reads an unpacked .pptx folder into a `PPTXDeck` (see PPTXModel.swift for what is covered).
public final class PPTXParser {
    private let root: URL
    private var parts: [String: Part] = [:]
    private var defaultText: XMLTree?

    public init(directory: URL) { root = directory }

    /// Unpacks `pptx` into a temporary folder, reads it and hands the deck to `use` while the
    /// picture files still exist.
    public static func withDeck<T>(_ pptx: URL, _ use: (PPTXDeck) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("livecore-pptx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Unzip.extract(pptx, to: dir)
        return try use(PPTXParser(directory: dir).deck())
    }

    public func deck() throws -> PPTXDeck {
        guard let pres = part("ppt/presentation.xml") else { throw Unzip.Failure(description: "Not a PowerPoint .pptx file") }
        var deck = PPTXDeck()
        if let size = pres.xml.child("sldSz"), let cx = size.double("cx"), let cy = size.double("cy"), cx > 0, cy > 0 {
            deck.width = cx / Self.emu; deck.height = cy / Self.emu
        }
        defaultText = pres.xml.child("defaultTextStyle")
        let ids = pres.xml.child("sldIdLst")?.children("sldId").compactMap { $0["r:id"] } ?? []
        deck.slides = ids.compactMap { pres.rels[$0] }.compactMap(part).filter { $0.xml["show"] != "0" }.map(slide)
        guard !deck.slides.isEmpty else { throw Unzip.Failure(description: "The presentation has no slides") }
        return deck
    }

    static let emu = 12700.0

    // MARK: Parts

    final class Part {
        let path: String
        let xml: XMLTree
        /// Relationship id → part path inside the package.
        let rels: [String: String]
        /// Relationship id → relationship type URI.
        let types: [String: String]
        init(path: String, xml: XMLTree, rels: [String: String], types: [String: String]) {
            self.path = path; self.xml = xml; self.rels = rels; self.types = types
        }
    }

    private func part(_ path: String) -> Part? {
        if let p = parts[path] { return p }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)), let xml = XMLTree.parse(data) else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        let relsURL = root.appendingPathComponent(dir).appendingPathComponent("_rels/\((path as NSString).lastPathComponent).rels")
        var rels: [String: String] = [:]
        var types: [String: String] = [:]
        if let d = try? Data(contentsOf: relsURL), let r = XMLTree.parse(d) {
            for e in r.children("Relationship") where e["TargetMode"] != "External" {
                guard let id = e["Id"], let target = e["Target"] else { continue }
                rels[id] = String(ProjectPaths.resolve(target, againstDirectory: "/" + dir).dropFirst())
                types[id] = e["Type"]
            }
        }
        let p = Part(path: path, xml: xml, rels: rels, types: types)
        parts[path] = p
        return p
    }

    private func related(_ p: Part, _ type: String) -> Part? {
        p.types.first { $0.value.hasSuffix("/" + type) }.flatMap { p.rels[$0.key] }.flatMap(part)
    }

    private func file(_ p: Part, _ rid: String?) -> String? {
        rid.flatMap { p.rels[$0] }.map { root.appendingPathComponent($0).path }
    }

    // MARK: Slide

    /// Everything a slide inherits: its layout, master, theme colours and fonts.
    struct Context {
        var layout: Part?, master: Part?
        var colors: [String: PPTXColor] = [:]
        var majorFont: String?, minorFont: String?
        /// Theme colour behind each `p:clrMap` name (bg1 → lt1…).
        var map: [String: String] = [:]
    }

    private func slide(_ s: Part) -> PPTXSlide {
        var ctx = Context()
        ctx.layout = related(s, "slideLayout")
        ctx.master = ctx.layout.flatMap { related($0, "slideMaster") }
        if let theme = ctx.master.flatMap({ related($0, "theme") })?.xml.find("themeElements") {
            for c in theme.child("clrScheme")?.children ?? [] {
                if let e = c.children.first { ctx.colors[c.name] = rawColor(e) }
            }
            ctx.majorFont = theme.at("fontScheme", "majorFont", "latin")?["typeface"]
            ctx.minorFont = theme.at("fontScheme", "minorFont", "latin")?["typeface"]
        }
        ctx.map = ctx.master?.xml.child("clrMap")?.attributes ?? [:]

        var out = PPTXSlide()
        // Background: the slide's own, else the layout's, else the master's.
        for p in [s, ctx.layout, ctx.master].compactMap({ $0 }) {
            guard let bg = p.xml.at("cSld", "bg") else { continue }
            if let pr = bg.child("bgPr") {
                switch fill(pr, p, ctx) {
                case let .color(c)?: out.background = c
                case let .image(f)?: out.backgroundImage = f
                default: continue
                }
            } else if let ref = bg.child("bgRef"), let c = ref.children.first.flatMap({ color($0, ctx) }) {
                out.background = c
            }
            break
        }
        // Master and layout decorations (not their placeholders) go under the slide's own shapes.
        let showMaster = s.xml["showMasterSp"] != "0"
        if showMaster, ctx.layout?.xml["showMasterSp"] != "0", let m = ctx.master { out.shapes += shapes(of: m, ctx, decorationsOnly: true) }
        if showMaster, let l = ctx.layout { out.shapes += shapes(of: l, ctx, decorationsOnly: true) }
        out.shapes += shapes(of: s, ctx, decorationsOnly: false)
        return out
    }

    private func shapes(of p: Part, _ ctx: Context, decorationsOnly: Bool) -> [PPTXShape] {
        guard let tree = p.xml.at("cSld", "spTree") else { return [] }
        return shapes(in: tree, p, ctx, Xform(), decorationsOnly)
    }

    /// Maps a group's child coordinates onto the slide.
    struct Xform {
        var sx = 1.0, sy = 1.0, tx = 0.0, ty = 0.0
        func apply(_ r: PPTXRect) -> PPTXRect {
            PPTXRect(x: r.x * sx + tx, y: r.y * sy + ty, width: r.width * sx, height: r.height * sy)
        }
    }

    private func shapes(in tree: XMLTree, _ p: Part, _ ctx: Context, _ xf: Xform, _ decorationsOnly: Bool) -> [PPTXShape] {
        var out: [PPTXShape] = []
        for el in tree.children {
            // Newer content (equations, ink…) carries a picture fallback.
            let el = el.name == "AlternateContent" ? (el.child("Fallback")?.children.first ?? el) : el
            let ph = el.children.first?.find("ph")
            if decorationsOnly && ph != nil { continue }
            switch el.name {
            case "sp", "cxnSp", "pic":
                if let s = shape(el, ph, p, ctx, xf) { out.append(s) }
            case "grpSp":
                guard let x = el.at("grpSpPr", "xfrm"), let r = rect(x),
                      let ch = x.child("chOff"), let ce = x.child("chExt") else { continue }
                let cw = (ce.double("cx") ?? 0) / Self.emu, chh = (ce.double("cy") ?? 0) / Self.emu
                let sx = cw > 0 ? r.width / cw : 1, sy = chh > 0 ? r.height / chh : 1
                let inner = Xform(sx: sx, sy: sy, tx: r.x - (ch.double("x") ?? 0) / Self.emu * sx,
                                  ty: r.y - (ch.double("y") ?? 0) / Self.emu * sy)
                let composed = Xform(sx: inner.sx * xf.sx, sy: inner.sy * xf.sy,
                                     tx: inner.tx * xf.sx + xf.tx, ty: inner.ty * xf.sy + xf.ty)
                out += shapes(in: el, p, ctx, composed, decorationsOnly)
            case "graphicFrame":
                out += table(el, p, ctx, xf)
            default: break
            }
        }
        return out
    }

    // MARK: Shapes

    private func shape(_ el: XMLTree, _ ph: XMLTree?, _ p: Part, _ ctx: Context, _ xf: Xform) -> PPTXShape? {
        let inherited = ph.map { placeholders($0, p, ctx) } ?? []
        let spPr = el.child("spPr")
        guard let xfrm = spPr?.child("xfrm") ?? inherited.lazy.compactMap({ $0.at("spPr", "xfrm") }).first,
              let frame = rect(xfrm) else { return nil }
        var s = PPTXShape(frame: xf.apply(frame))
        s.rotation = (xfrm.double("rot") ?? 0) / 60000
        s.flipH = xfrm["flipH"] == "1"; s.flipV = xfrm["flipV"] == "1"
        if let g = spPr?.child("prstGeom")?["prst"] {
            s.geometry = PPTXShape.Geometry(rawValue: g)
                ?? (g.hasSuffix("Connector1") || g.hasPrefix("straightConnector") || g.hasPrefix("bentConnector") ? .line : .rect)
        } else if let cust = spPr?.child("custGeom") {
            s.geometry = .custom
            s.path = customPath(cust)
        }
        let style = el.child("style")
        switch spPr.flatMap({ fill($0, p, ctx) }) {
        case let .color(c)?: s.fill = c
        case let .image(f)?: s.image = f
        case .none?: break
        case nil:
            if let r = style?.child("fillRef"), (r.double("idx") ?? 0) > 0 { s.fill = r.children.first.flatMap { color($0, ctx) } }
        }
        if let ln = spPr?.child("ln") {
            if ln.child("noFill") == nil {
                s.line = ln.child("solidFill")?.children.first.flatMap { color($0, ctx) }
                    ?? style?.child("lnRef")?.children.first.flatMap { color($0, ctx) }
            }
            if let w = ln.double("w") { s.lineWidth = w / Self.emu }
        } else if let r = style?.child("lnRef"), (r.double("idx") ?? 0) > 0 {
            s.line = r.children.first.flatMap { color($0, ctx) }
        }
        if s.geometry == .line, s.line == nil { s.line = color(name: "tx1", ctx) }
        if el.name == "pic", let blip = el.child("blipFill") {
            s.image = file(p, blip.child("blip")?["r:embed"])
            if let src = blip.child("srcRect") {
                s.crop = ["l", "t", "r", "b"].map { (src.double($0) ?? 0) / 100_000 }
            }
        }
        if let body = el.child("txBody") {
            let fontColor = style?.child("fontRef")?.children.first.flatMap { color($0, ctx) }
            s.text = text(body, ph: ph, inherited: inherited, base: fontColor, ctx)
        }
        return s
    }

    /// The placeholder this one inherits from in the layout, then in the master.
    private func placeholders(_ ph: XMLTree, _ p: Part, _ ctx: Context) -> [XMLTree] {
        let type = ph["type"] ?? "body", idx = ph["idx"]
        func search(_ part: Part?, byIndex: Bool) -> XMLTree? {
            guard let tree = part?.xml.at("cSld", "spTree") else { return nil }
            let candidates = tree.children.filter { $0.children.first?.find("ph") != nil }
            if byIndex, let idx, let hit = candidates.first(where: { $0.children.first?.find("ph")?["idx"] == idx }) { return hit }
            let generic = type == "ctrTitle" ? "title" : (type == "subTitle" || type == "obj" ? "body" : type)
            return candidates.first { ($0.children.first?.find("ph")?["type"] ?? "body") == type }
                ?? candidates.first { ($0.children.first?.find("ph")?["type"] ?? "body") == generic }
        }
        if p === ctx.master { return [] }
        let fromLayout = p === ctx.layout ? nil : search(ctx.layout, byIndex: true)
        return [fromLayout, search(ctx.master, byIndex: false)].compactMap { $0 }
    }

    private func rect(_ xfrm: XMLTree) -> PPTXRect? {
        guard let off = xfrm.child("off"), let ext = xfrm.child("ext") else { return nil }
        return PPTXRect(x: (off.double("x") ?? 0) / Self.emu, y: (off.double("y") ?? 0) / Self.emu,
                        width: (ext.double("cx") ?? 0) / Self.emu, height: (ext.double("cy") ?? 0) / Self.emu)
    }

    private func customPath(_ cust: XMLTree) -> [PPTXPathCommand] {
        var out: [PPTXPathCommand] = []
        for path in cust.child("pathLst")?.children("path") ?? [] {
            let w = max(path.double("w") ?? 1, 1), h = max(path.double("h") ?? 1, 1)
            func pt(_ e: XMLTree?) -> (Double, Double) { ((e?.double("x") ?? 0) / w, (e?.double("y") ?? 0) / h) }
            for c in path.children {
                let pts = c.children("pt").map(pt)
                switch c.name {
                case "moveTo": if let a = pts.first { out.append(.move(a.0, a.1)) }
                case "lnTo": if let a = pts.first { out.append(.line(a.0, a.1)) }
                case "cubicBezTo" where pts.count == 3:
                    out.append(.cubic(pts[0].0, pts[0].1, pts[1].0, pts[1].1, pts[2].0, pts[2].1))
                case "quadBezTo" where pts.count == 2: out.append(.line(pts[1].0, pts[1].1))
                case "close": out.append(.close)
                default: break
                }
            }
        }
        return out
    }

    /// Tables become one rectangle per cell with its fill, border and text.
    private func table(_ el: XMLTree, _ p: Part, _ ctx: Context, _ xf: Xform) -> [PPTXShape] {
        guard let tbl = el.find("tbl"), let xfrm = el.child("xfrm"), let frame = rect(xfrm) else { return [] }
        let cols = tbl.child("tblGrid")?.children("gridCol").map { ($0.double("w") ?? 0) / Self.emu } ?? []
        var out: [PPTXShape] = []
        var y = frame.y
        for row in tbl.children("tr") {
            let h = (row.double("h") ?? 0) / Self.emu
            var x = frame.x
            for (i, tc) in row.children("tc").enumerated() where i < cols.count {
                let span = max(Int(tc["gridSpan"] ?? "1") ?? 1, 1)
                let w = cols[i..<min(i + span, cols.count)].reduce(0, +)
                defer { x += cols[i] }
                if tc["hMerge"] == "1" || tc["vMerge"] == "1" { continue }
                var cell = PPTXShape(frame: xf.apply(PPTXRect(x: x, y: y, width: w, height: h)))
                if let pr = tc.child("tcPr") {
                    if case let .color(c)? = fill(pr, p, ctx) { cell.fill = c }
                    cell.line = pr.child("lnB")?.child("solidFill")?.children.first.flatMap { color($0, ctx) }
                    cell.lineWidth = (pr.child("lnB")?.double("w") ?? 12700) / Self.emu
                }
                if let body = tc.child("txBody") { cell.text = text(body, ph: nil, inherited: [], base: nil, ctx) }
                out.append(cell)
            }
            y += h
        }
        return out
    }

    // MARK: Fills and colours

    enum Fill { case none, color(PPTXColor), image(String) }

    private func fill(_ pr: XMLTree, _ p: Part, _ ctx: Context) -> Fill? {
        if pr.child("noFill") != nil { return Fill.none }
        if let c = pr.child("solidFill")?.children.first.flatMap({ color($0, ctx) }) { return .color(c) }
        if let gs = pr.child("gradFill")?.child("gsLst")?.children("gs").first?.children.first,
           let c = color(gs, ctx) { return .color(c) }
        if let f = file(p, pr.child("blipFill")?.child("blip")?["r:embed"]) { return .image(f) }
        return nil
    }

    /// srgbClr / schemeClr / sysClr / prstClr with its lumMod, lumOff, shade, tint and alpha.
    func color(_ e: XMLTree, _ ctx: Context) -> PPTXColor? {
        let base: PPTXColor?
        if e.name == "schemeClr" { base = e["val"].flatMap { color(name: $0, ctx) } } else { base = rawColor(e) }
        guard var c = base else { return nil }
        for m in e.children {
            let v = (m.double("val") ?? 100_000) / 100_000
            switch m.name {
            case "alpha": c.a = v
            case "shade": c = PPTXColor(r: c.r * v, g: c.g * v, b: c.b * v, a: c.a)
            case "tint": c = PPTXColor(r: 1 - (1 - c.r) * v, g: 1 - (1 - c.g) * v, b: 1 - (1 - c.b) * v, a: c.a)
            case "lumMod", "lumOff":
                var (h, s, l) = Self.hsl(c)
                l = m.name == "lumMod" ? l * v : l + v
                c = Self.rgb(h, s, min(max(l, 0), 1), c.a)
            default: break
            }
        }
        return c
    }

    func color(name: String, _ ctx: Context) -> PPTXColor? {
        ctx.colors[ctx.map[name] ?? name]
    }

    private func rawColor(_ e: XMLTree) -> PPTXColor? {
        switch e.name {
        case "srgbClr": return e["val"].flatMap(Self.hex)
        case "sysClr": return (e["lastClr"]).flatMap(Self.hex) ?? (e["val"] == "window" ? .white : .black)
        case "prstClr": return ["white": .white, "black": .black, "red": PPTXColor(r: 1, g: 0, b: 0)][e["val"] ?? ""] ?? .black
        default: return nil
        }
    }

    static func hex(_ s: String) -> PPTXColor? {
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return PPTXColor(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    static func hsl(_ c: PPTXColor) -> (Double, Double, Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn, s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h = mx == c.r ? (c.g - c.b) / d + (c.g < c.b ? 6 : 0) : mx == c.g ? (c.b - c.r) / d + 2 : (c.r - c.g) / d + 4
        h /= 6
        return (h, s, l)
    }

    static func rgb(_ h: Double, _ s: Double, _ l: Double, _ a: Double) -> PPTXColor {
        guard s > 0 else { return PPTXColor(r: l, g: l, b: l, a: a) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func f(_ t: Double) -> Double {
            let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
            return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p
        }
        return PPTXColor(r: f(h + 1 / 3), g: f(h), b: f(h - 1 / 3), a: a)
    }

    // MARK: Text

    /// Text properties of one list level; nil fields are taken from the next style down.
    struct Level {
        var size: Double?, bold: Bool?, italic: Bool?, underline: Bool?, color: PPTXColor?, font: String?
        var align: PPTXParagraph.Align?, bullet: String?, marginLeft: Double?, firstLine: Double?
        var lineSpacing: Double?, spaceBefore: Double?

        func over(_ b: Level) -> Level {
            Level(size: size ?? b.size, bold: bold ?? b.bold, italic: italic ?? b.italic, underline: underline ?? b.underline,
                  color: color ?? b.color, font: font ?? b.font, align: align ?? b.align, bullet: bullet ?? b.bullet,
                  marginLeft: marginLeft ?? b.marginLeft, firstLine: firstLine ?? b.firstLine,
                  lineSpacing: lineSpacing ?? b.lineSpacing, spaceBefore: spaceBefore ?? b.spaceBefore)
        }
    }

    /// Reads a paragraph-properties element (pPr / lvlNpPr) and its run defaults.
    private func level(_ pPr: XMLTree?, _ ctx: Context) -> Level {
        guard let pPr else { return Level() }
        var l = runLevel(pPr.child("defRPr"), ctx)
        l.align = pPr["algn"].flatMap(PPTXParagraph.Align.init)
        l.marginLeft = pPr.double("marL").map { $0 / Self.emu }
        l.firstLine = pPr.double("indent").map { $0 / Self.emu }
        if pPr.child("buNone") != nil { l.bullet = "" }
        if let ch = pPr.child("buChar")?["char"] { l.bullet = ch }
        if let n = pPr.child("buAutoNum") { l.bullet = n["type"]?.hasSuffix("ParenR") == true ? "#)" : "#." }
        l.lineSpacing = pPr.at("lnSpc", "spcPct")?.double("val").map { $0 / 100_000 }
        l.spaceBefore = pPr.at("spcBef", "spcPts")?.double("val").map { $0 / 100 }
        return l
    }

    private func runLevel(_ rPr: XMLTree?, _ ctx: Context) -> Level {
        guard let rPr else { return Level() }
        var l = Level()
        l.size = rPr.double("sz").map { $0 / 100 }
        l.bold = rPr["b"].map { $0 == "1" || $0 == "true" }
        l.italic = rPr["i"].map { $0 == "1" || $0 == "true" }
        l.underline = rPr["u"].map { $0 != "none" }
        l.color = rPr.child("solidFill")?.children.first.flatMap { color($0, ctx) }
        l.font = rPr.child("latin")?["typeface"].map { f in
            f == "+mj-lt" ? (ctx.majorFont ?? f) : f == "+mn-lt" ? (ctx.minorFont ?? f) : f
        }
        return l
    }

    private func text(_ body: XMLTree, ph: XMLTree?, inherited: [XMLTree], base: PPTXColor?, _ ctx: Context) -> PPTXText? {
        let type = ph.map { $0["type"] ?? "body" }
        let isTitle = type == "title" || type == "ctrTitle"
        // Style sources from the most specific to the most general.
        let lists = [body.child("lstStyle")] + inherited.map { $0.at("txBody", "lstStyle") }
        let master = ctx.master?.xml.child("txStyles")
        let general = type == nil ? defaultText : (isTitle ? master?.child("titleStyle")
                                                   : ["dt", "ftr", "sldNum"].contains(type!) ? master?.child("otherStyle") : master?.child("bodyStyle"))
        let bodyPrs = [body.child("bodyPr")] + inherited.map { $0.at("txBody", "bodyPr") }

        var t = PPTXText(paragraphs: [])
        if let a = bodyPrs.lazy.compactMap({ $0?["anchor"] }).first { t.anchor = PPTXText.Anchor(rawValue: a) ?? .top }
        for (i, k) in ["lIns", "tIns", "rIns", "bIns"].enumerated() {
            if let v = bodyPrs.lazy.compactMap({ $0?.double(k) }).first { t.insets[i] = v / Self.emu }
        }
        t.wrap = bodyPrs.lazy.compactMap({ $0?["wrap"] }).first != "none"
        let autofit = bodyPrs.lazy.compactMap({ $0?.child("normAutofit") }).first
        t.shrink = autofit != nil
        let scale = (body.child("bodyPr")?.child("normAutofit")?.double("fontScale") ?? 100_000) / 100_000

        let fallback = Level(size: 18, bold: false, italic: false, underline: false,
                             color: base ?? color(name: "tx1", ctx) ?? .black,
                             font: isTitle ? ctx.majorFont : ctx.minorFont, align: .left, bullet: "",
                             marginLeft: 0, firstLine: 0, lineSpacing: nil, spaceBefore: 0)
        var number = 0
        for p in body.children("p") {
            let pPr = p.child("pPr")
            let lvl = Int(pPr?["lvl"] ?? "0") ?? 0
            let key = "lvl\(lvl + 1)pPr"
            var style = level(pPr, ctx)
            for l in lists { style = style.over(level(l?.child(key), ctx)) }
            style = style.over(level(general?.child(key), ctx))
            if base != nil { style = style.over(Level(color: base)) }
            style = style.over(fallback)

            var para = PPTXParagraph()
            para.align = style.align ?? .left
            para.marginLeft = style.marginLeft ?? 0
            para.firstLine = style.firstLine ?? 0
            para.lineSpacing = style.lineSpacing
            para.spaceBefore = style.spaceBefore ?? 0
            for r in p.children where r.name == "r" || r.name == "fld" || r.name == "br" {
                let rs = runLevel(r.child("rPr"), ctx).over(style)
                let text = r.name == "br" ? "\n" : (r.child("t")?.text ?? "")
                para.runs.append(PPTXRun(text: text, size: (rs.size ?? 18) * scale, bold: rs.bold ?? false,
                                         italic: rs.italic ?? false, underline: rs.underline ?? false,
                                         color: rs.color ?? .black, font: rs.font))
            }
            let visible = para.runs.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if let b = style.bullet, !b.isEmpty, visible {
                if b.contains("#") { number += 1; para.bullet = b.replacingOccurrences(of: "#", with: "\(number)") } else { para.bullet = b }
            } else if !(style.bullet ?? "").contains("#") { number = 0 }
            if para.runs.isEmpty {
                // An empty line still takes the height of its font.
                let end = runLevel(p.child("endParaRPr"), ctx).over(style)
                para.runs = [PPTXRun(text: " ", size: (end.size ?? 18) * scale, color: .black)]
            }
            t.paragraphs.append(para)
        }
        return t.paragraphs.contains(where: { $0.runs.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }) ? t : nil
    }
}
