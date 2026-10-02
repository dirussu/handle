import Foundation
import Security
import os

private let migrationLog = Logger(subsystem: "com.dimarussu.Handle", category: "Agent")

/// ONE-TIME move from the project's former name. Until 2026-10-02 the app was
/// called "Akari" (bundle id com.dimarussu.Akari). This carries an existing
/// install across: the Application Support folder, the preferences (keys renamed
/// akari.* → handle.*) and the Keychain items. Each part runs once and never
/// deletes the original. The only file that still names the old app; safe to
/// delete once every install has launched once.
nonisolated enum LegacyMigration {
    private static let oldName = "Akari"
    private static let oldBundleID = "com.dimarussu.Akari"
    private static let oldKeyPrefix = "akari."
    private static let doneKey = "handle.migratedFromLegacyName"
    private static let keychainDoneKey = "handle.legacyKeychainDone"
    private static let keychainAttemptsKey = "handle.legacyKeychainAttempts"

    /// Call before anything reads settings or opens a store.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        // Keychain, off the main thread: reading an item another app created makes macOS
        // ask the user once per item. Tried on the first three launches, then given up —
        // declining only means entering the key again in Settings.
        let attempts = defaults.integer(forKey: keychainAttemptsKey)
        if !defaults.bool(forKey: keychainDoneKey) && attempts < 3 {
            defaults.set(attempts + 1, forKey: keychainAttemptsKey)
            Task.detached(priority: .utility) { migrateKeychain() }
        }
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        // 1. The data folder: automations, audit log, memory, chats, recipes, tools, voice model.
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let old = support.appendingPathComponent(oldName), new = support.appendingPathComponent("Handle")
        var movedFolder = false
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
            movedFolder = (try? FileManager.default.moveItem(at: old, to: new)) != nil
        }

        // 2. Preferences: copy the old domain; our own keys get the new prefix.
        var copied = 0
        for (key, value) in defaults.persistentDomain(forName: oldBundleID) ?? [:] {
            let newKey = key.hasPrefix(oldKeyPrefix) ? "handle." + key.dropFirst(oldKeyPrefix.count) : key
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey); copied += 1 }
        }
        migrationLog.info("legacy migration: data folder moved=\(movedFolder), \(copied) preference(s) copied")
    }

    private static func migrateKeychain() {
        var moved = 0, unreadable = 0
        var lastStatus: OSStatus = errSecSuccess
        for suffix in ["providers", "mcp"] {
            let oldService = "\(oldBundleID).\(suffix)"
            let newStore = SecretStore(service: "com.dimarussu.Handle.\(suffix)")
            for name in SecretStore(service: oldService).allNames() where newStore.get(name) == nil {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: oldService,
                    kSecAttrAccount as String: name,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var out: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &out)
                if status == errSecSuccess, let data = out as? Data, let secret = String(data: data, encoding: .utf8),
                   !secret.isEmpty, newStore.set(secret, for: name) {
                    moved += 1
                } else {
                    unreadable += 1
                    lastStatus = status
                }
            }
        }
        if unreadable == 0 { UserDefaults.standard.set(true, forKey: keychainDoneKey) }
        migrationLog.info("legacy migration: keychain \(moved) item(s) carried over, \(unreadable) not readable (last status \(lastStatus))")
    }
}
