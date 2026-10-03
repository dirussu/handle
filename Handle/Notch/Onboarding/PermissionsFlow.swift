import SwiftUI
import AppKit

// MARK: - Permissions, one screen at a time
//
// A wall of six toggles reads as a chore — a form to endure. Instead we walk the
// user through the permissions ONE AT A TIME: each gets the full hero treatment,
// its own reason, and a single clear choice. Granting one glides to the next;
// an already-granted one flashes a green ✓ and moves on by itself. It feels
// guided, and every grant is a small, deliberate win rather than a checkbox.
struct PermissionsFlow: View {
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
        else { withAnimation(reduce ? .easeOut(duration: 0.2) : HandleMotion.settle) { index += 1 } }
    }

    private static func makePerms() -> [Perm] {
        [
            Perm(id: "sr", icon: "rectangle.dashed.badge.record", name: "Screen Recording",
                 why: "So Handle can see the screen you're asking about. A screenshot is taken only when you ask about the screen, sent only to the AI you connected, and never stored.",
                 refresh: { PermissionsService.screenRecording() },
                 request: { PermissionsService.requestScreenRecording() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_ScreenCapture")),
            Perm(id: "ax", icon: "hand.point.up.left", name: "Accessibility",
                 why: "So Handle can point at and click things for you, the way you'd ask a person to.",
                 refresh: { PermissionsService.accessibility() },
                 request: { PermissionsService.requestAccessibility() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Accessibility")),
            Perm(id: "mic", icon: "mic", name: "Microphone",
                 why: "So you can talk to Handle. Your voice is transcribed on this Mac — the audio never leaves.",
                 refresh: { PermissionsService.microphone() },
                 request: { PermissionsService.requestMicrophone() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Microphone")),
            Perm(id: "cal", icon: "calendar", name: "Calendars",
                 why: "So Handle can check your schedule and add events when you ask.",
                 refresh: { PermissionsService.calendars() },
                 request: { PermissionsService.requestCalendars() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Calendars")),
            Perm(id: "rem", icon: "checklist", name: "Reminders",
                 why: "So Handle can read and add your to-dos.",
                 refresh: { PermissionsService.reminders() },
                 request: { PermissionsService.requestReminders() },
                 settingsURL: PermissionsService.settingsURL(pane: "Privacy_Reminders")),
            // (No Notifications card: Handle's own notch notification center is the
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
        VStack(spacing: HandleSpacing.xl) {
            Text("\(number) of \(total)")
                .font(.handleMicro).tracking(1.6)
                .foregroundStyle(.white.opacity(0.35))
                .appearIn(0, appeared, reduce)

            OnboardingHero(
                icon: perm.icon,
                title: perm.name,
                subtitle: perm.why,
                appeared: appeared, reduce: reduce,
                titleFont: .handleTitle,
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
                Button("Continue") { onNext() }.buttonStyle(.handleSolidProminent)
                    .transition(.opacity)
            } else {
                // Just earned it — ride the momentum onward automatically.
                Label("Granted", systemImage: "checkmark")
                    .font(.handleCaption).foregroundStyle(.green)
                    .transition(.opacity)
            }
        } else if !resolved || stage == .waiting {
            ProgressView().controlSize(.small)
        } else if stage == .settings {
            HStack(spacing: HandleSpacing.s) {
                Button("Open Settings") { NSWorkspace.shared.open(perm.settingsURL); pollForGrant() }
                    .buttonStyle(.handleSolidProminent)
                Button("Skip") { onNext() }.buttonStyle(.handleSolid)
            }
        } else {
            HStack(spacing: HandleSpacing.s) {
                Button("Allow") { perm.request(); pollForGrant() }
                    .buttonStyle(.handleSolidProminent)
                Button("Not now") { onNext() }.buttonStyle(.handleSolid)
            }
        }
    }

    /// Read the true status once. Already granted → mark it pre-granted (show the
    /// ✓ badge, wait for a tap; don't yank them forward when they didn't act).
    @MainActor private func firstResolve() async {
        let s = await perm.refresh()
        withAnimation(HandleMotion.swap) {
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
                    withAnimation(HandleMotion.swap) { status = s }
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
