import SwiftUI
import AppKit

/// Which AI answers — provider (no default; the user picks), key (Keychain),
/// model, a live Test, and the session's token cost. The honest privacy line
/// lives in the footer (PROVIDERS.md: local software, your model).
struct AISection: View {
    @State private var kind: AIProviderKind? = AIConfig.provider
    @State private var model: String = AIConfig.model ?? AIConfig.provider?.defaultModel ?? ""
    @ObservedObject private var engine = CloudEngine.shared
    // OpenAI-compatible endpoint
    @State private var baseURL: String = AIConfig.openAIBaseURLString
    @State private var serverTools: Bool = AIConfig.openAISupportsTools
    @State private var serverVision: Bool = AIConfig.openAISupportsVision
    @State private var fetched: [String] = []
    @State private var fetchStatus: String? = nil
    @State private var webSearch: Bool = WebSettings.searchEnabled
    @State private var maxSteps: Int = AgentSettings.maxSteps
    @State private var turnBudget: Double = AgentSettings.turnBudgetUSD

    var body: some View {
        Section {
            Picker("Provider", selection: $kind) {
                Text("Not connected").tag(AIProviderKind?.none)
                ForEach(AIProviderKind.allCases) { k in
                    Text(k.isAvailable ? k.displayName : "\(k.displayName) — next update").tag(AIProviderKind?.some(k))
                }
            }
            .onChange(of: kind) { _, k in
                AIConfig.setProvider(k)
                model = AIConfig.model ?? k?.defaultModel ?? ""
            }
            if let kind {
                if !kind.isAvailable {
                    Text("\(kind.displayName) support arrives in the next update — pick Claude (Anthropic) for now.")
                        .font(.handleCaption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    AIKeyField(kind: kind, keyOptional: kind == .openai && AIConfig.openAIBaseURL != nil)
                    if kind == .openai {
                        // Model is a free id here (the real list comes from the server).
                        HStack(spacing: 8) {
                            TextField("Model id", text: $model)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { AIConfig.setModel(model) }
                            Button("Fetch models…") { fetchModels() }
                                .buttonStyle(.handleSolid)
                        }
                        .onChange(of: model) { _, m in AIConfig.setModel(m) }
                        if !fetched.isEmpty {
                            Picker("Available", selection: $model) {
                                if !fetched.contains(model) { Text(model.isEmpty ? "—" : model).tag(model) }
                                ForEach(fetched, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if let fetchStatus {
                            Text(fetchStatus).font(.handleCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup("Custom server (LM Studio, Ollama, OpenRouter…)") {
                            HStack(spacing: 8) {
                                TextField("Base URL — blank = api.openai.com", text: $baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { saveBaseURL() }
                                Button("Save") { saveBaseURL() }.buttonStyle(.handleSolid)
                            }
                            Text("LM Studio: http://localhost:1234/v1 · Ollama: http://localhost:11434/v1 · OpenRouter: https://openrouter.ai/api/v1. A local server means nothing leaves this Mac — and no key is needed.")
                                .font(.handleCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if AIConfig.openAIBaseURL != nil {
                                Toggle("The model supports tool calls", isOn: $serverTools)
                                    .onChange(of: serverTools) { _, v in AIConfig.openAISupportsTools = v }
                                Toggle("The model can see images", isOn: $serverVision)
                                    .onChange(of: serverVision) { _, v in AIConfig.openAISupportsVision = v }
                                Text("Turn these off for a text-only or tool-less model: Handle then folds tool instructions into the prompt, and answers without screenshots.")
                                    .font(.handleCaption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else if !kind.knownModels.isEmpty {
                        Picker("Model", selection: $model) {
                            ForEach(kind.knownModels, id: \.self) { Text($0).tag($0) }
                            if !model.isEmpty, !kind.knownModels.contains(model) { Text("Custom: \(model)").tag(model) }
                        }
                        .onChange(of: model) { _, m in AIConfig.setModel(m) }
                    }
                    if let url = kind.keyURL, !(kind == .openai && AIConfig.openAIBaseURL != nil) {
                        HStack {
                            Button("Get a \(kind.shortName) API key…") { NSWorkspace.shared.open(url) }
                                .buttonStyle(.handleSolid)
                            Spacer()
                        }
                    }
                }
            }
            if engine.sessionUsage != .init() {
                LabeledContent("This session") {
                    Text(usageText).foregroundStyle(.secondary)
                }
            }
            if kind == .anthropic {
                Toggle("Let the model search the web", isOn: $webSearch)
                    .onChange(of: webSearch) { _, v in WebSettings.searchEnabled = v }
            }
            // Agent limits (ASSISTANT.md): visible budgets, never silent stops.
            Stepper("Max steps per turn: \(maxSteps)", value: $maxSteps, in: 5...100, step: 5)
                .onChange(of: maxSteps) { _, v in AgentSettings.setMaxSteps(v) }
            LabeledContent("Budget per turn") {
                HStack(spacing: 6) {
                    TextField("", value: $turnBudget, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing).labelsHidden()
                        .onSubmit { AgentSettings.setTurnBudget(turnBudget) }
                        .onChange(of: turnBudget) { _, v in AgentSettings.setTurnBudget(v) }
                    Text("USD · 0 = no limit").foregroundStyle(.secondary)
                }
            }
        } header: {
            SettingsHeader(icon: "sparkles", title: "AI")
        } footer: {
            Text("Handle is local software. Only the current conversation — and a screenshot when you ask about the screen — goes to the provider you chose, with your own key. Memory, chat history, voice, and screen reading stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var usageText: String {
        let u = engine.sessionUsage
        var parts = ["\(AICost.formatTokens(u.input + u.cacheRead + u.cacheWrite)) in", "\(AICost.formatTokens(u.output)) out"]
        if u.cacheRead > 0 { parts.append("\(AICost.formatTokens(u.cacheRead)) cached") }
        var text = parts.joined(separator: " · ")
        if AIConfig.isLocalEndpoint {
            text += " · $0 · local"
        } else if let d = AICost.estimate(model: engine.lastModel, input: u.input, output: u.output, cacheRead: u.cacheRead, cacheWrite: u.cacheWrite) {
            text += " ≈ \(AICost.format(d))"
        }
        return text
    }

    private func saveBaseURL() {
        AIConfig.setOpenAIBaseURL(baseURL)
        baseURL = AIConfig.openAIBaseURLString
        fetched = []; fetchStatus = nil
    }

    private func fetchModels() {
        let base = AIConfig.openAIBaseURL ?? OpenAIProvider.defaultBaseURL
        let key = SecretStore.providers.get("openai") ?? ""
        fetchStatus = "Fetching from \(base.host ?? base.absoluteString)…"
        Task {
            do {
                var ids = try await OpenAIProvider.fetchModels(baseURL: base, apiKey: key)
                if base == OpenAIProvider.defaultBaseURL {   // OpenAI lists hundreds; keep the chat-capable families
                    ids = ids.filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o") || $0.hasPrefix("chatgpt") }
                }
                await MainActor.run { fetched = ids; fetchStatus = "\(ids.count) models" }
            } catch {
                await MainActor.run { fetched = []; fetchStatus = error.localizedDescription }
            }
        }
    }
}
