import AppKit
import OSLog

// The agent loop: one implementation for chat turns, sub-agents, routines and background tasks.

extension AppDelegate {
    /// Hide the chat panel, run a fresh selection overlay, capture a region,
    /// and stage it as the pending attachment on the conversation.
    /// The agent loop (M3). Replaces the old single-shot `runTurn` at every call
    /// site. Three paths, in priority order:
    ///   1. POINTING turn (image + asked to point + not the initial explain) →
    ///      ONE step, the validated index-select `point_at` path. Unchanged.
    ///   2. ACTION turn (asked to do/recapture something) → a bounded multi-step
    ///      loop: stream → parse a tool call → execute → fold the result into the
    ///      next prompt → repeat, until no call (final answer) or `maxSteps`.
    ///   3. PLAIN explain/ask → ONE step, no tools. Identical to the old behavior.
    /// Owns the working-comet + completion notification for the WHOLE run.
    func runToolLoop(in conversation: Conversation, isInitial: Bool, action: ActionType) async {
        guard !isAgentRunning else { agentLog.info("runToolLoop: re-entry ignored (already running)"); return }
        isAgentRunning = true
        NotchController.shared.setWorking(true)
        conversation.isAwaitingResponse = true   // bubble comet from the first instant, on every path (typed, voice, capture)
        defer {
            isAgentRunning = false
            NotchController.shared.setWorking(false)
            conversation.stopStreaming()   // unstick the panel on ANY exit — incl. a user-cancelled turn
            // Persist the transcript on EVERY exit path (text-only snapshot; the
            // loop is the single choke point all turns — typed, voice, capture —
            // flow through).
            if let snap = conversation.snapshot() {
                Task.detached(priority: .utility) { await ConversationStore.shared.save(snap) }
            }
            if !NotchController.shared.isPanelOpen {
                let last = conversation.visibleMessages.last
                NotchController.shared.notifyResult((last?.text).map { String($0.prefix(800)) } ?? "Done")
            }
            // Drain the queue: messages typed during this turn run now, in
            // order — unless the user hit Stop (cancel clears the queue, and a
            // cancelled turn must not resurrect work).
            if !Task.isCancelled, !conversation.queuedTexts.isEmpty {
                let next = conversation.queuedTexts.removeFirst()
                agentLog.info("queue: draining next message (\(conversation.queuedTexts.count) left)")
                Task { @MainActor [weak self] in self?.runSubmittedTurn(text: next, in: conversation) }
            } else if !Task.isCancelled {
                // Model idle → give this chat a real title (once), off the hot path.
                Task { @MainActor [weak self] in await self?.maybeGenerateTitle(for: conversation) }
            }
        }

        // No usable AI → say so in chat instead of failing inside a model turn.
        // (Legacy on-device is always "ready"; cloud needs a provider + key.)
        if let message = AIConfig.state.userMessage {
            agentLog.info("runToolLoop: no usable AI (\(String(describing: AIConfig.state), privacy: .public)) — asking the user to connect one")
            conversation.commitAssistantMessage(message)
            return
        }

        conversation.screenSendDecision = nil   // ask-before-send is decided once per user turn
        let image = conversation.messages.last(where: { $0.role == .user })?.image
        let userText = conversation.messages.last(where: { $0.role == .user })?.text ?? ""
        agentLog.info("runToolLoop: ENTER isInitial=\(isInitial) text=\"\(userText, privacy: .public)\"")

        // 0. CLICK turn — the same select-by-index as pointing, but ACTED on:
        // highlight → confirm card → AXPress → audit. Checked before pointing so
        // "click the send button" presses rather than just highlights.
        if image != nil, !isInitial, Intent.asksToClick(userText) {
            let out = await streamTurn(in: conversation, instr: AgentPrompting.pointingGuide(elements: conversation.axElements, native: AIConfig.nativeTools),
                                       display: false, extraSpecs: [AgentPrompting.pointAtSpec])
            if !(await dispatchClick(out.call, conversation: conversation)) {
                conversation.commitAssistantMessage("I don't see that on the screen.")
            }
            return
        }

        // 1. Pointing turn — single step, validated index-select path. Buffered
        // (display:false) so the raw point_at JSON never shows; the highlight IS the
        // answer, so we add a message only when nothing was highlighted.
        if image != nil, !isInitial, Intent.asksToPoint(userText) {
            let out = await streamTurn(in: conversation, instr: AgentPrompting.pointingGuide(elements: conversation.axElements, native: AIConfig.nativeTools),
                                       display: false, extraSpecs: [AgentPrompting.pointAtSpec])
            if !dispatchPointAt(out.call, conversation: conversation) {
                conversation.commitAssistantMessage("I don't see that on the screen.")
            }
            return
        }

        // 2b. MEMORY — explicit "remember that…" / "forget…" turns are handled by
        // deterministic code, never a model turn (facts enter memory only
        // explicitly — PRODUCT.md memory layer; the user can read the whole store
        // in Settings → Memory).
        if !isInitial, let fact = Intent.rememberCommand(userText) {
            let stored = await MemoryStore.shared.remember(fact)
            let reply = stored != nil ? "Remembered: \(fact)" : "I couldn't save that."
            conversation.commitAssistantMessage(reply)
            Task { await AuditLog.shared.record(tool: "remember", argsJSON: "{}", outcome: stored != nil ? "ok" : "error", summary: String(fact.prefix(80)), confirmed: false) }
            return
        }
        if !isInitial, let phrase = Intent.forgetCommand(userText) {
            let matches = await MemoryStore.shared.matching(phrase)
            switch matches.count {
            case 0:
                conversation.commitAssistantMessage("I don't have anything remembered about that.")
            case 1:
                await MemoryStore.shared.delete(id: matches[0].id)
                conversation.commitAssistantMessage("Forgotten: \(matches[0].content)")
                Task { await AuditLog.shared.record(tool: "forget", argsJSON: "{}", outcome: "ok", summary: String(matches[0].content.prefix(80)), confirmed: false) }
            default:
                conversation.commitAssistantMessage("That matches \(matches.count) remembered facts — remove the right one in Settings → Memory.")
            }
            return
        }

        // Memory injection — the top keyword-matched facts, folded RIGHT NEXT
        // to the user's text by streamOneTurn (its own slot, not the context
        // preamble: sandwiched before the tool spec a small model ignored it —
        // verified live). Empty for prompts that touch nothing remembered.
        if !userText.isEmpty {
            let facts = await MemoryStore.shared.relevant(to: userText)
            conversation.pendingMemory = MemoryStore.preamble(for: facts)
            if !facts.isEmpty {
                agentLog.info("memory: injecting \(facts.count) fact(s) for this turn")
            }
        }

        // Personal-context injection : calendar/reminder-
        // shaped prompts get a FRESH digest (EventKit is milliseconds) folded
        // into the same slot — the model answers in ONE pass instead of a tool
        // round trip. Authorized sources only; a false-positive gate hit just
        // costs a few tokens.
        if promptAsksPersonalContext(userText) {
            let digest = await personalContextDigest()
            if !digest.isEmpty {
                conversation.pendingMemory += (conversation.pendingMemory.isEmpty ? "" : "\n\n") + digest
                agentLog.info("context: personal digest injected")
            }
        }

        // 3. Plain explain/ask — no tools, identical to the old single-turn path.
        guard !isInitial, Intent.asksToAct(userText) else {
            _ = await streamOneTurn(in: conversation, instr: "")
            return
        }

        // 2a-0a. EVENT TRIGGER — "when(ever) a PDF lands in Downloads, …" saves a
        // reactive automation (approved once; fired by TriggerEngine, no card).
        if hasEventTriggerHint(userText), await saveTriggeredAutomationIfRequested(goal: userText, in: conversation) { return }

        // 2a-0. SCHEDULE — if the goal is a recurring request ("every day at 8am…"),
        // save it as a scheduled automation (approved once) instead of running now.
        if hasScheduleHint(userText), await saveScheduledAutomationIfRequested(goal: userText, in: conversation) { return }

        // Recipes and MCP no longer front-run the loop: the
        // matching recipes are listed for `run_recipe`, and the configured MCP tools
        // are native tools, so the model can plan across all of them.

        _ = await runAgentLoop(in: conversation, goal: userText, policy: .interactive(), headless: false)
    }

    /// Result slot for a ledger-tracked run (the ledger holds `Task<Void, Never>` handles).
    final class AgentRunBox { var run: AgentRun? }

    /// What a headless run tells the model when a tool needs consent it doesn't have.
    static let refusedNote = "Not run: this action needs the user's OK, and this run has no standing consent. Say so in your answer instead of trying another way to do it."

    /// Runs the agent loop for one goal. Chat turns, sub-agents, routines and background
    /// tasks all come through here; `policy` sets the tools, the limits and the consent.
    /// The final answer is returned and also committed to the conversation.
    @discardableResult
    func runAgentLoop(in conversation: Conversation, goal: String, policy: AgentPolicy, headless: Bool) async -> AgentRun {
        await AgentRunner(app: self, conversation: conversation, goal: goal, policy: policy, headless: headless).run()
    }
}
