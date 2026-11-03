#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

/// LUT library (0.48.0): .cube files kept in Application Support/LiveCore Studio/LUTs, so a
/// project keeps working when the original file is moved.
extension AppModel {
    public static var lutFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveCore Studio/LUTs", isDirectory: true)
    }

    /// The .cube files in the library, by name.
    public func lutLibrary() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.lutFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Asks for a .cube file, checks it and copies it into the library. Returns the library copy.
    public func importLUT() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = L10n.t("lut.import_message")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try CubeLUT.parse(text)
            let dest = uniqueLUTURL(url.deletingPathExtension().lastPathComponent)
            try FileManager.default.createDirectory(at: Self.lutFolder, withIntermediateDirectories: true)
            try text.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        } catch let e as CubeLUT.ParseError {
            report(L10n.f("lut.invalid", url.lastPathComponent, e.description))
        } catch {
            report(L10n.f("lut.invalid", url.lastPathComponent, error.localizedDescription))
        }
        return nil
    }

    /// Saves a generated look into the library (replacing a LUT of the same name).
    @discardableResult
    public func saveGeneratedLUT(_ look: LUTLook, name: String, size: Int) -> URL? {
        let clean = Self.lutFileName(name)
        let dest = Self.lutFolder.appendingPathComponent(clean + ".cube")
        do {
            try FileManager.default.createDirectory(at: Self.lutFolder, withIntermediateDirectories: true)
            try look.makeLUT(title: name, size: size).cubeText(comment: "Made with LiveCore Studio LUT Generator")
                .write(to: dest, atomically: true, encoding: .utf8)
            engine?.reloadLUT(dest.path)
            return dest
        } catch {
            report(L10n.f("lut.save_failed", error.localizedDescription))
            return nil
        }
    }

    /// Saves a generated look anywhere (for other apps: Resolve, Premiere, OBS, cameras…).
    public func exportGeneratedLUT(_ look: LUTLook, name: String, size: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.nameFieldStringValue = Self.lutFileName(name) + ".cube"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try look.makeLUT(title: name, size: size).cubeText(comment: "Made with LiveCore Studio LUT Generator")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            report(L10n.f("lut.save_failed", error.localizedDescription))
        }
    }

    public func setLUT(_ id: InputID, path: String?, strength: Double? = nil) {
        var a = adjust(of: id)
        a.lut = path
        if let strength { a.lutStrength = strength }
        setAdjust(id, a)
    }

    static func lutFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let s = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "LUT" : String(s.prefix(80))
    }

    private func uniqueLUTURL(_ name: String) -> URL {
        let base = Self.lutFileName(name)
        var url = Self.lutFolder.appendingPathComponent(base + ".cube")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.lutFolder.appendingPathComponent("\(base) \(n).cube"); n += 1
        }
        return url
    }
}
#endif
