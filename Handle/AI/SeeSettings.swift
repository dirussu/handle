import Foundation
import AppKit

/// What happened to the screenshot of one user turn — shown under the bubble
/// so "Handle looked" is never silent now that looking can mean sending.
nonisolated enum ScreenshotStatus: Equatable, Sendable {
    case sent(provider: String)
    case withheldExcluded(app: String)
    case withheldDeclined
    case withheldUnsupported

    var caption: String {
        switch self {
        case .sent(let p): return "Screenshot sent to \(p)"
        case .withheldExcluded(let app): return "Screen not shared — \(app) is excluded"
        case .withheldDeclined: return "Screenshot not shared"
        case .withheldUnsupported: return "Screen not shared — this model can't see images"
        }
    }
    var symbol: String {
        if case .sent = self { return "eye" } else { return "eye.slash" }
    }
}

/// Screen-sharing consent (PROVIDERS.md phase 3). Capture is local and free;
/// these decide whether an excluded app is captured at all, and whether the
/// user is asked before a screenshot leaves the Mac. Both default to "off":
/// nothing is excluded silently, nothing asks until the user wants it to.
nonisolated enum SeeSettings {
    static let excludedKey = "handle.see.excludedBundleIDs"
    static let askKey = "handle.see.askBeforeSend"

    static var excludedBundleIDs: [String] { UserDefaults.standard.stringArray(forKey: excludedKey) ?? [] }
    static func setExcluded(_ ids: [String]) {
        UserDefaults.standard.set(Array(Set(ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted(), forKey: excludedKey)
    }
    static func exclude(_ id: String) { setExcluded(excludedBundleIDs + [id]) }
    static func include(_ id: String) { setExcluded(excludedBundleIDs.filter { $0.caseInsensitiveCompare(id) != .orderedSame }) }

    static var askBeforeSend: Bool {
        get { UserDefaults.standard.bool(forKey: askKey) }
        set { UserDefaults.standard.set(newValue, forKey: askKey) }
    }

    /// Pure (self-tested): is this app on the list?
    static func isExcluded(_ bundleID: String?, in list: [String]) -> Bool {
        guard let id = bundleID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return false }
        return list.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }
    static func isExcluded(_ bundleID: String?) -> Bool { isExcluded(bundleID, in: excludedBundleIDs) }

    /// Apps worth suggesting — credential stores. Offered only when installed,
    /// and never added on their own (founder: unchecked, not silently on).
    static let suggestions: [(id: String, name: String)] = [
        ("com.1password.1password", "1Password"),
        ("com.bitwarden.desktop", "Bitwarden"),
        ("com.apple.Passwords", "Passwords"),
        ("com.apple.keychainaccess", "Keychain Access"),
        ("com.dashlane.DashlaneAppMac", "Dashlane"),
        ("com.lastpass.LastPass", "LastPass"),
    ]

    @MainActor static func installedSuggestions() -> [(id: String, name: String)] {
        suggestions.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The installed app's name for a bundle id, else the id itself.
    @MainActor static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Bundle id of a running app by its visible name (window captures only know the name).
    @MainActor static func bundleID(forRunningAppNamed name: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleIdentifier
    }

    // What the model is told when the screen was NOT captured / sent.
    static func excludedNote(app: String) -> String {
        "[The screen was NOT captured for this question: \(app) is on the user's excluded-apps list. If the answer needs the screen, say so plainly instead of guessing.]"
    }
    static let declinedNote = "[The user chose not to share a screenshot for this question. Answer from the text; if the answer needs the screen, say so plainly instead of guessing.]"
    static let unsupportedNote = "[No screenshot was attached: the configured model can't take images. Answer from the text; if the answer needs the screen, say so plainly instead of guessing.]"
}
