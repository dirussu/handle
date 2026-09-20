import Foundation

/// CUSTOM INSTRUCTIONS — the user's standing note to the model, sent with every
/// request (CUSTOMIZING.md). Stored as plain text at
/// `~/Library/Application Support/Akari/instructions.md`, editable in Settings →
/// Customize or in any editor.
@MainActor
enum UserInstructions {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Akari/instructions.md")
    static let maxChars = 4000

    static var text: String { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }

    static func save(_ text: String) {
        let t = String(text.prefix(maxChars))
        if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? t.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// The system-prompt block, or "" when there are no instructions.
    static var promptBlock: String { block(for: text) }

    nonisolated static func block(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return "# The user's standing instructions\nWritten by the user in Settings → Customize. Follow them as you would their message, unless one conflicts with the rules above.\n"
            + String(t.prefix(maxChars))
    }
}
