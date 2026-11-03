import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import LiveCoreCore

/// Reads the first worksheet of an Excel .xlsx file into a `CSVTable` (first row = header), for
/// title data sources. Values only: formulas show their last calculated result, formatting is
/// ignored. The archive is opened with the system `unzip`.
public enum XLSXReader {
    public enum ReadError: Error, CustomStringConvertible {
        case notXLSX
        case unzipFailed(String)
        public var description: String {
            switch self {
            case .notXLSX: return "Not an Excel .xlsx workbook (no first worksheet)."
            case let .unzipFailed(m): return "Could not open the .xlsx file: \(m)"
            }
        }
    }

    public static func table(at url: URL) throws -> CSVTable {
        let sheet = try entry(url, firstSheetPath(url))
        guard let sheet else { throw ReadError.notXLSX }
        let strings = try entry(url, "xl/sharedStrings.xml")
        return parse(sharedStrings: strings, sheet: sheet)
    }

    /// The path of the first sheet in workbook order (falls back to sheet1.xml).
    static func firstSheetPath(_ url: URL) throws -> String {
        guard let wb = try entry(url, "xl/workbook.xml"), let rels = try entry(url, "xl/_rels/workbook.xml.rels") else {
            return "xl/worksheets/sheet1.xml"
        }
        let firstID = AttributeCollector.first(in: wb, element: "sheet", attribute: "r:id")
        let targets = AttributeCollector.all(in: rels, element: "Relationship", attributes: ["Id", "Target"])
        guard let id = firstID, let target = targets.first(where: { $0["Id"] == id })?["Target"] else {
            return "xl/worksheets/sheet1.xml"
        }
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        return "xl/" + target
    }

    /// One file from the archive, nil when it is not there.
    static func entry(_ url: URL, _ path: String) throws -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw ReadError.unzipFailed(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // unzip exits 11 when the entry does not exist, 9 when the file is not a zip.
        if p.terminationStatus == 11 { return nil }
        if p.terminationStatus == 9 { throw ReadError.notXLSX }
        guard p.terminationStatus == 0 else { throw ReadError.unzipFailed("unzip exit \(p.terminationStatus)") }
        return data
    }

    /// Builds the table from the sheet XML and the shared-string table.
    public static func parse(sharedStrings: Data?, sheet: Data) -> CSVTable {
        let strings = sharedStrings.map(SharedStringsParser.parse) ?? []
        let cells = SheetParser.parse(sheet)
        guard let maxRow = cells.keys.map(\.row).max() else { return CSVTable(header: [], rows: []) }
        let width = (cells.keys.map(\.col).max() ?? 0) + 1
        var grid: [[String]] = []
        for r in 0...maxRow {
            var line = Array(repeating: "", count: width)
            for c in 0..<width {
                guard let cell = cells[CellRef(row: r, col: c)] else { continue }
                if cell.type == "s", let i = Int(cell.value), strings.indices.contains(i) { line[c] = strings[i] }
                else if cell.type == "b" { line[c] = cell.value == "1" ? "TRUE" : "FALSE" }
                else { line[c] = Self.tidyNumber(cell.value) }
            }
            grid.append(line)
        }
        // Drop empty rows (Excel keeps formatted but empty rows) and trailing empty columns.
        grid = grid.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let header = grid.first else { return CSVTable(header: [], rows: []) }
        let used = (0..<width).filter { c in grid.contains { !$0[c].isEmpty } }.max().map { $0 + 1 } ?? 0
        return CSVTable(header: Array(header.prefix(used)), rows: grid.dropFirst().map { Array($0.prefix(used)) })
    }

    /// "12.0" → "12"; floating noise such as "0.30000000000000004" stays as Excel stored it.
    static func tidyNumber(_ s: String) -> String {
        if s.hasSuffix(".0"), Double(s) != nil { return String(s.dropLast(2)) }
        return s
    }

    struct CellRef: Hashable { var row: Int; var col: Int }

    /// "B12" → row 11, column 1.
    static func cellRef(_ r: String) -> CellRef? {
        var col = 0, digits = ""
        for ch in r {
            if let a = ch.asciiValue, a >= 65, a <= 90 { col = col * 26 + Int(a - 64) }
            else if ch.isNumber { digits.append(ch) }
        }
        guard col > 0, let row = Int(digits), row > 0 else { return nil }
        return CellRef(row: row - 1, col: col - 1)
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current: String?
    private var inText = false
    private var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let d = SharedStringsParser()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        // Phonetic hints (rPh) are not part of the visible text.
        if name == "rPh" { inPhonetic = true }
        if name == "t" && current != nil && !inPhonetic { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current? += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "rPh" { inPhonetic = false }
        if name == "si" { strings.append(current ?? ""); current = nil }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    struct Cell { var type: String; var value: String }
    var cells: [XLSXReader.CellRef: Cell] = [:]
    private var ref: XLSXReader.CellRef?
    private var type = ""
    private var value = ""
    private var reading = false
    private var nextCol = 0
    private var row = 0

    static func parse(_ data: Data) -> [XLSXReader.CellRef: Cell] {
        let d = SheetParser()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.cells
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "row":
            row = attributes["r"].flatMap(Int.init).map { $0 - 1 } ?? row
            nextCol = 0
        case "c":
            // Cells without "r" follow the previous one.
            ref = attributes["r"].flatMap(XLSXReader.cellRef) ?? XLSXReader.CellRef(row: row, col: nextCol)
            type = attributes["t"] ?? "n"
            value = ""
        case "v", "t":
            if ref != nil { reading = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if reading { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": reading = false
        case "c":
            if let r = ref {
                cells[r] = Cell(type: type, value: value)
                nextCol = r.col + 1
                row = r.row
            }
            ref = nil
        case "row": row += 1
        default: break
        }
    }
}

/// Small helper to read attributes of one element type (workbook sheet order, relationships).
private final class AttributeCollector: NSObject, XMLParserDelegate {
    let element: String
    var found: [[String: String]] = []
    init(element: String) { self.element = element }

    static func all(in data: Data, element: String, attributes: [String]) -> [[String: String]] {
        let d = AttributeCollector(element: element)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.found.map { a in a.filter { attributes.contains($0.key) } }
    }

    static func first(in data: Data, element: String, attribute: String) -> String? {
        all(in: data, element: element, attributes: [attribute]).first?[attribute]
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == element { found.append(attributes) }
    }
}
