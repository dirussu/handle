import Foundation

/// What one agent run may do (ASSISTANT.md phase 4). User turns are interactive
/// (confirm cards, the Settings limits); sub-agents, routines and background
/// tasks are headless: consequential tools run only with standing consent the
/// user granted on the automation's card, otherwise they're refused and the run
/// says so. Stored on saved automations; old ones decode with `nil` (read-only).
nonisolated struct AgentPolicy: Codable, Equatable, Sendable {
    var allowedTools: [String]? = nil     // nil = every tool
    var maxSteps: Int = 15
    var budgetUSD: Double = 0.25
    var standingConsent: Bool = false
    var depth: Int = 0                    // 0 = the user's turn; sub-agents nest at most twice

    static func interactive() -> AgentPolicy {
        AgentPolicy(maxSteps: AgentSettings.maxSteps, budgetUSD: AgentSettings.turnBudgetUSD)
    }
    static let headlessReadOnly = AgentPolicy()

    func allows(_ toolName: String) -> Bool {
        guard let allowedTools else { return true }
        return allowedTools.contains(toolName)
    }

    /// A child run: never more capable than its parent, never with consent of its own.
    func child(allowedTools: [String]?, maxSteps: Int) -> AgentPolicy {
        AgentPolicy(allowedTools: allowedTools ?? self.allowedTools,
                    maxSteps: max(1, min(maxSteps, min(self.maxSteps, 15))),
                    budgetUSD: budgetUSD > 0 ? min(budgetUSD, 0.25) : 0.25,
                    standingConsent: false, depth: depth + 1)
    }
}
