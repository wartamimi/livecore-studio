#if os(macOS)
import CoreText
import Foundation
import LiveCoreCore

/// Reads and writes `.lctitle` template files (0.64.0) and keeps the "My Templates" folder
/// (Application Support/LiveCore Studio/Templates). Zipping uses macOS's own /usr/bin/zip and
/// /usr/bin/unzip, like the spreadsheet import.
public enum TitleTemplateLibrary {
    public enum FileError: Error, CustomStringConvertible {
        case tool(String), notTemplate, unreadable(String)
        public var description: String {
            switch self {
            case let .tool(s): return "zip failed: \(s)"
            case .notTemplate: return "This file is not a LiveCore title template (.lctitle)."
            case let .unreadable(s): return "The template could not be read: \(s)"
            }
        }
    }

    public static var folder: URL {
        AppSupport.folder("Templates")
    }

    /// Templates in My Templates, by name.
    public static func list() -> [(url: URL, package: TitlePackage)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == TitlePackage.fileExtension }
            .compactMap { u in (try? read(u)).map { (u, $0) } }
            .sorted { $0.package.name.localizedStandardCompare($1.package.name) == .orderedAscending }
    }

    // MARK: Write

    /// Writes `package` to `url`, with the font files of its families that are not part of macOS.
    public static func write(_ p0: TitlePackage, to url: URL) throws {
        var p = p0
        p.app = "LiveCore Studio " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lctitle-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let fontsDir = tmp.appendingPathComponent(TitlePackage.fontsFolder, isDirectory: true)
        try fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        var names: [String] = []
        for f in p.fontFamilies.flatMap(fontFiles(family:)) where !names.contains(f.lastPathComponent) {
            if (try? fm.copyItem(at: f, to: fontsDir.appendingPathComponent(f.lastPathComponent))) != nil {
                names.append(f.lastPathComponent)
            }
        }
        p.fonts = names
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: tmp.appendingPathComponent(TitlePackage.jsonName))
        let out = tmp.appendingPathComponent("out.zip")
        try run("/usr/bin/zip", ["-r", "-X", "-q", out.path, TitlePackage.jsonName, "assets"], in: tmp)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: out, to: url)
    }

    /// Saves into My Templates (a template of the same name is replaced). Returns the file.
    @discardableResult
    public static func save(_ p: TitlePackage) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(TitlePackage.fileName(for: p.name))
        try write(p, to: url)
        return url
    }

    /// Font files for a family that may be shared: user and app-installed fonts, never the
    /// fonts that come with macOS (their licence does not allow it, and every Mac has them).
    static func fontFiles(family: String) -> [URL] {
        let attrs = [kCTFontFamilyNameAttribute: family] as CFDictionary
        let desc = CTFontDescriptorCreateWithAttributes(attrs)
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(desc, nil) as? [CTFontDescriptor]) ?? []
        var out: [URL] = []
        for m in matches {
            guard let u = CTFontDescriptorCopyAttribute(m, kCTFontURLAttribute) as? URL else { continue }
            let path = u.path
            if path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") || path.contains("/AssetsV2/") { continue }
            if !out.contains(u) { out.append(u) }
        }
        return Array(out.prefix(12))
    }

    // MARK: Read

    /// Reads a template; `installFonts` receives its bundled font files (still in a temporary
    /// folder, so install / copy them before returning).
    public static func read(_ url: URL, installFonts: (([URL]) -> Void)? = nil) throws -> TitlePackage {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lctitle-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do { try run("/usr/bin/unzip", ["-q", "-o", url.path, TitlePackage.jsonName, TitlePackage.fontsFolder + "/*", "-d", tmp.path], in: tmp, okCodes: [0, 11]) }
        catch { throw FileError.notTemplate }
        guard let data = try? Data(contentsOf: tmp.appendingPathComponent(TitlePackage.jsonName)) else { throw FileError.notTemplate }
        let p: TitlePackage
        do { p = try JSONDecoder().decode(TitlePackage.self, from: data) } catch { throw FileError.unreadable(error.localizedDescription) }
        guard p.isValid else { throw FileError.notTemplate }
        if let installFonts, !p.fonts.isEmpty {
            let dir = tmp.appendingPathComponent(TitlePackage.fontsFolder, isDirectory: true)
            let files = p.fonts.map { dir.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
            if !files.isEmpty { installFonts(files) }
        }
        return p
    }

    private static func run(_ tool: String, _ args: [String], in dir: URL, okCodes: Set<Int32> = [0]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw FileError.tool(error.localizedDescription) }
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard okCodes.contains(p.terminationStatus) else { throw FileError.tool("\(tool) exit \(p.terminationStatus) \(msg)") }
    }
}
#endif
