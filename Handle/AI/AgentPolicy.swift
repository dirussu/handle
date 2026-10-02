import Foundation

/// What one agent run may do. User turns are interactive
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
    var effort: AIEffort? = nil           // reasoning depth for the run's turns (children: medium)
    var label: String? = nil              // audit prefix: "routine:Morning", "subagent", "task:1a2b"

    static func interactive() -> AgentPolicy {
        AgentPolicy(maxSteps: AgentSettings.maxSteps, budgetUSD: AgentSettings.turnBudgetUSD)
    }
    static let headlessReadOnly = AgentPolicy()

    func allows(_ toolName: String) -> Bool {
        guard let allowedTools else { return true }
        return allowedTools.contains(toolName)
    }

    /// A child run: never more capable than its parent (a requested tool list can
    /// only NARROW the parent's), never with consent of its own.
    func child(allowedTools requested: [String]?, maxSteps: Int, label: String? = nil) -> AgentPolicy {
        let narrowed: [String]?
        switch (requested, self.allowedTools) {
        case (let r?, let p?): narrowed = r.filter { p.contains($0) }
        case (let r?, nil): narrowed = r
        case (nil, let p?): narrowed = p
        case (nil, nil): narrowed = nil
        }
        return AgentPolicy(allowedTools: narrowed,
                           maxSteps: max(1, min(maxSteps, min(self.maxSteps, 15))),
                           budgetUSD: budgetUSD > 0 ? min(budgetUSD, 0.25) : 0.25,
                           standingConsent: false, depth: depth + 1, effort: .medium, label: label)
    }
}
