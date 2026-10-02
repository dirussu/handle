import AppKit
import CoreGraphics

/// One turn in an Handle conversation.
struct Message: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    var isStreaming: Bool
    /// Optional captured image attached to this user message.
    /// (Assistant messages never carry images.)
    var image: CGImage?
    /// Pixel dimensions of `image` after API preparation (downsampled for Claude).
    /// Used to label the image in the prompt and to translate point_at coords.
    var imagePixelSize: CGSize?

    /// What happened to this user message's screenshot (sent / withheld) —
    /// rendered as a caption under the bubble. nil = no screenshot involved.
    var screenshotStatus: ScreenshotStatus? = nil

    /// Optional PDF document attached to this user message.
    var pdfData: Data?
    /// Display name for the PDF (e.g. "contract.pdf"). Shown in the chat UI.
    var pdfFilename: String?

    /// Tool-call blocks an assistant message wants the app to execute.
    /// Empty for plain-text assistant turns and for all user messages.
    var toolUses: [ToolUseBlock] = []

    /// Tool-result blocks a user message is sending back to the model.
    /// Empty for plain user turns and for all assistant messages.
    var toolResults: [ToolResultBlock] = []

    enum Role: String, Hashable { case user, assistant }

    /// True when this message exists only to carry tool_results back to Claude;
    /// it has no human-visible text/image/pdf and shouldn't render as a chat bubble.
    var isToolResultOnly: Bool {
        role == .user
            && !toolResults.isEmpty
            && text.isEmpty
            && image == nil
            && pdfData == nil
    }
}

/// PDF the user has attached but not yet sent.
struct PendingPDF: Hashable {
    let data: Data
    let filename: String
}

/// Represents one ongoing conversation, anchored to a single captured screen region.
/// The first message in `messages` is the implicit user prompt for the chosen action,
/// not shown in the UI but always sent to the API.
@MainActor
@Observable
final class Conversation {
    /// Image shown at the top of the panel (the first capture). Nil for a
    /// text-only "Ask" conversation that began without a capture.
    let displayImage: NSImage?
    /// True when the conversation began with a screen capture (See). Its
    /// `messages[0]` is the synthesized capture prompt and is hidden from the
    /// transcript. False for a text-only Ask conversation, where every
    /// message is real and shown.
    let hasInitialCapture: Bool
    let appName: String
    let originalBundleID: String?  // Frontmost app's bundle ID at capture time — used for "type into focused field" tools.
    let initialAction: ActionType

    /// Stable identity for persistence — survives restore, so continuing a
    /// reopened conversation updates its row instead of forking a new one.
    let persistentID: String
    let createdAt: Date

    /// Where the most-recent capture came from. Used to translate point_at coords
    /// (which Claude picks within the captured region) to absolute display coords.
    /// Mutable so that recapture_screen can refresh after the screen state changes.
    var captureRect: CGRect       // display top-left origin, in points
    var captureScreen: NSScreen?
    /// The app that was on screen for the current capture (for the consent card,
    /// the status caption, and the excluded-apps check).
    var capturedAppName: String?
    var capturedBundleID: String?
    /// A capture that was skipped this turn because the app is excluded — picked
    /// up by the turn that would have used it (`takeCaptureWithheld`).
    var captureWithheld: ScreenshotStatus?
    /// Ask-before-send decision for the current user turn (nil = not asked yet).
    var screenSendDecision: Bool?
    /// Pixel dimensions of the most-recent capture (after API preparation).
    /// Used by point_at to translate from image pixels to capture-rect points.
    var currentImagePixelSize: CGSize?

    /// Snapshot of interactive UI elements on screen, refreshed on every
    /// (re)capture. The model SELECTS one by index to point at — AX supplies the
    /// exact frame, so the model never estimates coordinates (which the local 7B
    /// does badly). `var` so a recapture can refresh it.
    var axElements: [AXElement]

    /// Full message history (sent to API as-is).
    /// `messages[0]` is the synthesized initial user prompt; not rendered in the
    /// conversation list (the captured image at the top of the panel represents it).
    var messages: [Message]

    var inputDraft: String = ""
    var isAwaitingResponse: Bool = false
    var errorMessage: String?

