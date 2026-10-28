#if os(macOS)
import AppKit
import CoreText
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Fonts LiveCore installs for imported titles (0.40.0): kept in Application Support/LiveCore
/// Studio/Fonts and registered for this app only (no admin rights, nothing changes system-wide).
public enum FontInstaller {
    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveCore Studio/Fonts", isDirectory: true)
    }

    /// Registers every font saved earlier; call once at launch.
    public static func registerAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        register(files.filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) })
    }

    static func register(_ urls: [URL]) {
        for u in urls { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
    }

    public static func isInstalled(_ family: String) -> Bool {
        let f = family.lowercased()
        return NSFontManager.shared.availableFontFamilies.contains { $0.lowercased() == f } || NSFont(name: family, size: 12) != nil
    }

    /// Font families a template uses that this Mac does not have.
    public static func missing(in t: GTTemplate) -> [String] {
        var seen: [String] = []
        for e in t.elements where e.kind == .text && !seen.contains(e.fontFamily) && !isInstalled(e.fontFamily) {
            seen.append(e.fontFamily)
        }
        return seen
    }

    /// Installs the fonts in the picked files and folders (folders are searched, sub-folders too).
    /// Fonts this Mac already has are skipped. Returns the font names installed and skipped.
    public static func installFiles(_ picked: [URL]) -> (installed: [String], skipped: [String]) {
        let exts: Set<String> = ["ttf", "otf", "ttc"]
        var files: [URL] = []
        for u in picked {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while files.count < 5000, let f = e?.nextObject() as? URL {
                    if exts.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else if exts.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        var installed: [String] = [], skipped: [String] = []
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in files {
            let descs = (CTFontManagerCreateFontDescriptorsFromURL(f as CFURL) as? [CTFontDescriptor]) ?? []
            let names = descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            guard !names.isEmpty else { continue }   // not a font CoreText can read
            let label = descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String }.first
                ?? names[0]
            if names.allSatisfy({ NSFont(name: $0, size: 12) != nil }) {
                skipped.append(label)
                continue
            }
            let dest = folder.appendingPathComponent(f.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: f, to: dest)
                register([dest])
                installed.append(label)
            } catch { continue }
        }
        return (installed, skipped)
    }

    /// Downloads each family from Google Fonts. Returns the families installed and those not found.
    public static func download(_ families: [String]) async -> (installed: [String], notFound: [String], failed: [String]) {
        var ok: [String] = [], nf: [String] = [], bad: [String] = []
        for f in families {
            if isInstalled(f) { continue }   // installed meanwhile (e.g. from a folder)
            switch await GoogleFonts.download(family: f, into: folder) {
            case let .installed(urls): register(urls); ok.append(f)
            case .notOnGoogleFonts: nf.append(f)
            case .failed: bad.append(f)
            }
        }
        return (ok, nf, bad)
    }
}

extension AppModel {
    /// Asks whether to download the fonts a GT title needs; nothing happens without a yes.
    func offerFontDownload(_ families: [String]) {
        guard !families.isEmpty else { return }
        let a = NSAlert()
        a.messageText = L10n.t("gt.fonts_missing_title")
        a.informativeText = L10n.f("gt.fonts_missing_body", families.joined(separator: ", "))
        a.addButton(withTitle: L10n.t("gt.fonts_download"))
        a.addButton(withTitle: L10n.t("gt.fonts_file"))
        a.addButton(withTitle: L10n.t("gt.fonts_skip"))
        switch a.runModal() {
        case .alertFirstButtonReturn: downloadFonts(families)
        case .alertSecondButtonReturn: installFontsFromPicker()
        default: break
        }
    }

    /// A folder of fonts (searched with its sub-folders) or single font files; fonts already on
    /// this Mac are skipped.
    func installFontsFromPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = L10n.t("gt.fonts_pick_message")
        panel.prompt = L10n.t("gt.fonts_install")
        panel.allowedContentTypes = [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf"),
                                     UTType(filenameExtension: "ttc"), .folder].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        let r = FontInstaller.installFiles(panel.urls)
        refreshGTTitles()
        report(L10n.f("gt.fonts_folder_result", "\(r.installed.count)", "\(r.skipped.count)"))
    }

    func downloadFonts(_ families: [String], done: (() -> Void)? = nil) {
        Task { @MainActor in
            let r = await FontInstaller.download(families)
            refreshGTTitles()
            var lines: [String] = []
            if !r.installed.isEmpty { lines.append(L10n.f("gt.fonts_installed", r.installed.joined(separator: ", "))) }
            if !r.notFound.isEmpty { lines.append(L10n.f("gt.fonts_not_found", r.notFound.joined(separator: ", "))) }
            if !r.failed.isEmpty { lines.append(L10n.f("gt.fonts_failed", r.failed.joined(separator: ", "))) }
            report(lines.joined(separator: " "))
            done?()
        }
    }

    func refreshGTTitles() {
        for i in inputs where i.kind == .gtTitle { gtTitleSource(i.id)?.refresh() }
        objectWillChange.send()
    }
}
#endif
