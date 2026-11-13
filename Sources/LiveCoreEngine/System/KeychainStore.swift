#if os(macOS)
import Foundation
import LiveCoreServices
import Security

/// Stores secrets (stream keys, remote PIN, API keys). Never written to UserDefaults,
/// project files, logs or source code.
///
/// Since 0.51.0 all secrets live in ONE vault (a JSON dictionary) that is read once per
/// launch and kept in memory. Before, every secret was its own Keychain item, and because
/// the app is ad-hoc signed (no Developer ID), each new build is a "different app" to the
/// Keychain, so macOS asked for the login password once per item per build.
/// Now it asks at most once per build (`.keychain`), never (`.keychainOpen`, the vault item
/// trusts any app of this macOS user), or never (`.localFile`, a 0600 file).
/// Old per-item entries are moved into the vault the first time they are read.
public enum KeychainStore {
    public static let service = "studio.livecore.LiveCoreStudio.streamkey"
    static let vaultAccount = "livecore-vault"
    public static let modeDefaultsKey = "secrets.storage"

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case keychain, keychainOpen, localFile
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .keychain: return "Keychain (asks once per new build)"
            case .keychainOpen: return "Keychain, never ask (any app of this Mac user may read it)"
            case .localFile: return "Local file, no Keychain (~/Library/Application Support, owner-only)"
            }
        }
    }

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case file(String)
        public var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(msg)"
            case let .file(m): return "Secret file error: \(m)"
            }
        }
    }

    private static let lock = NSLock()
    private static var cache: [String: String]?
    private static var legacyChecked = Set<String>()

    public static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeDefaultsKey) ?? "") ?? .keychain
    }

    // MARK: Public API (unchanged since 0.1)

    public static func save(streamKey: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var v = try vaultLocked()
        guard v[account] != streamKey else { return }
        v[account] = streamKey
        legacyChecked.insert(account)
        try writeVault(v, mode: mode)
        cache = v
        deleteLegacy(account)
    }

    public static func load(account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var v = try vaultLocked()
        if let s = v[account] { return s }
        guard !legacyChecked.contains(account) else { return nil }
        legacyChecked.insert(account)
        // One-time migration of a pre-0.51 per-item entry.
        guard let old = try? legacyLoad(account), !old.isEmpty else { return nil }
        v[account] = old
        if (try? writeVault(v, mode: mode)) != nil { cache = v; deleteLegacy(account) }
        return old
    }

    public static func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        var v = try vaultLocked()
        legacyChecked.insert(account)
        deleteLegacy(account)
        guard v.removeValue(forKey: account) != nil else { return }
        try writeVault(v, mode: mode)
        cache = v
    }

    /// Moves every secret to `newMode` and removes it from the old place.
    public static func setMode(_ newMode: Mode) throws {
        lock.lock(); defer { lock.unlock() }
        let old = mode
        let v = try vaultLocked()
        guard newMode != old || newMode == .keychainOpen else { return }
        try writeVault(v, mode: newMode)
        UserDefaults.standard.set(newMode.rawValue, forKey: modeDefaultsKey)
        if old == .localFile, newMode != .localFile { try? FileManager.default.removeItem(at: fileURL) }
        if old != .localFile, newMode == .localFile { deleteItem(vaultAccount) }
        cache = v
    }

    // MARK: Vault

    /// Read failure (e.g. the user pressed Deny) is not cached, so the next access asks
    /// again, and writes refuse to run so they never overwrite the vault with a partial copy.
    private static func vaultLocked() throws -> [String: String] {
        if let c = cache { return c }
        let v = try readVault(mode: mode)
        cache = v
        return v
    }

    static var fileURL: URL {
        AppSupport.root.appendingPathComponent("secrets.json")
    }

    private static func readVault(mode: Mode) throws -> [String: String] {
        let data: Data?
        switch mode {
        case .localFile: data = try? Data(contentsOf: fileURL)
        case .keychain, .keychainOpen: data = try itemData(vaultAccount)
        }
        guard let d = data, !d.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    private static func writeVault(_ v: [String: String], mode: Mode) throws {
        let data = try JSONEncoder().encode(v)
        switch mode {
        case .localFile:
            let dir = fileURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch { throw KeychainError.file(error.localizedDescription) }
        case .keychain:
            try upsertItem(vaultAccount, data: data, open: false)
        case .keychainOpen:
            try upsertItem(vaultAccount, data: data, open: true)
        }
    }

    // MARK: Keychain items

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func itemData(_ account: String) throws -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.unexpectedStatus(status) }
        return data
    }

    private static func upsertItem(_ account: String, data: Data, open: Bool) throws {
        if open {
            // Re-create so the item carries the open access list.
            deleteItem(account)
            try addItem(account, data: data, open: true)
            return
        }
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { try addItem(account, data: data, open: false); return }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    private static func addItem(_ account: String, data: Data, open: Bool) throws {
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "LiveCore Studio secrets"
        if open, let access = openAccess() {
            add[kSecAttrAccess as String] = access
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Access object whose use ACLs trust every application (Keychain Access:
    /// "Allow all applications to access this item"). Only changing the ACL stays owner-only.
    private static func openAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("LiveCore Studio secrets" as CFString, [] as CFArray, &access) == errSecSuccess,
              let a = access else { return nil }
        guard let list = SecAccessCopyMatchingACLList(a, kSecACLAuthorizationDecrypt),
              let acls = list as? [SecACL] else { return a }
        for acl in acls {
            _ = SecACLSetContents(acl, nil, "LiveCore Studio secrets" as CFString, [])
        }
        return a
    }

    private static func deleteItem(_ account: String) {
        _ = SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func legacyLoad(_ account: String) throws -> String? {
        guard account != vaultAccount, let d = try itemData(account) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func deleteLegacy(_ account: String) {
        guard account != vaultAccount else { return }
        deleteItem(account)
    }
}
#endif