    /// Cached measured height of the transcript content. Lives on the model
    /// (not @State in the view) so it survives the panel being closed and
    /// reopened — otherwise it resets to 0 each open and the scroll area
    /// flashes a scrollbar for a frame before re-measuring.
    var transcriptHeight: CGFloat = 0

    /// Window/machine context for the CURRENT turn, folded into the prompt
    /// sent to the model (never into the displayed message). Set per-turn by
    /// the ambient-sight router and consumed by `runTurn`. Empty for
    /// self-contained turns that don't need machine awareness.
    var pendingContextPreamble: String = ""

    /// Remembered user facts relevant to the CURRENT turn, folded into the
    /// prompt right next to the user's text (the 4B ignores context placed
    /// before a long tool spec). Set per-turn by the memory injection in
    /// `runToolLoop`; consumed by the first `streamOneTurn`.
    var pendingMemory: String = ""

    /// A PDF queued to be sent with the user's next message.
    var pendingPDF: PendingPDF?

    /// When set, the chat shows a confirmation card instead of the input bar.
    /// The orchestrator sets this and awaits the user's decision.
    var pendingConfirmation: ConfirmationRequest?

    init(
        image: CGImage,
        imagePixelSize: CGSize,
        appName: String,
        originalBundleID: String?,
        action: ActionType,
        initialUserMessage: String,
        captureRect: CGRect,
        captureScreen: NSScreen?,
        axElements: [AXElement]
    ) {
        self.displayImage = NSImage(cgImage: image, size: .zero)
        self.hasInitialCapture = true
        self.persistentID = UUID().uuidString
        self.createdAt = Date()
        self.appName = appName
        self.originalBundleID = originalBundleID
        self.initialAction = action
        self.captureRect = captureRect
        self.captureScreen = captureScreen
        self.currentImagePixelSize = imagePixelSize
        self.axElements = axElements
        self.messages = [
            Message(
                role: .user,
                text: initialUserMessage,
                isStreaming: false,
                image: image,
                imagePixelSize: imagePixelSize
            )
        ]
    }

    /// A text-only "Ask" conversation — no capture, no synthesized first
    /// prompt. Every message is real and shown. Steered into See/Do as the
    /// thread evolves (the connective-tissue role from PRODUCT.md).
    init(chatWithApp appName: String, persistentID: String = UUID().uuidString, createdAt: Date = Date()) {
        self.displayImage = nil
        self.hasInitialCapture = false
        self.persistentID = persistentID
        self.createdAt = createdAt
        self.appName = appName
        self.originalBundleID = nil
        self.initialAction = .ask
        self.captureRect = .zero
        self.captureScreen = nil
        self.currentImagePixelSize = nil
        self.axElements = []
        self.messages = []
    }

    /// Messages shown in the UI. For a capture conversation, skips the
    /// synthesized first prompt (the thumbnail represents it); a text-only
    /// Ask conversation shows every message. Pure tool-result envelopes are
    /// always hidden.
    var visibleMessages: [Message] {
        let base = hasInitialCapture ? Array(messages.dropFirst()) : messages
        return base.filter { !$0.isToolResultOnly }
    }

    /// Find the tool-result that responds to a given tool_use id.
    func toolResult(forUseId id: String) -> ToolResultBlock? {
        for msg in messages {
            for r in msg.toolResults where r.toolUseId == id { return r }
        }
        return nil
    }

    // MARK: - Mutations

    func addUserMessage(
        _ text: String,
        image: CGImage? = nil,
        imagePixelSize: CGSize? = nil,
        pdfData: Data? = nil,
        pdfFilename: String? = nil
    ) {
        messages.append(
            Message(
                role: .user,
                text: text,
                isStreaming: false,
                image: image,
                imagePixelSize: imagePixelSize,
                pdfData: pdfData,
                pdfFilename: pdfFilename
            )
        )
    }

    /// Append a fresh assistant message that the streaming loop will fill.
    @discardableResult
    func startAssistantStream() -> Int {
        messages.append(Message(role: .assistant, text: "", isStreaming: true, image: nil))
        isAwaitingResponse = true
        errorMessage = nil
        return messages.count - 1
    }

