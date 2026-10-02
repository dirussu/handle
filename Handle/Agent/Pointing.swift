import AppKit
import OSLog

// Pointing at and clicking on-screen elements chosen by index from the accessibility tree.

extension AppDelegate {
    /// The point_at tool spec. We give the model a NUMBERED LIST of the real
    /// on-screen elements (from AX, each with an exact frame) and have it pick one
    /// by index — the local 7B is good at naming the right element but bad at
    /// estimating its coordinates, so AX supplies the geometry. Empty list (no AX,
    /// e.g. custom-drawn apps) → no pointing instruction at all.
    func pointAtToolInstruction(elements: [AXElement], native: Bool = false) -> String {
        guard !elements.isEmpty else { return "" }
        let list = elements.enumerated().map { i, e in
            let role = e.role.hasPrefix("AX") ? String(e.role.dropFirst(2)) : e.role
            return "[\(i)] \(role) \"\(e.label)\""
        }.joined(separator: "\n")
        if native {   // cloud: point_at is a real tool; the list is the turn's data
            return """
            # On-screen elements (each has an index)
            \(list)

            The user is asking you to point at something on screen. Call the point_at tool with the index of the element that matches their request — or index -1 if NONE of the listed elements match (never force a wrong match).
            """
        }
        return """
        # On-screen elements (each has an index)
        \(list)

        The user is asking you to point at something on screen. Reply with ONLY this JSON — no other text:
        {"name": "point_at", "arguments": {"index": <index>}}

        Use the index of the element that matches their request. Example — asked "where is the search field?" with `[3] TextField "Search"` in the list → {"name": "point_at", "arguments": {"index": 3}}.

        If NONE of the listed elements match what they asked for, use index -1 — do NOT force a wrong match:
        {"name": "point_at", "arguments": {"index": -1}}
        """
    }

    /// Parse the reply for a `<tool_call>{…}</tool_call>` block; if it's a point_at,
    /// run it: capture-pixel point → screen, AX hit-test there for the exact element
    /// ("vision points, AX pins"), and outline it (small box if AX finds nothing).
    /// Returns true iff it highlighted an element. The caller shows a fallback
    /// message when this is false (no call / bad index / model declined).
    @discardableResult
    func dispatchPointAtIfPresent(_ text: String, conversation: Conversation) -> Bool {
        guard let scraped = parseToolCall(text) else {
            // Diagnostics: show the reply tail so we can tell whether the model
            // skipped the call, malformed it, or pointed in prose instead.
            agentLog.info("runTurn: no point_at parsed. reply tail=\"\(String(text.suffix(200)), privacy: .public)\"")
            return false
        }
        return dispatchPointAt(AgentToolCall(id: "local", name: scraped.name, args: scraped.args), conversation: conversation)
    }

    /// Engine-neutral core: a parsed `point_at` (native block or scraped JSON) → highlight.
    @discardableResult
    func dispatchPointAt(_ call: AgentToolCall?, conversation: Conversation) -> Bool {
        guard let call, call.name == "point_at" else {
            agentLog.info("runTurn: no point_at call (got \(call?.name ?? "nothing", privacy: .public))")
            return false
        }
        // AX-select: the model picked an element index from the candidate list we
        // gave it; highlight that element's EXACT frame. No coordinate path — the
        // local 7B can't localize, and AX already supplies the geometry.
        guard let idx = Self.intArg(call.args["index"]) else {
            agentLog.info("runTurn: point_at without an index (args: \(call.args.keys.sorted().joined(separator: ","), privacy: .public))")
            return false
        }
        if idx < 0 {   // model's "none of these match" sentinel — decline gracefully, no highlight
            agentLog.info("runTurn: model declined (index -1) — no element matched the request")
            return false
        }
        guard conversation.axElements.indices.contains(idx) else {
            agentLog.info("runTurn: point_at index \(idx) out of range (0..<\(conversation.axElements.count))")
            return false
        }
        let el = conversation.axElements[idx]
        let frame = AccessibilityProbe.liveFrame(of: el) ?? el.frame   // re-read NOW so a reflow during inference can't stale it
        let screen = conversation.captureScreen ?? PointingOverlay.currentScreen()
        agentLog.info("runTurn: point_at index \(idx) → \(el.role, privacy: .public) \"\(el.label, privacy: .public)\" live(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))×\(Int(frame.height))) snapshot(\(Int(el.frame.minX)),\(Int(el.frame.minY)))")
        MetaballPointer.shared.guide(steps: [GuideStep(rect: frame, message: el.label)], on: screen)
        return true
    }

