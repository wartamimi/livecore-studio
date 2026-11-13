#if os(macOS)
import AppKit
import CoreText
import LiveCoreServices

/// Fonts LiveCore installs for imported titles (0.40.0): kept in Application Support/LiveCore
/// Studio/Fonts and registered for this app only (no admin rights, nothing changes system-wide).
public enum FontInstaller {
    public static var folder: URL {
        AppSupport.folder("Fonts")
    }

    /// Registers every font saved earlier; call once at launch.
    public static func registerAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        register(files.filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) })
    }

    static func register(_ urls: [URL]) {
        for u in urls { CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil) }
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
}
#endif
