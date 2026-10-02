import AppKit
import OSLog

// Running saved automations: the scheduler, the trigger engine and routines.

extension AppDelegate {
    /// ROUTINE RUN — the headless agentic pass (v2 #2): gather via one matched
    /// MCP tool and/or a short read-only registry-tool loop, then the model
    /// synthesizes a glanceable result for the notch pill. Standing consent:
    /// NO cards fire — so only `.auto` (read-only / workspace-scoped) registry
    /// tools may run; a `.confirm` tool named by the model is refused and
    /// logged. Every step audits under "routine:<name>".
    func runRoutine(_ a: Automation, depth: Int = 0) async -> String {
        // The real loop, headless (ASSISTANT.md phase 4): read-only unless the
        // automation carries standing consent; every tool audited under
        // "routine:<name> › <tool>"; tracked in the ledger so "Stop everything" reaches it.
        let goal = a.routineGoal ?? a.name
        var policy = a.policy ?? .headlessReadOnly
        policy.label = "routine:\(a.name)"
        policy.depth = depth
        await AuditLog.shared.record(tool: "routine:\(a.name)", argsJSON: "{}", outcome: "started", summary: policy.standingConsent ? "standing consent" : "read-only", confirmed: policy.standingConsent)
        let convo = Conversation(chatWithApp: "")
        convo.addUserMessage(goal + "\n\n(Deliver the result short and glanceable — 2–4 plain sentences or up to 5 short lines; it appears under the notch.)")
        let ledgerID = TaskLedger.shared.start(goal: "Routine: \(a.name)")
        runningAutomationIDs.insert(a.id)
        let runPolicy = policy
        let box = AgentRunBox()
        let handle = Task { @MainActor [weak self] in
            guard let self else { return }
            box.run = await self.runAgentLoop(in: convo, goal: goal, policy: runPolicy, headless: true)
        }
        TaskLedger.shared.attach(id: ledgerID, task: handle)
        await handle.value
        let run = box.run ?? AgentRun(text: "", cancelled: true)
        runningAutomationIDs.remove(a.id)
        if run.cancelled || handle.isCancelled {
            await AuditLog.shared.record(tool: "routine:\(a.name)", argsJSON: "{}", outcome: "cancelled", summary: AICost.format(run.costUSD), confirmed: policy.standingConsent)
            TaskLedger.shared.finish(id: ledgerID, result: "Cancelled.", costUSD: run.costUSD)
            return ""
        }
        let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
        TaskLedger.shared.finish(id: ledgerID, result: text, costUSD: run.costUSD)
        await AuditLog.shared.record(tool: "routine:\(a.name)", argsJSON: "{}", outcome: text.isEmpty ? "error" : "ok",
                                     summary: "\(AICost.format(run.costUSD)) · \(text.prefix(80))", confirmed: policy.standingConsent)
        return text.isEmpty ? "Routine “\(a.name)” ran — but came back empty." : String(text.prefix(800))
    }

    /// Run a saved automation WITHOUT a card (standing consent granted at save time).
    /// `extra` carries trigger context (e.g. trigger_file = the new file's path) that
    /// substitutes into the body AFTER the recipe's own params.
    func runAutomation(_ a: Automation, extra: [String: String] = [:], depth: Int = 0) async {
        if a.routineGoal != nil {
            let summary = await runRoutine(a, depth: depth)
            guard !summary.isEmpty else { return }   // cancelled: no pill, audited as such
            NotchController.shared.notifyResult(summary)
            agentLog.info("routine \(a.name, privacy: .public): delivered — \(summary.prefix(120), privacy: .public)")
            return
        }
        guard let recipe = RecipeStore.shared.recipes.first(where: { $0.id == a.recipeId }) else {
            agentLog.error("automation \(a.name, privacy: .public): recipe \(a.recipeId, privacy: .public) missing"); return
        }
        let params = a.paramsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var body = recipe.resolve(recipe.body, with: params)
        for (k, v) in extra { body = body.replacingOccurrences(of: "${\(k)}", with: v) }
        do {
            _ = try AppleScriptTool.shared.runScript(body)
            agentLog.info("automation \(a.name, privacy: .public): ran OK")
            await AuditLog.shared.record(tool: "automation:\(a.name)", argsJSON: a.paramsJSON, outcome: "ok", summary: recipe.title, confirmed: true)
        } catch {
            await AuditLog.shared.record(tool: "automation:\(a.name)", argsJSON: a.paramsJSON, outcome: "error", summary: error.localizedDescription, confirmed: true)
        }
    }

    /// Wire the TriggerEngine to the automation runner and start watching. The engine
    /// is event-driven (no polling); refresh() reconciles watchers with the store.
    func startTriggerEngine() {
        TriggerEngine.shared.onFire = { [weak self] automation, extra in
            Task { @MainActor in
                await self?.runAutomation(automation, extra: extra)
                if !NotchController.shared.isPanelOpen {
                    NotchController.shared.notifyResult("Ran automation: \(automation.name)")
                }
            }
        }
        TriggerEngine.shared.refresh()
    }

    /// Once-a-tick scheduler: run any enabled automation whose time is due (deduped per
    /// minute via `lastRunKey`). Started on launch.
    func startScheduler() {
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickScheduler() }
        }
        agentLog.info("scheduler: started (\(AutomationStore.shared.automations.count) automation(s))")
    }

    func tickScheduler() async {
        let now = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: Date())
        guard let y = now.year, let mo = now.month, let d = now.day, let h = now.hour, let mi = now.minute else { return }
        let key = String(format: "%04d-%02d-%02d-%02d-%02d", y, mo, d, h, mi)
        for a in AutomationStore.shared.automations where a.enabled && a.lastRunKey != key {
            guard let s = a.schedule, s.isDue(now) else { continue }
            var updated = a; updated.lastRunKey = key
            AutomationStore.shared.replace(updated)
            agentLog.info("scheduler: firing \"\(a.name, privacy: .public)\" (\(s.describe, privacy: .public))")
            await runAutomation(a)
            // Routines deliver their own summary pill inside runAutomation.
            if a.routineGoal == nil, !NotchController.shared.isPanelOpen {
                NotchController.shared.notifyResult("Ran automation: \(a.name)")
            }
        }
    }
}
