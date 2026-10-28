#if os(macOS)
import AppKit
import CoreText
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

    /// Copies a font file the user picked into the folder and registers it.
    @discardableResult
    public static func installFile(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            register([dest])
            return true
        } catch { return false }
    }

    /// Downloads each family from Google Fonts. Returns the families installed and those not found.
    public static func download(_ families: [String]) async -> (installed: [String], notFound: [String], failed: [String]) {
        var ok: [String] = [], nf: [String] = [], bad: [String] = []
        for f in families {
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
        a.addButton(withTitle: L10n.t("gt.fonts_skip"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        downloadFonts(families)
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