    // The mutations below all use the explicit copy-modify-assign pattern.
    // Reason: `@Observable` doesn't reliably notify observers when a struct
    // field is mutated in place through an array subscript (Swift uses
    // Array's `_modify` coroutine, which can bypass the property's setter
    // and skip the macro-generated `withMutation` notification). Reading
    // `messages` and assigning the whole array back guarantees the setter
    // fires, which is what makes the live chat panel re-render mid-stream.
    /// Messages typed WHILE a turn runs (2026-07-10): they queue here
    /// and the loop's exit drains them in order — each gets a fresh capture
    /// when ITS turn starts. Stop clears the queue along with the turn.
    var queuedTexts: [String] = []

    // Streaming presentation (2026-07-10: "typing isn't smooth"):
    // model tokens arrive in BURSTS — several words, then a pause — and every
    // burst re-parsed the markdown and re-laid-out the panel, which read as
    // stutter. Deltas now land in a buffer and DRAIN to the visible text at a
    // steady 30Hz, a few characters per tick (adaptive: a backlog drains in
    // ~half a second, so display never falls far behind generation). Display
    // is smooth regardless of generation rhythm.
    private var streamBuffer = ""
    private var streamIndex: Int?
    private var streamFinished = false
    private var drainTimer: Timer?

    /// Characters per 30Hz tick: floor of 2 (a calm typewriter), scaling up
    /// so any backlog clears in ~15 ticks (~0.5s).
    static func drainAmount(backlog: Int) -> Int {
        max(2, backlog / 15)
    }

