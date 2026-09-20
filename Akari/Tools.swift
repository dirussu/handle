import Foundation
import CoreGraphics

/// JSON Schema-shaped dictionary describing a tool's input.
typealias ToolSchema = [String: Any]

/// A tool exposed to Claude.
struct Tool {
    let name: String
    let description: String
    let inputSchema: ToolSchema
    let confirmation: ToolConfirmation
}

/// Whether a tool needs the user to confirm before execution.
enum ToolConfirmation {
    case auto    // Read-only — execute immediately.
    case confirm // Show a confirmation sheet first.
}

/// A tool call recorded in the conversation. The `inputJSON` field is built up
/// from streaming `input_json_delta` chunks during the API stream.
struct ToolUseBlock: Identifiable, Hashable {
    let id: String
    let name: String
    var inputJSON: String
    var isComplete: Bool

    static func == (lhs: ToolUseBlock, rhs: ToolUseBlock) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Result of executing a tool. `content` is the string fed back to Claude;
/// `displaySummary` is a short label shown in the UI. Optional `attachedImage`
/// and `attachedPDF` let a tool return a file (image or PDF) for Claude to
/// inspect — used by read_file / pick_file when the user picks a binary file.
struct ToolResultBlock {
    let toolUseId: String
    let content: String
    let isError: Bool
    let displaySummary: String?
    let attachedImage: CGImage?
    let attachedPDF: Data?

    init(
        toolUseId: String,
        content: String,
        isError: Bool,
        displaySummary: String?,
        attachedImage: CGImage? = nil,
        attachedPDF: Data? = nil
    ) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
        self.displaySummary = displaySummary
        self.attachedImage = attachedImage
        self.attachedPDF = attachedPDF
    }
}

/// A request for the user to confirm a write/send tool call.
/// The orchestrator awaits the user's decision via `onDecision`.
struct ConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let detailRows: [(label: String, value: String)]
    let confirmLabel: String
    let cancelLabel: String
    let isDestructive: Bool
    let onDecision: (Bool) -> Void
}
