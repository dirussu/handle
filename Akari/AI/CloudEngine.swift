import Foundation
import Combine
import CoreGraphics
import OSLog

nonisolated private let log = Logger(subsystem: "com.dimarussu.Akari", category: "Agent")

/// The model engine. `turn` is the agent primitive — system role, provider
/// messages, native tools — that `streamTurn` drives; `chat` is the text-only
/// one-shot for select/fill/title prompts. Tracks token usage per turn and per
/// session (PROVIDERS.md: show the cost) and keeps the "what was sent" log.
@MainActor
final class CloudEngine: ObservableObject {
    static let shared = CloudEngine()
    private init() {}

    nonisolated struct Usage: Equatable { var input = 0; var output = 0; var cacheRead = 0; var cacheWrite = 0 }   // built inside the detached task
    @Published private(set) var sessionUsage = Usage()
    @Published private(set) var lastTurnUsage: Usage?
    @Published private(set) var lastModel: String?
    /// Everything that left the Mac this session, newest first, memory only (cap 30).
    @Published private(set) var sent: [SentRecord] = []

    /// Text-only turn(s) → text deltas. `effort` low for one-shot select/fill prompts.
    func chat(messages: [AIMessage], effort: AIEffort? = nil, label: String? = nil) -> AsyncThrowingStream<String, Error> {
        textOnly(events(AIRequest(messages: messages, model: AIConfig.model, effort: effort, label: label)))
    }

    /// Full agent turn: a real system prompt, the projected transcript (+ this
    /// turn's tool_use/tool_result history), native tools. Raw events out.
    func turn(system: String, messages: [AIMessage], tools: [AIToolSpec], effort: AIEffort? = nil, label: String? = nil) -> AsyncThrowingStream<AIStreamEvent, Error> {
        var all = messages
        if !system.isEmpty { all.insert(.system(system), at: 0) }
        return events(AIRequest(messages: all, tools: tools, model: AIConfig.model, effort: effort, label: label))
    }

    // MARK: Core

    private func events(_ request: AIRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let provider: AIProvider
        do { provider = try AIConfig.makeProvider() } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let model = request.model ?? provider.defaultModel
        lastModel = model
        let record = SentRecord.skeleton(for: request, provider: provider.id, model: model)
        return AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                let t0 = Date()
                var usage = Usage()
                var sawContent = false
                var stop: String?
                do {
                    for try await event in provider.stream(request) {
                        if Task.isCancelled { break }
                        switch event {
                        case .textDelta, .toolCall:
                            sawContent = true
                            continuation.yield(event)
                        case .usage(let i, let o, let cr, let cw):
                            if let i { usage.input = i }
                            if let o { usage.output = o }
                            if let cr { usage.cacheRead = cr }
                            if let cw { usage.cacheWrite = cw }
                        case .done(let reason):
                            stop = reason
                            continuation.yield(event)
                        }
                    }
                    if stop == "refusal" && !sawContent { throw AIProviderError.refusal(category: nil) }
                    log.info("cloud turn: \(provider.id, privacy: .public)/\(model, privacy: .public) in=\(usage.input) out=\(usage.output) cache(r=\(usage.cacheRead) w=\(usage.cacheWrite)) tools=\(request.tools.count) stop=\(stop ?? "-", privacy: .public) \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s")
                    await self?.record(usage, sent: record)
                    continuation.finish()
                } catch {
                    await self?.record(usage, sent: record)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Text deltas only — for `chat`.
    private nonisolated func textOnly(_ events: AsyncThrowingStream<AIStreamEvent, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for try await ev in events {
                        if case .textDelta(let t) = ev { continuation.yield(t) }
                        else if case .toolCall(_, let name, _) = ev {
                            log.info("cloud: tool call \(name, privacy: .public) on a text-only turn — ignored")
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ u: Usage, sent: SentRecord) {
        lastTurnUsage = u
        sessionUsage.input += u.input
        sessionUsage.output += u.output
        sessionUsage.cacheRead += u.cacheRead
        sessionUsage.cacheWrite += u.cacheWrite
        var entry = sent
        entry.usage = u
        self.sent.insert(entry, at: 0)
        if self.sent.count > 30 { self.sent.removeLast(self.sent.count - 30) }
    }
}
