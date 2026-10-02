import Foundation

/// TRUST — which tools the model may see, and which may run without a card
/// (CUSTOMIZING.md). "Don't ask" applies to attended runs only: an unattended
/// run (routine, background task, sub-agent) keeps following its automation's
/// consent, so trusting a tool never widens what happens while nobody is at the notch.
nonisolated enum TrustSettings {
    static let disabledKey = "handle.trust.disabledTools"
    static let dontAskKey = "handle.trust.dontAsk"

    /// Always a card: these mint or remove capability.
    static let alwaysAsk: Set<String> = ["save_automation", "delete_automation"]

    static var disabledTools: Set<String> { Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? []) }
    static var dontAsk: Set<String> { Set(UserDefaults.standard.stringArray(forKey: dontAskKey) ?? []) }

    static func isDisabled(_ name: String) -> Bool { disabledTools.contains(name) }
    static func isTrusted(_ name: String) -> Bool { !alwaysAsk.contains(name) && dontAsk.contains(name) }

    static func setDisabled(_ name: String, _ off: Bool) {
        var s = disabledTools
        if off { s.insert(name) } else { s.remove(name) }
        UserDefaults.standard.set(s.sorted(), forKey: disabledKey)
    }
    static func setDontAsk(_ name: String, _ on: Bool) {
        var s = dontAsk
        if on && !alwaysAsk.contains(name) { s.insert(name) } else { s.remove(name) }
        UserDefaults.standard.set(s.sorted(), forKey: dontAskKey)
    }
}
