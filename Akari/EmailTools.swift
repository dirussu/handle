import AppKit

enum EmailToolError: LocalizedError {
    case urlBuildFailed
    case openFailed
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .urlBuildFailed:    return "Couldn't build mailto URL."
        case .openFailed:        return "Couldn't open the default mail app."
        case .decodeFailed(let s): return "Tool input invalid: \(s)."
        }
    }
}

struct DraftEmailReplyInput: Decodable {
    let to: String?
    let subject: String?
    let body: String
}

@MainActor
final class EmailTools {
    static let shared = EmailTools()
    private init() {}

    static var tools: [Tool] {
        [draftReplyTool]
    }

    static let draftReplyTool = Tool(
        name: "draft_email_reply",
        description: """
        Draft a reply to an email or message that's visible on the user's screen. \
        The user is shown the draft (recipient, subject, body) for review and confirms before \
        it's opened in their default mail app. Akari NEVER sends — the user reviews and clicks Send themselves.

        Use this when the user asks you to "draft a reply", "write a response", "reply politely", \
        or any phrasing that wants you to compose a message back to someone in the visible content. \
        Match the user's apparent register (formal vs. casual) and the tone they request.
        """,
        inputSchema: [
            "type": "object",
            "properties": [
                "to": [
                    "type": "string",
                    "description": "Recipient email address. Extract from the visible email; leave empty if you can't determine it confidently — the user can fill it in."
                ],
                "subject": [
                    "type": "string",
                    "description": "Reply subject line, typically 'Re: <original subject>'. Leave empty if unknown."
                ],
                "body": [
                    "type": "string",
                    "description": "The drafted reply body, ready to send. Plain text. Match the writing style of the visible content and the requested tone."
                ],
            ],
            "required": ["body"]
        ],
        confirmation: .confirm
    )

    func decodeDraftReply(from json: String) throws -> DraftEmailReplyInput {
        guard let data = json.data(using: .utf8) else {
            throw EmailToolError.decodeFailed("not UTF-8")
        }
        return try JSONDecoder().decode(DraftEmailReplyInput.self, from: data)
    }

    /// Open the user's default mail client with a pre-filled compose window
    /// via a `mailto:` URL. The user clicks Send themselves.
    func openMailDraft(to: String?, subject: String?, body: String) throws {
        // Per RFC 6068, mailto values must percent-encode reserved chars.
        // We exclude the mailto-meaningful chars (& = ? #) from the allowed set.
        let allowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=?#"))

        var urlString = "mailto:"
        if let to, !to.isEmpty {
            urlString += to.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }

        var queryParts: [String] = []
        if let subject, !subject.isEmpty {
            let s = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            queryParts.append("subject=\(s)")
        }
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        queryParts.append("body=\(b)")

        if !queryParts.isEmpty {
            urlString += "?" + queryParts.joined(separator: "&")
        }

        guard let url = URL(string: urlString) else {
            throw EmailToolError.urlBuildFailed
        }
        guard NSWorkspace.shared.open(url) else {
            throw EmailToolError.openFailed
        }
    }
}
