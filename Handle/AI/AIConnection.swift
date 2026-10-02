import Foundation

/// A tiny live request to prove a key works — used by the "Test" button in
/// Settings and by onboarding. Builds the adapter directly so a key can be
/// tested before (or without) being the configured one.
nonisolated enum AIConnectionTest {
    struct Success: Sendable { let model: String; let seconds: Double }

    static func run(kind: AIProviderKind, key: String, model: String?) async -> Result<Success, Error> {
        let provider: AIProvider
        switch kind {
        case .anthropic: provider = AnthropicProvider(apiKey: key, defaultModel: model ?? "claude-sonnet-5")
        case .openai: provider = OpenAIProvider(apiKey: key, baseURL: AIConfig.openAIBaseURL, defaultModel: model ?? "gpt-5",
                                                supportsVision: AIConfig.openAISupportsVision, supportsTools: AIConfig.openAISupportsTools)
        }
        let t0 = Date()
        let request = AIRequest(messages: [.user("Reply with the single word OK.")], model: model, maxTokens: 16, effort: .low)
        do {
            for try await _ in provider.stream(request) { }
            return .success(Success(model: model ?? provider.defaultModel, seconds: Date().timeIntervalSince(t0)))
        } catch {
            return .failure(error)
        }
    }
}
