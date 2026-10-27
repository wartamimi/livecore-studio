#if os(macOS)
import Foundation

/// Localised strings. English is the development language; Indonesian (id) is provided.
/// Add a language by copying Resources/en.lproj/Localizable.strings to <lang>.lproj.
enum L10n {
    static func t(_ key: String) -> String { NSLocalizedString(key, bundle: bundle, comment: "") }
    static func f(_ key: String, _ args: CVarArg...) -> String { String(format: t(key), arguments: args) }

    /// Locates the SwiftPM resource bundle in every packaging we support: Xcode app target
    /// (Contents/Resources), scripts/bundle_spm_app.sh (Contents/Resources) and `swift run`
    /// (build directory, via Bundle.module's own fallback).
    static let bundle: Bundle = {
        let name = "LiveCoreStudio_LiveCoreUI.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: BundleToken.self).resourceURL]
            .compactMap { $0?.appendingPathComponent(name) }
        for url in candidates { if let b = Bundle(url: url) { return b } }
        return Bundle.module
    }()

    private final class BundleToken {}
}
#endif
