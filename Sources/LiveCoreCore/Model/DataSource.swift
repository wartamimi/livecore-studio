/// Title data sources (vMix "Data Sources"): a CSV file, a CSV link or a Google Sheets link whose
/// rows fill a title's text. The operator steps through rows (next speaker, next guest) and the
/// title on Preview/Program changes with them.
public struct TitleDataSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case file, url }
    public var kind: Kind
    /// Absolute path (file) or http(s) link (url). Google Sheets links are turned into their CSV export.
    public var location: String
    /// Column shown as the title / subtitle / tag (header name; nil = none).
    public var titleColumn: String?
    public var subtitleColumn: String?
    /// Selected row (0 = first row after the header).
    public var row: Int
    /// Reload a link every N seconds (nil / 0 = only when asked).
    public var refreshSeconds: Double?

    public init(kind: Kind, location: String, titleColumn: String? = nil, subtitleColumn: String? = nil, row: Int = 0,
                refreshSeconds: Double? = nil) {
        self.kind = kind; self.location = location; self.titleColumn = titleColumn; self.subtitleColumn = subtitleColumn
        self.row = row; self.refreshSeconds = refreshSeconds
    }

    /// The text for the selected row, or nil when the table has no such row.
    public func text(in table: CSVTable) -> (title: String, subtitle: String)? {
        guard table.rows.indices.contains(row) else { return nil }
        return (titleColumn.flatMap { table.value(row: row, column: $0) } ?? "",
                subtitleColumn.flatMap { table.value(row: row, column: $0) } ?? "")
    }

    /// Fills in the first two columns when none were chosen.
    public mutating func pickDefaultColumns(_ table: CSVTable) {
        if titleColumn == nil || !table.header.contains(titleColumn!) { titleColumn = table.header.first }
        if subtitleColumn == nil || !table.header.contains(subtitleColumn!) { subtitleColumn = table.header.dropFirst().first }
        row = SlideMath.clamp(row, count: table.rows.count)
    }

    public static let refreshRange: ClosedRange<Double> = 5 ... 3_600
    public var refreshInterval: Double? {
        guard let r = refreshSeconds, r.isFinite, r > 0 else { return nil }
        return min(max(r, Self.refreshRange.lowerBound), Self.refreshRange.upperBound)
    }

    /// The address to download for a link: Google Sheets edit/view links → CSV export of that sheet tab.
    public static func downloadURL(for link: String) -> String {
        let s = link.trimmingWhitespace
        guard s.hasPrefix("https://docs.google.com/spreadsheets/d/") else { return s }
        let rest = s.dropFirst("https://docs.google.com/spreadsheets/d/".count)
        let id = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !id.isEmpty, !rest.hasPrefix("e/") else { return s }   // "Publish to web" links (/d/e/…) already serve CSV with output=csv
        var gid = "0"
        if let r = s.firstRange(of: "gid=") {
            let digits = s[r.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { gid = String(digits) }
        }
        return "https://docs.google.com/spreadsheets/d/\(id)/export?format=csv&gid=\(gid)"
    }
}

/// A parsed CSV table (RFC 4180: quoted fields, doubled quotes, line breaks inside quotes; comma,
/// semicolon or tab separator detected from the header line). The first row is the header.
public struct CSVTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[String]]

    public init(header: [String], rows: [[String]]) { self.header = header; self.rows = rows }

    public func value(row: Int, column: String) -> String? {
        guard rows.indices.contains(row), let c = header.firstIndex(of: column) else { return nil }
        let r = rows[row]
        return c < r.count ? r[c] : ""
    }

    /// Short label for a row in pickers ("1 · Ana Lestari").
    public func label(row: Int) -> String {
        guard rows.indices.contains(row) else { return "" }
        let first = rows[row].first { !$0.isEmpty } ?? ""
        return "\(row + 1) · \(first)"
    }

    public static func parse(_ text: String) -> CSVTable {
        var body = Substring(text)
        if body.hasPrefix("\u{FEFF}") { body = body.dropFirst() }   // Excel's UTF-8 BOM
        let firstLine = body.prefix { $0 != "\n" && $0 != "\r" }
        let separators: [Character] = [",", ";", "\t"]
        let sep = separators.max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var chars = body.makeIterator()
        var pending: Character? = nil
        func endRecord() {
            record.append(field); field = ""
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = chars.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: inQuotes = true
            case sep: record.append(field); field = ""
            case "\r\n", "\n", "\r": endRecord()
            default: field.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        guard let head = records.first else { return CSVTable(header: [], rows: []) }
        let header = head.enumerated().map { i, h -> String in
            let t = h.trimmingWhitespace
            return t.isEmpty ? "Column \(i + 1)" : t
        }
        return CSVTable(header: header, rows: Array(records.dropFirst()))
    }
}

extension StringProtocol {
    var trimmingWhitespace: String {
        let s = self.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        var end = s.endIndex
        while end > s.startIndex {
            let p = s.index(before: end)
            if s[p] == " " || s[p] == "\t" || s[p] == "\n" || s[p] == "\r" { end = p } else { break }
        }
        return String(s[s.startIndex..<end])
    }
}
