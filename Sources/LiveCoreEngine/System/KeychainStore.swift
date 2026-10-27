#if os(macOS)
import Foundation
import Security

/// Stores stream keys in the user's login Keychain (kSecClassGenericPassword).
/// Keys are never written to UserDefaults, project files, logs or source code.
public enum KeychainStore {
    public static let service = "studio.livecore.LiveCoreStudio.streamkey"

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        public var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(msg)"
            }
        }
    }

    public static func save(streamKey: String, account: String) throws {
        let data = Data(streamKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "LiveCore Studio stream key (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public static func load(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.unexpectedStatus(status) }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}
#endif
