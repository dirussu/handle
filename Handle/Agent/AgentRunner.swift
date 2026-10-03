import AppKit
import OSLog

/// One run of the agent loop.
///
/// The same loop serves a chat turn, a sub-agent, a routine and a background task. What
/// differs between them is the policy (allowed tools, step cap, budget, standing consent)
/// and whether a person is there to answer a confirmation card: `headless` means nobody is.
///
/// Each step asks the model what to do next. If it answers in text, the run is over. If it
/// calls tools, every call in that step is carried out and all results go back together.
final class AgentRunner {
    typealias Connectors = (tools: [Tool], map: [String: MCPToolInfo])

    private unowned let app: AppDelegate
    private let conversation: Conversation
    private let goal: String
    private let policy: AgentPolicy
    private let headless: Bool
    private let inheritedConnectors: Connectors?

    // Fixed for the whole run; set in `prepare()`.
    private var usesNativeTools = false
    private var connectors: Connectors = ([], [:])
    private var toolset: [Tool] = []
    private var offered: Set<String> = []
    private var webSpecs: [AIToolSpec] = []
    private var turnPrefix = ""

    // Changes as the run goes on.
    private var spentUSD = 0.0
    /// With native tool calls: this run's calls and results so far.
    private var history: [AIMessage] = []
    /// Without native tool calls: the last step's results, prefixed to the next prompt.
    private var pendingResult = ""
    /// Shown when the model ends a run without saying anything.
    private var lastToolSummary = ""
    private var repeatGuard = RepeatGuard()
    private var retriedEmptyReply = false

    init(app: AppDelegate, conversation: Conversation, goal: String, policy: AgentPolicy, headless: Bool,
         inheritedConnectors: Connectors? = nil) {
        self.app = app
        self.conversation = conversation
        self.goal = goal
        self.policy = policy
        self.headless = headless
        self.inheritedConnectors = inheritedConnectors
    }

    /// Nobody is there to confirm and the automation was not given standing consent.
    private var readOnly: Bool { headless && !policy.standingConsent }

    // MARK: - The loop

    func run() async -> AgentRun {
        await prepare()
        defer {
            if usesNativeTools { conversation.pendingMemory = ""; conversation.pendingContextPreamble = "" }
        }
        for step in 0... {
            if Task.isCancelled { return finish("", cancelled: true) }
            if let limit = AgentSettings.stopReason(step: step, maxSteps: policy.maxSteps, spentUSD: spentUSD, budgetUSD: policy.budgetUSD) {
                agentLog.info("agent: \(limit, privacy: .public) after \(step) step(s), \(AICost.format(self.spentUSD), privacy: .public) — asking for the final answer")
                return await finalAnswer(note: "[\(limit). Give your final answer now in plain text, no tools — say what is done and what is not.]")
            }

            let reply = await nextStep()
            guard !reply.calls.isEmpty else { return await answer(with: reply) }
            agentLog.info("agent: step \(step) → \(reply.calls.count) call(s): \(reply.calls.map { "\($0.name)\($0.args.isEmpty ? "" : String(describing: $0.args))" }.joined(separator: " | "), privacy: .public)")
            record(reply)

            switch checkForRepeat(reply.calls) {
            case .stop:
                return await finalAnswer(note: "[You have made the same call three times. Do not call any tool again — give your final answer now in plain text, saying what is done and what is not.]")
            case .skip:
                continue
            case .proceed(let repeated):
                guard let outcome = await carryOut(reply.calls) else { return finish("", cancelled: true) }
                feedBack(outcome.results, note: repeated ? "[You already ran exactly this in the previous step and its result is above. Don't repeat a call unless something changed — if you have what you need, answer in plain text.]" : nil)
                if outcome.declined {
                    return await finalAnswer(note: "[The user declined that action. Acknowledge briefly, say what (if anything) was already done, and stop — do not retry.]")
                }
            }
        }
        return finish("")   // not reached: the limit check above always ends the run first
    }

