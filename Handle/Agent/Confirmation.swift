import AppKit
import OSLog

// The confirmation card: what it shows and how the loop waits for the answer.

extension AppDelegate {
    /// Confirm-card await — present the card with explicit title + rows and SUSPEND
    /// the loop until the user taps, bridging the `ConfirmationRequest.onDecision`
    /// callback to a continuation. `withCheckedContinuation` suspends the loop task
    /// without blocking the MainActor, so the card renders and the tap is processed
    /// normally; the working-comet pauses while the user decides. Used by tool calls,
    /// recipe runs, and the screenshot-consent question.
    /// DEBUG harness only (`__autoapprove__ on|off`): confirm cards approve themselves so
    /// consequential tools can be exercised without a hand on the notch.
    static var debugAutoApprove = false

    @MainActor
    func awaitConfirmation(in conversation: Conversation, title: String,
                                  rows: [(label: String, value: String)], label: String,
                                  destructive: Bool = false) async -> Bool {
        #if DEBUG
        if Self.debugAutoApprove {
            agentLog.info("awaitConfirmation: AUTO-APPROVED (debug harness) \(label, privacy: .public) — \(title, privacy: .public)")
            return true
        }
        #endif
        agentLog.info("awaitConfirmation: SHOW card for \(label, privacy: .public)")
        NotchController.shared.setWorking(false)
        defer { NotchController.shared.setWorking(true) }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conversation.pendingConfirmation = ConfirmationRequest(
                title: title, detailRows: rows, confirmLabel: "Run", cancelLabel: "Cancel",
                isDestructive: destructive,
                onDecision: { approved in
                    agentLog.info("awaitConfirmation: decision=\(approved) for \(label, privacy: .public)")
                    conversation.pendingConfirmation = nil
                    cont.resume(returning: approved)
                }
            )
        }
    }
}

/// The words on a confirmation card: its title and one row per argument.
enum ConfirmationText {
    /// Friendly card title from a tool name: "create_calendar_event" → "Create calendar event?".
    static func title(_ toolName: String) -> String {
        let phrase = toolName.split(separator: "_").joined(separator: " ")
        return phrase.isEmpty ? "Run this action?" : "\(phrase.prefix(1).uppercased())\(phrase.dropFirst())?"
    }

    /// One card row per NON-EMPTY argument, in a sensible order with friendly labels
    /// and (for ISO dates) human-readable local times — so the user can verify the
    /// action at a glance before approving.
    static func rows(args: [String: Any]) -> [(label: String, value: String)] {
        let pretty = ["purpose": "What it does", "title": "Title", "start_iso": "Starts", "end_iso": "Ends",
                      "due_iso": "Due", "priority": "Priority", "path": "File", "src": "From", "dst": "To",
                      "location": "Location", "notes": "Notes", "to": "To", "subject": "Subject",
                      "body": "Body", "message": "Message", "content": "Contents", "script": "Script",
                      "command": "Command", "working_directory": "In folder", "app": "In app", "key": "Key", "modifiers": "With", "text": "Text"]
        // Long fields (content, script) go LAST; everything else reads top-down.
        let order = ["purpose", "title", "start_iso", "end_iso", "due_iso", "priority", "to", "subject",
                     "location", "notes", "path", "src", "dst", "command", "working_directory",
                     "app", "key", "modifiers", "text", "message", "body", "content", "script"]
        func rank(_ k: String) -> Int { order.firstIndex(of: k) ?? order.count }
        return args
            .sorted { rank($0.key) < rank($1.key) }
            .compactMap { (k, v) -> (label: String, value: String)? in
                var val = ConfirmationText.friendlyValue(key: k, raw: String(describing: v))
                guard !val.isEmpty else { return nil }
                if val.count > 1000 { val = String(val.prefix(1000)) + "\n… (+\(val.count - 1000) more characters)" }
                return (label: pretty[k] ?? k, value: val)
            }
    }

    /// Render an argument value for display: ISO datetimes become a local
    /// "Jul 1, 2026 at 3:00 PM"; everything else is passed through (trimmed).
    static func friendlyValue(key: String, raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasSuffix("_iso"), !trimmed.isEmpty, let d = CalendarTools.parseDate(trimmed) {
            let out = DateFormatter(); out.dateStyle = .medium; out.timeStyle = .short
            return out.string(from: d)
        }
        return trimmed
    }
}
