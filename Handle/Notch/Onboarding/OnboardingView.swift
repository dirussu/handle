import SwiftUI
import AppKit

/// First-run state. The old hardware GATE (refuse below M1/16 GB) is gone with
/// the on-device model; what remains is a soft note —
/// on-device voice (WhisperKit) wants Apple Silicon. Pure logic split out so
/// self-tests can hit it.
enum Onboarding {
    static let doneKey = "handle.onboarding.done"

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
        VStack(spacing: HandleSpacing.l) {
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
        .padding(.top, HandleSpacing.s)
        .padding(.bottom, HandleSpacing.m)
        .frame(maxWidth: .infinity)
    }

    private func advance(to next: Int) {
        withAnimation(reduce ? .easeOut(duration: 0.2) : HandleMotion.settle) { step = next }
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
            .animation(HandleMotion.enter.delay(Double(index) * 0.07), value: appeared)
    }
}

extension View {
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

extension AnyTransition {
    static var calmDissolve: AnyTransition {
        .modifier(active: Dissolve(out: true), identity: Dissolve(out: false))
    }
}

/// The hero: a softly-glowing, gently-breathing ring around the step's symbol,
/// then the oversized title + subtitle. White-only; the glow IS the accent.
struct OnboardingHero: View {
    let icon: String
    let title: String
    let subtitle: String
    let appeared: Bool
    let reduce: Bool
    var titleFont: Font = .handleDisplay
    var tint: Color = .white
    var badge: String? = nil          // small overlay mark (e.g. a green ✓ when granted)
    @State private var breathe = false

    var body: some View {
        VStack(spacing: HandleSpacing.l) {
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

            VStack(spacing: HandleSpacing.xs) {   // title + subtitle read as one tight block
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .appearIn(1, appeared, reduce)

                Text(subtitle)
                    .font(.handleBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HandleSpacing.s)
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
        .animation(HandleMotion.pop, value: index)
    }
}

// MARK: - Steps
