import AppKit

enum MessageToolError: LocalizedError {
    case urlBuildFailed
    case openFailed
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .urlBuildFailed:    return "Couldn't build sms URL."
        case .openFailed:        return "Couldn't open Messages."
        case .decodeFailed(let s): return "Tool input invalid: \(s)."
        }
    }
}

struct DraftIMessageInput: Decodable {
    let to: String?
    let body: String
}

@MainActor
final class MessageTools {
    static let shared = MessageTools()
    private init() {}

    static var tools: [Tool] {
        [draftIMessageTool]
    }

    static let draftIMessageTool = Tool(
        name: "draft_imessage",
        description: """
        Draft an iMessage / SMS reply that lands in the user's CURRENTLY FOCUSED chat. Akari pastes \
        the body into the active conversation's input field — it does not open a new compose window or \
        switch chats. Akari NEVER sends — the user reviews and clicks Send themselves.

        Use this when the user is in Messages.app with a chat open and asks you to draft a reply or \
        message. For email replies use draft_email_reply instead. For other chat apps (Slack, Discord, \
        WhatsApp, Telegram), this tool also works as a generic "paste into the focused text field" \
        — call it anyway when the user is in one of those apps and asks for a draft. For non-chat \
        contexts, write the drafted body in your chat reply so the user can copy it.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "to": [
                    "type": "string",
                    "description": "Optional recipient label (name, phone number, or handle) — used only for display in the confirmation card. The actual recipient is whoever's chat is currently focused in the messaging app."
                ],
                "body": [
                    "type": "string",
                    "description": "The drafted message body, ready to send. Match the casual tone of the visible context."
                ],
            ],
            "required": ["body"]
        ],
        confirmation: .confirm
    )

    func decodeDraft(from json: String) throws -> DraftIMessageInput {
        guard let data = json.data(using: .utf8) else {
            throw MessageToolError.decodeFailed("not UTF-8")
        }
        return try JSONDecoder().decode(DraftIMessageInput.self, from: data)
    }

    /// Open Messages.app with the recipient selected and the body pre-filled in
    /// the chat input field via the `sms:` URL scheme. The user clicks Send themselves.
    func openMessageDraft(to: String?, body: String) throws {
        let allowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=?#"))

        var urlString = "sms:"
        if let to, !to.isEmpty {
            urlString += to.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        urlString += "?body=\(b)"

        guard let url = URL(string: urlString) else {
            throw MessageToolError.urlBuildFailed
        }
        guard NSWorkspace.shared.open(url) else {
            throw MessageToolError.openFailed
        }
    }
}
