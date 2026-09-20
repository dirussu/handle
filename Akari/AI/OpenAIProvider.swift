import Foundation

/// OpenAI Chat Completions adapter — and the door to every OpenAI-compatible
/// server (LM Studio, Ollama, OpenRouter, …) through `baseURL`. Chat Completions
/// rather than Responses precisely because compatible servers implement it.
/// Wire mapping only; the event decoder is a pure struct (self-tested).
nonisolated struct OpenAIProvider: AIProvider {
    let id = "openai"
    /// Empty = no Authorization header (local servers don't want one).
    let apiKey: String
    let baseURL: URL
    let defaultModel: String
    let supportsVision: Bool
    let supportsTools: Bool

    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    /// Suggestions for the picker — the real list comes from `/v1/models`.
    static let knownModels = ["gpt-5", "gpt-5-mini", "gpt-4.1", "gpt-4o"]

    init(apiKey: String, baseURL: URL? = nil, defaultModel: String = "gpt-5",
         supportsVision: Bool = true, supportsTools: Bool = true) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.defaultModel = defaultModel
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
    }

    // MARK: Base URL helpers (pure)

    /// "localhost:1234" → "http://localhost:1234/v1"; trailing slashes dropped;
    /// "/v1" appended when missing. nil for garbage.
    static func normalizeBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return url.path.hasSuffix("/v1") ? url : url.appendingPathComponent("v1")
    }

    static func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host) || host.hasSuffix(".local")
    }

    // MARK: Streaming

    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: request.model ?? defaultModel, includeTools: supportsTools))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData
        req.timeoutInterval = 180
        let provider = id
        let frozen = req
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await AIHTTP.openStream(frozen, provider: provider)
                    var decoder = EventDecoder()
                    for try await sse in SSEParser.events(from: bytes) {
                        if Task.isCancelled { break }
                        for ev in try decoder.decode(sse) { continuation.yield(ev) }
                    }
                    for ev in decoder.finish() { continuation.yield(ev) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GET /v1/models` → ids, sorted. For Settings' "Fetch models".
    static func fetchModels(baseURL: URL, apiKey: String) async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw AIProviderError.keyRejected(provider: "OpenAI") }
            throw AIProviderError.http(status: http.statusCode, message: AIHTTP.errorMessage(from: data) ?? "models request failed")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else {
            throw AIProviderError.malformedResponse("no model list")
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Request encoding (pure)

    static func body(for request: AIRequest, model: String, includeTools: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": encodeMessages(request.messages),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        let clientTools = request.tools.filter { $0.inputSchema["__server_type"] == nil }   // server-side tools are Anthropic-only
        if includeTools && !clientTools.isEmpty { body["tools"] = clientTools.map(encodeTool) }
        return body
    }

    /// Tool results become their own `tool` messages (they must directly follow
    /// the assistant's `tool_calls`); text-only user turns stay plain strings for
    /// the widest server compatibility; images ride as data URLs.
    static func encodeMessages(_ messages: [AIMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system:
                let t = m.text
                if !t.isEmpty { out.append(["role": "system", "content": t]) }
            case .assistant:
                var msg: [String: Any] = ["role": "assistant"]
                let calls: [[String: Any]] = m.parts.compactMap { part in
                    if case .toolCall(let id, let name, let json) = part {
                        return ["id": id, "type": "function", "function": ["name": name, "arguments": json]]
                    }
                    return nil
                }
                let text = m.text
                if !text.isEmpty { msg["content"] = text }
                if !calls.isEmpty { msg["tool_calls"] = calls }
                if !text.isEmpty || !calls.isEmpty { out.append(msg) }
            case .user, .tool:
                var content: [[String: Any]] = []
                var results: [[String: Any]] = []
                var resultImages: [Data] = []   // tool messages are text-only here; images follow as a user message
                for part in m.parts {
                    switch part {
                    case .text(let t):
                        if !t.isEmpty { content.append(["type": "text", "text": t]) }
                    case .image(let data, let mime):
                        content.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"]])
                    case .toolResult(let id, let text, _, let image):
                        results.append(["role": "tool", "tool_call_id": id, "content": text])
                        if let image { resultImages.append(image) }
                    case .toolCall:
                        break
                    }
                }
                out.append(contentsOf: results)
                if !resultImages.isEmpty {
                    var parts: [[String: Any]] = resultImages.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]] }
                    parts.insert(["type": "text", "text": "(Screenshot returned by the tool above.)"], at: 0)
                    out.append(["role": "user", "content": parts])
                }
                if content.count == 1, let only = content.first, only["type"] as? String == "text", let t = only["text"] {
                    out.append(["role": "user", "content": t])
                } else if !content.isEmpty {
                    out.append(["role": "user", "content": content])
                }
            }
        }
        return out
    }

    static func encodeTool(_ t: AIToolSpec) -> [String: Any] {
        ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": t.inputSchema]]
    }

    // MARK: Response decoding (pure)

    struct EventDecoder {
        private var calls: [Int: (id: String, name: String, args: String)] = [:]
        private var order: [Int] = []
        private var finishReason: String?
        private var done = false

        mutating func decode(_ sse: SSEEvent) throws -> [AIStreamEvent] {
            let data = sse.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if data == "[DONE]" { return finish() }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return [] }
            if let err = obj["error"] as? [String: Any] {
                throw AIProviderError.http(status: 0, message: err["message"] as? String ?? "unknown error")
            }
            var events: [AIStreamEvent] = []
            if let usage = obj["usage"] as? [String: Any] {
                let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
                events.append(.usage(input: usage["prompt_tokens"] as? Int, output: usage["completion_tokens"] as? Int,
                                     cacheRead: cached, cacheWrite: nil))
            }
            if let choice = (obj["choices"] as? [[String: Any]])?.first {
                if let delta = choice["delta"] as? [String: Any] {
                    if let c = delta["content"] as? String, !c.isEmpty { events.append(.textDelta(c)) }
                    for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                        let index = tc["index"] as? Int ?? 0
                        var entry = calls[index] ?? (id: "", name: "", args: "")
                        if calls[index] == nil { order.append(index) }
                        if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let n = fn["name"] as? String, !n.isEmpty, !entry.name.hasSuffix(n) { entry.name += n }
                            if let a = fn["arguments"] as? String { entry.args += a }
                        }
                        calls[index] = entry
                    }
                }
                if let f = choice["finish_reason"] as? String, !f.isEmpty {
                    finishReason = f
                    events.append(contentsOf: flushCalls())
                }
            }
            return events
        }

        /// Stream ended (`[DONE]` or EOF): emit any pending calls once, then done.
        mutating func finish() -> [AIStreamEvent] {
            guard !done else { return [] }
            done = true
            var out = flushCalls()
            out.append(.done(stopReason: Self.mapFinish(finishReason)))
            return out
        }

        private mutating func flushCalls() -> [AIStreamEvent] {
            let out: [AIStreamEvent] = order.compactMap { i in
                guard let c = calls[i], !c.name.isEmpty else { return nil }
                return .toolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, argumentsJSON: c.args.isEmpty ? "{}" : c.args)
            }
            calls = [:]; order = []
            return out
        }

        /// OpenAI finish reasons → the stop vocabulary the loop already knows.
        static func mapFinish(_ f: String?) -> String? {
            switch f {
            case "stop": return "end_turn"
            case "tool_calls", "function_call": return "tool_use"
            case "length": return "max_tokens"
            case "content_filter": return "refusal"
            default: return f
            }
        }
    }
}