    func appendChunk(at index: Int, _ chunk: String) {
        guard messages.indices.contains(index) else { return }
        streamIndex = index
        streamBuffer += Self.withoutEmoji(chunk)
        if drainTimer == nil {
            drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.drainOnce() }
            }
        }
    }

    /// One 30Hz tick: move a few characters from the buffer to the screen.
    /// Internal (not private) so the self-test can drive it deterministically.
    func drainOnce() {
        if let index = streamIndex, messages.indices.contains(index), !streamBuffer.isEmpty {
            let take = String(streamBuffer.prefix(Self.drainAmount(backlog: streamBuffer.count)))
            streamBuffer.removeFirst(take.count)
            var copy = messages
            copy[index].text += take
            messages = copy
        }
        if streamBuffer.isEmpty {
            drainTimer?.invalidate()
            drainTimer = nil
            if streamFinished, let index = streamIndex {
                streamIndex = nil
                streamFinished = false
                finalizeAssistantStream(at: index)
            }
        }
    }

    /// Push everything still buffered to the screen NOW (cancel path — the
    /// typewriter shouldn't swallow text that already arrived).
    private func flushStreamBuffer() {
        if let index = streamIndex, messages.indices.contains(index), !streamBuffer.isEmpty {
            var copy = messages
            copy[index].text += streamBuffer
            messages = copy
        }
        streamBuffer = ""
        streamIndex = nil
        streamFinished = false
        drainTimer?.invalidate()
        drainTimer = nil
    }

    /// Strip emoji from DISPLAYED chat text (decided 2026-07-10: the 4B
    /// ignores "use emoji rarely" and half-ignores "do not use emoji" — probed
    /// live; a deterministic strip is the only reliable dial). Applies to chat
    /// bubbles only — tool payloads and file contents are never touched.
    static func withoutEmoji(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { isEmojiScalar($0) }) else { return s }
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !isEmojiScalar(scalar) {
            scalars.append(scalar)
        }
        // The emoji usually rode in with a space ("welcome 🫶") — tidy the gaps.
        return String(scalars)
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "[ \\t]+(\\n)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
    }

    private static func isEmojiScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1F000...0x1FAFF,     // the emoji planes (smileys, symbols, hands, …)
             0x2600...0x27BF,       // misc symbols + dingbats (☀ ✨ ❤ …)
             0x2B00...0x2BFF,       // more symbols (⭐ ⬆ …)
             0x1F1E6...0x1F1FF,     // flag letters
             0xFE0F, 0x200D:        // emoji variation selector + ZWJ
            return true
        default:
            return s.properties.isEmojiPresentation   // digits/#/© stay (text presentation)
        }
    }

    /// Add a brand-new tool_use block to the assistant message at `index`.
    func startToolUse(at index: Int, id: String, name: String) {
        guard messages.indices.contains(index) else { return }
        var copy = messages
        copy[index].toolUses.append(
            ToolUseBlock(id: id, name: name, inputJSON: "", isComplete: false)
        )
        messages = copy
    }

    /// Append a partial JSON delta to the latest tool_use block.
    func appendToolInput(at index: Int, toolId: String, _ partial: String) {
        guard messages.indices.contains(index) else { return }
        var copy = messages
        if let i = copy[index].toolUses.firstIndex(where: { $0.id == toolId }) {
            copy[index].toolUses[i].inputJSON += partial
            messages = copy
        }
    }

    /// Mark a tool_use block's input as complete.
    func finishToolUse(at index: Int, toolId: String) {
        guard messages.indices.contains(index) else { return }
        var copy = messages
        if let i = copy[index].toolUses.firstIndex(where: { $0.id == toolId }) {
            copy[index].toolUses[i].isComplete = true
            messages = copy
        }
    }

    /// The MODEL is done — but the typewriter may still be draining. Mark the
    /// stream finished; the last drain tick finalizes (so the text never cuts
    /// off mid-drain). With nothing buffered, finalizes immediately.
    func finishAssistantStream(at index: Int) {
        if streamBuffer.isEmpty {
            finalizeAssistantStream(at: index)
        } else {
            streamFinished = true
        }
    }

    private func finalizeAssistantStream(at index: Int) {
        if messages.indices.contains(index) {
            var copy = messages
            copy[index].isStreaming = false
            messages = copy
        }
        isAwaitingResponse = false
    }

    /// Stop any in-progress stream — finalize the streaming assistant message (or
    /// drop it if nothing had arrived yet) and clear the awaiting flag. Idempotent:
    /// called on EVERY loop exit so a cancelled turn never leaves the panel stuck
    /// "thinking," and directly by the user's Stop action.
    func stopStreaming() {
        flushStreamBuffer()   // text that already arrived shows in full, instantly
        if let i = messages.lastIndex(where: { $0.isStreaming }) {
            var copy = messages
            copy[i].isStreaming = false
            if copy[i].text.isEmpty && copy[i].toolUses.isEmpty {
                copy.remove(at: i)   // nothing streamed in yet — no blank bubble
            }
            messages = copy
        }
        isAwaitingResponse = false
    }

    /// Append a complete, non-streamed assistant message. Used by the agent loop
    /// for turns that were buffered off-screen (so a raw tool-call payload never
    /// shows): once the final plain-text answer is known, it's committed here.
    func commitAssistantMessage(_ text: String) {
        let trimmed = Self.withoutEmoji(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(role: .assistant, text: trimmed, isStreaming: false, image: nil))
    }

    /// Add a subtle tool-use CHIP to the transcript — an assistant message carrying
    /// one `toolUse` (rendered by `ToolUseCard`: icon + headline + status badge), plus
    /// a hidden result envelope so the card can show success/error. This is how the
    /// user sees what Handle actually DID between their message and the reply (the
    /// agent-loop tool turns are otherwise buffered off-screen).
    func addToolChip(name: String, inputJSON: String, content: String, isError: Bool, displaySummary: String?) {
        let id = UUID().uuidString
        messages.append(Message(role: .assistant, text: "", isStreaming: false, image: nil,
                                toolUses: [ToolUseBlock(id: id, name: name, inputJSON: inputJSON, isComplete: true)]))
        addToolResults([ToolResultBlock(toolUseId: id, content: content, isError: isError, displaySummary: displaySummary)])
    }

    /// Append a tool_result-only user message to send back to Claude.
    func addToolResults(_ results: [ToolResultBlock]) {
        messages.append(
            Message(
                role: .user,
                text: "",
                isStreaming: false,
                image: nil,
                toolUses: [],
                toolResults: results
            )
        )
    }

    func setError(_ message: String) {
        errorMessage = message
        isAwaitingResponse = false
        if let last = messages.last, last.role == .assistant, last.text.isEmpty, last.toolUses.isEmpty {
            messages.removeLast()
        }
    }

    func setPendingPDF(_ pdf: PendingPDF) { pendingPDF = pdf }
    func clearPendingPDF() { pendingPDF = nil }

    /// Replace the "active" capture state used by point_at — the rect/screen/image
    /// AND the AX element list the model selects from. Called on every recapture so
    /// a follow-up turn points at the CURRENT screen's elements, not the original's.
    func updateCurrentCapture(rect: CGRect, screen: NSScreen?, imagePixelSize: CGSize, axElements: [AXElement]) {
        self.captureRect = rect
        self.captureScreen = screen
        self.currentImagePixelSize = imagePixelSize
        self.axElements = axElements
    }

    /// Mark the latest user message with what happened to its screenshot.
    func markScreenshot(_ status: ScreenshotStatus) {
        guard let i = messages.lastIndex(where: { $0.role == .user && !$0.isToolResultOnly }) else { return }
        messages[i].screenshotStatus = status
    }

    func takeCaptureWithheld() -> ScreenshotStatus? {
        defer { captureWithheld = nil }
        return captureWithheld
    }

    // MARK: - Persistence (text-only snapshots — never captures/PDF bytes)

    /// Reduce this conversation to its persistable text, or nil when there's
    /// nothing worth saving (no real user/assistant turn yet). Tool chips
    /// persist as role "tool" rows (name + summary + result text); synthesized
    /// capture prompts and raw tool-result envelopes don't persist.
    func snapshot() -> ConversationSnapshot? {
        var saved: [SavedMessage] = []
        let base = hasInitialCapture ? Array(messages.dropFirst()) : messages
        for m in base {
            switch m.role {
            case .user:
                guard !m.isToolResultOnly, !m.text.isEmpty else { continue }
                saved.append(SavedMessage(role: "user", text: m.text, toolName: nil, toolSummary: nil))
            case .assistant:
                if let chip = m.toolUses.first, m.text.isEmpty {
                    let result = toolResult(forUseId: chip.id)
                    saved.append(SavedMessage(role: "tool",
                                              text: result?.content ?? "",
                                              toolName: chip.name,
                                              toolSummary: result?.displaySummary))
                } else if !m.text.isEmpty, !m.isStreaming {
                    saved.append(SavedMessage(role: "assistant", text: m.text, toolName: nil, toolSummary: nil))
                }
            }
        }
        guard saved.contains(where: { $0.role != "tool" }) else { return nil }
        let firstUser = saved.first(where: { $0.role == "user" })?.text ?? "Conversation"
        let fallback = String(String(firstUser.split(separator: "\n").first.map(String.init) ?? firstUser).prefix(60))
        // "" is the in-flight claim marker (generation started, not landed) —
        // never persist it; the first-line fallback stands until a real title.
        let generated = (generatedTitle?.isEmpty == false) ? generatedTitle! : nil
        return ConversationSnapshot(id: persistentID,
                                    title: generated ?? fallback,
                                    appName: appName,
                                    createdAt: createdAt,
                                    updatedAt: Date(),
                                    messages: saved)
    }

    /// A model-written 2–4 word title (2026-07-10 — raw first lines
    /// made the Chats list unscannable). Set once per conversation, after the
    /// first real exchange; `snapshot()` prefers it. Restored conversations
    /// carry their stored title here so a later save never regresses it.
    var generatedTitle: String?

    /// Clean a model-emitted title: strip quotes/trailing punctuation/emoji,
    /// collapse whitespace, cap at 40 chars. nil = unusable (keep the fallback).
    static func sanitizedTitle(_ raw: String) -> String? {
        var t = withoutEmoji(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.。!?"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !t.isEmpty, t.count >= 3 else { return nil }
        guard t.split(separator: " ").count <= 6 else { return nil }   // a sentence is not a title
        if t.count > 40 { t = String(t.prefix(40)) }
        return t
    }

    /// Rebuild a (text-only, continuable) conversation from a snapshot. The
    /// restored thread is an Ask conversation — no capture context — but keeps
    /// its persistent identity, so further turns update the same row.
    static func restore(from snap: ConversationSnapshot) -> Conversation {
        let convo = Conversation(chatWithApp: snap.appName,
                                 persistentID: snap.id,
                                 createdAt: snap.createdAt)
        convo.generatedTitle = snap.title   // keep the stored title; never regress to first-line on re-save
        for m in snap.messages {
            switch m.role {
            case "user":      convo.addUserMessage(m.text)
            case "assistant": convo.commitAssistantMessage(m.text)
            case "tool":
                convo.addToolChip(name: m.toolName ?? "tool", inputJSON: "{}",
                                  content: m.text, isError: false, displaySummary: m.toolSummary)
            default: break
            }
        }
        return convo
    }
}
