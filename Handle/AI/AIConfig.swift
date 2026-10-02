import Foundation

/// The providers a user can pick. There is NO default (founder, 2026-09-19):
/// nothing is preselected in onboarding and the app never switches on its own.
nonisolated enum AIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        }
    }
    var shortName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }
    var isAvailable: Bool { true }
    /// Keychain account name for this provider's key.
    var keyAccount: String? {
        switch self {
        case .anthropic: return "anthropic"
        case .openai: return "openai"
        }
    }
    var keyURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        }
    }
    var knownModels: [String] {
        switch self {
        case .anthropic: return AnthropicProvider.knownModels
        case .openai: return OpenAIProvider.knownModels
        }
    }
    var defaultModel: String? { knownModels.first }
}

/// Where the user stands with their AI — pure so it's self-tested. Drives the
/// no-key bubble in the loop and the Settings/onboarding status lines.
nonisolated enum AIState: Equatable, Sendable {
    case notChosen
    case missingKey(AIProviderKind)
    case unavailable(AIProviderKind)
    case ready(AIProviderKind)

    /// `keyOptional`: a custom OpenAI-compatible endpoint (LM Studio, Ollama) needs no key.
    static func resolve(providerID: String?, hasKey: Bool, keyOptional: Bool = false) -> AIState {
        guard let id = providerID, let kind = AIProviderKind(rawValue: id) else { return .notChosen }
        if !kind.isAvailable { return .unavailable(kind) }
        if kind.keyAccount != nil && !hasKey && !keyOptional { return .missingKey(kind) }
        return .ready(kind)
    }

    var isReady: Bool { if case .ready = self { return true } else { return false } }

    /// What Handle says in the chat when it can't run a turn.
    var userMessage: String? {
        switch self {
        case .ready: return nil
        case .notChosen:
            return "Connect an AI first — open Settings → AI and add your Anthropic key. Handle itself keeps everything on this Mac; the model runs with your own key."
        case .missingKey(let k):
            return "Add your \(k.shortName) API key in Settings → AI to start."
        case .unavailable(let k):
            return "\(k.displayName) isn't available yet — choose Claude (Anthropic) in Settings → AI."
        }
    }
}

/// Which provider/model the user chose (UserDefaults) + the key (Keychain).
nonisolated enum AIConfig {
    static let providerKey = "handle.ai.provider"
    static let modelKey = "handle.ai.model"

    static var providerID: String? {
        let v = UserDefaults.standard.string(forKey: providerKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? nil : v
    }
    static var provider: AIProviderKind? { providerID.flatMap(AIProviderKind.init(rawValue:)) }
    static func setProvider(_ kind: AIProviderKind?) {
        if let kind { UserDefaults.standard.set(kind.rawValue, forKey: providerKey) }
        else { UserDefaults.standard.removeObject(forKey: providerKey) }
    }

    static var model: String? {
        let v = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return v.isEmpty ? nil : v
    }
    static func setModel(_ id: String?) {
        let v = id?.trimmingCharacters(in: .whitespaces) ?? ""
        if v.isEmpty { UserDefaults.standard.removeObject(forKey: modelKey) }
        else { UserDefaults.standard.set(v, forKey: modelKey) }
    }

    static func hasKey(for kind: AIProviderKind) -> Bool {
        guard let account = kind.keyAccount else { return true }
        return !(SecretStore.providers.get(account) ?? "").isEmpty
    }

    // OpenAI-compatible endpoint (phase 4): base URL + what the model there can do.
    static let openAIBaseURLKey = "handle.ai.openai.baseURL"
    static let openAINoToolsKey = "handle.ai.openai.noTools"      // stored inverted: default = supports
    static let openAINoVisionKey = "handle.ai.openai.noVision"

    static var openAIBaseURLString: String { UserDefaults.standard.string(forKey: openAIBaseURLKey) ?? "" }
    static var openAIBaseURL: URL? { OpenAIProvider.normalizeBaseURL(openAIBaseURLString) }
    static func setOpenAIBaseURL(_ raw: String?) {
        let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if v.isEmpty { UserDefaults.standard.removeObject(forKey: openAIBaseURLKey) }
        else { UserDefaults.standard.set(v, forKey: openAIBaseURLKey) }
    }
    static var openAISupportsTools: Bool {
        get { !UserDefaults.standard.bool(forKey: openAINoToolsKey) }
        set { UserDefaults.standard.set(!newValue, forKey: openAINoToolsKey) }
    }
    static var openAISupportsVision: Bool {
        get { !UserDefaults.standard.bool(forKey: openAINoVisionKey) }
        set { UserDefaults.standard.set(!newValue, forKey: openAINoVisionKey) }
    }
    /// A custom endpoint is configured (key optional).
    static var usesCustomEndpoint: Bool { provider == .openai && openAIBaseURL != nil }
    /// …and it's on this Mac — nothing leaves (identity + cost say so).
    static var isLocalEndpoint: Bool { provider == .openai && openAIBaseURL.map(OpenAIProvider.isLocalHost) == true }

    /// Native tool calls on the current provider? Otherwise the loop folds the
    /// tool prose into the prompt and scrapes JSON — the local-model path.
    static var nativeTools: Bool {
        switch provider {
        case .anthropic: return true
        case .openai: return openAISupportsTools
        case .none: return false
        }
    }
    static var visionAvailable: Bool {
        switch provider {
        case .openai: return openAISupportsVision
        default: return true
        }
    }

    static var state: AIState {
        AIState.resolve(providerID: providerID, hasKey: provider.map(hasKey) ?? false, keyOptional: usesCustomEndpoint)
    }

    /// For the identity block and the UI: what the user is talking to.
    static var providerDisplayName: String {
        if provider == .openai, let url = openAIBaseURL {
            let host = url.host ?? "custom server"
            return OpenAIProvider.isLocalHost(url) ? "a local model server (\(host))" : "an OpenAI-compatible model at \(host)"
        }
        return provider?.displayName ?? "the cloud model you chose"
    }

    /// The user's provider with its key from the Keychain. Throws a
    /// user-readable error when nothing is chosen or the key is missing.
    static func makeProvider() throws -> AIProvider {
        switch state {
        case .notChosen: throw AIConfigError.noProviderSelected
        case .unavailable(let k): throw AIConfigError.unavailable(k)
        case .missingKey(let k): throw AIProviderError.noAPIKey(provider: k.shortName)
        case .ready(let k):
            switch k {
            case .anthropic:
                let key = SecretStore.providers.get("anthropic") ?? ""
                return AnthropicProvider(apiKey: key, defaultModel: model ?? "claude-sonnet-5")
            case .openai:
                return OpenAIProvider(apiKey: SecretStore.providers.get("openai") ?? "", baseURL: openAIBaseURL,
                                      defaultModel: model ?? "gpt-5",
                                      supportsVision: openAISupportsVision, supportsTools: openAISupportsTools)
            }
        }
    }
}

nonisolated enum AIConfigError: LocalizedError {
    case noProviderSelected
    case unavailable(AIProviderKind)
    var errorDescription: String? {
        switch self {
        case .noProviderSelected: return "Choose an AI provider in Settings → AI."
        case .unavailable(let k): return "\(k.displayName) isn't available yet."
        }
    }
}
