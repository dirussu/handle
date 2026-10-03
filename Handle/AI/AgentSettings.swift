import Foundation

/// The loop's limits — visible and editable (ASSISTANT.md: budgets, not hopes).
/// A run that hits one ends with a plain answer that says what is done and what
/// is not; never a silent stop.
nonisolated enum AgentSettings {
    static let maxStepsKey = "handle.agent.maxSteps"
    static let turnBudgetKey = "handle.agent.turnBudgetUSD"
    static let defaultMaxSteps = 30
    static let defaultTurnBudgetUSD = 0.50

    static var maxSteps: Int {
        let v = UserDefaults.standard.integer(forKey: maxStepsKey)
        return v > 0 ? min(v, 100) : defaultMaxSteps
    }
    static func setMaxSteps(_ n: Int) { UserDefaults.standard.set(max(1, min(100, n)), forKey: maxStepsKey) }

    /// Dollars per user turn; 0 = no limit. Unknown-price models spend "0" per
    /// step, so the budget can only bite where the cost is actually known.
    static var turnBudgetUSD: Double {
        guard UserDefaults.standard.object(forKey: turnBudgetKey) != nil else { return defaultTurnBudgetUSD }
        return max(0, UserDefaults.standard.double(forKey: turnBudgetKey))
    }
    static func setTurnBudget(_ usd: Double) { UserDefaults.standard.set(max(0, usd), forKey: turnBudgetKey) }

    /// Pure: why a run must stop before this step, or nil to continue.
    static func stopReason(step: Int, maxSteps: Int, spentUSD: Double, budgetUSD: Double) -> String? {
        if step >= maxSteps { return "Step limit (\(maxSteps) steps) reached" }
        if budgetUSD > 0 && spentUSD >= budgetUSD { return "Turn budget (\(AICost.format(budgetUSD))) reached" }
        return nil
    }
}

/// Consecutive-repeat detector for the loop: the same step twice is a hint to
/// the model, three times is a stop. Pure value type (self-tested).
nonisolated struct RepeatGuard {
    private(set) var lastSignature = ""
    private(set) var count = 0

    /// Returns how many times in a row this signature has now been seen (1 = first).
    mutating func observe(_ signature: String) -> Int {
        if signature == lastSignature { count += 1 } else { lastSignature = signature; count = 1 }
        return count
    }
}

extension RepeatGuard {
    /// The signature of one tool call: its name and its arguments, normalised. A value that
    /// reads as a date collapses to its minute, and everything else is lowercased and
    /// trimmed, so the same call written slightly differently still counts as a repeat.
    @MainActor
    static func signature(name: String, args: [String: Any]) -> String {
        let parts = args.keys.sorted().map { key -> String in
            let raw = String(describing: args[key] ?? "")
            if let date = CalendarTools.parseDate(raw) {
                return "\(key)=@\(Int(date.timeIntervalSince1970 / 60))"
            }
            return "\(key)=\(raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return name + "|" + parts.joined(separator: "&")
    }
}
