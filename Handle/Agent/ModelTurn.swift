import AppKit
import OSLog

// One request to the model: the system prompt, the tool guide, streaming, and the fallback for servers without tool support.

extension AppDelegate {

    /// ONE model turn — See (image) or Ask (text), optionally with tools. Returns
    /// the reply text plus the first tool call, if the model made one.
    /// Identity + context preamble + `rules` form the system prompt; `instr` +
    /// memory are prefixed to the last user text (per-turn data, closest to the
    /// user's words); `tools`/`extraSpecs` go as native tool definitions and
    /// `loopHistory` carries this turn's tool_use/tool_result pairs. On a server
    /// without tool support the prose is folded into the prefix and the call is
    /// scraped from the reply text instead.
    func streamTurn(in conversation: Conversation, rules: String = "", instr: String = "", display: Bool = true,
                            tools: [Tool] = [], extraSpecs: [AIToolSpec] = [], loopHistory: [AIMessage] = [],
                            consumeSlots: Bool = true, effort: AIEffort? = nil) async -> TurnOutput {
        // The per-turn slots (context preamble, memory) are consumed by the turn —
        // except across the steps of one action loop (`consumeSlots: false`), where
        // every step must see the SAME system prompt + user prefix: the model needs
        // the memory at every step, and a byte-identical prefix is what makes the
        // provider's prompt cache hit. The loop clears the slots when it ends.
        let preamble = conversation.pendingContextPreamble
        if consumeSlots { conversation.pendingContextPreamble = "" }
        // Memory sits CLOSEST to the user's text — last position wins a small model's
        // attention; before the tool spec it gets ignored (verified live).
        let memory = conversation.pendingMemory
        if consumeSlots { conversation.pendingMemory = "" }
        // The user's real prompt (+ image) — from the VISIBLE transcript, so a
        // tool chip's result-only placeholder never hides it mid-loop.
        let lastUser = conversation.visibleMessages.last(where: { $0.role == .user })
        var image = lastUser?.image
        let userText = lastUser?.text ?? ""
        let toolTurn = !tools.isEmpty || !extraSpecs.isEmpty

        var events: AsyncThrowingStream<AIStreamEvent, Error>? = nil
        do {
            let native = AIConfig.nativeTools
            // The one place pixels leave the Mac — so consent, the caption under
            // the bubble, and the notch's eye all happen right here.
            var consentNote = ""
            if image != nil, !AIConfig.visionAvailable {
                image = nil
                consentNote = SeeSettings.unsupportedNote
                conversation.markScreenshot(.withheldUnsupported)
                agentLog.info("streamTurn: screenshot withheld — model has no vision")
            }
            if image != nil {
                if SeeSettings.askBeforeSend {
                    if conversation.screenSendDecision == nil {
                        let app = conversation.capturedAppName ?? "the screen"
                        conversation.screenSendDecision = await awaitConfirmation(
                            in: conversation, title: "Send a screenshot?",
                            rows: [("Of", app), ("To", AIConfig.providerDisplayName)], label: "send_screenshot")
                        if Task.isCancelled { return TurnOutput(text: "", call: nil) }
                    }
                    if conversation.screenSendDecision == false {
                        image = nil
                        consentNote = SeeSettings.declinedNote
                        conversation.markScreenshot(.withheldDeclined)
                        agentLog.info("streamTurn: screenshot withheld — user declined")
                    }
                }
                if image != nil {
                    conversation.markScreenshot(.sent(provider: AIConfig.provider?.shortName ?? "the provider"))
                    NotchController.shared.flashSeeing()
                }
            }
            // Native tools: rules in the system prompt, schemas as tool definitions.
            // No native tools (compatible server): the prose — with the JSON call
            // format — is folded into the user prefix and the call is scraped below.
            let system = [AgentPrompting.currentIdentity, UserInstructions.promptBlock, preamble, native ? rules : ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let prefix = [native ? "" : rules, instr, memory, consentNote].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let messages = AgentPrompting.messages(from: conversation.visibleMessages, prefix: prefix, image: image) + loopHistory
            guard !messages.isEmpty else { return TurnOutput(text: "", call: nil) }
            let specs = native ? AgentPrompting.uniqueByName(tools.map(AgentPrompting.spec) + extraSpecs) : []   // providers reject duplicate names
            agentLog.info("streamTurn: cloud \(image != nil ? "See" : "Ask", privacy: .public) msgs=\(messages.count) tools=\(specs.count) prompt=\"\(userText.prefix(80), privacy: .public)\"")
            events = CloudEngine.shared.turn(system: system, messages: messages, tools: specs, effort: effort,
                                             label: loopHistory.isEmpty ? String(userText.prefix(120)) : "agent step · " + String(userText.prefix(90)))
        }

        // When `display` is false (agent-loop turns), deltas are buffered off-screen
        // rather than streamed into a visible bubble — so a raw tool-call payload
        // never reaches the transcript. The caller commits the final answer instead.
        let assistantIdx = display ? conversation.startAssistantStream() : -1
        if !display { conversation.isAwaitingResponse = true }
        var buf = ""
        var calls: [AgentToolCall] = []
        var usage: CloudEngine.Usage? = nil
        var stopReason: String? = nil
        var deltaCount = 0
        let streamStart = Date()
        func onDelta(_ delta: String) {
            deltaCount += 1
            if deltaCount == 1 {
                agentLog.info("streamTurn: first delta after \(String(format: "%.1f", Date().timeIntervalSince(streamStart)))s")
            }
            buf += delta
            if display { conversation.appendChunk(at: assistantIdx, delta) }
        }
        do {
            if let events {
                for try await ev in events {
                    switch ev {
                    case .textDelta(let d): onDelta(d)
                    case .toolCall(let id, let name, let json):
                        calls.append(AgentToolCall(id: id, name: name, args: AgentToolCall.parseArgs(json)))
                    case .usage(let i, let o, let cr, let cw):
                        var u = usage ?? CloudEngine.Usage()
                        if let i { u.input = i }; if let o { u.output = o }; if let cr { u.cacheRead = cr }; if let cw { u.cacheWrite = cw }
                        usage = u
                    case .done(let reason): stopReason = reason
                    }
                }
            }
            // No native tools (a compatible server without them): the call, if any,
            // is JSON in the reply text.
            if calls.isEmpty, toolTurn, !AIConfig.nativeTools, let scraped = ToolCallParser.parse(buf) {
                calls = [AgentToolCall(id: "local", name: scraped.name, args: scraped.args)]
            }
            agentLog.info("streamTurn: finished — \(deltaCount) deltas, \(buf.count) chars, calls=\(calls.map(\.name).joined(separator: ","), privacy: .public), \(String(format: "%.1f", Date().timeIntervalSince(streamStart)))s")
            #if DEBUG
            agentLog.info("streamTurn: answer=\"\(buf.replacingOccurrences(of: "\n", with: " ").prefix(600), privacy: .public)\"")
            #endif
            if display { conversation.finishAssistantStream(at: assistantIdx) } else { conversation.isAwaitingResponse = false }
            return TurnOutput(text: buf, calls: calls, usage: usage, stopReason: stopReason)
        } catch {
            agentLog.error("streamTurn threw after \(deltaCount) deltas: \(error.localizedDescription, privacy: .public)")
            conversation.setError(error.localizedDescription)
            if display { conversation.finishAssistantStream(at: assistantIdx) } else { conversation.isAwaitingResponse = false }
            return TurnOutput(text: "", call: nil)
        }
    }

    /// Text-only turn (no tools) — the plain explain/ask primitive and every
    /// harness path. Thin wrapper over `streamTurn`.
    func streamOneTurn(in conversation: Conversation, instr: String, display: Bool = true) async -> String {
        await streamTurn(in: conversation, instr: instr, display: display).text
    }
}
