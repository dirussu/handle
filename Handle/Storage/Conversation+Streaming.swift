import AppKit
import CoreGraphics

// Streaming an assistant reply into the transcript: buffering, the typewriter drain, tool-use blocks.

extension Conversation {
    /// Append a fresh assistant message that the streaming loop will fill.
    @discardableResult
    func startAssistantStream() -> Int {
        messages.append(Message(role: .assistant, text: "", isStreaming: true, image: nil))
        isAwaitingResponse = true
        errorMessage = nil
        return messages.count - 1
    }

    /// Characters per 30Hz tick: floor of 2 (a calm typewriter), scaling up
    /// so any backlog clears in ~15 ticks (~0.5s).
    static func drainAmount(backlog: Int) -> Int {
        max(2, backlog / 15)
    }

    func appendChunk(at index: Int, _ chunk: String) {
        guard messages.indices.contains(index) else { return }
        streamIndex = index
        streamBuffer += Self.withoutEmoji(chunk)
        if drainTimer == nil {
            drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.drainOnce() }
            }
        }
    }

    /// One 30Hz tick: move a few characters from the buffer to the screen.
    /// Internal (not private) so the self-test can drive it deterministically.
    func drainOnce() {
        if let index = streamIndex, messages.indices.contains(index), !streamBuffer.isEmpty {
            let take = String(streamBuffer.prefix(Self.drainAmount(backlog: streamBuffer.count)))
            streamBuffer.removeFirst(take.count)
            var copy = messages
            copy[index].text += take
            messages = copy
        }
        if streamBuffer.isEmpty {
            drainTimer?.invalidate()
            drainTimer = nil
            if streamFinished, let index = streamIndex {
                streamIndex = nil
                streamFinished = false
                finalizeAssistantStream(at: index)
            }
        }
    }

    /// Push everything still buffered to the screen NOW (cancel path — the
    /// typewriter shouldn't swallow text that already arrived).
    private func flushStreamBuffer() {
        if let index = streamIndex, messages.indices.contains(index), !streamBuffer.isEmpty {
            var copy = messages
            copy[index].text += streamBuffer
            messages = copy
        }
        streamBuffer = ""
        streamIndex = nil
        streamFinished = false
        drainTimer?.invalidate()
        drainTimer = nil
    }

    /// Strip emoji from DISPLAYED chat text (a small model
    /// ignores "use emoji rarely" and half-ignores "do not use emoji" — probed
    /// live; a deterministic strip is the only reliable dial). Applies to chat
    /// bubbles only — tool payloads and file contents are never touched.
    static func withoutEmoji(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { isEmojiScalar($0) }) else { return s }
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !isEmojiScalar(scalar) {
            scalars.append(scalar)
        }
        // The emoji usually rode in with a space ("welcome 🫶") — tidy the gaps.
        return String(scalars)
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "[ \\t]+(\\n)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
    }

    private static func isEmojiScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1F000...0x1FAFF,     // the emoji planes (smileys, symbols, hands, …)
             0x2600...0x27BF,       // misc symbols + dingbats (☀ ✨ ❤ …)
             0x2B00...0x2BFF,       // more symbols (⭐ ⬆ …)
             0x1F1E6...0x1F1FF,     // flag letters
             0xFE0F, 0x200D:        // emoji variation selector + ZWJ
            return true
        default:
            return s.properties.isEmojiPresentation   // digits/#/© stay (text presentation)
        }
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

    /// The MODEL is done — but the typewriter may still be draining. Mark the
    /// stream finished; the last drain tick finalizes (so the text never cuts
    /// off mid-drain). With nothing buffered, finalizes immediately.
    func finishAssistantStream(at index: Int) {
        if streamBuffer.isEmpty {
            finalizeAssistantStream(at: index)
        } else {
            streamFinished = true
        }
    }

    private func finalizeAssistantStream(at index: Int) {
        if messages.indices.contains(index) {
            var copy = messages
            copy[index].isStreaming = false
            messages = copy
        }
        isAwaitingResponse = false
    }

    /// Stop any in-progress stream — finalize the streaming assistant message (or
    /// drop it if nothing had arrived yet) and clear the awaiting flag. Idempotent:
    /// called on EVERY loop exit so a cancelled turn never leaves the panel stuck
    /// "thinking," and directly by the user's Stop action.
    func stopStreaming() {
        flushStreamBuffer()   // text that already arrived shows in full, instantly
        if let i = messages.lastIndex(where: { $0.isStreaming }) {
            var copy = messages
            copy[i].isStreaming = false
            if copy[i].text.isEmpty && copy[i].toolUses.isEmpty {
                copy.remove(at: i)   // nothing streamed in yet — no blank bubble
            }
            messages = copy
        }
        isAwaitingResponse = false
    }
}
