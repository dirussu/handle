import AppKit
import CoreGraphics

// Saving and restoring a conversation as a text-only snapshot. Captures and PDF bytes are never stored.

extension Conversation {
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
