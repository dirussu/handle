import AppKit
import CoreGraphics

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
    /// exact frame, so the model never estimates coordinates (which a small local model
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
    /// prompt right next to the user's text (a small model ignores context placed
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

    // The mutations below all use the explicit copy-modify-assign pattern.
    // Reason: `@Observable` doesn't reliably notify observers when a struct
    // field is mutated in place through an array subscript (Swift uses
    // Array's `_modify` coroutine, which can bypass the property's setter
    // and skip the macro-generated `withMutation` notification). Reading
    // `messages` and assigning the whole array back guarantees the setter
    // fires, which is what makes the live chat panel re-render mid-stream.
    /// Messages typed WHILE a turn runs : they queue here
    /// and the loop's exit drains them in order — each gets a fresh capture
    /// when ITS turn starts. Stop clears the queue along with the turn.
    var queuedTexts: [String] = []

    // Streaming presentation ("typing isn't smooth"):
    // model tokens arrive in BURSTS — several words, then a pause — and every
    // burst re-parsed the markdown and re-laid-out the panel, which read as
    // stutter. Deltas now land in a buffer and DRAIN to the visible text at a
    // steady 30Hz, a few characters per tick (adaptive: a backlog drains in
    // ~half a second, so display never falls far behind generation). Display
    // is smooth regardless of generation rhythm.
    var streamBuffer = ""

    var streamIndex: Int?

    var streamFinished = false

    var drainTimer: Timer?

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

    /// A model-written 2–4 word title (raw first lines
    /// made the Chats list unscannable). Set once per conversation, after the
    /// first real exchange; `snapshot()` prefers it. Restored conversations
    /// carry their stored title here so a later save never regresses it.
    var generatedTitle: String?
}
