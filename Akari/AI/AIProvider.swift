import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Provider-neutral model layer (PROVIDERS.md §Architecture).
//
// Akari owns these types; each adapter (Anthropic today, OpenAI in phase 4)
// maps them to its wire format. Nothing above this file knows which vendor
// is on the other end.
//
// Everything here is `nonisolated`: the target defaults to MainActor isolation
// (SWIFT_DEFAULT_ACTOR_ISOLATION), but adapters run in detached tasks.

nonisolated enum AIRole: String, Sendable { case system, user, assistant, tool }

nonisolated struct AIMessage: Sendable {
    enum Part: Sendable {
        case text(String)
        /// Already-encoded image bytes (JPEG/PNG) + their MIME type.
        case image(Data, mime: String)
        /// A tool call the assistant made (id is provider-issued, echoed back
        /// on the matching `.toolResult`). `argumentsJSON` is a JSON object string.
        case toolCall(id: String, name: String, argumentsJSON: String)
        /// The app's answer to a tool call — optionally with an image (a screenshot
        /// a tool took), encoded JPEG/PNG bytes.
        case toolResult(id: String, text: String, isError: Bool, image: Data? = nil)
    }
    var role: AIRole
    var parts: [Part]

    static func system(_ text: String) -> AIMessage { AIMessage(role: .system, parts: [.text(text)]) }
    static func user(_ text: String) -> AIMessage { AIMessage(role: .user, parts: [.text(text)]) }
    static func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, parts: [.text(text)]) }

    /// All text parts joined — for logging and for adapters that need a flat string.
    var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }
}

/// A tool the model may call. `inputSchema` is a JSON Schema object.
nonisolated struct AIToolSpec: @unchecked Sendable {
    var name: String
    var description: String
    var inputSchema: [String: Any]
}

nonisolated enum AIEffort: String, Sendable { case low, medium, high }

nonisolated struct AIRequest: Sendable {
    var messages: [AIMessage]
    var tools: [AIToolSpec] = []
    /// Provider model id; nil = the adapter's default.
    var model: String? = nil
    var maxTokens: Int = 16384   // streaming, so a large cap is safe; adaptive thinking eats into it
    /// Reasoning depth hint; adapters that have no such knob ignore it.
    var effort: AIEffort? = nil
    /// For the "what was sent" log only — never sent to the provider.
    var label: String? = nil
}

nonisolated enum AIStreamEvent: Sendable {
    case textDelta(String)
    case toolCall(id: String, name: String, argumentsJSON: String)
    /// Token usage as reported by the provider (input may arrive before output).
    /// `cacheRead`/`cacheWrite` are prompt-cache tokens (billed differently).
    case usage(input: Int?, output: Int?, cacheRead: Int?, cacheWrite: Int?)
    /// The turn ended. `stopReason` is provider vocabulary passed through
    /// ("end_turn", "tool_use", "max_tokens", "refusal", ...).
    case done(stopReason: String?)
}

nonisolated protocol AIProvider: Sendable {
    /// Stable identifier ("anthropic", "openai") — used for settings and cost tables.
    var id: String { get }
    var defaultModel: String { get }
    var supportsVision: Bool { get }
    var supportsTools: Bool { get }
    func stream(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error>
}

nonisolated enum AIProviderError: LocalizedError, Sendable {
    case noAPIKey(provider: String)
    case keyRejected(provider: String)
    case rateLimited(provider: String)
    case offline
    case http(status: Int, message: String)
    case malformedResponse(String)
    case refusal(category: String?)

    /// Adapter ids ("openai") → names people read ("OpenAI").
    static func prettyName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        default: return provider
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let p): return "No \(Self.prettyName(p)) API key. Add one in Settings → AI."
        case .keyRejected(let p): return "\(Self.prettyName(p)) rejected the API key. Check it in Settings → AI."
        case .rateLimited(let p): return "\(Self.prettyName(p)) is rate-limiting this key. Try again in a moment."
        case .offline: return "No internet connection."
        case .http(let s, let m): return "Provider error \(s): \(m)"
        case .malformedResponse(let why): return "Unexpected reply from the provider: \(why)"
        case .refusal(let c): return "The model declined this request" + (c.map { " (\($0))" } ?? "") + "."
        }
    }
}

// MARK: - Shared HTTP plumbing

nonisolated enum AIHTTP {
    /// Open a streaming request. Retries 429 / 5xx / connection loss with backoff
    /// (3 attempts) — only before any bytes have been consumed, so a stream never
    /// restarts mid-answer. Non-2xx: the body is read fully and mapped to an error.
    static func openStream(_ request: URLRequest, provider: String) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AIProviderError.malformedResponse("not an HTTP response")
                }
                if (200..<300).contains(http.statusCode) { return bytes }
                var body = Data()
                for try await b in bytes { body.append(b) }
                let message = Self.errorMessage(from: body) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                switch http.statusCode {
                case 401, 403: throw AIProviderError.keyRejected(provider: provider)
                case 429:
                    if attempt < 3 { try await backoff(attempt); continue }
                    throw AIProviderError.rateLimited(provider: provider)
                case 500...599:
                    if attempt < 3 { try await backoff(attempt); continue }
                    throw AIProviderError.http(status: http.statusCode, message: message)
                default:
                    throw AIProviderError.http(status: http.statusCode, message: message)
                }
            } catch let e as URLError {
                switch e.code {
                case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                    throw AIProviderError.offline
                case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                    if attempt < 3 { try await backoff(attempt); continue }
                    throw AIProviderError.offline
                default: throw e
                }
            }
        }
    }

    private static func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 0.8 * 1_000_000_000))
    }

    /// Best-effort `{"error":{"message":…}}` / `{"message":…}` extraction.
    static func errorMessage(from body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return String(data: body, encoding: .utf8).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = obj["message"] as? String { return m }
        return nil
    }
}

// MARK: - Image encoding

nonisolated enum AIImage {
    /// JPEG-encode a screenshot for transport. Screens are text-heavy, so quality
    /// stays high; the pixel cap (ImagePreparation, 1280 long edge) already
    /// bounds the token cost — bytes only affect upload time.
    static func jpegData(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
