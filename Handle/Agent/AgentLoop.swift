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
        if image != nil, !isInitial, promptAsksToClick(userText) {
            let out = await streamTurn(in: conversation, instr: pointAtToolInstruction(elements: conversation.axElements, native: AIConfig.nativeTools),
                                       display: false, extraSpecs: [AgentPrompting.pointAtSpec])
            if !(await dispatchClick(out.call, conversation: conversation)) {
                conversation.commitAssistantMessage("I don't see that on the screen.")
            }
            return
        }

        // 1. Pointing turn — single step, validated index-select path. Buffered
        // (display:false) so the raw point_at JSON never shows; the highlight IS the
        // answer, so we add a message only when nothing was highlighted.
        if image != nil, !isInitial, promptAsksToPoint(userText) {
            let out = await streamTurn(in: conversation, instr: pointAtToolInstruction(elements: conversation.axElements, native: AIConfig.nativeTools),
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
        if !isInitial, let fact = parseRememberCommand(userText) {
            let stored = await MemoryStore.shared.remember(fact)
            let reply = stored != nil ? "Remembered: \(fact)" : "I couldn't save that."
            conversation.commitAssistantMessage(reply)
            Task { await AuditLog.shared.record(tool: "remember", argsJSON: "{}", outcome: stored != nil ? "ok" : "error", summary: String(fact.prefix(80)), confirmed: false) }
            return
        }
        if !isInitial, let phrase = parseForgetCommand(userText) {
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
        // preamble: sandwiched before the tool spec the 4B ignored it —
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
        guard !isInitial, promptAsksToAct(userText) else {
            _ = await streamOneTurn(in: conversation, instr: "")
            return
        }

        // 2a-0a. EVENT TRIGGER — "when(ever) a PDF lands in Downloads, …" saves a
        // reactive automation (approved once; fired by TriggerEngine, no card).
        if hasEventTriggerHint(userText), await saveTriggeredAutomationIfRequested(goal: userText, in: conversation) { return }

        // 2a-0. SCHEDULE — if the goal is a recurring request ("every day at 8am…"),
        // save it as a scheduled automation (approved once) instead of running now.
        if hasScheduleHint(userText), await saveScheduledAutomationIfRequested(goal: userText, in: conversation) { return }

        // Recipes and MCP no longer front-run the loop (ASSISTANT.md phase 3): the
        // matching recipes are listed for `run_recipe`, and the configured MCP tools
        // are native tools, so the model can plan across all of them.

        _ = await runAgentLoop(in: conversation, goal: userText, policy: .interactive(), headless: false)
    }

    /// Result slot for a ledger-tracked run (the ledger holds `Task<Void, Never>` handles).
    final class AgentRunBox { var run: AgentRun? }

    /// What a headless run tells the model when a tool needs consent it doesn't have.
    static let refusedNote = "Not run: this action needs the user's OK, and this run has no standing consent. Say so in your answer instead of trying another way to do it."

    /// The agent loop proper — shared by user turns, sub-agents, routines and
    /// background tasks (ASSISTANT.md phase 4). `policy` decides the tools, the
    /// limits and consent: interactive runs show confirm cards; headless runs
    /// either have standing consent or refuse consequential tools and say so.
    /// Returns the final answer (also committed to the conversation).
    @discardableResult
    func runAgentLoop(in conversation: Conversation, goal userText: String, policy: AgentPolicy, headless: Bool,
                              inheritedMCP: (tools: [Tool], map: [String: MCPToolInfo])? = nil) async -> AgentRun {
        // 2. Action loop — native tool_use/tool_result blocks (`loopHistory`) when the
        // provider has tools, prompt-folded JSON (`pendingResult`) otherwise. EVERY
        // call the model makes in a step runs and all results go back together; the
        // run continues until the model answers in plain text or a limit ends it
        // (ASSISTANT.md phase 1: the 4B-era leash — 5 steps, one action per turn,
        // first call only — is gone; limits are visible budgets instead).
        let native = AIConfig.nativeTools
        // MCP discovery once per user turn; children inherit it (no re-spawn per sub-agent).
        let (mcpTools, mcpMap): ([Tool], [String: MCPToolInfo])
        if let inheritedMCP { (mcpTools, mcpMap) = inheritedMCP } else { (mcpTools, mcpMap) = MCPLoopTools.make(await MCPService.shared.allConfiguredTools()) }
        // Unattended without standing consent = read-only: consequential tools and the
        // side-effecting `.auto` ones are not even offered (nothing to refuse, no wasted
        // steps, a much smaller prompt).
        let unattendedReadOnly = headless && !policy.standingConsent
        let toolset = (ToolRegistry.all + mcpTools + [Self.runRecipeTool] + AgentTools.tools).filter { t in
            policy.allows(t.name) && !TrustSettings.isDisabled(t.name)
                && !(unattendedReadOnly && (t.confirmation == .confirm || ScreenTools.sideEffectingAutoTools.contains(t.name)))
        }
        let webSpecs: [AIToolSpec] = (AIConfig.provider == .anthropic && WebSettings.searchEnabled) ? [WebSettings.anthropicSearchSpec] : []
        let recipeLines = unattendedReadOnly ? "" : Self.recipeCandidatesLine(for: userText)
        let maxSteps = policy.maxSteps
        let budgetUSD = policy.budgetUSD
        var spentUSD = 0.0
        // Native: the system prompt (identity + rules + tool schemas) is byte-stable
        // across steps AND turns so it caches; anything that changes per turn — the
        // clock — rides in the user prefix, identical at every step of this loop.
        var offered = Set(toolset.map(\.name))   // + the loop's own screenshot tool (pixels leave: not for unattended read-only runs)
        if !unattendedReadOnly && AIConfig.visionAvailable { offered.insert("recapture_screen") }
        let readOnlyLine = unattendedReadOnly
            ? "This run is unattended and read-only: only the tools in your tool list exist for it. Tools the guide mentions but the list doesn't (writing, shell, scripts, drafts, clicks) are unavailable — don't call them; say what you couldn't do."
            : ""
        let turnPrefix = [native ? Self.currentTimeLine() : "", readOnlyLine, recipeLines].filter { !$0.isEmpty }.joined(separator: "\n\n")
        defer { if native { conversation.pendingMemory = ""; conversation.pendingContextPreamble = "" } }
        var loopHistory: [AIMessage] = []   // native: [assistant tool_use(s), user tool_result(s)] per step
        var pendingResult = ""             // folded: the last step's results, prefixed to the next prompt
        var lastToolSummary = ""   // fallback shown if the model returns an empty final answer — the user always gets feedback
        var repeatGuard = RepeatGuard()
        var retriedEmptyReply = false

        /// Consent for a consequential action: a card when someone is at the notch;
        /// standing consent (granted on the automation's card) when headless; else refused.
        enum Approval { case approved, declined, refused }
        func approve(title: String, rows: [(label: String, value: String)], label: String, destructive: Bool = false) async -> Approval {
            if headless {
                if policy.standingConsent { agentLog.info("consent: standing — \(label, privacy: .public)"); return .approved }
                agentLog.info("consent: refused (headless, no standing consent) — \(label, privacy: .public)"); return .refused
            }
            if TrustSettings.isTrusted(label) {   // Settings → Tools → "Don't ask" (attended runs only)
                agentLog.info("consent: trusted, no card — \(label, privacy: .public)"); return .approved
            }
            return await awaitConfirmation(in: conversation, title: title, rows: rows, label: label, destructive: destructive) ? .approved : .declined
        }

        struct StepResult { let call: AgentToolCall; let content: String; let isError: Bool; let image: Data? }
        /// Feed a whole step's results back, whichever engine. A new screenshot
        /// retires the older ones in the history (each costs ~1.5k tokens per step).
        func feedback(_ results: [StepResult], note: String? = nil) {
            if native {
                if results.contains(where: { $0.image != nil }) { loopHistory = AgentPrompting.stripImages(from: loopHistory) }
                var parts: [AIMessage.Part] = results.map { .toolResult(id: $0.call.id, text: $0.content, isError: $0.isError, image: $0.image) }
                if let note { parts.append(.text(note)) }
                loopHistory.append(AIMessage(role: .user, parts: parts))
            } else {
                pendingResult = results.map { toolResultText($0.call.name, $0.content, isError: $0.isError) }.joined(separator: "\n\n")
                if let note { pendingResult += "\n\n" + note }
            }
        }
        /// One more model turn with NO tools — ends the loop with a plain-text answer.
        func forceFinalAnswer(_ note: String) async -> AgentRun {
            let out: TurnOutput
            if native {
                out = await streamTurn(in: conversation, rules: actionToolInstruction(native: true), instr: turnPrefix,
                                       loopHistory: loopHistory + [AIMessage.user(note)], effort: policy.effort)
            } else {
                out = await streamTurn(in: conversation, instr: [turnPrefix, pendingResult, note].filter { !$0.isEmpty }.joined(separator: "\n\n"), effort: policy.effort)
            }
            spend(out)
            return done(out.text, cancelled: Task.isCancelled)
        }
        /// Add a request's own cost to this run's tally (0 for unpriced models; nothing when no request was made).
        func spend(_ out: TurnOutput) {
            guard let u = out.usage else { return }
            spentUSD += AICost.estimate(model: CloudEngine.shared.lastModel, input: u.input, output: u.output, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite) ?? 0
        }
        /// Every exit goes through here so the result carries the cost.
        func done(_ text: String, cancelled: Bool = false) -> AgentRun { AgentRun(text: text, costUSD: spentUSD, cancelled: cancelled) }
        /// Audit label for a tool run inside this run ("routine:Morning › run_shell").
        func auditName(_ tool: String) -> String { policy.label.map { "\($0) › \(tool)" } ?? tool }

        for step in 0... {
            if Task.isCancelled { return done("", cancelled: true) }
            if let why = AgentSettings.stopReason(step: step, maxSteps: maxSteps, spentUSD: spentUSD, budgetUSD: budgetUSD) {
                agentLog.info("runToolLoop: \(why, privacy: .public) after \(step) step(s), \(AICost.format(spentUSD), privacy: .public) — forcing final answer")
                return await forceFinalAnswer("[\(why). Give your final answer now in plain text, no tools — say what is done and what is not.]")
            }
            let out: TurnOutput
            if native {
                out = await streamTurn(in: conversation, rules: actionToolInstruction(native: true), instr: turnPrefix, display: false,
                                       tools: toolset, extraSpecs: webSpecs, loopHistory: loopHistory, consumeSlots: false, effort: policy.effort)
            } else {
                let instr = [turnPrefix, actionToolInstruction(), pendingResult].filter { !$0.isEmpty }.joined(separator: "\n\n")
                pendingResult = ""
                out = await streamTurn(in: conversation, instr: instr, display: false, tools: toolset, effort: policy.effort)
            }
            spend(out)
            let calls = out.calls
            guard !calls.isEmpty else {            // no tool call → final answer
                if out.text.isEmpty && out.stopReason == "max_tokens" && !retriedEmptyReply {
                    // The output budget went to reasoning before any text. Ask once, plainly.
                    retriedEmptyReply = true
                    agentLog.info("runToolLoop: reply cut off (max_tokens) with no text — asking once for a plain-text answer")
                    return await forceFinalAnswer("[Your previous reply was cut off before any text. Answer now in plain text, concisely.]")
                }
                let finalText = out.text.isEmpty ? lastToolSummary : out.text
                conversation.commitAssistantMessage(finalText)
                return done(finalText)
            }
            agentLog.info("runToolLoop: step \(step) → \(calls.count) call(s): \(calls.map { "\($0.name)\($0.args.isEmpty ? "" : String(describing: $0.args))" }.joined(separator: " | "), privacy: .public)")
            if native {   // the model's own call(s) go on the record before their results
                var parts: [AIMessage.Part] = []
                if !out.text.isEmpty { parts.append(.text(out.text)) }
                for call in calls { parts.append(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argsJSON)) }
                loopHistory.append(AIMessage(role: .assistant, parts: parts))
            }

            // REPEAT GUARD — the same step twice in a row is a hint, three times is a
            // stop. A legitimate re-check after a change is a different step (args
            // differ or an action happened in between), so it passes.
            let signature = calls.map { Self.callSignature(name: $0.name, args: $0.args) }.joined(separator: " | ")
            let seen = repeatGuard.observe(signature)
            if seen >= 3 {
                agentLog.info("runToolLoop: same step three times — forcing final answer")
                feedback(calls.map { StepResult(call: $0, content: "(not run again — identical to the previous call; its result is above)", isError: false, image: nil) })
                return await forceFinalAnswer("[You have made the same call three times. Do not call any tool again — give your final answer now in plain text, saying what is done and what is not.]")
            }
            // Unattended with standing consent there is no card to catch a repeated
            // consequential action — an identical step is not run a second time.
            if seen == 2 && headless && calls.contains(where: { c in (ToolRegistry.tool(named: c.name)?.confirmation == .confirm) || mcpMap[c.name] != nil || ["run_recipe", "click_element", "save_automation", "run_automation", "delete_automation"].contains(c.name) }) {
                agentLog.info("runToolLoop: repeated consequential step in an unattended run — not run again")
                feedback(calls.map { StepResult(call: $0, content: "Not run again: this is identical to the previous step, whose result is above. If it is done, say so.", isError: false, image: nil) })
                continue
            }

            var results: [StepResult] = []
            var declined = false
            for call in calls {
                if Task.isCancelled { return done("", cancelled: true) }
                if declined {   // every call in the step still needs a result
                    results.append(StepResult(call: call, content: "Skipped — the user declined the previous action.", isError: true, image: nil))
                    continue
                }
                // A name that isn't in this run's tool list (the prose guide names tools the
                // list may not carry): answer at once instead of walking the consent paths.
                if !offered.contains(call.name) {
                    results.append(StepResult(call: call, content: "Not available in this run: \(call.name). Use only the tools in your tool list.", isError: true, image: nil))
                    continue
                }
                switch call.name {
                case "recapture_screen":
                    if !AIConfig.visionAvailable {
                        results.append(StepResult(call: call, content: SeeSettings.unsupportedNote, isError: false, image: nil)); continue
                    }
                    if let cap = await captureCurrentScreen(into: conversation) {
                        // Pixels leave here too — the same consent as the user-message screenshot.
                        var allowed = true
                        if headless {
                            allowed = policy.standingConsent
                        } else if SeeSettings.askBeforeSend {
                            if conversation.screenSendDecision == nil {
                                conversation.screenSendDecision = await awaitConfirmation(in: conversation, title: "Send a screenshot?",
                                    rows: [("Of", conversation.capturedAppName ?? "the screen"), ("To", AIConfig.providerDisplayName)], label: "send_screenshot")
                                if Task.isCancelled { return done("", cancelled: true) }
                            }
                            allowed = conversation.screenSendDecision == true
                        }
                        if allowed {
                            conversation.markScreenshot(.sent(provider: AIConfig.provider?.shortName ?? "the provider"))
                            NotchController.shared.flashSeeing()
                            results.append(StepResult(call: call, content: "Re-captured the current screen (\(Int(cap.pixelSize.width))×\(Int(cap.pixelSize.height)) px) — the screenshot is attached, and the on-screen element list is refreshed.", isError: false, image: AIImage.jpegData(cap.image)))
                        } else {
                            conversation.markScreenshot(.withheldDeclined)
                            results.append(StepResult(call: call, content: headless ? Self.refusedNote : SeeSettings.declinedNote + " The on-screen element list was refreshed; read_window still works.", isError: false, image: nil))
                        }
                    } else if let withheld = conversation.takeCaptureWithheld(), case .withheldExcluded(let app) = withheld {
                        results.append(StepResult(call: call, content: "Not captured: \(app) is on the user's excluded-apps list. Say so if the answer needs the screen.", isError: false, image: nil))
                    } else {
                        results.append(StepResult(call: call, content: "Couldn't recapture the screen.", isError: true, image: nil))
                    }
                case "click_element":
                    // The validated pointing path, mid-loop: highlight → card → press.
                    guard let idx = Self.intArg(call.args["index"]) else {
                        results.append(StepResult(call: call, content: "click_element needs an integer index from read_window.", isError: true, image: nil)); continue
                    }
                    if headless && !policy.standingConsent { results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil)); continue }
                    switch await performClick(index: idx, conversation: conversation, autoApprove: headless) {
                    case .outOfRange:
                        results.append(StepResult(call: call, content: "Index \(idx) is out of range (\(conversation.axElements.count) elements known). Call read_window first, then use one of its numbers.", isError: true, image: nil))
                    case .cancelled:
                        return done("", cancelled: true)
                    case .declined:
                        declined = true; lastToolSummary = "Okay — I won't click it."
                        results.append(StepResult(call: call, content: "The user declined the click.", isError: false, image: nil))
                    case .clicked(let label, let method):
                        lastToolSummary = "Clicked “\(label)”."
                        results.append(StepResult(call: call, content: "Clicked “\(label)” (\(method)). Call read_window or recapture_screen to see the result.", isError: false, image: nil))
                    case .failed(let label, let why):
                        results.append(StepResult(call: call, content: "Found “\(label)” but couldn't click it (\(why)).", isError: true, image: nil))
                    }
                case "list_automations":
                    results.append(StepResult(call: call, content: AgentTools.listAutomations(), isError: false, image: nil))
                case "save_automation":
                    let goal = (call.args["goal"] as? String) ?? ""
                    guard !goal.isEmpty else { results.append(StepResult(call: call, content: "save_automation needs a goal.", isError: true, image: nil)); continue }
                    let sched = (call.args["schedule"] as? [String: Any]).flatMap { Self.scheduleFrom($0.merging(["task": goal]) { a, _ in a }) }?.schedule
                    let trig = (call.args["trigger"] as? [String: Any]).flatMap { Self.triggerFrom($0.merging(["task": goal]) { a, _ in a }) }?.trigger
                    guard sched != nil || trig != nil else { results.append(StepResult(call: call, content: "save_automation needs a schedule or a trigger.", isError: true, image: nil)); continue }
                    // Standing consent is a human decision on a card — an unattended run
                    // (even one that has consent itself) can only create read-only automations.
                    let consent = headless ? false : ((call.args["standing_consent"] as? Bool) ?? false)
                    let name = (call.args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Automation.routineName(goal)
                    let when = [sched?.describe, trig?.describe].compactMap { $0 }.joined(separator: " and ")
                    let approval = await approve(title: "Save automation?",
                                                 rows: [("Name", name), ("When", when), ("Does", goal),
                                                        ("May act without asking", consent ? "Yes — standing consent" : "No — read-only; it says when something needs your OK")],
                                                 label: "save-automation")
                    if Task.isCancelled { return done("", cancelled: true) }
                    switch approval {
                    case .refused: results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil))
                    case .declined: declined = true; lastToolSummary = "Okay, I didn't save it."; results.append(StepResult(call: call, content: "The user declined.", isError: false, image: nil))
                    case .approved:
                        let a = Automation(id: UUID().uuidString, name: name, recipeId: "", paramsJSON: "{}", schedule: sched, trigger: trig,
                                           routineGoal: goal, policy: AgentPolicy(standingConsent: consent))
                        AutomationStore.shared.add(a); TriggerEngine.shared.refresh()
                        Task { await AuditLog.shared.record(tool: "save_automation", argsJSON: call.argsJSON, outcome: "ok", summary: name, confirmed: true) }
                        conversation.addToolChip(name: "save_automation", inputJSON: call.argsJSON, content: "Saved “\(name)” — \(when)", isError: false, displaySummary: "Automation saved")
                        lastToolSummary = "Saved “\(name)” — \(when)."
                        results.append(StepResult(call: call, content: "Saved automation “\(name)” (id \(a.id)) — \(when).", isError: false, image: nil))
                    }
                case "run_automation", "delete_automation":
                    let id = (call.args["id"] as? String) ?? ""
                    guard let a = AutomationStore.shared.automations.first(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else {
                        results.append(StepResult(call: call, content: "No automation with id or name \"\(id)\". Call list_automations.", isError: true, image: nil)); continue
                    }
                    let isDelete = call.name == "delete_automation"
                    if !isDelete && (policy.depth >= 2 || runningAutomationIDs.contains(a.id)) {
                        results.append(StepResult(call: call, content: "Not run: “\(a.name)” is already running or this run is nested too deep.", isError: true, image: nil)); continue
                    }
                    let approval = await approve(title: isDelete ? "Delete automation?" : "Run automation now?",
                                                 rows: [("Name", a.name), ("Does", a.routineGoal ?? "recipe \(a.recipeId)")], label: call.name, destructive: isDelete)
                    if Task.isCancelled { return done("", cancelled: true) }
                    switch approval {
                    case .refused: results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil))
                    case .declined: declined = true; lastToolSummary = "Okay, I've left it alone."; results.append(StepResult(call: call, content: "The user declined.", isError: false, image: nil))
                    case .approved:
                        if isDelete {
                            AutomationStore.shared.remove(id: a.id); TriggerEngine.shared.refresh()
                            Task { await AuditLog.shared.record(tool: "delete_automation", argsJSON: call.argsJSON, outcome: "ok", summary: a.name, confirmed: true) }
                            lastToolSummary = "Deleted “\(a.name)”."
                            results.append(StepResult(call: call, content: "Deleted automation “\(a.name)”.", isError: false, image: nil))
                        } else {
                            await runAutomation(a, depth: policy.depth + 1)
                            lastToolSummary = "Ran “\(a.name)”."
                            results.append(StepResult(call: call, content: "Ran “\(a.name)” — its result was delivered under the notch and audited.", isError: false, image: nil))
                        }
                    }
                case "run_subagent":
                    let goal = (call.args["goal"] as? String) ?? ""
                    guard !goal.isEmpty else { results.append(StepResult(call: call, content: "run_subagent needs a goal.", isError: true, image: nil)); continue }
                    guard policy.depth < 2 else { results.append(StepResult(call: call, content: "Sub-agents can't start sub-agents this deep — do the task yourself.", isError: true, image: nil)); continue }
                    let allowed = call.args["tools"] as? [String]
                    let steps = Self.intArg(call.args["max_steps"]) ?? 10
                    let approval = await approve(title: "Start a sub-agent?",
                                                 rows: [("Goal", goal), ("Tools", allowed?.joined(separator: ", ") ?? "read-only tools"), ("Steps", "up to \(min(steps, 15))")],
                                                 label: "run_subagent")
                    if Task.isCancelled { return done("", cancelled: true) }
                    switch approval {
                    case .refused: results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil))
                    case .declined: declined = true; lastToolSummary = "Okay."; results.append(StepResult(call: call, content: "The user declined.", isError: false, image: nil))
                    case .approved:
                        let child = policy.child(allowedTools: allowed, maxSteps: steps, label: (policy.label ?? "turn") + "/subagent")
                        let convo = Conversation(chatWithApp: "")
                        convo.addUserMessage(goal)
                        agentLog.info("subagent: start depth=\(child.depth) steps=\(child.maxSteps) goal=\"\(goal.prefix(80), privacy: .public)\"")
                        let run = await runAgentLoop(in: convo, goal: goal, policy: child, headless: true, inheritedMCP: (mcpTools, mcpMap))
                        spentUSD += run.costUSD   // the child's spend counts against this turn's budget
                        let answer = run.text
                        agentLog.info("subagent: done — \(answer.prefix(120), privacy: .public)")
                        conversation.addToolChip(name: "run_subagent", inputJSON: call.argsJSON, content: answer, isError: answer.isEmpty, displaySummary: "Sub-agent finished")
                        lastToolSummary = answer
                        results.append(StepResult(call: call, content: answer.isEmpty ? "(the sub-agent returned nothing)" : "Sub-agent result:\n" + answer, isError: answer.isEmpty, image: nil))
                    }
                case "run_in_background":
                    let goal = (call.args["goal"] as? String) ?? ""
                    guard !goal.isEmpty else { results.append(StepResult(call: call, content: "run_in_background needs a goal.", isError: true, image: nil)); continue }
                    let approval = await approve(title: "Run in the background?", rows: [("Goal", goal), ("Note", "Read-only; the result appears under the notch when it's done.")], label: "run_in_background")
                    if Task.isCancelled { return done("", cancelled: true) }
                    switch approval {
                    case .refused: results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil))
                    case .declined: declined = true; lastToolSummary = "Okay."; results.append(StepResult(call: call, content: "The user declined.", isError: false, image: nil))
                    case .approved:
                        let id = TaskLedger.shared.start(goal: goal)
                        let bg = policy.child(allowedTools: nil, maxSteps: 15, label: "task:\(id)")
                        let mcp = (mcpTools, mcpMap)
                        Task { await AuditLog.shared.record(tool: "task:\(id)", argsJSON: call.argsJSON, outcome: "started", summary: String(goal.prefix(80)), confirmed: !headless) }
                        let handle = Task { @MainActor [weak self] in
                            guard let self else { return }
                            let convo = Conversation(chatWithApp: "")
                            convo.addUserMessage(goal + "\n\n(Deliver the result short and glanceable — it appears under the notch.)")
                            let run = await self.runAgentLoop(in: convo, goal: goal, policy: bg, headless: true, inheritedMCP: mcp)
                            if run.cancelled || Task.isCancelled { return }
                            TaskLedger.shared.finish(id: id, result: run.text, costUSD: run.costUSD)
                            await AuditLog.shared.record(tool: "task:\(id)", argsJSON: "{}", outcome: run.text.isEmpty ? "error" : "ok", summary: "\(AICost.format(run.costUSD)) · \(run.text.prefix(80))", confirmed: false)
                            NotchController.shared.notifyResult(run.text.isEmpty ? "Background task finished with no result." : run.text)
                            agentLog.info("background \(id, privacy: .public): done — \(run.text.prefix(100), privacy: .public)")
                        }
                        TaskLedger.shared.attach(id: id, task: handle)
                        conversation.addToolChip(name: "run_in_background", inputJSON: call.argsJSON, content: "Started task \(id)", isError: false, displaySummary: "Running in background")
                        lastToolSummary = "Started in the background."
                        results.append(StepResult(call: call, content: "Started background task \(id). Tell the user it's running and that the result will appear under the notch; don't wait for it.", isError: false, image: nil))
                    }
                case "run_recipe":
                    let id = (call.args["id"] as? String) ?? ""
                    let params = (call.args["params"] as? [String: Any]) ?? [:]
                    if headless && !policy.standingConsent { results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil)); continue }
                    let r = await performRecipe(id: id, params: params, conversation: conversation, autoApprove: headless, auditLabel: policy.label)
                    if Task.isCancelled { return done("", cancelled: true) }
                    if r.declined { declined = true; lastToolSummary = "Okay, I've left that alone." } else if !r.isError { lastToolSummary = r.content }
                    results.append(StepResult(call: call, content: r.content, isError: r.isError, image: nil))
                default:
                    if let info = mcpMap[call.name] {   // a configured MCP tool — always confirmed
                        let label = "mcp:\(info.server).\(info.name)"
                        let argsJSON = call.argsJSON
                        let approval = await approve(title: confirmTitle(info.name),
                                                     rows: [("Connector", info.server), ("Tool", info.name)] + confirmRows(args: call.args), label: label)
                        if Task.isCancelled { return done("", cancelled: true) }
                        if approval == .refused { results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil)); continue }
                        guard approval == .approved else {
                            Task { await AuditLog.shared.record(tool: label, argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
                            declined = true; lastToolSummary = "Okay, I've left that alone."
                            results.append(StepResult(call: call, content: "The user declined this action.", isError: false, image: nil)); continue
                        }
                        do {
                            let output = try await MCPService.shared.callConfiguredTool(server: info.server, name: info.name, arguments: call.args)
                            Task { await AuditLog.shared.record(tool: auditName(label), argsJSON: argsJSON, outcome: "ok", summary: info.name, confirmed: !headless && !TrustSettings.isTrusted(label)) }
                            let summary = "\(info.server): \(info.name.replacingOccurrences(of: "_", with: " "))"
                            conversation.addToolChip(name: label, inputJSON: argsJSON, content: output.isEmpty ? "Done." : output, isError: false, displaySummary: summary)
                            lastToolSummary = output.isEmpty ? "Done — \(summary)." : output
                            results.append(StepResult(call: call, content: output.isEmpty ? "Done." : output, isError: false, image: nil))
                        } catch {
                            Task { await AuditLog.shared.record(tool: auditName(label), argsJSON: argsJSON, outcome: "error", summary: error.localizedDescription, confirmed: !headless) }
                            results.append(StepResult(call: call, content: "That didn't work — \(error.localizedDescription)", isError: true, image: nil))
                        }
                        continue
                    }
                    // Registry tools. `.confirm` (write/send/destructive) tools wait for
                    // the confirm card; `.auto` (read-only) tools execute immediately.
                    guard let tool = ToolRegistry.tool(named: call.name) else {
                        results.append(StepResult(call: call, content: "Unknown tool '\(call.name)'.", isError: true, image: nil))
                        continue
                    }
                    let argsJSON = call.argsJSON
                    var approval = Approval.approved
                    if tool.confirmation == .confirm {
                        approval = await approve(title: confirmTitle(call.name), rows: confirmRows(args: call.args), label: call.name,
                                                 destructive: ["delete_file", "move_file", "run_shell"].contains(call.name))
                        if Task.isCancelled { return done("", cancelled: true) }
                    }
                    if approval == .refused {
                        results.append(StepResult(call: call, content: Self.refusedNote, isError: false, image: nil)); continue
                    }
                    if approval == .approved {
                        let r = await ToolRegistry.execute(name: call.name, args: call.args, in: conversation)
                        // Audit trail — every executed tool, recorded locally.
                        Task { await AuditLog.shared.record(tool: auditName(call.name), argsJSON: argsJSON, outcome: r.isError ? "error" : "ok", summary: r.displaySummary ?? String(r.content.prefix(80)), confirmed: !headless && tool.confirmation == .confirm && !TrustSettings.isTrusted(call.name)) }
                        if !r.isError {
                            lastToolSummary = r.content
                            // Transparency: a chip for what ran — SUCCESSES only, so intermediate
                            // retry failures (wrong path, etc.) don't clutter the transcript.
                            conversation.addToolChip(name: call.name, inputJSON: argsJSON, content: r.content, isError: false, displaySummary: r.displaySummary)
                        }
                        var hint = ""
                        if r.isError {
                            // Self-correct: steer a FIXED retry, not an apology.
                            hint = "\n\nThis failed. Fix the cause and call \(call.name) again with corrected input — do NOT repeat the same failing call. If it genuinely can't be done, say so briefly in plain text."
                            // Failed AppleScript → inject the target app's REAL dictionary so the
                            // corrected script uses valid vocabulary (sdef subprocess, fetched off-main).
                            if call.name == "run_applescript", let script = call.args["script"] as? String,
                               let app = AppleScriptDictionary.appName(in: script),
                               let dict = await Task.detached(priority: .userInitiated,
                                                              operation: { AppleScriptDictionary.condensed(forApp: app) }).value {
                                hint += "\n\n\(dict)"
                            }
                        }
                        results.append(StepResult(call: call, content: r.content + hint, isError: r.isError, image: r.attachedImage.flatMap { AIImage.jpegData($0) }))
                    } else {
                        Task { await AuditLog.shared.record(tool: call.name, argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
                        declined = true   // the user cancelled — finish the step's bookkeeping, then stop, never re-prompt
                        lastToolSummary = "Okay, I've left that alone."
                        results.append(StepResult(call: call, content: "The user declined this action.", isError: false, image: nil))
                    }
                }
            }
            feedback(results, note: seen == 2 ? "[You already ran exactly this in the previous step and its result is above. Don't repeat a call unless something changed — if you have what you need, answer in plain text.]" : nil)
            if declined {
                return await forceFinalAnswer("[The user declined that action. Acknowledge briefly, say what (if anything) was already done, and stop — do not retry.]")
            }
        }
        return done("")   // unreachable: the step/budget guard above always returns first
    }

    /// Repeat-guard signature: tool name + NORMALIZED args. Byte-identical
    /// comparison missed real repeats (the 4B's
    /// first call carried "+02: soul" — corrupted text inside the timezone
    /// offset that the lenient date parser still accepted — so the clean
    /// second call didn't match and ran again → two chips). Any value that
    /// parses as a date collapses to its wall-clock MINUTE; everything else
    /// lowercases and trims, so same-intent re-calls match regardless of the
    /// model's textual jitter.
    static func callSignature(name: String, args: [String: Any]) -> String {
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
