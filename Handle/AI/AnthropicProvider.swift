import Foundation

/// Anthropic Messages API adapter (`POST /v1/messages`, streaming).
/// Wire mapping only — no prompts live here. The event decoder is a pure
/// struct so the SSE → AIStreamEvent mapping is covered by unit tests.
nonisolated struct AnthropicProvider: AIProvider {
    let id = "anthropic"
    let apiKey: String
    let defaultModel: String
    var supportsVision: Bool { true }
    var supportsTools: Bool { true }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    /// Bundled model choices (Settings picker). Ids are complete as-is.
    static let knownModels = ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5"]

    init(apiKey: String, defaultModel: String = "claude-sonnet-5") {
        self.apiKey = apiKey
        self.defaultModel = defaultModel
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        // Serialize up front so the (non-Sendable) dictionaries never cross into the Task.
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: request.model ?? defaultModel))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("text/event-stream", forHTTPHeaderField: "accept")
        req.httpBody = bodyData
        req.timeoutInterval = 180
        let provider = id
        let frozen = req                                             // immutable copy for the Task
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await AIHTTP.openStream(frozen, provider: provider)
                    var decoder = EventDecoder()
                    for try await sse in SSEParser.events(from: bytes) {
                        if Task.isCancelled { break }
                        for ev in try decoder.decode(sse) { continuation.yield(ev) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request encoding

    static func body(for request: AIRequest, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "thinking": ["type": "adaptive"],
        ]
        // Prompt caching: tools → system → messages is the cache order, so the
        // stable prefix (tool schemas + system prompt, ~6k tokens on an action
        // turn) gets a breakpoint each. Per-turn data (time, memory, screenshot)
        // lives in the messages, after the breakpoints, so it never invalidates them.
        let system = request.messages.filter { $0.role == .system }.map(\.text)
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty {
            body["system"] = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
        }
        if let effort = request.effort { body["output_config"] = ["effort": effort.rawValue] }
        body["messages"] = encodeMessages(request.messages)
        if !request.tools.isEmpty {
            var tools = request.tools.map(encodeTool)
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
            body["tools"] = tools
        }
        return body
    }

    /// Anthropic wants strictly alternating user/assistant turns starting with
    /// user, and no empty text blocks. Tool results are user-role content.
    static func encodeMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages where m.role != .system {
            let role = (m.role == .assistant) ? "assistant" : "user"
            let content = m.parts.compactMap(encodePart)
            guard !content.isEmpty else { continue }
            if out.isEmpty && role == "assistant" { continue }          // must start with user
            if let last = out.last, last["role"] as? String == role,
               let prev = last["content"] as? [[String: Any]] {
                out[out.count - 1]["content"] = prev + content            // merge adjacent same-role turns
            } else {
                out.append(["role": role, "content": content])
            }
        }
        return out
    }

    static func encodePart(_ part: AIMessage.Part) -> [String: Any]? {
        switch part {
        case .text(let t):
            return t.isEmpty ? nil : ["type": "text", "text": t]
        case .image(let data, let mime):
            return ["type": "image",
                    "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]]
        case .toolCall(let id, let name, let json):
            let input = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            return ["type": "tool_use", "id": id, "name": name, "input": input]
        case .toolResult(let id, let text, let isError, let image):
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": id]
            if let image {   // text + image blocks inside the result
                var content: [[String: Any]] = []
                if !text.isEmpty { content.append(["type": "text", "text": text]) }
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
                block["content"] = content
            } else {
                block["content"] = text
            }
            if isError { block["is_error"] = true }
            return block
        }
    }

    static func encodeTool(_ tool: AIToolSpec) -> [String: Any] {
        // A server-side tool (web search): `type` + `name` (+ options), no schema.
        if let serverType = tool.serverType {
            var t: [String: Any] = ["type": serverType, "name": tool.name]
            for (k, v) in tool.inputSchema { t[k] = v }
            return t
        }
        var t: [String: Any] = ["name": tool.name, "description": tool.description, "input_schema": tool.inputSchema]
        // strict only for schemas we wrote (needs additionalProperties:false +
        // required); third-party (MCP) schemas carry keywords strict mode rejects.
        if tool.strict { t["strict"] = true }
        return t
    }

    // MARK: Response decoding (pure)

    struct EventDecoder {
        private var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]
        private var stopReason: String?
        private var refusalCategory: String?

        mutating func decode(_ sse: SSEEvent) throws -> [AIStreamEvent] {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(sse.data.utf8)) as? [String: Any] else { return [] }
            let type = (obj["type"] as? String) ?? sse.event ?? ""
            switch type {
            case "message_start":
                guard let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] else { return [] }
                return [.usage(input: usage["input_tokens"] as? Int, output: nil,
                               cacheRead: usage["cache_read_input_tokens"] as? Int,
                               cacheWrite: usage["cache_creation_input_tokens"] as? Int)]
            case "content_block_start":
                guard let index = obj["index"] as? Int,
                      let block = obj["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use" else { return [] }
                toolBlocks[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
                return []
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any] else { return [] }
                switch delta["type"] as? String {
                case "text_delta":
                    if let t = delta["text"] as? String, !t.isEmpty { return [.textDelta(t)] }
                case "input_json_delta":
                    if let index = obj["index"] as? Int, let partial = delta["partial_json"] as? String {
                        toolBlocks[index]?.json += partial
                    }
                default: break                                   // thinking deltas etc.
                }
                return []
            case "content_block_stop":
                guard let index = obj["index"] as? Int, let b = toolBlocks.removeValue(forKey: index) else { return [] }
                return [.toolCall(id: b.id, name: b.name, argumentsJSON: b.json.isEmpty ? "{}" : b.json)]
            case "message_delta":
                var events: [AIStreamEvent] = []
                if let delta = obj["delta"] as? [String: Any] {
                    stopReason = delta["stop_reason"] as? String ?? stopReason
                    refusalCategory = (delta["stop_details"] as? [String: Any])?["category"] as? String ?? refusalCategory
                }
                if let usage = obj["usage"] as? [String: Any] {
                    events.append(.usage(input: usage["input_tokens"] as? Int, output: usage["output_tokens"] as? Int,
                                         cacheRead: usage["cache_read_input_tokens"] as? Int,
                                         cacheWrite: usage["cache_creation_input_tokens"] as? Int))
                }
                return events
            case "message_stop":
                return [.done(stopReason: stopReason)]
            case "error":
                let err = obj["error"] as? [String: Any]
                let message = err?["message"] as? String ?? "unknown error"
                if err?["type"] as? String == "overloaded_error" { throw AIProviderError.rateLimited(provider: "anthropic") }
                throw AIProviderError.http(status: 0, message: message)
            default:
                return []                                        // ping, unknown
            }
        }

        var lastRefusalCategory: String? { refusalCategory }
    }
}
