import AppKit
import CoreGraphics

/// One turn in an Akari conversation.
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
    func appendChunk(at index: Int, _ chunk: String) {
        guard messages.indices.contains(index) else { return }
        var copy = messages
        copy[index].text += chunk
        messages = copy
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

    func finishAssistantStream(at index: Int) {
        if messages.indices.contains(index) {
            var copy = messages
            copy[index].isStreaming = false
            messages = copy
        }
        isAwaitingResponse = false
    }

    /// Append a complete, non-streamed assistant message. Used by the agent loop
    /// for turns that were buffered off-screen (so a raw tool-call payload never
    /// shows): once the final plain-text answer is known, it's committed here.
    func commitAssistantMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(role: .assistant, text: trimmed, isStreaming: false, image: nil))
    }

    /// Add a subtle tool-use CHIP to the transcript — an assistant message carrying
    /// one `toolUse` (rendered by `ToolUseCard`: icon + headline + status badge), plus
    /// a hidden result envelope so the card can show success/error. This is how the
    /// user sees what Akari actually DID between their message and the reply (the
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
        let title = String(firstUser.split(separator: "\n").first.map(String.init) ?? firstUser).prefix(60)
        return ConversationSnapshot(id: persistentID,
                                    title: String(title),
                                    appName: appName,
                                    createdAt: createdAt,
                                    updatedAt: Date(),
                                    messages: saved)
    }

    /// Rebuild a (text-only, continuable) conversation from a snapshot. The
    /// restored thread is an Ask conversation — no capture context — but keeps
    /// its persistent identity, so further turns update the same row.
    static func restore(from snap: ConversationSnapshot) -> Conversation {
        let convo = Conversation(chatWithApp: snap.appName,
                                 persistentID: snap.id,
                                 createdAt: snap.createdAt)
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
