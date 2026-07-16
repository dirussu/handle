import AppKit
import SwiftUI
import MarkdownUI

/// Reports the transcript's content height so the scroll area can size to fit.
private struct TranscriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The assistant surface — the conversation transcript + input bar. Hosted
/// inside the notch's open panel (formerly the body of FloatingPanel). Pure
/// SwiftUI; owns no window. Sizing/΅scroll caps are tuned for the notch
/// drop-down panel.
struct ConversationContent: View {
    @Bindable var conversation: Conversation
    let onSubmit: (String) -> Void
    let onAddPDF: () -> Void
    let onClose: () -> Void
    let onStop: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var stopHover = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The transcript sizes to its content (snug) up to `maxTranscriptHeight`,
    /// then scrolls. The measured height is cached on the conversation
    /// (`conversation.transcriptHeight`) so it survives close/reopen — no
    /// 0-height flash on open.
    private let maxTranscriptHeight: CGFloat = 340

    var body: some View {
        // Force `@Observable` to register reads of the properties this view
        // depends on. Streaming mutations on nested struct fields can otherwise
        // be missed and the panel won't refresh until it's recreated.
        let _ = conversation.messages
        let _ = conversation.pendingConfirmation
        let _ = conversation.errorMessage
        let _ = conversation.isAwaitingResponse

        return VStack(alignment: .leading, spacing: AkariSpacing.m) {
            // A fresh chat greets the user; the greeting vanishes the moment
            // the first message lands and the transcript takes over.
            if conversation.visibleMessages.isEmpty {
                greeting
                    .transition(reduce ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AkariSpacing.l) {
                        ForEach(Array(conversation.visibleMessages)) { msg in
                            messageView(msg)
                                .id(msg.id)
                                .transition(reduce ? .opacity : .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                        if let error = conversation.errorMessage {
                            HStack(alignment: .top, spacing: AkariSpacing.s) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.akariBody)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(AkariSpacing.m)
                            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .transition(reduce ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        }
                        // Anchor to scroll to.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 2)
                    // Breathing room above the first message so it doesn't sit jammed
                    // under the notch. Only when there ARE messages — the greeting's
                    // own top padding covers the empty state. Applied before the height
                    // measurement so the transcript frame accounts for it.
                    .padding(.top, conversation.visibleMessages.isEmpty ? 0 : AkariSpacing.xxl)
                    // Clear the BOTTOM fade zone at rest (the Chats-list trick):
                    // scrolled to the newest message, its last line sits above the
                    // fade and stays crisp; the fade only melts content that is
                    // actually scrolling out under the input bar.
                    .padding(.bottom, conversation.visibleMessages.isEmpty ? 0 : 20)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: TranscriptHeightKey.self, value: geo.size.height)
                        }
                    )
                    .animation(AkariMotion.swap, value: conversation.visibleMessages.count)
                }
                // +1 epsilon so sub-pixel measurement rounding can't make a
                // snug transcript falsely "overflow" and show a scrollbar.
                .frame(height: min(conversation.transcriptHeight + 1, maxTranscriptHeight))
                // No scrollbar — one rule for every Akari scroll surface (the
                // Form's thick AppKit scroller clashed with the slim overlays).
                // The scroll edge fade is the "more content" affordance.
                .scrollIndicators(.never)
                .scrollEdgeFade()   // both edges — content melts under the header AND above the input bar (bottom padding keeps the resting reply out of the fade)
                .onPreferenceChange(TranscriptHeightKey.self) { conversation.transcriptHeight = $0 }
                .onChange(of: lastMessageText) {
                    withAnimation(AkariMotion.swap) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            ZStack {
                if let confirmation = conversation.pendingConfirmation {
                    ConfirmationCard(request: confirmation)
                        .transition(reduce ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                } else {
                    inputBar
                        .transition(.opacity)
                }
            }
            .animation(AkariMotion.swap, value: conversation.pendingConfirmation?.id)
        }
        .animation(AkariMotion.swap, value: conversation.visibleMessages.isEmpty)
        .tint(.white)   // white-only accent everywhere (caret, selection, links)
        .onAppear { inputFocused = true }
        // New chat (or reopening one) swaps the conversation in place without a
        // re-appear, so re-focus the input on identity change — type immediately.
        .onChange(of: conversation.persistentID) { inputFocused = true }
    }

    /// Auto-scroll trigger. Fires only when a new message arrives or a new tool
    /// call is added — NOT on every text-delta during streaming. This lets the
    /// user scroll up to read earlier content without being snapped back to bottom.
    private var lastMessageText: String {
        let count = conversation.visibleMessages.count
        let lastID = conversation.visibleMessages.last?.id.uuidString ?? ""
        let toolCount = conversation.visibleMessages.last?.toolUses.count ?? 0
        return "\(count)|\(lastID)|\(toolCount)"
    }

    // MARK: Greeting

    /// Warm empty-state shown only in a fresh chat. It disappears the moment
    /// the user sends something and the transcript takes over. Replaces the old
    /// persistent "Akari" / app-name header — identity lives in a one-time
    /// greeting, not permanent chrome.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.akariTitle)
                .foregroundStyle(.primary)
            Text("What can I help with?")
                .font(.akariBody)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)   // breathing room above the greeting; it sits close to the input below
    }

