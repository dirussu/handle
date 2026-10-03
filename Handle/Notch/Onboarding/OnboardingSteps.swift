import SwiftUI
import AppKit

struct WelcomeStep: View {
    let voiceOK: Bool
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false

    var body: some View {
        VStack(spacing: HandleSpacing.xl) {
            OnboardingHero(
                icon: "lightbulb.fill",
                title: "Welcome to Handle",
                subtitle: "The Mac AI in your notch. It sees your screen, answers, and acts — with the AI model you choose, under your own key. Handle itself keeps everything on this Mac.",
                appeared: appeared, reduce: reduce)

            if !voiceOK {
                Text("Voice needs an Apple Silicon Mac — everything else works here.")
                    .font(.handleCaption).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .appearIn(3, appeared, reduce)
            }
            Button("Continue") { onContinue() }
                .buttonStyle(.handleSolidProminent)
                .appearIn(voiceOK ? 3 : 4, appeared, reduce)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

/// Pick a provider, paste a key, see it answer. Nothing is preselected (a deliberate
/// decision: no default provider). Skipping is fine — Handle asks again in chat.
struct ConnectStep: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false
    @State private var picked: AIProviderKind? = AIConfig.provider
    @State private var connected = false

    var body: some View {
        VStack(spacing: HandleSpacing.l) {
            OnboardingHero(
                icon: "key.fill",
                title: "Connect your AI",
                subtitle: "Handle is local software — it works with the model you choose, using your own key. Nothing is stored anywhere but this Mac.",
                appeared: appeared, reduce: reduce)

            HStack(spacing: HandleSpacing.m) {
                ForEach([AIProviderKind.anthropic, .openai]) { k in
                    AIProviderCard(kind: k, selected: picked == k) {
                        picked = k
                        AIConfig.setProvider(k)
                        connected = false
                    }
                }
            }
            .appearIn(3, appeared, reduce)

            if let picked, picked.isAvailable {
                AIKeyField(kind: picked) { connected = true }
                    .appearIn(4, appeared, reduce)
            } else {
                Text("Running a model locally (LM Studio, Ollama)? Pick OpenAI, then set the server address in Settings → AI.")
                    .font(.handleCaption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .appearIn(4, appeared, reduce)
            }

            if connected {
                Button("Continue") { onContinue() }
                    .buttonStyle(.handleSolidProminent)
                    .appearIn(5, appeared, reduce)
            } else {
                Button("Skip for now") { onContinue() }
                    .buttonStyle(.handleSolid)
                    .appearIn(5, appeared, reduce)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true; connected = AIConfig.state.isReady }   // a saved, working setup needs no re-test
    }
}

struct ReadyStep: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false

    private let tips: [(String, String)] = [
        ("eye", "\u{201C}What does this error mean?\u{201D}"),
        ("cursorarrow.rays", "\u{201C}Click the send button\u{201D}"),
        ("clock.arrow.circlepath", "\u{201C}Every day at 6pm, set my volume to 20\u{201D}"),
        ("mic", "Or hold \u{2325} and just talk"),
    ]

    var body: some View {
        VStack(spacing: HandleSpacing.xl) {
            OnboardingHero(
                icon: "bolt.fill",
                title: "You're set",
                subtitle: "Hover the notch to open Handle, then ask:",
                appeared: appeared, reduce: reduce)

            VStack(alignment: .leading, spacing: HandleSpacing.s) {
                ForEach(Array(tips.enumerated()), id: \.offset) { i, tip in
                    Label(tip.1, systemImage: tip.0)
                        .font(.handleCaption).foregroundStyle(.white.opacity(0.7))
                        .appearIn(3 + i, appeared, reduce)
                }
            }

            Button("Start using Handle") { onDone() }
                .buttonStyle(.handleSolidProminent)
                .appearIn(3 + tips.count, appeared, reduce)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}
