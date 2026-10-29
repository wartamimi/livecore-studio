#if os(macOS)
import Foundation

/// Localised strings. English is the development language; Indonesian (id) is complete and
/// Malay, Spanish and Simplified Chinese cover the main screens (0.45.0). A key missing from a
/// language falls back to English. The language follows macOS unless one is picked in
/// Settings › General (stored as "app.language"; applied at the next launch).
/// Add a language by copying Resources/en.lproj/Localizable.strings to <lang>.lproj.
enum L10n {
    static func t(_ key: String) -> String {
        let missing = "\u{1}"
        if let b = chosen, case let v = b.localizedString(forKey: key, value: missing, table: nil), v != missing { return v }
        if let b = english, case let v = b.localizedString(forKey: key, value: missing, table: nil), v != missing { return v }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    /// Languages offered in Settings: code and own name.
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("id", "Bahasa Indonesia"), ("ms", "Bahasa Melayu"), ("es", "Español"), ("zh-Hans", "简体中文"),
    ]
    static let languageKey = "app.language"

    private static func lproj(_ code: String) -> Bundle? {
        bundle.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
    private static let english = lproj("en")
    /// The picked language, or the best match for the macOS preferences.
    private static let chosen: Bundle? = {
        let picked = UserDefaults.standard.string(forKey: languageKey) ?? ""
        let code = picked.isEmpty
            ? Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first ?? "en"
            : picked
        return lproj(code)
    }()
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
