import SwiftUI
import AppKit
import OSLog

// Debug commands that drive the agent: a full turn, chat and identity probes, pointing.

#if DEBUG

extension AppDelegate {
    /// RECIPE PROBE (`__recipe__ <goal>`): match → fill → resolve, logging each stage
    /// (no execution) to validate retrieve+fill on the real model.
    func runRecipeProbe(goal: String) async {
        agentLog.info("recipe: goal=\"\(goal, privacy: .public)\"")
        guard let recipe = await matchRecipe(goal: goal) else {
            agentLog.info("recipe: NO MATCH — would decline"); return
        }
        agentLog.info("recipe: matched → \(recipe.id, privacy: .public) (\(recipe.title, privacy: .public))")
        let params = await fillParams(recipe: recipe, goal: goal)
        agentLog.info("recipe: params=\(String(describing: params), privacy: .public)")
        let card = recipe.resolve(recipe.confirmTemplate, with: params)
        let script = recipe.resolve(recipe.body, with: params)
        agentLog.info("recipe: CARD=\"\(card, privacy: .public)\"\nrecipe: RESOLVED SCRIPT:\n\(script, privacy: .public)")
    }

    /// Run the full pointing pipeline against the frontmost app for `query`, no GUI
    /// needed — capture, enumerate AX, See turn with the pointing instruction; the
    /// dispatch logs the selected element + live frame (and draws the highlight).
    func runPointingHarness(query: String, click: Bool = false) async {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return }
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        guard let raw = try? await ScreenCapture.captureRegion(rect, on: screen) else {
            agentLog.error("harness: capture failed"); return
        }
        let prepared = ImagePreparation.prepareForAPI(raw)
        let axElements = AccessibilityProbe.elements(in: rect, of: bundleID, limit: 25)
        agentLog.info("harness: query=\"\(query, privacy: .public)\" app=\(bundleID ?? "?", privacy: .public) ax=\(axElements.count)")
        for (i, e) in axElements.enumerated() {
            agentLog.info("AX candidate [\(i)] \(e.role, privacy: .public) \"\(e.label, privacy: .public)\" (\(Int(e.frame.minX)),\(Int(e.frame.minY)),\(Int(e.frame.width))×\(Int(e.frame.height)))")
        }
        let convo = Conversation(chatWithApp: app?.localizedName ?? "")
        convo.updateCurrentCapture(rect: rect, screen: screen, imagePixelSize: prepared.pixelSize, axElements: axElements)
        convo.addUserMessage(query, image: prepared.image, imagePixelSize: prepared.pixelSize)
        if click {
            // __clicktest__: run the click pipeline card-less (DEBUG auto-approve) so
            // select → press is verifiable headlessly.
            let finalText = await streamOneTurn(in: convo, instr: AgentPrompting.pointingGuide(elements: axElements), display: false)
            if !(await dispatchClickIfPresent(finalText, conversation: convo, autoApprove: true)) {
                agentLog.info("click: NOT HANDLED — nothing selected")
            }
            return
        }
        await runToolLoop(in: convo, isInitial: false, action: convo.initialAction)
    }

    /// `__websearch__`
    func debugSetWebSearch(_ cmd: String) async {
        // Toggle the Settings → AI web-search switch from the harness.
        WebSettings.searchEnabled = cmd.hasSuffix(" on")
        agentLog.info("harness: websearch=\(WebSettings.searchEnabled)")
    }

    /// `__chatprobe__`
    func debugProbeChat(_ cmd: String) async {
        // Plain text turns straight through streamOneTurn — for tone/
        // wording checks without driving the GUI. " || " separates
        // successive turns of ONE conversation (multi-turn repros).
        let convo = Conversation(chatWithApp: "")
        for turn in String(cmd.dropFirst("__chatprobe__ ".count)).components(separatedBy: " || ") {
            convo.addUserMessage(turn)
            let reply = await self.streamOneTurn(in: convo, instr: "", display: false)
            let shown = Conversation.withoutEmoji(reply)
            convo.commitAssistantMessage(shown)
            // Log the DISPLAYED form — commit-time filtering applied.
            agentLog.info("chatprobe [\(turn.prefix(40), privacy: .public)] → \(shown.prefix(300), privacy: .public)")
        }
    }

    /// `__identityeval__`
    func debugEvaluateIdentity(_ cmd: String) async {
        // Identity block eval (EVALS.md): the questions Handle must
        // never fumble, cold and at depth. Judged on "mentions
        // Handle" + (privacy) a stays-local claim; full replies
        // logged for a wording pass.
        let cases = ["who are you?", "who made you?",
                     "do you send my data to the cloud?",
                     "are you ChatGPT?", "what can you do?"]
        for q in cases {
            let convo = Conversation(chatWithApp: "")
            convo.addUserMessage(q)
            let reply = await self.streamOneTurn(in: convo, instr: "", display: false)
            let lower = reply.lowercased()
            let named = lower.contains("handle")
            let privacyOK = !q.contains("cloud") || lower.contains("local") || lower.contains("never leave") || lower.contains("on your mac") || lower.contains("on this mac")
            agentLog.info("identityeval [\(q, privacy: .public)] named=\(named) privacy=\(privacyOK) → \(reply.prefix(220), privacy: .public)")
        }
        // Depth: the same question after 8 unrelated exchanges.
        let deep = Conversation(chatWithApp: "")
        for i in 1...8 {
            deep.addUserMessage("random filler question number \(i) about cooking pasta")
            deep.commitAssistantMessage("Filler answer \(i): boil water, add salt, cook until al dente.")
        }
        deep.addUserMessage("who are you?")
        let deepReply = await self.streamOneTurn(in: deep, instr: "", display: false)
        agentLog.info("identityeval [DEPTH who are you?] named=\(deepReply.lowercased().contains("handle")) → \(deepReply.prefix(220), privacy: .public)")
        agentLog.info("identityeval DONE")
    }

    /// `__queuetest__`
    func debugCheckMessageQueue(_ cmd: String) async {
        // Message queue e2e: start a turn, queue a second mid-run
        // (what onSubmit does while isAgentRunning), and verify BOTH
        // answers land in order via the loop-exit drain.
        let convo = Conversation(chatWithApp: "")
        self.runSubmittedTurn(text: "what is 2+2? answer with just the number", in: convo)
        try? await Task.sleep(for: .seconds(1))
        convo.queuedTexts.append("what is 3+3? answer with just the number")
        agentLog.info("queuetest: queued second message mid-turn")
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            let answers = convo.visibleMessages.filter { $0.role == .assistant && !$0.text.isEmpty }
            if answers.count >= 2 {
                agentLog.info("queuetest: DONE — answers in order: \"\(answers[0].text.prefix(40), privacy: .public)\" then \"\(answers[1].text.prefix(40), privacy: .public)\" queueLeft=\(convo.queuedTexts.count)")
                return
            }
        }
        agentLog.error("queuetest: TIMEOUT — second answer never arrived")
    }

    /// `__voicecmd__`
    func debugRunTurn(_ cmd: String) async {
        // Drive the transcript→capture→loop path with given text (no mic).
        await self.handleVoiceCommand(transcript: String(cmd.dropFirst(13)))
    }
}

#endif
