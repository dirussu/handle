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
