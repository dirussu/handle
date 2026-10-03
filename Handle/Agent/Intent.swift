import AppKit
import OSLog

/// Cheap checks on the user's wording that decide which path a message takes.
enum Intent {
    /// "remember that X" / "remember my X" / "remember I X" → the fact to store.
    /// "remember to X" is deliberately NOT memory — that's a reminder request and
    /// falls through to the normal loop (create_reminder).
    static func rememberCommand(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard lower.hasPrefix("remember ") else { return nil }
        if lower.hasPrefix("remember to ") { return nil }
        var rest = String(t.dropFirst("remember ".count))
        if rest.lowercased().hasPrefix("that ") { rest = String(rest.dropFirst("that ".count)) }
        let fact = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return fact.isEmpty ? nil : fact
    }

    /// "forget (that|about|my) X" → the phrase to match against stored facts.
    /// Bare "forget it" is colloquial, not a deletion.
    static func forgetCommand(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard lower.hasPrefix("forget ") else { return nil }
        if lower == "forget it" || lower == "forget about it" { return nil }
        var rest = String(t.dropFirst("forget ".count))
        for prefix in ["that ", "about ", "what i said about "] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        let phrase = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.isEmpty ? nil : phrase
    }

    /// Does the prompt ask Handle to DO something (vs. explain/ask)? Gates the
    /// action loop so plain explain/ask turns keep their validated single-turn
    /// behavior. Deliberately conservative (recapture-style intent).
    static func asksToAct(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // HIGH-RECALL gate: offer tools for almost everything and let the model decide.
        // Missing a needed tool ("what's on my desktop" → list_files, "am I free?" →
        // read_calendar_events) makes Handle look broken; offering an unused one just
        // costs a little prompt. Only a pure screen-DESCRIBE (handled by the tool-less
        // vision path) and short conversational filler opt out.
        if t.hasPrefix("explain") || t.hasPrefix("describe") { return false }
        let fillers: Set<String> = ["hi", "hello", "hey", "thanks", "thank you", "ty", "ok", "okay",
                                    "cool", "nice", "great", "got it", "yes", "no", "yep", "nope", "sure"]
        return !fillers.contains(t)
    }

    /// Does this prompt actually ask Handle to point at / locate something? Gates
    /// the (token-heavy) candidate list so it's only sent when pointing is wanted —
    /// not on a plain "explain this screen" turn. ("click"/"press"/"tap" now route
    /// to the CLICK path — checked before this gate.)
    static func asksToPoint(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["where", "point at", "point to", "show me", "find the", "locate",
                "highlight", "which"].contains { t.contains($0) }
    }

    /// Does this prompt ask Handle to actually PRESS something on screen? Routes to
    /// the click path: same select-by-index as pointing, then highlight → confirm
    /// card → AXPress. Checked before `asksToPoint`.
    static func asksToClick(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["click", "press the", "press on", "tap ", "tap the", "push the button",
                "hit the button"].contains { t.contains($0) }
    }
}