    /// CLICK dispatch: same select-by-index as pointing, but the selection is ACTED
    /// on — highlight the element (so the user sees exactly what will be pressed),
    /// suspend on a confirm card, then AXPress (synthetic-click fallback), audit, chip.
    /// Returns true iff it handled the turn (clicked, failed-with-message, or the
    /// user declined). False = nothing selected; the caller shows "I don't see that."
    @discardableResult
    func dispatchClickIfPresent(_ text: String, conversation: Conversation, autoApprove: Bool = false) async -> Bool {
        guard let scraped = parseToolCall(text) else {
            agentLog.info("click: no selection parsed. reply tail=\"\(String(text.suffix(200)), privacy: .public)\"")
            return false
        }
        return await dispatchClick(AgentToolCall(id: "local", name: scraped.name, args: scraped.args), conversation: conversation, autoApprove: autoApprove)
    }

    /// Engine-neutral core: a parsed `point_at` selection → highlight → confirm → press.
    @discardableResult
    func dispatchClick(_ call: AgentToolCall?, conversation: Conversation, autoApprove: Bool = false) async -> Bool {
        guard let call, call.name == "point_at", let idx = Self.intArg(call.args["index"]) else {
            agentLog.info("click: no selection (got \(call?.name ?? "nothing", privacy: .public))")
            return false
        }
        if idx < 0 {
            agentLog.info("click: model declined (index -1) — no element matched")
            return false
        }
        switch await performClick(index: idx, conversation: conversation, autoApprove: autoApprove) {
        case .outOfRange: return false
        case .cancelled: return true
        case .declined: conversation.commitAssistantMessage("Okay — I won't click it."); return true
        case .clicked(let label, _): conversation.commitAssistantMessage("Clicked “\(label)”."); return true
        case .failed(let label, let why): conversation.commitAssistantMessage("I found “\(label)” but couldn't click it (\(why))."); return true
        }
    }

    enum ClickOutcome { case outOfRange, cancelled, declined, clicked(label: String, method: String), failed(label: String, why: String) }

    /// The click itself — highlight the element while the card is up, confirm,
    /// AXPress (synthetic-click fallback), audit, chip. Shared by the pointing
    /// path (which commits a message) and the loop's `click_element` tool (which
    /// feeds the outcome back to the model).
    func performClick(index idx: Int, conversation: Conversation, autoApprove: Bool = false) async -> ClickOutcome {
        guard conversation.axElements.indices.contains(idx) else {
            agentLog.info("click: index \(idx) out of range (0..<\(conversation.axElements.count))")
            return .outOfRange
        }
        let el = conversation.axElements[idx]
        let role = el.role.hasPrefix("AX") ? String(el.role.dropFirst(2)) : el.role
        let frame = AccessibilityProbe.liveFrame(of: el) ?? el.frame
        let screen = conversation.captureScreen ?? PointingOverlay.currentScreen()
        agentLog.info("click: index \(idx) → \(el.role, privacy: .public) \"\(el.label, privacy: .public)\" live(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))×\(Int(frame.height)))")
        // Show what will be clicked WHILE the card is up.
        MetaballPointer.shared.guide(steps: [GuideStep(rect: frame, message: el.label)], on: screen)

        let approved: Bool
        if autoApprove {
            approved = true   // DEBUG harness only (__clicktest__)
        } else {
            approved = await awaitConfirmation(in: conversation, title: "Click this?",
                                               rows: [("Element", "\(role) “\(el.label)”")],
                                               label: "click_element", destructive: false)
            if Task.isCancelled { return .cancelled }
        }
        guard approved else { return .declined }
        let result = AccessibilityProbe.press(el)
        agentLog.info("click: press → \(result.label, privacy: .public)")
        await AuditLog.shared.record(tool: "click_element",
                                     argsJSON: "{\"element\": \"\(el.label)\", \"role\": \"\(role)\", \"method\": \"\(result.label)\"}",
                                     outcome: result.succeeded ? "ok" : "error",
                                     summary: "Click “\(el.label)”", confirmed: !autoApprove)
        if result.succeeded {
            conversation.addToolChip(name: "click_element", inputJSON: "{}",
                                     content: "Clicked “\(el.label)” (\(result.label))", isError: false,
                                     displaySummary: "Clicked “\(el.label)”")
            return .clicked(label: el.label, method: result.label)
        }
        return .failed(label: el.label, why: result.label)
    }
}