    private func prepare() async {
        usesNativeTools = AIConfig.nativeTools
        // Connectors are discovered once per user turn; a child run reuses its parent's.
        if let inheritedConnectors {
            connectors = inheritedConnectors
        } else {
            connectors = MCPLoopTools.make(await MCPService.shared.allConfiguredTools())
        }
        // A read-only run is not even offered the tools that act, so there is nothing to
        // refuse and the prompt is much smaller.
        toolset = (ToolRegistry.all + connectors.tools + [AppDelegate.runRecipeTool] + AgentTools.tools).filter { tool in
            policy.allows(tool.name) && !TrustSettings.isDisabled(tool.name)
                && !(readOnly && (tool.confirmation == .confirm || ScreenTools.sideEffectingAutoTools.contains(tool.name)))
        }
        offered = Set(toolset.map(\.name))
        // The screenshot tool sends pixels to the provider, so a read-only run does not get it.
        if !readOnly && AIConfig.visionAvailable { offered.insert("recapture_screen") }
        webSpecs = (AIConfig.provider == .anthropic && WebSettings.searchEnabled) ? [WebSettings.anthropicSearchSpec] : []

        let readOnlyNote = readOnly
            ? "This run is unattended and read-only: only the tools in your tool list exist for it. Tools the guide mentions but the list doesn't (writing, shell, scripts, drafts, clicks) are unavailable — don't call them; say what you couldn't do."
            : ""
        let recipes = readOnly ? "" : AppDelegate.recipeCandidatesLine(for: goal)
        // The system prompt stays identical across steps and turns so the provider can cache
        // it. Anything that changes per turn, like the clock, goes in this prefix instead.
        turnPrefix = [usesNativeTools ? AppDelegate.currentTimeLine() : "", readOnlyNote, recipes]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Asks the model for the next step.
    private func nextStep() async -> TurnOutput {
        let reply: TurnOutput
        if usesNativeTools {
            reply = await app.streamTurn(in: conversation, rules: app.actionToolInstruction(native: true), instr: turnPrefix, display: false,
                                         tools: toolset, extraSpecs: webSpecs, loopHistory: history, consumeSlots: false, effort: policy.effort)
        } else {
            let instructions = [turnPrefix, app.actionToolInstruction(), pendingResult].filter { !$0.isEmpty }.joined(separator: "\n\n")
            pendingResult = ""
            reply = await app.streamTurn(in: conversation, instr: instructions, display: false, tools: toolset, effort: policy.effort)
        }
        spend(reply)
        return reply
    }

    /// The model answered in text: that is the result of the run.
    private func answer(with reply: TurnOutput) async -> AgentRun {
        if reply.text.isEmpty && reply.stopReason == "max_tokens" && !retriedEmptyReply {
            // The whole output budget went to reasoning before any text. Ask once more, plainly.
            retriedEmptyReply = true
            agentLog.info("agent: reply cut off with no text — asking once for a plain-text answer")
            return await finalAnswer(note: "[Your previous reply was cut off before any text. Answer now in plain text, concisely.]")
        }
        let text = reply.text.isEmpty ? lastToolSummary : reply.text
        conversation.commitAssistantMessage(text)
        return finish(text)
    }

    /// One more request with no tools, which ends the run with a plain-text answer.
    private func finalAnswer(note: String) async -> AgentRun {
        let reply: TurnOutput
        if usesNativeTools {
            reply = await app.streamTurn(in: conversation, rules: app.actionToolInstruction(native: true), instr: turnPrefix,
                                         loopHistory: history + [AIMessage.user(note)], effort: policy.effort)
        } else {
            let instructions = [turnPrefix, pendingResult, note].filter { !$0.isEmpty }.joined(separator: "\n\n")
            reply = await app.streamTurn(in: conversation, instr: instructions, effort: policy.effort)
        }
        spend(reply)
        return finish(reply.text, cancelled: Task.isCancelled)
    }

    /// Every exit goes through here, so the result always carries the cost.
    private func finish(_ text: String, cancelled: Bool = false) -> AgentRun {
        AgentRun(text: text, costUSD: spentUSD, cancelled: cancelled)
    }

    /// Adds one request's cost to the run's total. Models without a known price count as zero.
    private func spend(_ reply: TurnOutput) {
        guard let usage = reply.usage else { return }
        spentUSD += AICost.estimate(model: CloudEngine.shared.lastModel, input: usage.input, output: usage.output,
                                    cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite) ?? 0
    }

    // MARK: - History

    private struct StepResult {
        let call: AgentToolCall
        let content: String
        var isError = false
        var image: Data? = nil
    }

    private func success(_ call: AgentToolCall, _ content: String, image: Data? = nil) -> StepResult {
        StepResult(call: call, content: content, isError: false, image: image)
    }

    private func failure(_ call: AgentToolCall, _ content: String) -> StepResult {
        StepResult(call: call, content: content, isError: true)
    }

    /// Puts the model's own calls on the record before their results.
    private func record(_ reply: TurnOutput) {
        guard usesNativeTools else { return }
        var parts: [AIMessage.Part] = []
        if !reply.text.isEmpty { parts.append(.text(reply.text)) }
        for call in reply.calls { parts.append(.toolCall(id: call.id, name: call.name, argumentsJSON: call.argsJSON)) }
        history.append(AIMessage(role: .assistant, parts: parts))
    }

    /// Sends a step's results back to the model.
    private func feedBack(_ results: [StepResult], note: String? = nil) {
        if usesNativeTools {
            // A new screenshot replaces the older ones: each costs tokens on every later step.
            if results.contains(where: { $0.image != nil }) { history = AgentPrompting.stripImages(from: history) }
            var parts: [AIMessage.Part] = results.map { .toolResult(id: $0.call.id, text: $0.content, isError: $0.isError, image: $0.image) }
            if let note { parts.append(.text(note)) }
            history.append(AIMessage(role: .user, parts: parts))
        } else {
            pendingResult = results.map { app.toolResultText($0.call.name, $0.content, isError: $0.isError) }.joined(separator: "\n\n")
            if let note { pendingResult += "\n\n" + note }
        }
    }

    // MARK: - Repeats

    private enum RepeatVerdict {
        case proceed(repeated: Bool)
        case skip
        case stop
    }

    /// The same step twice in a row earns a hint, three times ends the run. A real re-check
    /// after something changed has different arguments, so it is not a repeat.
    private func checkForRepeat(_ calls: [AgentToolCall]) -> RepeatVerdict {
        let signature = calls.map { RepeatGuard.signature(name: $0.name, args: $0.args) }.joined(separator: " | ")
        let seen = repeatGuard.observe(signature)
        if seen >= 3 {
            agentLog.info("agent: same step three times — asking for the final answer")
            feedBack(calls.map { success($0, "(not run again — identical to the previous call; its result is above)") })
            return .stop
        }
        // With standing consent and nobody watching, no card would catch a repeated action,
        // so an identical step that acts is not run a second time.
        if seen == 2 && headless && calls.contains(where: actsOnTheMac) {
            agentLog.info("agent: repeated action in an unattended run — not run again")
            feedBack(calls.map { success($0, "Not run again: this is identical to the previous step, whose result is above. If it is done, say so.") })
            return .skip
        }
        return .proceed(repeated: seen == 2)
    }

    private func actsOnTheMac(_ call: AgentToolCall) -> Bool {
        ToolRegistry.tool(named: call.name)?.confirmation == .confirm
            || connectors.map[call.name] != nil
            || ["run_recipe", "click_element", "save_automation", "run_automation", "delete_automation"].contains(call.name)
    }

    // MARK: - Carrying out a step

    private enum Outcome {
        case done(StepResult)
        /// The user said no on a card. The step is finished, then the run ends.
        case declined(StepResult)
        case cancelled
    }

    /// Carries out every call of one step. Returns nil if the run was cancelled meanwhile.
    private func carryOut(_ calls: [AgentToolCall]) async -> (results: [StepResult], declined: Bool)? {
        var results: [StepResult] = []
        var declined = false
        for call in calls {
            if Task.isCancelled { return nil }
            if declined {   // every call still needs a result
                results.append(failure(call, "Skipped — the user declined the previous action."))
                continue
            }
            // The written tool guide names tools this run may not have. Answer such a call
            // at once instead of walking the consent path.
            guard offered.contains(call.name) else {
                results.append(failure(call, "Not available in this run: \(call.name). Use only the tools in your tool list."))
                continue
            }
            switch await perform(call) {
            case .cancelled: return nil
            case .done(let result): results.append(result)
            case .declined(let result): results.append(result); declined = true
            }
        }
        return (results, declined)
    }

    private func perform(_ call: AgentToolCall) async -> Outcome {
        switch call.name {
        case "recapture_screen": return await recaptureScreen(call)
        case "click_element": return await clickElement(call)
        case "list_automations": return .done(success(call, AgentTools.listAutomations()))
        case "save_automation": return await saveAutomation(call)
        case "run_automation", "delete_automation": return await runOrDeleteAutomation(call)
        case "run_subagent": return await runSubagent(call)
        case "run_in_background": return await runInBackground(call)
        case "run_recipe": return await runRecipe(call)
        default:
            if let connector = connectors.map[call.name] { return await callConnector(call, connector) }
            guard let tool = ToolRegistry.tool(named: call.name) else { return .done(failure(call, "Unknown tool '\(call.name)'.")) }
            return await callBuiltIn(call, tool)
        }
    }

    // MARK: - Consent

    private enum Approval { case approved, declined, refused }

    /// Consent for an action: a card when someone is at the notch, the automation's standing
    /// consent when nobody is, and a refusal otherwise.
    private func approve(title: String, rows: [(label: String, value: String)], label: String, destructive: Bool = false) async -> Approval {
        if headless {
            if policy.standingConsent {
                agentLog.info("consent: standing — \(label, privacy: .public)")
                return .approved
            }
            agentLog.info("consent: refused (unattended, no standing consent) — \(label, privacy: .public)")
            return .refused
        }
        if TrustSettings.isTrusted(label) {   // "Don't ask" in Settings → Tools
            agentLog.info("consent: trusted, no card — \(label, privacy: .public)")
            return .approved
        }
        let approved = await app.awaitConfirmation(in: conversation, title: title, rows: rows, label: label, destructive: destructive)
        return approved ? .approved : .declined
    }

    /// The name a tool run is audited under inside this run, such as "routine:Morning › run_shell".
    private func auditName(_ tool: String) -> String {
        policy.label.map { "\($0) › \(tool)" } ?? tool
    }

    // MARK: - Screen

    private func recaptureScreen(_ call: AgentToolCall) async -> Outcome {
        guard AIConfig.visionAvailable else { return .done(success(call, SeeSettings.unsupportedNote)) }
        guard let capture = await app.captureCurrentScreen(into: conversation) else {
            if let withheld = conversation.takeCaptureWithheld(), case .withheldExcluded(let excludedApp) = withheld {
                return .done(success(call, "Not captured: \(excludedApp) is on the user's excluded-apps list. Say so if the answer needs the screen."))
            }
            return .done(failure(call, "Couldn't recapture the screen."))
        }
        // A screenshot leaves the Mac here, so it needs the same consent as one attached to a message.
        var allowed = true
        if headless {
            allowed = policy.standingConsent
        } else if SeeSettings.askBeforeSend {
            if conversation.screenSendDecision == nil {
                conversation.screenSendDecision = await app.awaitConfirmation(
                    in: conversation, title: "Send a screenshot?",
                    rows: [("Of", conversation.capturedAppName ?? "the screen"), ("To", AIConfig.providerDisplayName)], label: "send_screenshot")
                if Task.isCancelled { return .cancelled }
            }
            allowed = conversation.screenSendDecision == true
        }
        guard allowed else {
            conversation.markScreenshot(.withheldDeclined)
            return .done(success(call, headless ? AppDelegate.refusedNote : SeeSettings.declinedNote + " The on-screen element list was refreshed; read_window still works."))
        }
        conversation.markScreenshot(.sent(provider: AIConfig.provider?.shortName ?? "the provider"))
        NotchController.shared.flashSeeing()
        return .done(success(call, "Re-captured the current screen (\(Int(capture.pixelSize.width))×\(Int(capture.pixelSize.height)) px) — the screenshot is attached, and the on-screen element list is refreshed.",
                             image: AIImage.jpegData(capture.image)))
    }

    /// Clicks an element by its index from `read_window`: highlight, card, press.
    private func clickElement(_ call: AgentToolCall) async -> Outcome {
        guard let index = ToolCallParser.intArg(call.args["index"]) else {
            return .done(failure(call, "click_element needs an integer index from read_window."))
        }
        if readOnly { return .done(success(call, AppDelegate.refusedNote)) }
        switch await app.performClick(index: index, conversation: conversation, autoApprove: headless) {
        case .outOfRange:
            return .done(failure(call, "Index \(index) is out of range (\(conversation.axElements.count) elements known). Call read_window first, then use one of its numbers."))
        case .cancelled:
            return .cancelled
        case .declined:
            lastToolSummary = "Okay — I won't click it."
            return .declined(success(call, "The user declined the click."))
        case .clicked(let label, let method):
            lastToolSummary = "Clicked “\(label)”."
            return .done(success(call, "Clicked “\(label)” (\(method)). Call read_window or recapture_screen to see the result."))
        case .failed(let label, let why):
            return .done(failure(call, "Found “\(label)” but couldn't click it (\(why))."))
        }
    }

    // MARK: - Automations

    private func saveAutomation(_ call: AgentToolCall) async -> Outcome {
        let goal = call.args["goal"] as? String ?? ""
        guard !goal.isEmpty else { return .done(failure(call, "save_automation needs a goal.")) }
        let schedule = (call.args["schedule"] as? [String: Any]).flatMap { AppDelegate.scheduleFrom($0.merging(["task": goal]) { a, _ in a }) }?.schedule
        let trigger = (call.args["trigger"] as? [String: Any]).flatMap { AppDelegate.triggerFrom($0.merging(["task": goal]) { a, _ in a }) }?.trigger
        guard schedule != nil || trigger != nil else { return .done(failure(call, "save_automation needs a schedule or a trigger.")) }

        // Standing consent is a person's decision on a card. An unattended run, even one that
        // has consent itself, can only create read-only automations.
        let consent = headless ? false : (call.args["standing_consent"] as? Bool ?? false)
        let name = (call.args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Automation.routineName(goal)
        let when = [schedule?.describe, trigger?.describe].compactMap { $0 }.joined(separator: " and ")
        let approval = await approve(
            title: "Save automation?",
            rows: [("Name", name), ("When", when), ("Does", goal),
                   ("May act without asking", consent ? "Yes — standing consent" : "No — read-only; it says when something needs your OK")],
            label: "save-automation")
        if Task.isCancelled { return .cancelled }

        switch approval {
        case .refused:
            return .done(success(call, AppDelegate.refusedNote))
        case .declined:
            lastToolSummary = "Okay, I didn't save it."
            return .declined(success(call, "The user declined."))
        case .approved:
            let automation = Automation(id: UUID().uuidString, name: name, recipeId: "", paramsJSON: "{}", schedule: schedule, trigger: trigger,
                                        routineGoal: goal, policy: AgentPolicy(standingConsent: consent))
            AutomationStore.shared.add(automation)
            TriggerEngine.shared.refresh()
            Task { await AuditLog.shared.record(tool: "save_automation", argsJSON: call.argsJSON, outcome: "ok", summary: name, confirmed: true) }
            conversation.addToolChip(name: "save_automation", inputJSON: call.argsJSON, content: "Saved “\(name)” — \(when)", isError: false, displaySummary: "Automation saved")
            lastToolSummary = "Saved “\(name)” — \(when)."
            return .done(success(call, "Saved automation “\(name)” (id \(automation.id)) — \(when)."))
        }
    }

    private func runOrDeleteAutomation(_ call: AgentToolCall) async -> Outcome {
        let id = call.args["id"] as? String ?? ""
        guard let automation = AutomationStore.shared.automations.first(where: { $0.id == id || $0.name.lowercased() == id.lowercased() }) else {
            return .done(failure(call, "No automation with id or name \"\(id)\". Call list_automations."))
        }
        let isDelete = call.name == "delete_automation"
        if !isDelete && (policy.depth >= 2 || app.runningAutomationIDs.contains(automation.id)) {
            return .done(failure(call, "Not run: “\(automation.name)” is already running or this run is nested too deep."))
        }
        let approval = await approve(title: isDelete ? "Delete automation?" : "Run automation now?",
                                     rows: [("Name", automation.name), ("Does", automation.routineGoal ?? "recipe \(automation.recipeId)")],
                                     label: call.name, destructive: isDelete)
        if Task.isCancelled { return .cancelled }

        switch approval {
        case .refused:
            return .done(success(call, AppDelegate.refusedNote))
        case .declined:
            lastToolSummary = "Okay, I've left it alone."
            return .declined(success(call, "The user declined."))
        case .approved where isDelete:
            AutomationStore.shared.remove(id: automation.id)
            TriggerEngine.shared.refresh()
            Task { await AuditLog.shared.record(tool: "delete_automation", argsJSON: call.argsJSON, outcome: "ok", summary: automation.name, confirmed: true) }
            lastToolSummary = "Deleted “\(automation.name)”."
            return .done(success(call, "Deleted automation “\(automation.name)”."))
        case .approved:
            await app.runAutomation(automation, depth: policy.depth + 1)
            lastToolSummary = "Ran “\(automation.name)”."
            return .done(success(call, "Ran “\(automation.name)” — its result was delivered under the notch and audited."))
        }
    }

    private func runRecipe(_ call: AgentToolCall) async -> Outcome {
        let id = call.args["id"] as? String ?? ""
        let params = call.args["params"] as? [String: Any] ?? [:]
        if readOnly { return .done(success(call, AppDelegate.refusedNote)) }
        let recipe = await app.performRecipe(id: id, params: params, conversation: conversation, autoApprove: headless, auditLabel: policy.label)
        if Task.isCancelled { return .cancelled }
        let result = StepResult(call: call, content: recipe.content, isError: recipe.isError)
        if recipe.declined {
            lastToolSummary = "Okay, I've left that alone."
            return .declined(result)
        }
        if !recipe.isError { lastToolSummary = recipe.content }
        return .done(result)
    }

    // MARK: - Other agents

    private func runSubagent(_ call: AgentToolCall) async -> Outcome {
        let goal = call.args["goal"] as? String ?? ""
        guard !goal.isEmpty else { return .done(failure(call, "run_subagent needs a goal.")) }
        guard policy.depth < 2 else { return .done(failure(call, "Sub-agents can't start sub-agents this deep — do the task yourself.")) }
        let allowedTools = call.args["tools"] as? [String]
        let steps = ToolCallParser.intArg(call.args["max_steps"]) ?? 10
        let approval = await approve(title: "Start a sub-agent?",
                                     rows: [("Goal", goal), ("Tools", allowedTools?.joined(separator: ", ") ?? "read-only tools"), ("Steps", "up to \(min(steps, 15))")],
                                     label: "run_subagent")
        if Task.isCancelled { return .cancelled }

        switch approval {
        case .refused:
            return .done(success(call, AppDelegate.refusedNote))
        case .declined:
            lastToolSummary = "Okay."
            return .declined(success(call, "The user declined."))
        case .approved:
            let child = policy.child(allowedTools: allowedTools, maxSteps: steps, label: (policy.label ?? "turn") + "/subagent")
            let childConversation = Conversation(chatWithApp: "")
            childConversation.addUserMessage(goal)
            agentLog.info("subagent: start depth=\(child.depth) steps=\(child.maxSteps) goal=\"\(goal.prefix(80), privacy: .public)\"")
            let run = await AgentRunner(app: app, conversation: childConversation, goal: goal, policy: child, headless: true,
                                        inheritedConnectors: connectors).run()
            spentUSD += run.costUSD   // a child's spend counts against its parent's budget
            let answer = run.text
            agentLog.info("subagent: done — \(answer.prefix(120), privacy: .public)")
            conversation.addToolChip(name: "run_subagent", inputJSON: call.argsJSON, content: answer, isError: answer.isEmpty, displaySummary: "Sub-agent finished")
            lastToolSummary = answer
            return .done(StepResult(call: call, content: answer.isEmpty ? "(the sub-agent returned nothing)" : "Sub-agent result:\n" + answer, isError: answer.isEmpty))
        }
    }

    private func runInBackground(_ call: AgentToolCall) async -> Outcome {
        let goal = call.args["goal"] as? String ?? ""
        guard !goal.isEmpty else { return .done(failure(call, "run_in_background needs a goal.")) }
        let approval = await approve(title: "Run in the background?",
                                     rows: [("Goal", goal), ("Note", "Read-only; the result appears under the notch when it's done.")],
                                     label: "run_in_background")
        if Task.isCancelled { return .cancelled }

        switch approval {
        case .refused:
            return .done(success(call, AppDelegate.refusedNote))
        case .declined:
            lastToolSummary = "Okay."
            return .declined(success(call, "The user declined."))
        case .approved:
            let id = TaskLedger.shared.start(goal: goal)
            let background = policy.child(allowedTools: nil, maxSteps: 15, label: "task:\(id)")
            let connectors = self.connectors
            let attended = !headless
            let argsJSON = call.argsJSON
            Task { await AuditLog.shared.record(tool: "task:\(id)", argsJSON: argsJSON, outcome: "started", summary: String(goal.prefix(80)), confirmed: attended) }
            let handle = Task { @MainActor [weak app] in
                guard let app else { return }
                let taskConversation = Conversation(chatWithApp: "")
                taskConversation.addUserMessage(goal + "\n\n(Deliver the result short and glanceable — it appears under the notch.)")
                let run = await AgentRunner(app: app, conversation: taskConversation, goal: goal, policy: background, headless: true,
                                            inheritedConnectors: connectors).run()
                if run.cancelled || Task.isCancelled { return }
                TaskLedger.shared.finish(id: id, result: run.text, costUSD: run.costUSD)
                await AuditLog.shared.record(tool: "task:\(id)", argsJSON: "{}", outcome: run.text.isEmpty ? "error" : "ok",
                                             summary: "\(AICost.format(run.costUSD)) · \(run.text.prefix(80))", confirmed: false)
                NotchController.shared.notifyResult(run.text.isEmpty ? "Background task finished with no result." : run.text)
                agentLog.info("background \(id, privacy: .public): done — \(run.text.prefix(100), privacy: .public)")
            }
            TaskLedger.shared.attach(id: id, task: handle)
            conversation.addToolChip(name: "run_in_background", inputJSON: call.argsJSON, content: "Started task \(id)", isError: false, displaySummary: "Running in background")
            lastToolSummary = "Started in the background."
            return .done(success(call, "Started background task \(id). Tell the user it's running and that the result will appear under the notch; don't wait for it."))
        }
    }

    // MARK: - Tools

    /// A connector's tool is third-party code, so it always asks first.
    private func callConnector(_ call: AgentToolCall, _ connector: MCPToolInfo) async -> Outcome {
        let label = "mcp:\(connector.server).\(connector.name)"
        let argsJSON = call.argsJSON
        let approval = await approve(title: ConfirmationText.title(connector.name),
                                     rows: [("Connector", connector.server), ("Tool", connector.name)] + ConfirmationText.rows(args: call.args),
                                     label: label)
        if Task.isCancelled { return .cancelled }
        if approval == .refused { return .done(success(call, AppDelegate.refusedNote)) }
        guard approval == .approved else {
            Task { await AuditLog.shared.record(tool: label, argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
            lastToolSummary = "Okay, I've left that alone."
            return .declined(success(call, "The user declined this action."))
        }
        let auditLabel = auditName(label)
        let attended = !headless
        do {
            let output = try await MCPService.shared.callConfiguredTool(server: connector.server, name: connector.name, arguments: call.args)
            Task { await AuditLog.shared.record(tool: auditLabel, argsJSON: argsJSON, outcome: "ok", summary: connector.name, confirmed: attended && !TrustSettings.isTrusted(label)) }
            let summary = "\(connector.server): \(connector.name.replacingOccurrences(of: "_", with: " "))"
            conversation.addToolChip(name: label, inputJSON: argsJSON, content: output.isEmpty ? "Done." : output, isError: false, displaySummary: summary)
            lastToolSummary = output.isEmpty ? "Done — \(summary)." : output
            return .done(success(call, output.isEmpty ? "Done." : output))
        } catch {
            let message = error.localizedDescription
            Task { await AuditLog.shared.record(tool: auditLabel, argsJSON: argsJSON, outcome: "error", summary: message, confirmed: attended) }
            return .done(failure(call, "That didn't work — \(message)"))
        }
    }

    /// A built-in tool. Tools that write, send or delete wait for a card; read-only tools run at once.
    private func callBuiltIn(_ call: AgentToolCall, _ tool: Tool) async -> Outcome {
        let argsJSON = call.argsJSON
        var approval = Approval.approved
        if tool.confirmation == .confirm {
            approval = await approve(title: ConfirmationText.title(call.name), rows: ConfirmationText.rows(args: call.args), label: call.name,
                                     destructive: ["delete_file", "move_file", "run_shell"].contains(call.name))
            if Task.isCancelled { return .cancelled }
        }
        switch approval {
        case .refused:
            return .done(success(call, AppDelegate.refusedNote))
        case .declined:
            Task { await AuditLog.shared.record(tool: call.name, argsJSON: argsJSON, outcome: "declined", summary: "declined by user", confirmed: true) }
            lastToolSummary = "Okay, I've left that alone."
            return .declined(success(call, "The user declined this action."))
        case .approved:
            break
        }

        let result = await ToolRegistry.execute(name: call.name, args: call.args, in: conversation)
        let auditLabel = auditName(call.name)
        let confirmedByPerson = !headless && tool.confirmation == .confirm && !TrustSettings.isTrusted(call.name)
        let auditSummary = result.displaySummary ?? String(result.content.prefix(80))
        let failed = result.isError
        Task { await AuditLog.shared.record(tool: auditLabel, argsJSON: argsJSON, outcome: failed ? "error" : "ok", summary: auditSummary, confirmed: confirmedByPerson) }

        guard result.isError else {
            lastToolSummary = result.content
            // The transcript shows a chip for what ran. Failed attempts that the model then
            // corrects are left out so they don't clutter it.
            conversation.addToolChip(name: call.name, inputJSON: argsJSON, content: result.content, isError: false, displaySummary: result.displaySummary)
            return .done(success(call, result.content, image: result.attachedImage.flatMap { AIImage.jpegData($0) }))
        }

        // Steer the model towards a corrected retry rather than an apology.
        var hint = "\n\nThis failed. Fix the cause and call \(call.name) again with corrected input — do NOT repeat the same failing call. If it genuinely can't be done, say so briefly in plain text."
        // A failed AppleScript gets the target app's real scripting dictionary, so the
        // corrected script uses vocabulary that exists.
        if call.name == "run_applescript", let script = call.args["script"] as? String,
           let targetApp = AppleScriptDictionary.appName(in: script),
           let dictionary = await Task.detached(priority: .userInitiated, operation: { AppleScriptDictionary.condensed(forApp: targetApp) }).value {
            hint += "\n\n\(dictionary)"
        }
        return .done(StepResult(call: call, content: result.content + hint, isError: true, image: result.attachedImage.flatMap { AIImage.jpegData($0) }))
    }
}