    /// Time-of-day greeting, resolved on the user's machine.
    private var greetingText: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Hello"
        }
    }

    // MARK: Messages

    /// Streaming-placeholder label. Reflects ambient sight: if Akari captured
    /// the screen for this turn it's "Looking…"; a pure text turn is "Thinking…".
    private func thinkingLabel(for msg: Message) -> String {
        let sawScreen = conversation.messages.last(where: { $0.role == .user })?.image != nil
        return sawScreen ? "Looking…" : "Thinking…"
    }

    @ViewBuilder
    private func messageView(_ msg: Message) -> some View {
        if msg.role == .user {
            HStack(alignment: .top) {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: AkariSpacing.xs) {
                    // The captured screenshot is intentionally NOT rendered — it's ambient
                    // context (Akari "looked"), not user-authored content, and a thumbnail on
                    // every look-at-screen turn is clutter. The pixels still ride on
                    // `msg.image` for the model; the "Looking…" streaming label signals the
                    // capture happened. (All `msg.image`s are screen captures; user PDFs
                    // attach via `pdfData` below and DO show.)
                    if msg.pdfData != nil {
                        HStack(spacing: AkariSpacing.s) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(msg.pdfFilename ?? "document.pdf")
                                .font(.akariBody)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .userBubble()
                    }
                    if !msg.text.isEmpty {
                        Text(msg.text)
                            .font(.akariBody)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .userBubble()
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: AkariSpacing.s) {
                if msg.text.isEmpty && msg.toolUses.isEmpty && msg.isStreaming {
                    ThinkingLabel(text: thinkingLabel(for: msg))
                } else if !msg.text.isEmpty {
                    Markdown(msg.text)
                        .markdownTheme(.akariCompact)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(msg.toolUses) { use in
                    ToolUseCard(
                        toolUse: use,
                        result: conversation.toolResult(forUseId: use.id)
                    )
                }
            }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(spacing: AkariSpacing.s) {
            if let pdf = conversation.pendingPDF {
                pdfPreview(pdf: pdf)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // Queued messages (typed mid-turn) — a quiet count so the user knows
            // their message wasn't lost; it runs when the current reply finishes.
            if !conversation.queuedTexts.isEmpty {
                Text(conversation.queuedTexts.count == 1
                     ? "1 message queued — runs when this reply finishes"
                     : "\(conversation.queuedTexts.count) messages queued — run when this reply finishes")
                    .font(.akariCaption)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }
            HStack(spacing: AkariSpacing.m) {
                // Attach a PDF — the one thing ambient sight can't reach (a
                // document that isn't on a screen). Screenshots are no longer a
                // manual action: Akari captures the screen / the named window itself.
                Button(action: onAddPDF) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .akariIconHover()
                .help("Attach a PDF")
                .disabled(conversation.isAwaitingResponse)

                // NOT disabled while a turn runs — typing mid-turn queues the
                // message (founder ask); Enter submits into the queue.
                TextField(conversation.visibleMessages.isEmpty ? "Ask Akari…" : "Reply…", text: $conversation.inputDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.akariBody)
                    .tint(.white)   // white caret + selection (DESIGN.md: white-only accent)
                    .focused($inputFocused)
                    .lineLimit(1...4)
                    .onSubmit { submit() }

                // Click-to-talk mic — for users who'd rather tap than hold the
                // hotkey. Tap: record (the icon becomes the dictation bars, the
                // blob's own waveform). Tap again: transcribe → submitted through
                // the SAME pipeline as a typed message.
                MicButton(onTranscript: onSubmit, disabled: conversation.isAwaitingResponse)

                // White-only send button per DESIGN.md: white-fill circle when
                // armed (this IS the action), faint idle. While Akari works it
                // becomes Stop — tap to cancel the running turn.
                Group {
                    if conversation.isAwaitingResponse {
                        Button(action: onStop) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                // Solid-button hover = the fill lifts (the glyph is
                                // already white, so the icon-brighten rule can't apply).
                                .background(Circle().fill(Color.white.opacity(stopHover ? 0.24 : 0.14)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .onHover { stopHover = $0 }
                        .animation(AkariMotion.feedback, value: stopHover)
                        .help("Stop")
                    } else {
                        Button(action: submit) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSubmit ? Color.black : Color.secondary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(canSubmit ? Color.white : Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }
                .animation(AkariMotion.swap, value: conversation.isAwaitingResponse)
                .animation(AkariMotion.swap, value: canSubmit)
            }
        }
        .padding(.horizontal, AkariSpacing.m)
        .padding(.vertical, AkariSpacing.s)
        // Bubble fill + the "working" comet share ONE background layer, and
        // `.compositingGroup()` flattens them into a SINGLE rendered image —
        // so the comet is part of the bubble and moves/resizes atomically
        // with it (no drift when the panel resizes mid-answer).
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(inputFocused ? 0.14 : 0.08))
                if conversation.isAwaitingResponse {
                    BorderComet(shape: RoundedRectangle(cornerRadius: 20, style: .continuous), loops: true)
                        .transition(.opacity)
                }
            }
            .compositingGroup()
        }
        .animation(AkariMotion.feedback, value: inputFocused)
        .animation(AkariMotion.swap, value: conversation.isAwaitingResponse)
        // Isolate the bubble's geometry so it + its background comet resolve
        // any ancestor resize (the transcript growing mid-answer) as ONE
        // rigid unit — the comet can't lag behind the bubble's frame.
        .geometryGroup()
    }

    private func pdfPreview(pdf: PendingPDF) -> some View {
        HStack(spacing: AkariSpacing.m) {
            Image(systemName: "doc.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(pdf.filename)
                    .font(.akariBody.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(pdf.data.count / 1024) KB · PDF")
                    .font(.akariCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            removeAttachmentButton(action: conversation.clearPendingPDF)
        }
        .padding(AkariSpacing.s)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func removeAttachmentButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Color.akariChip, in: Circle())
        }
        .buttonStyle(.plain)
        .akariIconHover()
        .help("Remove attachment")
    }

    private var canSubmit: Bool {
        let trimmed = conversation.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // While a turn runs, plain text still submits — it QUEUES (the app-side
        // handler routes it) and runs when the reply finishes. PDFs don't queue.
        if conversation.isAwaitingResponse { return !trimmed.isEmpty }
        return !trimmed.isEmpty
            || conversation.pendingPDF != nil
    }

    private func submit() {
        guard canSubmit else { return }
        let text = conversation.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.inputDraft = ""
        onSubmit(text)
    }
}

// MARK: - Click-to-talk mic button

/// The input bar's mic: tap to record, tap again to stop → the transcript is
/// submitted like a typed message (same loop, same Stop, same persistence).
/// While recording, the icon is replaced by the SAME 5-bar dictation waveform
/// the pointer blob uses (identical envelope + shimmer math, button-scaled) —
/// one voice language everywhere. Spinner while Whisper loads / transcribes.
private struct MicButton: View {
    let onTranscript: (String) -> Void
    let disabled: Bool
    @ObservedObject private var speech = SpeechService.shared

    var body: some View {
        Button(action: toggle) {
            ZStack {
                switch speech.state {
                case .recording:
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        Canvas { ctx, size in
                            let barCount = 5
                            let barW: CGFloat = 2.2, barGap: CGFloat = 2.2
                            let span = CGFloat(barCount - 1) * (barW + barGap)
                            let maxBar: CGFloat = 15, minBar: CGFloat = 2.5
                            let level = CGFloat(SpeechService.shared.level)
                            for i in 0..<barCount {
                                let x = size.width / 2 - span / 2 + CGFloat(i) * (barW + barGap)
                                let d = abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount - 1) / 2)
                                let envelope = 1 - 0.45 * d
                                let shimmer = 0.5 + 0.5 * sin(t * 6 + Double(i) * 0.9)
                                let energy = level * envelope + CGFloat(shimmer) * 0.18 * envelope
                                let h = max(minBar, min(maxBar, minBar + energy * (maxBar - minBar)))
                                let bar = CGRect(x: x - barW / 2, y: size.height / 2 - h / 2, width: barW, height: h)
                                ctx.fill(Path(roundedRect: bar, cornerRadius: barW / 2), with: .color(.white))
                            }
                        }
                    }
                case .loading, .transcribing:
                    ProgressView().controlSize(.small)
                default:
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(speech.state == .recording ? Color.white.opacity(0.14) : Color.clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .akariIconHover()
        .help(speech.state == .recording ? "Stop and send" : "Dictate")
        .disabled(disabled || speech.state == .loading || speech.state == .transcribing)
        .animation(AkariMotion.swap, value: speech.state == .recording)
    }

    private func toggle() {
        Task { @MainActor in
            switch speech.state {
            case .idle, .failed:
                await speech.startRecording()      // first tap may lazy-load Whisper (spinner)
            case .recording:
                let t = await speech.stopRecordingAndTranscribe()
                if t.isEmpty { NSSound.beep() } else { onTranscript(t) }
            default:
                break
            }
        }
    }
}

// MARK: - Thinking indicator

/// The "Akari is working" line shown before the first token streams in.
/// A calm opacity breathe rather than a stock spinner — minimal, white-only,
/// and unobtrusive next to the comet already orbiting the input bar.
private struct ThinkingLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var breathing = false

    var body: some View {
        Text(text)
            .font(.akariBody)
            .foregroundStyle(.white)
            .opacity(reduce ? 0.7 : (breathing ? 0.85 : 0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                guard !reduce else { return }   // no forever-breathing under reduce-motion
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

// MARK: - User message bubble (white-accent chip)

private extension View {
    /// The user's message chip: a soft grey bubble (white @ 10%) with primary
    /// (white) text — subtle and user-attributed without shouting. Akari's
    /// replies stay as plain text, so the bubble alone marks "your message."
    func userBubble() -> some View {
        self
            .padding(.horizontal, AkariSpacing.m)
            .padding(.vertical, AkariSpacing.s)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Tool use card

struct ToolUseCard: View {
    let toolUse: ToolUseBlock
    let result: ToolResultBlock?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AkariSpacing.m) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.akariBody.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.akariCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, AkariSpacing.m)
        .padding(.vertical, AkariSpacing.m)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        }
        .animation(AkariMotion.swap, value: result?.isError)
    }

    private var iconName: String {
        switch toolUse.name {
        case "create_calendar_event": return "calendar.badge.plus"
        case "read_calendar_events":  return "calendar"
        case "create_reminder":       return "checklist"
        case "list_reminders":        return "list.bullet.rectangle"
        case "draft_email_reply":     return "envelope.badge"
        case "draft_imessage":        return "message.badge"
        case "point_at":              return "scope"
        case "write_file":            return "doc.badge.plus"
        case "read_file":             return "doc.text"
        case "list_files":            return "folder"
        case "create_folder":         return "folder.badge.plus"
        case "delete_file":           return "trash"
        case "move_file":             return "arrow.right.doc.on.clipboard"
        case "open_file":             return "arrow.up.forward.app"
        case "open_url":              return "safari"
        case "pick_file":             return "doc.viewfinder"
        case "recapture_screen":      return "arrow.triangle.2.circlepath.camera"
        case "web_search":            return "magnifyingglass.circle"
        case "run_applescript":       return "applescript"
        case "run_shell":             return "terminal"
        case "code_execution":        return "curlybraces"
        case "list_shortcuts":        return "square.grid.2x2"
        case "run_shortcut":          return "play.square"
        default:                       return "wrench.and.screwdriver"
        }
    }

    private var headline: String {
        switch toolUse.name {
        case "create_calendar_event":
            if let title = inputField("title"), !title.isEmpty {
                return "Create event: \(title)"
            }
            return "Create calendar event"
        case "read_calendar_events":
            return "Read calendar"
        case "create_reminder":
            if let title = inputField("title"), !title.isEmpty {
                return "Add reminder: \(title)"
            }
            return "Create reminder"
        case "list_reminders":
            return "List reminders"
        case "draft_email_reply":
            if let to = inputField("to"), !to.isEmpty {
                return "Draft reply to \(to)"
            }
            return "Draft email reply"
        case "draft_imessage":
            if let to = inputField("to"), !to.isEmpty {
                return "Draft message to \(to)"
            }
            return "Draft iMessage"
        case "point_at":
            if let label = inputField("label"), !label.isEmpty {
                return "Point at \"\(label)\""
            }
            return "Point at element"
        case "write_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Write \(path)"
            }
            return "Write file"
        case "read_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Read \(path)"
            }
            return "Read file"
        case "list_files":
            if let path = inputField("path"), !path.isEmpty {
                return "List \(path)"
            }
            return "List workspace"
        case "create_folder":
            if let path = inputField("path"), !path.isEmpty {
                return "Create folder \(path)"
            }
            return "Create folder"
        case "delete_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Move \(path) to Trash"
            }
            return "Delete file"
        case "move_file":
            return "Move file"
        case "open_file":
            if let path = inputField("path"), !path.isEmpty {
                return "Open \(path)"
            }
            return "Open file"
        case "open_url":
            if let url = inputField("url"), !url.isEmpty {
                return "Open \(url)"
            }
            return "Open URL"
        case "pick_file":
            return "Pick a file…"
        case "recapture_screen":
            return "Refreshed screen view"
        case "run_applescript":
            if let purpose = inputField("purpose"), !purpose.isEmpty {
                return purpose
            }
            return "Run AppleScript"
        case "run_shell":
            if let cmd = inputField("command"), !cmd.isEmpty {
                let short = cmd.count > 50 ? String(cmd.prefix(50)) + "…" : cmd
                return "Shell: \(short)"
            }
            return "Run shell command"
        case "code_execution":
            return "Run code"
        case "list_shortcuts":
            return "List shortcuts"
        case "run_shortcut":
            if let name = inputField("name"), !name.isEmpty {
                return "Run shortcut: \(name)"
            }
            return "Run shortcut"
        default:
            return toolUse.name
        }
    }

    private var subtitle: String? {
        if let r = result, !r.isError {
            return r.displaySummary
        }
        if let r = result, r.isError {
            return r.displaySummary ?? "Error"
        }
        if !toolUse.isComplete {
            return "Preparing…"
        }
        return "Awaiting confirmation"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let r = result {
            Image(systemName: r.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(r.isError ? .red : .green)
        } else if !toolUse.isComplete {
            ProgressView().controlSize(.mini)
        } else {
            // Pending-confirmation state: a small white dot (white-only accent).
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
        }
    }

    private func inputField(_ key: String) -> String? {
        guard let data = toolUse.inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }
}

// MARK: - Confirmation card (replaces input bar while pending)

struct ConfirmationCard: View {
    let request: ConfirmationRequest

    var body: some View {
        VStack(alignment: .leading, spacing: AkariSpacing.m) {
            HStack(spacing: AkariSpacing.s) {
                if request.isDestructive {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                Text(request.title)
                    .font(.akariSection)
                    .foregroundStyle(.primary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: AkariSpacing.s) {
                ForEach(Array(request.detailRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: AkariSpacing.m) {
                        Text(row.label)
                            .font(.akariCaption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(row.value)
                            .font(.akariBody)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(AkariSpacing.m)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            }

            HStack(spacing: 10) {
                Button(request.cancelLabel) {
                    request.onDecision(false)
                }
                .buttonStyle(.akariSolid)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(request.confirmLabel) {
                    request.onDecision(true)
                }
                .buttonStyle(request.isDestructive ? .akariSolidDestructive : .akariSolidProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(AkariSpacing.l)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.10))
        }
    }
}

// MARK: - Markdown theme tuned for Akari's compact glass panel

extension Theme {
    /// Markdown theme aligned with Akari's type ramp:
    /// - body: 13pt regular (akariBody)
    /// - h1:   17pt semibold
    /// - h2:   15pt semibold
    /// - h3:   14pt semibold (akariSection)
    /// - code: 12pt monospaced
    static let akariCompact: Theme = Theme()
        .text {
            FontSize(13)
            ForegroundColor(.primary)
        }
        .strong {
            FontWeight(.semibold)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            BackgroundColor(.primary.opacity(0.08))
        }
        .link {
            ForegroundColor(.white)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.30))
                .markdownMargin(top: .em(0), bottom: .em(0.6))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.20), bottom: .em(0))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.6), bottom: .em(0.4))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.5), bottom: .em(0.35))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.4), bottom: .em(0.3))
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
        }
        .codeBlock { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.25))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12)
                }
                .padding(12)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .foregroundStyle(.secondary)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 2)
                }
        }
        .table { configuration in
            configuration.label
                .markdownTableBorderStyle(.init(.allBorders, color: .primary.opacity(0.18)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(.clear, Color.white.opacity(0.04))
                )
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle { FontSize(12) }
                .padding(.horizontal, AkariSpacing.s)
                .padding(.vertical, AkariSpacing.xs)
        }
}
