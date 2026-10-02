import Foundation
import Security

/// Generic-password Keychain store, one service name per purpose. Provider API
/// keys live here (never in UserDefaults, never logged). Same SecItem shape as
/// MCPKeychain, which phase 2 folds onto this type.
nonisolated struct SecretStore: Sendable {
    let service: String

    static let providers = SecretStore(service: "com.dimarussu.Handle.providers")

    @discardableResult
    func set(_ secret: String, for name: String) -> Bool {
        delete(name)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: Data(secret.utf8),
        ]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    func get(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func delete(_ name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Account names only (never the secrets) — for Settings.
    func allNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

extension SecretStore {
    /// "••••abcd" for a saved key — enough to recognise it, never the key.
    nonisolated static func hint(for secret: String) -> String {
        let tail = secret.suffix(4)
        return tail.isEmpty ? "" : "••••" + tail
    }
}
