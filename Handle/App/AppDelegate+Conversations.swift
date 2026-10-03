import AppKit
import EventKit
import UniformTypeIdentifiers
import OSLog

// Opening, starting, titling and presenting conversations.

extension AppDelegate {
    /// Reopen a saved conversation from the History page: restore the text
    /// transcript, make it the active conversation, and mount it. It keeps its
    /// persistent id, so continuing it updates the same stored row.
    func openSavedConversation(id: String) async {
        guard let snap = await ConversationStore.shared.load(id: id) else {
            agentLog.info("history: no stored conversation for id \(id, privacy: .public)")
            return
        }
        let convo = Conversation.restore(from: snap)
        activeConversation = convo
        presentConversation(convo)
    }

    /// New chat → a clean, blank text-first conversation (no capture), opened and
    /// ready to type. The prior conversation is already persisted (it lands in
    /// Chats), so this is a safe swap to a clean slate — and it lets you ask
    /// Handle something that isn't about your screen.
    func startNewChat() {
        let convo = Conversation(chatWithApp: "")
        activeConversation = convo
        presentConversation(convo)
    }

    /// One submitted turn: user message (fresh ambient capture) → the loop.
    /// Called from the input bar (idle path) AND the queue drain.
    func runSubmittedTurn(text: String, in conversation: Conversation) {
        // Track this turn as the active task so the Stop button can cancel it
        // (the loop checks Task.isCancelled at each step; its defer cleans up).
        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Thinking starts at the TAP: the pre-work before the first token
            // (capture, AX probe, manifest, gating) took ~2s during which
            // nothing moved (by design). Loop exits reset this via stopStreaming.
            conversation.isAwaitingResponse = true
            let attachedPDF = conversation.pendingPDF
            conversation.clearPendingPDF()

            if let pdf = attachedPDF {
                conversation.addUserMessage(text, pdfData: pdf.data, pdfFilename: pdf.filename)
            } else {
                // Ambient sight: route to the visible screen, a specific
                // (even occluded) window, or a pure text turn — and hand
                // the model a manifest of what's open. See handleAmbientTurn.
                await self.handleAmbientTurn(text: text, in: conversation)
            }

            await self.runToolLoop(in: conversation, isInitial: false, action: conversation.initialAction)
        }
    }

    /// Does the prompt touch the user's calendar/reminder world? Loose on
    /// purpose — a false positive costs ~30ms + a few tokens, nothing else.
    func promptAsksPersonalContext(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["calendar", "meeting", "event", "appointment", "schedule", "agenda",
                "reminder", "remind", "to-do", "todo", " due", "task", "today", "tomorrow"]
            .contains { t.contains($0) }
    }

    /// Fresh events (now → end of tomorrow) + incomplete reminders, from the
    /// sources the user has ALREADY authorized — never prompts.
    func personalContextDigest() async -> String {
        var events: [(title: String, start: Date)]?
        let evStatus = EKEventStore.authorizationStatus(for: .event)
        if evStatus == .fullAccess || evStatus == .authorized {
            events = CalendarTools.shared.upcomingForDigest().map { ($0.title ?? "event", $0.startDate) }
        }
        var reminders: [String]?
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        if remStatus == .fullAccess || remStatus == .authorized {
            reminders = (try? await ReminderTools.shared.listReminders(from: ListRemindersInput(state: "incomplete")))
                .map { Array($0.prefix(8)).map { $0.title ?? "reminder" } }
        }
        return Self.formatPersonalDigest(events: events, reminders: reminders)
    }

    /// Pure formatter. nil source = NOT AUTHORIZED → omitted entirely (never
    /// claim an empty calendar we can't actually see); authorized-but-empty
    /// says "none" so the model can answer that fast, truthfully.
    static func formatPersonalDigest(events: [(title: String, start: Date)]?, reminders: [String]?, now: Date = Date()) -> String {
        guard events != nil || reminders != nil else { return "" }
        var lines = ["[The user's calendar and reminders, fetched just now:"]
        if let events {
            if events.isEmpty {
                lines.append("Events: none today or tomorrow")
            } else {
                let cal = Calendar.current
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
                let parts = events.map { e -> String in
                    let day = cal.isDateInToday(e.start) ? "today" : (cal.isDateInTomorrow(e.start) ? "tomorrow" : fmt.string(from: e.start))
                    return "\(day) \(fmt.string(from: e.start)) \(e.title)"
                }
                lines.append("Events: " + parts.joined(separator: "; "))
            }
        }
        if let reminders {
            lines.append(reminders.isEmpty ? "Reminders: none incomplete"
                                           : "Reminders (incomplete): " + reminders.joined(separator: "; "))
        }
        lines.append("For questions about these, answer directly from this list — don't call the read tools. For creating or changing anything, still use the tools.]")
        return lines.joined(separator: "\n")
    }

    /// Give the chat a model-written 2–4 word title after its first real
    /// exchange (raw first lines made the list
    /// unscannable). Once per conversation; flag set even when the model's
    /// title is unusable (no retry loops — the first-line fallback stands).
    /// Runs AFTER the loop, model idle, and re-saves the snapshot.
    func maybeGenerateTitle(for conversation: Conversation) async {
        guard conversation.generatedTitle == nil, !isAgentRunning else { return }
        let user = conversation.visibleMessages.first { $0.role == .user && !$0.text.isEmpty }?.text
        let assistant = conversation.visibleMessages.first { $0.role == .assistant && !$0.text.isEmpty }?.text
        guard let user, let assistant else { return }
        conversation.generatedTitle = ""   // claim BEFORE the async call — no double generation
        let reply = await askModel("""
        Give this chat a title of 2 to 4 words. Reply with ONLY the title — no quotes, no punctuation.
        Example — a chat about scheduling a dentist visit → Dentist appointment
        Example — a chat asking to lower the volume → Volume change
        The chat:
        user: \(user.prefix(200))
        assistant: \(assistant.prefix(200))
        """)
        if let title = Conversation.sanitizedTitle(reply) {
            conversation.generatedTitle = title
            agentLog.info("title: \"\(title, privacy: .public)\"")
            if let snap = conversation.snapshot() {
                Task.detached(priority: .utility) { await ConversationStore.shared.save(snap) }
            }
        } else {
            agentLog.info("title: model reply unusable (\"\(reply.prefix(60), privacy: .public)\") — keeping the first-line fallback")
        }
    }

    /// User tapped Stop — cancel the running turn AND drop the queue (stopping
    /// means "halt everything", not "run the next one"). The loop checks
    /// Task.isCancelled at each step and bails; runToolLoop's defer finalizes
    /// the streaming message (conversation.stopStreaming), so the panel
    /// unsticks cleanly.
    func stopGeneration() {
        activeConversation?.queuedTexts.removeAll()
        activeTask?.cancel()
        activeTask = nil
    }

    func presentConversation(_ conversation: Conversation, andOpen: Bool = true) {
        NotchController.shared.present(
            conversation: conversation,
            onSubmit: { [weak self] text in
                guard let self else { return }
                // A turn is running → QUEUE (by request): the message runs when
                // the current reply finishes, in order. Previously this path
                // silently CANCELLED the running turn.
                if self.isAgentRunning {
                    conversation.queuedTexts.append(text)
                    return
                }
                self.runSubmittedTurn(text: text, in: conversation)
            },
            onAddPDF: { [weak self] in
                Task { @MainActor in
                    self?.attachPDF(to: conversation)
                }
            },
            andOpen: andOpen
        )
    }

    /// Show an open panel to pick a PDF, then stage it as the pending PDF on the conversation.
    private func attachPDF(to conversation: Conversation) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        panel.title = "Choose a PDF to attach"
        panel.prompt = "Attach"
        // While the panel is showing we want to be able to interact with it; activate as regular.
        let priorPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        NSApp.setActivationPolicy(priorPolicy)
        guard response == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            // Soft cap at ~30MB to stay under Anthropic's 32MB PDF limit after base64 inflation.
            let maxBytes = 30 * 1024 * 1024
            guard data.count <= maxBytes else {
                conversation.errorMessage = "PDF is too large (\(data.count / 1024 / 1024) MB). Anthropic's limit is ~32 MB."
                return
            }
            conversation.setPendingPDF(PendingPDF(data: data, filename: url.lastPathComponent))

        } catch {
            conversation.errorMessage = "Couldn't read PDF: \(error.localizedDescription)"
        }
    }
}
