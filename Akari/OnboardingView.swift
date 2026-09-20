import SwiftUI
import AppKit

/// First-run state. The old hardware GATE (refuse below M1/16 GB) is gone with
/// the on-device model (PROVIDERS.md phase 2); what remains is a soft note —
/// on-device voice (WhisperKit) wants Apple Silicon. Pure logic split out so
/// self-tests can hit it.
enum Onboarding {
    static let doneKey = "akari.onboarding.done"

    @MainActor static var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// Voice transcription runs on-device (WhisperKit) and needs Apple Silicon.
    /// Everything else works on any Mac that runs the app — no memory floor.
    static func voiceSupported(isAppleSilicon: Bool) -> Bool { isAppleSilicon }

    static var currentMemGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))
    }

    static var currentIsAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine.hasPrefix("arm64")
    }
}

/// The first-run walk-through, as a page inside the notch panel (the notch is
/// the app's only surface). Four steps: welcome → staged permissions (each with
/// its rationale, skippable) → connect your AI (provider + key, nothing
/// preselected) → ready.
///
/// Design: a first impression, not a form. A breathing glow hero, an oversized
/// centered title (real size-contrast), and a staggered blur-in entrance so each
/// screen *arrives*. Steps cross-fade; a progress rail shows the journey. All in
/// the white-on-black language — contrast comes from size/opacity, never colour.
struct OnboardingBody: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var step = 0
    private let voiceOK = Onboarding.voiceSupported(isAppleSilicon: Onboarding.currentIsAppleSilicon)

    /// The panel height is intrinsic (the notch shape self-sizes to content),
    /// so a per-step height change makes the whole notch collapse + re-expand —
    /// reads as "closes then opens." Pinning ONE stable height across all steps
    /// keeps the notch still; the steps cross-dissolve inside it. Sized to the
    /// tallest step (the connect step); shorter steps centre in the space.
    private let stageHeight: CGFloat = 330

    var body: some View {
        VStack(spacing: AkariSpacing.l) {
            ZStack {
                Group {
                    switch step {
                    case 0:  WelcomeStep(voiceOK: voiceOK) { advance(to: 1) }
                    case 1:  PermissionsFlow(onDone: { advance(to: 2) })
                    case 2:  ConnectStep(onContinue: { advance(to: 3) })
                    default: ReadyStep(onDone: { Onboarding.isDone = true; onDone() })
                    }
                }
                .transition(reduce ? .opacity : .calmDissolve)
                .id(step)
            }
            .frame(maxWidth: .infinity, minHeight: stageHeight)

            StepDots(count: 4, index: step)
        }
        .padding(.top, AkariSpacing.s)
        .padding(.bottom, AkariSpacing.m)
        .frame(maxWidth: .infinity)
    }

    private func advance(to next: Int) {
        withAnimation(reduce ? .easeOut(duration: 0.2) : AkariMotion.settle) { step = next }
    }
}

// MARK: - Shared onboarding chrome

/// Staggered blur-in: each element fades + rises + un-blurs, delayed by its
/// index, so the screen assembles itself top-down. (Emil: blur masks the entry;
/// never scale-from-zero; ease-out/spring, short delays.)
private struct AppearIn: ViewModifier {
    let index: Int
    let appeared: Bool
    let reduce: Bool
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: (appeared || reduce) ? 0 : 12)
            .blur(radius: (appeared || reduce) ? 0 : 4)
            .animation(AkariMotion.enter.delay(Double(index) * 0.07), value: appeared)
    }
}
private extension View {
    func appearIn(_ index: Int, _ appeared: Bool, _ reduce: Bool) -> some View {
        modifier(AppearIn(index: index, appeared: appeared, reduce: reduce))
    }
}

/// A calm blur-dissolve for swapping sequential cards: no slide, no zoom — just
/// a soft cross-blur (Emil: blur masks the swap). Matches the app's gentle
/// crossfade grammar rather than a hard directional push.
private struct Dissolve: ViewModifier {
    let out: Bool
    func body(content: Content) -> some View {
        content.opacity(out ? 0 : 1).blur(radius: out ? 8 : 0)
    }
}
private extension AnyTransition {
    static var calmDissolve: AnyTransition {
        .modifier(active: Dissolve(out: true), identity: Dissolve(out: false))
    }
}

/// The hero: a softly-glowing, gently-breathing ring around the step's symbol,
/// then the oversized title + subtitle. White-only; the glow IS the accent.
private struct OnboardingHero: View {
    let icon: String
    let title: String
    let subtitle: String
    let appeared: Bool
    let reduce: Bool
    var titleFont: Font = .akariDisplay
    var tint: Color = .white
    var badge: String? = nil          // small overlay mark (e.g. a green ✓ when granted)
    @State private var breathe = false

    var body: some View {
        VStack(spacing: AkariSpacing.l) {
            ZStack {
                Circle().fill(tint.opacity(0.08)).frame(width: 76, height: 76).blur(radius: 13)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(tint)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.green)
                                .background(Circle().fill(.black))   // punch-out so it reads over the glyph
                                .offset(x: 9, y: 5)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
            }
            .frame(width: 76, height: 76)
            .scaleEffect((breathe && !reduce) ? 1.05 : 1.0)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { breathe = true }
            }
            .appearIn(0, appeared, reduce)

