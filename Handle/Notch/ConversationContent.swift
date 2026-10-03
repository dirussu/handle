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

        return VStack(alignment: .leading, spacing: HandleSpacing.m) {
            // A fresh chat greets the user; the greeting vanishes the moment
            // the first message lands and the transcript takes over.
            if conversation.visibleMessages.isEmpty {
                greeting
                    .transition(reduce ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HandleSpacing.l) {
                        ForEach(Array(conversation.visibleMessages)) { msg in
                            messageView(msg)
                                .id(msg.id)
                                .transition(reduce ? .opacity : .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                        if let error = conversation.errorMessage {
                            HStack(alignment: .top, spacing: HandleSpacing.s) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.handleBody)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(HandleSpacing.m)
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
                    .padding(.top, conversation.visibleMessages.isEmpty ? 0 : HandleSpacing.xxl)
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
                    .animation(HandleMotion.swap, value: conversation.visibleMessages.count)
                }
                // +1 epsilon so sub-pixel measurement rounding can't make a
                // snug transcript falsely "overflow" and show a scrollbar.
                .frame(height: min(conversation.transcriptHeight + 1, maxTranscriptHeight))
                // No scrollbar — one rule for every Handle scroll surface (the
                // Form's thick AppKit scroller clashed with the slim overlays).
                // The scroll edge fade is the "more content" affordance.
                .scrollIndicators(.never)
                .scrollEdgeFade()   // both edges — content melts under the header AND above the input bar (bottom padding keeps the resting reply out of the fade)
                .onPreferenceChange(TranscriptHeightKey.self) { conversation.transcriptHeight = $0 }
                .onChange(of: lastMessageText) {
                    withAnimation(HandleMotion.swap) {
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
            .animation(HandleMotion.swap, value: conversation.pendingConfirmation?.id)
        }
        .animation(HandleMotion.swap, value: conversation.visibleMessages.isEmpty)
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
    /// persistent "Handle" / app-name header — identity lives in a one-time
    /// greeting, not permanent chrome.
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.handleTitle)
                .foregroundStyle(.primary)
            Text("What can I help with?")
                .font(.handleBody)
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

    /// Streaming-placeholder label. Reflects ambient sight: if Handle captured
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
                VStack(alignment: .trailing, spacing: HandleSpacing.xs) {
                    // The captured screenshot is intentionally NOT rendered — it's ambient
                    // context (Handle "looked"), not user-authored content, and a thumbnail on
                    // every look-at-screen turn is clutter. The pixels still ride on
                    // `msg.image` for the model; the "Looking…" streaming label signals the
                    // capture happened. (All `msg.image`s are screen captures; user PDFs
                    // attach via `pdfData` below and DO show.)
                    if msg.pdfData != nil {
                        HStack(spacing: HandleSpacing.s) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(msg.pdfFilename ?? "document.pdf")
                                .font(.handleBody)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .userBubble()
                    }
                    if !msg.text.isEmpty {
                        Text(msg.text)
                            .font(.handleBody)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .userBubble()
                    }
                    // Looking is no longer silent: say whether the screenshot left the Mac.
                    if let status = msg.screenshotStatus {
                        Label(status.caption, systemImage: status.symbol)
                            .font(.handleCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: HandleSpacing.s) {
                if msg.text.isEmpty && msg.toolUses.isEmpty && msg.isStreaming {
                    ThinkingLabel(text: thinkingLabel(for: msg))
                } else if !msg.text.isEmpty {
                    Markdown(msg.text)
                        .markdownTheme(.handleCompact)
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
        VStack(spacing: HandleSpacing.s) {
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
                    .font(.handleCaption)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 8)
                    .transition(.opacity)
            }
            HStack(spacing: HandleSpacing.m) {
                // Attach a PDF — the one thing ambient sight can't reach (a
                // document that isn't on a screen). Screenshots are no longer a
                // manual action: Handle captures the screen / the named window itself.
                Button(action: onAddPDF) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handleIconHover()
                .help("Attach a PDF")
                .disabled(conversation.isAwaitingResponse)

                // NOT disabled while a turn runs — typing mid-turn queues the
                // message (by request); Enter submits into the queue.
                TextField(conversation.visibleMessages.isEmpty ? "Ask Handle…" : "Reply…", text: $conversation.inputDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.handleBody)
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
                // armed (this IS the action), faint idle. While Handle works it
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
                        .animation(HandleMotion.feedback, value: stopHover)
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
                .animation(HandleMotion.swap, value: conversation.isAwaitingResponse)
                .animation(HandleMotion.swap, value: canSubmit)
            }
        }
        .padding(.horizontal, HandleSpacing.m)
        .padding(.vertical, HandleSpacing.s)
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
        .animation(HandleMotion.feedback, value: inputFocused)
        .animation(HandleMotion.swap, value: conversation.isAwaitingResponse)
        // Isolate the bubble's geometry so it + its background comet resolve
        // any ancestor resize (the transcript growing mid-answer) as ONE
        // rigid unit — the comet can't lag behind the bubble's frame.
        .geometryGroup()
    }

    private func pdfPreview(pdf: PendingPDF) -> some View {
        HStack(spacing: HandleSpacing.m) {
            Image(systemName: "doc.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(pdf.filename)
                    .font(.handleBody.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(pdf.data.count / 1024) KB · PDF")
                    .font(.handleCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            removeAttachmentButton(action: conversation.clearPendingPDF)
        }
        .padding(HandleSpacing.s)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func removeAttachmentButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Color.handleChip, in: Circle())
        }
        .buttonStyle(.plain)
        .handleIconHover()
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
