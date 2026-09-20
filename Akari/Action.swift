import Foundation
import CoreGraphics

/// One of the six things the user can do with a captured region.
enum ActionType: String, CaseIterable, Identifiable, Hashable {
    case identify
    case explain
    case summarize
    case extract
    case rewrite
    case ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identify:  return "What is this?"
        case .explain:   return "Explain simply"
        case .summarize: return "Summarize"
        case .extract:   return "Extract"
        case .rewrite:   return "Rewrite"
        case .ask:       return "Ask…"
        }
    }

    var symbol: String {
        switch self {
        case .identify:  return "questionmark.circle"
        case .explain:   return "lightbulb"
        case .summarize: return "list.bullet.rectangle"
        case .extract:   return "tablecells"
        case .rewrite:   return "wand.and.stars"
        case .ask:       return "text.cursor"
        }
    }

    /// 1–6 keyboard shortcut to fire this action from the menu.
    var keyEquivalent: String {
        switch self {
        case .identify:  return "1"
        case .explain:   return "2"
        case .summarize: return "3"
        case .extract:   return "4"
        case .rewrite:   return "5"
        case .ask:       return "6"
        }
    }

    /// Verb shown while streaming (e.g. "Explaining…").
    var inProgressLabel: String {
        switch self {
        case .identify:  return "Identifying…"
        case .explain:   return "Explaining…"
        case .summarize: return "Summarizing…"
        case .extract:   return "Extracting…"
        case .rewrite:   return "Rewriting…"
        case .ask:       return "Thinking…"
        }
    }
}

/// What the user picked from the menu — type plus the typed question for `.ask`.
struct ActionRequest: Hashable {
    let type: ActionType
    let askText: String

    init(type: ActionType, askText: String = "") {
        self.type = type
        self.askText = askText
    }
}

/// Prompt templates. (The old cloud-era `system` prompt was removed 2026-09-19 —
/// the system prompt now lives in `AgentPrompting.identity` + the loop's rules.)
enum Prompts {
    static func userMessage(
        request: ActionRequest,
        appName: String,
        ocrText: String?
    ) -> String {
        var parts: [String] = []

        // Context
        parts.append("Current app: \(appName)")
        parts.append("Current local time: \(currentLocalTime())")

        if let ocr = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
            parts.append("Visible text (from OCR — may contain errors):\n\(ocr)")
        }

        // Action-specific instruction
        parts.append(instruction(for: request))
        return parts.joined(separator: "\n\n")
    }

    private static func currentLocalTime() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        let iso = f.string(from: Date())
        let tzName = TimeZone.current.identifier
        return "\(iso) (\(tzName))"
    }

    private static func instruction(for request: ActionRequest) -> String {
        switch request.type {
        case .identify:
            return """
            Identify what's at the highlighted region. Lead with the name or category, then add one clarifying detail. One or two sentences. No hedging.
            """

        case .explain:
            return """
            Explain what's at the highlighted region in plain language for someone unfamiliar with the topic. Avoid jargon; if a technical term is unavoidable, define it inline in five words or fewer. Two to four sentences. Do not state what the image shows — explain the underlying concept.
            """

        case .summarize:
            return """
            Summarize the visible content. Use 2–4 bullets if multiple distinct points are present, otherwise a short paragraph (2–3 sentences). Preserve specifics — names, numbers, dates, identifiers, quoted phrases.
            """

        case .extract:
            return """
            Extract the structured information from the visible content into Markdown.

            Conventions:
            - Tabular data → a Markdown table with header row.
            - Forms, invoices, contact cards, key-value data → a list with **Field**: value.
            - Code → a fenced code block, language tag inferred.
            - Bulleted or numbered lists → a Markdown list.

            If multiple structures coexist, separate them with blank lines. Output only the extracted data — no explanation, no commentary.
            """

        case .rewrite:
            return """
            Rewrite the visible text. Goal: clearer, tighter, more professional — while preserving meaning, names, dates, intent, and the writer's voice. Cut redundancies and filler. Match the source's apparent register (formal email vs. casual message; keep it casual if it was casual). Output only the rewritten text — no quoting the original, no commentary.
            """

        case .ask:
            let q = request.askText.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            The user's request about the highlighted region:

            > \(q.isEmpty ? "(empty request)" : q)

            If the request is asking you to *do* something a tool can handle (for example "add this to my calendar", "what's on my calendar Friday", "schedule this for Wednesday at 2pm"), call the appropriate tool. Don't describe what you would do — call the tool. The app will ask the user to confirm any write action.

            Otherwise answer the question using only what's visible in the screenshot (and OCR text above when relevant). If a question can't be determined from the visible content, say so plainly in one sentence.
            """
        }
    }
}