            VStack(spacing: AkariSpacing.xs) {   // title + subtitle read as one tight block
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .appearIn(1, appeared, reduce)

                Text(subtitle)
                    .font(.akariBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AkariSpacing.s)
                    .appearIn(2, appeared, reduce)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The progress rail — the active step's dot elongates and brightens. Signals a
/// designed journey, springs between steps.
private struct StepDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i == index ? 0.9 : 0.20))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .animation(AkariMotion.pop, value: index)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let voiceOK: Bool
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false

    var body: some View {
        VStack(spacing: AkariSpacing.xl) {
            OnboardingHero(
                icon: "lightbulb.fill",
                title: "Welcome to Akari",
                subtitle: "The Mac AI in your notch. It sees your screen, answers, and acts — with the AI model you choose, under your own key. Akari itself keeps everything on this Mac.",
                appeared: appeared, reduce: reduce)

            if !voiceOK {
                Text("Voice needs an Apple Silicon Mac — everything else works here.")
                    .font(.akariCaption).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .appearIn(3, appeared, reduce)
            }
            Button("Continue") { onContinue() }
                .buttonStyle(.akariSolidProminent)
                .appearIn(voiceOK ? 3 : 4, appeared, reduce)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

/// Pick a provider, paste a key, see it answer. Nothing is preselected (founder
/// decision: no default provider). Skipping is fine — Akari asks again in chat.
struct ConnectStep: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false
    @State private var picked: AIProviderKind? = AIConfig.provider
    @State private var connected = false

    var body: some View {
        VStack(spacing: AkariSpacing.l) {
            OnboardingHero(
                icon: "key.fill",
                title: "Connect your AI",
                subtitle: "Akari is local software — it works with the model you choose, using your own key. Nothing is stored anywhere but this Mac.",
                appeared: appeared, reduce: reduce)

            HStack(spacing: AkariSpacing.m) {
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
                    .font(.akariCaption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .appearIn(4, appeared, reduce)
            }

            if connected {
                Button("Continue") { onContinue() }
                    .buttonStyle(.akariSolidProminent)
                    .appearIn(5, appeared, reduce)
            } else {
                Button("Skip for now") { onContinue() }
                    .buttonStyle(.akariSolid)
                    .appearIn(5, appeared, reduce)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true; connected = AIConfig.state.isReady }   // a saved, working setup needs no re-test
    }
}

private struct ReadyStep: View {
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
        VStack(spacing: AkariSpacing.xl) {
            OnboardingHero(
                icon: "bolt.fill",
                title: "You're set",
                subtitle: "Hover the notch to open Akari, then ask:",
                appeared: appeared, reduce: reduce)

            VStack(alignment: .leading, spacing: AkariSpacing.s) {
                ForEach(Array(tips.enumerated()), id: \.offset) { i, tip in
                    Label(tip.1, systemImage: tip.0)
                        .font(.akariCaption).foregroundStyle(.white.opacity(0.7))
                        .appearIn(3 + i, appeared, reduce)
                }
            }

            Button("Start using Akari") { onDone() }
                .buttonStyle(.akariSolidProminent)
                .appearIn(3 + tips.count, appeared, reduce)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

// MARK: - Permissions, one screen at a time
//
// A wall of six toggles reads as a chore — a form to endure. Instead we walk the
// user through the permissions ONE AT A TIME: each gets the full hero treatment,
// its own reason, and a single clear choice. Granting one glides to the next;
// an already-granted one flashes a green ✓ and moves on by itself. It feels
// guided, and every grant is a small, deliberate win rather than a checkbox.
private struct PermissionsFlow: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var index = 0
    private let perms: [Perm]

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.perms = Self.makePerms()   // sync: the first card is present on frame 1 (no blank beat)
    }

    struct Perm: Identifiable {
        let id: String
        let icon: String
        let name: String
        let why: String
        let refresh: () async -> PermissionsService.Status
        let request: () -> Void
        let settingsURL: URL
    }

    var body: some View {
        ZStack {
            let perm = perms[min(index, perms.count - 1)]
            PermissionCard(perm: perm, number: index + 1, total: perms.count, onNext: advance)
                .id(perm.id)
                .transition(reduce ? .opacity : .calmDissolve)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
    }

    /// Grant → next; skip → next; past the end → hand back to the parent flow.
    private func advance() {
        if index + 1 >= perms.count { onDone() }
        else { withAnimation(reduce ? .easeOut(duration: 0.2) : AkariMotion.settle) { index += 1 } }
    }

    private static func makePerms() -> [Perm] {
        [
            Perm(id: "sr", icon: "rectangle.dashed.badge.record", name: "Screen Recording",
                 why: "So Akari can see the screen you're asking about. A screenshot is taken only when you ask about the screen, sent only to the AI you connected, and never stored.",
                 refresh: { PermissionsService.screenRecording() },
                 request: { PermissionsService.requestScreenRecording() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_ScreenCapture")),
            Perm(id: "ax", icon: "hand.point.up.left", name: "Accessibility",
                 why: "So Akari can point at and click things for you, the way you'd ask a person to.",
                 refresh: { PermissionsService.accessibility() },
                 request: { PermissionsService.requestAccessibility() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Accessibility")),
            Perm(id: "mic", icon: "mic", name: "Microphone",
                 why: "So you can talk to Akari. Your voice is transcribed on this Mac — the audio never leaves.",
                 refresh: { PermissionsService.microphone() },
                 request: { PermissionsService.requestMicrophone() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Microphone")),
            Perm(id: "cal", icon: "calendar", name: "Calendars",
                 why: "So Akari can check your schedule and add events when you ask.",
                 refresh: { PermissionsService.calendars() },
                 request: { PermissionsService.requestCalendars() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Calendars")),
            Perm(id: "rem", icon: "checklist", name: "Reminders",
                 why: "So Akari can read and add your to-dos.",
                 refresh: { PermissionsService.reminders() },
                 request: { PermissionsService.requestReminders() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Reminders")),
            // (No Notifications card: Akari's own notch notification center is the
            // only completion surface — system notifications were removed.)
        ]
    }
}

/// A single permission, front and centre. Reads its live status on appear:
/// already granted → a green ✓ and an automatic glide onward; not yet → one
/// bold **Allow** and a quiet **Not now**. Allow fires the real OS prompt, then
/// we poll for the flip (the dialog is async + out-of-process); if it doesn't
/// land — the user said no, or macOS won't re-ask — we reveal **Open Settings**.
private struct PermissionCard: View {
    let perm: PermissionsFlow.Perm
    let number: Int
    let total: Int
    let onNext: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false
    @State private var status: PermissionsService.Status = .notDetermined
    @State private var resolved = false          // first live read done (no button flash)
    @State private var preGranted = false         // granted before we asked → let them read + tap on
    @State private var stage: Stage = .choose
    @State private var advanced = false          // one-shot guard on auto-advance

    private enum Stage { case choose, waiting, settings }

    private var granted: Bool { status == .granted }

    var body: some View {
        VStack(spacing: AkariSpacing.xl) {
            Text("\(number) of \(total)")
                .font(.akariMicro).tracking(1.6)
                .foregroundStyle(.white.opacity(0.35))
                .appearIn(0, appeared, reduce)

            OnboardingHero(
                icon: perm.icon,
                title: perm.name,
                subtitle: perm.why,
                appeared: appeared, reduce: reduce,
                titleFont: .akariTitle,
                badge: granted ? "checkmark.circle.fill" : nil)

            actionArea
                .frame(height: 34)
                .appearIn(3, appeared, reduce)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            appeared = true
            Task { await firstResolve() }
        }
    }

    @ViewBuilder private var actionArea: some View {
        if granted {
            if preGranted {
                // Already had it — no cascade; let them see it and step on.
                Button("Continue") { onNext() }.buttonStyle(.akariSolidProminent)
                    .transition(.opacity)
            } else {
                // Just earned it — ride the momentum onward automatically.
                Label("Granted", systemImage: "checkmark")
                    .font(.akariCaption).foregroundStyle(.green)
                    .transition(.opacity)
            }
        } else if !resolved || stage == .waiting {
            ProgressView().controlSize(.small)
        } else if stage == .settings {
            HStack(spacing: AkariSpacing.s) {
                Button("Open Settings") { NSWorkspace.shared.open(perm.settingsURL); pollForGrant() }
                    .buttonStyle(.akariSolidProminent)
                Button("Skip") { onNext() }.buttonStyle(.akariSolid)
            }
        } else {
            HStack(spacing: AkariSpacing.s) {
                Button("Allow") { perm.request(); pollForGrant() }
                    .buttonStyle(.akariSolidProminent)
                Button("Not now") { onNext() }.buttonStyle(.akariSolid)
            }
        }
    }

    /// Read the true status once. Already granted → mark it pre-granted (show the
    /// ✓ badge, wait for a tap; don't yank them forward when they didn't act).
    @MainActor private func firstResolve() async {
        let s = await perm.refresh()
        withAnimation(AkariMotion.swap) {
            status = s
            resolved = true
            if s == .granted { preGranted = true }
        }
    }

    /// After Allow / Open Settings, poll for the grant (~6s). Land → ✓ + advance;
    /// time out → reveal the Settings deep-link so a denied permission isn't a
    /// dead end.
    private func pollForGrant() {
        withAnimation { stage = .waiting }
        Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let s = await perm.refresh()
                if s == .granted {
                    withAnimation(AkariMotion.swap) { status = s }
                    scheduleAdvance(after: 0.7)
                    return
                }
            }
            withAnimation { stage = .settings }
        }
    }

    @MainActor private func scheduleAdvance(after seconds: Double) {
        guard !advanced else { return }
        advanced = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onNext()
        }
    }
}
