import SwiftUI
import AppKit

/// Key entry · Save · Test · status for one cloud provider. Shared by Settings
/// (inside the AI section) and onboarding (inside the connect step). The key
/// goes straight to the Keychain from here — the app owns the item, so no
/// "Handle wants to access…" dialog ever appears for keys saved this way.
struct AIKeyField: View {
    let kind: AIProviderKind
    /// Custom OpenAI-compatible servers (LM Studio, Ollama) take no key.
    var keyOptional: Bool = false
    var onConnected: (() -> Void)? = nil

    @State private var keyInput = ""
    @State private var savedHint: String? = nil
    @State private var testing = false
    @State private var status: Status = .idle

    enum Status: Equatable { case idle, ok(String, Double), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: HandleSpacing.s) {
            if let savedHint, keyInput.isEmpty {
                HStack(spacing: HandleSpacing.s) {
                    Label("Key saved · \(savedHint)", systemImage: "key.fill")
                        .font(.handleBody).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button("Test") { test() }
                        .buttonStyle(.handleSolid)
                        .disabled(testing)
                    Button("Replace") { self.savedHint = nil }
                        .buttonStyle(.handleSolid)
                    Button("Remove") { remove() }
                        .buttonStyle(.handleSolid)
                }
            } else {
                HStack(spacing: HandleSpacing.s) {
                    SecureField(keyOptional ? "API key (optional for local servers)" : "Paste your \(kind.shortName) API key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { keyInput.isEmpty ? test() : saveAndTest() }
                    Button("Save & test") { saveAndTest() }
                        .buttonStyle(.handleSolidProminent)
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                    if keyOptional && keyInput.isEmpty {
                        Button("Test without a key") { test() }
                            .buttonStyle(.handleSolid)
                            .disabled(testing)
                    }
                }
            }
            statusLine
        }
        .onAppear { refresh() }
        .onChange(of: kind) { _, _ in keyInput = ""; status = .idle; refresh() }
    }

    @ViewBuilder private var statusLine: some View {
        if testing {
            HStack(spacing: HandleSpacing.s) {
                ProgressView().controlSize(.small)
                Text("Checking the key with \(kind.shortName)…").font(.handleCaption).foregroundStyle(.secondary)
            }
        } else {
            switch status {
            case .idle:
                EmptyView()
            case .ok(let model, let secs):
                Label("Connected — \(model) answered in \(String(format: "%.1f", secs)) s", systemImage: "checkmark.circle.fill")
                    .font(.handleCaption).foregroundStyle(.green)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.handleCaption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        guard let account = kind.keyAccount, let saved = SecretStore.providers.get(account), !saved.isEmpty else {
            savedHint = nil; return
        }
        savedHint = SecretStore.hint(for: saved)
    }

    private func saveAndTest() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let account = kind.keyAccount else { return }
        SecretStore.providers.set(key, for: account)
        keyInput = ""
        refresh()
        test()
    }

    private func remove() {
        guard let account = kind.keyAccount else { return }
        SecretStore.providers.delete(account)
        status = .idle
        refresh()
    }

    private func test() {
        guard let account = kind.keyAccount else { return }
        let key = SecretStore.providers.get(account) ?? ""
        let model = AIConfig.model ?? kind.defaultModel
        let kind = self.kind
        testing = true
        Task {
            let result = await AIConnectionTest.run(kind: kind, key: key, model: model)
            await MainActor.run {
                testing = false
                switch result {
                case .success(let ok):
                    status = .ok(ok.model, ok.seconds)
                    onConnected?()
                case .failure(let error):
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }
}

/// One provider choice in onboarding — equal cards, none preselected.
struct AIProviderCard: View {
    let kind: AIProviderKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: kind == .anthropic ? "sparkle" : "circle.hexagongrid")
                    .font(.system(size: 18, weight: .semibold))
                Text(kind.displayName).font(.handleBody).foregroundStyle(.white)
                Text(kind.isAvailable ? "Your own API key" : "Next update")
                    .font(.handleCaption).foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HandleSpacing.m)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(selected ? 0.16 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(selected ? 0.55 : 0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .disabled(!kind.isAvailable)
        .opacity(kind.isAvailable ? 1 : 0.55)
    }
}
