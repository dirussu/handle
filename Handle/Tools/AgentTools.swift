import Foundation

/// Agents as tools (ASSISTANT.md phase 4). Definitions only — the loop executes
/// them, because they need the loop itself (sub-agents), its consent path
/// (saving/deleting automations) or the ledger (background tasks).
@MainActor
enum AgentTools {
    static var tools: [Tool] { [saveAutomationTool, listAutomationsTool, runAutomationTool, deleteAutomationTool, runSubagentTool, runInBackgroundTool] }

    static let saveAutomationTool = Tool(
        name: "save_automation",
        description: "Save an automation Handle runs on its own — on a schedule and/or when an event happens. `goal` is what to do each time; Handle runs it as an agent with its tools. Set standing_consent only if the task must act (send, write, change things); otherwise it runs read-only and reports. The user confirms.",
        inputSchema: ["type": "object",
                      "properties": ["name": ["type": "string"],
                                     "goal": ["type": "string"],
                                     "schedule": ["type": "object", "description": "Recurring time: hour 0-23, minute 0-59, days 1=Sunday…7=Saturday (omit for every day)",
                                                  "properties": ["hour": ["type": "integer"], "minute": ["type": "integer"], "days": ["type": "array", "items": ["type": "integer"]]]],
                                     "trigger": ["type": "object", "description": "Event: kind fileAppears (folder, ext) | appLaunches (app) | wifiConnects (ssid) | windowMatches (window) | calendarSoon (minutesBefore) | screenLocks (state lock|unlock)",
                                                 "properties": ["kind": ["type": "string"], "folder": ["type": "string"], "ext": ["type": "string"], "app": ["type": "string"], "ssid": ["type": "string"], "window": ["type": "string"], "minutesBefore": ["type": "integer"], "state": ["type": "string"]]],
                                     "standing_consent": ["type": "boolean"]],
                      "required": ["goal"]],
        confirmation: .confirm)

    static let listAutomationsTool = Tool(
        name: "list_automations",
        description: "List the saved automations (id, name, when, what, whether it may act without asking).",
        inputSchema: ["type": "object", "properties": [:]],
        confirmation: .auto)

    static let runAutomationTool = Tool(
        name: "run_automation",
        description: "Run a saved automation now, by id or name. The user confirms.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
        confirmation: .confirm)

    static let deleteAutomationTool = Tool(
        name: "delete_automation",
        description: "Delete a saved automation, by id or name. The user confirms.",
        inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
        confirmation: .confirm)

    static let runSubagentTool = Tool(
        name: "run_subagent",
        description: "Delegate a self-contained sub-task to a fresh agent with its own step budget and, optionally, a restricted tool set; you get its final answer back as text. Sub-agents can read and look but cannot take consequential actions. Use it for research or long reads that would clutter your own context.",
        inputSchema: ["type": "object",
                      "properties": ["goal": ["type": "string"], "tools": ["type": "array", "items": ["type": "string"], "description": "Tool names it may use (omit = all read-only)"], "max_steps": ["type": "integer"]],
                      "required": ["goal"]],
        confirmation: .confirm)

    static let runInBackgroundTool = Tool(
        name: "run_in_background",
        description: "Start a longer read-only task that runs while you keep talking to the user; its result appears under the notch when it's done. Tell the user it's running; don't wait for it.",
        inputSchema: ["type": "object", "properties": ["goal": ["type": "string"]], "required": ["goal"]],
        confirmation: .confirm)

    /// One line per saved automation. Pure given the list.
    static func describe(_ automations: [Automation]) -> String {
        guard !automations.isEmpty else { return "(no saved automations)" }
        return automations.map { a in
            let when = [a.schedule?.describe, a.trigger?.describe].compactMap { $0 }.joined(separator: " and ")
            let what = a.routineGoal ?? "recipe \(a.recipeId)"
            let consent = (a.policy?.standingConsent ?? false) ? "may act" : "read-only"
            return "\(a.id) — \(a.name) — \(when.isEmpty ? "(no schedule)" : when) — \(what) — \(consent)\(a.enabled ? "" : " — disabled")"
        }.joined(separator: "\n")
    }

    static func listAutomations() -> String { describe(AutomationStore.shared.automations) }
}
